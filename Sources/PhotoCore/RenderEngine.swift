import AppKit
import CoreImage
import Darwin
import Foundation
import ImageIO
import Metal
import os
import UniformTypeIdentifiers

public struct RenderedPreview: @unchecked Sendable {
    public let image: NSImage
    public let durationMilliseconds: Double

    public init(image: NSImage, durationMilliseconds: Double) {
        self.image = image
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Wall-clock phase timings for the exact production render path. Core Image
/// is lazy, so runtime kernel work may occur during materialization even when
/// the graph was assembled earlier. These names deliberately avoid claiming
/// hardware GPU time; Instruments signposts are emitted for deeper profiling.
public struct RenderPhaseTimings: Codable, Equatable, Sendable {
    public let graphAndKernelSetupMilliseconds: Double
    public let materializeAndReadbackMilliseconds: Double
    public let jpegEncodeAndWriteMilliseconds: Double?
    public let atomicInstallMilliseconds: Double?
    public let totalMilliseconds: Double

    public init(
        graphAndKernelSetupMilliseconds: Double,
        materializeAndReadbackMilliseconds: Double,
        jpegEncodeAndWriteMilliseconds: Double? = nil,
        atomicInstallMilliseconds: Double? = nil,
        totalMilliseconds: Double
    ) {
        self.graphAndKernelSetupMilliseconds = graphAndKernelSetupMilliseconds
        self.materializeAndReadbackMilliseconds = materializeAndReadbackMilliseconds
        self.jpegEncodeAndWriteMilliseconds = jpegEncodeAndWriteMilliseconds
        self.atomicInstallMilliseconds = atomicInstallMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

public struct MeasuredRenderedPreview: @unchecked Sendable {
    public let image: NSImage
    public let timings: RenderPhaseTimings

    public init(image: NSImage, timings: RenderPhaseTimings) {
        self.image = image
        self.timings = timings
    }
}

/// Immutable Core Image graph shared by the legacy bitmap fallback and the
/// direct Metal presentation path. Building the graph and materializing it are
/// deliberately separate: the production UI can hand the graph to a drawable
/// without first reading RGBA pixels back to the CPU.
public struct PreparedPreviewFrame: @unchecked Sendable {
    public let image: CIImage
    public let extent: CGRect
    public let sourceURL: URL
    public let graphAndKernelSetupMilliseconds: Double
    public let maxDimension: CGFloat

    public init(
        image: CIImage,
        extent: CGRect,
        sourceURL: URL,
        graphAndKernelSetupMilliseconds: Double,
        maxDimension: CGFloat
    ) {
        self.image = image
        self.extent = extent
        self.sourceURL = sourceURL
        self.graphAndKernelSetupMilliseconds = graphAndKernelSetupMilliseconds
        self.maxDimension = maxDimension
    }
}

public struct PreviewAspectFitGeometry: Equatable, Sendable {
    public let scale: CGFloat
    public let origin: CGPoint
    public let destinationSize: CGSize

    public init(scale: CGFloat, origin: CGPoint, destinationSize: CGSize) {
        self.scale = scale
        self.origin = origin
        self.destinationSize = destinationSize
    }

    public static func fitting(source: CGRect, destinationSize: CGSize) -> Self? {
        guard source.width.isFinite, source.height.isFinite,
              destinationSize.width.isFinite, destinationSize.height.isFinite,
              source.width > 0, source.height > 0,
              destinationSize.width > 0, destinationSize.height > 0
        else {
            return nil
        }
        let scale = min(
            destinationSize.width / source.width,
            destinationSize.height / source.height
        )
        let fitted = CGSize(width: source.width * scale, height: source.height * scale)
        return Self(
            scale: scale,
            origin: CGPoint(
                x: (destinationSize.width - fitted.width) / 2,
                y: (destinationSize.height - fitted.height) / 2
            ),
            destinationSize: destinationSize
        )
    }
}

/// Pure state machine for the direct preview mailbox. It bounds queued work to
/// one in-flight revision and one latest pending revision. Superseded pending
/// revisions are observable instead of silently disappearing from metrics.
public struct LatestPreviewQueueState: Equatable, Sendable {
    public private(set) var latestID: UInt64?
    public private(set) var pendingID: UInt64?
    public private(set) var inFlightID: UInt64?

    public init() {}

    /// Returns the pending request that was coalesced, if any. Duplicate or
    /// out-of-order submissions are ignored.
    @discardableResult
    public mutating func submit(_ id: UInt64) -> UInt64? {
        if let latestID, id <= latestID { return nil }
        let superseded = pendingID
        latestID = id
        pendingID = id
        return superseded
    }

    /// Atomically claims the expected pending revision. A stale view update
    /// cannot accidentally move a different pending revision in flight.
    @discardableResult
    public mutating func beginPending(_ expectedID: UInt64) -> Bool {
        guard inFlightID == nil, pendingID == expectedID else { return false }
        self.pendingID = nil
        inFlightID = expectedID
        return true
    }

    @discardableResult
    public mutating func finish(_ id: UInt64) -> Bool {
        guard inFlightID == id else { return false }
        inFlightID = nil
        return true
    }

    /// Resize/display moves need the current image rendered again without
    /// manufacturing a new user-input revision.
    public mutating func resubmitLatest() {
        guard let latestID else { return }
        pendingID = latestID
    }
}

public enum MetalPreviewRendererError: LocalizedError {
    case commandQueueUnavailable
    case commandBufferUnavailable
    case incompatibleTexture
    case invalidGeometry
    case renderTaskCreationFailed

    public var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            "Metalの描画キューを作成できません。"
        case .commandBufferUnavailable:
            "Metalの描画コマンドを作成できません。"
        case .incompatibleTexture:
            "表示先のMetalテクスチャ形式がプレビュー契約と一致しません。"
        case .invalidGeometry:
            "プレビューの表示寸法が不正です。"
        case .renderTaskCreationFailed:
            "Core ImageのMetal描画タスクを開始できません。"
        }
    }
}

/// One long-lived, Metal-backed Core Image context per preview surface.
/// Export continues to use RenderEngine's isolated cache-free context.
public final class MetalPreviewRenderer: @unchecked Sendable {
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let context: CIContext

    public static var isSupported: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    public init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        context = CIContext(
            mtlCommandQueue: commandQueue,
            options: [
                .workingColorSpace: CGColorSpace(
                    name: CGColorSpace.extendedLinearSRGB
                ) as Any,
                .outputColorSpace: Self.outputColorSpace,
                // Keep the acceptance route cache-free until repeated-photo
                // RSS and eviction gates exist. Export is independently
                // cache-free as well.
                .cacheIntermediates: false,
                .highQualityDownsample: true,
                .name: "PhotoBench.InteractivePreview"
            ]
        )
    }

    public func makeCommandBuffer() throws -> any MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalPreviewRendererError.commandBufferUnavailable
        }
        commandBuffer.label = "PhotoBench.DirectPreview"
        return commandBuffer
    }

    /// Encodes an opaque, SDR sRGB aspect-fit frame. No CPU pixel readback is
    /// performed. The caller owns commit/present and the drawable lifecycle.
    @discardableResult
    public func encodeAspectFit(
        frame: PreparedPreviewFrame,
        to texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws -> CIRenderTask {
        guard texture.textureType == .type2D,
              texture.pixelFormat == Self.pixelFormat,
              texture.width > 0, texture.height > 0
        else {
            throw MetalPreviewRendererError.incompatibleTexture
        }
        let destinationSize = CGSize(width: texture.width, height: texture.height)
        guard let geometry = PreviewAspectFitGeometry.fitting(
            source: frame.extent,
            destinationSize: destinationSize
        ) else {
            throw MetalPreviewRendererError.invalidGeometry
        }

        let cropped = frame.image.cropped(to: frame.extent)
        let normalized = cropped.transformed(
            by: CGAffineTransform(
                translationX: -frame.extent.minX,
                y: -frame.extent.minY
            )
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: geometry.scale, y: geometry.scale)
        )
        let destination = CIRenderDestination(
            mtlTexture: texture,
            commandBuffer: commandBuffer
        )
        destination.colorSpace = Self.outputColorSpace
        destination.alphaMode = .none
        destination.isFlipped = false
        destination.isDithered = false
        destination.isClamped = true
        _ = try context.startTask(toClear: destination)
        let task = try context.startTask(
            toRender: scaled,
            from: scaled.extent,
            to: destination,
            at: geometry.origin
        )
        return task
    }

    public func clearCaches() {
        context.clearCaches()
    }
}

public enum RenderEngineError: LocalizedError {
    case sourceOverwriteForbidden(URL)
    case destinationIsDirectory(URL)
    case renderFailed(URL)
    case previewResolutionExportForbidden(URL)
    case previewResolutionPresentationForbidden(URL)

    public var errorDescription: String? {
        switch self {
        case let .sourceOverwriteForbidden(url):
            "原本は上書きできません。別の保存先を選んでください: \(url.lastPathComponent)"
        case let .destinationIsDirectory(url):
            "フォルダ自体には書き出せません。フォルダ内のファイル名を指定してください: \(url.lastPathComponent)"
        case let .renderFailed(url):
            "画像をレンダーできません: \(url.lastPathComponent)"
        case let .previewResolutionExportForbidden(url):
            "縮小プレビューから原寸書き出しはできません。原本を再読み込みしてください: \(url.lastPathComponent)"
        case let .previewResolutionPresentationForbidden(url):
            "本番表示には原寸デコードが必要です。縮小RAW候補は校正不合格のため使用できません: \(url.lastPathComponent)"
        }
    }
}

