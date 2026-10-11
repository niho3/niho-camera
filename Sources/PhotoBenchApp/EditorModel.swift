import AppKit
import Foundation
import NihoCameraCutout
import PhotoBenchAppSupport
import PhotoCore
import QuartzCore
import UniformTypeIdentifiers
import os

enum PreviewPresentationRoute: String, Sendable {
    case legacyBitmap = "legacy-bitmap"
    case metalDirect = "metal-direct"

    static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        environment["PHOTO_BENCH_PREVIEW_ROUTE"] == metalDirect.rawValue
            ? .metalDirect
            : .legacyBitmap
    }
}

struct DirectPreviewRequest: Identifiable, @unchecked Sendable {
    enum Kind: Sendable {
        case initialSelection
        case edit
    }

    /// Monotonic per request (a settle render re-presents a revision that
    /// is already on screen, so the revision alone is not unique).
    let id: UInt64
    let frame: PreparedPreviewFrame
    let inputHostTime: CFTimeInterval
    let kind: Kind
    let revision: UInt64
    /// `false` for the quiet exact frame after a drag: the shown latency
    /// stays the drag frame's.
    let updatesTiming: Bool
}

/// What one preview render needs besides its revision (`PreviewRenderPump`).
private struct PreviewRenderRequest: Sendable {
    let settings: EditSettings
    let background: BackgroundRenderCapture?
    /// Non-nil: a drag frame (`PreviewDragSession`).
    let drag: PreviewDragSession?
    let inputHostTime: CFTimeInterval

    init(
        settings: EditSettings,
        background: BackgroundRenderCapture?,
        drag: PreviewDragSession?,
        inputHostTime: CFTimeInterval
    ) {
        self.settings = settings
        self.background = background
        self.drag = drag
        self.inputHostTime = inputHostTime
    }
}

private struct BackgroundRenderCapture: Sendable {
    let recipe: BackgroundEditRecipe
    let maskPNGData: Data
}

private typealias PreviewRenderJob = PreviewRenderPump<PreviewRenderRequest>.Job

enum EditPersistenceStatus: Equatable {
    case idle
    case saving
    case saved
    case saveFailed(String)
    case loadFailed(String)

    var message: String {
        switch self {
        case .idle: "編集状態なし"
        case .saving: "保存中…"
        case .saved: "保存済み"
        case let .saveFailed(reason): "保存失敗: \(reason)"
        case let .loadFailed(reason): "読込失敗・保存停止: \(reason)"
        }
    }

    var isFailure: Bool {
        switch self {
        case .saveFailed, .loadFailed: true
        case .idle, .saving, .saved: false
        }
    }
}

/// The inspector's Lightroom-equivalent panels, for `EditorModel.resetSection`.
/// `.basic` and `.detail` both live under the single "基本補正" disclosure
/// header (see that method's doc comment); the rest map 1:1 to their own
/// header.
enum EditSection {
    case basic
    case toneCurve
    case hsl
    case colorGrading
    case calibration
    case detail
}

@MainActor
final class EditorModel: ObservableObject {
    private static let presentationLog = OSLog(
        subsystem: "life.niho.photobench",
        category: "presentation"
    )

    @Published private(set) var rootURL: URL?
    @Published private(set) var assets: [PhotoAsset] = []
    @Published var selectedAssetID: String? {
        didSet {
            guard selectedAssetID != oldValue else { return }
            finishSliderGesture()
            finishBrushStroke()
            saveEditState(for: oldValue)
            flushPendingEditSave()
            restoreEditState(for: selectedAssetID)
            loadSelection()
        }
    }
    @Published private(set) var preview: NSImage?
    @Published private(set) var directPreviewRequest: DirectPreviewRequest?
    @Published private(set) var previewRoute: PreviewPresentationRoute
    @Published private(set) var decodeInfo: DecodeInfo?
    @Published private(set) var renderMilliseconds: Double?
    @Published private(set) var editSnapshot = PhotoEditSnapshot.neutral
    @Published private(set) var presetLibrary: [StoredXMPPreset] = []
    @Published private(set) var presetLibraryErrorMessage: String?
    @Published private(set) var persistenceStatus: EditPersistenceStatus = .idle
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isBusy = false
    @Published private(set) var isCutoutRunning = false
    @Published private(set) var cutoutMaskErrorMessage: String?
    @Published var cutoutBrushMode: CutoutBrushMode = .erase
    @Published var cutoutBrushRadius: Double = 0.025
    @Published private(set) var hasPreviewInFlight = false
    @Published private(set) var directPresentedCount = 0
    @Published private(set) var directCoalescedCount = 0
    @Published private(set) var directDrawableUnavailableCount = 0
    @Published private(set) var directDroppedCount = 0
    @Published private(set) var statusMessage = "写真フォルダを読み込んでいます…"

    private let decoder = PhotoDecoder()
    private let renderCoordinator = RenderCoordinator()
    private let initialDirectoryHint: URL
    private let folderAccess: FolderAccessCoordinator
    private let store: PhotoBenchStore
    private var decodedPhoto: DecodedPhoto?
    /// Preview-sized copy of `decodedPhoto` (`RenderEngine.
    /// makePreviewWorkingCopy`) that every preview render uses; `nil` falls
    /// back to rendering previews from `decodedPhoto`. Export always uses
    /// `decodedPhoto`.
    private var previewWorkingCopy: DecodedPhoto?
    private var assetsByID: [String: PhotoAsset] = [:]
    private var scanTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var saveDebounceTask: Task<Void, Never>?
    private var cutoutTask: Task<Void, Never>?
    private var cutoutJobToken: UUID?
    private var loadGeneration = 0
    private var renderRevision: UInt64 = 0
    /// Live while a slider, color wheel or curve point is held: previews
    /// rendered meanwhile are drag approximations (`PreviewDragSession`) and
    /// the exact frame follows on release (`PreviewRenderPump`'s settle job).
    private var previewDragSession: PreviewDragSession?
    /// Which render runs, which drag tick waits, and what is on screen.
    private var renderPump = PreviewRenderPump<PreviewRenderRequest>()
    private var directPreviewSerial: UInt64 = 0
    private var editStates: [String: PhotoEditSnapshot] = [:]
    @Published private var unsavedEditStates: [String: PendingEditSave] = [:]
    @Published private var persistenceStatusByAssetID: [String: EditPersistenceStatus] = [:]
    private var loadBlockedAssetIDs: Set<String> = []
    private var pendingEditSave: PendingEditSave?
    private var editHistory = PerPhotoEditHistory()
    private var activeSliderGesturePhotoID: String?
    private var activeBrushStrokePhotoID: String?
    /// Content-addressed cache. Old artifacts remain available while undo can
    /// still restore a recipe created before a re-detection.
    private var cutoutMaskDataByArtifactID: [String: Data] = [:]
    private var currentInputSHA256: String?

