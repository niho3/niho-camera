import PhotoCore
import SwiftUI

/// The Lightroom-equivalent inspector panels that `ContentView.inspectorPane`
/// assembles inside per-section `DisclosureGroup`s. Split out of
/// `ContentView.swift` because the full Basic/Tone Curve/HSL/Color Grading/
/// Calibration panel set is large; every view here reads/writes through
/// `EditorModel.updateSettings`/`updateSetting(_:at:)` so undo, autosave and
/// preview re-render all keep working exactly as they do for the model's
/// other mutators.

// MARK: - Shared building blocks

/// A section header with a title and a small trailing reset button, used as
/// the `label` of each panel's `DisclosureGroup`.
struct SectionHeader: View {
    let title: String
    let onReset: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(NihoPalette.heading)
            Spacer()
            Button("リセット", action: onReset)
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

/// The same slider row `ContentView` already used for its flat "一発調整"
/// section (label, live value, `Slider`, optional guidance caption), pulled
/// out so every new panel can share it instead of re-declaring the same
/// binding/formatting boilerplate.
struct AdjustmentSliderView: View {
    @EnvironmentObject private var model: EditorModel
    let label: String
    let keyPath: WritableKeyPath<EditSettings, Double>
    let range: ClosedRange<Double>
    let format: String
    var guidance: String?

