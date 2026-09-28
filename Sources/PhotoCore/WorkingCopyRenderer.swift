import ColorSync
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

// `renderWorkingCopy` (docs/ENGINE_PROTOCOL.md): the NIHO develop engine's
// stage 1 (niho-coliving/niho-app#16943). A RAW, JPEG, PNG, HEIC/HEIF or TIFF
// becomes, once, a "working copy": linear ProPhoto (D50), long edge 2560,
// written as a 16-bit PNG, plus an optional sRGB preview JPEG.
//
// This route is macOS's own decoding only: RAW through Core Image's
// `CIRAWFilter` (RAW 8; `8.dng` for a DNG), everything else through `CIImage` and Core Image's
// color management. It never reads an Adobe camera profile or Adobe Color,
// never goes through LibRaw, and never picks a per-camera boost, so the
// result does not depend on whether Lightroom or DNG Converter is installed.

// MARK: - Request and result

/// One working copy to make.
public struct WorkingCopyRequest: Equatable, Sendable {
    public var sourceURL: URL
    public var workingCopyURL: URL
    /// `nil`: no preview.
    public var previewURL: URL?
    /// Long-edge bound of the working copy (1...2560). A smaller source is not enlarged.
    public var maxDimension: Int
    /// Long-edge bound of the preview (1...2560). A smaller source is not enlarged.
    public var previewMaxDimension: Int
    /// Files never to overwrite besides `sourceURL` itself (the engine passes
    /// the photos it has open).
    public var protectedSourceURLs: [URL]

    public init(
        sourceURL: URL,
        workingCopyURL: URL,
        previewURL: URL? = nil,
        maxDimension: Int = WorkingCopyRenderer.defaultMaxDimension,
        previewMaxDimension: Int = WorkingCopyRenderer.defaultPreviewMaxDimension,
        protectedSourceURLs: [URL] = []
    ) {
        self.sourceURL = sourceURL
        self.workingCopyURL = workingCopyURL
        self.previewURL = previewURL
        self.maxDimension = maxDimension
        self.previewMaxDimension = previewMaxDimension
        self.protectedSourceURLs = protectedSourceURLs
    }
}

public struct WorkingCopyResult: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case raw
        case raster
    }

    /// The preview JPEG as written (read back from the file).
    public struct Preview: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let bytes: Int

        public init(width: Int, height: Int, bytes: Int) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }
    }

    /// Whole milliseconds. `decode`: from opening the original to the reduced
    /// linear ProPhoto pixels (Core Image decodes lazily, so the demosaic,
    /// the color conversion and the Lanczos reduction are one render);
    /// `workingCopy`: 16-bit encoding, PNG, writing and reading back;
    /// `preview`: the preview's own decode, JPEG, writing and reading back
    /// (0 without a preview).
    public struct Timings: Equatable, Sendable {
        public let decodeMilliseconds: Int
        public let workingCopyMilliseconds: Int
        public let previewMilliseconds: Int

        public init(decodeMilliseconds: Int, workingCopyMilliseconds: Int, previewMilliseconds: Int) {
            self.decodeMilliseconds = decodeMilliseconds
            self.workingCopyMilliseconds = workingCopyMilliseconds
            self.previewMilliseconds = previewMilliseconds
        }
    }

    public let kind: Kind
    /// `[A-Za-z0-9._-]` only (it becomes part of an object key).
    public let baseVersion: String
    /// The working copy's pixel size, read back from the PNG.
    public let width: Int
    public let height: Int
    /// The original's full-resolution size, orientation applied.
    public let sourceWidth: Int
    public let sourceHeight: Int
    /// The working copy PNG's file size.
    public let bytes: Int
    public let preview: Preview?
    public let meta: WorkingCopyMeta
    public let timings: Timings

    public init(
        kind: Kind,
        baseVersion: String,
        width: Int,
        height: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        bytes: Int,
        preview: Preview?,
        meta: WorkingCopyMeta,
        timings: Timings
    ) {
        self.kind = kind
        self.baseVersion = baseVersion
        self.width = width
        self.height = height
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.bytes = bytes
        self.preview = preview
        self.meta = meta
        self.timings = timings
    }
}

/// What the working copy is, per source kind. Never the camera model, the
/// file name, the capture time or the location.
public enum WorkingCopyMeta: Equatable, Sendable {
    case raw(RAW)
    case raster(Raster)

    /// How the PNG's 16-bit codes map to linear ProPhoto:
    /// `code = round(65535 * (min(v, ceiling) / ceiling)^(1 / gamma))`,
    /// `v = ceiling * (code / 65535)^gamma`.
    public struct Encoding: Equatable, Sendable {
        public let format: String
        public let gamma: Double
        public let ceiling: Double

