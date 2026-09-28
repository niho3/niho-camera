# photobench-engine プロトコル（v1）

NIHO Desktop（Tauri）が写真編集タブのために起動する、Photo Bench の現像エンジンの入出力の約束。
エンジンは PhotoCore をそのまま使い、画は Photo Bench アプリ・`photobench-render` と同じになる。
NIHO 側の Epic は niho-coliving/niho-app#16314（Desktop 側は #16316）。
`renderWorkingCopy`（NIHO の現像エンジンの段 1、niho-coliving/niho-app#16943。NIHO の Mac ワーカーが使う）だけは別の経路で、macOS の現像だけで作る。

## 起動と終了

- 起動: `photobench-engine --stdio`。NIHO Desktop が子プロセスとして起動する（写真編集タブで最初の要求が来たとき）
- 終了: 標準入力が閉じたら、走行中の `render` を取り消して終了する。`shutdown` 要求でも終了する（どちらも、走行中の `open` / `export` / `renderWorkingCopy` は終わるまで最大 30 秒待つ。まだ始まっていない要求には応答しない）
- 標準エラー出力はログ（1 行 1 件、先頭に `photobench-engine:`）。NIHO Desktop は末尾だけを保持する
- 環境変数は NIHO Desktop が許可したものだけが渡る前提で、HOME と PATH 以外に依存しない

## 形式

- 要求: 標準入力に 1 行 1 つの JSON（UTF-8、改行で区切る）
  `{"id": 1, "method": "open", "params": {...}}`
  `id` は正の整数で、呼び出し側が一意に振る
- 応答: 標準出力に 1 行の JSON ヘッダ。バイナリを伴う応答は、ヘッダの `"binaryLength": N` の改行の直後に、ちょうど N バイトの本体が続く
  - 成功: `{"id": 1, "ok": true, "result": {...}}`（バイナリ付きは `"binaryLength"` と `"mime"` を足す）
  - 失敗: `{"id": 1, "ok": false, "error": {"code": "...", "message": "..."}}`
  - `id` が読めない行（JSON でない、`id` が無い・正の整数でない）には `"id": 0` の `invalidRequest` を返す
- 応答は `id` で対応づける。順番は要求と一致しないことがある（`render` の取り消しなど）
- 標準出力には応答以外を書かない

### エラーコード

| code | 意味 |
|---|---|
| `invalidRequest` | JSON が読めない、method が無い・知らない、params の型が違う、パスが絶対パスでない |
| `notFound` | `photoId` が開かれていない（`close` した写真の、待機中・走行中の `render` も） |
| `cancelled` | 同じ写真へのより新しい `render` が来たので取り消した |
| `decodeFailed` | 写真を読めない（壊れている・対応していない形式・ファイルが無い） |
| `unsupportedCamera` | `renderWorkingCopy`: macOS の RAW 現像（RAW 8、DNG は 8.dng）がその機種に対応していない |
| `unsupportedProfile` | `renderWorkingCopy`: 写真の埋め込み ICC が壊れていて色空間を作れない |
| `presetInvalid` | XMP を読めない、Camera Raw の設定が 1 つも無い |
| `exportFailed` | 書き出せない（書き込み先に書けない、開いている写真の原本を上書きしようとしたなど） |
| `internal` | それ以外 |

Adobe のカメラプロファイルが見つからない RAW はエラーにしない（macOS の RAW 現像で開き、`open` の `profile` が `fallback` になる）。

## 編集設定（settings）

PhotoCore の `EditSettings` を JSONEncoder で書いたもの（Photo Bench アプリの保存形式と同じ）。
呼び出し側は `presetSettings` などで受け取った JSON を保持し、次の数値キーだけを書き換えて送り返す。それ以外のキーは中身を解釈せず、そのまま返す。

| キー | 範囲 | 意味 |
|---|---|---|
| `exposure` | −5〜+5 | 露光量（EV） |
| `contrast` / `highlights` / `shadows` / `whites` / `blacks` | −100〜+100 | 基本補正 |
| `texture` / `clarity` / `dehaze` | −100〜+100 | テクスチャ・明瞭度・かすみの除去 |
| `vibrance` / `saturation` | −100〜+100 | 自然な彩度・彩度 |
| `whiteBalance` | オブジェクト | RAW の色温度・色かぶり補正。`{"mode": "custom", "temperature": 2000〜50000, "tint": −150〜+150}`、撮影時に戻すときは `{"mode": "asShot"}` |
| `relativeTemperature` / `relativeTint` | −100〜+100 | RAW 以外（JPEG など）の色温度・色かぶり補正 |

