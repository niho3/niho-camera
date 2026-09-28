import Foundation
import ImageIO
import PhotoBenchCalibrationSupport
import PhotoCore
import Testing

@Suite("Calibration manifest and stage support")
struct CalibrationSupportTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func productionManifestIsStructurallyValidAndHashLocked() throws {
        let loaded = try CalibrationManifestLoader.load(root: projectRoot)
        let previewParity = try #require(loaded.manifest.previewParity)

        let settleGate = try #require(loaded.manifest.canonicalSettleGate)

        #expect(loaded.manifest.schemaVersion == 4)
        #expect(loaded.manifest.scenes.count == 2)
        #expect(loaded.manifest.stageMatrix.count == 12)
        #expect(loaded.manifest.processing.sourceFiles.count == 43)
        #expect(loaded.manifest.processing.fingerprint == .current)
        #expect(previewParity.maxDimension == nil)
        #expect(
            previewParity.outputMaxDimension
                == loaded.manifest.benchmark.previewMaxDimension
        )
        #expect(previewParity.candidateDecodeMaximumDimensions == [3_072, 3_840])
        #expect(previewParity.plateauSpatialTolerance?.radiusPixels == 1)
        #expect(
            previewParity.plateauSpatialTolerance?.structuringElement == "square-3x3"
        )
        #expect(previewParity.settingsStageIDs == ["neutral", "basic-legacy", "full-current"])
        #expect(previewParity.baselineDecodeIntent == "full-resolution")
        #expect(previewParity.candidateDecodeIntent == "interactive-preview")
        #expect(previewParity.thresholds.meanDeltaEMaximum == 1)
        #expect(previewParity.thresholds.blurredDeltaE2000P95Maximum == 2)
        #expect(previewParity.thresholds.meanEVAbsoluteDriftMaximum == 0.02)
        #expect(previewParity.thresholds.newSharedPlateauMaximumArea == nil)
        #expect(previewParity.thresholds.netSharedPlateauAreaIncreaseMaximum == 0.000_1)
        #expect(
            previewParity.thresholds.spatiallyDistinctNewSharedPlateauMaximumArea
                == 0.000_1
        )
        #expect(settleGate.outputMaxDimension == 2_560)
        #expect(settleGate.downsamplingFilter == "CILanczosScaleTransform")
        #expect(settleGate.inputAspectRatio == 1)
        #expect(settleGate.workingColorSpace == "extended-linear-sRGB")
        #expect(settleGate.outputTransformPlacement == "after-downsampling")
        #expect(settleGate.baselineStageID == "basic-legacy")
        #expect(settleGate.candidateStageID == "full-current")
        #expect(
            abs(
                settleGate.thresholds.completeClipNormalizedMinimum
                    - (1 - 0.5 / 65_535)
            ) < 0.000_000_000_001
        )
        #expect(settleGate.thresholds.nearClipNormalizedMinimum == 0.999)
        #expect(settleGate.thresholds.completeClipMaximumPixelCountIncrease == 0)
        #expect(settleGate.thresholds.nearClipMaximumPixelCountIncrease == 0)
        #expect(settleGate.thresholds.newSharedPlateauMaximumArea == 0.0005)
        #expect(loaded.manifest.benchmark.warmupIterations == 5)
        #expect(loaded.manifest.benchmark.processFreshIterations == 40)
        #expect(
            CalibrationManifestLoader.expectedArtifactRelativePaths(for: loaded.manifest).count
                == 122
        )
        let artifactPaths = Set(
            CalibrationManifestLoader.expectedArtifactRelativePaths(for: loaded.manifest)
        )
        for scene in loaded.manifest.scenes {
            for stageID in previewParity.settingsStageIDs {
                #expect(
                    artifactPaths.contains(
                        ".photobench/calibration/renders/\(scene.id)-preview-parity-\(stageID)-full-decode-to-2560.tif"
                    )
                )
                for candidateDimension in [3_072, 3_840] {
                    #expect(
                        artifactPaths.contains(
                            ".photobench/calibration/renders/\(scene.id)-preview-parity-\(stageID)-decode-\(candidateDimension)-to-2560.tif"
                        )
                    )
                }
            }
        }
        #expect(loaded.verifiedInputs.count == 7)
        #expect(loaded.verifiedInputs.allSatisfy { $0.sha256.count == 64 })
    }

    @Test func schemaV1ManifestRemainsExplicitlyLoadable() throws {
        let loaded = try CalibrationManifestLoader.load(
            root: projectRoot,
            manifestURL: projectRoot.appendingPathComponent("calibration/manifest-v1.json")
        )

        #expect(loaded.manifest.schemaVersion == 1)
        #expect(loaded.manifest.previewParity == nil)
        #expect(loaded.manifest.canonicalSettleGate == nil)
        #expect(
            loaded.manifest.processing.fingerprint.rawDecode
                == PhotoCoreProcessingFingerprint.legacyRawDecodeIdentifier
        )
        #expect(
            CalibrationManifestLoader.expectedArtifactRelativePaths(for: loaded.manifest).count
                == 104
        )
    }

    @Test func schemaV2ManifestRemainsExplicitlyLoadable() throws {
        let loaded = try CalibrationManifestLoader.load(
            root: projectRoot,
            manifestURL: projectRoot.appendingPathComponent("calibration/manifest-v2.json")
        )
        let previewParity = try #require(loaded.manifest.previewParity)

        #expect(loaded.manifest.schemaVersion == 2)
        #expect(loaded.manifest.canonicalSettleGate == nil)
        #expect(previewParity.maxDimension == 2_560)
        #expect(previewParity.outputMaxDimension == nil)
        #expect(previewParity.candidateDecodeMaximumDimensions == nil)
        #expect(previewParity.plateauSpatialTolerance == nil)
        #expect(previewParity.thresholds.newSharedPlateauMaximumArea == 0.000_1)
        #expect(previewParity.thresholds.blurredDeltaE2000P95Maximum == nil)
        #expect(previewParity.thresholds.netSharedPlateauAreaIncreaseMaximum == nil)
        #expect(
            CalibrationManifestLoader.expectedArtifactRelativePaths(for: loaded.manifest).count
                == 116
        )
    }

    @Test func schemaV3ManifestRemainsHistoricalAndExplicitlyLoadable() throws {
        let loaded = try CalibrationManifestLoader.load(
            root: projectRoot,
            manifestURL: projectRoot.appendingPathComponent("calibration/manifest-v3.json")
        )

        #expect(loaded.manifest.schemaVersion == 3)
        #expect(loaded.manifest.canonicalSettleGate == nil)
        #expect(
            loaded.manifest.processing.fingerprint
                == PhotoCoreProcessingFingerprint.legacyCurrentRawDecode
        )
        #expect(
            CalibrationManifestLoader.expectedArtifactRelativePaths(for: loaded.manifest).count
                == 122
        )
    }

    @Test func lanczosComparisonExportMaterializesTheRequestedFinalDimension() throws {
        let sourceURL = projectRoot.appendingPathComponent("P1524180.RW2")
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchLanczosTests-\(UUID().uuidString)")
        let outputURL = outputDirectory.appendingPathComponent("candidate-300.tif")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let decoded = try CoreImageDecoder().decode(
            url: sourceURL,
            intent: .interactivePreview(maxDimension: 384)
        )
        _ = try RenderEngine().exportTIFF(
            decoded: decoded,
            settings: .neutral,
            destination: outputURL,
            maxDimension: 300,
            downsamplingFilter: .lanczos
        )

        let source = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 300)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 200)
        #expect(properties[kCGImagePropertyDepth as String] as? Int == 16)
    }

    @Test func pathTraversalAndAbsolutePathsAreRejected() throws {
        #expect(throws: CalibrationManifestError.self) {
            _ = try CalibrationManifestLoader.resolve("../outside", inside: projectRoot)
        }
        #expect(throws: CalibrationManifestError.self) {
            _ = try CalibrationManifestLoader.resolve("/tmp/outside", inside: projectRoot)
        }
    }

    @Test func manifestPathCannotEscapeRootDirectlyOrThroughSymlink() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchManifestPathTests-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        let outside = sandbox.appendingPathComponent("outside.json")
        let link = root.appendingPathComponent("manifest-link.json")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: CalibrationManifestError.self) {
            _ = try CalibrationManifestLoader.load(root: root, manifestURL: outside)
        }
        #expect(throws: CalibrationManifestError.self) {
            _ = try CalibrationManifestLoader.load(root: root, manifestURL: link)
        }
    }

    @Test func generatedOutputRejectsSymlinkedDirectoriesAndFiles() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchOutputPathTests-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        let outputLink = root.appendingPathComponent(".photobench")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outputLink, withDestinationURL: outside)

        #expect(throws: CalibrationManifestError.self) {
            _ = try CalibrationManifestLoader.prepareOutputDirectory(
                ".photobench/calibration",
                inside: root
            )
        }

        try FileManager.default.removeItem(at: outputLink)
        let safeDirectory = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/calibration",
            inside: root
        )
        let outsideFile = outside.appendingPathComponent("victim.json")
        let outputFile = safeDirectory.appendingPathComponent("run-manifest.json")
        try Data("do-not-change".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: outputFile, withDestinationURL: outsideFile)

        #expect(throws: CalibrationManifestError.self) {
            _ = try CalibrationManifestLoader.prepareOutputFile(
                named: "run-manifest.json",
                in: safeDirectory,
                inside: root
            )
        }
        #expect(try Data(contentsOf: outsideFile) == Data("do-not-change".utf8))
    }

    @Test func schemaAndFixedCandidateMatricesFailClosed() throws {
        let unsupported = try mutatedManifest { object in
            object["schemaVersion"] = 99
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(unsupported)
        }

        let duplicateStage = try mutatedManifest { object in
            var stages = object["stageMatrix"] as! [[String: Any]]
            stages[1] = stages[0]
            object["stageMatrix"] = stages
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(duplicateStage)
        }

        let wrongRoute = try mutatedManifest { object in
            var gate = object["qualityGate"] as! [String: Any]
            var routes = gate["routes"] as! [[String: Any]]
            routes[0]["fullLabel"] = "xmp-basic"
            gate["routes"] = routes
            object["qualityGate"] = gate
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(wrongRoute)
        }

        let wrongLegacyLabel = try mutatedManifest { object in
            var candidates = object["legacyCandidates"] as! [[String: Any]]
            candidates[0]["rawLabel"] = "xmp-renamed-exposure"
            object["legacyCandidates"] = candidates
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(wrongLegacyLabel)
        }

        let wrongStageLabel = try mutatedManifest { object in
            var stages = object["stageMatrix"] as! [[String: Any]]
            stages[0]["rawLabel"] = "xmp-stage-renamed"
            object["stageMatrix"] = stages
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(wrongStageLabel)
        }

        let wrongRAWProfile = try mutatedManifest { object in
            var rawProfile = object["rawProfile"] as! [String: Any]
            rawProfile["boostAmount"] = 0.8
            object["rawProfile"] = rawProfile
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(wrongRAWProfile)
        }

        let wrongComparison = try mutatedManifest { object in
            var comparison = object["comparison"] as! [String: Any]
            comparison["outputFormat"] = "RGBA8 TIFF"
            object["comparison"] = comparison
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(wrongComparison)
        }

        let collidingArtifactPaths = try mutatedManifest { object in
            var scenes = object["scenes"] as! [[String: Any]]
            scenes[0]["id"] = "collision"
            scenes[1]["id"] = "collision-lr-input"
            object["scenes"] = scenes
            var benchmark = object["benchmark"] as! [String: Any]
            benchmark["sceneID"] = "collision"
            object["benchmark"] = benchmark
        }
        do {
            try CalibrationManifestLoader.validateStructure(collidingArtifactPaths)
            Issue.record("sceneとlabelの合成後に重複するartifact pathを受理しました")
        } catch let error as CalibrationManifestError {
            #expect(
                error == .invalid(
                    "校正artifact output pathがsceneとlabelの合成後に重複しています"
                )
            )
        } catch {
            Issue.record("想定外のerrorです: \(error)")
        }

        let caseOnlyArtifactAliases = try mutatedManifest { object in
            var scenes = object["scenes"] as! [[String: Any]]
            scenes[0]["id"] = "CaseCollision"
            scenes[1]["id"] = "casecollision"
            object["scenes"] = scenes
            var benchmark = object["benchmark"] as! [String: Any]
            benchmark["sceneID"] = "CaseCollision"
            object["benchmark"] = benchmark
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(caseOnlyArtifactAliases)
        }
    }

    @Test func schemaV4PreviewParityContractFailsClosed() throws {
        let missingPreviewParity = try mutatedManifest { object in
            object.removeValue(forKey: "previewParity")
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(missingPreviewParity)
        }

        let wrongDimension = try mutatedManifest { object in
            var previewParity = object["previewParity"] as! [String: Any]
            previewParity["outputMaxDimension"] = 1_500
            object["previewParity"] = previewParity
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(wrongDimension)
        }

        let noncanonicalOutputDimension = try mutatedManifest { object in
            var previewParity = object["previewParity"] as! [String: Any]
            previewParity["outputMaxDimension"] = 2_048
            object["previewParity"] = previewParity
            var benchmark = object["benchmark"] as! [String: Any]
            benchmark["previewMaxDimension"] = 2_048
            object["benchmark"] = benchmark
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(noncanonicalOutputDimension)
        }

        for candidateDimensions in [[3_840, 3_072], [3_072, 3_072]] {
            let invalidCandidates = try mutatedManifest { object in
                var previewParity = object["previewParity"] as! [String: Any]
                previewParity["candidateDecodeMaximumDimensions"] = candidateDimensions
                object["previewParity"] = previewParity
            }
            #expect(throws: CalibrationManifestError.self) {
                try CalibrationManifestLoader.validateStructure(invalidCandidates)
            }
        }

        let candidateExceedsSceneNativeSize = try mutatedManifest { object in
            var scenes = object["scenes"] as! [[String: Any]]
            var capture = scenes[0]["capture"] as! [String: Any]
            capture["width"] = 3_000
            capture["height"] = 2_000
            scenes[0]["capture"] = capture
            object["scenes"] = scenes
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(candidateExceedsSceneNativeSize)
        }

        let reorderedStages = try mutatedManifest { object in
            var previewParity = object["previewParity"] as! [String: Any]
            previewParity["settingsStageIDs"] = ["neutral", "full-current", "basic-legacy"]
            object["previewParity"] = previewParity
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(reorderedStages)
        }

        let wrongIntent = try mutatedManifest { object in
            var previewParity = object["previewParity"] as! [String: Any]
            previewParity["candidateDecodeIntent"] = "post-decode-resize"
            object["previewParity"] = previewParity
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(wrongIntent)
        }

        for (field, value) in [
            ("radiusPixels", 2 as Any),
            ("structuringElement", "disk-3x3" as Any)
        ] {
            let wrongSpatialTolerance = try mutatedManifest { object in
                var previewParity = object["previewParity"] as! [String: Any]
                var spatialTolerance =
                    previewParity["plateauSpatialTolerance"] as! [String: Any]
                spatialTolerance[field] = value
                previewParity["plateauSpatialTolerance"] = spatialTolerance
                object["previewParity"] = previewParity
            }
            #expect(throws: CalibrationManifestError.self) {
                try CalibrationManifestLoader.validateStructure(wrongSpatialTolerance)
            }
        }

        for (field, weakenedValue) in [
            ("meanDeltaEMaximum", 1.000_001),
            ("blurredDeltaE2000P95Maximum", 2.000_001),
            ("meanEVAbsoluteDriftMaximum", 0.020_001),
            ("netSharedPlateauAreaIncreaseMaximum", 0.000_101),
            ("spatiallyDistinctNewSharedPlateauMaximumArea", 0.000_101)
        ] {
            let weakenedThreshold = try mutatedManifest { object in
                var previewParity = object["previewParity"] as! [String: Any]
                var thresholds = previewParity["thresholds"] as! [String: Any]
                thresholds[field] = weakenedValue
                previewParity["thresholds"] = thresholds
                object["previewParity"] = previewParity
            }
            #expect(throws: CalibrationManifestError.self) {
                try CalibrationManifestLoader.validateStructure(weakenedThreshold)
            }
        }

        for legacyField in ["maxDimension", "newSharedPlateauMaximumArea"] {
            let mixedSchema = try mutatedManifest { object in
                var previewParity = object["previewParity"] as! [String: Any]
                if legacyField == "maxDimension" {
                    previewParity[legacyField] = 2_560
                } else {
                    var thresholds = previewParity["thresholds"] as! [String: Any]
                    thresholds[legacyField] = 0.000_1
                    previewParity["thresholds"] = thresholds
                }
                object["previewParity"] = previewParity
            }
            #expect(throws: CalibrationManifestError.self) {
                try CalibrationManifestLoader.validateStructure(mixedSchema)
            }
        }

        let previewParityInV1 = try mutatedManifest { object in
            object["schemaVersion"] = 1
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(previewParityInV1)
        }

        let wrongDecodeFingerprint = try mutatedManifest { object in
            var processing = object["processing"] as! [String: Any]
            var fingerprint = processing["fingerprint"] as! [String: Any]
            fingerprint["rawDecode"] = "unversioned-preview-policy"
            processing["fingerprint"] = fingerprint
            object["processing"] = processing
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(wrongDecodeFingerprint)
        }
    }

    @Test func schemaV4CanonicalSettleAndFingerprintFailClosed() throws {
        let missingGate = try mutatedManifest { object in
            object.removeValue(forKey: "canonicalSettleGate")
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(missingGate)
        }

        for (field, value) in [
            ("outputMaxDimension", 2_048 as Any),
            ("downsamplingFilter", "CIAffineTransform" as Any),
            ("inputAspectRatio", 0.9 as Any),
            ("workingColorSpace", "sRGB" as Any),
            ("outputTransformPlacement", "before-downsampling" as Any),
            ("baselineStageID", "neutral" as Any),
            ("candidateStageID", "basic-legacy" as Any)
        ] {
            let wrongContract = try mutatedManifest { object in
                var gate = object["canonicalSettleGate"] as! [String: Any]
                gate[field] = value
                object["canonicalSettleGate"] = gate
            }
            #expect(throws: CalibrationManifestError.self) {
                try CalibrationManifestLoader.validateStructure(wrongContract)
            }
        }

        for (field, value) in [
            ("completeClipNormalizedMinimum", 0.999 as Any),
            ("nearClipNormalizedMinimum", 0.998 as Any),
            ("completeClipMaximumPixelCountIncrease", 1 as Any),
            ("nearClipMaximumPixelCountIncrease", 1 as Any),
            ("newSharedPlateauMaximumArea", 0.000_6 as Any)
        ] {
            let wrongThreshold = try mutatedManifest { object in
                var gate = object["canonicalSettleGate"] as! [String: Any]
                var thresholds = gate["thresholds"] as! [String: Any]
                thresholds[field] = value
                gate["thresholds"] = thresholds
                object["canonicalSettleGate"] = gate
            }
            #expect(throws: CalibrationManifestError.self) {
                try CalibrationManifestLoader.validateStructure(wrongThreshold)
            }
        }

        let legacyPipelineInV4 = try mutatedManifest { object in
            var processing = object["processing"] as! [String: Any]
            var fingerprint = processing["fingerprint"] as! [String: Any]
            fingerprint["renderPipeline"] = RenderEngine.legacyProcessingIdentifier
            processing["fingerprint"] = fingerprint
            object["processing"] = processing
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(legacyPipelineInV4)
        }

        let currentPipelineInV3 = try mutatedManifest(
            relativePath: "calibration/manifest-v3.json"
        ) { object in
            var processing = object["processing"] as! [String: Any]
            var fingerprint = processing["fingerprint"] as! [String: Any]
            fingerprint["renderPipeline"] = RenderEngine.processingIdentifier
            processing["fingerprint"] = fingerprint
            object["processing"] = processing
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(currentPipelineInV3)
        }

        let v4GateInV3 = try mutatedManifest { v4 in
            let gate = v4["canonicalSettleGate"]
            let v3URL = projectRoot.appendingPathComponent("calibration/manifest-v3.json")
            var v3 = try! JSONSerialization.jsonObject(
                with: Data(contentsOf: v3URL)
            ) as! [String: Any]
            v3["canonicalSettleGate"] = gate
            v4 = v3
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(v4GateInV3)
        }
    }

    @Test func schemaV2PreviewParityContractRemainsFailClosed() throws {
        let missingPreviewParity = try mutatedManifest(
            relativePath: "calibration/manifest-v2.json"
        ) { object in
            object.removeValue(forKey: "previewParity")
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(missingPreviewParity)
        }

        let wrongDimension = try mutatedManifest(
            relativePath: "calibration/manifest-v2.json"
        ) { object in
            var previewParity = object["previewParity"] as! [String: Any]
            previewParity["maxDimension"] = 1_500
            object["previewParity"] = previewParity
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(wrongDimension)
        }

        let mixedSchema = try mutatedManifest(
            relativePath: "calibration/manifest-v2.json"
        ) { object in
            var previewParity = object["previewParity"] as! [String: Any]
            previewParity["outputMaxDimension"] = 2_560
            previewParity["candidateDecodeMaximumDimensions"] = [3_072, 3_840]
            object["previewParity"] = previewParity
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(mixedSchema)
        }
    }

    @Test func sourceFingerprintManifestCoversEveryProductionRenderingSource() throws {
        let loaded = try CalibrationManifestLoader.load(root: projectRoot)
        var expected: Set<String> = [
            "Package.swift",
            "Sources/PhotoBenchApp/ContentView.swift",
            "Sources/PhotoBenchApp/EditorModel.swift",
            "Sources/PhotoBenchApp/PhotoBenchApp.swift",
            "Sources/PhotoBenchApp/RenderCoordinator.swift",
            "Sources/PhotoBenchAppSupport/FolderAccess.swift",
            "Sources/PhotoBenchCalibration/main.swift",
            "Sources/PhotoBenchBenchmark/main.swift",
            "scripts/analyze-calibration.py"
        ]
        for directory in ["Sources/PhotoCore", "Sources/PhotoBenchCalibrationSupport"] {
            expected.formUnion(
                try swiftSourcePaths(under: directory, root: projectRoot)
            )
        }

        #expect(Set(loaded.manifest.processing.sourceFiles) == expected)
    }

    @Test func manifestPostflightDetectsChangedBytes() throws {
        let production = try CalibrationManifestLoader.load(root: projectRoot)
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchManifestPostflightTests-\(UUID().uuidString)")
        let manifestURL = sandbox.appendingPathComponent("manifest.json")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let original = Data("original".utf8)
        try original.write(to: manifestURL)
        let loaded = LoadedCalibrationManifest(
            manifest: production.manifest,
            root: sandbox,
            manifestURL: manifestURL,
            manifestSHA256: SHA256Digest.data(original),
            verifiedInputs: []
        )

        #expect(try loaded.verifyManifestAgain() == SHA256Digest.data(original))
        try Data("changed".utf8).write(to: manifestURL)
        #expect(throws: CalibrationManifestError.self) {
            _ = try loaded.verifyManifestAgain()
        }
    }

    @Test func hashesAndDiagnosticMatrixAreCanonical() throws {
        let uppercaseHash = try mutatedManifest { object in
            var preset = object["preset"] as! [String: Any]
            var file = preset["file"] as! [String: Any]
            file["sha256"] = (file["sha256"] as! String).uppercased()
            preset["file"] = file
            object["preset"] = preset
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(uppercaseHash)
        }

        let incompleteDiagnostics = try mutatedManifest { object in
            var diagnostics = object["diagnostics"] as! [String: Any]
            diagnostics["extendedDynamicRangeAmounts"] = [0.0, 1.0]
            object["diagnostics"] = diagnostics
        }
        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(incompleteDiagnostics)
        }
    }

    @Test func sha256MatchesKnownVectorAndDetectsChangedBytes() throws {
        #expect(
            SHA256Digest.data(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(SHA256Digest.data(Data("abd".utf8)) != SHA256Digest.data(Data("abc".utf8)))
    }

    @Test func legacyStagesPreserveExistingSemantics() throws {
        let preset = try XMPPresetParser.parse(
            url: projectRoot.appendingPathComponent("niho-priset_colorful.xmp")
        )
        let exposure = try CalibrationStageFactory.settings(
            for: "exposure-only",
            preset: preset
        )
        let tone = try CalibrationStageFactory.settings(for: "tone-base", preset: preset)
        let basic = try CalibrationStageFactory.settings(for: "basic-legacy", preset: preset)
        let full = try CalibrationStageFactory.settings(for: "full-current", preset: preset)
        let neutral = try CalibrationStageFactory.settings(for: "neutral", preset: preset)

        #expect(neutral == .neutral)
        #expect(exposure == EditSettings(exposure: preset.settings.exposure))
        #expect(tone.vibrance == 0)
        #expect(tone.saturation == 0)
        #expect(tone.toneCurves.isEmpty)
        #expect(tone.hsl.isEmpty)
        #expect(basic.vibrance == preset.settings.vibrance)
        #expect(basic.saturation == preset.settings.saturation)
        #expect(basic.toneCurves.isEmpty)
        #expect(basic.hsl.isEmpty)
        #expect(full == preset.settings)
    }

    @Test func stageMatrixIsolatesCurvesAndMixerComponents() throws {
        let preset = try XMPPresetParser.parse(
            url: projectRoot.appendingPathComponent("niho-priset_colorful.xmp")
        )
        let globalCurve = try CalibrationStageFactory.settings(
            for: "tone-plus-global-curve",
            preset: preset
        )
        let rgbCurves = try CalibrationStageFactory.settings(
            for: "tone-plus-rgb-curves",
            preset: preset
        )
        let hue = try CalibrationStageFactory.settings(
            for: "tone-plus-mixer-hue",
            preset: preset
        )
        let saturation = try CalibrationStageFactory.settings(
            for: "tone-plus-mixer-saturation",
            preset: preset
        )
        let luminance = try CalibrationStageFactory.settings(
            for: "tone-plus-mixer-luminance",
            preset: preset
        )

        #expect(globalCurve.toneCurves.allSatisfy { $0.channel == .rgb })
        #expect(rgbCurves.toneCurves.allSatisfy { $0.channel != .rgb })
        #expect(!globalCurve.toneCurves.isEmpty)
        #expect(!rgbCurves.toneCurves.isEmpty)
        #expect(hue.hsl.values.allSatisfy { $0.saturation == 0 && $0.luminance == 0 })
        #expect(saturation.hsl.values.allSatisfy { $0.hue == 0 && $0.luminance == 0 })
        #expect(luminance.hsl.values.allSatisfy { $0.hue == 0 && $0.saturation == 0 })
        #expect(hue.vibrance == 0 && hue.saturation == 0)
    }

    @Test func globalSaturationZeroActsAsIdentitySentinelForCurrentPreset() throws {
        let preset = try XMPPresetParser.parse(
            url: projectRoot.appendingPathComponent("niho-priset_colorful.xmp")
        )
        let tone = try CalibrationStageFactory.settings(for: "tone-base", preset: preset)
        let globalSaturation = try CalibrationStageFactory.settings(
            for: "tone-plus-global-saturation",
            preset: preset
        )

        #expect(preset.settings.saturation == 0)
        #expect(globalSaturation == tone)
        #expect(
            try CalibrationStageFactory.settingsSHA256(
                for: "tone-plus-global-saturation",
                preset: preset
            ) == SHA256Digest.encodable(tone)
        )
    }

    @Test func percentileUsesR7LinearInterpolation() throws {
        let distribution = try BenchmarkDistribution(samples: [0, 10, 20, 30])

        #expect(distribution.p50 == 15)
        #expect(abs(distribution.p95 - 28.5) < 0.000_001)
        #expect(BenchmarkDistribution.percentile([7], quantile: 0.95) == 7)
    }

    @Test func benchmarkDistributionRejectsEmptyAndNonFiniteSamples() {
        #expect(throws: CalibrationManifestError.self) {
            _ = try BenchmarkDistribution(samples: [])
        }
        #expect(throws: CalibrationManifestError.self) {
            _ = try BenchmarkDistribution(samples: [1, .infinity])
        }
    }

    @Test func benchmarkEnforcementSeparatesPassFailureAndIneligibleRuns() throws {
        func gate(_ status: String) -> BenchmarkGateResult {
            BenchmarkGateResult(
                status: status,
                observedP95Milliseconds: 10,
                maximumP95Milliseconds: 20,
                reason: status == "notEvaluated" ? "diagnostic run" : nil
            )
        }

        let passed = try BenchmarkGateEvaluation.evaluate([gate("passed"), gate("passed")])
        #expect(passed == .passed)
        #expect(passed.enforcedExitCode == 0)

        let failed = try BenchmarkGateEvaluation.evaluate([gate("passed"), gate("failed")])
        #expect(failed == .performanceFailed)
        #expect(failed.enforcedExitCode == 1)

        let ineligible = try BenchmarkGateEvaluation.evaluate([
            gate("failed"), gate("notEvaluated")
        ])
        #expect(ineligible == .notEvaluated)
        #expect(ineligible.enforcedExitCode == 2)
    }

    @Test func benchmarkEnforcementRejectsEmptyAndUnknownGateSets() {
        #expect(throws: CalibrationManifestError.self) {
            _ = try BenchmarkGateEvaluation.evaluate([BenchmarkGateResult]())
        }
        #expect(throws: CalibrationManifestError.self) {
            _ = try BenchmarkGateEvaluation.evaluate([
                BenchmarkGateResult(
                    status: "unknown",
                    observedP95Milliseconds: nil,
                    maximumP95Milliseconds: 20,
                    reason: nil
                )
            ])
        }
    }

    @Test func runSchemaV2RoundTripsDecodeIntentProvenance() throws {
        let decode = CalibrationDecodeRecord(
            sceneID: "P1524180",
            route: "preview-parity-interactive-preview-3072",
            backend: "Core Image RAW 8",
            intent: "interactive-preview",
            requestedMaximumDimension: 3_072,
            nativeWidth: 6_000,
            nativeHeight: 4_000,
            appliedScaleFactor: Float(3_072) / Float(6_000),
            width: 3_072,
            height: 2_048,
            decoderGraphSetupMilliseconds: 12.5,
            cameraMake: "Panasonic",
            cameraModel: "DC-S5",
            calibrationID: "panasonic-dc-s5-lightroom-9.3-edr1-v2"
        )
        let run = CalibrationRunManifest(
            status: "running",
            runID: "test-run",
            startedAtUTC: "2026-07-24T00:00:00Z",
            manifest: ManifestRunReference(
                path: "calibration/manifest-v3.json",
                sha256: String(repeating: "a", count: 64),
                suiteID: "preview-parity-test"
            ),
            runtime: RuntimeProvenance.capture(executableURL: nil),
            processing: .current,
            sourceFingerprintSHA256: String(repeating: "b", count: 64),
            sourceFiles: [],
            verifiedInputs: [],
            decodes: [decode]
        )

        #expect(run.schemaVersion == 2)
        let data = try JSONEncoder().encode(run)
        let roundTrip = try JSONDecoder().decode(CalibrationRunManifest.self, from: data)
        #expect(roundTrip == run)
        #expect(roundTrip.decodes == [decode])
    }

    private func mutatedManifest(
        relativePath: String = CalibrationManifestLoader.defaultRelativePath,
        _ mutation: (inout [String: Any]) -> Void
    ) throws -> CalibrationManifest {
        let url = projectRoot.appendingPathComponent(relativePath)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        mutation(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(CalibrationManifest.self, from: data)
    }
}
