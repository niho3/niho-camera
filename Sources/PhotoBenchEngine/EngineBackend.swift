import AppKit
import CoreImage
import Foundation
import ImageIO
import PhotoCore
import UniformTypeIdentifiers

/// What `open` reports about a photo (docs/ENGINE_PROTOCOL.md `open`).
struct PhotoSummary: Equatable, Sendable {
    enum Kind: String, Sendable {
        case raw
        case raster
    }

    /// How a RAW was developed: with the Adobe camera profile (the same base
    /// rendering as Lightroom), or by macOS's Core Image RAW because the
    /// profile or LibRaw could not be used (`PhotoDecoder`'s fallback).
    enum Profile: String, Sendable {
        case adobe
        case fallback
    }

    let kind: Kind
    let fileName: String
    /// Full resolution, orientation applied.
    let width: Int
    let height: Int
    /// RAW with the Adobe profile only (the decoder's as-shot white point).
    let asShotWhiteBalance: AsShotWhiteBalance?
    /// `nil` for a non-RAW photo.
    let profile: Profile?
    /// `DecodeInfo.backend`, for the log.
    let backend: String

    init(decoded: DecodedPhoto) {
        let info = decoded.info
        kind = info.isRAW ? .raw : .raster
        fileName = decoded.sourceURL.lastPathComponent
        width = info.width
        height = info.height
        asShotWhiteBalance = info.asShotWhiteXY.map {
            let (temperature, tint) = ColorSpec.temperatureAndTint(fromXY: $0)
            return AsShotWhiteBalance(temperature: Int(temperature.rounded()), tint: Int(tint.rounded()))
        }
        profile = info.isRAW ? (decoded.adobeBase != nil ? .adobe : .fallback) : nil
        backend = info.backend
    }

    init(
        kind: Kind, fileName: String, width: Int, height: Int,
        asShotWhiteBalance: AsShotWhiteBalance?, profile: Profile?, backend: String
    ) {
        self.kind = kind
        self.fileName = fileName
        self.width = width
        self.height = height
        self.asShotWhiteBalance = asShotWhiteBalance
        self.profile = profile
        self.backend = backend
    }
}

/// A decoded photo reduced to its preview working copy; the full-resolution
/// decode is not kept.
struct OpenedPhoto: Sendable {
    let summary: PhotoSummary
    let workingCopy: DecodedPhoto
}

struct RenderedJPEG: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

struct ExportedJPEG: Sendable {
    let path: String
    let width: Int
    let height: Int
    let bytes: Int
}

/// The image work behind `open`, `render`, `export` and `renderWorkingCopy`.
/// `EngineSession` calls it from one serial queue only, as Photo Bench's
/// `RenderCoordinator` actor does. Errors are `EngineError`s, or
/// `CancellationError` from a cancelled render.
protocol EngineBackend: AnyObject, Sendable {
    func open(url: URL) throws -> OpenedPhoto
    func render(
        workingCopy: DecodedPhoto,
        settings: EditSettings,
        maxDimension: Int,
        drag: PreviewDragSession?,
        cancellation: PreviewCancellation
    ) throws -> RenderedJPEG
    func export(
        url: URL,
        settings: EditSettings,
        destination: URL,
        quality: Double,
        protectedSources: [URL]
    ) throws -> ExportedJPEG
    func renderWorkingCopy(_ request: WorkingCopyRequest) throws -> WorkingCopyResult
}

/// PhotoCore, used exactly as the Photo Bench app does: `PhotoDecoder` ->
/// `RenderEngine.makePreviewWorkingCopy` once per photo, then every preview
/// from the working copy (`preparePreviewFromWorkingCopy`, `.interactive`)
/// through the app's bitmap route (`materializePreview`, sRGB), and export
/// from a fresh full-resolution decode (`exportJPEG`, `.final`).
/// `renderWorkingCopy` is `WorkingCopyRenderer` alone: macOS's decoding,
/// never `PhotoDecoder`'s Adobe profile route.
final class PhotoCoreBackend: EngineBackend, @unchecked Sendable {
    /// Preview JPEG quality (export uses the request's `jpegQuality`).
    static let previewJPEGQuality = 0.85