`whiteBalance` が効くのは、`open` の `asShotWhiteBalance` が null でない写真（Adobe のカメラプロファイルで開いた RAW）だけ。
RAW 以外と `profile: "fallback"` の RAW には `relativeTemperature` / `relativeTint` を使う（Photo Bench アプリと同じ）。

## メソッド

### `hello`
- params: なし
- result: `{"engineVersion": "0.2.0+<git sha>", "protocolVersion": 1}`（メソッドを足しても `protocolVersion` は 1 のまま。0.2.0 で `renderWorkingCopy` を足した）
  `<git sha>` は 12 桁。未コミットの変更を含むビルドは `+<git sha>.dirty`、`scripts/package-engine.sh` を通さない開発ビルドは `+dev`

### `profileStatus`
この Mac の Adobe のカメラプロファイルがどこにあるか。写真を開かずに、ファイルがあるかだけを見る（中身は読まない）。NIHO Desktop の写真編集の「設定」が、基準現像が Adobe か macOS かを出すのに使う（NIHO #16592）。
- params: なし
- result: `{"available": true, "lookSource": "sharedCameraRaw" | null, "dcpSources": ["sharedCameraRaw", "lightroom"]}`
  - `lookSource`: `open` が使う Adobe Color の出どころ。`dcpSources`: カメラの DCP が 1 つ以上ある出どころ（探す順）。`available` は両方あるとき true
  - 出どころ: `userCameraRaw`（`~/Library/Application Support/Adobe/CameraRaw`）/ `sharedCameraRaw`（`/Library/Application Support/Adobe/CameraRaw`。Adobe DNG Converter と Camera Raw が入れる）/ `lightroom`（Lightroom のアプリの中）/ `lightroomClassic`（Lightroom Classic のアプリの中）
  - `available` が true でも、入っている版より新しいカメラの RAW は `profile: "fallback"` で開く（その機種の DCP が無い）
  - 結果はキャッシュしない。エンジンの動いている間に DNG Converter を入れても、次の `profileStatus` と `open` から見える
  - 外付けのディスクにある Lightroom を見に行くことがあるので、読み込みの行とも `render` とも別の列で答える

### `builtinPresets`
エンジンに同梱した NIHO のプリセット（bluesky2 / colorful / night / pastel）。
- params: なし
- result: `{"presets": [{"id": "niho-bluesky2", "name": "bluesky2", "xmp": "<XMP 本文>"}, ...]}`

### `presetSettings`
XMP を読み、`base` に当てた編集設定を返す（Lightroom と同じく、プリセットが持つ項目だけを置き換える）。
- params: `{"xmp": "<XMP 本文>", "base": <settings>}`（`base` を省くと既定値に当てる）
- result: `{"name": "<プリセット名>", "settings": <settings>, "unsupported": ["Sharpness", ...]}`
  `name` は XMP の `crs:Name`（無ければ空文字）。
  `unsupported` は、エンジンが再現しない項目（シャープ・ノイズ軽減・粒子・周辺光量など）の XMP キー名。Photo Bench アプリが「未対応」と数える項目と同じで、値が 0 の項目や Photo Bench が知らない項目も含む（埋め込みの Look は `Look.<キー>`）

### `open`
写真を読み、プレビュー用の作業コピー（長辺 2560px）を作る。原寸のデコードは保持せず、`export` のときに読み直す。
- params: `{"path": "<絶対パス>"}`（NIHO Desktop がネイティブの選択ダイアログで得たパスだけを渡す）
- result: `{"photoId": "<ID>", "kind": "raw" | "raster", "fileName": "P1524180.RW2", "width": 6000, "height": 4000, "asShotWhiteBalance": {"temperature": 5200, "tint": 3} | null, "profile": "adobe" | "fallback" | null, "settings": <既定の編集設定>}`
  `width` / `height` は向きを反映した原寸。`settings` は何も当てていない状態（Photo Bench の `EditSettings.neutral`）で、プリセットを当てるときの `base` にもなる
  - `profile`: RAW をどう現像したか。`adobe` は Adobe のカメラプロファイル（Lightroom と同じ基準の色）。`fallback` はプロファイルが見つからない（または LibRaw が読めない）ため macOS の RAW 現像（Core Image）で開いたもので、色は Lightroom と揃わない。Lightroom / Lightroom Classic / Adobe DNG Converter のどれかを入れると `adobe` になる。RAW 以外は null
  - `asShotWhiteBalance`: 撮影時の色温度・色かぶり（整数に丸めた値）。`profile` が `adobe` の RAW のときだけ