        public init(format: String, gamma: Double, ceiling: Double) {
            self.format = format
            self.gamma = gamma
            self.ceiling = ceiling
        }

        /// Photo Bench's cube encoding (`AdobeBaseRenderer.cubeGammaPower`).
        public static let png16 = Encoding(format: "png16", gamma: 1.8, ceiling: 2.0)
    }

    /// `CIRAWFilter`'s as-shot neutral: chromaticity, and Core Image's own
    /// temperature / tint (not Adobe's scale), rounded to integers.
    public struct AsShotWhite: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let temperature: Int
        public let tint: Int

        public init(x: Double, y: Double, temperature: Int, tint: Int) {
            self.x = x
            self.y = y
            self.temperature = temperature
            self.tint = tint
        }
    }

    public struct NoiseReduction: Equatable, Sendable {
        public let luminance: Double
        public let color: Double

        public init(luminance: Double, color: Double) {
            self.luminance = luminance
            self.color = color
        }
    }

    public struct RAW: Equatable, Sendable {
        /// `apple-raw`.
        public let engine: String
        /// `CIRAWDecoderVersion.rawValue`: `8`, or `8.dng` for a DNG.
        public let decoderVersion: String
        /// EV that stage 2 adds before its exposure: 0, since Apple's
        /// BaselineExposure is already in the working copy's pixels.
        public let baselineEV: Double
        /// `WorkingCopyCalibration.label` (`none`).
        public let calibration: String
        public let asShotWhite: AsShotWhite
        public let orientationApplied: Bool
        /// `apple` when `CIRAWFilter` corrected the lens, `nil` otherwise.
        public let lensCorrection: String?
        /// `CIRAWFilter`'s own defaults, as used (never changed here).
        public let noiseReduction: NoiseReduction
        public let sharpness: Double
        public let encoding: Encoding
        public let colorSpace: String
        /// The original's extension, lowercased (`rw2`).
        public let sourceExtension: String

        public init(
            engine: String,
            decoderVersion: String,
            baselineEV: Double,
            calibration: String,
            asShotWhite: AsShotWhite,
            orientationApplied: Bool,
            lensCorrection: String?,
            noiseReduction: NoiseReduction,
            sharpness: Double,
            encoding: Encoding,
            colorSpace: String,
            sourceExtension: String
        ) {
            self.engine = engine
            self.decoderVersion = decoderVersion
            self.baselineEV = baselineEV
            self.calibration = calibration
            self.asShotWhite = asShotWhite
            self.orientationApplied = orientationApplied
            self.lensCorrection = lensCorrection
            self.noiseReduction = noiseReduction
            self.sharpness = sharpness
            self.encoding = encoding
            self.colorSpace = colorSpace
            self.sourceExtension = sourceExtension
        }
    }

    /// The ICC profile Core Image converted from: `sha256` of its bytes and
    /// its description, both `nil` when the image has none (read as sRGB).
    public struct ICC: Equatable, Sendable {
        public let sha256: String?
        public let description: String?

        public init(sha256: String?, description: String?) {
            self.sha256 = sha256
            self.description = description
        }

        public static let assumedSRGB = ICC(sha256: nil, description: nil)
    }

    public struct Raster: Equatable, Sendable {
        /// `ci1`: Core Image's color management.
        public let cms: String
        public let icc: ICC
        public let orientationApplied: Bool
        public let encoding: Encoding
        public let colorSpace: String
        public let sourceExtension: String

        public init(
            cms: String,
            icc: ICC,
            orientationApplied: Bool,
            encoding: Encoding,
            colorSpace: String,
            sourceExtension: String
        ) {
            self.cms = cms
            self.icc = icc
            self.orientationApplied = orientationApplied
            self.encoding = encoding
            self.colorSpace = colorSpace
            self.sourceExtension = sourceExtension
        }
    }
}

public struct WorkingCopyError: LocalizedError, Equatable, Sendable {
    /// The engine protocol's codes (docs/ENGINE_PROTOCOL.md).
    public enum Code: String, Sendable {
        case invalidRequest
        case decodeFailed
        case unsupportedCamera
        case unsupportedProfile
        case exportFailed
        case `internal`
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

// MARK: - Calibration

/// Where a per-camera-model correction of the RAW working copy goes (S9a):
/// applied to the linear ProPhoto (D50) camera image, before the negative
/// clip and the reduction. Only the identity exists; a real correction
/// changes `baseVersion` through its `label`, so working copies made
/// without it are never mistaken for corrected ones.
public protocol WorkingCopyCalibration: Sendable {
    /// `none` for the identity, `<id>-v<n>` (`[A-Za-z0-9.-]`) for a
    /// correction. Written as `cal-<label>` in `baseVersion` and as
    /// `meta.calibration`.
    var label: String { get }
    func apply(to linearProPhoto: CIImage) -> CIImage
}

public struct IdentityWorkingCopyCalibration: WorkingCopyCalibration {
    public init() {}

