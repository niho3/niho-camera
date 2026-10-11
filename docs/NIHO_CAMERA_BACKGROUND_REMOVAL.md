# NIHO camera：背景除去の詳細設計

2026-10-12。Mac先行。対象は人物・家具・商品の切り抜きと透明／単色背景への変更。外部AIへ写真を送信しない。

## 完了条件

- アプリ表示名と配布バンドルを `NIHO camera` にする。既存の写真編集・保存データを引き継ぐ。
- 写真を選び「背景を除去」でApple Visionの端末内推論を実行する。既定は最大面積の被写体。検出された対象を切り替えられる。
- プレビューで透過を市松模様表示し、透明・白・任意色を選べる。ブラシで消す／戻すの補正ができる。
- 背景編集をUndo/Redo・保存・再起動後の復元に含める。色補正の操作では推論を再実行しない。
- 原寸透明PNG、単色背景PNG／JPEGを書き出せる。JPEGの透過領域は白または選択色へ合成する。元画像と既存出力を上書きしない。
- 指定写真 `_DSC5037.png` の中央人物を切り抜き、2731×4096の透明PNGを返す。右奥の小さな人物は対象に含めない。

## 構成

```text
NIHO camera (SwiftUI / macOS 14+)
  EditorModel / Undo / PhotoBenchStore
       ↓ 編集レシピ・マスク参照
  NihoCameraCutout（独立Swift library）
       ├─ Apple Vision：被写体別マスク生成
       ├─ マスク選択・ブラシ補正・Core Image合成
       └─ PNG / JPEG出力
  PhotoCore：既存の現像、プレビュー、原寸色補正

niho-camera-cutout CLI → 同じNihoCameraCutout
将来：NIHO Desktop native bridge → マスク契約 → 共通Rust描画
```

新ライブラリはLibRaw・Adobeプロファイル・ネットワークに依存しない。既存RAW現像の数学やXMP解釈は変更しない。指定PNGのCLI処理は現像プリセットを適用せず元画像の色を使う。

## マスクと座標の契約

- EXIFの向きを適用した画像を正とする。左上原点の正規化座標を編集レシピに保存する。Core Image合成時だけ下原点へ変換する。
- ソフトマスクは0＝背景、1＝被写体。髪・輪郭の中間透明度を保持する。元画像にもalphaがある場合は乗算し、透明部分を復活させない。
- アーティファクトはschema version、入力内容hash、正規化後の寸法、推論器とrevision、被写体IDに対応づける。元写真の内容が変わったときは古いマスクを適用しない。
- マスクはアプリ管理フォルダ内に不変ファイルとして保存し、JSONには小さなレシピと参照だけを保存する。パスは管理フォルダ内の安全なIDから解決する。
- ブラシは消す／戻すの正規化座標と半径を記録する。戻すは元画像の画素へ戻す。1ストロークをUndoの1操作とする。
- マスクを先に確実に保存してからレシピを保存する。既存schemaの背景設定がないレコードは背景編集なしとして読む。読めないマスクは明示エラーにし、元画像は残す。

## 推論と表示

`VNGenerateForegroundInstanceMaskRequest`と`VNInstanceMaskObservation`を使う。ラベル画像の面積から最大の被写体を選ぶ。ユーザーは個別被写体／全被写体を選び直せる。主被写体だけに固定した人物専用モデルは使わない。

推論はUIスレッド外で1件ずつ実行する。写真ID・load generation・入力hashを結果と照合し、写真切替後の遅い結果は破棄する。失敗・被写体なし・キャンセル時は元画像と既存編集を保持する。処理中表示と中止経路を用意する。

プレビューは現像後の画像へマスクを合成する。写真とマスクを同じextentへ合わせる。必要なら背景編集中は既存bitmap経路を使い、通常のMetalプレビューは保つ。原寸出力にも同じレシピを適用する。

## 書き出し

PNGはsRGB RGBA。JPEGは背景合成後に符号化する。ImageIOが実際に符号化できたことを確認し、Foundationの`itemReplacementDirectory`で取得した同一ボリュームの一時領域から、`link(2)`で排他的に配置する。NSSavePanelは選択したファイルへの権限を付与し、隣接する任意の一時ファイルは許可しないため、保存先の隣には一時ファイルを作らない。エラー時は不完全な完成ファイルを残さない。元画像、symlink経由の元画像、既存の切り抜き出力は保護する。

CLIは入力、出力、被写体選択、背景色を指定可能にする。成功時は寸法・選択被写体・処理時間を表示し、失敗時は非0終了する。クラウド送信も自動課金もない。

## 改名と互換性

ユーザーに見える名称、ウインドウ、保存名、README、バンドルをNIHO cameraへ変更する。既存の`life.niho.photobench` bundle ID、Application Support/PhotoBench、bookmark/defaultsキー、PhotoBench実行ファイルや既存CLIの識別子は互換性維持のため残す。リポジトリのフォルダ名は参照元を壊さないため変更しない。