- 同時に開いておける写真は 4 枚まで。5 枚目を開くと、いちばん長く使っていない写真の作業コピーを捨てる（`photoId` はそのまま使え、次の要求で読み直す）

### `render`
プレビューの JPEG を返す（バイナリ付き）。
- params: `{"photoId": "<ID>", "settings": <settings>, "maxDimension": 1600, "drag": false, "original": false}`
  - `maxDimension`: 長辺の上限（px、最大 2560。省くと 2560、それより大きい値は 2560 として扱う）
  - `drag`: スライダーをドラッグ中なら true。その写真で最初の `drag: true` の settings からドラッグが始まり、近似で速く描く（Photo Bench の `PreviewDragSession` と同じ）。離したら `drag: false` でもう一度呼ぶと正確な画になり、ドラッグが終わる
  - `original`: true なら編集前（既定の設定）の画。`settings` は省いてよく、ドラッグの状態は変えない
- result: `{"width": 1600, "height": 1067}`、`"mime": "image/jpeg"`、`"binaryLength": N`（`width` / `height` は JPEG の画素数。原寸より大きくはしない）
- 同じ写真へのより新しい `render` が来たら、待機中のものはすぐに、走行中のものは止まったところで `cancelled` で終わる（別の写真の要求と `export` は取り消さない）
  ドラッグ中は前の応答が返ってから次を送る（待たずに送り続けると取り消しが続き、画が出ない）

### `export`
原寸の JPEG を書き出す。
- params: `{"photoId": "<ID>", "settings": <settings>, "destinationPath": "<絶対パス>.jpg", "jpegQuality": 0.92}`（NIHO Desktop が保存ダイアログで得たパスだけを渡す。`jpegQuality` は省くと 0.92）
- result: `{"path": "<書いたパス>", "width": 6000, "height": 4000, "bytes": 8123456}`
  書き込み先のフォルダが無ければ作る。開いている写真の原本は上書きしない（`exportFailed`）

### `renderWorkingCopy`
原本を 1 回だけ「作業コピー」（linear ProPhoto（D50）・長辺 2560px・16bit PNG）にし、求められればプレビューの JPEG も作る（NIHO の現像エンジンの段 1、niho-coliving/niho-app#16943）。写真を `open` せずに使う。
**Adobe のカメラプロファイル（DCP・Adobe Color）と LibRaw を使わない経路**: RAW は macOS の RAW 現像（Core Image の `CIRAWFilter`、RAW 8。DNG は `8.dng`）、それ以外は Core Image の色管理だけで作る。Lightroom や DNG Converter が入った Mac でも結果は変わらない。
- params: `{"path": "<原本の絶対パス>", "workingCopyPath": "<絶対パス>.png", "previewPath": "<絶対パス>.jpg", "maxDimension": 2560, "previewMaxDimension": 1024}`
  - `previewPath`: 省くか null ならプレビューを作らない
  - `maxDimension`: 作業コピーの長辺の上限（省くと 2560、それより大きい値は 2560 として扱う）。`previewMaxDimension`: プレビューの長辺の上限（省くと 1024、1〜2560）。どちらも原寸より大きくはしない
  - 書き込み先のフォルダが無ければ作る。どちらも一時ファイルに書き、両方できてから名前を変えて置く（途中で失敗したらどちらも置かない）
  - 原本（と開いている写真）・フォルダ自体・作業コピーと同じパスのプレビューには書かない（`exportFailed`）
  - `open` / `render` / `export` と同じ列で 1 件ずつ実行する。取り消さない
