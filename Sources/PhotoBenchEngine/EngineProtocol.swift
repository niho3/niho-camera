import Foundation
import PhotoCore

// The wire format of `photobench-engine --stdio` (docs/ENGINE_PROTOCOL.md):
// one JSON request per line on standard input; one JSON header line per
// response on standard output, followed by exactly `binaryLength` bytes when
// the response carries a body.

/// The protocol's error codes (docs/ENGINE_PROTOCOL.md "エラーコード").
struct EngineError: Error, Equatable, Sendable {
    enum Code: String, Sendable, CaseIterable {
        case invalidRequest
        case notFound
        case cancelled
        case decodeFailed
        /// `renderWorkingCopy`: macOS's RAW 8 decoder (`8.dng` for a DNG)
        /// does not support the camera.
        case unsupportedCamera
        /// `renderWorkingCopy`: the embedded ICC profile is broken.
        case unsupportedProfile
        case presetInvalid
        case exportFailed
        case `internal`
    }

    let code: Code
    let message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    static func invalidRequest(_ message: String) -> EngineError { EngineError(.invalidRequest, message) }

    static func notFound(photoID: String) -> EngineError {
        EngineError(.notFound, "写真が開かれていません: \(photoID)")
    }

    static let cancelled = EngineError(.cancelled, "同じ写真へのより新しい render が来たので取り消しました")

    /// Any error from outside the engine, as the protocol's `internal`
    /// (an `EngineError` keeps its own code, a `WorkingCopyError` its
    /// protocol code).
    static func wrapping(_ error: Error) -> EngineError {
        if let engineError = error as? EngineError { return engineError }
        if error is CancellationError { return .cancelled }
        if let workingCopyError = error as? WorkingCopyError {
            return EngineError(Code(rawValue: workingCopyError.code.rawValue) ?? .internal, workingCopyError.message)
        }
        return EngineError(.internal, describe(error))
    }
}

/// A human-readable message for an error from PhotoCore or Foundation.
func describe(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    return (error as NSError).localizedDescription
}

enum EngineMethod: String, Sendable, CaseIterable {
    case hello
    case profileStatus
    case builtinPresets
    case presetSettings
    case open
    case render
    case export
    case renderWorkingCopy
    case close
    case shutdown
}

/// One parsed request line. `params` is the request's `params` object
/// re-serialized as JSON (`{}` when absent), decoded per method.
struct EngineRequest: Sendable {
    let id: Int
    let method: String
    let params: Data

    func decodeParams<Params: Decodable>(_ type: Params.Type) throws -> Params {
        do {
            return try JSONDecoder().decode(Params.self, from: params)
        } catch let error as DecodingError {
            throw EngineError.invalidRequest(Self.describeDecodingError(error))
        } catch {
            throw EngineError.invalidRequest("params を読めません")
        }
    }

    private static func describeDecodingError(_ error: DecodingError) -> String {
        func path(_ codingPath: [any CodingKey], _ key: (any CodingKey)? = nil) -> String {
            let keys = codingPath + (key.map { [$0] } ?? [])
            return (["params"] + keys.map { $0.intValue.map(String.init) ?? $0.stringValue }).joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context):
            return "\(path(context.codingPath, key)) がありません"
        case let .valueNotFound(_, context):
            return "\(path(context.codingPath)) が null です"
        case let .typeMismatch(_, context):
            return "\(path(context.codingPath)) の型が違います"
        case let .dataCorrupted(context):
            return "\(path(context.codingPath)) を読めません"
        @unknown default:
            return "params を読めません"
        }
    }
}

enum RequestParser {
    /// A request line longer than this is rejected without being parsed.
    static let maximumLineBytes = 32 << 20
    /// JavaScript's largest safe integer: the callers' ids are JS numbers.
    static let maximumRequestID = 9_007_199_254_740_991.0

    struct Failure: Error, Sendable {
        /// `0` when the line has no readable `id` (docs: "`id` が読めない要求").
        let id: Int
        let error: EngineError
    }