    private struct PendingEditSave {
        let assetID: String
        let photoURL: URL
        let snapshot: PhotoEditSnapshot
    }

    init(
        initialDirectoryHint: URL,
        folderAccess: FolderAccessCoordinator? = nil,
        store: PhotoBenchStore? = nil
    ) {
        self.initialDirectoryHint = initialDirectoryHint
        self.folderAccess = folderAccess ?? FolderAccessCoordinator()
        self.store = store ?? .applicationSupport()
        let configuredRoute = PreviewPresentationRoute.configured()
        previewRoute = configuredRoute == .metalDirect && MetalPreviewRenderer.isSupported
            ? .metalDirect
            : .legacyBitmap
        rootURL = nil
        loadPresetLibrary()

        switch self.folderAccess.restore() {
        case let .restored(url):
            if let kind = PhotoKind.detect(url: url),
               (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let asset = PhotoAsset(url: url, kind: kind)
                rootURL = url.deletingLastPathComponent()
                assets = [asset]
                assetsByID = [asset.id: asset]
                selectedAssetID = asset.id
            } else {
                rootURL = url
                reloadLibrary()
            }
        case .selectionRequired(.missing):
            isBusy = false
            statusMessage = "写真フォルダを選択してください。初回は自動走査しません。"
        case .selectionRequired(.stale):
            isBusy = false
            statusMessage = "保存した写真フォルダ情報が古くなりました。もう一度フォルダを選択してください。"
        case .selectionRequired(.accessDenied):
            isBusy = false
            statusMessage = "保存した写真フォルダへのアクセスを再開できません。もう一度フォルダを選択してください。"
        case .selectionRequired(.unavailable):
            isBusy = false
            statusMessage = "保存した写真フォルダが見つかりません。SSDを接続して再起動するか、別のフォルダを選択してください。"
        case .selectionRequired(.invalid):
            isBusy = false
            statusMessage = "保存した写真フォルダ情報を復元できません。もう一度フォルダを選択してください。"
        }
    }

    var selectedAsset: PhotoAsset? {
        selectedAssetID.flatMap { assetsByID[$0] }
    }

    var settings: EditSettings { editSnapshot.settings }
    var preset: XMPPreset? { editSnapshot.appliedPreset }
    var applyApproximateXMPColor: Bool { editSnapshot.applyApproximateXMPColor }
    var appliedPresetDisplayName: String? {
        guard let preset = editSnapshot.appliedPreset else { return nil }
        return editSnapshot.appliedPresetID == PhotoEditSnapshot.bluesky2ReferencePresetID
            ? "bluesky2（更新XMP）"
            : preset.name
    }
    var persistenceMessage: String { persistenceStatus.message }
    var unsavedEditCount: Int { unsavedEditStates.count }
    var unsavedStatusMessage: String? {
        guard !unsavedEditStates.isEmpty else { return nil }
        let failure = persistenceStatusByAssetID.values.compactMap { status -> String? in
            guard case let .saveFailed(reason) = status else { return nil }
            return reason
        }.first
        if let failure { return "未保存 \(unsavedEditStates.count)枚: \(failure)" }
        return "保存中… \(unsavedEditStates.count)枚未保存"
    }
    var hasSaveFailures: Bool {
        persistenceStatusByAssetID.values.contains {
            if case .saveFailed = $0 { return true }
            return false
        }
    }
    var backgroundEdit: BackgroundEditRecipe? { editSnapshot.backgroundEdit }
    var isShowingCutout: Bool { backgroundRenderCapture != nil }
    var cutoutSubjects: [CutoutSubject] { editSnapshot.backgroundEdit?.subjects ?? [] }
    var selectedCutoutSubject: CutoutSubjectSelection? {
        editSnapshot.backgroundEdit?.selectedSubject
    }
    var canEdit: Bool {
        guard selectedAssetID != nil, !isBusy, !isCutoutRunning else { return false }
        if case .loadFailed = persistenceStatus { return false }
        return true
    }
    var canRetrySave: Bool {
        !unsavedEditStates.isEmpty
    }
    var canRetryLoad: Bool {
        guard selectedAssetID != nil else { return false }
        if case .loadFailed = persistenceStatus { return true }
        return false
    }

    var canExport: Bool {
        decodedPhoto != nil
            && !isBusy
            && !isCutoutRunning
            && (editSnapshot.backgroundEdit == nil || backgroundRenderCapture != nil)
    }
    var canChooseFolder: Bool { !isBusy && !isCutoutRunning && !hasPreviewInFlight }

    private var backgroundRenderCapture: BackgroundRenderCapture? {
        guard let recipe = editSnapshot.backgroundEdit,
              let reference = recipe.selectedMask,
              let mask = cutoutMaskDataByArtifactID[reference.artifactID]
        else { return nil }
        return BackgroundRenderCapture(recipe: recipe, maskPNGData: mask)
    }

