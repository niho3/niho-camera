import Darwin
import Foundation
import PhotoCore

/// This suite deliberately has no production/calibrated state. Promoting an
/// observation requires a different manifest schema and a separate review.
public enum WhiteBalanceObservationAdoptionStatus: String, Codable, Sendable {
    case exploratoryObservationOnly = "exploratory-observation-only"
}

public struct WhiteBalanceObservationManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let suiteID: String
    public let description: String
    public let adoptionStatus: WhiteBalanceObservationAdoptionStatus
    public let baseCalibrationManifest: WhiteBalanceObservationBaseManifest
    public let expectedEnvironment: ExpectedEnvironment
    public let processing: WhiteBalanceObservationProcessing
    public let output: WhiteBalanceObservationOutputContract
    public let setterOrder: WhiteBalanceObservationSetterOrderContract
    public let candidatePlan: WhiteBalanceObservationCandidatePlan
    public let scenes: [WhiteBalanceObservationScene]
}

public struct WhiteBalanceObservationBaseManifest: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let suiteID: String
    public let schemaVersion: Int
}

public struct WhiteBalanceObservationProcessing: Codable, Equatable, Sendable {
    public let legacyAsShotDecoder: String
    public let customRAWDecoder: String
    public let renderPipeline: String
    public let sourceFiles: [String]
}

public struct WhiteBalanceObservationOutputContract: Codable, Equatable, Sendable {
    public let maxDimension: Int
    public let outputFormat: String
    public let outputColorSpace: String
    public let bitsPerChannel: Int
    public let downsamplingFilter: String
    public let outputTransformPlacement: String
    public let sourceMetadataPolicy: String
}

public struct WhiteBalanceObservationSetterOrderContract: Codable, Equatable, Sendable {
    public let primary: RAWNeutralSetterOrder
    public let comparison: RAWNeutralSetterOrder
    public let exactByteEqualityRequired: Bool
}

public struct WhiteBalanceObservationCorner: Codable, Equatable, Sendable {
    public let temperatureMiredOffset: Int
    public let tintOffset: Int
}

public struct WhiteBalanceObservationCandidatePlan: Codable, Equatable, Sendable {
    public let temperatureMiredOffsets: [Int]
    public let tintOffsets: [Int]
    public let corners: [WhiteBalanceObservationCorner]
    public let includesAsShot: Bool
    public let includesCustomCenter: Bool
    public let expectedCandidateCountPerScene: Int
}

public struct WhiteBalanceObservationTeacher: Codable, Equatable, Sendable {
    public let software: String
    public let processVersion: String
    public let cameraProfile: String
    public let whiteBalanceMode: String
    public let temperatureKelvin: Int
    public let tint: Int
}

public struct WhiteBalanceObservationScene: Codable, Equatable, Sendable {
    public let id: String
    public let sceneGroup: String
    public let fold: String
    public let raw: HashedFixture
    public let lightroomReference: HashedFixture
    public let teacher: WhiteBalanceObservationTeacher
}

public struct LoadedWhiteBalanceObservationManifest: Sendable {
    public let manifest: WhiteBalanceObservationManifest
    public let root: URL
    public let manifestURL: URL
    public let manifestSHA256: String
    public let base: LoadedCalibrationManifest
    public let verifiedInputs: [VerifiedFile]

    public func resolve(_ relativePath: String) throws -> URL {
        try CalibrationManifestLoader.resolve(relativePath, inside: root)
    }

    public func verifyManifestAgain() throws -> String {
        let actual = try SHA256Digest.file(manifestURL)
        guard actual == manifestSHA256 else {
            throw CalibrationManifestError.hashMismatch(
                path: manifestURL.path,
                expected: manifestSHA256,
                actual: actual
            )
        }
        return actual
    }

    public func verifyInputsAgain() throws -> [VerifiedFile] {
        try WhiteBalanceObservationManifestLoader.verifyInputs(manifest, root: root)
    }
}

public struct WhiteBalanceObservationCandidate: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case asShot = "as-shot"
        case customCenter = "custom-center"
        case temperatureAxis = "temperature-axis"
        case tintAxis = "tint-axis"
        case corner
    }

    public let id: String
    public let kind: Kind
    public let temperatureMiredOffset: Int
    public let tintOffset: Int
    public let customWhiteBalance: RAWCustomWhiteBalance?
}

