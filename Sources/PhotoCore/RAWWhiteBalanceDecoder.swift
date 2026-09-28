import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Metal

/// A validated Core Image temperature/tint pair.
///
/// These values belong to Core Image's decoder space. They are not Adobe XMP
/// values and must never be treated as a cross-backend white-balance identity.
public struct RAWCustomWhiteBalance: Codable, Equatable, Sendable {
    public static let temperatureRange = 2_000.0 ... 50_000.0
    public static let tintRange = -150.0 ... 150.0

    public let temperatureKelvin: Double
    public let tint: Double

    public init(temperatureKelvin: Double, tint: Double) throws {
        let floatTemperature = Float(temperatureKelvin)
        guard Self.isNormalFinite(temperatureKelvin),
              Self.temperatureRange.contains(temperatureKelvin),
              floatTemperature.isFinite,
              floatTemperature.isNormal
        else {
            throw RAWWhiteBalanceDecoderError.invalidTemperature(temperatureKelvin)
        }
        let floatTint = Float(tint)
        guard Self.isNormalFiniteOrZero(tint),
              Self.tintRange.contains(tint),
              floatTint.isFinite,
              floatTint.isNormal || floatTint == 0,
              tint == 0 || floatTint != 0
        else {
            throw RAWWhiteBalanceDecoderError.invalidTint(tint)
        }
        self.temperatureKelvin = temperatureKelvin
        // Collapse signed zero before it reaches a framework parameter or a
        // provenance hash. +0 and -0 are the same user request here.
        self.tint = tint == 0 ? 0 : tint
    }

    private enum CodingKeys: String, CodingKey {
        case temperatureKelvin
        case tint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            temperatureKelvin: container.decode(Double.self, forKey: .temperatureKelvin),
            tint: container.decode(Double.self, forKey: .tint)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(temperatureKelvin, forKey: .temperatureKelvin)
        try container.encode(tint, forKey: .tint)
    }

    private static func isNormalFinite(_ value: Double) -> Bool {
        value.isFinite && value.isNormal
    }

    private static func isNormalFiniteOrZero(_ value: Double) -> Bool {
        value.isFinite && (value.isNormal || value == 0)
    }
}

public enum RAWWhiteBalanceRequest: Equatable, Sendable {
    /// Delegates to the existing decoder without observing or writing any
    /// CIRAWFilter neutral property.
    case asShot
    /// Core Image decoder-space values; not Adobe Temperature/Tint.
    case custom(RAWCustomWhiteBalance)
}

public enum RAWNeutralSetterOrder: String, Codable, Equatable, Sendable {
    case temperatureThenTint = "temperature-then-tint"
    case tintThenTemperature = "tint-then-temperature"
}

public struct RAWNeutralValues: Codable, Equatable, Sendable {
    public let temperatureKelvin: Double
    public let tint: Double
    public let chromaticityX: Double
    public let chromaticityY: Double

    public init(
        temperatureKelvin: Double,
        tint: Double,
        chromaticityX: Double,
        chromaticityY: Double
    ) {
        self.temperatureKelvin = temperatureKelvin
        self.tint = tint
        self.chromaticityX = chromaticityX
        self.chromaticityY = chromaticityY
    }
}

public struct RAWWhiteBalanceDecodeConfiguration: Codable, Equatable, Sendable {
    public let exposure: Double
    public let shadowBias: Double
    public let boostAmount: Double
    public let boostShadowAmount: Double
    public let extendedDynamicRangeAmount: Double
    public let scaleFactor: Double
    public let draftModeEnabled: Bool
    public let gamutMappingEnabled: Bool

    public init(raw: RAWDecodeConfiguration, scaleFactor: Float) {
        exposure = Double(raw.exposure)
        shadowBias = Double(raw.shadowBias)
        boostAmount = Double(raw.boostAmount)
        boostShadowAmount = Double(raw.boostShadowAmount)
        extendedDynamicRangeAmount = Double(raw.extendedDynamicRangeAmount)
        self.scaleFactor = Double(scaleFactor)
        draftModeEnabled = false
        gamutMappingEnabled = true
    }
}

