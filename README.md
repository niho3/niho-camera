# NIHO camera

**進捗・現在の目標・次の作業:** [PROGRESS.md](./docs/PROGRESS.md)

自分専用の macOS 向けローカル写真編集アプリです。Lightroom で作った XMP プリセットを登録し、RAW／JPEG に適用して Lightroom 相当のパネル（基本補正・トーンカーブ・HSL・カラーグレーディング・キャリブレーション）で微調整し、原寸 JPEG を書き出します。編集は写真ごとに自動保存され、Undo／Redo できます。

現在の要件は、**Lightroom の XMP をプリセット共通の現像処理で再現すること**です。方針は「Lightroom を教師にして操作ごとの応答を計測し、プリセット非依存の共通モデルへ落とす」で、正は [ENGINE_ROADMAP.md](./docs/ENGINE_ROADMAP.md) です。2026-09-23 時点で、RAW の基準現像（LibRaw + Adobe Standard DCP + Adobe Color）、基本補正・カーブ・HSL・グレーディング・Calibration・Texture／Clarity／Dehaze・RW2 埋め込みレンズ歪曲補正まで計測モデルで実装済みです。**ただし Lightroom との一致はまだ完成していません**（単体操作は平均 ΔE00 1〜2.5 の水準。オーナーの 4 プリセットは RAW で 1.2〜2.3、JPEG 入力で 1.8〜2.7、night のみ 5.4〜6.0）。

公開 Git リポジトリには source・tests・docs・契約 manifest だけを置き、個人写真、Lightroom 基準画像、生成 render、署名済み app は含めません。詳細は [Repository and local data policy](./DATA_POLICY.md) を参照してください。

このプロジェクトの目的、Lightroom から移行するための完成条件、これまでの取り組みは [プロジェクト概要](./PROJECT_OVERVIEW.md) を参照してください。
## 起動

Finderから`open-photo.command`をダブルクリックします。ターミナルからなら次でも起動できます。

```sh
./open-photo.command
```

ビルド済みアプリは`dist/NIHO camera.app`です（互換性のため実行ファイル名は`PhotoBench`のままです）。`open-photo.command`はソースがアプリより新しければ自動で再ビルドします。初回起動時は「フォルダを開く」から写真ルートを選び、以後はmacOSのsecurity-scoped bookmarkで同じフォルダを復元します。起動直後にDocumentsや外付けSSDを勝手に走査しません。手動ビルドは次で行えます。

「写真を開く」では1枚だけ選択できます。2026-10-12のMac Studio製ビルドはApple Silicon・macOS 26以降向けです。Swift/Visionのソース対象はmacOS 14以上ですが、配布バンドルの最低OSは同梱するdylibの要件も含めて自動設定します。LibRawなどの依存とライセンス文をアプリ内へ同梱するため、利用するMacにHomebrewを入れる必要はありません。

```sh
./scripts/build-app.sh
```

既定は個人ローカル利用向けのad-hoc署名です。アプリ本体を再ビルドするとmacOSから写真フォルダの再選択を求められる場合があります。自分のコード署名証明書を用意した場合だけ、`PHOTO_BENCH_CODESIGN_IDENTITY`へそのidentityを指定します。別組織の証明書は流用しません。

## 普段の使い方

1. 「フォルダを開く」で写真フォルダを選び、写真をクリックします。
2. 右側のプリセットライブラリから `colorful` / `bluesky2` / `night` / `pastel` を選びます。追加 XMP は上部の「プリセットを読み込む」から登録できます。
3. 右側の編集パネルで調整します。**基本補正**（RAW は色温度 K／色かぶり補正の絶対 WB、露光量・コントラスト・ハイライト・シャドウ・白レベル・黒レベル・テクスチャ・明瞭度・かすみの除去・自然な彩度・彩度）、**トーンカーブ**（parametric と点カーブ。クリックで点追加、ドラッグで移動、枠の外へドラッグで削除）、**HSL**（8 色 × 色相／彩度／輝度）、**カラーグレーディング**、**キャリブレーション**。各セクションに「リセット」があります。
4. 編集は自動保存されます。取り消しは `⌘Z`、やり直しは `⇧⌘Z`（スライダー 1 回のドラッグが 1 操作）。
5. 「JPEG を書き出す」で仕上がりを別ファイルに保存します。