    public var label: String { "none" }

    public func apply(to linearProPhoto: CIImage) -> CIImage {
        linearProPhoto
    }
}

// MARK: - Renderer

/// Makes working copies. Used from one queue at a time (the engine's serial
/// work queue), like `RenderEngine`.
public final class WorkingCopyRenderer: @unchecked Sendable {
    public static let defaultMaxDimension = 2_560
    public static let maximumDimension = 2_560
    public static let defaultPreviewMaxDimension = 1_024
    /// The preview JPEG must not be larger than this.
    public static let previewByteLimit = 1_048_576
    /// Tried in order until the preview fits `previewByteLimit`.
    public static let previewQualities: [Double] = [0.85, 0.75, 0.65, 0.55, 0.45]
    public static let encoding = WorkingCopyMeta.Encoding.png16
    public static let colorSpaceIdentifier = "linear-prophoto-d50"
    public static let rawEngine = "apple-raw"
    public static let rasterCMS = "ci1"
    /// `baseVersion` parts: stage-1 processing, and the PNG encoding.
    static let processingVersion = "p1"
    static let encodingVersion = "e1"
    /// The RAW decoder the working copy uses: RAW 8 (as `CoreImageDecoder`
    /// pins it), or for a DNG, which Core Image offers as `8.dng` instead,
    /// that variant. `nil` (neither) is `unsupportedCamera`.
    static func selectRAWDecoderVersion(supported: [CIRAWDecoderVersion]) -> CIRAWDecoderVersion? {
        if supported.contains(.version8) { return .version8 }
        if supported.contains(.version8DNG) { return .version8DNG }
        return nil
    }

    /// `baseVersion`'s decoder part: `d` and the version without its dots,
    /// lowercased (`8` -> `d8`, `8.dng` -> `d8dng`), so it never adds a dot
    /// to the dot-separated `baseVersion`.
    static func decoderToken(for version: CIRAWDecoderVersion) -> String {
        "d" + version.rawValue.replacingOccurrences(of: ".", with: "").lowercased()
    }

    private static let inverseEncodingGamma = 1 / encoding.gamma
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private let calibration: any WorkingCopyCalibration
    /// `PreviewWorkingRaster`'s float context (working space extended linear
    /// sRGB, RGBAf intermediates, no cache), also used for the preview JPEG.
    private let raster: PreviewWorkingRaster

    public init(calibration: any WorkingCopyCalibration = IdentityWorkingCopyCalibration()) {
        self.calibration = calibration
        if let device = MTLCreateSystemDefaultDevice() {
            raster = PreviewWorkingRaster(
                context: CIContext(mtlDevice: device, options: PreviewWorkingRaster.contextOptions)
            )
        } else {
            raster = PreviewWorkingRaster(context: CIContext(options: PreviewWorkingRaster.contextOptions))
        }
    }

    /// Writes the working copy (and the preview), each through a temporary
    /// file renamed into place once both are made, and reads them back.
    public func render(_ request: WorkingCopyRequest) throws -> WorkingCopyResult {
        try Self.validate(request)
        let source = request.sourceURL
        let protectedSources = [source] + request.protectedSourceURLs

        // 1. The original, as extended linear sRGB numbers, into linear
        //    ProPhoto, clipped below 0, reduced, rendered once as floats.
        let decodeStarted = ContinuousClock.now
        let opened = try autoreleasepool {
            try PhotoKind.detect(url: source) == .raw ? openRAW(source) : openRaster(source)
        }
        let pixels = try autoreleasepool { () throws -> PreviewWorkingRaster.RenderedPixels in
            var linear = AdobeBaseRenderer.applyMatrix(DNGColorSpace.srgbLinearToProPhoto, to: opened.image)
            if opened.kind == .raw {
                linear = calibration.apply(to: linear)
            }
            let clipped = linear.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1.0e6, y: 1.0e6, z: 1.0e6, w: 1)
            ])
            guard let rendered = raster.renderPixels(Self.reduced(clipped, maxDimension: request.maxDimension)) else {
                throw WorkingCopyError(.decodeFailed, "作業コピーの画素を作れません: \(source.lastPathComponent)")
            }
            return rendered
        }
        let decodeMilliseconds = Self.milliseconds(since: decodeStarted)