public enum WhiteBalanceObservationManifestLoader {
    public static let defaultRelativePath =
        "calibration/white-balance-observation-v1.json"
    public static let requiredTemperatureMiredOffsets = [-100, -60, -30, 0, 30, 60, 100]
    public static let requiredTintOffsets = [-60, -30, -15, 0, 15, 30, 60]
    public static let requiredCorners = [
        WhiteBalanceObservationCorner(temperatureMiredOffset: -30, tintOffset: -15),
        WhiteBalanceObservationCorner(temperatureMiredOffset: -30, tintOffset: 15),
        WhiteBalanceObservationCorner(temperatureMiredOffset: 30, tintOffset: -15),
        WhiteBalanceObservationCorner(temperatureMiredOffset: 30, tintOffset: 15)
    ]
    public static let requiredSourceFiles = [
        "Package.swift",
        "Sources/PhotoCore/PhotoCoreProcessingFingerprint.swift",
        "Sources/PhotoCore/Spatial/SpatialToneOps.swift",
        "Sources/PhotoCore/CoreImageDecoder.swift",
        "Sources/PhotoCore/RAWWhiteBalanceDecoder.swift",
        "Sources/PhotoCore/EditSettings.swift",
        "Sources/PhotoCore/OKLabColor.swift",
        "Sources/PhotoCore/AdobeProfile/ColorOps.swift",
        "Sources/PhotoCore/RenderEngine.swift",
        "Sources/PhotoCore/PhotoLibrary.swift",
        "Sources/PhotoCore/SRGBOutputTransform.swift",
        "Sources/PhotoCore/ToneCurveModel.swift",
        "Sources/PhotoCore/XMPPresetParser.swift",
        "Sources/PhotoCore/AdobeBaseRenderer.swift",
        "Sources/PhotoCore/LibRawDecoder.swift",
        "Sources/PhotoCore/PhotoDecoder.swift",
        "Sources/PhotoCore/AdobeProfile/AdobeBaseCalibration.swift",
        "Sources/PhotoCore/AdobeProfile/AdobeColorMath.swift",
        "Sources/PhotoCore/AdobeProfile/AdobeLookXMP.swift",
        "Sources/PhotoCore/AdobeProfile/AdobeProfileLocator.swift",
        "Sources/PhotoCore/AdobeProfile/ColorSpec.swift",
        "Sources/PhotoCore/AdobeProfile/DCPProfile.swift",
        "Sources/PhotoCore/AdobeProfile/HueSatMap.swift",
        "Sources/PhotoCore/AdobeProfile/RGBTone.swift",
        "Sources/PhotoCore/AdobeProfile/ToneOps.swift",
        "Sources/PhotoCore/Lens/LensDistortion.swift",
        "Sources/PhotoCore/Lens/PanasonicRW2Metadata.swift",
        "Sources/PhotoCore/Spatial/SpatialToneMetalSource.swift",
        "Sources/PhotoCore/Spatial/SpatialToneProcessor.swift",
        "Sources/PhotoCore/WorkingCopyRenderer.swift",
        "Sources/PhotoBenchCalibrationSupport/BenchmarkModels.swift",
        "Sources/PhotoBenchCalibrationSupport/CalibrationManifest.swift",
        "Sources/PhotoBenchCalibrationSupport/CalibrationRun.swift",
        "Sources/PhotoBenchCalibrationSupport/CalibrationStages.swift",
        "Sources/PhotoBenchCalibrationSupport/WhiteBalanceObservation.swift",
        "Sources/PhotoBenchApp/ContentView.swift",
        "Sources/PhotoBenchApp/EditorModel.swift",
        "Sources/PhotoBenchApp/PhotoBenchApp.swift",
        "Sources/PhotoBenchApp/RenderCoordinator.swift",
        "Sources/PhotoBenchAppSupport/FolderAccess.swift",
        "Sources/PhotoBenchCalibration/main.swift",
        "Sources/PhotoBenchBenchmark/main.swift",
        "scripts/analyze-calibration.py",
        "Sources/PhotoBenchWhiteBalanceObservation/main.swift",
        "scripts/analyze-white-balance-observation.py"
    ]
    public static let observationOnlySourceFiles = [
        "Sources/PhotoBenchWhiteBalanceObservation/main.swift",
        "scripts/analyze-white-balance-observation.py"
    ]