編集と登録 XMP はアプリの Application Support / PhotoBench 内に保存し、原本には書き込みません。写真を移動・改名すると別の写真として扱います。Undo 履歴は起動中のみ保持します。保存に失敗した場合は「再試行」を使え、失敗が残ったままの終了時は確認を表示します。

背景除去はApple Visionを端末内で実行します。既定では最大の被写体を選び、個別被写体／全被写体の切替、透明／白／任意色背景、消す／戻すブラシに対応します。マスクはApplication Support / PhotoBench内へ入力内容hashと寸法・向き・推論器版を付けて不変保存し、原寸PNGまたは背景合成JPEGとして書き出します。CLIは次の形式です。

背景除去の設計・検証結果は[詳細設計](docs/NIHO_CAMERA_BACKGROUND_REMOVAL.md)を参照してください。GPT / ClaudeのサブスクやAPIキーは不要です。今回の実装はこのMacアプリ側で、NIHO本体への接続は別の工程です。

```bash
swift run niho-camera-cutout --input input.jpg --output cutout.png --subject largest --background transparent
```

## 現在できること

- ユーザーが選んだフォルダ以下にある JPEG / HEIC / PNG / TIFF / RAW を非同期走査し、選択権限を次回起動へ安全に保存
- **RAW の基準現像**: LibRaw でカメラ RGB を取り出し、Lightroom 同梱の Adobe Standard DCP（ColorMatrix／ForwardMatrix／HueSatMap／LookTable）と Adobe Color のルックテーブル・点カーブ、ACR 既定トーンカーブを DNG 仕様どおりに適用（`docs/PHASE1_BASE_RENDERING.md`）。プリセット無しで Lightroom 既定と平均 ΔE00 0.9〜1.2（レンズ歪曲補正込み）
- **RW2 埋め込みレンズ歪曲補正**: Panasonic DistortionInfo（IFD0 0x0119）の係数で Lightroom と同じ 6000×4000 の幾何に補正（自由パラメータ 0 個、格子点残差 0.4〜0.6 px）
- **計測モデルの現像操作**（`docs/PHASE2_DEVELOP_PIPELINE.md`、`docs/PHASE2_C2_C3.md`）: 露出（RAW はトーンカーブ前のリニア倍率）、絶対 WB（DNG SDK の式）、コントラスト／白／黒／parametric／点カーブ（sRGB 符号化空間の RGBTone。白を下げる・上げる、黒を上げるときは、輝度だけを動かす式と混ぜて LR と同じく彩度を保つ）、HSL 8 帯、Vibrance／Saturation、Color Grading／Split Toning、Camera Calibration、Highlights／Shadows（局所ラプラシアン、Metal compute）、Texture／Clarity（Laplacian 段別ゲイン）、Dehaze（大域カーブ＋彩度倍率）
- XMP の属性形式と要素形式を解析し、未対応項目（シャープ／NR、粒子、周辺光量、増分 WB、Refine Saturation ≠ 100）は互換性一覧で表示
- 写真ごとの編集・適用プリセットをバージョン付き JSON に自動保存し、再起動後に復元。破損・未知形式の記録は上書きせず読み込みエラーを表示
- Apple Visionによる端末内の背景除去。最大／個別／全被写体、透明・白・任意色、消す／戻すブラシ、原寸PNG／JPEGに対応
- ドラッグを 1 操作として取り消し・やり直し。写真ごとのセッション履歴を最大 100 操作保持
- スライダーのドラッグ中は近似で描いて速く追従し（Mac mini で 1 更新 0.1 秒以内）、離すと正確な画に静かに差し替える。`PHOTO_BENCH_PREVIEW_DIAG=1` で段ごとの時間を stderr に出し、`photobench-preview-bench` でドラッグを再現して計測できる
- 4 XMP を初期登録し、追加読込・重複抑止・登録削除に対応。適用済みの写真はプリセット登録を削除しても維持
- RAW とカラー編集途中は extended-linear sRGB を保持し、preview / 指定サイズ時は edge-clamped Lanczos で縮小した後に terminal sRGB transform を適用
- 原寸 sRGB JPEG を書き出し。原本・既存ファイルは上書きしない
- `photobench-render` CLI で GUI 無しに書き出し（計測ゲート用）。`PHOTO_BENCH_PREVIEW_ROUTE=metal-direct` の実験的な直接表示経路は従来どおり
- `photobench-engine`: NIHO Desktop の写真編集タブが使うときだけ起動する現像エンジン（標準入出力の JSON 行＋バイナリ、[docs/ENGINE_PROTOCOL.md](docs/ENGINE_PROTOCOL.md)）。`scripts/package-engine.sh` が LibRaw などの dylib を同梱した `dist/engine/` を作り、NIHO Desktop のビルドが取り込む（niho-coliving/niho-app#16314）
- `photobench-engine` の `renderWorkingCopy`: RAW / JPEG / PNG / HEIC / TIFF を、NIHO の現像エンジン用の作業コピー（linear ProPhoto・長辺 2560px・16bit PNG）とプレビューの JPEG にする。Adobe のカメラプロファイルと LibRaw を使わず、macOS の現像（Core Image）だけで作る（niho-coliving/niho-app#16943）