        // 2. The 16-bit PNG, to a temporary file.
        let encodeStarted = ContinuousClock.now
        let png = try autoreleasepool { try Self.encodePNG16(pixels) }
        let workingTemporary = try Self.writeTemporary(png, beside: request.workingCopyURL)
        var workingCopyMilliseconds = Self.milliseconds(since: encodeStarted)

        // 3. The preview JPEG, to a temporary file.
        var previewTemporary: URL?
        var previewMilliseconds = 0
        if let previewURL = request.previewURL {
            let previewStarted = ContinuousClock.now
            do {
                let jpeg = try autoreleasepool {
                    try makePreviewJPEG(opened, source: source, maxDimension: request.previewMaxDimension)
                }
                previewTemporary = try Self.writeTemporary(jpeg, beside: previewURL)
            } catch {
                try? FileManager.default.removeItem(at: workingTemporary)
                throw error
            }
            previewMilliseconds = Self.milliseconds(since: previewStarted)
        }

        // 4. Both in place, then read back.
        let installStarted = ContinuousClock.now
        do {
            try RenderEngine.installAtomically(
                temporary: workingTemporary,
                destination: request.workingCopyURL,
                protectedSources: protectedSources
            )
        } catch {
            try? FileManager.default.removeItem(at: workingTemporary)
            if let previewTemporary { try? FileManager.default.removeItem(at: previewTemporary) }
            throw WorkingCopyError(.exportFailed, "作業コピーを書き出せません: \(error.localizedDescription)")
        }
        let written = try Self.readBackPNG(
            request.workingCopyURL, expectedWidth: pixels.width, expectedHeight: pixels.height
        )
        workingCopyMilliseconds += Self.milliseconds(since: installStarted)

        var preview: WorkingCopyResult.Preview?
        if let previewURL = request.previewURL, let previewTemporary {
            let previewInstallStarted = ContinuousClock.now
            do {
                try RenderEngine.installAtomically(
                    temporary: previewTemporary,
                    destination: previewURL,
                    protectedSources: protectedSources + [request.workingCopyURL]
                )
            } catch {
                try? FileManager.default.removeItem(at: previewTemporary)
                throw WorkingCopyError(.exportFailed, "プレビューを書き出せません: \(error.localizedDescription)")
            }
            preview = try Self.readBackJPEG(previewURL)
            previewMilliseconds += Self.milliseconds(since: previewInstallStarted)
        }