## NIHO本体への接続範囲

今回の実装対象は指定されたMacアプリ。標準機能として本体へ接続するには、RustのRGB固定経路をRGBA保持へ変更し、同じマスクをプレビュー・出力・保存へ通す作業が別途必要。macOSの推論はこのライブラリ／CLIから再利用できる。Web向けONNXモデルは品質・ライセンス評価後に追加する。本体への未接続を、接続済みとして扱わない。

## 検証

- 合成：透明・白・任意色、元画像alpha、寸法と向き、複数被写体選択、ブラシ補正。
- 保存：旧JSON互換、マスク付きsnapshotのround-trip、Undo/Redo、プリセット適用時の背景編集保持、不正マスク参照。
- 書出し：PNG alpha、JPEG flatten、既存出力／入力保護、失敗時の後始末。
- 実写真：中央人物・手指・髪・足先・脇の抜けを目視し、入力hash不変と原寸出力を確認する。
- 実アプリ：改名したバンドルの起動、写真選択、切り抜き表示、背景色・補正・Undo・保存復元・書き出しを確認する。

release build・全体テスト・原寸処理はMac Studioで実行する。既存Studio checkoutは変更があるため使わず、今回専用のソースsnapshotで検証する。

## 品質上の境界

髪、半透明素材、ガラス、影は写真ごとに精度が変わる。対象写真での評価前にremove.bg同等とは主張しない。境界の旧背景色除去、バッチ処理、Web対応、クラウド同期、Rust現像への全面移行は初回の背景除去機能から独立して扱う。

## 実装・受入結果（2026-10-12）

NIHO camera 0.4.0 / build 6。独立ライブラリ`NihoCameraCutout`、`niho-camera-cutout` CLI、SwiftUI編集画面への接続を実装した。背景編集は既存schema 1レコードのoptional `backgroundEdit`へ保存し、古いレコードでは背景編集なしと扱う。マスクはcontent hash由来のIDで不変保存し、UndoはそのIDを参照する。

| 確認 | 結果 |
|---|---|
| 対象テスト | CutoutComposer / PhotoBenchStore / EditHistory / XMPPresetApplication：22件成功 |
| 保存方式修正後 | CutoutComposer：9件を再実行して成功 |
| ビルド | Mac Studio、Swift 6.3.3、release app build成功 |
| 同梱 | LibRaw・lcms2・libjpeg・libompを再帰同梱。ライセンス文・内側からの署名・Homebrew絶対参照ゼロを確認 |
| 署名 | 配布バンドルの`codesign --verify --deep --strict`成功 |
| 実UI | macOS 27で起動、写真選択、背景除去、透明／白／青背景、消す／戻すブラシ、Undoを確認 |
| 再起動 | 選択写真、保存済みマスク、透明背景を復元。再推論なしで表示 |
| 保存ダイアログ | サンドボックス有効のアプリから800×1200 PNG / JPEGを保存。PNG alphaあり、JPEG alphaなし |
| 原寸実写真 | 中央人物だけの2731×4096透明PNG。右奥の人物を含まない。元画像hash不変 |
| 輪郭 | Appleの`generateMaskedImage`とのalpha差は最大1/255。完全不透明領域のRGBは元写真との差0 |

入力のSHA-256：`5712cea20be49ba06e95642bc16eb415853e164bad24722a9b9dcc66701f1559`。原寸の最終切り抜きPNG：`f0bb78da2e68176b311e615cd629c52ad7e1cfdcc5d63650214fa6bd5f967e6e`。実測はStudioの初回CLI約5.3秒、後続約2.5秒。モデルの起動状態や写真によって変わる。

配布物は`dist/NIHO camera.app`と`dist/NIHO-camera.zip`。今回同梱したHomebrewライブラリの最低OSが26のため、バンドルもmacOS 26以降・Apple Silicon向けとしている。ソースの最低OSと配布物の最低OSを混同しない。個人利用用ad-hoc署名であり、一般配布のnotarizationは今回の工程に含めていない。

既存の写真選択・編集設定を保つため、UI受入は同じ実行バイナリを持つ別bundle IDの検証コピーで行った。原寸処理はStudio、手元のUI検証は長辺1200pxのコピーを使用した。個人写真や生成画像をGitへ追加していない。NIHO本体への接続、家具・ガラスなどの複数写真による品質評価、RAW現像全体の再校正は未実施。

最終コードの実行snapshotは`36cdc6790aa380a7`（ファイル別SHA-256 manifest付き）。対象22テストのsnapshotは`c66d35a094a50a15`で、後続のUndoキャッシュ復元は実UI、書き出し変更は9テストと実UIで確認した。文書の追記はビルド後に行った。

実装はSol high固定workerの初回batchと1回のレビュー修正batchを直列実行した。親担当が設計・差分レビュー・Studio検証・実UIを担当し、保存ダイアログの権限問題とバンドルの最低OS表示を最終修正した。workerのinput/cached/output個別値はこの実行方法では取得していないため、推定値は記録しない。