/// Decoder evidence for one explicit white-balance request.
///
/// `sourceAsShot` intentionally remains nil for `.asShot`. Reading it would
/// touch the lazy CIRAWFilter and weaken the guarantee that the legacy path is
/// unchanged. It is observed only on the isolated custom path.
public struct RAWWhiteBalanceDecodeProvenance: Codable, Equatable, Sendable {
    public let processingIdentifier: String
    public let requestMode: String
    public let neutralPropertiesObserved: Bool
    public let requested: RAWCustomWhiteBalance?
    public let sourceAsShot: RAWNeutralValues?
    public let applied: RAWNeutralValues?
    public let setterOrder: RAWNeutralSetterOrder?
    public let neutralLocationPolicy: String
    public let decoderVersion: String
    public let supportedDecoderVersions: [String]
    public let appRAWCalibrationProfileID: String?
    public let decodeConfiguration: RAWWhiteBalanceDecodeConfiguration?
    public let intent: String
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int
    public let cameraMake: String?
    public let cameraModel: String?
    public let macOSVersion: String
    public let macOSBuild: String
    public let architecture: String
    public let hardwareModel: String
    public let metalDevice: String?
    public let coreImageFrameworkVersion: String?
    public let supportedCameraModelsSHA256: String
    public let appleCameraProfileObservability: String
    public let colorSpacePolicy: String
}

public struct RAWWhiteBalanceDecodedPhoto: @unchecked Sendable {
    public let decoded: DecodedPhoto
    public let provenance: RAWWhiteBalanceDecodeProvenance

    public init(decoded: DecodedPhoto, provenance: RAWWhiteBalanceDecodeProvenance) {
        self.decoded = decoded
        self.provenance = provenance
    }
}

public enum RAWWhiteBalanceDecoderError: LocalizedError, Equatable {
    case invalidTemperature(Double)
    case invalidTint(Double)
    case customWhiteBalanceRequiresRAW(URL)
    case rawDecodeFailed(URL)
    case validatedDecoderUnavailable([String])
    case invalidPreviewMaximumDimension(Int)
    case invalidNativeDimensions(URL)
    case invalidNeutralReadback(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidTemperature(value):
            "Core Image RAW色温度が不正です: \(value)"
        case let .invalidTint(value):
            "Core Image RAW tintが不正です: \(value)"
        case let .customWhiteBalanceRequiresRAW(url):
            "custom RAWホワイトバランスはRAW画像だけに適用できます: \(url.lastPathComponent)"
        case let .rawDecodeFailed(url):
            "customホワイトバランスでRAWを現像できません: \(url.lastPathComponent)"
        case let .validatedDecoderUnavailable(versions):
            "検証済みのCore Image RAW 8 decoderを利用できません: \(versions.joined(separator: ", "))"
        case let .invalidPreviewMaximumDimension(value):
            "プレビューの最大辺は1以上で指定してください: \(value)"
        case let .invalidNativeDimensions(url):
            "RAWの原寸サイズを確認できません: \(url.lastPathComponent)"
        case let .invalidNeutralReadback(field):
            "CIRAWFilterのホワイトバランスreadbackが不正です: \(field)"
        }
    }
}

/// An isolated decode path for explicit Core Image RAW white balance.
///
/// The existing `CoreImageDecoder` remains the only production As Shot path.
/// This wrapper delegates `.asShot` to it verbatim and creates a fresh RAW
/// filter only for `.custom`, preventing exploratory neutral-property reads
/// from changing existing pixels or fingerprints.
public struct CoreImageRAWWhiteBalanceDecoder: Sendable {
    public static let customProcessingIdentifier =
        "core-image-raw8-custom-neutral-temperature-tint-v1"
    public static let colorSpacePolicy =
        "CIRAWFilter gamut mapping enabled; downstream extended-linear-sRGB edits; terminal sRGB output"
    public static let appleCameraProfileObservability = "unavailable-in-public-api"

    private let legacyDecoder: CoreImageDecoder
    private let rawConfigurationOverride: RAWDecodeConfiguration?

