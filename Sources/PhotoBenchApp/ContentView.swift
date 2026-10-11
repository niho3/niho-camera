import AppKit
import Metal
import MetalKit
import NihoCameraCutout
import PhotoBenchAppSupport
import PhotoCore
import QuartzCore
import SwiftUI
import os

struct ContentView: View {
    @EnvironmentObject private var model: EditorModel
    @State private var presetPendingDeletion: StoredXMPPreset?
    @State private var isBasicSectionExpanded = true
    @State private var isDrawingCutoutStroke = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            NihoDivider()
            HStack(spacing: 0) {
                libraryPane
                NihoDivider()
                centerPane
                NihoDivider()
                inspectorPane
            }
            NihoDivider()
            statusBar
        }
        .background(NihoPalette.canvas)
        .foregroundStyle(NihoPalette.ink)
        .tint(NihoPalette.green)
        .preferredColorScheme(.light)
        .confirmationDialog(
            "「\(presetPendingDeletion?.name ?? "プリセット")」を削除しますか？",
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let presetPendingDeletion {
                    model.deletePreset(id: presetPendingDeletion.id)
                }
                presetPendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) { presetPendingDeletion = nil }
        } message: {
            Text("登録だけを削除します。すでに写真へ適用した編集は保持されます。")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("フォルダを開く", action: model.chooseFolder)
                .disabled(!model.canChooseFolder)
            Button("写真を開く", action: model.choosePhoto)
                .disabled(!model.canChooseFolder)
            Button("プリセットを読み込む", action: model.importPreset)
                .disabled(model.isBusy)
            NihoDivider().frame(height: 18)
            Text(model.selectedAsset?.filename ?? "写真を選択")
                .font(.headline).foregroundStyle(NihoPalette.heading)
                .lineLimit(1)
            Spacer()
            if model.decodeInfo?.isRAW == true {
                Label("RAW", systemImage: "camera.aperture")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NihoPalette.coralInk)
            }
            if let info = model.decodeInfo, info.isRAW {
                let isCalibratedDCS5 = info.calibrationID
                    == RAWCalibrationProfile.panasonicDCS5Lightroom93.id
                NihoChip(
                    text: isCalibratedDCS5 ? "DC-S5 色差試験（白飛び未校正）" : "機種別の色は未校正",
                    foreground: NihoPalette.coralInk,
                    background: NihoPalette.coralTint
                )
            }
            if model.preset != nil {
                NihoChip(
                    text: "XMP近似・未校正",
                    foreground: NihoPalette.caution,
                    background: NihoPalette.creamTint
                )
            }
            if model.previewRoute == .metalDirect {
                NihoChip(
                    text: "Metal直接表示・検証中",
                    foreground: NihoPalette.navy,
                    background: NihoPalette.skyTint
                )
            }
            Menu("書き出す") {
                Button("JPEGを書き出す", action: model.exportFromPanel)
                Button("PNGを書き出す", action: model.exportPNGFromPanel)
                    .disabled(!model.isShowingCutout)
            }
            .menuStyle(.borderlessButton)
            .disabled(!model.canExport)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("写真")
                    .font(.headline).foregroundStyle(NihoPalette.heading)
                Text(model.rootURL?.path ?? "写真フォルダを選択してください")
                    .font(.caption2)
                    .foregroundStyle(NihoPalette.muted)
                    .lineLimit(2)
            }
            .padding(12)
            NihoDivider()
            List(model.assets, selection: $model.selectedAssetID) { asset in
                HStack(spacing: 8) {
                    Image(systemName: asset.kind == .raw ? "camera.aperture" : "photo")
                        .foregroundStyle(asset.kind == .raw ? NihoPalette.coralInk : NihoPalette.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.filename)
                            .lineLimit(1)
                        Text(asset.kind.rawValue)
                            .font(.caption2)
                            .foregroundStyle(NihoPalette.muted)
                    }
                }
                .tag(asset.id)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(NihoPalette.canvas)
            .disabled(model.isBusy)
        }
        .frame(width: 230)
    }

    private var centerPane: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    if model.isShowingCutout {
                        CheckerboardBackground()
                    } else {
                        NihoPalette.photoStage
                    }
                    if model.previewRoute == .metalDirect,
                       !model.isShowingCutout,
                   let request = model.directPreviewRequest {
                        DirectMetalPreviewView(
                            request: request,
                            onPresented: model.directPreviewPresented,
                            onCoalesced: model.directPreviewCoalesced,
                            onDrawableUnavailable: model.directPreviewDrawableUnavailable,
                            onDropped: model.directPreviewDropped,
                            onFailure: model.directPreviewFailed
                        )
                        .padding(20)
                    } else if let preview = model.preview {
                        Image(nsImage: preview)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .aspectRatio(contentMode: .fit)
                            .shadow(color: NihoPalette.heading.opacity(0.14), radius: 10, y: 3)
                            .padding(20)
                    } else if model.isBusy || model.hasPreviewInFlight {
                        ProgressView("プレビューを準備中…")
                    } else {
                        ContentUnavailableView("写真がありません", systemImage: "photo")
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(cutoutBrushGesture(in: geometry.size))
            }
            filmstrip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private func cutoutBrushGesture(in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.isShowingCutout,
                      let imageSize = model.preview?.size,
                      let point = normalizedImagePoint(
                        value.location,
                        canvasSize: canvasSize,
                        imageSize: imageSize
                      )
                else { return }
                if isDrawingCutoutStroke {
                    model.continueBrushStroke(at: point)
                } else {
                    isDrawingCutoutStroke = true
                    model.beginBrushStroke(at: point)
                }
            }
            .onEnded { _ in
                guard isDrawingCutoutStroke else { return }
                isDrawingCutoutStroke = false
                model.finishBrushStroke()
            }
    }

    private func normalizedImagePoint(
        _ location: CGPoint,
        canvasSize: CGSize,
        imageSize: CGSize
    ) -> CutoutPoint? {
        let available = CGSize(
            width: max(0, canvasSize.width - 40),
            height: max(0, canvasSize.height - 40)
        )
        guard imageSize.width > 0, imageSize.height > 0,
              available.width > 0, available.height > 0
        else { return nil }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: 20 + (available.width - fitted.width) / 2,
            y: 20 + (available.height - fitted.height) / 2
        )
        guard location.x >= origin.x, location.x <= origin.x + fitted.width,
              location.y >= origin.y, location.y <= origin.y + fitted.height
        else { return nil }
        return CutoutPoint(
            x: Double((location.x - origin.x) / fitted.width),
            y: Double((location.y - origin.y) / fitted.height)
        )
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(model.assets) { asset in
                    Button {
                        model.selectedAssetID = asset.id
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(asset.kind == .raw ? NihoPalette.coralTint : NihoPalette.creamTint)
                                Image(systemName: asset.kind == .raw ? "camera.aperture" : "photo")
                                    .font(.title2)
                                    .foregroundStyle(asset.kind == .raw ? NihoPalette.coralInk : NihoPalette.muted)
                            }
                            .frame(width: 74, height: 48)
                            .overlay {
                                if model.selectedAssetID == asset.id {
                                    RoundedRectangle(cornerRadius: 4).stroke(NihoPalette.green, lineWidth: 2)
                                }
                            }
                            Text(asset.filename)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 86)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                }
            }
            .padding(10)
        }
        .frame(height: 86)
        .background(NihoPalette.filmstrip)
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("背景").font(.headline).foregroundStyle(NihoPalette.heading)
                        Spacer()
                        if model.isCutoutRunning {
                            ProgressView().controlSize(.small)
                            Button("中止", action: model.cancelBackgroundRemoval)
                                .buttonStyle(.link)
                        }
                    }
                    if model.backgroundEdit == nil {
                        Button("背景を除去", systemImage: "person.crop.rectangle.badge.minus") {
                            model.startBackgroundRemoval()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canEdit)
                        Text("Apple Visionが端末内で人物・家具・商品を検出します。")
                            .font(.caption)
                            .foregroundStyle(NihoPalette.muted)
                    } else {
                        Picker("被写体", selection: Binding(
                            get: { model.selectedCutoutSubject ?? .all },
                            set: { model.selectCutoutSubject($0) }
                        )) {
                            ForEach(model.cutoutSubjects) { subject in
                                Text(cutoutSubjectLabel(subject))
                                    .tag(subject.selection)
                            }
                        }

                        Picker("背景", selection: cutoutBackgroundMode) {
                            Text("透明").tag(0)
                            Text("白").tag(1)
                            Text("色").tag(2)
                        }
                        .pickerStyle(.segmented)
                        if cutoutBackgroundMode.wrappedValue == 2 {
                            ColorPicker("背景色", selection: cutoutColor, supportsOpacity: false)
                        }

                        Picker("ブラシ", selection: $model.cutoutBrushMode) {
                            Text("消す").tag(CutoutBrushMode.erase)
                            Text("戻す").tag(CutoutBrushMode.restore)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("サイズ").font(.caption)
                            Slider(value: $model.cutoutBrushRadius, in: 0.003...0.12)
                            Text(String(format: "%.0f", model.cutoutBrushRadius * 1000))
                                .font(.caption.monospacedDigit())
                                .frame(width: 30, alignment: .trailing)
                        }
                        Text("プレビュー上をドラッグしてマスクを補正します。")
                            .font(.caption)
                            .foregroundStyle(NihoPalette.muted)
                        HStack {
                            Button("再検出", action: model.startBackgroundRemoval)
                            Button("背景編集を解除", role: .destructive, action: model.removeBackgroundEdit)
                        }
                        .buttonStyle(.link)
                    }
                    if let error = model.cutoutMaskErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(NihoPalette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                NihoDivider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("プリセットライブラリ").font(.headline).foregroundStyle(NihoPalette.heading)
                        Spacer()
                        Text("\(model.presetLibrary.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(NihoPalette.muted)
                    }
                    if let error = model.presetLibraryErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(NihoPalette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.presetLibrary.isEmpty {
                        Text("XMPを読み込むとここに登録されます。")
                            .font(.caption)
                            .foregroundStyle(NihoPalette.muted)
                    }
                    ForEach(model.presetLibrary) { item in
                        HStack(spacing: 6) {
                            Button {
                                model.applyPreset(id: item.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.presetDisplayName(for: item)).lineLimit(1)
                                    Text(item.isBuiltIn ? "標準" : "ユーザー登録")
                                        .font(.caption2)
                                        .foregroundStyle(NihoPalette.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.canEdit)
                            if model.editSnapshot.appliedPresetID == item.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(NihoPalette.green)
                                    .help("この写真へ適用中")
                            }
                            Button {
                                presetPendingDeletion = item
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("プリセットを削除")
                        }
                        .padding(.vertical, 2)
                    }
                }

                NihoDivider()

                HStack {
                    Text("編集").font(.headline).foregroundStyle(NihoPalette.heading)
                    Spacer()
                    Button("戻る", systemImage: "arrow.uturn.backward", action: model.undo)
                        .labelStyle(.iconOnly)
                        .help("編集を戻す (⌘Z)")
                        .disabled(!model.canUndo || !model.canEdit)
                    Button("やり直す", systemImage: "arrow.uturn.forward", action: model.redo)
                        .labelStyle(.iconOnly)
                        .help("編集をやり直す (⇧⌘Z)")
                        .disabled(!model.canRedo || !model.canEdit)
                    Button("全てリセット", action: model.resetAdjustments)
                        .buttonStyle(.link)
                        .disabled(!model.canEdit)
                }
                .disabled(!model.canEdit)

                Group {
                    DisclosureGroup(isExpanded: $isBasicSectionExpanded) {
                        VStack(alignment: .leading, spacing: 14) {
                            WhiteBalanceSection()
                            NihoDivider()
                            AdjustmentSliderView(label: "露光量", keyPath: \.exposure, range: -5...5, format: "%.2f")
                            AdjustmentSliderView(label: "コントラスト", keyPath: \.contrast, range: -100...100, format: "%.0f")
                            AdjustmentSliderView(label: "ハイライト", keyPath: \.highlights, range: -100...100, format: "%.0f")
                            AdjustmentSliderView(label: "シャドウ", keyPath: \.shadows, range: -100...100, format: "%.0f")
                            AdjustmentSliderView(label: "白レベル", keyPath: \.whites, range: -100...100, format: "%.0f")
                            AdjustmentSliderView(label: "黒レベル", keyPath: \.blacks, range: -100...100, format: "%.0f")
                            NihoDivider()
                            AdjustmentSliderView(label: "テクスチャ", keyPath: \.texture, range: -100...100, format: "%.0f")
                            AdjustmentSliderView(label: "明瞭度", keyPath: \.clarity, range: -100...100, format: "%.0f")
                            AdjustmentSliderView(label: "かすみの除去", keyPath: \.dehaze, range: -100...100, format: "%.0f")
                            NihoDivider()
                            AdjustmentSliderView(label: "自然な彩度", keyPath: \.vibrance, range: -100...100, format: "%.0f")
                            AdjustmentSliderView(label: "彩度", keyPath: \.saturation, range: -100...100, format: "%.0f")
                        }
                        .padding(.top, 8)
                    } label: {
                        SectionHeader(title: "基本補正") {
                            model.resetSection(.basic)
                            model.resetSection(.detail)
                        }
                    }

                    NihoDivider()

                    DisclosureGroup {
                        ToneCurveSection()
                            .padding(.top, 8)
                    } label: {
                        SectionHeader(title: "トーンカーブ") { model.resetSection(.toneCurve) }
                    }

                    NihoDivider()

                    DisclosureGroup {
                        HSLSection()
                            .padding(.top, 8)
                    } label: {
                        SectionHeader(title: "HSL") { model.resetSection(.hsl) }
                    }

                    NihoDivider()

                    DisclosureGroup {
                        ColorGradingSection()
                            .padding(.top, 8)
                    } label: {
                        SectionHeader(title: "カラーグレーディング") { model.resetSection(.colorGrading) }
                    }

                    NihoDivider()

                    DisclosureGroup {
                        CalibrationSection()
                            .padding(.top, 8)
                    } label: {
                        SectionHeader(title: "キャリブレーション") { model.resetSection(.calibration) }
                    }
                }
                .disabled(!model.canEdit)

                if let preset = model.preset {
                    NihoDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("適用中のプリセット").font(.headline).foregroundStyle(NihoPalette.heading)
                        Text(model.appliedPresetDisplayName ?? preset.name)
                            .font(.subheadline.weight(.semibold))
                        Text("Process \(preset.processVersion ?? "不明") / Camera Raw \(preset.cameraRawVersion ?? "不明")")
                            .font(.caption)
                            .foregroundStyle(NihoPalette.muted)
                        let supported = preset.compatibility.filter { $0.level == .supported }.count
                        let approximate = preset.compatibility.filter { $0.level == .approximate }.count
                        let unsupported = preset.compatibility.filter { $0.level == .unsupported }.count
                        Text("対応 \(supported) ・ 近似 \(approximate) ・ 未対応 \(unsupported)")
                            .font(.caption)
                            .foregroundStyle(NihoPalette.muted)
                        DisclosureGroup("互換性の詳細") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(preset.compatibility.filter { $0.level != .metadata }) { item in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(item.level.rawValue)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(color(for: item.level))
                                            .frame(width: 36, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.property).font(.caption)
                                            Text("\(item.value) — \(item.note)")
                                                .font(.caption2)
                                                .foregroundStyle(NihoPalette.muted)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                }

                DisclosureGroup("写真情報") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let info = model.decodeInfo {
                            LabeledContent("デコード", value: info.backend)
                            LabeledContent("解像度", value: "\(info.width) × \(info.height)")
                            if let cameraModel = info.cameraModel {
                                LabeledContent("カメラ", value: cameraModel)
                            }
                            if info.isRAW {
                                LabeledContent("現像", value: info.backend.hasPrefix("LibRaw")
                                    ? "Adobe Standard + Adobe Color（LibRaw）"
                                    : "Core Image（プロファイル未検出）")
                            }
                            if let calibrationLabel = info.calibrationLabel, info.isRAW {
                                LabeledContent("RAW基準", value: calibrationLabel)
                            }
                            if let lensCorrection = info.lensCorrection {
                                LabeledContent("レンズ補正", value: lensCorrection)
                            }
                            LabeledContent("読込", value: String(format: "%.0f ms", info.durationMilliseconds))
                        }
                        if let render = model.renderMilliseconds {
                            LabeledContent(
                                model.previewRoute == .metalDirect ? "入力→実表示" : "プレビュー生成",
                                value: String(format: "%.0f ms", render)
                            )
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(14)
        }
        .frame(width: 340)
    }

    private func cutoutSubjectLabel(_ subject: CutoutSubject) -> String {
        switch subject.selection {
        case let .instance(id): "被写体 \(id)"
        case .all: "すべての被写体"
        }
    }

    private var cutoutBackgroundMode: Binding<Int> {
        Binding(
            get: {
                guard let background = model.backgroundEdit?.background else { return 0 }
                switch background {
                case .transparent: return 0
                case let .color(color): return color == .white ? 1 : 2
                }
            },
            set: { mode in
                switch mode {
                case 0: model.setCutoutBackground(.transparent)
                case 1: model.setCutoutBackground(.color(.white))
                default:
                    if case let .color(color)? = model.backgroundEdit?.background,
                       color != .white {
                        model.setCutoutBackground(.color(color))
                    } else {
                        model.setCutoutBackground(.color(CutoutRGBA(red: 0.2, green: 0.45, blue: 0.85)))
                    }
                }
            }
        )
    }

    private var cutoutColor: Binding<Color> {
        Binding(
            get: {
                guard case let .color(value)? = model.backgroundEdit?.background else { return .white }
                return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: 1)
            },
            set: { value in
                let nsColor = NSColor(value).usingColorSpace(.sRGB) ?? .white
                model.setCutoutBackground(.color(CutoutRGBA(
                    red: Double(nsColor.redComponent),
                    green: Double(nsColor.greenComponent),
                    blue: Double(nsColor.blueComponent)
                )))
            }
        )
    }

    private var statusBar: some View {
        HStack {
            if model.isBusy { ProgressView().controlSize(.small) }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(NihoPalette.muted)
                .lineLimit(1)
            Spacer()
            Text(model.unsavedStatusMessage ?? model.persistenceMessage)
                .font(.caption2)
                .foregroundStyle(model.hasSaveFailures || model.persistenceStatus.isFailure ? NihoPalette.danger : NihoPalette.muted)
                .lineLimit(2)
                .frame(maxWidth: 340, alignment: .leading)
                .help(model.unsavedStatusMessage ?? model.persistenceMessage)
            if model.canRetrySave {
                Button(model.hasSaveFailures ? "再試行" : "今すぐ保存", action: model.retryAllUnsavedEdits)
                    .buttonStyle(.link)
            }
            if model.canRetryLoad {
                Button("編集を再読込", action: model.retryLoadCurrentPhotoEdits)
                    .buttonStyle(.link)
            }
            Text("原本は上書きしません")
                .font(.caption2)
                .foregroundStyle(NihoPalette.muted)
            Text("・プレビュー/書き出し: sRGB")
                .font(.caption2)
                .foregroundStyle(NihoPalette.muted)
            if model.previewRoute == .metalDirect {
                Text("・present \(model.directPresentedCount) / coalesce \(model.directCoalescedCount) / drawable nil \(model.directDrawableUnavailableCount) / drop \(model.directDroppedCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(NihoPalette.muted)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
    }

    private func color(for level: CompatibilityLevel) -> Color {
        switch level {
        case .supported: NihoPalette.green
        case .approximate: NihoPalette.caution
        case .unsupported: NihoPalette.danger
        case .metadata: NihoPalette.muted
        }
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 14
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.82)))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var column = 0
                while x < size.width {
                    if (row + column).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: tile, height: tile)),
                            with: .color(Color(white: 0.64))
                        )
                    }
                    x += tile
                    column += 1
                }
                y += tile
                row += 1
            }
        }
    }
}