    private let decoder = PhotoDecoder()
    /// Created on first use (its Metal contexts take a moment), so `hello`
    /// answers at once. Only touched from the session's serial work queue.
    private lazy var renderEngine = RenderEngine()
    /// Created on first use, like `renderEngine`.
    private lazy var workingCopyRenderer = WorkingCopyRenderer()

    func open(url: URL) throws -> OpenedPhoto {
        try autoreleasepool {
            let decoded: DecodedPhoto
            do {
                decoded = try decoder.decode(url: url)
            } catch {
                throw EngineError(.decodeFailed, "写真を読めません: \(describe(error))")
            }
            let summary = PhotoSummary(decoded: decoded)
            do {
                let workingCopy = try renderEngine.makePreviewWorkingCopy(from: decoded)
                return OpenedPhoto(summary: summary, workingCopy: workingCopy)
            } catch {
                throw EngineError(.decodeFailed, "プレビュー用の作業コピーを作れません: \(describe(error))")
            }
        }
    }

    func render(
        workingCopy: DecodedPhoto,
        settings: EditSettings,
        maxDimension: Int,
        drag: PreviewDragSession?,
        cancellation: PreviewCancellation
    ) throws -> RenderedJPEG {
        try autoreleasepool {
            do {
                let frame = try renderEngine.preparePreviewFromWorkingCopy(
                    workingCopy: workingCopy,
                    settings: settings,
                    maxDimension: CGFloat(maxDimension),
                    quality: .interactive,
                    drag: drag,
                    cancellation: cancellation
                )
                if cancellation.isCancelled { throw CancellationError() }
                let rendered = try renderEngine.materializePreview(frame)
                guard let image = rendered.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw EngineError(.internal, "プレビューのビットマップを取り出せません")
                }
                let data = try JPEGEncoding.encode(image, quality: Self.previewJPEGQuality)
                return RenderedJPEG(data: data, width: image.width, height: image.height)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw EngineError.wrapping(error)
            }
        }
    }

    func export(
        url: URL,
        settings: EditSettings,
        destination: URL,
        quality: Double,
        protectedSources: [URL]
    ) throws -> ExportedJPEG {
        try autoreleasepool {
            let decoded: DecodedPhoto
            do {
                decoded = try decoder.decode(url: url)
            } catch {
                throw EngineError(.decodeFailed, "写真を読めません: \(describe(error))")
            }
            do {
                _ = try renderEngine.exportJPEG(
                    decoded: decoded,
                    settings: settings,
                    destination: destination,
                    quality: quality,
                    protectedSourceURLs: protectedSources
                )
            } catch {
                throw EngineError(.exportFailed, "書き出せません: \(describe(error))")
            }
            let written = JPEGEncoding.pixelSize(of: destination)
            let extent = decoded.image.extent.integral
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            return ExportedJPEG(
                path: destination.path,
                width: written?.width ?? Int(extent.width),
                height: written?.height ?? Int(extent.height),
                bytes: bytes
            )
        }
    }

    func renderWorkingCopy(_ request: WorkingCopyRequest) throws -> WorkingCopyResult {
        try autoreleasepool {
            do {
                return try workingCopyRenderer.render(request)
            } catch {
                // `WorkingCopyError` codes are the protocol's own.
                throw EngineError.wrapping(error)
            }
        }
    }
}

enum JPEGEncoding {
    /// Baseline JPEG through ImageIO; the image's color space (sRGB for a
    /// preview) is embedded as its ICC profile.
    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EngineError(.internal, "JPEG の書き出し先を作れません")
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw EngineError(.internal, "JPEG に符号化できません")
        }
        return data as Data
    }

    /// Pixel size from the file's header, orientation applied as a viewer
    /// would (the engine writes orientation 1).
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }
}