## 画質校正の現在地（2026-07-24 時点の履歴）

以下「画質校正」「RAW ホワイトバランス」「性能基準」「Metal 直接表示」の 4 節は、2026-07-24 時点の旧エンジン（Core Image RAW 土台）に対する formal 校正の記録です。現行エンジン（LibRaw + DCP、計測モデル）の到達値は `docs/ENGINE_ROADMAP.md` を参照してください。

2026-09-24 に、この校正 suite の manifest を現行の編集処理（`SpatialToneOps` / `ColorOps`）と校正機 Mac Studio へ再固定し、正式 run を再実行しました。RAW 経路は旧土台の Core Image RAW 8 のままです。Lightroom 書き出し前 TIFF を入力にする経路で見つかった非決定的な描画欠損は、同日に修正しました。最新の結果と制約は [CALIBRATION.md](./CALIBRATION.md) を正とし、以下の数値は 2026-07-24 の履歴です。

DC-S5の2組の「Lightroom適用前 / `colorful`適用後」16bit TIFFを基準に、RAW直結とLightroom適用前TIFF入力の2経路を測定します。`basic`はXMP HSL／カーブを除く既定経路、`full`は実験的なencoded-sRGB 1DカーブとOKLCh 8バンド・ミキサーまで有効にした経路です。

校正は平均・中央値・p95のCIEDE2000に加え、未ぼかし16bit TIFFのcomplete clip、near-clip、basic/fullで共有したハイライト領域に新たに生じるplateau、linear-sRGB輝度の平均EV driftをfail-closedで判定します。C1 shoulder修正後の最終結果は次のとおりです。

| シーン / 経路 | 平均 ΔE basic → full | 平均 EV差 basic → full | 新規共有 plateau |
|---|---:|---:|---:|
| P1524180 / RAW | 7.5927 → 6.7963 | +0.00384 → +0.20787 | 0.000357 |
| P1524180 / LR-input | 5.5557 → 4.8355 | -0.12577 → +0.02634 | 0.000371 |
| P1522877 / RAW | 5.8595 → 3.3423 | -0.18014 → +0.00710 | 0.000073 |
| P1522877 / LR-input | 5.4686 → 3.4174 | -0.26830 → -0.08392 | 0.000177 |

4経路すべてで平均ΔE、complete / near clip、新規共有plateauの条件を通過しました。唯一の不合格はP1524180 / RAWの平均EV差で、許容上限`0.05384 EV`に対して`+0.20787 EV`です。目視でも同sceneはLightroom-afterより明るく、暖色・マゼンタと青の彩度が強く見えます。そのため総合品質は不合格で、実験的XMP HSL／curveは既定OFFのままです。正確な定義と判定は[CALIBRATION.md](./CALIBRATION.md)と`.photobench/calibration/report.json`を正とします。