    public static func load(
        root: URL,
        manifestURL explicitManifestURL: URL? = nil
    ) throws -> LoadedWhiteBalanceObservationManifest {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let requestedURL = explicitManifestURL
            ?? normalizedRoot.appendingPathComponent(defaultRelativePath)
        let manifestURL = try CalibrationManifestLoader.resolve(
            relativePath(requestedURL, root: normalizedRoot),
            inside: normalizedRoot
        )
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CalibrationManifestError.missingFile(
                relativePath(manifestURL, root: normalizedRoot)
            )
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(
            WhiteBalanceObservationManifest.self,
            from: data
        )
        try validateStructure(manifest)

        let baseURL = try CalibrationManifestLoader.resolve(
            manifest.baseCalibrationManifest.path,
            inside: normalizedRoot
        )
        let actualBaseHash = try SHA256Digest.file(baseURL)
        guard actualBaseHash == manifest.baseCalibrationManifest.sha256 else {
            throw CalibrationManifestError.hashMismatch(
                path: manifest.baseCalibrationManifest.path,
                expected: manifest.baseCalibrationManifest.sha256,
                actual: actualBaseHash
            )
        }
        let base = try CalibrationManifestLoader.load(
            root: normalizedRoot,
            manifestURL: baseURL
        )
        try validateAgainstBase(manifest, base: base)
        let verifiedInputs = try verifyInputs(manifest, root: normalizedRoot)
        return LoadedWhiteBalanceObservationManifest(
            manifest: manifest,
            root: normalizedRoot,
            manifestURL: manifestURL,
            manifestSHA256: SHA256Digest.data(data),
            base: base,
            verifiedInputs: verifiedInputs
        )
    }