    var body: some View {
        let value = Binding<Double>(
            get: { model.settings[keyPath: keyPath] },
            set: { model.updateSetting($0, at: keyPath) }
        )
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(NihoPalette.muted)
                    .frame(width: 48, alignment: .trailing)
            }
            // LR's sliders move in whole units (0.01 for exposure); snapping
            // here keeps stored values on that grid, so "0" is reachable by
            // dragging and `EditSettings.neutral` equality holds after a
            // round trip.
            Slider(value: value, in: range, step: format == "%.0f" ? 1 : 0.01, onEditingChanged: { editing in
                model.sliderEditingChanged(editing)
            })
            if let guidance {
                Text(guidance)
                    .font(.caption2)
                    .foregroundStyle(NihoPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

// MARK: - White Balance (Basic panel)

/// RAW absolute white balance (temperature/tint derived from the decoder's
/// as-shot chromaticity, phase2 C1) plus the pre-existing relative
/// temperature/tint fine-tune, folded away underneath.
struct WhiteBalanceSection: View {
    @EnvironmentObject private var model: EditorModel

    private static let temperatureRange: ClosedRange<Double> = 2_000...50_000

    private var showsAbsoluteControls: Bool {
        model.decodeInfo?.isRAW == true && model.decodeInfo?.asShotWhiteXY != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ホワイトバランス").font(.subheadline.weight(.semibold))
                Spacer()
                if showsAbsoluteControls {
                    Text(modeLabel).font(.caption2).foregroundStyle(NihoPalette.muted)
                }
            }
            if showsAbsoluteControls {
                absoluteControls
            } else if model.decodeInfo?.isRAW == true {
                Text("この写真は撮影時ホワイトバランスを取得できませんでした。下の相対調整のみ使用できます。")
                    .font(.caption2)
                    .foregroundStyle(NihoPalette.muted)
            } else if model.decodeInfo != nil {
                Text("非RAW画像は絶対ホワイトバランスに未対応です。下の相対調整のみ使用できます。")
                    .font(.caption2)
                    .foregroundStyle(NihoPalette.muted)
            }
            DisclosureGroup("微調整（撮影時基準の相対）") {
                VStack(alignment: .leading, spacing: 12) {
                    AdjustmentSliderView(
                        label: "色温度",
                        keyPath: \.relativeTemperature,
                        range: -100...100,
                        format: "%.0f",
                        guidance: "寒色 ←→ 暖色"
                    )
                    AdjustmentSliderView(
                        label: "色かぶり",
                        keyPath: \.relativeTint,
                        range: -100...100,
                        format: "%.0f",
                        guidance: "緑 ←→ マゼンタ"
                    )
                }
                .padding(.top, 8)
            }
        }
    }

    private var modeLabel: String {
        model.settings.whiteBalance.mode == .custom ? "カスタム" : "撮影時のまま"
    }

    /// `.custom` reads its own stored temperature/tint; `.asShot`/`.unknown`
    /// derive both from the decoder's as-shot chromaticity via
    /// `ColorSpec.temperatureAndTint(fromXY:)` (§4 of the UI brief) so the
    /// sliders show where the camera actually landed, not an arbitrary
    /// default, before the user ever touches them.
    private var currentTemperatureAndTint: (temperature: Double, tint: Double) {
        switch model.settings.whiteBalance.mode {
        case .custom:
            return (
                model.settings.whiteBalance.temperature ?? 5_500,
                model.settings.whiteBalance.tint ?? 0
            )
        case .asShot, .unknown:
            guard let xy = model.decodeInfo?.asShotWhiteXY else { return (5_500, 0) }
            return ColorSpec.temperatureAndTint(fromXY: xy)
        }
    }

    /// LR's own Temperature slider is logarithmic in Kelvin; the slider's
    /// backing value is `log(K)` over `log(2000)...log(50000)` while the
    /// displayed number stays plain integer Kelvin.
    private var temperatureLogBinding: Binding<Double> {
        Binding(
            get: {
                let clamped = min(max(currentTemperatureAndTint.temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound)
                return log(clamped)
            },
            set: { newLog in
                let temperature = min(max(exp(newLog), Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound).rounded()
                let tint = currentTemperatureAndTint.tint
                model.updateSettings { settings in
                    settings.whiteBalance = WhiteBalanceSettings(mode: .custom, temperature: temperature, tint: tint)
                }
            }
        )
    }

    private var tintBinding: Binding<Double> {
        Binding(
            get: { currentTemperatureAndTint.tint },
            set: { newTint in
                let temperature = currentTemperatureAndTint.temperature
                model.updateSettings { settings in
                    settings.whiteBalance = WhiteBalanceSettings(mode: .custom, temperature: temperature, tint: newTint.rounded())
                }
            }
        )
    }

    private var logRange: ClosedRange<Double> {
        log(Self.temperatureRange.lowerBound)...log(Self.temperatureRange.upperBound)
    }

    private var absoluteControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                HStack {
                    Text("色温度").font(.caption)
                    Spacer()
                    Text("\(Int(currentTemperatureAndTint.temperature.rounded())) K")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(NihoPalette.muted)
                }
                Slider(value: temperatureLogBinding, in: logRange, onEditingChanged: { model.sliderEditingChanged($0) })
            }
            VStack(spacing: 4) {
                HStack {
                    Text("色かぶり補正").font(.caption)
                    Spacer()
                    Text("\(Int(currentTemperatureAndTint.tint.rounded()))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(NihoPalette.muted)
                }
                Slider(value: tintBinding, in: -150...150, step: 1, onEditingChanged: { model.sliderEditingChanged($0) })
            }
            HStack {
                Spacer()
                Button("撮影時") {
                    model.updateSettings { $0.whiteBalance = .asShot }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(model.settings.whiteBalance.mode != .custom)
            }
        }
    }
}

// MARK: - Tone Curve

/// Parametric region sliders + split points, plus the point-curve `Canvas`
/// editor with a channel switcher.
struct ToneCurveSection: View {
    @EnvironmentObject private var model: EditorModel
    @State private var selectedChannel: ToneCurveChannel = .rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                AdjustmentSliderView(label: "ハイライト", keyPath: \.parametricHighlights, range: -100...100, format: "%.0f")
                AdjustmentSliderView(label: "明るい部分", keyPath: \.parametricLights, range: -100...100, format: "%.0f")
                AdjustmentSliderView(label: "暗い部分", keyPath: \.parametricDarks, range: -100...100, format: "%.0f")
                AdjustmentSliderView(label: "シャドウ", keyPath: \.parametricShadows, range: -100...100, format: "%.0f")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("分割点").font(.caption).foregroundStyle(NihoPalette.muted)
                splitSlider(
                    "シャドウ分割", keyPath: \.parametricShadowSplit,
                    lowerSibling: nil, upperSibling: \.parametricMidtoneSplit
                )
                splitSlider(
                    "中間域分割", keyPath: \.parametricMidtoneSplit,
                    lowerSibling: \.parametricShadowSplit, upperSibling: \.parametricHighlightSplit
                )
                splitSlider(
                    "ハイライト分割", keyPath: \.parametricHighlightSplit,
                    lowerSibling: \.parametricMidtoneSplit, upperSibling: nil
                )
            }

            NihoDivider()

            Picker("チャンネル", selection: $selectedChannel) {
                Text("RGB").tag(ToneCurveChannel.rgb)
                Text("レッド").tag(ToneCurveChannel.red)
                Text("グリーン").tag(ToneCurveChannel.green)
                Text("ブルー").tag(ToneCurveChannel.blue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Spacer()
                PointCurveEditor(channel: selectedChannel)
                Spacer()
            }
            Text("空き位置をクリックで点を追加、ドラッグで移動、枠の外へドラッグして離すと削除できます。")
                .font(.caption2)
                .foregroundStyle(NihoPalette.muted)

            HStack {
                Spacer()
                Button("カーブをリセット") {
                    model.updateSettings { settings in
                        settings.toneCurves.removeAll { $0.channel == selectedChannel }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    /// A 0...100 slider whose value is clamped to stay strictly between its
    /// two sibling split points (or a fixed 0/100 rail when there is no
    /// sibling on that side), matching LR's own shadow < midtone < highlight
    /// split-point constraint.
    private func splitSlider(
        _ label: String,
        keyPath: WritableKeyPath<EditSettings, Double>,
        lowerSibling: WritableKeyPath<EditSettings, Double>?,
        upperSibling: WritableKeyPath<EditSettings, Double>?
    ) -> some View {
        let value = Binding<Double>(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                model.updateSettings { settings in
                    let lower = (lowerSibling.map { settings[keyPath: $0] } ?? 0) + 1
                    let upperRaw = (upperSibling.map { settings[keyPath: $0] } ?? 100) - 1
                    let upper = max(upperRaw, lower)
                    let clamped = min(max(newValue, lower), upper)
                    settings[keyPath: keyPath] = min(max(clamped, 0), 100)
                }
            }
        )
        return VStack(spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(NihoPalette.muted)
            }
            Slider(value: value, in: 0...100, step: 1, onEditingChanged: { model.sliderEditingChanged($0) })
        }
    }
}

/// A square point-curve editor. Points are stored/edited in the same 0...1
/// domain `XMPPresetParser` normalizes `ToneCurvePV2012` into (see
/// `ToneCurveModel.normalizedPoints`'s doc comment); this view keeps its own
/// small sort/dedupe pass (mirroring, but not calling, that internal
/// `PhotoCore` logic) since it only needs to look right, not to reproduce
/// the renderer's exact endpoint-extrapolation math.
struct PointCurveEditor: View {
    @EnvironmentObject private var model: EditorModel
    let channel: ToneCurveChannel

    static let canvasSize: CGFloat = 260
    private static let minimumGap: Double = 0.012
    private static let hitRadius: Double = 12

    @State private var draggingIndex: Int?

    var body: some View {
        let currentPoints = points
        Canvas { context, size in
            Self.draw(context: context, size: size, points: currentPoints, channel: channel)
        }
        .frame(width: Self.canvasSize, height: Self.canvasSize)
        .background(NihoPalette.well)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(NihoPalette.line))
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    private var points: [CurvePoint] {
        let raw = model.settings.toneCurves.first { $0.channel == channel }?.points ?? []
        let sanitized = Self.sanitize(raw)
        return sanitized.count >= 2 ? sanitized : [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let index = draggingIndex {
                    movePoint(at: index, to: value.location)
                    return
                }
                model.sliderEditingChanged(true)
                let pts = points
                if let nearest = nearestIndex(to: value.startLocation, in: pts),
                   distance(from: point(for: pts[nearest]), to: value.startLocation) <= Self.hitRadius {
                    draggingIndex = nearest
                    movePoint(at: nearest, to: value.location)
                } else {
                    draggingIndex = insertPoint(at: value.startLocation)
                }
            }
            .onEnded { value in
                // `onChanged` always began an editing group (and the
                // preview's drag session), so always end it -- even when no
                // point ended up grabbed.
                defer { model.sliderEditingChanged(false) }
                guard let index = draggingIndex else { return }
                // Lightroom-style removal: dragging a control point well
                // outside the graph deletes it (endpoints stay). Done here,
                // inside the same slider-editing group, so add/move/delete
                // in one drag is still a single undo step.
                if Self.isOutsideDeleteZone(value.location) {
                    deletePoint(at: index)
                }
                draggingIndex = nil
            }
    }

    private func point(for curvePoint: CurvePoint) -> CGPoint {
        CGPoint(x: curvePoint.x * Self.canvasSize, y: (1 - curvePoint.y) * Self.canvasSize)
    }

    private func curvePoint(for location: CGPoint) -> CurvePoint {
        CurvePoint(
            x: min(max(location.x / Self.canvasSize, 0), 1),
            y: min(max(1 - location.y / Self.canvasSize, 0), 1)
        )
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func nearestIndex(to location: CGPoint, in points: [CurvePoint]) -> Int? {
        guard !points.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, candidate) in points.enumerated() {
            let d = distance(from: point(for: candidate), to: location)
            if d < bestDistance {
                bestDistance = d
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Moves the point at `index`, keeping interior points strictly between
    /// their neighbors ("xは隣の点の間にclamp") and endpoints pinned to
    /// their existing x ("端点はx固定").
    private func movePoint(at index: Int, to location: CGPoint) {
        var pts = points
        guard pts.indices.contains(index) else { return }
        let raw = curvePoint(for: location)
        let newX: Double
        if index == 0 || index == pts.count - 1 {
            newX = pts[index].x
        } else {
            let lower = pts[index - 1].x + Self.minimumGap
            let upper = pts[index + 1].x - Self.minimumGap
            newX = lower <= upper ? min(max(raw.x, lower), upper) : pts[index].x
        }
        pts[index] = CurvePoint(x: newX, y: raw.y)
        write(pts)
    }

    /// Inserts a new point at `location`'s x (clamped away from both
    /// endpoints and from its immediate neighbors), returning its index so
    /// the drag gesture can keep moving it for the rest of the gesture.
    private func insertPoint(at location: CGPoint) -> Int {
        var pts = points
        guard let first = pts.first, let last = pts.last, first.x < last.x else { return 0 }
        let raw = curvePoint(for: location)
        let clampedX = min(max(raw.x, first.x + Self.minimumGap), last.x - Self.minimumGap)
        let insertIndex = pts.firstIndex { $0.x > clampedX } ?? pts.count - 1
        let leftX = pts[insertIndex - 1].x
        let rightX = pts[insertIndex].x
        let lower = leftX + Self.minimumGap
        let upper = rightX - Self.minimumGap
        let finalX = lower <= upper ? min(max(clampedX, lower), upper) : (leftX + rightX) / 2
        pts.insert(CurvePoint(x: finalX, y: raw.y), at: insertIndex)
        write(pts)
        return insertIndex
    }

    /// How far past the canvas edge a drag has to end before it counts as
    /// "drag the point out of the graph to delete it".
    private static let deleteMargin: CGFloat = 28

    private static func isOutsideDeleteZone(_ location: CGPoint) -> Bool {
        location.x < -deleteMargin || location.y < -deleteMargin
            || location.x > canvasSize + deleteMargin || location.y > canvasSize + deleteMargin
    }

    /// Deletes the point at `index` unless it is an endpoint ("端点は不可").
    private func deletePoint(at index: Int) {
        let pts = points
        guard pts.count > 2, pts.indices.contains(index), index != 0, index != pts.count - 1 else { return }
        var updated = pts
        updated.remove(at: index)
        write(updated)
    }

    private func write(_ newPoints: [CurvePoint]) {
        model.updateSettings { settings in
            var curves = settings.toneCurves.filter { $0.channel != channel }
            let candidate = ToneCurve(channel: channel, points: newPoints)
            if !candidate.isIdentity {
                curves.append(candidate)
            }
            settings.toneCurves = curves.sorted { $0.channel.rawValue < $1.channel.rawValue }
        }
    }

    /// Clamp to 0...1, sort by x, and resolve duplicate x positions as
    /// last-authored-wins -- the same policy `ToneCurveModel.normalizedPoints`
    /// documents, kept in sync here only for the editor's own display/hit
    /// testing, not for evaluation.
    private static func sanitize(_ points: [CurvePoint]) -> [CurvePoint] {
        let clamped = points
            .filter { $0.x.isFinite && $0.y.isFinite }
            .enumerated()
            .map { index, point in
                (index: index, point: CurvePoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1)))
            }
            .sorted { $0.point.x < $1.point.x }
        var result: [(index: Int, point: CurvePoint)] = []
        for candidate in clamped {
            if let last = result.last, abs(last.point.x - candidate.point.x) < 0.000_001 {
                if candidate.index > last.index {
                    result[result.count - 1] = candidate
                }
            } else {
                result.append(candidate)
            }
        }
        return result.map(\.point)
    }

    private static func draw(context: GraphicsContext, size: CGSize, points: [CurvePoint], channel: ToneCurveChannel) {
        var grid = Path()
        for step in 1..<4 {
            let t = CGFloat(step) / 4
            grid.move(to: CGPoint(x: t * size.width, y: 0))
            grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: t * size.height))
            grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
        }
        context.stroke(grid, with: .color(NihoPalette.heading.opacity(0.08)))

        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diagonal, with: .color(NihoPalette.heading.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        let screenPoints = points.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
        let tint = curveColor(for: channel)
        if screenPoints.count >= 2 {
            var curve = Path()
            curve.move(to: screenPoints[0])
            for p in screenPoints.dropFirst() { curve.addLine(to: p) }
            context.stroke(curve, with: .color(tint), lineWidth: 2)
        }
        for p in screenPoints {
            let dot = Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
            context.fill(dot, with: .color(tint))
            context.stroke(dot, with: .color(.white), lineWidth: 1)
        }
    }

    private static func curveColor(for channel: ToneCurveChannel) -> Color {
        switch channel {
        case .rgb: NihoPalette.ink
        case .red: Color(nihoHex: 0xC0504A)
        case .green: Color(nihoHex: 0x4D8F52)
        case .blue: Color(nihoHex: 0x3F6FA8)
        }
    }
}

// MARK: - HSL

struct HSLSection: View {
    @EnvironmentObject private var model: EditorModel

    private enum Metric: String, CaseIterable, Identifiable {
        case hue = "色相"
        case saturation = "彩度"
        case luminance = "輝度"

        var id: String { rawValue }

        var keyPath: WritableKeyPath<HSLAdjustment, Double> {
            switch self {
            case .hue: \.hue
            case .saturation: \.saturation
            case .luminance: \.luminance
            }
        }
    }

    @State private var metric: Metric = .hue
    @State private var showAll = false

    private static let bandOrder: [HSLBand] = [.red, .orange, .yellow, .green, .aqua, .blue, .purple, .magenta]
    private static let bandLabels: [HSLBand: String] = [
        .red: "レッド", .orange: "オレンジ", .yellow: "イエロー", .green: "グリーン",
        .aqua: "アクア", .blue: "ブルー", .purple: "パープル", .magenta: "マゼンタ"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("表示項目", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("すべて表示", isOn: $showAll)
                .font(.caption)

            if showAll {
                ForEach(Self.bandOrder, id: \.self) { band in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.bandLabels[band] ?? band.rawValue)
                            .font(.caption.weight(.semibold))
                        ForEach(Metric.allCases) { oneMetric in
                            bandSlider(band: band, metric: oneMetric, label: oneMetric.rawValue)
                        }
                    }
                }
            } else {
                ForEach(Self.bandOrder, id: \.self) { band in
                    bandSlider(band: band, metric: metric, label: Self.bandLabels[band] ?? band.rawValue)
                }
            }
        }
    }

    private func bandSlider(band: HSLBand, metric: Metric, label: String) -> some View {
        let value = Binding<Double>(
            get: { model.settings.hsl[band]?[keyPath: metric.keyPath] ?? 0 },
            set: { newValue in
                model.updateSettings { settings in
                    var adjustment = settings.hsl[band] ?? HSLAdjustment()
                    adjustment[keyPath: metric.keyPath] = newValue
                    if adjustment.hue == 0, adjustment.saturation == 0, adjustment.luminance == 0 {
                        settings.hsl.removeValue(forKey: band)
                    } else {
                        settings.hsl[band] = adjustment
                    }
                }
            }
        )
        return VStack(spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(NihoPalette.muted)
            }
            Slider(value: value, in: -100...100, step: 1, onEditingChanged: { model.sliderEditingChanged($0) })
        }
    }
}

// MARK: - Color Grading

struct ColorGradingSection: View {
    @EnvironmentObject private var model: EditorModel