/// Controls the explicit final resize used by previews and comparison TIFFs.
public enum TIFFDownsamplingFilter: Sendable {
    case affineTransform
    case lanczos
}

/// Locates the bounded sRGB output transform relative to an optional resize.
/// Production rendering uses `afterDownsampling`: all edits and Lanczos run in
/// extended-linear sRGB, then the bounded transform is the terminal color
/// operation. The legacy case exists only to reproduce schema v1-v3 evidence.
public enum OutputTransformPlacement: Equatable, Sendable {
    case legacyBeforeDownsampling
    case afterDownsampling
}

/// Small relative adjustments around the white point already present in a
/// decoded photo. This is independent of Adobe white-balance metadata.
public enum RelativeColorAdjustment {
    /// Versions the optional relative color stage without changing the
    /// established zero-edit processing fingerprint.
    public static let identifier = "relative-temperature-and-tint-ci-v1"

    static func sanitizedValue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(-100, value))
    }

    static func apply(
        to image: CIImage,
        relativeTemperature: Double,
        relativeTint: Double
    ) -> CIImage {
        let temperature = sanitizedValue(relativeTemperature)
        let tint = sanitizedValue(relativeTint)
        guard temperature != 0 || tint != 0 else { return image }

        let neutral = CIVector(
            x: 6_500 + 30 * temperature,
            y: 0.5 * tint
        )
        let targetNeutral = CIVector(x: 6_500, y: 0)
        guard let filter = CIFilter(name: "CITemperatureAndTint", parameters: [
            kCIInputImageKey: image,
            "inputNeutral": neutral,
            "inputTargetNeutral": targetNeutral
        ]), let output = filter.outputImage else {
            preconditionFailure("Photo Benchの相対色温度・色かぶり調整を画像へ適用できませんでした。")
        }
        return output
    }
}

struct PreparedOutputGraph: @unchecked Sendable {
    let image: CIImage
    let extent: CGRect
}

/// The one-time reduction behind `RenderEngine.makePreviewWorkingCopy`
/// (`PreviewWorkingCopyInfo`): the full-resolution preview's final Lanczos
/// resize, applied to the decoded image instead of the finished render, and
/// rendered once into an RGBA float bitmap so no later preview re-evaluates
/// the full-resolution decode graph (24 MP camera bitmap, lens warp,
/// orientation) or resamples it again. (A private Metal texture instead of
/// the CPU bitmap measured the same per preview on the Mac mini: 77 ms vs
/// 78 ms per Exposure tick, 49 ms vs 51 ms per Shadows tick.)
struct PreviewWorkingRaster {
    static let bytesPerPixel = 4 * MemoryLayout<Float>.size
    /// `context`'s working space and the bitmap's color space, so the render
    /// is a numeric passthrough of working-space values -- the same
    /// convention as `SpatialToneProcessor.renderInput`.
    static let passthroughColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Float intermediates for this single, one-time render (preview renders
    /// keep their own contexts' defaults).
    static var contextOptions: [CIContextOption: Any] {
        [
            .workingColorSpace: passthroughColorSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue),
            .cacheIntermediates: false,
            .name: "PhotoBench.PreviewWorkingCopy"
        ]
    }

    let context: CIContext

    /// `RenderEngine.resize`'s production branch (`.lanczos` with
    /// `.afterDownsampling`: edge clamp, `CILanczosScaleTransform`, crop to
    /// the integral scaled extent) applied to `image` moved to a zero
    /// origin -- the identical scale and pixel grid the full-resolution
    /// preview ends on. An image already within `maxDimension` is only moved,
    /// never enlarged.
    static func reduce(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let extent = image.extent
        let normalized = extent.origin == .zero
            ? image
            : image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let bounds = normalized.extent
        let longest = max(bounds.width, bounds.height)
        guard longest > maxDimension else { return normalized }
        let scale = maxDimension / longest
        let scaledExtent = bounds.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        return normalized.clampedToExtent().applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ]
        ).cropped(to: scaledExtent)
    }

    /// Renders `image` (a finite extent at the origin) once into an RGBAf
    /// bitmap and wraps it back as a `CIImage` tagged `colorSpace`: `nil`
    /// keeps the values numeric, exactly like the decoder's camera image; a
    /// color space (non-RAW: `passthroughColorSpace`) keeps them converted
    /// correctly by any context. `nil` when the image has no usable extent.
    func materialize(_ image: CIImage, taggedAs colorSpace: CGColorSpace?) -> CIImage? {
        guard let rendered = renderPixels(image) else { return nil }
        return CIImage(
            bitmapData: rendered.data,
            bytesPerRow: rendered.rowBytes,
            size: CGSize(width: rendered.width, height: rendered.height),
            format: .RGBAf,
            colorSpace: colorSpace
        )
    }

    /// RGBA float pixels (premultiplied, rows top to bottom) of one
    /// `renderPixels` call, in `passthroughColorSpace`'s numbers.
    struct RenderedPixels: @unchecked Sendable {
        let data: Data
        let width: Int
        let height: Int
        let rowBytes: Int
    }

    /// `materialize`'s one-time render, returning the bitmap itself
    /// (`WorkingCopyRenderer` encodes it instead of wrapping it). `nil` when
    /// the image has no usable extent.
    func renderPixels(_ image: CIImage) -> RenderedPixels? {
        let bounds = image.extent.integral
        guard bounds.origin == .zero,
              let width = CoreImageDecoder.validatedPixelDimension(bounds.width),
              let height = CoreImageDecoder.validatedPixelDimension(bounds.height)
        else {
            return nil
        }
        let rowBytes = width * Self.bytesPerPixel
        let byteCount = rowBytes * height
        guard let pixels = malloc(byteCount) else { return nil }
        context.render(
            image,
            toBitmap: pixels,
            rowBytes: rowBytes,
            bounds: bounds,
            format: .RGBAf,
            colorSpace: Self.passthroughColorSpace
        )
        return RenderedPixels(
            data: Data(bytesNoCopy: pixels, count: byteCount, deallocator: .free),
            width: width,
            height: height,
            rowBytes: rowBytes
        )
    }
}