    public init(rawConfiguration: RAWDecodeConfiguration? = nil) {
        legacyDecoder = CoreImageDecoder(rawConfiguration: rawConfiguration)
        rawConfigurationOverride = rawConfiguration
    }

    public func decode(
        url: URL,
        intent: ImageDecodeIntent = .fullResolution,
        whiteBalance: RAWWhiteBalanceRequest
    ) throws -> RAWWhiteBalanceDecodedPhoto {
        switch whiteBalance {
        case .asShot:
            let decoded = try legacyDecoder.decode(url: url, intent: intent)
            return RAWWhiteBalanceDecodedPhoto(
                decoded: decoded,
                provenance: Self.asShotProvenance(decoded: decoded)
            )
        case let .custom(request):
            return try decodeCustom(
                url: url,
                intent: intent,
                request: request,
                setterOrder: .temperatureThenTint
            )
        }
    }

    /// Package-only characterization hook. The public API fixes
    /// temperature-then-tint; reverse order can be exercised only by the
    /// observation executable and tests.
    package func decodeForObservation(
        url: URL,
        intent: ImageDecodeIntent = .fullResolution,
        customWhiteBalance: RAWCustomWhiteBalance,
        setterOrder: RAWNeutralSetterOrder
    ) throws -> RAWWhiteBalanceDecodedPhoto {
        try decodeCustom(
            url: url,
            intent: intent,
            request: customWhiteBalance,
            setterOrder: setterOrder
        )
    }

