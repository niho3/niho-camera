#!/bin/zsh
set -euo pipefail

PHOTO_APP_DIR="${0:A:h}"
PHOTO_APP_BUNDLE="$PHOTO_APP_DIR/dist/NIHO camera.app"
PHOTO_APP_EXECUTABLE="$PHOTO_APP_BUNDLE/Contents/MacOS/PhotoBench"

if [[ ! -x "$PHOTO_APP_EXECUTABLE" ]] \
    || [[ "$PHOTO_APP_DIR/Package.swift" -nt "$PHOTO_APP_EXECUTABLE" ]] \
    || [[ -n "$(/usr/bin/find \
        "$PHOTO_APP_DIR/Sources" \
        "$PHOTO_APP_DIR/Resources" \
        "$PHOTO_APP_DIR/scripts/build-app.sh" \
        -type f -newer "$PHOTO_APP_EXECUTABLE" -print -quit)" ]]; then
    "$PHOTO_APP_DIR/scripts/build-app.sh"
fi

exec /usr/bin/open "$PHOTO_APP_BUNDLE" --args "${1:-$PHOTO_APP_DIR}"