    private enum Band: String, CaseIterable, Identifiable {
        case shadow = "シャドウ"
        case midtone = "中間調"
        case highlight = "ハイライト"
        case global = "全体"

        var id: String { rawValue }

        var keyPath: WritableKeyPath<ColorGradingSettings, ColorGradeBand> {
            switch self {
            case .shadow: \.shadow
            case .midtone: \.midtone
            case .highlight: \.highlight
            case .global: \.global
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Band.allCases) { band in
                VStack(alignment: .leading, spacing: 6) {
                    Text(band.rawValue).font(.subheadline.weight(.semibold))
                    hueSlider(band: band)
                    componentSlider(band: band, label: "彩度", range: 0...100, keyPath: \.saturation)
                    componentSlider(band: band, label: "輝度", range: -100...100, keyPath: \.luminance)
                    if band == .midtone || band == .global {
                        Text("輝度は現時点で描画に反映されません（値は保持されます）。")
                            .font(.caption2)
                            .foregroundStyle(NihoPalette.muted)
                    }
                }
            }

            NihoDivider()

            blendingSlider
            balanceSlider
        }
    }

    private func hueSlider(band: Band) -> some View {
        let keyPath = band.keyPath
        let value = Binding<Double>(
            get: { model.settings.colorGrading[keyPath: keyPath].hue },
            set: { newValue in
                model.updateSettings { $0.colorGrading[keyPath: keyPath].hue = newValue }
            }
        )
        let hueWheel = LinearGradient(
            colors: stride(from: 0.0, through: 360.0, by: 30.0).map {
                Color(hue: $0 / 360, saturation: 0.75, brightness: 0.9)
            },
            startPoint: .leading, endPoint: .trailing
        )
        return VStack(spacing: 2) {
            HStack {
                Text("色相").font(.caption)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(NihoPalette.muted)
            }
            Slider(value: value, in: 0...360, step: 1, onEditingChanged: { model.sliderEditingChanged($0) })
            hueWheel
                .frame(height: 4)
                .clipShape(Capsule())
        }
    }

