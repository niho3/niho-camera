import Foundation
import NihoCameraCutout
import PhotoCore

actor RenderCoordinator {
    private let renderer = RenderEngine()
    private let detector = CutoutDetector()
    private let composer = CutoutComposer()

    func prepareProductionPreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560,
        quality: SpatialToneQuality = .final
    ) throws -> PreparedPreviewFrame {
        try Task.checkCancellation()
        let frame = try renderer.prepareProductionPreview(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension,
            quality: quality
        )
        try Task.checkCancellation()
        return frame
    }

    /// Reduces the full-resolution decode once into the preview working copy
    /// every preview render then uses (`RenderEngine.makePreviewWorkingCopy`).
    func makePreviewWorkingCopy(
        from decoded: DecodedPhoto,
        maxDimension: CGFloat = 2_560
    ) throws -> DecodedPhoto {
        try Task.checkCancellation()
        let workingCopy = try renderer.makePreviewWorkingCopy(
            from: decoded,
            maxDimension: maxDimension
        )
        try Task.checkCancellation()
        return workingCopy
    }

    /// `drag`: a slider-drag approximation (`PreviewDragSession`). Cancelling
    /// the calling task stops the render at its next step or cube-bake chunk
    /// (`PreviewCancellation`), so a superseded exact render does not hold
    /// this actor for its full duration.
    func preparePreviewFromWorkingCopy(
        workingCopy: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560,
        quality: SpatialToneQuality = .final,
        drag: PreviewDragSession? = nil
    ) async throws -> PreparedPreviewFrame {
        try Task.checkCancellation()
        let cancellation = PreviewCancellation()
        let frame = try await withTaskCancellationHandler {
            // Core Image/Metal objects this render autoreleases (the spatial
            // pass's textures among them) are freed per frame, not whenever
            // the executor thread happens to drain.
            try autoreleasepool {
                try renderer.preparePreviewFromWorkingCopy(
                    workingCopy: workingCopy,
                    settings: settings,
                    maxDimension: maxDimension,
                    quality: quality,
                    drag: drag,
                    cancellation: cancellation
                )
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return frame
    }

    func materializePreview(
        _ frame: PreparedPreviewFrame
    ) throws -> RenderedPreview {
        try Task.checkCancellation()
        return try autoreleasepool { try renderer.materializePreview(frame) }
    }

    func materializeCutoutPreview(
        _ frame: PreparedPreviewFrame,
        recipe: BackgroundEditRecipe,
        maskPNGData: Data
    ) throws -> RenderedPreview {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let image = try composer.compose(
            image: frame.image,
            maskPNGData: maskPNGData,
            background: recipe.background,
            brushStrokes: recipe.brushStrokes
        )
        let composed = PreparedPreviewFrame(
            image: image,
            extent: frame.extent,
            sourceURL: frame.sourceURL,
            graphAndKernelSetupMilliseconds: frame.graphAndKernelSetupMilliseconds,
            maxDimension: frame.maxDimension
        )
        let rendered = try renderer.materializePreview(composed)
        let components = started.duration(to: .now).components
        let elapsed = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return RenderedPreview(
            image: rendered.image,
            durationMilliseconds: elapsed
        )
    }

    func detectCutout(
        decoded: DecodedPhoto,
        inputSHA256: String
    ) async throws -> CutoutDetectionResult {
        try Task.checkCancellation()
        let image = try renderer.prepareFullResolutionOutput(
            decoded: decoded,
            settings: .neutral
        )
        try Task.checkCancellation()
        return try await detector.detect(ciImage: image, inputSHA256: inputSHA256)
    }

    func renderPreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560
    ) throws -> RenderedPreview {
        try Task.checkCancellation()
        return try renderer.renderPreview(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension
        )
    }

    func exportJPEG(
        decoded: DecodedPhoto,
        settings: EditSettings,
        destination: URL,
        protectedSourceURLs: [URL] = []
    ) throws -> Double {
        try Task.checkCancellation()
        return try renderer.exportJPEG(
            decoded: decoded,
            settings: settings,
            destination: destination,
            protectedSourceURLs: protectedSourceURLs
        )
    }

    func exportCutout(
        decoded: DecodedPhoto,
        settings: EditSettings,
        recipe: BackgroundEditRecipe,
        maskPNGData: Data,
        destination: URL,
        format: CutoutOutputFormat,
        protectedSourceURLs: [URL]
    ) throws -> CGSize {
        try Task.checkCancellation()
        let image = try renderer.prepareFullResolutionOutput(
            decoded: decoded,
            settings: settings
        )
        try Task.checkCancellation()
        return try composer.export(
            image: image,
            maskPNGData: maskPNGData,
            background: recipe.background,
            brushStrokes: recipe.brushStrokes,
            destination: destination,
            format: format,
            protectedSourceURLs: protectedSourceURLs
        )
    }
}