    public static func validateStructure(
        _ manifest: WhiteBalanceObservationManifest
    ) throws {
        guard manifest.schemaVersion == 1 else {
            throw CalibrationManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.adoptionStatus == .exploratoryObservationOnly else {
            throw CalibrationManifestError.invalid(
                "WB observationはexploratory-observation-onlyに固定されています"
            )
        }
        try requireText(manifest.suiteID, field: "suiteID")
        try requireText(manifest.description, field: "description")
        try validateHash(
            manifest.baseCalibrationManifest.sha256,
            field: "baseCalibrationManifest.sha256"
        )
        guard manifest.baseCalibrationManifest.schemaVersion == 4 else {
            throw CalibrationManifestError.invalid("base calibration schemaはv4に固定です")
        }
        guard manifest.processing.legacyAsShotDecoder
                == CoreImageDecoder.processingIdentifier,
              manifest.processing.customRAWDecoder
                == CoreImageRAWWhiteBalanceDecoder.customProcessingIdentifier,
              manifest.processing.renderPipeline == RenderEngine.processingIdentifier,
              manifest.processing.sourceFiles == requiredSourceFiles
        else {
            throw CalibrationManifestError.invalid("WB observation processing契約が不一致です")
        }
        guard manifest.output.maxDimension == 1_500,
              manifest.output.outputFormat == "RGBA16 sRGB TIFF",
              manifest.output.outputColorSpace == "sRGB IEC61966-2.1",
              manifest.output.bitsPerChannel == 16,
              manifest.output.downsamplingFilter == "CILanczosScaleTransform",
              manifest.output.outputTransformPlacement == "after-downsampling",
              manifest.output.sourceMetadataPolicy
                == "pixel-only; canonical sRGB ICC only; source EXIF/XMP/IPTC/GPS removed"
        else {
            throw CalibrationManifestError.invalid("WB observation output契約が不一致です")
        }
        guard manifest.setterOrder.primary == .temperatureThenTint,
              manifest.setterOrder.comparison == .tintThenTemperature,
              manifest.setterOrder.exactByteEqualityRequired
        else {
            throw CalibrationManifestError.invalid("neutral setter-order契約が不一致です")
        }
        let plan = manifest.candidatePlan
        guard plan.temperatureMiredOffsets == requiredTemperatureMiredOffsets,
              plan.tintOffsets == requiredTintOffsets,
              plan.corners == requiredCorners,
              plan.includesAsShot,
              plan.includesCustomCenter,
              plan.expectedCandidateCountPerScene == 18
        else {
            throw CalibrationManifestError.invalid("WB candidate planが固定matrixと不一致です")
        }
        guard manifest.scenes.count == 2 else {
            throw CalibrationManifestError.invalid(
                "WB observation v1はdevelopment 2 scenes専用です"
            )
        }
        let sceneIDs = manifest.scenes.map(\.id)
        guard Set(sceneIDs).count == sceneIDs.count else {
            throw CalibrationManifestError.invalid("WB observation scene idが重複しています")
        }
        for scene in manifest.scenes {
            try requireSafeIdentifier(scene.id, field: "scene.id")
            try requireText(scene.sceneGroup, field: "scene.sceneGroup")
            guard scene.fold == "development" else {
                throw CalibrationManifestError.invalid(
                    "WB observation v1の全sceneはdevelopmentでなければなりません"
                )
            }
            try validateFixture(scene.raw, field: "\(scene.id).raw")
            try validateFixture(
                scene.lightroomReference,
                field: "\(scene.id).lightroomReference"
            )
            let teacher = scene.teacher
            guard teacher.software == "Adobe Lightroom 9.3 (Macintosh)",
                  teacher.processVersion == "15.4",
                  teacher.cameraProfile == "Adobe Standard",
                  teacher.whiteBalanceMode == "As Shot",
                  (2_000 ... 50_000).contains(teacher.temperatureKelvin),
                  (-150 ... 150).contains(teacher.tint)
            else {
                throw CalibrationManifestError.invalid(
                    "scene \(scene.id) のLightroom teacher契約が不正です"
                )
            }
        }
    }

    public static func candidates(
        plan: WhiteBalanceObservationCandidatePlan,
        source: RAWNeutralValues
    ) throws -> [WhiteBalanceObservationCandidate] {
        guard plan.temperatureMiredOffsets == requiredTemperatureMiredOffsets,
              plan.tintOffsets == requiredTintOffsets,
              plan.corners == requiredCorners,
              plan.includesAsShot,
              plan.includesCustomCenter,
              plan.expectedCandidateCountPerScene == 18
        else {
            throw CalibrationManifestError.invalid("candidate生成前にplanが変更されました")
        }
        guard source.temperatureKelvin.isFinite,
              RAWCustomWhiteBalance.temperatureRange.contains(source.temperatureKelvin),
              source.tint.isFinite,
              RAWCustomWhiteBalance.tintRange.contains(source.tint)
        else {
            throw CalibrationManifestError.invalid("source As Shot neutralが範囲外です")
        }

        var result = [
            WhiteBalanceObservationCandidate(
                id: "as-shot",
                kind: .asShot,
                temperatureMiredOffset: 0,
                tintOffset: 0,
                customWhiteBalance: nil
            ),
            WhiteBalanceObservationCandidate(
                id: "custom-center",
                kind: .customCenter,
                temperatureMiredOffset: 0,
                tintOffset: 0,
                customWhiteBalance: try RAWCustomWhiteBalance(
                    temperatureKelvin: source.temperatureKelvin,
                    tint: source.tint
                )
            )
        ]
        for offset in plan.temperatureMiredOffsets where offset != 0 {
            result.append(
                try customCandidate(
                    id: "temperature-mired-\(signedLabel(offset))",
                    kind: .temperatureAxis,
                    source: source,
                    temperatureMiredOffset: offset,
                    tintOffset: 0
                )
            )
        }
        for offset in plan.tintOffsets where offset != 0 {
            result.append(
                try customCandidate(
                    id: "tint-\(signedLabel(offset))",
                    kind: .tintAxis,
                    source: source,
                    temperatureMiredOffset: 0,
                    tintOffset: offset
                )
            )
        }
        for corner in plan.corners {
            result.append(
                try customCandidate(
                    id: "corner-mired-\(signedLabel(corner.temperatureMiredOffset))-tint-\(signedLabel(corner.tintOffset))",
                    kind: .corner,
                    source: source,
                    temperatureMiredOffset: corner.temperatureMiredOffset,
                    tintOffset: corner.tintOffset
                )
            )
        }
        guard result.count == plan.expectedCandidateCountPerScene,
              Set(result.map(\.id)).count == result.count
        else {
            throw CalibrationManifestError.invalid("展開後のWB candidateが18件ではありません")
        }
        return result
    }

    public static func verifyInputs(
        _ manifest: WhiteBalanceObservationManifest,
        root: URL
    ) throws -> [VerifiedFile] {
        var result: [VerifiedFile] = []
        for scene in manifest.scenes {
            for (role, fixture) in [
                ("\(scene.id).raw", scene.raw),
                ("\(scene.id).lightroomReference", scene.lightroomReference)
            ] {
                let url = try CalibrationManifestLoader.resolve(fixture.path, inside: root)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw CalibrationManifestError.missingFile(fixture.path)
                }
                let actual = try SHA256Digest.file(url)
                guard actual == fixture.sha256 else {
                    throw CalibrationManifestError.hashMismatch(
                        path: fixture.path,
                        expected: fixture.sha256,
                        actual: actual
                    )
                }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                result.append(
                    VerifiedFile(
                        role: role,
                        path: fixture.path,
                        sha256: actual,
                        byteCount: UInt64(values.fileSize ?? 0)
                    )
                )
            }
        }
        return result
    }