    /// Reads a fresh filter's source neutral only on the isolated observation
    /// path. The legacy As Shot decoder never calls this method.
    package func observeSourceNeutral(url: URL) throws -> RAWNeutralValues {
        guard PhotoKind.detect(url: url) == .raw else {
            throw RAWWhiteBalanceDecoderError.customWhiteBalanceRequiresRAW(url)
        }
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RAWWhiteBalanceDecoderError.rawDecodeFailed(url)
        }
        let versions = filter.supportedDecoderVersions
        guard versions.contains(.version8) else {
            throw RAWWhiteBalanceDecoderError.validatedDecoderUnavailable(
                versions.map(\.rawValue)
            )
        }
        filter.decoderVersion = .version8
        return try Self.neutralValues(filter: filter, label: "source-as-shot-observation")
    }

    private func decodeCustom(
        url: URL,
        intent: ImageDecodeIntent,
        request: RAWCustomWhiteBalance,
        setterOrder: RAWNeutralSetterOrder
    ) throws -> RAWWhiteBalanceDecodedPhoto {
        if let maximumDimension = intent.requestedMaximumDimension, maximumDimension < 1 {
            throw RAWWhiteBalanceDecoderError.invalidPreviewMaximumDimension(maximumDimension)
        }
        guard PhotoKind.detect(url: url) == .raw else {
            throw RAWWhiteBalanceDecoderError.customWhiteBalanceRequiresRAW(url)
        }

        let started = ContinuousClock.now
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RAWWhiteBalanceDecoderError.rawDecodeFailed(url)
        }
        let supportedDecoderVersions = filter.supportedDecoderVersions
        guard supportedDecoderVersions.contains(.version8) else {
            throw RAWWhiteBalanceDecoderError.validatedDecoderUnavailable(
                supportedDecoderVersions.map(\.rawValue)
            )
        }
        filter.decoderVersion = .version8
        let nativeSize = filter.nativeSize
        guard let nativeWidth = CoreImageDecoder.validatedPixelDimension(nativeSize.width),
              let nativeHeight = CoreImageDecoder.validatedPixelDimension(nativeSize.height)
        else {
            throw RAWWhiteBalanceDecoderError.invalidNativeDimensions(url)
        }

        let metadata = Self.readMetadata(url: url)
        let camera = Self.cameraIdentity(metadata: metadata)
        let profile: RAWCalibrationProfile
        if let rawConfigurationOverride {
            profile = RAWCalibrationProfile(
                id: "manual-calibration-override",
                label: "校正ツール指定値",
                configuration: rawConfigurationOverride
            )
        } else {
            profile = RAWCalibrationProfile.matching(make: camera.make, model: camera.model)
        }

        let raw = profile.configuration
        filter.exposure = raw.exposure
        filter.shadowBias = raw.shadowBias
        filter.boostAmount = raw.boostAmount
        filter.boostShadowAmount = raw.boostShadowAmount
        filter.extendedDynamicRangeAmount = raw.extendedDynamicRangeAmount
        let scaleFactor: Float
        switch intent {
        case let .interactivePreview(maxDimension):
            scaleFactor = min(1, Float(CGFloat(maxDimension) / max(nativeSize.width, nativeSize.height)))
        case .fullResolution:
            scaleFactor = 1
        }
        filter.scaleFactor = scaleFactor
        filter.isDraftModeEnabled = false
        filter.isGamutMappingEnabled = true

        // Only the isolated custom path observes the source neutral.
        let sourceAsShot = try Self.neutralValues(filter: filter, label: "source-as-shot")
        switch setterOrder {
        case .temperatureThenTint:
            filter.neutralTemperature = Float(request.temperatureKelvin)
            filter.neutralTint = Float(request.tint)
        case .tintThenTemperature:
            filter.neutralTint = Float(request.tint)
            filter.neutralTemperature = Float(request.temperatureKelvin)
        }
        let applied = try Self.neutralValues(filter: filter, label: "applied")
        guard let image = filter.outputImage else {
            throw RAWWhiteBalanceDecoderError.rawDecodeFailed(url)
        }
        guard let outputWidth = CoreImageDecoder.validatedPixelDimension(image.extent.width),
              let outputHeight = CoreImageDecoder.validatedPixelDimension(image.extent.height)
        else {
            throw RAWWhiteBalanceDecoderError.invalidNativeDimensions(url)
        }
        let duration = Self.milliseconds(started.duration(to: .now))
        let decoded = DecodedPhoto(
            sourceURL: url,
            image: image,
            metadata: metadata,
            info: DecodeInfo(
                backend: "Core Image RAW \(filter.decoderVersion.rawValue)",
                width: outputWidth,
                height: outputHeight,
                durationMilliseconds: duration,
                isRAW: true,
                cameraMake: camera.make,
                cameraModel: camera.model,
                calibrationID: profile.id,
                calibrationLabel: profile.label,
                intent: intent,
                requestedMaximumDimension: intent.requestedMaximumDimension,
                nativeWidth: nativeWidth,
                nativeHeight: nativeHeight,
                appliedScaleFactor: scaleFactor
            )
        )
        let environment = Self.environment()
        let provenance = RAWWhiteBalanceDecodeProvenance(
            processingIdentifier: Self.customProcessingIdentifier,
            requestMode: "custom-core-image-neutral",
            neutralPropertiesObserved: true,
            requested: request,
            sourceAsShot: sourceAsShot,
            applied: applied,
            setterOrder: setterOrder,
            neutralLocationPolicy: "unused",
            decoderVersion: filter.decoderVersion.rawValue,
            supportedDecoderVersions: supportedDecoderVersions.map(\.rawValue),
            appRAWCalibrationProfileID: profile.id,
            decodeConfiguration: RAWWhiteBalanceDecodeConfiguration(
                raw: raw,
                scaleFactor: scaleFactor
            ),
            intent: intent.identifier,
            nativeWidth: nativeWidth,
            nativeHeight: nativeHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            cameraMake: camera.make,
            cameraModel: camera.model,
            macOSVersion: environment.macOSVersion,
            macOSBuild: environment.macOSBuild,
            architecture: environment.architecture,
            hardwareModel: environment.hardwareModel,
            metalDevice: environment.metalDevice,
            coreImageFrameworkVersion: environment.coreImageFrameworkVersion,
            supportedCameraModelsSHA256: Self.supportedCameraModelsSHA256,
            appleCameraProfileObservability: Self.appleCameraProfileObservability,
            colorSpacePolicy: Self.colorSpacePolicy
        )
        return RAWWhiteBalanceDecodedPhoto(decoded: decoded, provenance: provenance)
    }

    private static func asShotProvenance(
        decoded: DecodedPhoto
    ) -> RAWWhiteBalanceDecodeProvenance {
        let environment = environment()
        return RAWWhiteBalanceDecodeProvenance(
            processingIdentifier: CoreImageDecoder.processingIdentifier,
            requestMode: "as-shot-untouched",
            neutralPropertiesObserved: false,
            requested: nil,
            sourceAsShot: nil,
            applied: nil,
            setterOrder: nil,
            neutralLocationPolicy: "unused",
            decoderVersion: decoded.info.backend.split(separator: " ").last.map(String.init) ?? "unknown",
            supportedDecoderVersions: [],
            appRAWCalibrationProfileID: decoded.info.calibrationID,
            decodeConfiguration: nil,
            intent: decoded.info.intent.identifier,
            nativeWidth: decoded.info.nativeWidth,
            nativeHeight: decoded.info.nativeHeight,
            outputWidth: decoded.info.width,
            outputHeight: decoded.info.height,
            cameraMake: decoded.info.cameraMake,
            cameraModel: decoded.info.cameraModel,
            macOSVersion: environment.macOSVersion,
            macOSBuild: environment.macOSBuild,
            architecture: environment.architecture,
            hardwareModel: environment.hardwareModel,
            metalDevice: environment.metalDevice,
            coreImageFrameworkVersion: environment.coreImageFrameworkVersion,
            supportedCameraModelsSHA256: supportedCameraModelsSHA256,
            appleCameraProfileObservability: appleCameraProfileObservability,
            colorSpacePolicy: colorSpacePolicy
        )
    }

    /// Also reads `WorkingCopyRenderer`'s as-shot white (the same readback
    /// and the same checks).
    static func neutralValues(
        filter: CIRAWFilter,
        label: String
    ) throws -> RAWNeutralValues {
        let temperature = Double(filter.neutralTemperature)
        let tint = Double(filter.neutralTint)
        let xy = filter.neutralChromaticity
        guard temperature.isFinite, temperature.isNormal,
              tint.isFinite, tint.isNormal || tint == 0,
              xy.x.isFinite, xy.y.isFinite,
              xy.x > 0, xy.y > 0,
              xy.x <= 1, xy.y <= 1,
              xy.x + xy.y <= 1
        else {
            throw RAWWhiteBalanceDecoderError.invalidNeutralReadback(label)
        }
        return RAWNeutralValues(
            temperatureKelvin: temperature,
            tint: tint == 0 ? 0 : tint,
            chromaticityX: Double(xy.x),
            chromaticityY: Double(xy.y)
        )
    }

    private static func cameraIdentity(
        metadata: [String: Any]
    ) -> (make: String?, model: String?) {
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake as String] as? String)
            ?? metadata[kCGImagePropertyTIFFMake as String] as? String
        let model = (tiff?[kCGImagePropertyTIFFModel as String] as? String)
            ?? metadata[kCGImagePropertyTIFFModel as String] as? String
        return (make, model)
    }

    private static func readMetadata(url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any]
        else { return [:] }
        return properties
    }

    private static let supportedCameraModelsSHA256: String = {
        let payload = CIRAWFilter.supportedCameraModels.sorted().joined(separator: "\u{0}")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }()

    private static func environment() -> (
        macOSVersion: String,
        macOSBuild: String,
        architecture: String,
        hardwareModel: String,
        metalDevice: String?,
        coreImageFrameworkVersion: String?
    ) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let description = ProcessInfo.processInfo.operatingSystemVersionString
        let build: String
        if let marker = description.range(of: "(Build "),
           let closing = description[marker.upperBound...].firstIndex(of: ")") {
            build = String(description[marker.upperBound ..< closing])
        } else {
            build = sysctlString("kern.osversion") ?? "unknown"
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return (
            macOSVersion: version,
            macOSBuild: build,
            architecture: architecture,
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            metalDevice: MTLCreateSystemDefaultDevice()?.name,
            coreImageFrameworkVersion: Bundle(identifier: "com.apple.CoreImage")?
                .object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