manifest v4ではproduction graphを **extended-linear-sRGB edits → edge-clamped Lanczos downsample → terminal sRGB transform** に固定しました。canonical settleは2 development sceneともcomplete clip `0 → 0`、near clip `0 → 0`で、新規共有plateauも`0.00003593 / 0.00009840`と上限`0.0005`以内でした。旧v3 archiveでは同じ2sceneでcomplete clipが`2,972 → 4,013`、`13 → 1,500`へ増えていたため、旧失敗を消さず改善証拠と対にして保存しています。これは2sceneの縮小後安全性だけを示し、Lightroom一致や未知sceneへの一般化ではありません。

preview parityは、原寸・3,072px・3,840pxの各RAW decodeへ同じ編集を適用し、最終2,560pxへ揃えて2シーン×3編集段階で判定します。

| RAW decode候補 | 最大平均ΔE00 | 最大ぼかし後p95 | 最大絶対EV | 最大plateau純増 | 最大1px許容外面積 | 不合格比較 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072px | 0.48847 | 1.57485 | 0.00549 | 0.00005492 | 0.00012105 | 2 / 6 | 不採用 |
| 3,840px | 0.41677 | 1.25678 | 0.00425 | 0.00009954 | 0.00021282 | 4 / 6 | 不採用 |

全6件の失敗理由は上限`0.0001`の1px dilation外にあるspatial plateauだけです。正式結果を見た後に閾値は緩めず、選択候補なし・full-resolution RAW decodeへのfallbackとしています。

## RAWホワイトバランスの現在地

製品へ接続する前に、As Shotは既存production decoder delegateへ委ねたまま、custom Temperature / Tintだけをfresh Core Image RAW 8 filterで観測する独立suiteを追加しました。正式run `51ba2f46-185d-4b87-8345-407d380214cd`は、2 development scene、各18候補、40 / 40 artifactの構造・hash・metadata検証に合格しました。custom中心点のsetter順序は両sceneでbyte exactでした。

ただし採用状態は`exploratory-observation-only`、`productionAdoptionAllowed = false`です。Lightroom側のTemperature / Tint教師sweep、灰色基準と領域別評価、5〜10以上のdevelopment scene、最低2 sealed holdoutがないため、候補の順位やAdobe→Apple変換は決めていません。製品のpreview / export / persistence / Undoにも未接続です。正確な結果と次の受け入れ条件は[RAWホワイトバランス観測記録](./docs/WHITE_BALANCE_OBSERVATION.md)を参照してください。

## 性能基準の現在地

manifest v4の現行source正式benchmark run `74e553f0-6b7c-4e2a-9e5d-4f09bc2910ce`はeligibleで、manifest / source / binary / inputの開始・終了整合を確認し、4 workload中3件が合格しました。

| engine workload | p95 | gate | 判定 |
|---|---:|---:|---|
| process-fresh tone preview | 358.4783 ms | ≤ 1,000 ms | 合格 |
| warm exposure-perturbation proxy | 60.1203 ms | ≤ 50 ms | 不合格 |
| warm full-current preview | 61.8840 ms | ≤ 300 ms | 合格 |
| 原寸JPEG quality 0.92 | 244.6853 ms | ≤ 3,000 ms | 合格 |

slider proxyだけが50ms gateを超えました。これは1回のengine runで、安定性や実UIのinput-to-screen latencyを証明しません。canonical v3の連続3 runは履歴として残しますが、v4の合否へ継承しません。詳しくは[BENCHMARK.md](./BENCHMARK.md)を参照してください。

process-freshは新しいworker processですが、timer前のmanifest検証がRAW全体をSHA-256読込するため、cold file-openではなくprevalidated / page-cache-warmed入力です。また現行値はengine wall-clockで、実UIのinput-to-screen latency、drop frame、hardware GPU timeではありません。定義、全分布、未計測項目、次の改善順は[BENCHMARK.md](./BENCHMARK.md)を正とします。

## Metal直接表示の現在地

原寸decode graphのCPU bitmap round-tripを外すための`MTKView` / `CIRenderDestination`経路は実装済みです。表示はsRGB / SDR、pixel formatは`.bgra8Unorm`、黒レターボックス付きaspect fitとし、1件のin-flightと最新pendingだけを保持します。expected request IDの原子的claim、window-levelの可視性判定、上限付き再描画、可視状態の10秒deadline、signpost / counter、その起動中の一方向fallbackを持ちます。previewの`cacheIntermediates`は、RSS上限と回収契約がない現段階では`false`です。