- result:
  ```json
  {"kind": "raw", "baseVersion": "raw-apple.d8.p1.e1.cal-none",
   "width": 2560, "height": 1707, "sourceWidth": 6000, "sourceHeight": 4000, "bytes": 14567890,
   "preview": {"width": 1024, "height": 683, "bytes": 234567},
   "meta": {...}, "timings": {"decodeMs": 1200, "workingCopyMs": 800, "previewMs": 300}}
  ```
  - `kind`: 拡張子が RAW（rw2・raw・dng・arw・cr2・cr3・nef・orf・raf）なら `raw`、それ以外は `raster`
  - `width` / `height` は書いた PNG を読み戻した画素数、`sourceWidth` / `sourceHeight` は向きを反映した原寸、`bytes` / `preview.bytes` はファイルの大きさ。`preview` は `previewPath` を省いたとき null
  - `timings`（ミリ秒の整数）: `decodeMs` は原本を開いて縮小済みの線形の画素にするまで（Core Image はデコード・色の変換・縮小を 1 回の描画で行う）、`workingCopyMs` は 16bit への符号化・PNG・書き込み・読み戻し、`previewMs` はプレビューのデコード・JPEG・書き込み・読み戻し（プレビューが無ければ 0）
  - `baseVersion`（object key に入るので `[A-Za-z0-9._-]` だけ）:
    - RAW: `raw-apple.d<RAW デコーダの版>.p<段 1 の処理の版>.e<符号化の版>.cal-<機種別補正>`。今は `raw-apple.d8.p1.e1.cal-none`（`cal-none` は機種別補正なし。S9a が `cal-<id>-v<n>` を足す）
    - DNG（iPhone の ProRAW・DNG Converter の出力など）は Core Image が RAW 8 を `8.dng` として出すので `raw-apple.d8dng.p1.e1.cal-none`（デコーダの版は `meta.decoderVersion` から `.` を除いた小文字）
    - raster: `raster.ci1.p1.e1.icc-<ICC の SHA-256（小文字 64 桁）>`、ICC の無い画像は `raster.ci1.p1.e1.icc-srgb`（`ci1` は Core Image の色管理の版）
- `meta`（原本の種類ごと。`kind` で見分ける。カメラの機種名・ファイル名・撮影日時・位置情報は入れない）:
  - RAW: `{"kind": "raw", "engine": "apple-raw", "decoderVersion": "8", "baselineEV": 0, "calibration": "none", "asShotWhite": {"x": 0.3457, "y": 0.3585, "temperature": 5200, "tint": 3}, "orientationApplied": true, "lensCorrection": "apple" | null, "noiseReduction": {"luminance": <数>, "color": <数>}, "sharpness": <数>, "encoding": {"format": "png16", "gamma": 1.8, "ceiling": 2}, "colorSpace": "linear-prophoto-d50", "sourceExtension": "rw2"}`
    - `decoderVersion`: 使った `CIRAWFilter` の版。RAW 8 に固定し、DNG だけは `"8.dng"`（RAW 8 が無く `8.dng` がある写真）
    - `baselineEV`: 段 2 が露出の前に足す EV。Apple の BaselineExposure は作業コピーの画素に入っているので 0
    - `asShotWhite`: `CIRAWFilter` の撮影時の白。`x` / `y` は `neutralChromaticity`、`temperature` / `tint` は Core Image の値（`neutralTemperature` / `neutralTint` を整数に丸めたもの。Adobe の色温度・色かぶりとは尺度が違う）
    - `lensCorrection`: macOS がレンズを補正したら `apple`、しなければ null。`noiseReduction` / `sharpness`: 使った `CIRAWFilter` の既定値（変えていない）
  - raster: `{"kind": "raster", "cms": "ci1", "icc": {"sha256": "<hex>" | null, "description": "Display P3" | null}, "orientationApplied": true, "encoding": {...RAW と同じ}, "colorSpace": "linear-prophoto-d50", "sourceExtension": "heic"}`
    - `icc`: Core Image が変換元にした ICC（`CGColorSpace.copyICCData()` のバイト列の SHA-256 と、その説明）。色空間の無い画像と ICC を持たない色空間（macOS は CMYK の JPEG を device RGB で開く）は sRGB として扱い、両方 null。macOS は ICC の無い JPEG / PNG / TIFF や壊れた ICC の画像も sRGB の ICC で開くので、それらは sRGB の ICC の SHA-256 になる