    static func parse(_ line: Data) -> Result<EngineRequest, Failure> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
        } catch {
            return .failure(Failure(id: 0, error: .invalidRequest("JSON を読めません")))
        }
        guard let dictionary = object as? [String: Any] else {
            return .failure(Failure(id: 0, error: .invalidRequest("要求は JSON のオブジェクトにしてください")))
        }
        guard let id = requestID(dictionary["id"]) else {
            return .failure(Failure(id: 0, error: .invalidRequest("id は正の整数にしてください")))
        }
        guard let method = dictionary["method"] as? String, !method.isEmpty else {
            return .failure(Failure(id: id, error: .invalidRequest("method がありません")))
        }
        let params: Data
        switch dictionary["params"] {
        case nil, is NSNull:
            params = Data("{}".utf8)
        case let object as [String: Any]:
            guard let data = try? JSONSerialization.data(withJSONObject: object) else {
                return .failure(Failure(id: id, error: .invalidRequest("params を読めません")))
            }
            params = data
        default:
            return .failure(Failure(id: id, error: .invalidRequest("params は JSON のオブジェクトにしてください")))
        }
        return .success(EngineRequest(id: id, method: method, params: params))
    }

    /// A positive integer (`1.0` is accepted as `1`); booleans, strings and
    /// fractions are not ids.
    static func requestID(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 1, double <= maximumRequestID, double == double.rounded(.towardZero) else {
            return nil
        }
        return Int(double)
    }
}

// MARK: - Params

struct OpenParams: Decodable, Sendable {
    let path: String
}

struct RenderParams: Decodable, Sendable {
    let photoId: String
    let settings: EditSettings?
    let maxDimension: Int?
    let drag: Bool?
    let original: Bool?
}

struct ExportParams: Decodable, Sendable {
    let photoId: String
    let settings: EditSettings
    let destinationPath: String
    let jpegQuality: Double?
}

struct RenderWorkingCopyParams: Decodable, Sendable {
    let path: String
    let workingCopyPath: String
    let previewPath: String?
    let maxDimension: Int?
    let previewMaxDimension: Int?
}

struct CloseParams: Decodable, Sendable {
    let photoId: String
}

struct PresetSettingsParams: Decodable, Sendable {
    let xmp: String
    let base: EditSettings?
}

// MARK: - Results

struct EmptyResult: Encodable, Sendable {}

struct HelloResult: Encodable, Sendable {
    let engineVersion: String
    let protocolVersion: Int
}

/// Where this Mac's Adobe camera profiles come from
/// (`AdobeProfileLocator.status()`), without opening a photo.
struct ProfileStatusResult: Encodable, Sendable {
    let available: Bool
    let lookSource: String?
    let dcpSources: [String]

    init(_ status: AdobeProfileLocator.Status) {
        available = status.isAvailable
        lookSource = status.lookSource?.rawValue
        dcpSources = status.dcpSources.map(\.rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case available, lookSource, dcpSources
    }

    /// `lookSource` is written as explicit `null` (documented as `... | null`).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        if let lookSource {
            try container.encode(lookSource, forKey: .lookSource)
        } else {
            try container.encodeNil(forKey: .lookSource)
        }
        try container.encode(dcpSources, forKey: .dcpSources)
    }
}

struct BuiltinPresetsResult: Encodable, Sendable {
    struct Preset: Encodable, Sendable {
        let id: String
        let name: String
        let xmp: String
    }

    let presets: [Preset]
}

struct PresetSettingsResult: Encodable, Sendable {
    let name: String
    let settings: EditSettings
    let unsupported: [String]
}

struct AsShotWhiteBalance: Codable, Equatable, Sendable {
    let temperature: Int
    let tint: Int
}

struct OpenResult: Encodable, Sendable {
    let photoId: String
    let kind: String
    let fileName: String
    let width: Int
    let height: Int
    let asShotWhiteBalance: AsShotWhiteBalance?
    let profile: String?
    let settings: EditSettings

    private enum CodingKeys: String, CodingKey {
        case photoId, kind, fileName, width, height, asShotWhiteBalance, profile, settings
    }