    private static func validateAgainstBase(
        _ manifest: WhiteBalanceObservationManifest,
        base: LoadedCalibrationManifest
    ) throws {
        let reference = manifest.baseCalibrationManifest
        guard base.manifestSHA256 == reference.sha256,
              base.manifest.suiteID == reference.suiteID,
              base.manifest.schemaVersion == reference.schemaVersion,
              base.manifest.expectedEnvironment == manifest.expectedEnvironment
        else {
            throw CalibrationManifestError.invalid("base calibration参照が一致しません")
        }
        guard manifest.processing.sourceFiles
                == base.manifest.processing.sourceFiles + observationOnlySourceFiles
        else {
            throw CalibrationManifestError.invalid(
                "WB observation sourceはbase calibration全sourceと観測専用sourceの和でなければなりません"
            )
        }
        guard manifest.scenes.map(\.id) == base.manifest.scenes.map(\.id) else {
            throw CalibrationManifestError.invalid("scene順序がbase calibrationと一致しません")
        }
        for scene in manifest.scenes {
            guard let baseScene = base.manifest.scenes.first(where: { $0.id == scene.id }),
                  scene.sceneGroup == baseScene.sceneGroup,
                  scene.fold == baseScene.fold,
                  scene.raw == baseScene.raw,
                  scene.lightroomReference == baseScene.lightroomBefore,
                  scene.teacher.temperatureKelvin
                    == baseScene.capture.lightroomColorTemperature
            else {
                throw CalibrationManifestError.invalid(
                    "scene \(scene.id) がbase calibrationと一致しません"
                )
            }
        }
    }

    private static func customCandidate(
        id: String,
        kind: WhiteBalanceObservationCandidate.Kind,
        source: RAWNeutralValues,
        temperatureMiredOffset: Int,
        tintOffset: Int
    ) throws -> WhiteBalanceObservationCandidate {
        let sourceMired = 1_000_000 / source.temperatureKelvin
        let targetMired = sourceMired + Double(temperatureMiredOffset)
        guard targetMired.isFinite, targetMired > 0 else {
            throw CalibrationManifestError.invalid("mired offsetが正の色温度を生成しません")
        }
        let request = try RAWCustomWhiteBalance(
            temperatureKelvin: 1_000_000 / targetMired,
            tint: source.tint + Double(tintOffset)
        )
        return WhiteBalanceObservationCandidate(
            id: id,
            kind: kind,
            temperatureMiredOffset: temperatureMiredOffset,
            tintOffset: tintOffset,
            customWhiteBalance: request
        )
    }

    private static func signedLabel(_ value: Int) -> String {
        value < 0
            ? "minus-\(String(format: "%03d", abs(value)))"
            : "plus-\(String(format: "%03d", value))"
    }