        return WorkingCopyResult(
            kind: opened.kind,
            baseVersion: opened.baseVersion,
            width: written.width,
            height: written.height,
            sourceWidth: opened.width,
            sourceHeight: opened.height,
            bytes: written.bytes,
            preview: preview,
            meta: opened.meta,
            timings: .init(
                decodeMilliseconds: decodeMilliseconds,
                workingCopyMilliseconds: workingCopyMilliseconds,
                previewMilliseconds: previewMilliseconds
            )
        )
    }

    // MARK: - Opening the original

    private struct OpenedSource {
        let kind: WorkingCopyResult.Kind
        /// Full resolution, orientation applied, in the context's working
        /// space (extended linear sRGB).
        let image: CIImage
        let width: Int
        let height: Int
        let meta: WorkingCopyMeta
        let baseVersion: String
    }

    /// `CIRAWFilter` configured in `CoreImageDecoder.decode`'s order with the
    /// flat `RAWDecodeConfiguration.calibrationBaseline` (no boost, exposure
    /// 0, shadow bias 0, boost shadow 1, EDR 0): a linear, scene-referred
    /// output. Orientation, lens correction, noise reduction and sharpening
    /// stay Apple's defaults.
    private func openRAW(_ url: URL) throws -> OpenedSource {
        let name = url.lastPathComponent
        try Self.requireRAWImage(url)
        // `CIRAWFilter(imageURL:)` is not nil even for an unreadable file (it
        // reports no decoder versions), hence the ImageIO check above.
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw WorkingCopyError(.unsupportedCamera, "macOS の RAW 現像がこの RAW に対応していません: \(name)")
        }
        let versions = filter.supportedDecoderVersions
        guard let decoderVersion = Self.selectRAWDecoderVersion(supported: versions) else {
            throw WorkingCopyError(
                .unsupportedCamera,
                "macOS の RAW 現像（RAW 8、DNG は 8.dng）がこの機種に対応していません（対応: \(versions.map(\.rawValue).joined(separator: ", "))）: \(name)"
            )
        }
        filter.decoderVersion = decoderVersion
        let nativeSize = filter.nativeSize
        guard CoreImageDecoder.validatedPixelDimension(nativeSize.width) != nil,
              CoreImageDecoder.validatedPixelDimension(nativeSize.height) != nil
        else {
            throw WorkingCopyError(.decodeFailed, "RAW の原寸を読めません: \(name)")
        }
        let configuration = RAWDecodeConfiguration.calibrationBaseline
        filter.exposure = configuration.exposure
        filter.shadowBias = configuration.shadowBias
        filter.boostAmount = configuration.boostAmount
        filter.boostShadowAmount = configuration.boostShadowAmount
        filter.extendedDynamicRangeAmount = configuration.extendedDynamicRangeAmount
        filter.scaleFactor = 1
        filter.isGamutMappingEnabled = true
        guard let image = filter.outputImage,
              let width = CoreImageDecoder.validatedPixelDimension(image.extent.width),
              let height = CoreImageDecoder.validatedPixelDimension(image.extent.height)
        else {
            throw WorkingCopyError(.decodeFailed, "RAW を現像できません: \(name)")
        }

        let neutral: RAWNeutralValues
        do {
            neutral = try CoreImageRAWWhiteBalanceDecoder.neutralValues(filter: filter, label: "working-copy-as-shot")
        } catch {
            throw WorkingCopyError(.decodeFailed, "撮影時の白を読めません: \(name)")
        }
        let luminanceNoiseReduction = filter.luminanceNoiseReductionAmount
        let colorNoiseReduction = filter.colorNoiseReductionAmount
        let sharpness = filter.sharpnessAmount
        guard luminanceNoiseReduction.isFinite, colorNoiseReduction.isFinite, sharpness.isFinite else {
            throw WorkingCopyError(.decodeFailed, "RAW 現像の既定値を読めません: \(name)")
        }
        let meta = WorkingCopyMeta.RAW(
            engine: Self.rawEngine,
            decoderVersion: filter.decoderVersion.rawValue,
            baselineEV: 0,
            calibration: calibration.label,
            asShotWhite: .init(
                x: Self.shortest(Float(neutral.chromaticityX)),
                y: Self.shortest(Float(neutral.chromaticityY)),
                temperature: Int(neutral.temperatureKelvin.rounded()),
                tint: Int(neutral.tint.rounded())
            ),
            orientationApplied: true,
            lensCorrection: filter.isLensCorrectionSupported && filter.isLensCorrectionEnabled ? "apple" : nil,
            noiseReduction: .init(
                luminance: Self.shortest(luminanceNoiseReduction),
                color: Self.shortest(colorNoiseReduction)
            ),
            sharpness: Self.shortest(sharpness),
            encoding: Self.encoding,
            colorSpace: Self.colorSpaceIdentifier,
            sourceExtension: url.pathExtension.lowercased()
        )
        let baseVersion = "raw-apple.\(Self.decoderToken(for: filter.decoderVersion))"
            + ".\(Self.processingVersion).\(Self.encodingVersion).cal-\(calibration.label)"
        try Self.requireValidBaseVersion(baseVersion)
        return OpenedSource(
            kind: .raw, image: image, width: width, height: height, meta: .raw(meta), baseVersion: baseVersion
        )
    }

    /// `CIImage(contentsOf:)` with its orientation applied; Core Image converts
    /// from the image's color space (its ICC profile) to the working space.
    private func openRaster(_ url: URL) throws -> OpenedSource {
        let name = url.lastPathComponent
        guard let loaded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw WorkingCopyError(.decodeFailed, "写真を読めません: \(name)")
        }
        let icc = try Self.iccIdentity(of: loaded.colorSpace)
        let image: CIImage
        if loaded.colorSpace == nil {
            // Untagged: read as sRGB rather than as working-space numbers.
            guard let matched = loaded.matchedToWorkingSpace(from: Self.sRGB) else {
                throw WorkingCopyError(.unsupportedProfile, "写真の色空間を sRGB として扱えません: \(name)")
            }
            image = matched
        } else {
            image = loaded
        }
        guard let width = CoreImageDecoder.validatedPixelDimension(image.extent.width),
              let height = CoreImageDecoder.validatedPixelDimension(image.extent.height)
        else {
            throw WorkingCopyError(.decodeFailed, "写真の大きさを読めません: \(name)")
        }
        let meta = WorkingCopyMeta.Raster(
            cms: Self.rasterCMS,
            icc: icc,
            orientationApplied: true,
            encoding: Self.encoding,
            colorSpace: Self.colorSpaceIdentifier,
            sourceExtension: url.pathExtension.lowercased()
        )
        let baseVersion = "raster.\(Self.rasterCMS).\(Self.processingVersion).\(Self.encodingVersion)"
            + ".icc-\(icc.sha256 ?? "srgb")"
        try Self.requireValidBaseVersion(baseVersion)
        return OpenedSource(
            kind: .raster, image: image, width: width, height: height, meta: .raster(meta), baseVersion: baseVersion
        )
    }

    /// A RAW-extension file that is missing, unreadable, or not a RAW image
    /// to ImageIO is `decodeFailed` (broken), not `unsupportedCamera`.
    private static func requireRAWImage(_ url: URL) throws {
        let name = url.lastPathComponent
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw WorkingCopyError(.decodeFailed, "写真を読めません（ファイルがありません）: \(name)")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String?
        else {
            throw WorkingCopyError(.decodeFailed, "写真を読めません（壊れているか、画像ではありません）: \(name)")
        }
        if let type = UTType(typeIdentifier), !type.conforms(to: .rawImage) {
            throw WorkingCopyError(.decodeFailed, "拡張子は RAW ですが中身が RAW ではありません（\(typeIdentifier)）: \(name)")
        }
    }

    /// The ICC profile of `colorSpace`: its SHA-256 (lowercase hex) and
    /// description. No color space, or one without ICC data (Core Image
    /// treats device RGB as sRGB), is read as sRGB: `ICC.assumedSRGB`.
    static func iccIdentity(of colorSpace: CGColorSpace?) throws -> WorkingCopyMeta.ICC {
        guard let colorSpace, let data = colorSpace.copyICCData() as Data?, !data.isEmpty else {
            return .assumedSRGB
        }
        return try iccIdentity(iccData: data, fallbackDescription: colorSpace.name as String?)
    }

    /// Profile bytes ColorSync cannot read are `unsupportedProfile`.
    static func iccIdentity(iccData data: Data, fallbackDescription: String?) throws -> WorkingCopyMeta.ICC {
        guard let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue() else {
            throw WorkingCopyError(.unsupportedProfile, "写真の ICC プロファイルが壊れていて色空間を作れません")
        }
        let described = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
        let description = [described, fallbackDescription]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return WorkingCopyMeta.ICC(sha256: sha256Hex(data), description: description)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pixels

    /// `PreviewWorkingRaster.reduce` -- edge-clamped Lanczos to the long edge
    /// `maxDimension`, a source already within it only moved to the origin --
    /// kept on whole pixels: the long edge never exceeds `maxDimension`
    /// (`.integral` can round a floating-point product up by one) and a
    /// fractional extent is completed from its edge pixels.
    static func reduced(_ image: CIImage, maxDimension: Int) -> CIImage {
        let reduced = PreviewWorkingRaster.reduce(image, maxDimension: CGFloat(maxDimension))
        let extent = reduced.extent
        let bound = CGFloat(maxDimension)
        let grid = CGRect(
            x: 0,
            y: 0,
            width: min(extent.width.rounded(.up), bound),
            height: min(extent.height.rounded(.up), bound)
        )
        return extent == grid ? reduced : reduced.clampedToExtent().cropped(to: grid)
    }

    /// One linear ProPhoto component as its 16-bit code (`Encoding.png16`).
    /// Negative values (Lanczos ringing below the clip) and NaN are 0.
    static func encodedSample(_ value: Float) -> UInt16 {
        let linear = Double(value)
        guard linear > 0 else { return 0 }
        let normalized = min(linear, encoding.ceiling) / encoding.ceiling
        return UInt16((65_535 * pow(normalized, inverseEncodingGamma)).rounded())
    }

    /// The inverse of `encodedSample`, as a consumer decodes the PNG.
    public static func decodedSample(_ code: UInt16) -> Double {
        encoding.ceiling * pow(Double(code) / 65_535, encoding.gamma)
    }

    /// RGB, 16 bits per component, big-endian, no alpha, through ImageIO,
    /// with ImageIO's own color and metadata chunks removed.
    static func encodePNG16(_ pixels: PreviewWorkingRaster.RenderedPixels) throws -> Data {
        let width = pixels.width
        let height = pixels.height
        let rowBytes = width * 6
        var samples = Data(count: rowBytes * height)
        let sourceStride = pixels.rowBytes / MemoryLayout<Float>.size
        pixels.data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            samples.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
                // Each iteration writes only its own row of `samples` and
                // reads only its own row of `pixels`.
                let input = UnsafeRowsBox(
                    pointer: UnsafeMutableRawPointer(mutating: sourceBase).assumingMemoryBound(to: Float.self)
                )
                let output = UnsafeRowsBox(pointer: destinationBase.assumingMemoryBound(to: UInt16.self))
                DispatchQueue.concurrentPerform(iterations: height) { row in
                    let rowInput = input.pointer + row * sourceStride
                    let rowOutput = output.pointer + row * width * 3
                    for x in 0..<width {
                        rowOutput[x * 3] = encodedSample(rowInput[x * 4]).bigEndian
                        rowOutput[x * 3 + 1] = encodedSample(rowInput[x * 4 + 1]).bigEndian
                        rowOutput[x * 3 + 2] = encodedSample(rowInput[x * 4 + 2]).bigEndian
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: samples as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 16,
                  bitsPerPixel: 48,
                  bytesPerRow: rowBytes,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            throw WorkingCopyError(.internal, "作業コピーのビットマップを作れません")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw WorkingCopyError(.internal, "PNG の書き出し先を作れません")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WorkingCopyError(.exportFailed, "作業コピーを PNG に符号化できません")
        }
        return try strippingAncillaryChunks(encoded as Data)
    }

    /// Keeps IHDR, IDAT and IEND only. ImageIO tags every PNG it writes
    /// (`sRGB` or `iCCP`/`cICP`, and `eXIf`); the working copy carries no
    /// ICC, EXIF or XMP, and no PNG color chunk could describe its values
    /// anyway. An unexpected critical chunk fails instead of being dropped.
    static func strippingAncillaryChunks(_ png: Data) throws -> Data {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let malformed = WorkingCopyError(.internal, "ImageIO が書いた PNG を読めません")
        return try png.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress, bytes.count >= signature.count,
                  Array(bytes.prefix(signature.count)) == signature
            else {
                throw malformed
            }
            var output = Data(capacity: bytes.count)
            output.append(contentsOf: signature)
            var offset = signature.count
            var sawHeader = false
            var sawEnd = false
            while !sawEnd {
                guard offset + 12 <= bytes.count else { throw malformed }
                let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                let end = offset + 12 + length
                guard length <= Int(Int32.max), end <= bytes.count else { throw malformed }
                let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
                let isCritical = bytes[offset + 4] & 0x20 == 0
                switch type {
                case "IHDR":
                    guard !sawHeader, offset == signature.count else { throw malformed }
                    sawHeader = true
                case "IDAT":
                    guard sawHeader else { throw malformed }
                case "IEND":
                    guard sawHeader else { throw malformed }
                    sawEnd = true
                default:
                    // Ancillary chunks are dropped; an unknown critical one
                    // would change how the pixels decode.
                    guard !isCritical else { throw malformed }
                    offset = end
                    continue
                }
                output.append(base + offset, count: end - offset)
                offset = end
            }
            return output
        }
    }

    // MARK: - Preview

    /// Apple's standard look (for a RAW, a second `CIRAWFilter` with the same
    /// decoder version and every other property at its default, decoded at a reduced
    /// `scaleFactor`), long edge `maxDimension` (never enlarged), sRGB JPEG
    /// without the original's metadata, at the first quality that fits
    /// `previewByteLimit`.
    private func makePreviewJPEG(_ opened: OpenedSource, source: URL, maxDimension: Int) throws -> Data {
        let longEdge = min(maxDimension, max(opened.width, opened.height))
        let decoded: CIImage
        switch opened.kind {
        case .raw:
            guard let filter = CIRAWFilter(imageURL: source),
                  let decoderVersion = Self.selectRAWDecoderVersion(supported: filter.supportedDecoderVersions)
            else {
                throw WorkingCopyError(.unsupportedCamera, "macOS の RAW 現像がこの RAW に対応していません: \(source.lastPathComponent)")
            }
            filter.decoderVersion = decoderVersion
            let nativeLongest = max(filter.nativeSize.width, filter.nativeSize.height)
            guard nativeLongest.isFinite, nativeLongest >= 1 else {
                throw WorkingCopyError(.decodeFailed, "RAW の原寸を読めません: \(source.lastPathComponent)")
            }
            filter.scaleFactor = min(1, Float(CGFloat(maxDimension) / nativeLongest))
            guard let output = filter.outputImage else {
                throw WorkingCopyError(.decodeFailed, "プレビュー用に RAW を現像できません: \(source.lastPathComponent)")
            }
            decoded = output
        case .raster:
            decoded = opened.image
        }
        let image = Self.reduced(decoded, maxDimension: longEdge).settingProperties([:])
        let context = raster.context
        return try Self.fittingPreviewJPEG { quality in
            guard let data = context.jpegRepresentation(
                of: image,
                colorSpace: Self.sRGB,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
            ) else {
                throw WorkingCopyError(.exportFailed, "プレビューの JPEG を作れません: \(source.lastPathComponent)")
            }
            return data
        }
    }

    /// The first of `qualities` whose JPEG is at most `limit` bytes.
    static func fittingPreviewJPEG(
        qualities: [Double] = previewQualities,
        limit: Int = previewByteLimit,
        encode: (Double) throws -> Data
    ) throws -> Data {
        var smallest = Int.max
        for quality in qualities {
            let data = try encode(quality)
            if data.count <= limit { return data }
            smallest = min(smallest, data.count)
        }
        throw WorkingCopyError(
            .exportFailed,
            "プレビューが 1MiB を超えるため作れません（品質 \(qualities.last ?? 0) でも \(smallest) バイト）"
        )
    }

    // MARK: - Files

    private static func validate(_ request: WorkingCopyRequest) throws {
        guard (1...maximumDimension).contains(request.maxDimension) else {
            throw WorkingCopyError(.invalidRequest, "maxDimension は 1〜\(maximumDimension) にしてください")
        }
        guard (1...maximumDimension).contains(request.previewMaxDimension) else {
            throw WorkingCopyError(.invalidRequest, "previewMaxDimension は 1〜\(maximumDimension) にしてください")
        }
        let protectedSources = [request.sourceURL] + request.protectedSourceURLs
        for destination in [request.workingCopyURL] + [request.previewURL].compactMap({ $0 }) {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                throw WorkingCopyError(
                    .exportFailed,
                    "フォルダ自体には書き出せません。ファイル名を指定してください: \(destination.lastPathComponent)"
                )
            }
            guard !RenderEngine.destinationAliasesAnySource(destination, sources: protectedSources) else {
                throw WorkingCopyError(
                    .exportFailed, "原本は上書きできません。別の書き出し先を指定してください: \(destination.lastPathComponent)"
                )
            }
        }
        if let previewURL = request.previewURL,
           RenderEngine.destinationAliasesSource(previewURL, source: request.workingCopyURL) {
            throw WorkingCopyError(.exportFailed, "作業コピーとプレビューの書き出し先が同じです: \(previewURL.lastPathComponent)")
        }
    }

    private static func requireValidBaseVersion(_ value: String) throws {
        let allowed = value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
        guard !value.isEmpty, allowed else {
            throw WorkingCopyError(.internal, "baseVersion に使えない文字があります: \(value)")
        }
    }

    /// A temporary file next to `destination` (its folder is created), for
    /// `RenderEngine.installAtomically` to rename into place.
    private static func writeTemporary(_ data: Data, beside destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temporary, options: [.withoutOverwriting])
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw WorkingCopyError(.exportFailed, "書き出せません: \(error.localizedDescription)")
        }
        return temporary
    }

    private static func readBackPNG(
        _ url: URL, expectedWidth: Int, expectedHeight: Int
    ) throws -> (width: Int, height: Int, bytes: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 16,
              (properties[kCGImagePropertyHasAlpha] as? Bool) != true,
              width == expectedWidth, height == expectedHeight,
              let bytes = fileSize(url)
        else {
            throw WorkingCopyError(.exportFailed, "書いた作業コピーを読み戻せません: \(url.lastPathComponent)")
        }
        return (width, height, bytes)
    }

    private static func readBackJPEG(_ url: URL) throws -> WorkingCopyResult.Preview {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              let bytes = fileSize(url)
        else {
            throw WorkingCopyError(.exportFailed, "書いたプレビューを読み戻せません: \(url.lastPathComponent)")
        }
        return WorkingCopyResult.Preview(width: width, height: height, bytes: bytes)
    }

    private static func fileSize(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    // MARK: - Numbers

    /// A value Core Image computed in single precision, with the fewest
    /// digits that round-trip it (0.41497162, not 0.41497161984443665).
    static func shortest(_ value: Float) -> Double {
        Double(value.description) ?? Double(value)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return Int(milliseconds.rounded())
    }
}

/// A pointer shared by `encodePNG16`'s `concurrentPerform` rows: each
/// iteration touches only its own row, so the race the compiler cannot rule
/// out does not occur.
private struct UnsafeRowsBox<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>
}