- 作業コピーの中身:
  1. RAW: `CIRAWFilter` を RAW 8（DNG は `8.dng`）に固定し、`boostAmount` 0・`exposure` 0・`shadowBias` 0・`boostShadowAmount` 1・EDR 0 の線形の出力（`RAWDecodeConfiguration.calibrationBaseline`。機種別の設定は使わない）。向き・レンズ補正・ノイズ軽減・シャープは Apple の既定。raster: `CIImage` で向きを反映し、ICC から Core Image の作業空間（extended linear sRGB）へ
  2. linear sRGB → linear ProPhoto（D50。`DNGColorSpace.srgbLinearToProPhoto`）→ 0 未満を 0 にする（上は切らない）
  3. 長辺 `maxDimension` へ Lanczos で縮小（端を延ばす。Photo Bench のプレビュー用作業コピーと同じ）
  4. 16bit PNG（RGB・アルファ無し・big-endian。チャンクは IHDR・IDAT・IEND だけで、ICC・EXIF・XMP・色のチャンクを入れない）。各成分 `v`（linear ProPhoto、0 以上）を `code = round(65535 × (min(v, 2) / 2)^(1/1.8))` で符号化し、復号は `v = 2 × (code / 65535)^1.8`（Photo Bench の cube と同じ gamma 1.8、上限 2.0）
- プレビュー: Apple 標準の見た目の sRGB JPEG（長辺 `previewMaxDimension`、原本のメタデータ無し）。RAW は別の `CIRAWFilter`（デコーダの版は作業コピーと同じ。ほかは既定のまま）を縮小デコードし、必要なら Lanczos で長辺を合わせる。品質 0.85 で 1,048,576 バイトを超えたら 0.75 → 0.65 → 0.55 → 0.45 と下げ、それでも超えたら `exportFailed`
- エラー: `decodeFailed`（ファイルが無い・壊れている・拡張子は RAW だが中身が RAW でない）、`unsupportedCamera`（macOS の RAW 8（DNG は `8.dng`）がその機種に対応していない。LibRaw などには切り替えない）、`unsupportedProfile`（Core Image が返した色空間の ICC を ColorSync が読めない。macOS は壊れた ICC をふつう無視して sRGB で開くので、まれ）、`exportFailed`（書けない、原本の上書き、プレビューが 1MiB を超える）、`invalidRequest`（パスが絶対パスでない、`maxDimension` が 0 以下、`previewMaxDimension` が 1〜2560 の外）

### `close`
- params: `{"photoId": "<ID>"}`
- result: `{}`（その写真の待機中・走行中の `render` は `notFound` で終わる）

### `shutdown`
- params: なし
- result: 走行中の `render` を取り消し、走行中の `open` / `export` / `renderWorkingCopy` が終わるのを待ってから `{}` を返して終了する。まだ始まっていない要求と、`shutdown` の後に届いた要求には応答しない

## 第三者ライセンス

`dist/engine/licenses/` に、同梱する dylib のライセンス文を Homebrew の keg ごと（`<formula>-<version>/`）に置き、一覧を `licenses/INDEX.txt` に書く（LibRaw: LGPL-2.1-only OR CDDL-1.0、Little CMS: MIT、libjpeg-turbo: IJG AND BSD-3-Clause AND Zlib、JasPer: JasPer-2.0、LLVM OpenMP: Apache-2.0 WITH LLVM-exception）。
LibRaw などは動的リンクのまま同梱し、差し替えできる形を保つ。Adobe のカメラプロファイルは同梱しない（各 Mac の Lightroom / DNG Converter から実行時に読む）。

## 同梱の形（NIHO Desktop へ）

`scripts/package-engine.sh` が `dist/engine/` を作る。

```
dist/engine/
  MacOS/photobench-engine      # 実行ファイル（LC_RPATH = @executable_path/../Frameworks）
  Frameworks/*.dylib           # LibRaw・lcms2 と、その依存（install name は @rpath/…）
  licenses/                    # 同梱 dylib のライセンス文と一覧（INDEX.txt）
  engine.json                  # 版・git の commit・同梱 dylib の出所と対応 macOS・各ファイルの SHA-256
```

NIHO Desktop のビルドは、`MacOS/photobench-engine` を `Contents/MacOS/photobench-engine` に、`Frameworks/` の dylib を `Contents/Frameworks/` に置く。
`dist/engine/` の中も同じ相対位置なので、開発時はその場で起動できる。
すべて ad-hoc 署名する（Apple Silicon は署名の無い・壊れた実行ファイルを起動しない）。NIHO Desktop を Developer ID で署名・公証するときは、hardened runtime のライブラリ検証に通るよう、同梱の dylib と実行ファイルも同じ ID で署名し直す。
同梱の dylib は Homebrew のボトルなので、パッケージを作った Mac の macOS 向けにビルドされている。起動できる最も古い macOS は `engine.json` の `minimumMacOS`（実行ファイル自体は macOS 14 以降）。