    private func componentSlider(
        band: Band,
        label: String,
        range: ClosedRange<Double>,
        keyPath: WritableKeyPath<ColorGradeBand, Double>
    ) -> some View {
        let bandKeyPath = band.keyPath
        let value = Binding<Double>(
            get: { model.settings.colorGrading[keyPath: bandKeyPath][keyPath: keyPath] },
            set: { newValue in
                model.updateSettings { $0.colorGrading[keyPath: bandKeyPath][keyPath: keyPath] = newValue }
            }
        )
        return VStack(spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(NihoPalette.muted)
            }
            Slider(value: value, in: range, step: 1, onEditingChanged: { model.sliderEditingChanged($0) })
        }
    }

    private var blendingSlider: some View {
        let value = Binding<Double>(
            get: { model.settings.colorGrading.blending },
            set: { newValue in model.updateSettings { $0.colorGrading.blending = newValue } }
        )
        return VStack(spacing: 2) {
            HStack {
                Text("ブレンド").font(.caption)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(NihoPalette.muted)
            }
            Slider(value: value, in: 0...100, step: 1, onEditingChanged: { model.sliderEditingChanged($0) })
        }
    }

    private var balanceSlider: some View {
        let value = Binding<Double>(
            get: { model.settings.colorGrading.balance },
            set: { newValue in model.updateSettings { $0.colorGrading.balance = newValue } }
        )
        return VStack(spacing: 2) {
            HStack {
                Text("バランス").font(.caption)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(NihoPalette.muted)
            }
            Slider(value: value, in: -100...100, step: 1, onEditingChanged: { model.sliderEditingChanged($0) })
        }
    }
}

// MARK: - Calibration

struct CalibrationSection: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            slider("シャドウ色かぶり", \.shadowTint)
            NihoDivider()
            Text("レッド").font(.caption.weight(.semibold))
            slider("色相", \.redHue)
            slider("彩度", \.redSaturation)
            Text("グリーン").font(.caption.weight(.semibold))
            slider("色相", \.greenHue)
            slider("彩度", \.greenSaturation)
            Text("ブルー").font(.caption.weight(.semibold))
            slider("色相", \.blueHue)
            slider("彩度", \.blueSaturation)
        }
    }

    private func slider(_ label: String, _ keyPath: WritableKeyPath<CalibrationSettings, Double>) -> some View {
        let value = Binding<Double>(
            get: { model.settings.calibration[keyPath: keyPath] },
            set: { newValue in model.updateSettings { $0.calibration[keyPath: keyPath] = newValue } }
        )
        return VStack(spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(NihoPalette.muted)
            }
            Slider(value: value, in: -100...100, step: 1, onEditingChanged: { model.sliderEditingChanged($0) })
        }
    }
}