    /// `asShotWhiteBalance` and `profile` are written as explicit `null`
    /// (the protocol documents them as `... | null`), not left out.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(photoId, forKey: .photoId)
        try container.encode(kind, forKey: .kind)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        if let asShotWhiteBalance {
            try container.encode(asShotWhiteBalance, forKey: .asShotWhiteBalance)
        } else {
            try container.encodeNil(forKey: .asShotWhiteBalance)
        }
        if let profile {
            try container.encode(profile, forKey: .profile)
        } else {
            try container.encodeNil(forKey: .profile)
        }
        try container.encode(settings, forKey: .settings)
    }
}

struct RenderResult: Encodable, Sendable {
    let width: Int
    let height: Int
}

struct ExportResult: Encodable, Sendable {
    let path: String
    let width: Int
    let height: Int
    let bytes: Int
}

/// `renderWorkingCopy`'s result. `preview`, `meta.lensCorrection` and
/// `meta.icc.sha256` / `meta.icc.description` are written as explicit
/// `null` (documented as `... | null`), not left out.
struct RenderWorkingCopyResult: Encodable, Sendable {
    let rendered: WorkingCopyResult

    init(_ rendered: WorkingCopyResult) {
        self.rendered = rendered
    }

    private enum CodingKeys: String, CodingKey {
        case kind, baseVersion, width, height, sourceWidth, sourceHeight, bytes, preview, meta, timings
    }

    private struct PreviewBody: Encodable {
        let width: Int
        let height: Int
        let bytes: Int
    }

    private struct TimingsBody: Encodable {
        let decodeMs: Int
        let workingCopyMs: Int
        let previewMs: Int
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rendered.kind.rawValue, forKey: .kind)
        try container.encode(rendered.baseVersion, forKey: .baseVersion)
        try container.encode(rendered.width, forKey: .width)
        try container.encode(rendered.height, forKey: .height)
        try container.encode(rendered.sourceWidth, forKey: .sourceWidth)
        try container.encode(rendered.sourceHeight, forKey: .sourceHeight)
        try container.encode(rendered.bytes, forKey: .bytes)
        if let preview = rendered.preview {
            try container.encode(
                PreviewBody(width: preview.width, height: preview.height, bytes: preview.bytes),
                forKey: .preview
            )
        } else {
            try container.encodeNil(forKey: .preview)
        }
        try container.encode(WorkingCopyMetaBody(rendered.meta), forKey: .meta)
        let timings = rendered.timings
        try container.encode(
            TimingsBody(
                decodeMs: timings.decodeMilliseconds,
                workingCopyMs: timings.workingCopyMilliseconds,
                previewMs: timings.previewMilliseconds
            ),
            forKey: .timings
        )
    }
}

/// `renderWorkingCopy`'s `meta`: one object per source kind, told apart by
/// its `kind` (`raw` / `raster`).
private struct WorkingCopyMetaBody: Encodable {
    let meta: WorkingCopyMeta

    init(_ meta: WorkingCopyMeta) {
        self.meta = meta
    }

    private enum RAWKeys: String, CodingKey {
        case kind, engine, decoderVersion, baselineEV, calibration, asShotWhite, orientationApplied
        case lensCorrection, noiseReduction, sharpness, encoding, colorSpace, sourceExtension
    }

    private enum RasterKeys: String, CodingKey {
        case kind, cms, icc, orientationApplied, encoding, colorSpace, sourceExtension
    }

    private struct AsShotWhiteBody: Encodable {
        let x: Double
        let y: Double
        let temperature: Int
        let tint: Int
    }

    private struct NoiseReductionBody: Encodable {
        let luminance: Double
        let color: Double
    }

    private struct EncodingBody: Encodable {
        let format: String
        let gamma: Double
        let ceiling: Double

        init(_ encoding: WorkingCopyMeta.Encoding) {
            format = encoding.format
            gamma = encoding.gamma
            ceiling = encoding.ceiling
        }
    }

    private struct ICCBody: Encodable {
        let icc: WorkingCopyMeta.ICC