    func startBackgroundRemoval() {
        guard !isCutoutRunning,
              let decodedPhoto,
              let asset = selectedAsset,
              let inputHash = currentInputSHA256,
              canEdit
        else { return }
        finishSliderGesture()
        finishBrushStroke()
        cutoutTask?.cancel()
        let generation = loadGeneration
        let assetID = asset.id
        let token = UUID()
        let coordinator = renderCoordinator
        cutoutJobToken = token
        isCutoutRunning = true
        cutoutMaskErrorMessage = nil
        statusMessage = "Apple Visionで被写体を検出しています…"
        cutoutTask = Task { [weak self] in
            do {
                let result = try await coordinator.detectCutout(
                    decoded: decodedPhoto,
                    inputSHA256: inputHash
                )
                try Task.checkCancellation()
                guard let self,
                      self.isCurrentCutoutJob(token, generation: generation, assetID: assetID)
                else { return }
                var subjects: [CutoutSubject] = []
                var dataByArtifactID: [String: Data] = [:]
                for mask in result.masks {
                    try Task.checkCancellation()
                    guard self.isCurrentCutoutJob(token, generation: generation, assetID: assetID) else {
                        return
                    }
                    let reference = try self.store.saveMask(
                        pngData: mask.pngData,
                        inputSHA256: result.inputSHA256,
                        width: result.width,
                        height: result.height,
                        orientation: 1,
                        selection: mask.selection
                    )
                    subjects.append(CutoutSubject(
                        selection: mask.selection,
                        pixelCount: mask.pixelCount,
                        mask: reference
                    ))
                    dataByArtifactID[reference.artifactID] = mask.pngData
                }
                guard let selectedReference = subjects.first(where: {
                    $0.selection == result.largestSelection
                })?.mask,
                      dataByArtifactID[selectedReference.artifactID] != nil
                else {
                    throw CutoutError.noForegroundSubjects
                }
                try Task.checkCancellation()
                guard self.isCurrentCutoutJob(token, generation: generation, assetID: assetID) else {
                    return
                }
                self.cutoutMaskDataByArtifactID.merge(dataByArtifactID) { _, new in new }
                // mutateEditSnapshot intentionally observes canEdit. Finish the
                // current job first or the completed detection is discarded.
                self.finishCutoutJob(token, generation: generation, assetID: assetID)
                self.mutateEditSnapshot { snapshot in
                    snapshot.backgroundEdit = BackgroundEditRecipe(
                        subjects: subjects,
                        selectedSubject: result.largestSelection,
                        background: snapshot.backgroundEdit?.background ?? .transparent
                    )
                }
                self.statusMessage = "背景を除去しました。最大の被写体を選択しています。"
            } catch is CancellationError {
                guard let self,
                      self.finishCutoutJob(token, generation: generation, assetID: assetID)
                else { return }
                self.statusMessage = "背景除去を中止しました。以前の編集は保持されています。"
            } catch {
                guard let self,
                      self.finishCutoutJob(token, generation: generation, assetID: assetID)
                else { return }
                self.statusMessage = "背景除去に失敗しました。以前の編集は保持されています: \(error.localizedDescription)"
            }
        }
    }

    func cancelBackgroundRemoval() {
        cutoutTask?.cancel()
    }

    private func isCurrentCutoutJob(_ token: UUID, generation: Int, assetID: String) -> Bool {
        cutoutJobToken == token
            && loadGeneration == generation
            && selectedAssetID == assetID
    }

    @discardableResult
    private func finishCutoutJob(_ token: UUID, generation: Int, assetID: String) -> Bool {
        guard isCurrentCutoutJob(token, generation: generation, assetID: assetID) else {
            return false
        }
        cutoutJobToken = nil
        cutoutTask = nil
        isCutoutRunning = false
        return true
    }

    func removeBackgroundEdit() {
        guard editSnapshot.backgroundEdit != nil else { return }
        finishBrushStroke()
        mutateEditSnapshot { $0.backgroundEdit = nil }
        statusMessage = "背景編集を解除しました。保存済みマスクは元写真保護のため残しています。"
    }

    func selectCutoutSubject(_ selection: CutoutSubjectSelection) {
        guard let subject = editSnapshot.backgroundEdit?.subjects.first(where: {
            $0.selection == selection
        }),
              cutoutMaskDataByArtifactID[subject.mask.artifactID] != nil
        else {
            cutoutMaskErrorMessage = "選択した被写体の保存済みマスクを読み込めません。"
            return
        }
        mutateEditSnapshot { snapshot in
            guard snapshot.backgroundEdit?.subjects.contains(where: { $0.selection == selection }) == true else { return }
            snapshot.backgroundEdit?.selectedSubject = selection
            snapshot.backgroundEdit?.brushStrokes = []
        }
    }

    func setCutoutBackground(_ background: CutoutBackground) {
        mutateEditSnapshot { $0.backgroundEdit?.background = background }
    }

    func beginBrushStroke(at point: CutoutPoint) {
        guard activeBrushStrokePhotoID == nil,
              let assetID = selectedAssetID,
              editSnapshot.backgroundEdit != nil,
              canEdit
        else { return }
        finishSliderGesture()
        activeBrushStrokePhotoID = assetID
        editHistory.beginGroup(for: assetID, startingAt: editSnapshot)
        mutateEditSnapshot { snapshot in
            snapshot.backgroundEdit?.brushStrokes.append(CutoutBrushStroke(
                mode: cutoutBrushMode,
                radius: cutoutBrushRadius,
                points: [point]
            ))
        }
    }

    func continueBrushStroke(at point: CutoutPoint) {
        guard activeBrushStrokePhotoID == selectedAssetID else { return }
        mutateEditSnapshot { snapshot in
            guard var stroke = snapshot.backgroundEdit?.brushStrokes.popLast() else { return }
            if stroke.points.last != point { stroke.points.append(point) }
            snapshot.backgroundEdit?.brushStrokes.append(stroke)
        }
    }

    func finishBrushStroke() {
        guard let assetID = activeBrushStrokePhotoID else { return }
        let current = editStates[assetID] ?? editSnapshot
        editHistory.endGroup(for: assetID, at: current)
        activeBrushStrokePhotoID = nil
        refreshHistoryAvailability()
        flushPendingEditSave()
    }

    func presetDisplayName(for storedPreset: StoredXMPPreset) -> String {
        storedPreset.id == PhotoEditSnapshot.bluesky2ReferencePresetID
            ? "bluesky2（更新XMP）"
            : storedPreset.name
    }

    /// General-purpose entry point for every inspector control: sliders keyed
    /// by a `Double` keypath (`updateSetting(_:at:)` below), point-curve drag
    /// handles, HSL/Color Grading/Calibration bands, and white balance mode
    /// switches all go through this so they share one undo/autosave/render
    /// path (`mutateEditSnapshot`).
    func updateSettings(_ mutation: (inout EditSettings) -> Void) {
        mutateEditSnapshot { snapshot in
            mutation(&snapshot.settings)
        }
    }

    func updateSetting(_ value: Double, at keyPath: WritableKeyPath<EditSettings, Double>) {
        updateSettings { $0[keyPath: keyPath] = value }
    }

    func setApproximateColorEnabled(_ enabled: Bool) {
        mutateEditSnapshot { $0.applyApproximateXMPColor = enabled }
    }