    private static func validateFixture(_ fixture: HashedFixture, field: String) throws {
        try validateHash(fixture.sha256, field: "\(field).sha256")
        guard !fixture.path.isEmpty,
              !NSString(string: fixture.path).isAbsolutePath,
              !fixture.path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !fixture.path.contains("\0")
        else {
            throw CalibrationManifestError.pathEscapesRoot(fixture.path)
        }
    }

    private static func validateHash(_ value: String, field: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.count == 64,
              value == value.lowercased(),
              value.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw CalibrationManifestError.invalid("\(field)はlowercase SHA-256ではありません")
        }
    }

    private static func requireText(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalibrationManifestError.invalid("\(field)が空です")
        }
    }

    private static func requireSafeIdentifier(_ value: String, field: String) throws {
        try requireText(value, field: field)
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
        )
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CalibrationManifestError.invalid("\(field)に未対応文字があります: \(value)")
        }
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedURL = url.standardizedFileURL
        let prefix = normalizedRoot.path.hasSuffix("/")
            ? normalizedRoot.path
            : normalizedRoot.path + "/"
        guard normalizedURL.path.hasPrefix(prefix) else { return normalizedURL.path }
        return String(normalizedURL.path.dropFirst(prefix.count))
    }
}

public enum WhiteBalanceObservationOutput {
    public static let rootRelativePath = ".photobench/white-balance-observations"

    public static func prepareNewRunDirectory(runID: String, root: URL) throws -> URL {
        guard let uuid = UUID(uuidString: runID),
              uuid.uuidString.lowercased() == runID
        else {
            throw CalibrationManifestError.invalid("WB observation run IDがcanonical UUIDではありません")
        }
        let parent = try CalibrationManifestLoader.prepareOutputDirectory(
            rootRelativePath,
            inside: root
        )
        let candidate = parent.appendingPathComponent(runID, isDirectory: true)
        do {
            // A fresh UUID directory is the ownership boundary for the whole
            // run. Atomic mkdir closes the check/create race and makes every
            // descendant write private to this invocation.
            try FileManager.default.createDirectory(
                at: candidate,
                withIntermediateDirectories: false
            )
        } catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain,
               cocoa.code == CocoaError.fileWriteFileExists.rawValue {
                throw CalibrationManifestError.invalid(
                    "既存または競合したWB observation runは再開・上書きできません"
                )
            }
            throw CalibrationManifestError.invalid(
                "WB observation run directoryを作成できません: \(error.localizedDescription)"
            )
        }
        return try CalibrationManifestLoader.prepareOutputDirectory(
            "\(rootRelativePath)/\(runID)",
            inside: root
        )
    }

    public static func prepareNewFile(
        named fileName: String,
        in directory: URL,
        root: URL
    ) throws -> URL {
        let destination = try CalibrationManifestLoader.prepareOutputFile(
            named: fileName,
            in: directory,
            inside: root
        )
        if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
            throw CalibrationManifestError.invalid("既存WB observation成果物は上書きできません")
        }
        return destination
    }

    /// Publishes immutable JSON evidence without ever replacing an existing
    /// path. The temporary file and destination are on the same filesystem;
    /// hard-link creation is the atomic no-replace commit point.
    public static func writeNewJSON<T: Encodable>(
        _ value: T,
        to destination: URL,
        root: URL
    ) throws {
        let validated = try prepareNewFile(
            named: destination.lastPathComponent,
            in: destination.deletingLastPathComponent(),
            root: root
        )
        guard validated.standardizedFileURL.path == destination.standardizedFileURL.path else {
            throw CalibrationManifestError.invalid("WB JSON destinationの検証結果が一致しません")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value) + Data("\n".utf8)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString.lowercased()).json.tmp")
        try writeExclusive(data, to: temporary)
        do {
            try FileManager.default.linkItem(at: temporary, to: destination)
            try FileManager.default.removeItem(at: temporary)
            try synchronizeDirectory(destination.deletingLastPathComponent())
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CalibrationManifestError.invalid(
                "WB JSON evidenceのexclusive publishに失敗しました: \(error.localizedDescription)"
            )
        }
    }

    private static func writeExclusive(_ data: Data, to destination: URL) throws {
        let descriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CalibrationManifestError.invalid(
                "WB JSON staging fileをexclusive作成できません: \(String(cString: strerror(errno)))"
            )
        }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove { try? FileManager.default.removeItem(at: destination) }
        }
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CalibrationManifestError.invalid(
                        "WB JSON staging writeに失敗しました: \(String(cString: strerror(errno)))"
                    )
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw CalibrationManifestError.invalid(
                    "WB JSON staging fsyncに失敗しました: \(String(cString: strerror(errno)))"
                )
            }
        }
        shouldRemove = false
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CalibrationManifestError.invalid(
                "WB output directoryを開けません: \(String(cString: strerror(errno)))"
            )
        }
        defer { Darwin.close(descriptor) }
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw CalibrationManifestError.invalid(
                    "WB output directory fsyncに失敗しました: \(String(cString: strerror(errno)))"
                )
            }
        }
    }
}

