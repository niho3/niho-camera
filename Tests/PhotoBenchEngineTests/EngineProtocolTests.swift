import Darwin
import Foundation
import PhotoCore
import Testing
@testable import PhotoBenchEngine

/// The wire format alone: request lines, response headers and bodies, the
/// response writer and the line reader.
struct EngineProtocolTests {
    // MARK: - Requests

    @Test func parsesARequestWithAndWithoutParams() throws {
        let withParams = try RequestParser.parse(Data(#"{"id": 7, "method": "open", "params": {"path": "/a.jpg"}}"#.utf8)).get()
        #expect(withParams.id == 7)
        #expect(withParams.method == "open")
        #expect(try withParams.decodeParams(OpenParams.self).path == "/a.jpg")

        let withoutParams = try RequestParser.parse(Data(#"{"id": 1.0, "method": "hello"}"#.utf8)).get()
        #expect(withoutParams.id == 1)
        #expect(String(decoding: withoutParams.params, as: UTF8.self) == "{}")
        let nullParams = try RequestParser.parse(Data(#"{"id": 2, "method": "hello", "params": null}"#.utf8)).get()
        #expect(String(decoding: nullParams.params, as: UTF8.self) == "{}")
    }

    @Test func rejectsLinesWithoutAReadableID() {
        for line in [
            "not json",
            "[1, 2]",
            "42",
            #"{"method": "hello"}"#,
            #"{"id": "1", "method": "hello"}"#,
            #"{"id": 0, "method": "hello"}"#,
            #"{"id": -3, "method": "hello"}"#,
            #"{"id": 1.5, "method": "hello"}"#,
            #"{"id": true, "method": "hello"}"#,
            #"{"id": 1e300, "method": "hello"}"#
        ] {
            guard case let .failure(failure) = RequestParser.parse(Data(line.utf8)) else {
                Issue.record("accepted \(line)")
                continue
            }
            #expect(failure.id == 0, "\(line)")
            #expect(failure.error.code == .invalidRequest, "\(line)")
        }
    }

    @Test func rejectsAMissingMethodOrMalformedParamsWithTheRequestID() {
        for (line, id) in [
            (#"{"id": 3}"#, 3),
            (#"{"id": 4, "method": ""}"#, 4),
            (#"{"id": 5, "method": 5}"#, 5),
            (#"{"id": 6, "method": "open", "params": [1]}"#, 6),
            (#"{"id": 7, "method": "open", "params": "x"}"#, 7)
        ] {
            guard case let .failure(failure) = RequestParser.parse(Data(line.utf8)) else {
                Issue.record("accepted \(line)")
                continue
            }
            #expect(failure.id == id)
            #expect(failure.error.code == .invalidRequest)
        }
    }

    @Test func paramsErrorsNameTheField() throws {
        let missing = try RequestParser.parse(Data(#"{"id": 1, "method": "open", "params": {}}"#.utf8)).get()
        #expect(throws: EngineError.invalidRequest("params.path がありません")) {
            try missing.decodeParams(OpenParams.self)
        }
        let wrongType = try RequestParser.parse(Data(
            #"{"id": 2, "method": "render", "params": {"photoId": "p", "settings": {"exposure": "high"}}}"#.utf8
        )).get()
        #expect(throws: EngineError.invalidRequest("params.settings.exposure の型が違います")) {
            try wrongType.decodeParams(RenderParams.self)
        }
    }

    @Test func settingsRoundTripThroughTheRequestParams() throws {
        var settings = EditSettings.neutral
        settings.exposure = 0.42
        settings.whiteBalance = WhiteBalanceSettings(mode: .custom, temperature: 5_200, tint: 3)
        settings.hsl[.orange] = HSLAdjustment(hue: 1, saturation: -13, luminance: 2)
        settings.toneCurves = [ToneCurve(channel: .rgb, points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)])]
        let request: [String: Any] = [
            "id": 9, "method": "render", "params": ["photoId": "p", "settings": settingsJSON(settings), "drag": true]
        ]
        let line = try JSONSerialization.data(withJSONObject: request)
        let params = try RequestParser.parse(line).get().decodeParams(RenderParams.self)
        #expect(params.settings == settings)
        #expect(params.drag == true)
        #expect(params.original == nil)
        #expect(params.maxDimension == nil)
    }

    // MARK: - Responses

    @Test func profileStatusWritesAMissingLookSourceAsNull() throws {
        let response = try ParsedResponse(.success(
            id: 3, result: ProfileStatusResult(.init(lookSource: nil, dcpSources: [.lightroom]))
        ))
        #expect(response.result?["available"] as? Bool == false)
        #expect(response.result?["lookSource"] is NSNull)
        #expect(response.result?["dcpSources"] as? [String] == ["lightroom"])
    }

    @Test func successAndFailureHeadersFollowTheProtocol() throws {
        let hello = try ParsedResponse(.success(id: 1, result: HelloResult(engineVersion: "0.2.0+dev", protocolVersion: 1)))
        #expect(hello.id == 1)
        #expect(hello.ok)
        #expect(hello.result?["protocolVersion"] as? Int == 1)
        #expect(hello.binaryLength == nil)
        #expect(hello.header["mime"] == nil)

        let failure = try ParsedResponse(.failure(id: 2, error: EngineError(.exportFailed, "書けません: /tmp/a.jpg")))
        #expect(failure.id == 2)
        #expect(!failure.ok)
        #expect(failure.errorCode == "exportFailed")
        #expect(failure.errorMessage == "書けません: /tmp/a.jpg")
        #expect(failure.header["result"] == nil)
    }

    @Test func binaryResponsesDeclareTheirLengthAndMime() throws {
        let body = Data([0xFF, 0xD8, 0xFF, 0x0A, 0x0A, 0x00, 0xFF, 0xD9])
        let response = EngineResponse.binary(id: 3, result: RenderResult(width: 4, height: 2), body: body, mime: "image/jpeg")
        let parsed = try ParsedResponse(response)
        #expect(parsed.binaryLength == body.count)
        #expect(parsed.mime == "image/jpeg")
        #expect(parsed.result?["width"] as? Int == 4)
        #expect(parsed.result?["height"] as? Int == 2)
        #expect(response.binary == body)
        #expect(!response.header.contains(0x0A), "the header must be a single line")
    }

    @Test func openResultsWriteExplicitNulls() throws {
        let result = OpenResult(
            photoId: "p", kind: "raster", fileName: "a.jpg", width: 3, height: 2,
            asShotWhiteBalance: nil, profile: nil, settings: .neutral
        )
        let parsed = try ParsedResponse(.success(id: 1, result: result))
        let object = try #require(parsed.result)
        #expect(object["asShotWhiteBalance"] is NSNull)
        #expect(object["profile"] is NSNull)
        #expect(try decodeSettings(object["settings"]) == .neutral)

        let raw = OpenResult(
            photoId: "p", kind: "raw", fileName: "a.RW2", width: 6_000, height: 4_000,
            asShotWhiteBalance: AsShotWhiteBalance(temperature: 5_200, tint: 3), profile: "adobe", settings: .neutral
        )
        let rawObject = try #require(try ParsedResponse(.success(id: 1, result: raw)).result)
        #expect((rawObject["asShotWhiteBalance"] as? [String: Any])?["temperature"] as? Int == 5_200)
        #expect(rawObject["profile"] as? String == "adobe")
    }

    @Test func slashesAndJapaneseAreWrittenPlainly() throws {
        let response = EngineResponse.success(id: 1, result: ExportResult(path: "/Users/写真/a.jpg", width: 1, height: 1, bytes: 1))
        let text = String(decoding: response.header, as: UTF8.self)
        #expect(text.contains(#""path":"/Users/写真/a.jpg""#))
    }

    // MARK: - renderWorkingCopy

    @Test func renderWorkingCopyParamsDecodeWithTheirOptionalFields() throws {
        let full = try RequestParser.parse(Data(#"""
        {"id": 1, "method": "renderWorkingCopy", "params": {"path": "/a.RW2", "workingCopyPath": "/w/a.png",
         "previewPath": "/w/a.jpg", "maxDimension": 2048, "previewMaxDimension": 512}}
        """#.utf8)).get().decodeParams(RenderWorkingCopyParams.self)
        #expect(full.path == "/a.RW2")
        #expect(full.workingCopyPath == "/w/a.png")
        #expect(full.previewPath == "/w/a.jpg")
        #expect(full.maxDimension == 2_048)
        #expect(full.previewMaxDimension == 512)

        let minimal = try RequestParser.parse(Data(
            #"{"id": 2, "method": "renderWorkingCopy", "params": {"path": "/a.jpg", "workingCopyPath": "/w/a.png", "previewPath": null}}"#.utf8
        )).get().decodeParams(RenderWorkingCopyParams.self)
        #expect(minimal.previewPath == nil)
        #expect(minimal.maxDimension == nil)
        #expect(minimal.previewMaxDimension == nil)

        let missing = try RequestParser.parse(Data(
            #"{"id": 3, "method": "renderWorkingCopy", "params": {"path": "/a.jpg"}}"#.utf8
        )).get()
        #expect(throws: EngineError.invalidRequest("params.workingCopyPath がありません")) {
            try missing.decodeParams(RenderWorkingCopyParams.self)
        }
    }

    @Test func renderWorkingCopyResultsWriteTheMetaUnionAndExplicitNulls() throws {
        let raw = WorkingCopyResult(
            kind: .raw, baseVersion: "raw-apple.d8.p1.e1.cal-none",
            width: 2_560, height: 1_707, sourceWidth: 6_000, sourceHeight: 4_000, bytes: 14_567_890,
            preview: nil,
            meta: .raw(.init(
                engine: "apple-raw", decoderVersion: "8", baselineEV: 0, calibration: "none",
                asShotWhite: .init(x: 0.3457, y: 0.3585, temperature: 5_200, tint: 3),
                orientationApplied: true, lensCorrection: nil,
                noiseReduction: .init(luminance: 0.77, color: 0.5), sharpness: 0.9,
                encoding: .png16, colorSpace: "linear-prophoto-d50", sourceExtension: "rw2"
            )),
            timings: .init(decodeMilliseconds: 1_200, workingCopyMilliseconds: 800, previewMilliseconds: 0)
        )
        let object = try #require(try ParsedResponse(.success(id: 1, result: RenderWorkingCopyResult(raw))).result)
        #expect(Set(object.keys) == [
            "kind", "baseVersion", "width", "height", "sourceWidth", "sourceHeight", "bytes", "preview", "meta", "timings"
        ])
        #expect(object["kind"] as? String == "raw")
        #expect(object["baseVersion"] as? String == "raw-apple.d8.p1.e1.cal-none")
        #expect(object["bytes"] as? Int == 14_567_890)
        #expect(object["preview"] is NSNull)
        let timings = try #require(object["timings"] as? [String: Int])
        #expect(timings == ["decodeMs": 1_200, "workingCopyMs": 800, "previewMs": 0])
        let meta = try #require(object["meta"] as? [String: Any])
        #expect(Set(meta.keys) == [
            "kind", "engine", "decoderVersion", "baselineEV", "calibration", "asShotWhite", "orientationApplied",
            "lensCorrection", "noiseReduction", "sharpness", "encoding", "colorSpace", "sourceExtension"
        ])
        #expect(meta["kind"] as? String == "raw")
        #expect(meta["engine"] as? String == "apple-raw")
        #expect(meta["decoderVersion"] as? String == "8")
        #expect(meta["baselineEV"] as? Double == 0)
        #expect(meta["calibration"] as? String == "none")
        #expect(meta["lensCorrection"] is NSNull)
        #expect(meta["orientationApplied"] as? Bool == true)
        #expect(meta["sharpness"] as? Double == 0.9)
        let white = try #require(meta["asShotWhite"] as? [String: Any])
        #expect(white["x"] as? Double == 0.3457)
        #expect(white["y"] as? Double == 0.3585)
        #expect(white["temperature"] as? Int == 5_200)
        #expect(white["tint"] as? Int == 3)
        let noise = try #require(meta["noiseReduction"] as? [String: Any])
        #expect(noise["luminance"] as? Double == 0.77)
        #expect(noise["color"] as? Double == 0.5)
        let encoding = try #require(meta["encoding"] as? [String: Any])
        #expect(encoding["format"] as? String == "png16")
        #expect(encoding["gamma"] as? Double == 1.8)
        #expect(encoding["ceiling"] as? Double == 2)
        #expect(meta["colorSpace"] as? String == "linear-prophoto-d50")
        #expect(meta["sourceExtension"] as? String == "rw2")

        let rasterMeta: (WorkingCopyMeta.ICC) -> WorkingCopyMeta = { icc in
            .raster(.init(
                cms: "ci1", icc: icc, orientationApplied: true, encoding: .png16,
                colorSpace: "linear-prophoto-d50", sourceExtension: "heic"
            ))
        }
        let sha = String(repeating: "ab", count: 32)
        let raster = WorkingCopyResult(
            kind: .raster, baseVersion: "raster.ci1.p1.e1.icc-\(sha)",
            width: 2_560, height: 1_920, sourceWidth: 4_032, sourceHeight: 3_024, bytes: 12_000_000,
            preview: .init(width: 1_024, height: 768, bytes: 234_567),
            meta: rasterMeta(.init(sha256: sha, description: "Display P3")),
            timings: .init(decodeMilliseconds: 300, workingCopyMilliseconds: 700, previewMilliseconds: 90)
        )
        let rasterObject = try #require(try ParsedResponse(.success(id: 2, result: RenderWorkingCopyResult(raster))).result)
        #expect((rasterObject["preview"] as? [String: Int]) == ["width": 1_024, "height": 768, "bytes": 234_567])
        let rasterMetaObject = try #require(rasterObject["meta"] as? [String: Any])
        #expect(Set(rasterMetaObject.keys) == [
            "kind", "cms", "icc", "orientationApplied", "encoding", "colorSpace", "sourceExtension"
        ])
        #expect(rasterMetaObject["kind"] as? String == "raster")
        #expect(rasterMetaObject["cms"] as? String == "ci1")
        #expect((rasterMetaObject["icc"] as? [String: String]) == ["sha256": sha, "description": "Display P3"])

        // An image without an ICC profile: both written as explicit nulls.
        let untagged = WorkingCopyResult(
            kind: .raster, baseVersion: "raster.ci1.p1.e1.icc-srgb",
            width: 96, height: 64, sourceWidth: 96, sourceHeight: 64, bytes: 1_000, preview: nil,
            meta: rasterMeta(.assumedSRGB),
            timings: .init(decodeMilliseconds: 1, workingCopyMilliseconds: 1, previewMilliseconds: 0)
        )
        let untaggedObject = try #require(try ParsedResponse(.success(id: 3, result: RenderWorkingCopyResult(untagged))).result)
        let icc = try #require((untaggedObject["meta"] as? [String: Any])?["icc"] as? [String: Any])
        #expect(icc["sha256"] is NSNull)
        #expect(icc["description"] is NSNull)
    }

    @Test func workingCopyErrorsKeepTheirProtocolCode() {
        for code in [
            WorkingCopyError.Code.invalidRequest, .decodeFailed, .unsupportedCamera, .unsupportedProfile,
            .exportFailed, .internal
        ] {
            let wrapped = EngineError.wrapping(WorkingCopyError(code, "理由"))
            #expect(wrapped.code.rawValue == code.rawValue)
            #expect(wrapped.message == "理由")
        }
    }

    // MARK: - Writer

    /// Many threads writing binary responses at once: every header is
    /// followed by exactly its own body.
    @Test func concurrentResponsesNeverInterleave() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
        let sink = FileDescriptorResponseSink(fileDescriptor: writeEnd)
        let count = 64
        let collected = Collected()
        let reader = Thread {
            var bytes = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let read = chunk.withUnsafeMutableBytes { Darwin.read(readEnd, $0.baseAddress, $0.count) }
                guard read > 0 else { break }
                bytes.append(contentsOf: chunk[0..<read])
            }
            collected.set(bytes)
        }
        reader.start()
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let body = Data(repeating: UInt8(index), count: 10_000 + index * 997)
            sink.send(.binary(id: index + 1, result: RenderResult(width: index, height: index), body: body, mime: "image/jpeg"))
        }
        close(writeEnd)
        let stream = try collected.wait()
        close(readEnd)

        var offset = 0
        var seen = Set<Int>()
        while offset < stream.count {
            let newline = try #require(stream[offset...].firstIndex(of: 0x0A))
            let header = try ParsedResponse(header: Data(stream[offset..<newline]), binary: nil)
            let length = try #require(header.binaryLength)
            let body = stream[(newline + 1)..<(newline + 1 + length)]
            #expect(body.count == 10_000 + (header.id - 1) * 997)
            #expect(body.allSatisfy { $0 == UInt8(header.id - 1) })
            seen.insert(header.id)
            offset = newline + 1 + length
        }
        #expect(seen == Set(1...count))
    }

    @Test func aClosedReaderMakesSendReturnFalse() {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        close(descriptors[0])
        // As the engine does (and harmless for the test process).
        signal(SIGPIPE, SIG_IGN)
        let sink = FileDescriptorResponseSink(fileDescriptor: descriptors[1])
        #expect(!sink.send(.success(id: 1, result: EmptyResult())))
        #expect(!sink.send(.success(id: 2, result: EmptyResult())))
        close(descriptors[1])
    }

    // MARK: - Line reader

    @Test func linesAreSplitAcrossReadsWithCRLFBlankAndUnterminatedLines() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
        let input = "first\r\n\n   \nsecond\n" + String(repeating: "x", count: 100) + "\nthird-without-newline"
        let writer = Thread {
            _ = FileDescriptorResponseSink.writeAll(Data(input.utf8), to: writeEnd)
            close(writeEnd)
        }
        writer.start()
        var lines: [String] = []
        var oversized = 0
        LineReader(fileDescriptor: readEnd, maximumLineBytes: 50).run(
            onLine: { lines.append(String(decoding: $0, as: UTF8.self)) },
            onOversizedLine: { oversized += 1 }
        )
        close(readEnd)
        #expect(lines == ["first", "second", "third-without-newline"])
        #expect(oversized == 1)
    }

    // MARK: - Version

    @Test func buildMetadataAcceptsCommitsOnly() {
        #expect(EngineVersion.isValidBuildMetadata("0123456789ab"))
        #expect(EngineVersion.isValidBuildMetadata("0123456789ab.dirty"))
        #expect(!EngineVersion.isValidBuildMetadata(""))
        #expect(!EngineVersion.isValidBuildMetadata("abc def"))
        #expect(!EngineVersion.isValidBuildMetadata("abc..dirty"))
        #expect(!EngineVersion.isValidBuildMetadata("コミット"))
        #expect(EngineVersion.current.hasPrefix("\(EngineVersion.semanticVersion)+"))
    }
}

/// Bytes handed from a reader thread to the test.
private final class Collected: @unchecked Sendable {
    private let condition = NSCondition()
    private var bytes: [UInt8]?

    func set(_ value: [UInt8]) {
        condition.lock()
        bytes = value
        condition.broadcast()
        condition.unlock()
    }

    func wait() throws -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        while bytes == nil {
            guard condition.wait(until: Date().addingTimeInterval(20)) else {
                throw TestFailure(description: "reader did not finish")
            }
        }
        return bytes!
    }
}