    /// Resets one inspector panel's fields to `EditSettings.neutral`, as a
    /// single undo step (one `mutateEditSnapshot` call, not wrapped in a
    /// slider-editing group). `.basic` and `.detail` are split so the visible
    /// "基本補正" header's reset button can restore both the always-on tone/
    /// presence/white-balance sliders (`.basic`) and the not-yet-rendered
    /// Texture/Clarity/Dehaze trio (`.detail`) together, while still letting
    /// either be reset independently through this API.
    func resetSection(_ section: EditSection) {
        let neutral = EditSettings.neutral
        updateSettings { settings in
            switch section {
            case .basic:
                settings.exposure = neutral.exposure
                settings.contrast = neutral.contrast
                settings.highlights = neutral.highlights
                settings.shadows = neutral.shadows
                settings.whites = neutral.whites
                settings.blacks = neutral.blacks
                settings.vibrance = neutral.vibrance
                settings.saturation = neutral.saturation
                settings.relativeTemperature = neutral.relativeTemperature
                settings.relativeTint = neutral.relativeTint
                settings.whiteBalance = neutral.whiteBalance
            case .toneCurve:
                settings.toneCurves = neutral.toneCurves
                settings.parametricShadows = neutral.parametricShadows
                settings.parametricDarks = neutral.parametricDarks
                settings.parametricLights = neutral.parametricLights
                settings.parametricHighlights = neutral.parametricHighlights
                settings.parametricShadowSplit = neutral.parametricShadowSplit
                settings.parametricMidtoneSplit = neutral.parametricMidtoneSplit
                settings.parametricHighlightSplit = neutral.parametricHighlightSplit
            case .hsl:
                settings.hsl = neutral.hsl
            case .colorGrading:
                settings.colorGrading = neutral.colorGrading
            case .calibration:
                settings.calibration = neutral.calibration
            case .detail:
                settings.texture = neutral.texture
                settings.clarity = neutral.clarity
                settings.dehaze = neutral.dehaze
            }
        }
    }

    func sliderEditingChanged(_ isEditing: Bool) {
        if isEditing {
            guard canEdit, let assetID = selectedAssetID else { return }
            if activeSliderGesturePhotoID != nil { finishSliderGesture() }
            activeSliderGesturePhotoID = assetID
            editHistory.beginGroup(for: assetID, startingAt: editSnapshot)
            refreshHistoryAvailability()
            // Ticks until release render as drag frames: statistics frozen
            // at these settings, the spatial pass reused while its inputs are
            // unchanged, and small cubes for values not baked yet.
            previewDragSession = PreviewDragSession(startSettings: renderSettings)
            renderPump.beginDrag()
        } else {
            finishSliderGesture()
            flushPendingEditSave()
            // No `.final` re-render here: the preview always uses
            // `.interactive` quality (its difference from `.final` is mean
            // ΔE00 0.03〜0.08, below perception), and the owner reported a
            // post-release `.final` re-render as a ~0.7s lag. The exact
            // `.interactive` frame replaces the last drag frame quietly
            // (`finishSliderGesture` -> the pump's settle job), and any new
            // input cancels it. Exports still use `.final`.
        }
    }

    func undo() {
        guard canEdit, let assetID = selectedAssetID else { return }
        finishSliderGesture()
        flushPendingEditSave()
        guard let restored = editHistory.undo(for: assetID, current: editSnapshot) else { return }
        restoreSnapshotThroughMutation(restored, for: assetID)
    }

    func redo() {
        guard canEdit, let assetID = selectedAssetID else { return }
        finishSliderGesture()
        flushPendingEditSave()
        guard let restored = editHistory.redo(for: assetID, current: editSnapshot) else { return }
        restoreSnapshotThroughMutation(restored, for: assetID)
    }

    func retryAllUnsavedEdits() {
        let alreadyFlushedID = pendingEditSave?.assetID
        flushPendingEditSave()
        for assetID in Array(unsavedEditStates.keys) where assetID != alreadyFlushedID {
            guard let pending = unsavedEditStates[assetID], !loadBlockedAssetIDs.contains(assetID) else { continue }
            setPersistenceStatus(.saving, for: assetID)
            persist(pending)
        }
    }

    func retryLoadCurrentPhotoEdits() {
        guard let assetID = selectedAssetID, let asset = assetsByID[assetID] else { return }
        do {
            let snapshot = try store.loadEdit(for: asset.url)?.snapshot ?? .neutral
            loadBlockedAssetIDs.remove(assetID)
            unsavedEditStates.removeValue(forKey: assetID)
            editStates[assetID] = snapshot
            editSnapshot = snapshot
            setPersistenceStatus(.saved, for: assetID)
            refreshHistoryAvailability()
            loadSelection()
        } catch {
            loadBlockedAssetIDs.insert(assetID)
            setPersistenceStatus(.loadFailed(error.localizedDescription), for: assetID)
        }
    }

    @discardableResult
    func flushPendingChanges() -> Int {
        finishSliderGesture()
        let alreadyFlushedID = pendingEditSave?.assetID
        flushPendingEditSave()
        for assetID in Array(unsavedEditStates.keys) where assetID != alreadyFlushedID {
            guard let pending = unsavedEditStates[assetID],
                  !loadBlockedAssetIDs.contains(assetID)
            else { continue }
            persist(pending)
        }
        return unsavedEditStates.count
    }