自動テストでは直接経路と従来経路のnative raster差が全channel 1 LSB以内であることと、aspect fit、queueの順序・不正ID拒否を確認しました。最終ハードニング直前の実アプリsmokeでは、可視状態のdraw後にGPU commandが2回`completed`になった一方、1回目は`presentedTime == 0`でdrop、2回目は提示callbackが返らず、10秒deadlineで従来表示へfallbackしました。その後に`drawableSize > 0`のwatchdog条件と`allowsNextDrawableTimeout = true`を追加し、最終sourceではfallback後の写真表示と空表示がないことを再確認しましたが、同じ詳細traceは再取得していません。**正の`presentedTime`、実画面の1 LSB parity、input-to-screen p95、drop率、定常RSSは未確立**です。古いdrawableのpresent登録後により新しいrequestが来た場合の完全なstale-present防止と、可視性・drop・timeout・teardownのapp lifecycle分岐の自動テストも残っています。

## 重要な制限

- Lightroom との一致は完成していません。単体操作は平均 ΔE00 1〜2.5、4 プリセットは RAW で 1.2〜2.3、JPEG 入力で 1.8〜2.7（night は 5.4〜6.0）です。ハイライト／シャドウは写真ごとの統計量で振幅と帯域位置を変える画像適応（RAW 14 scene、JPEG 8 scene の計測）を入れていますが、Lightroom の適応則の推定であって同一ではありません（`docs/ENGINE_ROADMAP.md`）。
- Adobe の現像数式は非公開で、計測に基づく近似です。カメラプロファイル（DCP）と Adobe Color は Lightroom の導入先から実行時に読み、リポジトリには含めません。DC-S5 以外の機種は DCP があれば動きますが検証していません。
- 周辺光量補正、色収差補正、既定シャープ／NR、粒子、非 RAW の増分 WB は未実装です。
- クロップ、明るさ等の局所補正ブラシ、SQLite カタログ、評価・選別、アルバム、移動した写真の再リンクは未実装です。
- 教師データは 3 scene（同一カメラ）と 4 プリセット × 2 scene が中心で、独立 holdout はまだ少数です。
- 校正 archive の置換は atomic ですが cross-process lock がなく、同じ root の並行校正は禁止です。
- 個人用 Mac mini（16GB）では原寸 float パイプラインの並行実行で watchdog リセットが起きたため、重い処理は Mac Studio で `scripts/studio/studio-run.sh` 経由で実行します（`docs/PROGRESS.md`「実行環境の注意」）。

## データの扱い

- 読み取り元の写真は変更しません。
- App Sandboxを有効にし、写真はユーザーが選んだフォルダのsecurity-scoped URL経由でだけ読み書きします。初回は自動走査せず、保存した権限が無効なら再選択を求めます。
- NSOpenPanel / NSSavePanelと復元bookmarkのアクセス開始・終了を対応させます。外付けSSDが一時的に外れている場合はbookmarkを削除せず、再接続後に復元できる状態を保ちます。
- JPEGは指定先へ隠し一時ファイルを作り、完成後だけ置き換えます。失敗時は一時ファイルを除去します。
- RAW固有のMakerNote等はレンダリング済みJPEGへコピーしません。
- 現在の開発用ルートはこのフォルダです。完成時はユーザーが選んだ外付けSSD上の写真フォルダを復元できる設計です。

## 重い処理は Mac Studio で行う

Mac mini（16GB）はアプリの利用と日常の編集に使い、次の重い処理は Mac Studio（64GB）で行います。Mac mini では、原寸の描画、`swift test`、release ビルド、numpy の原寸比較が重なると、メモリが逼迫して watchdog で再起動したことがあります。

- 全体の `swift test`、release ビルド、`photobench-render` による原寸の描画
- 実写ゲート（`scripts/lr_measure/`）と、原寸画像の比較・計測
- 校正の正式 run と WB 観測。校正機は Mac Studio に固定しています（[CALIBRATION.md](./CALIBRATION.md)）

開発中のソースは `scripts/studio/studio-run.sh` で Studio へ送って実行し、結果だけを取り込みます。