public final class RenderEngine: @unchecked Sendable {
    public static let processingIdentifier =
        "extended-linear-srgb-edits-resize-before-final-srgb-v1"
    public static let legacyProcessingIdentifier =
        "extended-linear-srgb-edits-final-srgb-then-resize-v1"
    private static let performanceLog = OSLog(
        subsystem: "life.niho.photobench",
        category: "render"
    )
    /// Preview and export must never share an intermediate cache. Both remain
    /// uncached in this slice; a later preview-only cache can be enabled without
    /// changing export output or hash stability.
    private let previewContext: CIContext
    private let exportContext: CIContext
    /// Preview-side only (`makePreviewWorkingCopy`): never shared with export.
    private let workingCopyRaster: PreviewWorkingRaster
    /// Preview-side only (`preparePreviewFromWorkingCopy`): the last spatial
    /// pass over the working copy. Export never reads or writes it.
    let previewSpatialPassCache = SpatialPassCache()
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            let options: [CIContextOption: Any] = [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .cacheIntermediates: false
            ]
            previewContext = CIContext(mtlDevice: device, options: options)
            exportContext = CIContext(mtlDevice: device, options: options)
            workingCopyRaster = PreviewWorkingRaster(
                context: CIContext(mtlDevice: device, options: PreviewWorkingRaster.contextOptions)
            )
        } else {
            let options: [CIContextOption: Any] = [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .cacheIntermediates: false
            ]
            previewContext = CIContext(options: options)
            exportContext = CIContext(options: options)
            workingCopyRaster = PreviewWorkingRaster(
                context: CIContext(options: PreviewWorkingRaster.contextOptions)
            )
        }
        precondition(previewContext !== exportContext)
        precondition(workingCopyRaster.context !== exportContext)
    }

    var hasIsolatedPreviewAndExportContexts: Bool {
        previewContext !== exportContext
    }

    public func renderPreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560
    ) throws -> RenderedPreview {
        let measured = try renderPreviewMeasured(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension
        )
        return RenderedPreview(
            image: measured.image,
            durationMilliseconds: measured.timings.totalMilliseconds
        )
    }

    public func renderPreviewMeasured(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560
    ) throws -> MeasuredRenderedPreview {
        let totalStarted = ContinuousClock.now
        let frame = try preparePreview(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension
        )

        let materialized = try materializePreview(frame)
        let timings = RenderPhaseTimings(
            graphAndKernelSetupMilliseconds: frame.graphAndKernelSetupMilliseconds,
            materializeAndReadbackMilliseconds: materialized.durationMilliseconds,
            totalMilliseconds: Self.milliseconds(totalStarted.duration(to: .now))
        )
        return MeasuredRenderedPreview(image: materialized.image, timings: timings)
    }

    /// Builds the exact preview graph used by both presentation routes. This
    /// general API remains available to benchmark/calibration paths that
    /// intentionally exercise an interactive decode candidate.
    public func preparePreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560,
        quality: SpatialToneQuality = .final
    ) throws -> PreparedPreviewFrame {
        guard maxDimension.isFinite, maxDimension > 0 else {
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        return try preparePreviewFrame(
            decoded: decoded,
            settings: settings,
            resizeMaxDimension: maxDimension,
            frameMaxDimension: maxDimension,
            quality: quality
        )
    }

    /// `preparePreview`'s body, shared with `preparePreviewFromWorkingCopy`:
    /// the same production graph (`.lanczos`, `.afterDownsampling`), with the
    /// final resize optional so a working copy already on the preview's
    /// pixel grid is not resampled a second time.
    private func preparePreviewFrame(
        decoded: DecodedPhoto,
        settings: EditSettings,
        resizeMaxDimension: CGFloat?,
        frameMaxDimension: CGFloat,
        quality: SpatialToneQuality,
        options: PreviewRenderOptions = .standard
    ) throws -> PreparedPreviewFrame {
        os_signpost(.begin, log: Self.performanceLog, name: "PreviewGraph")
        PreviewDiagnostics.beginFrame()
        let graphStarted = ContinuousClock.now
        let output = try makeOutputGraph(
            decoded: decoded,
            settings: settings,
            maxDimension: resizeMaxDimension,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling,
            quality: quality,
            options: options
        )
        let image = output.image
        let extent = output.extent
        let graphMilliseconds = Self.milliseconds(graphStarted.duration(to: .now))
        os_signpost(.end, log: Self.performanceLog, name: "PreviewGraph")
        PreviewDiagnostics.endFrame("prepare", milliseconds: graphMilliseconds)

        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0
        else {
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        return PreparedPreviewFrame(
            image: image,
            extent: extent,
            sourceURL: decoded.sourceURL,
            graphAndKernelSetupMilliseconds: graphMilliseconds,
            maxDimension: frameMaxDimension
        )
    }

    /// Fail-closed entry point for the production UI. Preview-scale RAW
    /// candidates remain calibration-only until a candidate passes the formal
    /// parity gate. A preview working copy is refused here too: it has its
    /// own entry point, `preparePreviewFromWorkingCopy`.
    public func prepareProductionPreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560,
        quality: SpatialToneQuality = .final
    ) throws -> PreparedPreviewFrame {
        guard decoded.info.intent == .fullResolution,
              decoded.info.requestedMaximumDimension == nil,
              !decoded.info.isRAW || decoded.info.appliedScaleFactor == 1,
              decoded.info.previewWorkingCopy == nil
        else {
            throw RenderEngineError.previewResolutionPresentationForbidden(
                decoded.sourceURL
            )
        }
        return try preparePreview(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension,
            quality: quality
        )
    }

    /// Reduces a full-resolution decode once into a preview working copy
    /// (`PreviewWorkingCopyInfo`): RAW keeps its full-resolution demosaic,
    /// lens correction and orientation and reduces the resulting camera
    /// image (`AdobeBaseRenderer.Handle.downscaled`); non-RAW reduces its
    /// input image in the extended-linear-sRGB working space. The reduction
    /// is the full-resolution preview's own final Lanczos step, moved to the
    /// front of the pipeline and materialized as RGBA float pixels, so
    /// `preparePreviewFromWorkingCopy` then runs every edit (spatial
    /// Highlights/Shadows/Texture/Clarity included, whose `scalePx` and
    /// adaptive statistics follow the processed image's size) on about a
    /// fifth of a 24 MP photo's pixels. The returned photo can only be
    /// previewed: export and `prepareProductionPreview` reject it; keep the
    /// full-resolution `decoded` for export.
    public func makePreviewWorkingCopy(
        from decoded: DecodedPhoto,
        maxDimension: CGFloat = 2_560
    ) throws -> DecodedPhoto {
        // A new photo: drop the previous copy's spatial pass (~70 MB).
        previewSpatialPassCache.removeAll()
        guard maxDimension.isFinite, maxDimension >= 1,
              maxDimension == maxDimension.rounded(.down)
        else {
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        guard Self.isFullResolutionDecode(decoded) else {
            throw RenderEngineError.previewResolutionPresentationForbidden(decoded.sourceURL)
        }
        let raster = workingCopyRaster
        os_signpost(.begin, log: Self.performanceLog, name: "PreviewWorkingCopy")
        defer { os_signpost(.end, log: Self.performanceLog, name: "PreviewWorkingCopy") }
        let started = ContinuousClock.now

        let image: CIImage
        let workingExtent: CGRect
        let handle: AdobeBaseRenderer.Handle?
        if let source = decoded.adobeBase {
            guard let reduced = source.downscaled(maxDimension: maxDimension, using: raster) else {
                throw RenderEngineError.renderFailed(decoded.sourceURL)
            }
            handle = reduced
            image = reduced.image(userExposureEV: 0)
            workingExtent = reduced.cameraImage.extent
        } else {
            guard let reduced = raster.materialize(
                PreviewWorkingRaster.reduce(decoded.image, maxDimension: maxDimension),
                taggedAs: PreviewWorkingRaster.passthroughColorSpace
            ) else {
                throw RenderEngineError.renderFailed(decoded.sourceURL)
            }
            handle = nil
            image = reduced
            workingExtent = reduced.extent
        }
        // The long edge must be the bound (a reduced copy; `.integral` may
        // round a floating-point product up by one pixel, exactly as the
        // full-resolution preview's own resize would) or the source's own.
        let info = decoded.info
        let sourceLongest = max(info.width, info.height)
        let expectedLongest = min(sourceLongest, Int(maxDimension))
        guard workingExtent.origin == .zero,
              let width = CoreImageDecoder.validatedPixelDimension(workingExtent.width),
              let height = CoreImageDecoder.validatedPixelDimension(workingExtent.height),
              abs(max(width, height) - expectedLongest) <= 1
        else {
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        return DecodedPhoto(
            sourceURL: decoded.sourceURL,
            image: image,
            metadata: decoded.metadata,
            info: DecodeInfo(
                backend: info.backend,
                width: width,
                height: height,
                durationMilliseconds: info.durationMilliseconds,
                isRAW: info.isRAW,
                isBoundedSRGBRaster: info.isBoundedSRGBRaster,
                cameraMake: info.cameraMake,
                cameraModel: info.cameraModel,
                calibrationID: info.calibrationID,
                calibrationLabel: info.calibrationLabel,
                intent: info.intent,
                requestedMaximumDimension: info.requestedMaximumDimension,
                nativeWidth: info.nativeWidth,
                nativeHeight: info.nativeHeight,
                appliedScaleFactor: info.appliedScaleFactor,
                asShotWhiteXY: info.asShotWhiteXY,
                lensCorrection: info.lensCorrection,
                previewWorkingCopy: PreviewWorkingCopyInfo(
                    maxDimension: Int(maxDimension),
                    sourceWidth: info.width,
                    sourceHeight: info.height,
                    durationMilliseconds: Self.milliseconds(started.duration(to: .now)),
                    byteCount: width * height * PreviewWorkingRaster.bytesPerPixel
                )
            ),
            adobeBase: handle
        )
    }

    /// Production preview entry point for a preview working copy
    /// (`makePreviewWorkingCopy`). Builds exactly `preparePreview`'s graph;
    /// at the copy's own `maxDimension` the final resize is skipped, since
    /// the copy already is that resize's pixel grid. Only working copies of
    /// full-resolution decodes are accepted, and a reduced copy cannot serve
    /// a preview larger than it was reduced to.
    ///
    /// The spatial pass's result is kept (`SpatialPassCache`, this engine's
    /// working copy only) and reused whenever a later frame would compute it
    /// from exactly the same input, so a frame is identical with or without
    /// the reuse. `drag`: the frame is a slider-drag approximation instead
    /// (`PreviewDragSession`); render the same settings again without it to
    /// get the exact frame. `cancellation`: once cancelled, the render stops
    /// at its next step or cube-bake chunk and throws `CancellationError`.
    public func preparePreviewFromWorkingCopy(
        workingCopy: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560,
        quality: SpatialToneQuality = .final,
        drag: PreviewDragSession? = nil,
        cancellation: PreviewCancellation? = nil
    ) throws -> PreparedPreviewFrame {
        guard let provenance = workingCopy.info.previewWorkingCopy,
              workingCopy.info.intent == .fullResolution,
              workingCopy.info.requestedMaximumDimension == nil,
              !workingCopy.info.isRAW || workingCopy.info.appliedScaleFactor == 1
        else {
            throw RenderEngineError.previewResolutionPresentationForbidden(
                workingCopy.sourceURL
            )
        }
        guard maxDimension.isFinite, maxDimension > 0 else {
            throw RenderEngineError.renderFailed(workingCopy.sourceURL)
        }
        let workingCopyMaxDimension = CGFloat(provenance.maxDimension)
        if provenance.isReduced, maxDimension > workingCopyMaxDimension {
            throw RenderEngineError.previewResolutionPresentationForbidden(
                workingCopy.sourceURL
            )
        }
        let resizeMaxDimension: CGFloat? =
            provenance.isReduced && maxDimension == workingCopyMaxDimension ? nil : maxDimension
        let options = PreviewRenderOptions(
            toneCubeDimension: drag == nil ? AdobeBaseRenderer.cubeDimension : AdobeBaseRenderer.dragCubeDimension,
            dragSession: drag,
            spatialCache: previewSpatialPassCache,
            cancellation: cancellation
        )
        return try preparePreviewFrame(
            decoded: workingCopy,
            settings: settings,
            resizeMaxDimension: resizeMaxDimension,
            frameMaxDimension: maxDimension,
            quality: quality,
            options: options
        )
    }

    /// Existing CPU bitmap path retained as the default and one-way runtime
    /// fallback until the direct route passes visible-window acceptance gates.
    public func materializePreview(
        _ frame: PreparedPreviewFrame
    ) throws -> RenderedPreview {
        os_signpost(.begin, log: Self.performanceLog, name: "PreviewMaterialize")
        let materializeStarted = ContinuousClock.now
        guard let cgImage = previewContext.createCGImage(
            frame.image,
            from: frame.extent,
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else {
            os_signpost(.end, log: Self.performanceLog, name: "PreviewMaterialize")
            throw RenderEngineError.renderFailed(frame.sourceURL)
        }
        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: frame.extent.width, height: frame.extent.height)
        )
        let materializeMilliseconds = Self.milliseconds(
            materializeStarted.duration(to: .now)
        )
        os_signpost(.end, log: Self.performanceLog, name: "PreviewMaterialize")
        return RenderedPreview(
            image: nsImage,
            durationMilliseconds: materializeMilliseconds
        )
    }

    public func exportJPEG(
        decoded: DecodedPhoto,
        settings: EditSettings,
        destination: URL,
        quality: Double = 0.92,
        protectedSourceURLs: [URL] = []
    ) throws -> Double {
        try exportJPEGMeasured(
            decoded: decoded,
            settings: settings,
            destination: destination,
            quality: quality,
            protectedSourceURLs: protectedSourceURLs
        ).totalMilliseconds
    }

    /// Full-resolution, orientation-normalized sRGB output before encoding.
    /// Background removal consumes this small public hook so it does not
    /// duplicate or alter the RAW/XMP rendering pipeline.
    public func prepareFullResolutionOutput(
        decoded: DecodedPhoto,
        settings: EditSettings
    ) throws -> CIImage {
        try Self.requireFullResolutionDecodeForExport(decoded)
        return try makeOutputGraph(
            decoded: decoded,
            settings: settings,
            maxDimension: nil,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        ).image
    }

    public func exportJPEGMeasured(
        decoded: DecodedPhoto,
        settings: EditSettings,
        destination: URL,
        quality: Double = 0.92,
        protectedSourceURLs: [URL] = []
    ) throws -> RenderPhaseTimings {
        try Self.requireFullResolutionDecodeForExport(decoded)
        let protectedSources = [decoded.sourceURL] + protectedSourceURLs
        guard !Self.isExistingDirectory(destination) else {
            throw RenderEngineError.destinationIsDirectory(destination)
        }
        guard !Self.destinationAliasesAnySource(
            destination,
            sources: protectedSources
        ) else {
            throw RenderEngineError.sourceOverwriteForbidden(destination)
        }
        let totalStarted = ContinuousClock.now

        os_signpost(.begin, log: Self.performanceLog, name: "JPEGGraph")
        let graphStarted = ContinuousClock.now
        let output = try makeOutputGraph(
            decoded: decoded,
            settings: settings,
            maxDimension: nil,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        let image = output.image
        let graphMilliseconds = Self.milliseconds(graphStarted.duration(to: .now))
        os_signpost(.end, log: Self.performanceLog, name: "JPEGGraph")

        os_signpost(.begin, log: Self.performanceLog, name: "JPEGMaterialize")
        let materializeStarted = ContinuousClock.now
        guard let cgImage = exportContext.createCGImage(
            image,
            from: image.extent.integral,
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else {
            os_signpost(.end, log: Self.performanceLog, name: "JPEGMaterialize")
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        let materializeMilliseconds = Self.milliseconds(
            materializeStarted.duration(to: .now)
        )
        os_signpost(.end, log: Self.performanceLog, name: "JPEGMaterialize")

        os_signpost(.begin, log: Self.performanceLog, name: "JPEGEncode")
        let encodeStarted = ContinuousClock.now
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            guard let imageDestination = CGImageDestinationCreateWithURL(
                temporary as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }

            var properties = Self.safeJPEGMetadata(
                from: decoded.metadata,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height
            )
            properties[kCGImageDestinationLossyCompressionQuality as String] = min(max(quality, 0), 1)
            properties[kCGImagePropertyOrientation as String] = 1
            properties[kCGImageDestinationEmbedThumbnail as String] = true
            CGImageDestinationAddImage(imageDestination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(imageDestination) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            os_signpost(.end, log: Self.performanceLog, name: "JPEGEncode")
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let encodeMilliseconds = Self.milliseconds(encodeStarted.duration(to: .now))
        os_signpost(.end, log: Self.performanceLog, name: "JPEGEncode")

        os_signpost(.begin, log: Self.performanceLog, name: "JPEGInstall")
        let installStarted = ContinuousClock.now
        do {
            try Self.installAtomically(
                temporary: temporary,
                destination: destination,
                protectedSources: protectedSources
            )
        } catch {
            os_signpost(.end, log: Self.performanceLog, name: "JPEGInstall")
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let installMilliseconds = Self.milliseconds(installStarted.duration(to: .now))
        os_signpost(.end, log: Self.performanceLog, name: "JPEGInstall")
        return RenderPhaseTimings(
            graphAndKernelSetupMilliseconds: graphMilliseconds,
            materializeAndReadbackMilliseconds: materializeMilliseconds,
            jpegEncodeAndWriteMilliseconds: encodeMilliseconds,
            atomicInstallMilliseconds: installMilliseconds,
            totalMilliseconds: Self.milliseconds(totalStarted.duration(to: .now))
        )
    }

    /// Lightroom基準TIFFと同じsRGBで、量子化誤差を抑えた16bit比較用TIFFを書き出す。
    /// 比較を高速化する場合だけmaxDimensionを指定し、本番書き出しではnilを使う。`quality`も
    /// 同じ位置づけ(既定`.final`、`photobench-render --quality interactive`のような
    /// 計測目的の上書きだけを想定) -- 本番のJPEG書き出し(`exportJPEG`/`exportJPEGMeasured`)
    /// にはこのパラメータ自体が存在せず、常に`.final`。
    public func exportTIFF(
        decoded: DecodedPhoto,
        settings: EditSettings,
        destination: URL,
        maxDimension: CGFloat? = nil,
        downsamplingFilter: TIFFDownsamplingFilter = .affineTransform,
        outputTransformPlacement: OutputTransformPlacement = .afterDownsampling,
        protectedSourceURLs: [URL] = [],
        allowDestinationReplacement: Bool = true,
        quality: SpatialToneQuality = .final
    ) throws -> Double {
        // A preview working copy is never an output source, not even for a
        // comparison TIFF with an explicit `maxDimension`.
        guard decoded.info.previewWorkingCopy == nil else {
            throw RenderEngineError.previewResolutionExportForbidden(decoded.sourceURL)
        }
        if maxDimension == nil {
            try Self.requireFullResolutionDecodeForExport(decoded)
        }
        let protectedSources = [decoded.sourceURL] + protectedSourceURLs
        guard !Self.isExistingDirectory(destination) else {
            throw RenderEngineError.destinationIsDirectory(destination)
        }
        guard !Self.destinationAliasesAnySource(
            destination,
            sources: protectedSources
        ) else {
            throw RenderEngineError.sourceOverwriteForbidden(destination)
        }
        let started = ContinuousClock.now
        let output = try makeOutputGraph(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension,
            downsamplingFilter: downsamplingFilter,
            outputTransformPlacement: outputTransformPlacement,
            quality: quality
        )
        let image = output.image

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            try exportContext.writeTIFFRepresentation(
                of: image,
                to: temporary,
                format: .RGBA16,
                colorSpace: outputColorSpace,
                options: [:]
            )
            try Self.installAtomically(
                temporary: temporary,
                destination: destination,
                protectedSources: protectedSources,
                allowDestinationReplacement: allowDestinationReplacement
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    /// Full-size output must never inherit an interactive decode or a
    /// preview working copy. The app is required to reopen the protected
    /// source with `.fullResolution` (and to keep that decode for export).
    /// Calibration TIFFs remain allowed when an explicit comparison dimension
    /// is supplied, because those artifacts intentionally exercise both paths.
    private static func requireFullResolutionDecodeForExport(
        _ decoded: DecodedPhoto
    ) throws {
        guard isFullResolutionDecode(decoded) else {
            throw RenderEngineError.previewResolutionExportForbidden(decoded.sourceURL)
        }
    }

    /// Whether `decoded` is exactly a full-resolution decode: the export
    /// contract, and the only input `makePreviewWorkingCopy` accepts.
    private static func isFullResolutionDecode(_ decoded: DecodedPhoto) -> Bool {
        guard decoded.info.previewWorkingCopy == nil,
              decoded.info.intent == .fullResolution,
              decoded.info.requestedMaximumDimension == nil
        else {
            return false
        }
        guard decoded.info.nativeWidth > 0, decoded.info.nativeHeight > 0 else {
            return false
        }
        guard let imageWidth = CoreImageDecoder.validatedPixelDimension(
            decoded.image.extent.width
        ), let imageHeight = CoreImageDecoder.validatedPixelDimension(
            decoded.image.extent.height
        ) else {
            return false
        }
        guard decoded.info.width == decoded.info.nativeWidth,
              decoded.info.height == decoded.info.nativeHeight,
              imageWidth == decoded.info.nativeWidth,
              imageHeight == decoded.info.nativeHeight
        else {
            return false
        }
        if decoded.info.isRAW, decoded.info.appliedScaleFactor != 1 {
            return false
        }
        return true
    }

    static func installAtomically(
        temporary: URL,
        destination: URL,
        protectedSources: [URL],
        allowDestinationReplacement: Bool = true
    ) throws {
        // Re-check immediately before replacement as well. The early public API
        // guard avoids needless rendering, while this prevents a destination
        // file or parent-directory alias introduced during a long render from
        // redirecting the final install onto a protected original.
        guard !isExistingDirectory(destination) else {
            throw RenderEngineError.destinationIsDirectory(destination)
        }
        guard !destinationAliasesAnySource(destination, sources: protectedSources) else {
            throw RenderEngineError.sourceOverwriteForbidden(destination)
        }
        if !allowDestinationReplacement {
            // `link(2)` is an atomic no-replace publication: an existing file,
            // directory, or symlink makes the operation fail with EEXIST. This
            // is used for immutable evidence, while user exports retain their
            // explicit replacement behavior through the default branch.
            try synchronizeFile(temporary)
            try FileManager.default.linkItem(at: temporary, to: destination)
            try FileManager.default.removeItem(at: temporary)
            try synchronizeDirectory(destination.deletingLastPathComponent())
        } else if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func synchronizeFile(_ file: URL) throws {
        let descriptor = Darwin.open(file.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { Darwin.close(descriptor) }
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { Darwin.close(descriptor) }
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Rejects path aliases before any temporary output is created. A textual
    /// URL comparison is insufficient on the default case-insensitive APFS and
    /// also misses symlinks and hard links to the original.
    static func destinationAliasesSource(_ destination: URL, source: URL) -> Bool {
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        if resolvedSource.path.compare(
            resolvedDestination.path,
            options: [.caseInsensitive, .literal]
        ) == .orderedSame {
            return true
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: resolvedSource.path),
              fileManager.fileExists(atPath: resolvedDestination.path),
              let sourceIdentifier = try? resolvedSource.resourceValues(
                  forKeys: [.fileResourceIdentifierKey]
              ).fileResourceIdentifier as? NSObject,
              let destinationIdentifier = try? resolvedDestination.resourceValues(
                  forKeys: [.fileResourceIdentifierKey]
              ).fileResourceIdentifier as? NSObject
        else {
            return false
        }
        return sourceIdentifier.isEqual(destinationIdentifier)
    }

    static func destinationAliasesAnySource(_ destination: URL, sources: [URL]) -> Bool {
        sources.contains { destinationAliasesSource(destination, source: $0) }
    }

    private static func safeJPEGMetadata(
        from source: [String: Any],
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [String: Any] {
        var result: [String: Any] = [:]

        var exif = source[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = pixelWidth
        exif[kCGImagePropertyExifPixelYDimension as String] = pixelHeight
        exif[kCGImagePropertyExifColorSpace as String] = 1 // sRGB
        result[kCGImagePropertyExifDictionary as String] = exif
        if let exifAux = source[kCGImagePropertyExifAuxDictionary as String] {
            result[kCGImagePropertyExifAuxDictionary as String] = exifAux
        }
        if let gps = source[kCGImagePropertyGPSDictionary as String] {
            result[kCGImagePropertyGPSDictionary as String] = gps
        }

        if let sourceTIFF = source[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            let allowedKeys = [
                kCGImagePropertyTIFFMake as String,
                kCGImagePropertyTIFFModel as String,
                kCGImagePropertyTIFFDateTime as String,
                kCGImagePropertyTIFFArtist as String,
                kCGImagePropertyTIFFSoftware as String,
                kCGImagePropertyTIFFCopyright as String
            ]
            var tiff = sourceTIFF.filter { allowedKeys.contains($0.key) }
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        } else {
            result[kCGImagePropertyTIFFDictionary as String] = [
                kCGImagePropertyTIFFOrientation as String: 1
            ]
        }

        return result
    }

    /// Non-RAW entry point: `source` is a plain working-space (extended
    /// linear sRGB) image with no Adobe base pipeline behind it (a decoded
    /// JPEG/HEIC/PNG/TIFF, or a synthetic test image). `docs/
    /// PHASE2_DEVELOP_PIPELINE.md`'s "非RAW" path -- Exposure/Contrast/
    /// Whites/Blacks/Parametric/Point curve/Highlights2012/Shadows2012
    /// (`applyNonRAWStageP`) and Vibrance/Saturation/HSL/Color Grading/
    /// Calibration (`applyNonRAWStageQ`) all run through `ToneOps`/
    /// `SpatialToneOps`/`ColorOps` here instead of the legacy
    /// `CIExposureAdjust`/`BasicToneModel`/`toneCurveKernel`/`CIVibrance`/
    /// `CIColorControls`/`PerceptualColorMixer` approximations. RAW photos
    /// (`decoded.adobeBase != nil`) never reach this function -- see
    /// `baseImage(decoded:settings:)`, which calls `AdobeBaseRenderer.
    /// Handle.image(settings:)` instead (that RAW path's own Stage P
    /// mirrors this one, including the H/S spatial split).
    /// `sourceURL`: `decoded.sourceURL` when called from `baseImage(decoded:
    /// settings:)`, `nil` from every direct test call site -- used only to
    /// cache `highlightRatioBase` (round2 set A, `.photobench/phase2/
    /// spatial-adaptive/model.md`) per photo; `nil` computes it fresh from
    /// `source` every call instead of skipping it, since a bare `CIImage`
    /// has no other stable identity to cache against. `needsSpatial` gates
    /// this so a photo whose settings never touch Highlights/Shadows/
    /// Texture/Clarity never pays for it. `previewWorkingCopyLongEdge`
    /// (non-nil only for a preview working copy's pixels) joins that cache
    /// key, so the statistic of a reduced copy is never served to the
    /// full-resolution decode export reads.
    func apply(
        settings: EditSettings,
        to source: CIImage,
        sourceURL: URL? = nil,
        quality: SpatialToneQuality = .final,
        previewWorkingCopyLongEdge: Int? = nil
    ) -> CIImage {
        // `.standard`: no cancellation token, so this cannot throw.
        try! apply(
            settings: settings, to: source, sourceURL: sourceURL, quality: quality,
            previewWorkingCopyLongEdge: previewWorkingCopyLongEdge, options: .standard
        )
    }

    /// `apply(settings:to:...)` under the preview's `options`
    /// (`PreviewRenderOptions`; the statistics here are per photo, not per
    /// setting, so a drag session has nothing to freeze).
    func apply(
        settings: EditSettings,
        to source: CIImage,
        sourceURL: URL?,
        quality: SpatialToneQuality,
        previewWorkingCopyLongEdge: Int?,
        options: PreviewRenderOptions
    ) throws -> CIImage {
        try options.checkCancellation()
        var image = RelativeColorAdjustment.apply(
            to: source,
            relativeTemperature: settings.relativeTemperature,
            relativeTint: settings.relativeTint
        )
        let stats = SpatialToneOps.needsSpatial(settings)
            ? nonRAWAdaptiveStats(
                source: source, sourceURL: sourceURL, quality: quality,
                previewWorkingCopyLongEdge: previewWorkingCopyLongEdge
            ) : nil
        image = try applyNonRAWStageP(
            settings: settings, to: image, source: source, adaptiveStats: stats, quality: quality, options: options
        )
        image = try applyNonRAWStageQ(settings: settings, to: image, adaptiveStats: stats, quality: quality, options: options)
        return image
    }

    // MARK: - Non-RAW image-adaptive Highlights2012/Shadows2012
    // (`.photobench/phase2/nonraw-hs/model.md`)

    /// Keyed by `sourceURL` only, **not** settings -- unlike RAW's
    /// preHS-based `Handle.adaptiveStats(for:)`, non-RAW's law reads
    /// `full_highlightRatio`/`full_p90` straight off the *unmodified input*
    /// (`model.md` §5/§8 item 1: non-RAW's spatial pass [S] already runs
    /// *first*, `s-p1-p2`, so "the image H/S actually sees" already *is* the
    /// input -- no preHS render needed at all, unlike RAW). This makes the
    /// statistic settings-independent: computed once per photo, never
    /// recomputed for any slider move (RAW's preHS version must recompute
    /// whenever a non-H/S/Texture/Clarity slider changes).
    /// `quality` joins `sourceURL` in the key for the same reason
    /// `AdobeBaseRenderer.StatsCacheKey` gained it: an `.interactive`
    /// (halved-resolution) statistic must never be served back to a later
    /// `.final` (export) request.
    struct NonRAWStatsCacheKey: Hashable {
        var url: URL
        var quality: SpatialToneQuality
        var previewWorkingCopyLongEdge: Int? = nil
    }
    private static let nonRawStatsCacheLock = NSLock()
    nonisolated(unsafe) private static var nonRawStatsCache: [NonRAWStatsCacheKey: SpatialAdaptiveStats.Stats] = [:]
    /// `model.md` §1.4/§5: the input JPEG's own sRGB primaries (Rec.709 luma
    /// weights), *not* `SpatialToneOps.ppLuma` (RAW's ProPhoto weights) --
    /// `source` here is still the plain working-space input, never converted
    /// to ProPhoto.
    private static let nonRAWLumaWeights = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    private func nonRAWAdaptiveStats(
        source: CIImage, sourceURL: URL?, quality: SpatialToneQuality = .final,
        previewWorkingCopyLongEdge: Int? = nil
    ) -> SpatialAdaptiveStats.Stats {
        let cacheKey = sourceURL.map {
            NonRAWStatsCacheKey(
                url: $0, quality: quality, previewWorkingCopyLongEdge: previewWorkingCopyLongEdge
            )
        }
        if let cacheKey {
            Self.nonRawStatsCacheLock.lock()
            if let cached = Self.nonRawStatsCache[cacheKey] {
                Self.nonRawStatsCacheLock.unlock()
                return cached
            }
            Self.nonRawStatsCacheLock.unlock()
        }

        let diagnosticsEnabled = ProcessInfo.processInfo.environment["PHOTO_BENCH_SPATIAL_DIAG"] != nil
        let startTime = diagnosticsEnabled ? DispatchTime.now() : nil

        let longEdge = AdobeBaseRenderer.highlightRatioBaseLongEdge(for: quality)
        let stats = PreviewDiagnostics.measure("stats") {
            SpatialAdaptiveStats.computeStats(
                image: source, longEdge: longEdge, lumaWeights: Self.nonRAWLumaWeights
            )
        }
        if let startTime {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000
            // kH/kS/sShift themselves omitted here, same reasoning as
            // `AdobeBaseRenderer.Handle.adaptiveStats`'s doc comment --
            // printed downstream in `applySpatialToneOps`'s own diagnostic
            // line instead. The raw statistics (including `highlightRatioBase`,
            // now non-RAW's kH input too) are cheap and printed eagerly here.
            let message = "RenderEngine.nonRAWAdaptiveStats: quality=\(quality) baseHighlightRatio=\(stats.highlightRatioBase) fullHighlightRatio=\(stats.fullHighlightRatio) fullP90=\(stats.fullP90) "
                + "(\(String(format: "%.2f", elapsedMs))ms)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }

        if let cacheKey {
            Self.nonRawStatsCacheLock.lock()
            Self.nonRawStatsCache[cacheKey] = stats
            Self.nonRawStatsCacheLock.unlock()
        }
        return stats
    }

    /// `docs/PHASE2_DEVELOP_PIPELINE.md`'s non-RAW Stage P: working space ->
    /// ProPhoto -> `ToneOps.exposureNonRaw` -> cube P
    /// (`ToneOps.applyPostOps`) -> working space, baked as a single cube via
    /// `AdobeBaseRenderer.postOpsCube` -- unless Highlights2012/Shadows2012's
    /// spatial pass is active (`SpatialToneOps.needsSpatial`), per
    /// `docs/PHASE2_C2_C3.md`'s C3 section: then cube P splits into P1
    /// (exposureNonRaw -> Contrast) -> [S] (`AdobeBaseRenderer.
    /// applySpatialToneOps`, linear ProPhoto, cube-free) -> P2 (Whites ->
    /// Blacks -> Parametric -> Point curve), mirroring `AdobeBaseRenderer.
    /// Handle.image(settings:)`'s RAW-path branch exactly -- both share
    /// `postOpsCubeP1`/`postOpsCubeP2`/`applySpatialToneOps`, so this is the
    /// only place that logic is written twice at the call-site level (never
    /// duplicated at the cube-baking level). No-ops (returns `image`
    /// unchanged, not just numerically close to it) when neither exposure
    /// nor any P-op nor H/S is active, so `.neutral` settings keep the exact
    /// bypass `RelativeColorAdjustmentTests.zeroIsAnExactBypassAndKeepsThe
    /// ExistingPipelineFingerprint` (and this function's own callers) rely on.
    ///
    /// `source`: the input `image` was derived from (before
    /// `RelativeColorAdjustment`), which with the relative temperature and
    /// tint identifies what [S] reads at `.sP1P2` for `options.spatialCache`.
    private func applyNonRAWStageP(
        settings: EditSettings, to image: CIImage, source: CIImage, adaptiveStats: SpatialAdaptiveStats.Stats?,
        quality: SpatialToneQuality, options: PreviewRenderOptions
    ) throws -> CIImage {
        let order = SpatialOrder.currentForNonRAW
        let needsSpatial = SpatialToneOps.needsSpatial(settings)
        guard settings.exposure != 0 || ToneOps.needsPostOps(settings) || needsSpatial else {
            return image
        }
        var stage = AdobeBaseRenderer.applyMatrix(DNGColorSpace.srgbLinearToProPhoto, to: image)
        func spatial(_ input: CIImage, cached: Bool = false) throws -> CIImage {
            try options.checkCancellation()
            return AdobeBaseRenderer.spatialPass(
                settings: settings, to: input, source: source,
                inputParameters: [settings.relativeTemperature, settings.relativeTint],
                adaptiveStats: adaptiveStats, path: .nonRAW, quality: quality,
                cache: cached ? options.spatialCache : nil
            )
        }
        func postOps(exposureNonRaw: Double) throws -> AdobeBaseRenderer.BakedCube {
            try AdobeBaseRenderer.postOpsCube(exposureNonRaw: exposureNonRaw, settings: settings, options: options)
        }

        // `.sP1P2` is today's non-RAW production default (`SpatialOrder`'s
        // doc comment); the other branches (`.p1SP2` -- the old shared
        // default, `.p1P2S`, `.postQ`) exist to measure the C4-era
        // full-recipe darkness regression under a different [S] position
        // and remain reachable via the env var; mirrors `AdobeBaseRenderer.Handle.
        // image(settings:)`'s RAW-path `switch` exactly.
        if needsSpatial {
            switch order {
            case .preTone:
                if settings.exposure != 0 {
                    let exposureOnly = AdobeBaseRenderer.buildCubeData { ToneOps.exposureNonRaw($0, ev: settings.exposure) }
                    stage = AdobeBaseRenderer.applyCube(exposureOnly, to: stage)
                }
                stage = try spatial(stage)
                if ToneOps.needsPostOps(settings) {
                    stage = AdobeBaseRenderer.applyCube(try postOps(exposureNonRaw: 0), to: stage)
                }
            case .sP1P2:
                stage = try spatial(stage, cached: true)
                if settings.exposure != 0 || ToneOps.needsPostOps(settings) {
                    stage = AdobeBaseRenderer.applyCube(try postOps(exposureNonRaw: settings.exposure), to: stage)
                }
            case .p1P2S, .postQ:
                if settings.exposure != 0 || ToneOps.needsPostOps(settings) {
                    stage = AdobeBaseRenderer.applyCube(try postOps(exposureNonRaw: settings.exposure), to: stage)
                }
                if order == .p1P2S {
                    stage = try spatial(stage)
                }
            // `.postQ`: [S] deferred to `applyNonRAWStageQ`'s tail.
            case .p1SP2:
                if settings.exposure != 0 || ToneOps.needsContrastOrDehaze(settings) {
                    stage = AdobeBaseRenderer.applyCube(
                        try AdobeBaseRenderer.postOpsCubeP1(
                            exposureNonRaw: settings.exposure, contrast: settings.contrast, dehaze: settings.dehaze,
                            options: options
                        ),
                        to: stage
                    )
                }
                stage = try spatial(stage)
                if ToneOps.needsPostOpsAfterContrast(settings) {
                    stage = AdobeBaseRenderer.applyCube(
                        try AdobeBaseRenderer.postOpsCubeP2(settings: settings, options: options), to: stage
                    )
                }
            }
        } else {
            stage = AdobeBaseRenderer.applyCube(try postOps(exposureNonRaw: settings.exposure), to: stage)
        }
        return AdobeBaseRenderer.applyMatrix(DNGColorSpace.proPhotoToSRGBLinear, to: stage)
    }

    /// `docs/PHASE2_C2_C3.md`'s non-RAW Stage Q: working space -> ProPhoto ->
    /// cube Q (`ColorOps.applyColorOps`: Vibrance -> Saturation -> HSL ->
    /// Color Grading) -> Camera Calibration (`ColorOps.calibrationMatrix`, an
    /// exact `CIColorMatrix` kept separate from cube Q -- see
    /// `AdobeBaseRenderer.applyCalibration`'s doc comment) -> working space.
    /// Mirrors `applyNonRAWStageP`'s exact-bypass-at-neutral-settings shape.
    private func applyNonRAWStageQ(
        settings: EditSettings, to image: CIImage, adaptiveStats: SpatialAdaptiveStats.Stats?,
        quality: SpatialToneQuality, options: PreviewRenderOptions
    ) throws -> CIImage {
        // **Experiment only** (`SpatialOrder`'s doc comment): `.postQ`
        // defers [S] here, after cube Q/Calibration, instead of
        // `applyNonRAWStageP` running it.
        let deferredSpatial = SpatialOrder.currentForNonRAW == .postQ && SpatialToneOps.needsSpatial(settings)
        guard ColorOps.needsColorOps(settings) || ColorOps.needsCalibration(settings.calibration) || deferredSpatial else {
            return image
        }
        var proPhoto = AdobeBaseRenderer.applyMatrix(DNGColorSpace.srgbLinearToProPhoto, to: image)
        if CalibrationOrder.calibrationFirst {
            if ColorOps.needsCalibration(settings.calibration) {
                proPhoto = AdobeBaseRenderer.applyCalibration(
                    ColorOps.calibrationMatrix(settings.calibration), to: proPhoto
                )
            }
            if ColorOps.needsColorOps(settings) {
                proPhoto = AdobeBaseRenderer.applyCube(
                    try AdobeBaseRenderer.postColorCube(settings: settings, options: options), to: proPhoto
                )
            }
        } else {
            if ColorOps.needsColorOps(settings) {
                proPhoto = AdobeBaseRenderer.applyCube(
                    try AdobeBaseRenderer.postColorCube(settings: settings, options: options), to: proPhoto
                )
            }
            if ColorOps.needsCalibration(settings.calibration) {
                proPhoto = AdobeBaseRenderer.applyCalibration(
                    ColorOps.calibrationMatrix(settings.calibration), to: proPhoto
                )
            }
        }
        if deferredSpatial {
            try options.checkCancellation()
            proPhoto = AdobeBaseRenderer.applySpatialToneOps(settings: settings, to: proPhoto, adaptiveStats: adaptiveStats, path: .nonRAW, quality: quality)
        }
        return AdobeBaseRenderer.applyMatrix(DNGColorSpace.proPhotoToSRGBLinear, to: proPhoto)
    }

    /// Picks the RAW (`AdobeBaseRenderer.Handle.image(settings:)`) or non-RAW
    /// (`apply(settings:to:)`) path per `decoded.adobeBase`'s presence, per
    /// `docs/PHASE2_DEVELOP_PIPELINE.md` C1 item 5 / `docs/PHASE2_C2_C3.md`
    /// C2 item 3. The RAW branch applies `RelativeColorAdjustment` on top of
    /// the Handle's fully-rendered (WB + Stage M...P...Q + Calibration,
    /// including phase2 C3's H/S spatial pass) image, instead of
    /// `decoded.image` (which is always the neutral-settings baseline --
    /// see `LibRawDecoder`).
    private func baseImage(
        decoded: DecodedPhoto, settings: EditSettings, quality: SpatialToneQuality = .final,
        options: PreviewRenderOptions = .standard
    ) throws -> CIImage {
        guard let handle = decoded.adobeBase else {
            return try apply(
                settings: settings, to: decoded.image, sourceURL: decoded.sourceURL, quality: quality,
                previewWorkingCopyLongEdge: decoded.info.previewWorkingCopy == nil
                    ? nil : max(decoded.info.width, decoded.info.height),
                options: options
            )
        }
        let rendered = try handle.image(settings: settings, quality: quality, options: options)
        return RelativeColorAdjustment.apply(
            to: rendered,
            relativeTemperature: settings.relativeTemperature,
            relativeTint: settings.relativeTint
        )
    }

    /// Kept module-internal so tests can exercise the real RAW/raster branch
    /// together with the final shoulder and gamut transform.
    func applyForOutput(decoded: DecodedPhoto, settings: EditSettings) -> CIImage {
        // `.standard`: no cancellation token, so this cannot throw.
        let working = try! baseImage(decoded: decoded, settings: settings)
        return applyOutputTransformIfRequired(
            to: working,
            info: decoded.info,
            settings: settings
        )
    }

    /// Builds the sole production output graph. Core Image remains lazy, but
    /// the dependency graph fixes the semantic order and preserves float HDR
    /// headroom without an intermediate bitmap materialization.
    func makeOutputGraph(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat?,
        downsamplingFilter: TIFFDownsamplingFilter,
        outputTransformPlacement: OutputTransformPlacement,
        quality: SpatialToneQuality = .final,
        options: PreviewRenderOptions = .standard
    ) throws -> PreparedOutputGraph {
        if let maxDimension {
            guard maxDimension.isFinite, maxDimension > 0 else {
                throw RenderEngineError.renderFailed(decoded.sourceURL)
            }
        }

        var image = try baseImage(decoded: decoded, settings: settings, quality: quality, options: options)
        if outputTransformPlacement == .legacyBeforeDownsampling {
            image = applyOutputTransformIfRequired(
                to: image,
                info: decoded.info,
                settings: settings
            )
        }
        image = resize(
            image,
            maxDimension: maxDimension,
            downsamplingFilter: downsamplingFilter,
            outputTransformPlacement: outputTransformPlacement
        )
        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0
        else {
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        image = image.cropped(to: extent)
        if outputTransformPlacement == .afterDownsampling {
            image = applyOutputTransformIfRequired(
                to: image,
                info: decoded.info,
                settings: settings
            ).cropped(to: extent)
        }
        return PreparedOutputGraph(image: image, extent: extent)
    }

    private func resize(
        _ image: CIImage,
        maxDimension: CGFloat?,
        downsamplingFilter: TIFFDownsamplingFilter,
        outputTransformPlacement: OutputTransformPlacement
    ) -> CIImage {
        guard let maxDimension else { return image }
        let longest = max(image.extent.width, image.extent.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        switch downsamplingFilter {
        case .affineTransform:
            return image.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )
        case .lanczos:
            if outputTransformPlacement == .legacyBeforeDownsampling {
                // Preserve schema v1-v3 byte semantics. Historical evidence
                // sampled transparent black outside the finite image extent.
                return image.applyingFilter(
                    "CILanczosScaleTransform",
                    parameters: [
                        kCIInputScaleKey: scale,
                        kCIInputAspectRatioKey: 1
                    ]
                )
            }
            // Lanczos reads beyond the finite image extent. Extend the edge
            // pixels before filtering so an opaque photo is not mixed with
            // transparent black at its boundary, then restore the exact
            // finite scaled extent for the remainder of the graph.
            let scaledExtent = image.extent.applying(
                CGAffineTransform(scaleX: scale, y: scale)
            ).integral
            return image.clampedToExtent().applyingFilter(
                "CILanczosScaleTransform",
                parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1
                ]
            ).cropped(to: scaledExtent)
        }
    }

    private func applyOutputTransformIfRequired(
        to image: CIImage,
        info: DecodeInfo,
        settings: EditSettings
    ) -> CIImage {
        Self.requiresOutputTransform(info: info, settings: settings)
            ? SRGBOutputTransform.apply(to: image)
            : image
    }

    /// Separates the branch contract from rendering so the RAW disjunct can be
    /// tested independently of the decoder invariant that RAW is unbounded.
    static func requiresOutputTransform(info: DecodeInfo, settings: EditSettings) -> Bool {
        info.isRAW
            || !info.isBoundedSRGBRaster
            || settings.hasActiveColorEdits()
    }
}

// MARK: - Interactive preview: drag sessions, spatial-pass reuse, cancellation

/// Lets the app abandon a preview render that a newer request superseded.
/// `RenderEngine.preparePreviewFromWorkingCopy` checks it between its steps
/// and inside every cube bake, and then throws `CancellationError`; nothing a
/// cancelled render half-computed is cached. Export never takes one.
public final class PreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// One slider drag in the preview (`EditorModel` starts it when a slider,
/// wheel or curve point is grabbed and drops it on release). While a session
/// is passed to `RenderEngine.preparePreviewFromWorkingCopy`, that frame is
/// an approximation of the exact preview, cheap enough for every drag tick:
///
/// - The spatial pass's image statistics (RAW Highlights/Shadows adaptive
///   law, `.photobench/phase2/spatial-adaptive/model.md` §6/§7) are frozen at
///   the values of the drag's starting settings instead of being re-measured
///   for every tick. Their definition is unchanged; only when they are read
///   differs. With them frozen, a slider downstream of the spatial pass
///   leaves every input of the pass unchanged, so its GPU result from the
///   previous frame is reused (`SpatialPassCache`). A drag that only moves
///   the pass's own inputs (exposure, white balance, Highlights/Shadows/
///   Texture/Clarity) reruns the pass anyway, so it keeps measuring them
///   (`movesOnlySpatialInputs`): their exact cubes are all cached.
/// - A tone cube (P/P1/P2) whose exact 64^3 bake is not cached yet is baked
///   on a `AdobeBaseRenderer.dragCubeDimension`^3 grid instead (its exact
///   bake is several hundred milliseconds on the Mac mini). Cubes Q and H
///   stay exact: their bakes take a few to twenty milliseconds.
///
/// After the drag, the app renders the same settings once more without a
/// session, which gives exactly the preview it rendered before drag sessions
/// existed.
public final class PreviewDragSession: @unchecked Sendable {
    /// `PHOTO_BENCH_DRAG_FREEZE_STATS=0` re-measures the statistics for every
    /// drag frame instead (measurements only; the app never sets it).
    static let freezesStatistics = ProcessInfo.processInfo.environment["PHOTO_BENCH_DRAG_FREEZE_STATS"] != "0"

    public let startSettings: EditSettings
    private let lock = NSLock()
    /// Per working-copy source image (identity) and quality.
    private var frozenStatistics: [(source: CIImage, quality: SpatialToneQuality, stats: SpatialAdaptiveStats.Stats)] = []

    public init(startSettings: EditSettings) {
        self.startSettings = startSettings
    }

    /// Whether `settings` differs from `startSettings` only in what the RAW
    /// spatial pass itself reads (exposure, absolute white balance,
    /// Highlights/Shadows/Texture/Clarity). The pass reruns for such a frame
    /// anyway and the statistics' cubes are those of `startSettings`, so the
    /// exact statistics cost only their small render.
    func movesOnlySpatialInputs(_ settings: EditSettings) -> Bool {
        var moved = settings
        moved.exposure = startSettings.exposure
        moved.whiteBalance = startSettings.whiteBalance
        moved.highlights = startSettings.highlights
        moved.shadows = startSettings.shadows
        moved.texture = startSettings.texture
        moved.clarity = startSettings.clarity
        return moved == startSettings
    }

    /// The statistics frozen for `source` at `quality`, computing them once
    /// with `compute` (the exact statistics of `startSettings`).
    func statistics(
        source: CIImage, quality: SpatialToneQuality,
        compute: () throws -> SpatialAdaptiveStats.Stats
    ) rethrows -> SpatialAdaptiveStats.Stats {
        lock.lock()
        if let frozen = frozenStatistics.first(where: { $0.source === source && $0.quality == quality }) {
            lock.unlock()
            return frozen.stats
        }
        lock.unlock()
        let stats = try compute()
        lock.lock()
        frozenStatistics.append((source, quality, stats))
        lock.unlock()
        return stats
    }
}

/// Preview-only knobs threaded through the render graph builders. Export and
/// every other caller use `.standard`, which reproduces the graph exactly as
/// it was built before these options existed.
struct PreviewRenderOptions {
    /// Grid for tone cubes (P, P1, P2) that are not cached at the exact size
    /// yet (`AdobeBaseRenderer.dragCubeDimension` during a drag).
    var toneCubeDimension: Int = AdobeBaseRenderer.cubeDimension
    var dragSession: PreviewDragSession?
    var spatialCache: SpatialPassCache?
    var cancellation: PreviewCancellation?

    static let standard = PreviewRenderOptions()

    /// The options for the statistics' own "preHS" render: exact cubes, no
    /// spatial pass (it is zeroed there anyway), same cancellation.
    var forStatistics: PreviewRenderOptions {
        PreviewRenderOptions(cancellation: cancellation)
    }

    func checkCancellation() throws {
        if cancellation?.isCancelled == true {
            throw CancellationError()
        }
    }
}

/// The spatial pass's (`AdobeBaseRenderer.applySpatialToneOps`) most recent
/// GPU result for the preview working copy, reused when a later frame's pass
/// would read exactly the same input and parameters. `Key` holds everything
/// the pass reads -- the source pixels' identity, the white balance /
/// exposure / relative-color values and Stage H cube that turn them into the
/// pass's input, Highlights/Shadows/Texture/Clarity, quality and the adaptive
/// statistics -- and compares them exactly, so a hit returns the very image
/// a recomputation would produce. One entry (one 2560 px RGBA float texture,
/// about 70 MB); the entry keeps its source image alive so an identity
/// cannot be recycled while it is cached.
final class SpatialPassCache: @unchecked Sendable {
    struct Key: Equatable {
        var source: ObjectIdentifier
        var extent: CGRect
        var path: SpatialAdaptivePath
        /// RAW: effective white x/y, Stage E exposure, Stage H cube size.
        /// Non-RAW: relative temperature and tint.
        var inputParameters: [Double]
        var highlights: Double
        var shadows: Double
        var texture: Double
        var clarity: Double
        var quality: SpatialToneQuality
        var stats: SpatialAdaptiveStats.Stats?
    }

    private let lock = NSLock()
    private var entry: (key: Key, source: CIImage, output: CIImage)?
    /// How many lookups were served from the entry (tests).
    private(set) var hitCount = 0

    func output(for key: Key) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.key == key else { return nil }
        hitCount += 1
        return entry.output
    }

    func store(_ output: CIImage, for key: Key, source: CIImage) {
        lock.lock()
        entry = (key, source, output)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entry = nil
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entry == nil
    }
}

extension EditSettings {
    /// For a drag-grid tone cube only: without the curves that are the
    /// identity (Lightroom presets carry flat Red/Green/Blue curves), whose
    /// spline `ToneOps.pointCurve` would otherwise rebuild for every grid
    /// point just to return the value it was given (up to float rounding and
    /// the [0, 1] clamp the cube applies anyway).
    func withoutIdentityToneCurves() -> EditSettings {
        var copy = self
        copy.toneCurves = toneCurves.filter { !$0.isIdentity }
        return copy
    }

    /// The same values with freshly allocated `hsl`/`toneCurves` storage.
    /// Cube bakes give every concurrent chunk its own copy, so the Swift
    /// runtime's reference counting of these collections never bounces one
    /// shared cache line between cores (measured on the Mac mini as about
    /// 70% of a cube Q bake). Values, and therefore results, are identical.
    func uniquelyStoredCopy() -> EditSettings {
        var copy = self
        var hsl = [HSLBand: HSLAdjustment](minimumCapacity: self.hsl.count)
        for (band, adjustment) in self.hsl {
            hsl[band] = adjustment
        }
        copy.hsl = hsl
        copy.toneCurves = toneCurves.map { curve in
            ToneCurve(channel: curve.channel, points: curve.points.map { $0 })
        }
        return copy
    }
}

// MARK: - Interactive preview: timing diagnostics

/// Wall-clock breakdown of one preview update, for profiling slider drags.
///
/// `PHOTO_BENCH_PREVIEW_DIAG=1` prints one line per prepared preview frame to
/// stderr (`RenderEngine.preparePreviewFromWorkingCopy` and friends): the
/// total and every step that did real work inside it -- adaptive statistics,
/// each cube bake (with its grid size), the spatial pass (input render,
/// compute wait, GPU time) or its reuse. The app adds one line per shown
/// frame with its input-to-screen latency (`EditorModel`).
/// `photobench-preview-bench` turns collection on programmatically
/// (`setCollecting(true)`) and drains the records after every simulated
/// tick instead.
///
/// Only timing is recorded; nothing here changes what is rendered. With both
/// switches off every hook is a single flag check.
public enum PreviewDiagnostics {
    public static let environmentVariable = "PHOTO_BENCH_PREVIEW_DIAG"

    public struct Record: Sendable, Equatable {
        public let label: String
        public let milliseconds: Double

        public init(label: String, milliseconds: Double) {
            self.label = label
            self.milliseconds = milliseconds
        }
    }

    public static let printsToStandardError =
        ProcessInfo.processInfo.environment[environmentVariable] == "1"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var collecting = false
    nonisolated(unsafe) private static var records: [Record] = []
    nonisolated(unsafe) private static var frameStartIndex = 0

    /// `photobench-preview-bench`: keep every record until `drain()`.
    public static func setCollecting(_ enabled: Bool) {
        lock.lock()
        collecting = enabled
        if !enabled {
            records.removeAll()
            frameStartIndex = 0
        }
        lock.unlock()
    }

    /// Returns and clears everything recorded since the previous drain.
    public static func drain() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        let drained = records
        records.removeAll()
        frameStartIndex = 0
        return drained
    }

    static var isEnabled: Bool {
        if printsToStandardError { return true }
        lock.lock()
        defer { lock.unlock() }
        return collecting
    }

    static func record(_ label: String, milliseconds: Double) {
        lock.lock()
        records.append(Record(label: label, milliseconds: milliseconds))
        lock.unlock()
    }

    static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    /// Runs `body`, recording its wall time under `label` when enabled.
    static func measure<T>(_ label: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = DispatchTime.now()
        let result = try body()
        record(label(), milliseconds: milliseconds(since: start))
        return result
    }

    /// Marks the start of one prepared frame (for the stderr line).
    static func beginFrame() {
        guard isEnabled else { return }
        lock.lock()
        frameStartIndex = records.count
        lock.unlock()
    }

    /// Records the frame total and, with `PHOTO_BENCH_PREVIEW_DIAG=1`, prints
    /// the frame's records on one line. Outside collection mode the records
    /// are dropped afterwards so a long app session does not accumulate them.
    static func endFrame(_ label: String, milliseconds total: Double) {
        guard isEnabled else { return }
        lock.lock()
        records.append(Record(label: label, milliseconds: total))
        let frame = Array(records[min(frameStartIndex, records.count)...])
        if !collecting {
            records.removeAll()
        }
        frameStartIndex = records.count
        lock.unlock()
        guard printsToStandardError else { return }
        let parts = frame.map { "\($0.label)=\(String(format: "%.1f", $0.milliseconds))" }
        FileHandle.standardError.write(Data(("PreviewDiagnostics: " + parts.joined(separator: " ") + "\n").utf8))
    }
}