    func reloadLibrary() {
        scanTask?.cancel()
        guard let root = rootURL else {
            isBusy = false
            statusMessage = "写真フォルダを選択してください。"
            return
        }
        isBusy = true
        statusMessage = "写真フォルダを走査しています…"
        scanTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try PhotoLibrary.scan(root: root)
                }
                let scanned = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.rootURL == root else { return }
                self.assets = scanned
                self.assetsByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
                let nextID = self.selectedAssetID.flatMap { self.assetsByID[$0] }?.id ?? scanned.first?.id
                if self.selectedAssetID != nextID {
                    self.selectedAssetID = nextID
                } else if nextID != nil {
                    self.loadSelection()
                } else {
                    self.isBusy = false
                    self.statusMessage = "対応するJPEGまたはRAWがありません。"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.rootURL == root else { return }
                self.assets = []
                self.assetsByID = [:]
                self.isBusy = false
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func chooseFolder() {
        // Replacing the active security-scoped root while a lazy Core Image
        // decode/render/export is still using it can revoke access mid-flight.
        // Keep the capability alive until the current operation completes.
        guard canChooseFolder else {
            statusMessage = "処理中は写真フォルダを変更できません。完了後にもう一度お試しください。"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "JPEGとRAWがある写真フォルダを選んでください"
        panel.directoryURL = rootURL ?? initialDirectoryHint
        guard panel.runModal() == .OK, let url = panel.url else { return }

        flushPendingChanges()
        scanTask?.cancel()
        loadTask?.cancel()
        renderTask?.cancel()
        renderPump.reset()
        renderRevision &+= 1
        do {
            try folderAccess.activateSelection(url)
        } catch {
            isBusy = false
            statusMessage = "写真フォルダのアクセス情報を保存できません: \(error.localizedDescription)"
            return
        }

        rootURL = url
        selectedAssetID = nil
        assets = []
        assetsByID = [:]
        preview = nil
        directPreviewRequest = nil
        hasPreviewInFlight = false
        decodedPhoto = nil
        previewWorkingCopy = nil
        decodeInfo = nil
        reloadLibrary()
    }

    func choosePhoto() {
        guard canChooseFolder else {
            statusMessage = "処理中は写真を変更できません。完了後にもう一度お試しください。"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "編集する写真を1枚選んでください"
        panel.directoryURL = rootURL ?? initialDirectoryHint
        guard panel.runModal() == .OK,
              let url = panel.url,
              let kind = PhotoKind.detect(url: url)
        else { return }

        flushPendingChanges()
        scanTask?.cancel()
        loadTask?.cancel()
        renderTask?.cancel()
        renderPump.reset()
        renderRevision &+= 1
        do {
            // Keep the selected file's security-scoped bookmark active for
            // decode, inference and export-source reads until another choice.
            try folderAccess.activateSelection(url)
        } catch {
            statusMessage = "写真のアクセス情報を保存できません: \(error.localizedDescription)"
            return
        }
        let asset = PhotoAsset(url: url, kind: kind)
        rootURL = url.deletingLastPathComponent()
        selectedAssetID = nil
        assets = [asset]
        assetsByID = [asset.id: asset]
        selectedAssetID = asset.id
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL ?? initialDirectoryHint
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let sourceData = try ImplicitSecurityScopedAccess.withAccess(to: url) {
                try Data(contentsOf: url)
            }
            let imported = try store.registerPreset(
                data: sourceData,
                name: url.deletingPathExtension().lastPathComponent
            )
            try refreshPresetLibrary()
            applyPreset(imported)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applyPreset(id: String) {
        guard let stored = presetLibrary.first(where: { $0.id == id }) else { return }
        applyPreset(stored)
    }

    func deletePreset(id: String) {
        do {
            try store.deletePreset(id: id)
            try refreshPresetLibrary()
            statusMessage = "プリセットを削除しました。適用済みの編集状態は保持されています。"
        } catch {
            presetLibraryErrorMessage = error.localizedDescription
        }
    }

    func resetAdjustments() {
        finishSliderGesture()
        flushPendingEditSave()
        mutateEditSnapshot { $0 = .neutral }
        statusMessage = "調整をリセットしました。"
    }

    func scheduleRender() {
        guard decodedPhoto != nil else { return }
        renderRevision &+= 1
        let drag = previewWorkingCopy == nil ? nil : previewDragSession
        hasPreviewInFlight = true
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewInput",
            "request=%{public}llu",
            renderRevision
        )
        // A running drag frame is kept (the newest tick waits for it), so a
        // continuous drag keeps updating; anything else supersedes and
        // cancels the running render (`PreviewRenderPump`).
        if let job = renderPump.submit(
            revision: renderRevision,
            isDragFrame: drag != nil,
            payload: PreviewRenderRequest(
                settings: renderSettings,
                background: backgroundRenderCapture,
                drag: drag,
                inputHostTime: CACurrentMediaTime()
            )
        ) {
            startRender(job)
        }
    }

    private func startRender(_ job: PreviewRenderJob) {
        guard let decodedPhoto else { return }
        // A settle job renders the current settings (its revision's) exactly.
        let request = job.payload
            ?? PreviewRenderRequest(
                settings: renderSettings,
                background: backgroundRenderCapture,
                drag: nil,
                inputHostTime: CACurrentMediaTime()
            )
        let workingCopy = previewWorkingCopy
        let coordinator = renderCoordinator
        let generation = loadGeneration
        renderTask?.cancel()
        // The preview always renders at `.interactive` spatial quality
        // (Shadows discretization 5 instead of 10, 375px statistics): it is
        // visually indistinguishable from `.final` (mean ΔE00 0.03〜0.08) and
        // about twice as fast, and a settled-state `.final` re-render after
        // each drag was perceived as lag. Export paths (`exportFromPanel` →
        // `RenderEngine.exportJPEG`) keep `.final`.
        let quality: SpatialToneQuality = .interactive
        renderTask = Task { [weak self] in
            do {
                let frame: PreparedPreviewFrame
                if let workingCopy {
                    frame = try await coordinator.preparePreviewFromWorkingCopy(
                        workingCopy: workingCopy,
                        settings: request.settings,
                        quality: quality,
                        drag: request.drag
                    )
                } else {
                    frame = try await coordinator.prepareProductionPreview(
                        decoded: decodedPhoto,
                        settings: request.settings,
                        quality: quality
                    )
                }
                try Task.checkCancellation()
                if let self, self.loadGeneration == generation {
                    try await self.presentPreparedFrame(frame, job: job, request: request)
                }
            } catch is CancellationError {
                // Superseded: a newer render is (or will be) shown instead.
            } catch {
                if let self, !Task.isCancelled, self.loadGeneration == generation,
                   self.renderRevision == job.revision {
                    self.hasPreviewInFlight = false
                    self.statusMessage = error.localizedDescription
                }
            }
            if let self, let next = self.renderPump.finish(job) {
                self.startRender(next)
            }
        }
    }

    func directPreviewPresented(
        requestID: UInt64,
        presentedTime: CFTimeInterval
    ) {
        guard previewRoute == .metalDirect,
              let request = directPreviewRequest,
              request.id == requestID
        else {
            return
        }
        guard presentedTime > 0 else {
            directPreviewDropped(requestID: requestID)
            return
        }
        let milliseconds = max(0, (presentedTime - request.inputHostTime) * 1_000)
        if request.updatesTiming {
            renderMilliseconds = milliseconds
        }
        if PreviewDiagnostics.printsToStandardError {
            FileHandle.standardError.write(Data(
                "PreviewLatency: revision=\(request.revision) inputToPresent=\(String(format: "%.1f", milliseconds))ms\n".utf8
            ))
        }
        directPresentedCount += 1
        if request.revision == renderRevision {
            hasPreviewInFlight = false
        }
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewPresented",
            "request=%{public}llu inputToPresentMs=%{public}.3f",
            requestID,
            milliseconds
        )
        if request.kind == .initialSelection {
            isBusy = false
            statusMessage = loadedStatusMessage()
        }
    }

    func directPreviewCoalesced(requestID: UInt64) {
        directCoalescedCount += 1
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewCoalesced",
            "request=%{public}llu",
            requestID
        )
    }

    func directPreviewDrawableUnavailable(requestID: UInt64) {
        directDrawableUnavailableCount += 1
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewDrawableUnavailable",
            "request=%{public}llu",
            requestID
        )
    }