public struct WhiteBalanceObservationToolProvenance: Codable, Equatable, Sendable {
    public let path: String
    public let version: String
    public let sha256: String

    public init(path: String, version: String, sha256: String) {
        self.path = path
        self.version = version
        self.sha256 = sha256
    }
}

public struct WhiteBalanceObservationMetadataAudit: Codable, Equatable, Sendable {
    public let imageIOPropertyKeys: [String]
    public let exifToolTagKeys: [String]
    public let iccProfileDescription: String
    public let sourceMetadataAbsent: Bool

    public init(
        imageIOPropertyKeys: [String],
        exifToolTagKeys: [String],
        iccProfileDescription: String,
        sourceMetadataAbsent: Bool
    ) {
        self.imageIOPropertyKeys = imageIOPropertyKeys
        self.exifToolTagKeys = exifToolTagKeys
        self.iccProfileDescription = iccProfileDescription
        self.sourceMetadataAbsent = sourceMetadataAbsent
    }
}

public struct WhiteBalanceObservationArtifact: Codable, Equatable, Sendable {
    public let role: String
    public let sceneID: String
    public let candidateID: String?
    public let candidateKind: String?
    public let requestMode: String
    public let temperatureMiredOffset: Int?
    public let tintOffset: Int?
    public let requested: RAWCustomWhiteBalance?
    public let decodeProvenance: RAWWhiteBalanceDecodeProvenance?
    public let path: String
    public let sha256: String
    public let byteCount: UInt64
    public let width: Int
    public let height: Int
    public let renderAndEncodeMilliseconds: Double
    public let metadataAudit: WhiteBalanceObservationMetadataAudit

    public init(
        role: String,
        sceneID: String,
        candidateID: String?,
        candidateKind: String?,
        requestMode: String,
        temperatureMiredOffset: Int?,
        tintOffset: Int?,
        requested: RAWCustomWhiteBalance?,
        decodeProvenance: RAWWhiteBalanceDecodeProvenance?,
        path: String,
        sha256: String,
        byteCount: UInt64,
        width: Int,
        height: Int,
        renderAndEncodeMilliseconds: Double,
        metadataAudit: WhiteBalanceObservationMetadataAudit
    ) {
        self.role = role
        self.sceneID = sceneID
        self.candidateID = candidateID
        self.candidateKind = candidateKind
        self.requestMode = requestMode
        self.temperatureMiredOffset = temperatureMiredOffset
        self.tintOffset = tintOffset
        self.requested = requested
        self.decodeProvenance = decodeProvenance
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.renderAndEncodeMilliseconds = renderAndEncodeMilliseconds
        self.metadataAudit = metadataAudit
    }
}

public struct WhiteBalanceObservationSceneRecord: Codable, Equatable, Sendable {
    public let sceneID: String
    public let fold: String
    public let sourceNeutral: RAWNeutralValues
    public let teacher: WhiteBalanceObservationTeacher
    public let candidateIDs: [String]

    public init(
        sceneID: String,
        fold: String,
        sourceNeutral: RAWNeutralValues,
        teacher: WhiteBalanceObservationTeacher,
        candidateIDs: [String]
    ) {
        self.sceneID = sceneID
        self.fold = fold
        self.sourceNeutral = sourceNeutral
        self.teacher = teacher
        self.candidateIDs = candidateIDs
    }
}