        private enum CodingKeys: String, CodingKey {
            case sha256
            case profileDescription = "description"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let sha256 = icc.sha256 {
                try container.encode(sha256, forKey: .sha256)
            } else {
                try container.encodeNil(forKey: .sha256)
            }
            if let description = icc.description {
                try container.encode(description, forKey: .profileDescription)
            } else {
                try container.encodeNil(forKey: .profileDescription)
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch meta {
        case let .raw(raw):
            var container = encoder.container(keyedBy: RAWKeys.self)
            try container.encode("raw", forKey: .kind)
            try container.encode(raw.engine, forKey: .engine)
            try container.encode(raw.decoderVersion, forKey: .decoderVersion)
            try container.encode(raw.baselineEV, forKey: .baselineEV)
            try container.encode(raw.calibration, forKey: .calibration)
            let white = raw.asShotWhite
            try container.encode(
                AsShotWhiteBody(x: white.x, y: white.y, temperature: white.temperature, tint: white.tint),
                forKey: .asShotWhite
            )
            try container.encode(raw.orientationApplied, forKey: .orientationApplied)
            if let lensCorrection = raw.lensCorrection {
                try container.encode(lensCorrection, forKey: .lensCorrection)
            } else {
                try container.encodeNil(forKey: .lensCorrection)
            }
            try container.encode(
                NoiseReductionBody(luminance: raw.noiseReduction.luminance, color: raw.noiseReduction.color),
                forKey: .noiseReduction
            )
            try container.encode(raw.sharpness, forKey: .sharpness)
            try container.encode(EncodingBody(raw.encoding), forKey: .encoding)
            try container.encode(raw.colorSpace, forKey: .colorSpace)
            try container.encode(raw.sourceExtension, forKey: .sourceExtension)
        case let .raster(raster):
            var container = encoder.container(keyedBy: RasterKeys.self)
            try container.encode("raster", forKey: .kind)
            try container.encode(raster.cms, forKey: .cms)
            try container.encode(ICCBody(icc: raster.icc), forKey: .icc)
            try container.encode(raster.orientationApplied, forKey: .orientationApplied)
            try container.encode(EncodingBody(raster.encoding), forKey: .encoding)
            try container.encode(raster.colorSpace, forKey: .colorSpace)
            try container.encode(raster.sourceExtension, forKey: .sourceExtension)
        }
    }
}

// MARK: - Responses

/// One response: the JSON header line (without its newline) and, for a
/// binary response, the body that follows it.
struct EngineResponse: Sendable {
    let id: Int
    let header: Data
    let binary: Data?

    private struct SuccessHeader<Result: Encodable>: Encodable {
        let id: Int
        let ok: Bool
        let result: Result
        let binaryLength: Int?
        let mime: String?
    }

    private struct FailureHeader: Encodable {
        struct Body: Encodable {
            let code: String
            let message: String
        }

        let id: Int
        let ok: Bool
        let error: Body
    }

    static func success<Result: Encodable>(id: Int, result: Result) -> EngineResponse {
        encode(id: id, SuccessHeader(id: id, ok: true, result: result, binaryLength: nil, mime: nil), binary: nil)
    }

    static func binary<Result: Encodable>(id: Int, result: Result, body: Data, mime: String) -> EngineResponse {
        encode(
            id: id,
            SuccessHeader(id: id, ok: true, result: result, binaryLength: body.count, mime: mime),
            binary: body
        )
    }

    static func failure(id: Int, error: EngineError) -> EngineResponse {
        encode(
            id: id,
            FailureHeader(id: id, ok: false, error: .init(code: error.code.rawValue, message: error.message)),
            binary: nil
        )
    }

    private static func encode(id: Int, _ header: some Encodable, binary: Data?) -> EngineResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            return EngineResponse(id: id, header: try encoder.encode(header), binary: binary)
        } catch {
            // Only reachable if a result cannot be encoded (a non-finite
            // number): answer the request rather than leave it pending.
            let fallback = #"{"id":\#(id),"ok":false,"error":{"code":"internal","message":"応答を JSON にできません"}}"#
            return EngineResponse(id: id, header: Data(fallback.utf8), binary: nil)
        }
    }
}
