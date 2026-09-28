import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import PhotoCore

/// `WorkingCopyRenderer` (the engine's `renderWorkingCopy`): the working copy
/// is linear ProPhoto in a metadata-free 16-bit PNG with the documented
/// encoding, bounded and never enlarged, oriented; `baseVersion` follows the
/// ICC profile; the preview is an sRGB JPEG within 1 MiB; the original is
/// never overwritten. Synthetic images always; `P1524180.RW2` (private,
/// ignored by git) only when it is present.
@Suite(.serialized)
struct WorkingCopyRendererTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - Size and orientation

    @Test func theLongEdgeIsBoundedAndSmallerSourcesAreNotEnlarged() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = WorkingCopyRenderer()

        let large = directory.appendingPathComponent("large.png")
        try Self.write(Self.gradient(width: 1_200, height: 800), to: large, type: .png)
        let reduced = try renderer.render(WorkingCopyRequest(
            sourceURL: large,
            workingCopyURL: directory.appendingPathComponent("out/large.png"),
            maxDimension: 512
        ))
        #expect(reduced.width == 512)
        #expect(reduced.height == 342)
        #expect(reduced.sourceWidth == 1_200)
        #expect(reduced.sourceHeight == 800)
        let reducedPNG = try Self.readPNG16(directory.appendingPathComponent("out/large.png"))
        #expect(reducedPNG.width == 512)
        #expect(reducedPNG.height == 342)

        let small = directory.appendingPathComponent("small.png")
        try Self.write(Self.gradient(width: 300, height: 200), to: small, type: .png)
        let unreduced = try renderer.render(WorkingCopyRequest(
            sourceURL: small,
            workingCopyURL: directory.appendingPathComponent("out/small.png")
        ))
        #expect(unreduced.width == 300)
        #expect(unreduced.height == 200)
        #expect(unreduced.sourceWidth == 300)
        #expect(unreduced.sourceHeight == 200)
    }

    /// EXIF orientation 6 (rotate 90° clockwise to display): the stored
    /// top-left red square ends up at the top right, as a viewer shows it.
    @Test func orientationIsApplied() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("rotated.jpg")
        let stored = Self.image(width: 120, height: 80) { x, y in
            x < 20 && y < 20 ? (255, 0, 0) : (128, 128, 128)
        }
        try Self.write(stored, to: source, type: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationLossyCompressionQuality: 1.0
        ])
        let workingCopy = directory.appendingPathComponent("rotated.png")
        let result = try WorkingCopyRenderer().render(WorkingCopyRequest(sourceURL: source, workingCopyURL: workingCopy))
        #expect(result.sourceWidth == 80)
        #expect(result.sourceHeight == 120)
        #expect(result.width == 80)
        #expect(result.height == 120)
        guard case let .raster(meta) = result.meta else {
            Issue.record("not a raster meta: \(result.meta)")
            return
        }
        #expect(meta.orientationApplied)

        let png = try Self.readPNG16(workingCopy)
        let topRight = png.linear(x: 70, y: 10)
        #expect(topRight.x > 0.3 && topRight.x > 3 * topRight.y, "red at the top right: \(topRight)")
        for (x, y) in [(10, 10), (10, 110), (70, 110)] {
            let gray = png.linear(x: x, y: y)
            #expect(abs(gray.x - gray.y) < 0.02 && abs(gray.y - gray.z) < 0.02, "gray at (\(x), \(y)): \(gray)")
        }
    }

    @Test func reductionStaysOnWholePixelsWithinTheBound() {
        for (width, height, bound) in [
            (6_000.0, 4_000.0, 2_560), (4_032.0, 3_024.0, 2_560), (8_256.0, 5_504.0, 2_560), (1_200.0, 800.0, 512),
            (333.0, 222.0, 100), (1_000.0, 3.0, 7), (3_024.0, 4_032.0, 1_024), (1_023.6, 682.4, 1_024)
        ] {
            let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let extent = WorkingCopyRenderer.reduced(image, maxDimension: bound).extent
            let longest = min(Double(bound), max(width, height).rounded(.up))
            #expect(extent.origin == .zero, "\(width)x\(height) -> \(bound)")
            #expect(Double(max(extent.width, extent.height)) == longest, "\(width)x\(height) -> \(bound): \(extent)")
            #expect(extent.width == extent.width.rounded() && extent.height == extent.height.rounded())
            #expect(min(extent.width, extent.height) >= 1)
        }
    }

    // MARK: - The PNG

    @Test func theWorkingCopyIsA16BitRGBPNGWithoutMetadata() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tagged.jpg")
        try Self.write(Self.gradient(width: 160, height: 100), to: source, type: .jpeg, properties: Self.privateMetadata)
        let workingCopy = directory.appendingPathComponent("tagged.png")
        let preview = directory.appendingPathComponent("tagged-preview.jpg")
        let result = try WorkingCopyRenderer().render(WorkingCopyRequest(
            sourceURL: source, workingCopyURL: workingCopy, previewURL: preview, previewMaxDimension: 80
        ))

        let chunks = try Self.pngChunks(workingCopy)
        #expect(chunks.first?.type == "IHDR")
        #expect(chunks.last?.type == "IEND")
        #expect(Set(chunks.map(\.type)) == ["IHDR", "IDAT", "IEND"], "\(chunks.map(\.type))")
        let header = try #require(chunks.first?.data)
        #expect(Self.bigEndian32(header, at: 0) == 160)
        #expect(Self.bigEndian32(header, at: 4) == 100)
        #expect(header[8] == 16, "bit depth")
        #expect(header[9] == 2, "color type RGB, no alpha")
        #expect(header[12] == 0, "not interlaced")
        #expect(result.bytes == (try Data(contentsOf: workingCopy)).count)

        let properties = try Self.properties(of: workingCopy)
        #expect(properties[kCGImagePropertyProfileName] == nil)
        #expect(properties[kCGImagePropertyExifDictionary] == nil)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
        #expect((properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 16)

        // The preview carries none of the original's camera, time or place either.
        let previewProperties = try Self.properties(of: preview)
        #expect(previewProperties[kCGImagePropertyGPSDictionary] == nil)
        let tiff = previewProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
        let exif = previewProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(exif?[kCGImagePropertyExifBodySerialNumber] == nil)
    }

    /// Known sRGB values become linear ProPhoto (`DNGColorSpace`), and the
    /// PNG decodes as documented: `v = 2 * (code / 65535)^1.8`.
    @Test func valuesAreLinearProPhotoInTheDocumentedEncoding() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = WorkingCopyRenderer()
        let block = 32
        let colors16: [(UInt16, UInt16, UInt16)] = [
            (32_768, 32_768, 32_768), (65_535, 0, 0), (0, 65_535, 0), (0, 0, 65_535),
            (65_535, 65_535, 65_535), (6_554, 6_554, 6_554), (65_535, 32_768, 0), (0, 0, 0)
        ]

        // Lossless 16-bit PNG.
        let png = directory.appendingPathComponent("blocks16.png")
        try Self.write(Self.image16(width: block * colors16.count, height: block) { x, _ in colors16[x / block] }, to: png, type: .png)
        let fromPNG = directory.appendingPathComponent("blocks16-work.png")
        _ = try renderer.render(WorkingCopyRequest(sourceURL: png, workingCopyURL: fromPNG))
        let decodedPNG = try Self.readPNG16(fromPNG)
        for (index, color) in colors16.enumerated() {
            let encoded = SIMD3(Double(color.0), Double(color.1), Double(color.2)) / 65_535
            Self.expectClose(decodedPNG.linear(x: index * block + block / 2, y: block / 2), Self.expectedProPhoto(encoded), "\(color)")
        }

        // 8-bit JPEG at quality 1 (block centers, away from JPEG's block edges).
        let colors8 = colors16.map { (UInt8($0.0 >> 8), UInt8($0.1 >> 8), UInt8($0.2 >> 8)) }
        let jpeg = directory.appendingPathComponent("blocks8.jpg")
        try Self.write(
            Self.image(width: block * colors8.count, height: block) { x, _ in colors8[x / block] },
            to: jpeg, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 1.0]
        )
        let fromJPEG = directory.appendingPathComponent("blocks8-work.png")
        _ = try renderer.render(WorkingCopyRequest(sourceURL: jpeg, workingCopyURL: fromJPEG))
        let decodedJPEG = try Self.readPNG16(fromJPEG)
        for (index, color) in colors8.enumerated() {
            let encoded = SIMD3(Double(color.0), Double(color.1), Double(color.2)) / 255
            Self.expectClose(decodedJPEG.linear(x: index * block + block / 2, y: block / 2), Self.expectedProPhoto(encoded), "\(color)")
        }
    }

    @Test func theEncodingRoundTripsEveryCode() {
        #expect(WorkingCopyRenderer.encodedSample(0) == 0)
        #expect(WorkingCopyRenderer.encodedSample(-0.25) == 0)
        #expect(WorkingCopyRenderer.encodedSample(.nan) == 0)
        #expect(WorkingCopyRenderer.encodedSample(2) == 65_535)
        #expect(WorkingCopyRenderer.encodedSample(7.5) == 65_535)
        #expect(WorkingCopyRenderer.encodedSample(.infinity) == 65_535)
        #expect(WorkingCopyRenderer.encodedSample(1) == UInt16((65_535 * pow(0.5, 1 / 1.8)).rounded()))
        #expect(WorkingCopyRenderer.decodedSample(65_535) == 2)
        #expect(WorkingCopyRenderer.decodedSample(0) == 0)
        var mismatches = 0
        for code in 0...UInt16.max where
            WorkingCopyRenderer.encodedSample(Float(WorkingCopyRenderer.decodedSample(code))) != code {
            mismatches += 1
        }
        #expect(mismatches == 0)
    }

    // MARK: - ICC and baseVersion

    @Test func baseVersionCarriesTheSHA256OfTheICCProfile() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = WorkingCopyRenderer()
        for (name, colorSpaceName, description) in [
            ("p3.png", CGColorSpace.displayP3, "Display P3"),
            ("srgb.jpg", CGColorSpace.sRGB, "sRGB IEC61966-2.1")
        ] {
            let source = directory.appendingPathComponent(name)
            let colorSpace = try #require(CGColorSpace(name: colorSpaceName))
            try Self.write(
                Self.image(width: 64, height: 48, colorSpace: colorSpace) { _, _ in (220, 40, 30) },
                to: source, type: name.hasSuffix(".png") ? .png : .jpeg
            )
            let loaded = try #require(CIImage(contentsOf: source, options: [.applyOrientationProperty: true]))
            let iccData = try #require(loaded.colorSpace?.copyICCData() as Data?)
            let sha = SHA256.hash(data: iccData).map { String(format: "%02x", $0) }.joined()
            let result = try renderer.render(WorkingCopyRequest(
                sourceURL: source, workingCopyURL: directory.appendingPathComponent("\(name).png")
            ))
            #expect(result.kind == .raster)
            #expect(result.baseVersion == "raster.ci1.p1.e1.icc-\(sha)", "\(name)")
            #expect(sha.count == 64)
            guard case let .raster(meta) = result.meta else {
                Issue.record("not a raster meta: \(result.meta)")
                continue
            }
            #expect(meta.icc == WorkingCopyMeta.ICC(sha256: sha, description: description), "\(name)")
            #expect(meta.cms == "ci1")
            #expect(meta.colorSpace == "linear-prophoto-d50")
            #expect(meta.encoding == .png16)
            #expect(meta.sourceExtension == (name as NSString).pathExtension)
        }
    }

    /// A color space without ICC data (Core Image opens a CMYK JPEG as device
    /// RGB) is read as sRGB: `icc-srgb`, both ICC fields null.
    @Test func anImageWithoutICCDataIsReadAsSRGB() throws {
        #expect(try WorkingCopyRenderer.iccIdentity(of: nil) == .assumedSRGB)
        #expect(try WorkingCopyRenderer.iccIdentity(of: CGColorSpaceCreateDeviceRGB()) == .assumedSRGB)
        #expect(throws: WorkingCopyError.self) {
            try WorkingCopyRenderer.iccIdentity(iccData: Data("not an ICC profile".utf8), fallbackDescription: nil)
        }
        do {
            _ = try WorkingCopyRenderer.iccIdentity(iccData: Data(repeating: 7, count: 256), fallbackDescription: nil)
            Issue.record("garbage ICC bytes were accepted")
        } catch let error as WorkingCopyError {
            #expect(error.code == .unsupportedProfile)
        }

        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cmyk.jpg")
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.genericCMYK))
        let context = try #require(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(CGColor(genericCMYKCyan: 0.2, magenta: 0.4, yellow: 0.1, black: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        try Self.write(try #require(context.makeImage()), to: source, type: .jpeg)
        let loaded = try #require(CIImage(contentsOf: source, options: [.applyOrientationProperty: true]))
        guard loaded.colorSpace?.copyICCData() == nil else {
            print("SKIP: この macOS は CMYK の JPEG を ICC 付きの色空間で開くため、ICC の無い画像の確認をスキップします。")
            return
        }
        let result = try WorkingCopyRenderer().render(WorkingCopyRequest(
            sourceURL: source, workingCopyURL: directory.appendingPathComponent("cmyk.png")
        ))
        #expect(result.baseVersion == "raster.ci1.p1.e1.icc-srgb")
        #expect(result.meta == .raster(.init(
            cms: "ci1", icc: .assumedSRGB, orientationApplied: true, encoding: .png16,
            colorSpace: "linear-prophoto-d50", sourceExtension: "jpg"
        )))
    }

    // MARK: - Preview

    @Test func thePreviewHasTheRequestedLongEdgeAndFitsIn1MiB() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = WorkingCopyRenderer()
        let source = directory.appendingPathComponent("large.jpg")
        try Self.write(Self.gradient(width: 1_200, height: 800), to: source, type: .jpeg)
        let preview = directory.appendingPathComponent("previews/large.jpg")
        let result = try renderer.render(WorkingCopyRequest(
            sourceURL: source,
            workingCopyURL: directory.appendingPathComponent("large.png"),
            previewURL: preview,
            previewMaxDimension: 256
        ))
        let written = try #require(result.preview)
        #expect(written.width == 256)
        #expect(written.height == 171)
        let jpeg = try Data(contentsOf: preview)
        #expect(written.bytes == jpeg.count)
        #expect(jpeg.count <= WorkingCopyRenderer.previewByteLimit)
        #expect(jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
        let properties = try Self.properties(of: preview)
        #expect((properties[kCGImagePropertyProfileName] as? String)?.contains("sRGB") == true)
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)

        // Never enlarged; and no preview unless asked for.
        let small = directory.appendingPathComponent("small.png")
        try Self.write(Self.gradient(width: 300, height: 200), to: small, type: .png)
        let smallPreview = directory.appendingPathComponent("small-preview.jpg")
        let unreduced = try renderer.render(WorkingCopyRequest(
            sourceURL: small, workingCopyURL: directory.appendingPathComponent("small-work.png"), previewURL: smallPreview
        ))
        #expect(unreduced.preview?.width == 300)
        #expect(unreduced.preview?.height == 200)
        let none = try renderer.render(WorkingCopyRequest(
            sourceURL: small, workingCopyURL: directory.appendingPathComponent("small-work-2.png")
        ))
        #expect(none.preview == nil)
        #expect(none.timings.previewMilliseconds == 0)
    }

    @Test func thePreviewQualityStepsDownUntilItFits() throws {
        var tried: [Double] = []
        let fitted = try WorkingCopyRenderer.fittingPreviewJPEG(limit: 100) { quality in
            tried.append(quality)
            return Data(count: quality > 0.6 ? 150 : 90)
        }
        #expect(fitted.count == 90)
        #expect(tried == [0.85, 0.75, 0.65, 0.55])

        do {
            _ = try WorkingCopyRenderer.fittingPreviewJPEG(limit: 100) { _ in Data(count: 101) }
            Issue.record("a preview over the limit was accepted")
        } catch let error as WorkingCopyError {
            #expect(error.code == .exportFailed)
            #expect(error.message.contains("プレビューが 1MiB を超える"))
        }
    }

    /// Noise cannot fit 1 MiB at 2560 px even at quality 0.45: the request
    /// fails and leaves neither file (nor a temporary one) behind.
    @Test func aPreviewThatCannotFitFailsAndWritesNothing() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("noise.png")
        try Self.write(Self.noise(width: 2_560, height: 2_560), to: source, type: .png)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        let workingCopy = output.appendingPathComponent("noise.png")
        let preview = output.appendingPathComponent("noise.jpg")
        do {
            _ = try WorkingCopyRenderer().render(WorkingCopyRequest(
                sourceURL: source, workingCopyURL: workingCopy, previewURL: preview,
                maxDimension: 64, previewMaxDimension: 2_560
            ))
            Issue.record("a preview over 1 MiB was accepted")
        } catch let error as WorkingCopyError {
            #expect(error.code == .exportFailed)
            #expect(error.message.contains("プレビューが 1MiB を超える"))
        }
        #expect(!FileManager.default.fileExists(atPath: workingCopy.path))
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [] == [])
    }

    // MARK: - Destinations and errors

    @Test func theOriginalIsNeverADestination() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.png")
        try Self.write(Self.gradient(width: 64, height: 48), to: source, type: .png)
        let before = try Data(contentsOf: source)
        let renderer = WorkingCopyRenderer()
        let workingCopy = directory.appendingPathComponent("work.png")
        let requests = [
            WorkingCopyRequest(sourceURL: source, workingCopyURL: source),
            // Default APFS compares names case-insensitively.
            WorkingCopyRequest(sourceURL: source, workingCopyURL: directory.appendingPathComponent("ORIGINAL.PNG")),
            WorkingCopyRequest(sourceURL: source, workingCopyURL: workingCopy, previewURL: source),
            WorkingCopyRequest(sourceURL: source, workingCopyURL: workingCopy, previewURL: workingCopy),
            WorkingCopyRequest(sourceURL: source, workingCopyURL: directory),
            WorkingCopyRequest(
                sourceURL: source, workingCopyURL: workingCopy,
                protectedSourceURLs: [workingCopy]
            )
        ]
        for request in requests {
            do {
                _ = try renderer.render(request)
                Issue.record("wrote \(request.workingCopyURL.lastPathComponent) / \(request.previewURL?.lastPathComponent ?? "-")")
            } catch let error as WorkingCopyError {
                #expect(error.code == .exportFailed, "\(error.message)")
            }
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(!FileManager.default.fileExists(atPath: workingCopy.path))
    }

    @Test func unreadableSourcesAndInvalidSizesAreRejected() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = WorkingCopyRenderer()
        let workingCopy = directory.appendingPathComponent("work.png")

        let garbageRAW = directory.appendingPathComponent("garbage.RW2")
        try Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }).write(to: garbageRAW)
        let jpegAsRAW = directory.appendingPathComponent("photo-as.RW2")
        try Self.write(Self.gradient(width: 32, height: 32), to: jpegAsRAW, type: .jpeg)
        let garbageJPEG = directory.appendingPathComponent("garbage.jpg")
        try Data(repeating: 0x42, count: 4_096).write(to: garbageJPEG)
        for source in [
            directory.appendingPathComponent("missing.RW2"), garbageRAW, jpegAsRAW,
            directory.appendingPathComponent("missing.jpg"), garbageJPEG
        ] {
            do {
                _ = try renderer.render(WorkingCopyRequest(sourceURL: source, workingCopyURL: workingCopy))
                Issue.record("rendered \(source.lastPathComponent)")
            } catch let error as WorkingCopyError {
                #expect(error.code == .decodeFailed, "\(source.lastPathComponent): \(error.message)")
            }
        }

        let source = directory.appendingPathComponent("fine.png")
        try Self.write(Self.gradient(width: 16, height: 16), to: source, type: .png)
        for (maxDimension, previewMaxDimension) in [(0, 1_024), (2_561, 1_024), (2_560, 0), (2_560, 2_561)] {
            do {
                _ = try renderer.render(WorkingCopyRequest(
                    sourceURL: source, workingCopyURL: workingCopy,
                    maxDimension: maxDimension, previewMaxDimension: previewMaxDimension
                ))
                Issue.record("accepted \(maxDimension) / \(previewMaxDimension)")
            } catch let error as WorkingCopyError {
                #expect(error.code == .invalidRequest)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: workingCopy.path))
    }

    /// The legal boundary of this route: no Adobe camera profile, no Adobe
    /// Color, no LibRaw, no per-camera boost.
    @Test func theWorkingCopyRouteNeverReachesTheAdobeProfileRoute() throws {
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/PhotoCore/WorkingCopyRenderer.swift"),
            encoding: .utf8
        )
        for forbidden in [
            "PhotoDecoder", "LibRawDecoder", "CLibRaw", "AdobeProfileLocator", "DCPProfile", "AdobeLookXMP",
            "makeHandle", "adobeBase", ".matching(", "lumixDCS5", "panasonicDCS5"
        ] {
            #expect(!source.contains(forbidden), "\(forbidden)")
        }
    }

    // MARK: - RAW decoder version

    /// RAW 8, or for a DNG (which Core Image offers as `8.dng`) that
    /// variant; anything else is `unsupportedCamera`. (No DNG sample: the
    /// DNG route itself is not exercised on a real file.)
    @Test func theRAWDecoderIsRAW8OrItsDNGVariant() {
        #expect(WorkingCopyRenderer.selectRAWDecoderVersion(supported: [.version7, .version8]) == .version8)
        #expect(WorkingCopyRenderer.selectRAWDecoderVersion(supported: [.version7DNG, .version8DNG]) == .version8DNG)
        #expect(WorkingCopyRenderer.selectRAWDecoderVersion(supported: [.version8DNG, .version8]) == .version8)
        #expect(WorkingCopyRenderer.selectRAWDecoderVersion(supported: [.version8, .version8DNG]) == .version8)
        #expect(WorkingCopyRenderer.selectRAWDecoderVersion(supported: [.version7]) == nil)
        #expect(WorkingCopyRenderer.selectRAWDecoderVersion(supported: [.none]) == nil)
        #expect(WorkingCopyRenderer.selectRAWDecoderVersion(supported: []) == nil)
    }

    /// `baseVersion`'s decoder part never adds a dot: `8` -> `d8`, `8.dng` -> `d8dng`.
    @Test func theDecoderTokenDropsDotsAndIsLowercase() {
        #expect(CIRAWDecoderVersion.version8DNG.rawValue == "8.dng")
        #expect(WorkingCopyRenderer.decoderToken(for: .version8) == "d8")
        #expect(WorkingCopyRenderer.decoderToken(for: .version8DNG) == "d8dng")
        #expect(WorkingCopyRenderer.decoderToken(for: CIRAWDecoderVersion(rawValue: "9.DNG")) == "d9dng")
    }

    // MARK: - RAW (private fixture)

    @Test func aRAWBecomesALinearWorkingCopyThroughMacOSOnly() throws {
        let url = projectRoot.appendingPathComponent("P1524180.RW2")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP: P1524180.RW2 がこの環境に無いため、この環境ではスキップします。")
            return
        }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingCopy = directory.appendingPathComponent("P1524180.png")
        let preview = directory.appendingPathComponent("P1524180.jpg")
        let result = try WorkingCopyRenderer().render(WorkingCopyRequest(
            sourceURL: url, workingCopyURL: workingCopy, previewURL: preview
        ))
        print(
            "WORKING-COPY P1524180 \(result.width)x\(result.height) bytes=\(result.bytes)"
                + " preview=\(result.preview.map { "\($0.width)x\($0.height) \($0.bytes)" } ?? "-")"
                + " decode=\(result.timings.decodeMilliseconds)ms workingCopy=\(result.timings.workingCopyMilliseconds)ms"
                + " preview=\(result.timings.previewMilliseconds)ms meta=\(result.meta)"
        )
        #expect(result.kind == .raw)
        #expect(result.baseVersion == "raw-apple.d8.p1.e1.cal-none")
        #expect(result.baseVersion.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil)
        #expect(result.sourceWidth == 6_000)
        #expect(result.sourceHeight == 4_000)
        #expect(result.width == 2_560)
        #expect(result.height == 1_707)
        guard case let .raw(meta) = result.meta else {
            Issue.record("not a RAW meta: \(result.meta)")
            return
        }
        #expect(meta.engine == "apple-raw")
        #expect(meta.decoderVersion == "8")
        #expect(meta.baselineEV == 0)
        #expect(meta.calibration == "none")
        #expect(meta.orientationApplied)
        #expect(meta.lensCorrection == nil || meta.lensCorrection == "apple")
        #expect(meta.colorSpace == "linear-prophoto-d50")
        #expect(meta.encoding == .png16)
        #expect(meta.sourceExtension == "rw2")
        #expect((0.2...0.6).contains(meta.asShotWhite.x))
        #expect((0.2...0.6).contains(meta.asShotWhite.y))
        #expect((2_000...50_000).contains(meta.asShotWhite.temperature))
        #expect((-150...150).contains(meta.asShotWhite.tint))
        #expect(meta.noiseReduction.luminance.isFinite && meta.noiseReduction.color.isFinite && meta.sharpness.isFinite)

        let png = try Self.readPNG16(workingCopy)
        #expect(png.width == 2_560)
        #expect(png.height == 1_707)
        #expect(Set(try Self.pngChunks(workingCopy).map(\.type)) == ["IHDR", "IDAT", "IEND"])
        var sum = 0.0
        var maximum = 0.0
        for code in png.samples {
            let value = WorkingCopyRenderer.decodedSample(code)
            sum += value
            maximum = max(maximum, value)
        }
        let mean = sum / Double(png.samples.count)
        #expect(mean > 0.005 && mean < 1, "mean \(mean)")
        #expect(maximum <= 2)
        #expect(png.samples.contains { $0 > 0 })

        // The decode is `CoreImageDecoder`'s with the same flat configuration
        // (the filter is set up in the same order): the same pixels.
        let decoded = try CoreImageDecoder(rawConfiguration: .calibrationBaseline).decode(url: url)
        let context = MTLCreateSystemDefaultDevice().map {
            CIContext(mtlDevice: $0, options: PreviewWorkingRaster.contextOptions)
        } ?? CIContext(options: PreviewWorkingRaster.contextOptions)
        let proPhoto = AdobeBaseRenderer.applyMatrix(DNGColorSpace.srgbLinearToProPhoto, to: decoded.image)
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1.0e6, y: 1.0e6, z: 1.0e6, w: 1)
            ])
        let reference = try #require(PreviewWorkingRaster(context: context).renderPixels(
            WorkingCopyRenderer.reduced(proPhoto, maxDimension: 2_560)
        ))
        #expect(reference.width == png.width && reference.height == png.height)
        var largestDifference = 0
        reference.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            let stride = reference.rowBytes / MemoryLayout<Float>.size
            for y in 0..<reference.height {
                for x in 0..<reference.width {
                    for channel in 0..<3 {
                        let expected = Int(WorkingCopyRenderer.encodedSample(floats[y * stride + x * 4 + channel]))
                        let actual = Int(png.samples[(y * png.width + x) * 3 + channel])
                        largestDifference = max(largestDifference, abs(expected - actual))
                    }
                }
            }
        }
        #expect(largestDifference <= 1, "largest code difference from CoreImageDecoder: \(largestDifference)")

        let written = try #require(result.preview)
        #expect(written.width == 1_024)
        #expect(written.height == 683)
        #expect(written.bytes <= WorkingCopyRenderer.previewByteLimit)
        #expect(written.bytes == (try Data(contentsOf: preview)).count)
    }

    // MARK: - Helpers

    private struct PNG16 {
        let width: Int
        let height: Int
        /// RGB codes, rows top to bottom.
        let samples: [UInt16]

        /// Linear ProPhoto at (x, y), decoded as documented.
        func linear(x: Int, y: Int) -> SIMD3<Double> {
            let index = (y * width + x) * 3
            return SIMD3(
                WorkingCopyRenderer.decodedSample(samples[index]),
                WorkingCopyRenderer.decodedSample(samples[index + 1]),
                WorkingCopyRenderer.decodedSample(samples[index + 2])
            )
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Camera, time and place the working copy and its preview must not carry.
    private static var privateMetadata: [CFString: Any] {
        [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "NIHO Test Camera Maker",
                kCGImagePropertyTIFFModel: "NIHO Secret Model"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:28 10:00:00",
                kCGImagePropertyExifBodySerialNumber: "SERIAL-123"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.3,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 139.5,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ]
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkingCopyRendererTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Linear ProPhoto for sRGB-encoded `encoded`, clipped as the working copy is.
    private static func expectedProPhoto(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
        let linear = SIMD3(
            DNGColorSpace.srgbDecode(encoded.x),
            DNGColorSpace.srgbDecode(encoded.y),
            DNGColorSpace.srgbDecode(encoded.z)
        )
        let proPhoto = DNGColorSpace.srgbLinearToProPhoto * linear
        return SIMD3(
            min(max(proPhoto.x, 0), 2),
            min(max(proPhoto.y, 0), 2),
            min(max(proPhoto.z, 0), 2)
        )
    }

    private static func expectClose(
        _ actual: SIMD3<Double>, _ expected: SIMD3<Double>, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let difference = actual - expected
        #expect(
            max(abs(difference.x), abs(difference.y), abs(difference.z)) <= 1e-2,
            "\(label): \(actual) vs \(expected)",
            sourceLocation: sourceLocation
        )
    }

    /// An 8-bit RGB image drawn by `pixel(x, y)` (row 0 at the top).
    private static func image(
        width: Int, height: Int,
        colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let index = (y * width + x) * 4
                bytes[index] = r
                bytes[index + 1] = g
                bytes[index + 2] = b
            }
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// A 16-bit sRGB image (big-endian samples) drawn by `pixel(x, y)`.
    private static func image16(width: Int, height: Int, pixel: (Int, Int) -> (UInt16, UInt16, UInt16)) -> CGImage {
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let index = (y * width + x) * 3
                samples[index] = r.bigEndian
                samples[index + 1] = g.bigEndian
                samples[index + 2] = b.bigEndian
            }
        }
        let data = samples.withUnsafeBytes { Data($0) }
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// Uniform random 8-bit RGB (incompressible for JPEG).
    private static func noise(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private static func gradient(width: Int, height: Int) -> CGImage {
        image(width: width, height: height) { x, y in
            (UInt8(x * 255 / max(width - 1, 1)), UInt8(y * 255 / max(height - 1, 1)),
             UInt8((x + y) * 127 / max(width + height - 2, 1)))
        }
    }

    private static func write(
        _ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure(description: "cannot create \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "cannot write \(url.path)")
        }
    }

    private static func properties(of url: URL) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw Failure(description: "cannot read \(url.path)")
        }
        return properties
    }

    /// The PNG's own 16-bit samples, without any color conversion.
    private static func readPNG16(_ url: URL) throws -> PNG16 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerComponent == 16, image.bitsPerPixel == 48,
              let data = image.dataProvider?.data as Data?
        else {
            throw Failure(description: "not a 16-bit RGB PNG: \(url.path)")
        }
        let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let littleEndian = byteOrder == CGBitmapInfo.byteOrder16Little.rawValue
        let width = image.width
        let height = image.height
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for y in 0..<height {
                for index in 0..<(width * 3) {
                    let offset = y * image.bytesPerRow + index * 2
                    let first = UInt16(bytes[offset])
                    let second = UInt16(bytes[offset + 1])
                    samples[y * width * 3 + index] = littleEndian ? first | second << 8 : first << 8 | second
                }
            }
        }
        return PNG16(width: width, height: height, samples: samples)
    }

    private static func pngChunks(_ url: URL) throws -> [(type: String, data: Data)] {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw Failure(description: "not a PNG: \(url.path)")
        }
        var chunks: [(type: String, data: Data)] = []
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard offset + 12 + length <= bytes.count else {
                throw Failure(description: "truncated PNG chunk: \(url.path)")
            }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            chunks.append((type, Data(bytes[(offset + 8)..<(offset + 8 + length)])))
            offset += 12 + length
        }
        return chunks
    }

    private static func bigEndian32(_ data: Data, at offset: Int) -> Int {
        let bytes = [UInt8](data)
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }
}