```sh
scripts/studio/studio-run.sh sync
scripts/studio/studio-run.sh run swift test
scripts/studio/studio-run.sh run swift build -c release --product photobench-render
scripts/studio/studio-run.sh fetch <結果の相対パス>
```

Mac mini で動かすのは、アプリそのものと、`swift test --filter PhotoCoreTests --jobs 2` のように対象を絞った軽い確認だけにします。重い処理を 2 つ以上同時に走らせないでください。

## 検証

```sh
cd /path/to/photoedit
swift test --filter PhotoCoreTests --jobs 2
swift build -c release --product photobench-render --jobs 2
python3 scripts/lr_measure/run_gate.py --render-binary .build/release/photobench-render --out-dir .photobench/phase2/c3-gate-results
python3 scripts/lr_measure/compare_renders.py --reference <LR 参照ディレクトリ> --renders <描画ディレクトリ> --no-align
```

2026-09-23 時点で `PhotoCoreTests` は **128 件全成功**（Mac mini と Mac Studio の両方）。空間処理は Python 参照実装との fixture 照合（相対誤差 0.0）と GPU／CPU の一致（最大 OKLab 距離 0.004）、レンズ補正は Python オラクルとの照合（< 1e-3 px）を含みます。全体の `swift test` は 2026-09-24 に Mac Studio で 206 件全成功しました。校正 manifest は校正機の Mac Studio に固定しているため、Mac mini では manifest を読み込むテストが実行環境不一致で失敗します（設計どおり）。

上のコマンドのうち release ビルドと実写ゲートは、前節のとおり Mac Studio で実行します。実写ゲート（Lightroom 書き出し比、30×20 領域平均 ΔE00）の到達値は `docs/ENGINE_ROADMAP.md` の各フェーズの結果節を正とします。2026-07-24 の formal 校正・性能結果（`CALIBRATION.md`、`BENCHMARK.md`）は履歴として維持し、今回のエンジンの合格証拠には流用しません。

## 文書

- [進捗・現在の目標・次の作業](./docs/PROGRESS.md)
- [汎用 XMP 現像エンジン: 調査結果と実行計画（現行方針の正）](./docs/ENGINE_ROADMAP.md)
- [フェーズ1 RAW 基準現像の設計](./docs/PHASE1_BASE_RENDERING.md) / [フェーズ2 現像パイプライン C1](./docs/PHASE2_DEVELOP_PIPELINE.md) / [C2・C3 設計](./docs/PHASE2_C2_C3.md)
- [日常編集の初版（2026-09-22）](./docs/EDITING_MVP.md)
- [プロジェクト概要・別セッション向け引継ぎ](./PROJECT_OVERVIEW.md)
- [全体設計](./DESIGN.md)
- [DC-S5 / Lightroom色校正](./CALIBRATION.md)
- [RAWホワイトバランス観測記録](./docs/WHITE_BALANCE_OBSERVATION.md)
- [再現可能な性能基準とP1判断](./BENCHMARK.md)
- [OSS・公式仕様の調査と採用判断](./RESEARCH.md)
- [Claude外部調査に基づく改善提案（方針レベルの参考資料）](./reviews/2026-07-24-claude-research-improvement-proposals.md)
- [RAW WB観測のClaude設計レビューと反映記録](./reviews/2026-07-24-claude-raw-wb-design-review.md)
- [RAW WB観測のClaude実装レビューと反映記録](./reviews/2026-07-24-claude-raw-wb-implementation-review.md)
- [P1-3 Metal直接表示のClaudeレビューと反映記録](./reviews/2026-07-24-claude-metal-direct-review.md)
- [P0証跡基盤とP1方針のClaude最終レビュー](./reviews/2026-07-24-claude-p0-evidence-review.md)
- [P1実装後のClaude最終レビューと対応記録](./reviews/2026-07-24-claude-p1-final-review.md)
- [初期Claude設計レビュー](./reviews/2026-07-23-claude-design-review.md)
- [初期Claude実装レビュー](./reviews/2026-07-23-claude-implementation-review.md)
- [トーン設計Claudeレビュー](./reviews/2026-07-23-claude-tone-design-review.md)
- [トーン実装Claudeレビュー](./reviews/2026-07-23-claude-tone-implementation-review.md)