/// Opt-in presentation surface used while the direct route is under formal
/// acceptance. It is event-driven, keeps at most one GPU frame in flight and
/// one pending frame, and never waits for the GPU on the main thread.
private struct DirectMetalPreviewView: NSViewRepresentable {
    let request: DirectPreviewRequest
    let onPresented: (UInt64, CFTimeInterval) -> Void
    let onCoalesced: (UInt64) -> Void
    let onDrawableUnavailable: (UInt64) -> Void
    let onDropped: (UInt64) -> Void
    let onFailure: (UInt64, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPresented: onPresented,
            onCoalesced: onCoalesced,
            onDrawableUnavailable: onDrawableUnavailable,
            onDropped: onDropped,
            onFailure: onFailure
        )
    }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.updateCallbacks(
            onPresented: onPresented,
            onCoalesced: onCoalesced,
            onDrawableUnavailable: onDrawableUnavailable,
            onDropped: onDropped,
            onFailure: onFailure
        )
        context.coordinator.submit(request, to: view)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private static let presentationLog = OSLog(
            subsystem: "life.niho.photobench",
            category: "presentation"
        )
        private let renderer: MetalPreviewRenderer?
        private var latestRequest: DirectPreviewRequest?
        private var pendingRequest: DirectPreviewRequest?
        private var inFlightRequest: DirectPreviewRequest?
        private var inFlightCompletion: SubmissionCompletion?
        private var queueState = LatestPreviewQueueState()
        private var lastReportedPresentedID: UInt64 = 0
        private var deliveryWatchdogTask: Task<Void, Never>?
        private var deliveryWatchdogID: UInt64?
        private var redrawRetryTask: Task<Void, Never>?
        private var retryStep = 0
        private var retryRequestID: UInt64?
        private var failingRequestID: UInt64?
        private weak var view: MTKView?
        private weak var observedWindow: NSWindow?

        private var onPresented: (UInt64, CFTimeInterval) -> Void
        private var onCoalesced: (UInt64) -> Void
        private var onDrawableUnavailable: (UInt64) -> Void
        private var onDropped: (UInt64) -> Void
        private var onFailure: (UInt64, String) -> Void

        private static let retryDelays: [Duration] = [
            .milliseconds(16),
            .milliseconds(33),
            .milliseconds(67),
            .milliseconds(133)
        ]
        private static let visibleDeliveryDeadline: Duration = .seconds(10)

        init(
            onPresented: @escaping (UInt64, CFTimeInterval) -> Void,
            onCoalesced: @escaping (UInt64) -> Void,
            onDrawableUnavailable: @escaping (UInt64) -> Void,
            onDropped: @escaping (UInt64) -> Void,
            onFailure: @escaping (UInt64, String) -> Void
        ) {
            renderer = MetalPreviewRenderer()
            self.onPresented = onPresented
            self.onCoalesced = onCoalesced
            self.onDrawableUnavailable = onDrawableUnavailable
            self.onDropped = onDropped
            self.onFailure = onFailure
        }

        func makeView() -> MTKView {
            let metalView = DirectPreviewMTKView(frame: .zero, device: renderer?.device)
            view = metalView
            metalView.didMoveToWindowHandler = { [weak self, weak metalView] in
                guard let self, let metalView else { return }
                self.observeWindowIfNeeded(for: metalView)
                self.resumePendingIfVisible(in: metalView)
            }
            metalView.delegate = self
            metalView.framebufferOnly = false
            metalView.colorPixelFormat = MetalPreviewRenderer.pixelFormat
            metalView.colorspace = MetalPreviewRenderer.outputColorSpace
            metalView.sampleCount = 1
            metalView.clearColor = MTLClearColorMake(
                NihoPalette.photoStageRGB.red,
                NihoPalette.photoStageRGB.green,
                NihoPalette.photoStageRGB.blue,
                1
            )
            metalView.isPaused = true
            metalView.enableSetNeedsDisplay = true
            metalView.autoResizeDrawable = true
            metalView.layer?.isOpaque = true
            if let metalLayer = metalView.layer as? CAMetalLayer {
                metalLayer.wantsExtendedDynamicRangeContent = false
                metalLayer.allowsNextDrawableTimeout = true
            }
            return metalView
        }

        func updateCallbacks(
            onPresented: @escaping (UInt64, CFTimeInterval) -> Void,
            onCoalesced: @escaping (UInt64) -> Void,
            onDrawableUnavailable: @escaping (UInt64) -> Void,
            onDropped: @escaping (UInt64) -> Void,
            onFailure: @escaping (UInt64, String) -> Void
        ) {
            self.onPresented = onPresented
            self.onCoalesced = onCoalesced
            self.onDrawableUnavailable = onDrawableUnavailable
            self.onDropped = onDropped
            self.onFailure = onFailure
        }

        func submit(_ request: DirectPreviewRequest, to view: MTKView) {
            if let latestID = queueState.latestID, request.id <= latestID { return }
            cancelRedrawRetry()
            cancelDeliveryWatchdog()
            retryRequestID = request.id
            retryStep = 0
            failingRequestID = nil
            latestRequest = request
            if let supersededID = queueState.submit(request.id) {
                onCoalesced(supersededID)
            }
            pendingRequest = request
            guard renderer != nil else {
                failRoute(
                    request: request,
                    message: MetalPreviewRendererError.commandQueueUnavailable.localizedDescription
                )
                return
            }
            observeWindowIfNeeded(for: view)
            resumePendingIfVisible(in: view)
        }

        func draw(in view: MTKView) {
            autoreleasepool {
                observeWindowIfNeeded(for: view)
                guard queueState.inFlightID == nil,
                      let request = pendingRequest,
                      let renderer
                else { return }
                os_signpost(
                    .event,
                    log: Self.presentationLog,
                    name: "PreviewDrawStarted",
                    "request=%{public}llu visible=%{public}d width=%{public}.0f height=%{public}.0f",
                    request.id,
                    isVisible(view) ? 1 : 0,
                    view.drawableSize.width,
                    view.drawableSize.height
                )
                guard isVisible(view) else {
                    suspendDeliveryWhileHidden()
                    return
                }
                guard view.drawableSize.width > 0, view.drawableSize.height > 0 else {
                    return
                }
                armDeliveryWatchdog(for: request, in: view)
                guard let drawable = view.currentDrawable else {
                    // Drawable pool pressure is recoverable. The on-demand
                    // invalidation has already been consumed, so explicitly
                    // schedule one bounded retry while the window is visible.
                    onDrawableUnavailable(request.id)
                    scheduleRedrawRetry(for: request, in: view)
                    return
                }

                do {
                    let commandBuffer = try renderer.makeCommandBuffer()
                    guard queueState.beginPending(request.id) else { return }
                    pendingRequest = nil
                    inFlightRequest = request
                    _ = try renderer.encodeAspectFit(
                        frame: request.frame,
                        to: drawable.texture,
                        commandBuffer: commandBuffer
                    )
                    let completion = SubmissionCompletion()
                    inFlightCompletion = completion
                    drawable.addPresentedHandler { [weak self] presentedDrawable in
                        guard completion.claim() else { return }
                        let presentedTime = presentedDrawable.presentedTime
                        Task { @MainActor [weak self] in
                            self?.finishPresented(
                                request: request,
                                presentedTime: presentedTime
                            )
                        }
                    }
                    commandBuffer.addCompletedHandler { [weak self] completed in
                        let statusRawValue = Int(completed.status.rawValue)
                        let message = completed.error?.localizedDescription
                        Task { @MainActor [weak self] in
                            self?.commandBufferCompleted(
                                request: request,
                                statusRawValue: statusRawValue,
                                message: message,
                                completion: completion
                            )
                        }
                    }
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                } catch {
                    _ = queueState.finish(request.id)
                    inFlightRequest = nil
                    inFlightCompletion = nil
                    if latestRequest?.id == request.id {
                        failRoute(request: request, message: error.localizedDescription)
                    } else {
                        resumePendingIfVisible(in: view)
                    }
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            guard size.width > 0, size.height > 0,
                  let latestRequest
            else { return }
            // A resize needs a fresh aspect-fit render even when the image
            // revision did not change. A newer pending edit still wins.
            if pendingRequest == nil
                || (pendingRequest?.id ?? 0) <= latestRequest.id {
                queueState.resubmitLatest()
                pendingRequest = latestRequest
            }
            resumePendingIfVisible(in: view)
        }

        func tearDown() {
            cancelRedrawRetry()
            cancelDeliveryWatchdog()
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
            (view as? DirectPreviewMTKView)?.didMoveToWindowHandler = nil
            pendingRequest = nil
            latestRequest = nil
            _ = inFlightCompletion?.claim()
            inFlightCompletion = nil
            inFlightRequest = nil
            queueState = LatestPreviewQueueState()
            renderer?.clearCaches()
        }

        private func finishPresented(
            request: DirectPreviewRequest,
            presentedTime: CFTimeInterval
        ) {
            guard inFlightRequest?.id == request.id,
                  queueState.finish(request.id)
            else { return }
            inFlightCompletion = nil
            inFlightRequest = nil
            if presentedTime > 0 {
                if latestRequest?.id == request.id {
                    cancelRedrawRetry()
                    cancelDeliveryWatchdog()
                    retryRequestID = nil
                    retryStep = 0
                }
                if latestRequest?.id == request.id,
                   request.id > lastReportedPresentedID {
                    lastReportedPresentedID = request.id
                    onPresented(request.id, presentedTime)
                }
            } else {
                onDropped(request.id)
                if latestRequest?.id == request.id {
                    queueState.resubmitLatest()
                    pendingRequest = request
                    if let view, isVisible(view) {
                        scheduleRedrawRetry(for: request, in: view)
                    } else {
                        suspendDeliveryWhileHidden()
                    }
                }
            }
            if pendingRequest != nil, let view, redrawRetryTask == nil {
                resumePendingIfVisible(in: view)
            }
        }

        private func finishFailed(
            request: DirectPreviewRequest,
            message: String
        ) {
            guard inFlightRequest?.id == request.id,
                  queueState.finish(request.id)
            else { return }
            inFlightCompletion = nil
            inFlightRequest = nil
            if latestRequest?.id == request.id {
                failRoute(request: request, message: message)
            } else if pendingRequest != nil, let view {
                resumePendingIfVisible(in: view)
            }
        }

        private func observeWindowIfNeeded(for view: MTKView) {
            guard observedWindow !== view.window else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didDeminiaturizeNotification,
                object: observedWindow
            )
            observedWindow = view.window
            guard let observedWindow else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityChanged(_:)),
                name: NSWindow.didDeminiaturizeNotification,
                object: observedWindow
            )
        }

        private func commandBufferCompleted(
            request: DirectPreviewRequest,
            statusRawValue: Int,
            message: String?,
            completion: SubmissionCompletion
        ) {
            os_signpost(
                .event,
                log: Self.presentationLog,
                name: "PreviewGPUCompleted",
                "request=%{public}llu status=%{public}d",
                request.id,
                statusRawValue
            )
            guard statusRawValue == Int(MTLCommandBufferStatus.error.rawValue),
                  completion.claim()
            else { return }
            finishFailed(
                request: request,
                message: message ?? "Metal command buffer error"
            )
        }

        @objc private func windowVisibilityChanged(_ notification: Notification) {
            guard let view else { return }
            if isVisible(view) {
                resumePendingIfVisible(in: view)
            } else {
                suspendDeliveryWhileHidden()
            }
        }

        private func isVisible(_ view: MTKView) -> Bool {
            guard let window = view.window,
                  !window.isMiniaturized,
                  window.occlusionState.contains(.visible),
                  !view.isHiddenOrHasHiddenAncestor
            else { return false }
            return true
        }

        private func resumePendingIfVisible(in view: MTKView) {
            guard isVisible(view) else {
                suspendDeliveryWhileHidden()
                return
            }
            if let latestRequest {
                armDeliveryWatchdog(for: latestRequest, in: view)
            }
            if queueState.inFlightID == nil, pendingRequest != nil {
                if let requestID = pendingRequest?.id {
                    os_signpost(
                        .event,
                        log: Self.presentationLog,
                        name: "PreviewDrawRequested",
                        "request=%{public}llu",
                        requestID
                    )
                }
                view.setNeedsDisplay(view.bounds)
            }
        }

        private func suspendDeliveryWhileHidden() {
            cancelRedrawRetry()
            cancelDeliveryWatchdog()
        }

        private func scheduleRedrawRetry(
            for request: DirectPreviewRequest,
            in view: MTKView
        ) {
            guard redrawRetryTask == nil,
                  latestRequest?.id == request.id
            else { return }
            if retryRequestID != request.id {
                retryRequestID = request.id
                retryStep = 0
            }
            let delay = Self.retryDelays[min(retryStep, Self.retryDelays.count - 1)]
            retryStep += 1
            redrawRetryTask = Task { @MainActor [weak self, weak view] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self else { return }
                self.redrawRetryTask = nil
                guard let view,
                      self.latestRequest?.id == request.id,
                      self.queueState.inFlightID == nil,
                      self.pendingRequest != nil
                else { return }
                self.resumePendingIfVisible(in: view)
            }
        }

        private func armDeliveryWatchdog(
            for request: DirectPreviewRequest,
            in view: MTKView
        ) {
            guard latestRequest?.id == request.id,
                  deliveryWatchdogID != request.id,
                  isVisible(view),
                  view.drawableSize.width > 0,
                  view.drawableSize.height > 0
            else { return }
            cancelDeliveryWatchdog()
            deliveryWatchdogID = request.id
            deliveryWatchdogTask = Task { @MainActor [weak self, weak view] in
                do {
                    try await Task.sleep(for: Self.visibleDeliveryDeadline)
                } catch {
                    return
                }
                guard let self else { return }
                self.deliveryWatchdogTask = nil
                self.deliveryWatchdogID = nil
                guard let view,
                      self.latestRequest?.id == request.id
                else { return }
                guard self.isVisible(view) else {
                    self.suspendDeliveryWhileHidden()
                    return
                }
                // A presented/error callback may already have claimed the
                // submission while its MainActor completion is still queued.
                // The watchdog must not race that terminal callback into a
                // false fallback.
                if self.inFlightRequest?.id == request.id,
                   let completion = self.inFlightCompletion,
                   !completion.claim() {
                    return
                }
                self.failRoute(
                    request: request,
                    message: "可視状態のMetal drawableを10秒以内に実表示できませんでした。"
                )
            }
        }

        private func cancelRedrawRetry() {
            redrawRetryTask?.cancel()
            redrawRetryTask = nil
        }

        private func cancelDeliveryWatchdog() {
            deliveryWatchdogTask?.cancel()
            deliveryWatchdogTask = nil
            deliveryWatchdogID = nil
        }

        private func failRoute(request: DirectPreviewRequest, message: String) {
            guard latestRequest?.id == request.id,
                  failingRequestID != request.id
            else { return }
            failingRequestID = request.id
            cancelRedrawRetry()
            cancelDeliveryWatchdog()
            pendingRequest = nil
            _ = inFlightCompletion?.claim()
            inFlightCompletion = nil
            inFlightRequest = nil
            latestRequest = nil
            queueState = LatestPreviewQueueState()
            onFailure(request.id, message)
        }
    }
}

@MainActor
private final class DirectPreviewMTKView: MTKView {
    var didMoveToWindowHandler: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        didMoveToWindowHandler?()
    }
}

private final class SubmissionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
