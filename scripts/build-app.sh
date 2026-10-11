#!/bin/zsh
set -euo pipefail

PHOTO_APP_DIR="${0:A:h:h}"
PHOTO_APP_BUNDLE="$PHOTO_APP_DIR/dist/NIHO camera.app"
PHOTO_CONTENTS_DIR="$PHOTO_APP_BUNDLE/Contents"
PHOTO_ENTITLEMENTS="$PHOTO_APP_DIR/Resources/PhotoBench.entitlements"
PHOTO_CODESIGN_IDENTITY="${PHOTO_BENCH_CODESIGN_IDENTITY:--}"

if [[ "$PHOTO_CODESIGN_IDENTITY" != "-" ]]; then
    if ! /usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/grep -F "\"$PHOTO_CODESIGN_IDENTITY\"" >/dev/null; then
        echo "指定されたNIHO camera署名証明書が見つかりません: $PHOTO_CODESIGN_IDENTITY" >&2
        exit 1
    fi
else
    echo "NIHO cameraをローカル用ad-hoc署名で作成します。再ビルド後は写真フォルダの再選択が必要になる場合があります。" >&2
fi

/usr/bin/swift build -c release --product PhotoBench --jobs 2 --package-path "$PHOTO_APP_DIR"
/bin/rm -rf "$PHOTO_APP_BUNDLE"
/bin/mkdir -p \
    "$PHOTO_CONTENTS_DIR/MacOS" \
    "$PHOTO_CONTENTS_DIR/Frameworks" \
    "$PHOTO_CONTENTS_DIR/Resources/ThirdPartyLicenses"
/bin/mkdir -p "$PHOTO_CONTENTS_DIR/Resources/Presets"
/usr/bin/install -m 755 \
    "$PHOTO_APP_DIR/.build/release/PhotoBench" \
    "$PHOTO_CONTENTS_DIR/MacOS/PhotoBench"
/bin/cp "$PHOTO_APP_DIR/Resources/Info.plist" "$PHOTO_CONTENTS_DIR/Info.plist"
/usr/bin/install -m 644 \
    "$PHOTO_APP_DIR/Resources/AppIcon.icns" \
    "$PHOTO_CONTENTS_DIR/Resources/AppIcon.icns"
/usr/bin/install -m 644 \
    "$PHOTO_APP_DIR/niho-priset_colorful.xmp" \
    "$PHOTO_APP_DIR/niho-preset bluesky2.xmp" \
    "$PHOTO_APP_DIR/bluesky2-updated.xmp" \
    "$PHOTO_APP_DIR/niho-preset night.xmp" \
    "$PHOTO_APP_DIR/niho-preset pastel.xmp" \
    "$PHOTO_CONTENTS_DIR/Resources/Presets/"
# PhotoBench is the only executable installed in this app. The independent
# niho-camera-cutout CLI has no LibRaw dependency and is intentionally omitted.
/usr/bin/python3 "$PHOTO_APP_DIR/scripts/bundle-macho-dependencies.py" \
    --executable "$PHOTO_CONTENTS_DIR/MacOS/PhotoBench" \
    --frameworks "$PHOTO_CONTENTS_DIR/Frameworks" \
    --licenses "$PHOTO_CONTENTS_DIR/Resources/ThirdPartyLicenses" \
    --info-plist "$PHOTO_CONTENTS_DIR/Info.plist" \
    --sign "$PHOTO_CODESIGN_IDENTITY"
/usr/bin/codesign \
    --force \
    --entitlements "$PHOTO_ENTITLEMENTS" \
    --sign "$PHOTO_CODESIGN_IDENTITY" \
    --timestamp=none \
    "$PHOTO_APP_BUNDLE"

echo "$PHOTO_APP_BUNDLE"