    func directPreviewDropped(requestID: UInt64) {
        directDroppedCount += 1
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewDropped",
            "request=%{public}llu",
            requestID
        )
    }

    func directPreviewFailed(requestID: UInt64, errorDescription: String) {
        guard previewRoute == .metalDirect,
              let request = directPreviewRequest,
              request.id == requestID,
              renderRevision == request.revision
        else {
            return
        }
        // Runtime fallback is intentionally one-way for this process. Repeated
        // Metal/bitmap oscillation would make both color and latency unstable.
        // Keep the loading state visible until the same prepared frame has
        // been materialized; switching routes must never flash an empty state.
        isBusy = true
        hasPreviewInFlight = true
        previewRoute = .legacyBitmap
        directPreviewRequest = nil
        statusMessage = "Metal直接表示を停止し、従来表示へ戻しています: \(errorDescription)"
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewMetalFallback",
            "request=%{public}llu",
            requestID
        )
        let coordinator = renderCoordinator
        renderTask?.cancel()
        renderPump.reset()
        renderTask = Task { [weak self] in
            do {
                let rendered = try await coordinator.materializePreview(request.frame)
                guard let self,
                      self.renderRevision == request.revision,
                      self.previewRoute == .legacyBitmap
                else { return }
                self.preview = rendered.image
                // This label becomes "preview generation" after switching to
                // the bitmap route. Report only the work that produced that
                // bitmap; the failed direct-route delivery latency remains in
                // the presentation signposts and status message.
                self.renderMilliseconds = request.frame.graphAndKernelSetupMilliseconds
                    + rendered.durationMilliseconds
                self.hasPreviewInFlight = false
                self.isBusy = false
                self.statusMessage = "Metal直接表示に失敗したため、この起動中は従来表示を使用します（\(errorDescription)）。"
            } catch {
                guard let self, self.renderRevision == request.revision else { return }
                self.hasPreviewInFlight = false
                self.isBusy = false
                self.statusMessage = "プレビュー表示に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    func exportFromPanel() {
        exportFromPanel(format: .jpeg(quality: 0.92))
    }

    func exportPNGFromPanel() {
        exportFromPanel(format: .png)
    }

    private func exportFromPanel(format: CutoutOutputFormat) {
        guard canExport, let decodedPhoto, let source = selectedAsset else {
            if editSnapshot.backgroundEdit != nil, backgroundRenderCapture == nil {
                statusMessage = "保存済みマスクを再検出するか背景編集を解除するまで書き出せません。"
            }
            return
        }
        let panel = NSSavePanel()
        let isPNG: Bool
        switch format {
        case .png: isPNG = true
        case .jpeg: isPNG = false
        }
        panel.allowedContentTypes = [isPNG ? .png : .jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = rootURL?.appendingPathComponent("exports", isDirectory: true)
            ?? initialDirectoryHint
        panel.nameFieldStringValue = source.url.deletingPathExtension().lastPathComponent
            + "-niho-camera." + (isPNG ? "png" : "jpg")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isBusy = true
        statusMessage = "原寸\(isPNG ? "PNG" : "JPEG")を書き出しています…"
        let capturedSettings = renderSettings
        let capturedBackground = backgroundRenderCapture
        let protectedSourceURLs = assets.map(\.url)
        let coordinator = renderCoordinator
        Task { [weak self] in
            do {
                let message = try await ImplicitSecurityScopedAccess.withAccess(to: destination) {
                    if let capturedBackground {
                        let size = try await coordinator.exportCutout(
                            decoded: decodedPhoto,
                            settings: capturedSettings,
                            recipe: capturedBackground.recipe,
                            maskPNGData: capturedBackground.maskPNGData,
                            destination: destination,
                            format: format,
                            protectedSourceURLs: protectedSourceURLs
                        )
                        return "\(Int(size.width))×\(Int(size.height))のsRGB \(isPNG ? "PNG" : "JPEG")を書き出しました: \(destination.lastPathComponent)"
                    }
                    guard !isPNG else {
                        throw CutoutError.unsupportedOutput(destination)
                    }
                    let milliseconds = try await coordinator.exportJPEG(
                        decoded: decodedPhoto,
                        settings: capturedSettings,
                        destination: destination,
                        protectedSourceURLs: protectedSourceURLs
                    )
                    return String(format: "sRGB JPEGを書き出しました（XMP互換は項目別、%.0fms）: %@", milliseconds, destination.lastPathComponent)
                }
                self?.isBusy = false
                self?.statusMessage = message
            } catch {
                self?.isBusy = false
                self?.statusMessage = "書き出し失敗: \(error.localizedDescription)"
            }
        }
    }

    private func loadSelection() {
        cutoutTask?.cancel()
        cutoutTask = nil
        cutoutJobToken = nil
        isCutoutRunning = false
        activeBrushStrokePhotoID = nil
        cutoutMaskDataByArtifactID = [:]
        currentInputSHA256 = nil
        cutoutMaskErrorMessage = nil
        guard let asset = selectedAsset else {
            loadTask?.cancel()
            renderTask?.cancel()
            renderPump.reset()
            renderRevision &+= 1
            preview = nil
            directPreviewRequest = nil
            hasPreviewInFlight = false
            decodedPhoto = nil
            previewWorkingCopy = nil
            decodeInfo = nil
            return
        }
        renderTask?.cancel()
        renderPump.reset()
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        renderRevision &+= 1
        let revision = renderRevision
        let inputHostTime = CACurrentMediaTime()
        isBusy = true
        hasPreviewInFlight = true
        preview = nil
        directPreviewRequest = nil
        decodedPhoto = nil
        previewWorkingCopy = nil
        decodeInfo = nil
        renderMilliseconds = nil
        statusMessage = "\(asset.filename)を現像しています…"
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewInput",
            "request=%{public}llu initial=1",
            revision
        )
        let decoder = decoder
        let coordinator = renderCoordinator

        loadTask = Task { [weak self] in
            do {
                let hashWorker = Task.detached(priority: .utility) {
                    try CutoutHash.sha256(fileURL: asset.url)
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try decoder.decode(url: asset.url)
                }
                let (inputHash, decoded) = try await withTaskCancellationHandler {
                    try await (hashWorker.value, worker.value)
                } onCancel: {
                    hashWorker.cancel()
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let self, self.loadGeneration == generation else { return }
                self.currentInputSHA256 = inputHash
                // Reduce the full-resolution decode once; every preview of
                // this photo then renders from the working copy. A failure
                // only costs speed: previews fall back to the full decode.
                let workingCopy: DecodedPhoto?
                do {
                    workingCopy = try await coordinator.makePreviewWorkingCopy(from: decoded)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    workingCopy = nil
                    os_signpost(
                        .event,
                        log: Self.presentationLog,
                        name: "PreviewWorkingCopyUnavailable",
                        "request=%{public}llu error=%{public}@",
                        revision,
                        error.localizedDescription as NSString
                    )
                }
                try Task.checkCancellation()
                guard self.loadGeneration == generation else { return }
                if let recipe = self.editSnapshot.backgroundEdit {
                    do {
                        guard self.loadGeneration == generation else { return }
                        var loaded: [String: Data] = [:]
                        for subject in recipe.subjects {
                            loaded[subject.mask.artifactID] = try self.store.loadMask(
                                subject.mask,
                                inputSHA256: inputHash,
                                width: decoded.info.width,
                                height: decoded.info.height,
                                orientation: 1
                            )
                        }
                        self.cutoutMaskDataByArtifactID = loaded
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        self.cutoutMaskDataByArtifactID = [:]
                        self.cutoutMaskErrorMessage = error.localizedDescription
                    }
                }
                // Resolve settings after decoding. The top-level controls are
                // disabled while busy, but taking the value here also prevents
                // an old pre-decode snapshot from reaching the screen.
                let frame: PreparedPreviewFrame
                if let workingCopy {
                    frame = try await coordinator.preparePreviewFromWorkingCopy(
                        workingCopy: workingCopy,
                        settings: self.renderSettings
                    )
                } else {
                    frame = try await coordinator.prepareProductionPreview(
                        decoded: decoded,
                        settings: self.renderSettings
                    )
                }
                try Task.checkCancellation()
                guard self.loadGeneration == generation,
                      self.renderRevision == revision
                else { return }
                self.decodedPhoto = decoded
                self.previewWorkingCopy = workingCopy
                self.decodeInfo = decoded.info
                try await self.presentPreparedFrame(
                    frame,
                    job: nil,
                    request: PreviewRenderRequest(
                        settings: self.renderSettings,
                        background: self.backgroundRenderCapture,
                        drag: nil,
                        inputHostTime: inputHostTime
                    ),
                    initialRevision: revision
                )
            } catch is CancellationError {
                return
            } catch {
                guard self?.loadGeneration == generation,
                      self?.renderRevision == revision
                else { return }
                self?.isBusy = false
                self?.hasPreviewInFlight = false
                self?.preview = nil
                self?.directPreviewRequest = nil
                self?.decodedPhoto = nil
                self?.previewWorkingCopy = nil
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    /// `job`: a pump job (`kind` `.edit`), or `nil` for the photo's first
    /// frame at `initialRevision` (`.initialSelection`).
    private func presentPreparedFrame(
        _ frame: PreparedPreviewFrame,
        job: PreviewRenderJob?,
        request: PreviewRenderRequest,
        initialRevision: UInt64 = 0
    ) async throws {
        let kind: DirectPreviewRequest.Kind = job == nil ? .initialSelection : .edit
        let revision = job?.revision ?? initialRevision
        // The quiet exact frame after a drag keeps the drag frame's timing.
        let updatesTiming = job?.kind != .settle
        func mayPresent() -> Bool {
            job.map { renderPump.canPresent($0) } ?? (revision > renderPump.presentedRevision)
        }
        func notePresented() {
            if let job {
                renderPump.presented(job)
            } else {
                renderPump.presentedExactFrame(revision: revision)
            }
        }
        guard mayPresent() else { throw CancellationError() }
        if let background = request.background {
            let materialized = try await renderCoordinator.materializeCutoutPreview(
                frame,
                recipe: background.recipe,
                maskPNGData: background.maskPNGData
            )
            try Task.checkCancellation()
            guard mayPresent() else { throw CancellationError() }
            directPreviewRequest = nil
            preview = materialized.image
            notePresented()
            let latency = max(0, (CACurrentMediaTime() - request.inputHostTime) * 1_000)
            if updatesTiming { renderMilliseconds = latency }
            if revision == renderRevision { hasPreviewInFlight = false }
            if kind == .initialSelection {
                isBusy = false
                statusMessage = loadedStatusMessage()
            }
            return
        }
        switch previewRoute {
        case .metalDirect:
            preview = nil
            directPreviewSerial &+= 1
            directPreviewRequest = DirectPreviewRequest(
                id: directPreviewSerial,
                frame: frame,
                inputHostTime: request.inputHostTime,
                kind: kind,
                revision: revision,
                updatesTiming: updatesTiming
            )
            notePresented()
            if kind == .initialSelection {
                statusMessage = "原寸デコード済み。Metalで画面表示しています…"
            }
        case .legacyBitmap:
            let materialized = try await renderCoordinator.materializePreview(frame)
            try Task.checkCancellation()
            guard mayPresent() else { throw CancellationError() }
            directPreviewRequest = nil
            preview = materialized.image
            notePresented()
            let latency = max(0, (CACurrentMediaTime() - request.inputHostTime) * 1_000)
            if updatesTiming {
                renderMilliseconds = latency
            }
            if PreviewDiagnostics.printsToStandardError {
                let label = job.map { "\($0.kind)" } ?? "initial"
                FileHandle.standardError.write(Data(
                    "PreviewLatency: revision=\(revision) \(label) inputToBitmap=\(String(format: "%.1f", latency))ms\n".utf8
                ))
            }
            if revision == renderRevision {
                hasPreviewInFlight = false
            }
            if kind == .initialSelection {
                isBusy = false
                statusMessage = loadedStatusMessage()
            }
        }
    }

    private func loadedStatusMessage() -> String {
        if let cutoutMaskErrorMessage {
            return "写真を読み込みました。\(cutoutMaskErrorMessage)"
        }
        guard let info = decodeInfo else { return "プレビューを表示しました。" }
        if info.isRAW {
            if info.calibrationID == RAWCalibrationProfile.panasonicDCS5Lightroom93.id {
                return "\(info.backend)で原寸デコードしました（DC-S5色差2枚のみ、白飛び未校正）。"
            }
            return "\(info.backend)で原寸デコードしました（この機種の色は未校正）。"
        }
        return "写真を読み込みました。"
    }

    /// Phase2 C1/C2 made every field in `EditSettings` (tone curves, HSL,
    /// Color Grading, Calibration, absolute white balance) a measured model,
    /// so there is no longer a "near-approximate, needs a gate" tier to hide
    /// behind `applyApproximateXMPColor` -- the CLI (`photobench-render`)
    /// already always applies everything. `applyApproximateXMPColor` is kept
    /// only as a `PhotoEditSnapshot` Codable field for old saved edits/XMP
    /// round-tripping; it no longer affects what gets rendered here.
    private var renderSettings: EditSettings { editSnapshot.settings }

    private func loadPresetLibrary() {
        do {
            let seeds = try bundledPresetSeeds()
            if !seeds.isEmpty {
                try store.seedBuiltInPresets(seeds, version: 2)
            }
            try refreshPresetLibrary()
        } catch {
            presetLibraryErrorMessage = error.localizedDescription
        }
    }

    private func bundledPresetSeeds() throws -> [BuiltInPresetSeed] {
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("Presets", isDirectory: true),
              FileManager.default.fileExists(atPath: resourceURL.path)
        else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "xmp" }
        return try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            BuiltInPresetSeed(
                name: url.deletingPathExtension().lastPathComponent,
                data: try Data(contentsOf: url)
            )
        }
    }

    private func refreshPresetLibrary() throws {
        presetLibrary = try store.listPresets()
        presetLibraryErrorMessage = nil
    }

    private func applyPreset(_ stored: StoredXMPPreset) {
        guard canEdit else {
            statusMessage = "プリセットを適用する写真を選択してください。"
            return
        }
        finishSliderGesture()
        flushPendingEditSave()
        mutateEditSnapshot {
            $0 = $0.applying(preset: stored)
        }
        let unsupported = stored.preset.compatibility.filter { $0.level == .unsupported }.count
        statusMessage = "\(presetDisplayName(for: stored))を適用しました（未対応 \(unsupported)項目）。"
    }

    private func mutateEditSnapshot(_ mutation: (inout PhotoEditSnapshot) -> Void) {
        guard canEdit,
              let assetID = selectedAssetID,
              !loadBlockedAssetIDs.contains(assetID)
        else { return }
        let before = editSnapshot
        var updated = before
        mutation(&updated)
        guard updated != before, let asset = assetsByID[assetID] else { return }

        editSnapshot = updated
        editStates[assetID] = updated
        editHistory.record(before: before, after: updated, for: assetID)
        refreshHistoryAvailability()
        markEditDirty(updated, for: asset)
        scheduleRender()
    }

    private func restoreSnapshotThroughMutation(_ snapshot: PhotoEditSnapshot, for assetID: String) {
        guard let asset = assetsByID[assetID], !loadBlockedAssetIDs.contains(assetID) else { return }
        editSnapshot = snapshot
        editStates[assetID] = snapshot
        if let recipe = snapshot.backgroundEdit {
            cacheMaskArtifactsIfNeeded(for: recipe)
        }
        refreshHistoryAvailability()
        markEditDirty(snapshot, for: asset)
        scheduleRender()
    }

    /// Undo history survives photo navigation, while the in-memory mask cache
    /// is intentionally photo-scoped. Reload an older recipe's immutable
    /// artifacts before rendering it; any failure leaves capture nil and thus
    /// keeps preview/export fail-closed.
    private func cacheMaskArtifactsIfNeeded(for recipe: BackgroundEditRecipe) {
        guard let inputHash = currentInputSHA256, let info = decodedPhoto?.info else {
            cutoutMaskErrorMessage = "保存済みマスクの入力情報を確認できません。"
            return
        }
        do {
            for subject in recipe.subjects {
                guard cutoutMaskDataByArtifactID[subject.mask.artifactID] == nil else { continue }
                cutoutMaskDataByArtifactID[subject.mask.artifactID] = try store.loadMask(
                    subject.mask,
                    inputSHA256: inputHash,
                    width: info.width,
                    height: info.height,
                    orientation: 1
                )
            }
            cutoutMaskErrorMessage = nil
        } catch {
            cutoutMaskErrorMessage = error.localizedDescription
        }
    }

    private func markEditDirty(_ snapshot: PhotoEditSnapshot, for asset: PhotoAsset) {
        let assetID = asset.id
        let pending = PendingEditSave(assetID: assetID, photoURL: asset.url, snapshot: snapshot)
        unsavedEditStates[assetID] = pending
        pendingEditSave = pending
        setPersistenceStatus(.saving, for: assetID)
        guard saveDebounceTask == nil else { return }
        saveDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard let self else { return }
            self.flushPendingEditSave()
        }
    }

    private func flushPendingEditSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        guard let pendingEditSave else { return }
        self.pendingEditSave = nil
        persist(pendingEditSave)
    }

    private func persist(_ pending: PendingEditSave) {
        do {
            try store.saveEdit(pending.snapshot, for: pending.photoURL)
            editStates[pending.assetID] = pending.snapshot
            if unsavedEditStates[pending.assetID]?.snapshot == pending.snapshot {
                unsavedEditStates.removeValue(forKey: pending.assetID)
            }
            setPersistenceStatus(.saved, for: pending.assetID)
        } catch {
            setPersistenceStatus(.saveFailed(error.localizedDescription), for: pending.assetID)
        }
    }

    private func setPersistenceStatus(_ status: EditPersistenceStatus, for assetID: String) {
        persistenceStatusByAssetID[assetID] = status
        if selectedAssetID == assetID {
            persistenceStatus = status
        }
    }

    private func refreshHistoryAvailability() {
        canUndo = editHistory.canUndo(for: selectedAssetID)
        canRedo = editHistory.canRedo(for: selectedAssetID)
    }

    private func finishSliderGesture() {
        if previewDragSession != nil {
            previewDragSession = nil
            if let settle = renderPump.endDrag() {
                startRender(settle)
            }
        }
        guard let assetID = activeSliderGesturePhotoID else { return }
        let current = editStates[assetID] ?? editSnapshot
        editHistory.endGroup(for: assetID, at: current)
        activeSliderGesturePhotoID = nil
        refreshHistoryAvailability()
    }

    private func saveEditState(for assetID: String?) {
        guard let assetID else { return }
        editStates[assetID] = editSnapshot
    }

    private func restoreEditState(for assetID: String?) {
        guard let assetID, let asset = assetsByID[assetID] else {
            editSnapshot = .neutral
            persistenceStatus = .idle
            refreshHistoryAvailability()
            return
        }
        if let state = editStates[assetID] {
            editSnapshot = state
            persistenceStatus = persistenceStatusByAssetID[assetID] ?? .saved
            refreshHistoryAvailability()
            return
        }

        do {
            let snapshot = try store.loadEdit(for: asset.url)?.snapshot ?? .neutral
            editStates[assetID] = snapshot
            persistenceStatusByAssetID[assetID] = .saved
            persistenceStatus = .saved
        } catch {
            let reason = error.localizedDescription
            loadBlockedAssetIDs.insert(assetID)
            editStates[assetID] = .neutral
            persistenceStatusByAssetID[assetID] = .loadFailed(reason)
            persistenceStatus = .loadFailed(reason)
        }
        editSnapshot = editStates[assetID] ?? .neutral
        refreshHistoryAvailability()
    }
}