public struct WhiteBalanceObservationSetterOrderRecord: Codable, Equatable, Sendable {
    public let sceneID: String
    public let candidateID: String
    public let primaryOrder: RAWNeutralSetterOrder
    public let comparisonOrder: RAWNeutralSetterOrder
    public let primarySHA256: String
    public let comparisonSHA256: String
    public let byteExact: Bool

    public init(
        sceneID: String,
        candidateID: String,
        primaryOrder: RAWNeutralSetterOrder,
        comparisonOrder: RAWNeutralSetterOrder,
        primarySHA256: String,
        comparisonSHA256: String,
        byteExact: Bool
    ) {
        self.sceneID = sceneID
        self.candidateID = candidateID
        self.primaryOrder = primaryOrder
        self.comparisonOrder = comparisonOrder
        self.primarySHA256 = primarySHA256
        self.comparisonSHA256 = comparisonSHA256
        self.byteExact = byteExact
    }
}

public struct WhiteBalanceObservationIncompleteSentinel: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let status: String
    public let runID: String
    public let startedAtUTC: String
    public let manifestSHA256: String

    public init(runID: String, startedAtUTC: String, manifestSHA256: String) {
        schemaVersion = 1
        status = "incomplete"
        self.runID = runID
        self.startedAtUTC = startedAtUTC
        self.manifestSHA256 = manifestSHA256
    }
}

public struct WhiteBalanceObservationRun: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let status: String
    public let adoptionStatus: WhiteBalanceObservationAdoptionStatus
    public let productionAdoptionAllowed: Bool
    public let runID: String
    public let startedAtUTC: String
    public let completedAtUTC: String
    public let manifest: ManifestRunReference
    public let baseCalibrationManifest: ManifestRunReference
    public let runtime: RuntimeProvenance
    public let exifTool: WhiteBalanceObservationToolProvenance
    public let sourceFingerprintSHA256: String
    public let postflightSourceFingerprintSHA256: String
    public let sourceFiles: [VerifiedFile]
    public let verifiedInputs: [VerifiedFile]
    public let postflightVerifiedInputs: [VerifiedFile]
    public let sceneCount: Int
    public let holdoutCount: Int
    public let scenes: [WhiteBalanceObservationSceneRecord]
    public let artifacts: [WhiteBalanceObservationArtifact]
    public let setterOrderChecks: [WhiteBalanceObservationSetterOrderRecord]

    public init(
        runID: String,
        startedAtUTC: String,
        completedAtUTC: String,
        manifest: ManifestRunReference,
        baseCalibrationManifest: ManifestRunReference,
        runtime: RuntimeProvenance,
        exifTool: WhiteBalanceObservationToolProvenance,
        sourceFingerprintSHA256: String,
        postflightSourceFingerprintSHA256: String,
        sourceFiles: [VerifiedFile],
        verifiedInputs: [VerifiedFile],
        postflightVerifiedInputs: [VerifiedFile],
        scenes: [WhiteBalanceObservationSceneRecord],
        artifacts: [WhiteBalanceObservationArtifact],
        setterOrderChecks: [WhiteBalanceObservationSetterOrderRecord]
    ) {
        schemaVersion = 1
        status = "complete"
        adoptionStatus = .exploratoryObservationOnly
        productionAdoptionAllowed = false
        self.runID = runID
        self.startedAtUTC = startedAtUTC
        self.completedAtUTC = completedAtUTC
        self.manifest = manifest
        self.baseCalibrationManifest = baseCalibrationManifest
        self.runtime = runtime
        self.exifTool = exifTool
        self.sourceFingerprintSHA256 = sourceFingerprintSHA256
        self.postflightSourceFingerprintSHA256 = postflightSourceFingerprintSHA256
        self.sourceFiles = sourceFiles
        self.verifiedInputs = verifiedInputs
        self.postflightVerifiedInputs = postflightVerifiedInputs
        sceneCount = scenes.count
        holdoutCount = scenes.filter { $0.fold == "holdout" }.count
        self.scenes = scenes
        self.artifacts = artifacts
        self.setterOrderChecks = setterOrderChecks
    }
}
