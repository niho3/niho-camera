import Darwin
import Foundation
import ImageIO
import PhotoCore
import Testing
@testable import PhotoBenchEngine

/// The built `photobench-engine` as NIHO Desktop runs it: a child process
/// with only HOME and PATH, driven over its standard input and output.
/// The photo is a small JPEG the test writes itself.
///
/// `PHOTOBENCH_ENGINE_BINARY` points the test at another build (for example
/// the packaged `dist/engine/MacOS/photobench-engine`).
@Suite(.serialized)
struct EngineEndToEndTests {
    @Test func openRenderExportCloseAndShutdown() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("gradient.jpg")
        try writeSyntheticJPEG(to: source, width: 96, height: 64)
        let engine = try EngineProcess(binary: Self.engineBinary(), logDirectory: directory)
        defer { engine.stop() }

        let hello = try engine.call(1, "hello")
        #expect(hello.ok, "\(engine.log)")
        #expect(hello.result?["protocolVersion"] as? Int == 1)
        #expect((hello.result?["engineVersion"] as? String)?.hasPrefix("0.2.0+") == true)

        // Which Adobe install is found depends on the Mac; only the shape is fixed.
        let status = try engine.call(100, "profileStatus")
        #expect(status.ok, "\(engine.log)")
        #expect(status.result?["available"] is Bool)
        #expect(status.result?["dcpSources"] is [String])

        // A line that is not JSON is answered with id 0; the engine goes on.
        try engine.sendRaw("this is not json")
        let invalid = try engine.readResponse()
        #expect(invalid.id == 0)
        #expect(invalid.errorCode == "invalidRequest")

        let open = try engine.call(2, "open", ["path": source.path])
        #expect(open.ok, "\(open.header) \(engine.log)")
        let opened = try #require(open.result)
        let photoID = try #require(opened["photoId"] as? String)
        #expect(opened["kind"] as? String == "raster")
        #expect(opened["fileName"] as? String == "gradient.jpg")
        #expect(opened["width"] as? Int == 96)
        #expect(opened["height"] as? Int == 64)
        #expect(opened["profile"] is NSNull)
        #expect(opened["asShotWhiteBalance"] is NSNull)
        let neutral = try #require(opened["settings"])
        #expect(try decodeSettings(neutral) == .neutral)

        var edited = try decodeSettings(neutral)
        edited.exposure = 0.7
        edited.contrast = 20
        let render = try engine.call(3, "render", [
            "photoId": photoID, "settings": settingsJSON(edited), "maxDimension": 48
        ])
        #expect(render.ok, "\(render.header) \(engine.log)")
        #expect(render.mime == "image/jpeg")
        #expect(render.result?["width"] as? Int == 48)
        #expect(render.result?["height"] as? Int == 32)
        let jpeg = try #require(render.binary)
        #expect(render.binaryLength == jpeg.count)
        #expect(jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(jpeg.suffix(2).elementsEqual([0xFF, 0xD9]))
        #expect(Self.pixelSize(of: jpeg) == [48, 32])

        // Drag frames, the exact frame after release, and the original.
        for (id, params) in [
            (4, ["drag": true]), (5, ["drag": true]), (6, ["drag": false]), (7, ["original": true])
        ] as [(Int, [String: Any])] {
            var request: [String: Any] = ["photoId": photoID, "settings": settingsJSON(edited), "maxDimension": 64]
            request.merge(params) { $1 }
            let frame = try engine.call(id, "render", request)
            #expect(frame.ok, "\(frame.header)")
            #expect(frame.binary.flatMap { Self.pixelSize(of: $0) } == [64, 43])
        }

        let presets = try engine.call(8, "builtinPresets")
        let bluesky = try #require((presets.result?["presets"] as? [[String: Any]])?.first)
        let preset = try engine.call(9, "presetSettings", ["xmp": bluesky["xmp"] as Any, "base": neutral])
        #expect(preset.ok, "\(preset.header)")
        let presetSettings = try #require(preset.result?["settings"])
        #expect(try decodeSettings(presetSettings).exposure == 0.42)

        let destination = directory.appendingPathComponent("exports/gradient-edit.jpg")
        let export = try engine.call(10, "export", [
            "photoId": photoID, "settings": presetSettings, "destinationPath": destination.path, "jpegQuality": 0.9
        ])
        #expect(export.ok, "\(export.header) \(engine.log)")
        #expect(export.result?["path"] as? String == destination.path)
        #expect(export.result?["width"] as? Int == 96)
        #expect(export.result?["height"] as? Int == 64)
        let written = try Data(contentsOf: destination)
        #expect(export.result?["bytes"] as? Int == written.count)
        #expect(written.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(Self.pixelSize(of: written) == [96, 64])

        // The source is never overwritten.
        let overwrite = try engine.call(11, "export", [
            "photoId": photoID, "settings": presetSettings, "destinationPath": source.path
        ])
        #expect(overwrite.errorCode == "exportFailed")

        #expect(try engine.call(12, "close", ["photoId": photoID]).ok)
        let afterClose = try engine.call(13, "render", ["photoId": photoID, "settings": neutral])
        #expect(afterClose.errorCode == "notFound")

        let missing = try engine.call(14, "open", ["path": directory.appendingPathComponent("missing.jpg").path])
        #expect(missing.errorCode == "decodeFailed")

        #expect(try engine.call(15, "shutdown").ok)
        #expect(try engine.waitForExit(timeout: 30) == 0)
        #expect(engine.log.contains("photobench-engine: "))
    }

    /// One working copy of a JPEG the test writes, over the child process:
    /// the PNG and the preview land where asked, with the reported sizes.
    @Test func renderWorkingCopyWritesTheWorkingCopyAndThePreview() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("gradient.jpg")
        try writeSyntheticJPEG(to: source, width: 96, height: 64)
        let engine = try EngineProcess(binary: Self.engineBinary(), logDirectory: directory)
        defer { engine.stop() }

        let workingCopy = directory.appendingPathComponent("work/gradient.png")
        let preview = directory.appendingPathComponent("work/gradient-preview.jpg")
        let response = try engine.call(1, "renderWorkingCopy", [
            "path": source.path,
            "workingCopyPath": workingCopy.path,
            "previewPath": preview.path,
            "previewMaxDimension": 48
        ])
        #expect(response.ok, "\(response.header) \(engine.log)")
        let result = try #require(response.result)
        #expect(result["kind"] as? String == "raster")
        let baseVersion = try #require(result["baseVersion"] as? String)
        #expect(baseVersion.hasPrefix("raster.ci1.p1.e1.icc-"))
        #expect(result["width"] as? Int == 96)
        #expect(result["height"] as? Int == 64)
        #expect(result["sourceWidth"] as? Int == 96)
        #expect(result["sourceHeight"] as? Int == 64)
        #expect(result["bytes"] as? Int == (try Data(contentsOf: workingCopy)).count)
        let written = try #require(result["preview"] as? [String: Any])
        #expect(written["width"] as? Int == 48)
        #expect(written["height"] as? Int == 32)
        let jpeg = try Data(contentsOf: preview)
        #expect(written["bytes"] as? Int == jpeg.count)
        #expect(Self.pixelSize(of: jpeg) == [48, 32])
        #expect((try Data(contentsOf: workingCopy)).starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let meta = try #require(result["meta"] as? [String: Any])
        #expect(meta["kind"] as? String == "raster")
        #expect(meta["sourceExtension"] as? String == "jpg")
        let timings = try #require(result["timings"] as? [String: Any])
        #expect(timings["decodeMs"] is Int)
        #expect(timings["workingCopyMs"] is Int)
        #expect(timings["previewMs"] is Int)
        #expect(engine.log.contains("renderWorkingCopy gradient.jpg 96x64 raster \(baseVersion) "))

        // The original is never a destination; paths must be absolute.
        let overwrite = try engine.call(2, "renderWorkingCopy", ["path": source.path, "workingCopyPath": source.path])
        #expect(overwrite.errorCode == "exportFailed")
        let relative = try engine.call(3, "renderWorkingCopy", ["path": source.path, "workingCopyPath": "work.png"])
        #expect(relative.errorCode == "invalidRequest")
        let missing = try engine.call(4, "renderWorkingCopy", [
            "path": directory.appendingPathComponent("missing.RW2").path,
            "workingCopyPath": directory.appendingPathComponent("work/missing.png").path
        ])
        #expect(missing.errorCode == "decodeFailed")

        #expect(try engine.call(5, "shutdown").ok)
        #expect(try engine.waitForExit(timeout: 30) == 0)
    }

    @Test func closingStandardInputEndsTheEngine() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try EngineProcess(binary: Self.engineBinary(), logDirectory: directory)
        defer { engine.stop() }
        #expect(try engine.call(1, "hello").ok)
        engine.closeInput()
        #expect(try engine.waitForExit(timeout: 30) == 0)
    }

    // MARK: - Helpers

    static func engineBinary() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["PHOTOBENCH_ENGINE_BINARY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // `swift test` builds every product next to the test bundle
        // (`<products>/PhotoBenchPackageTests.xctest/Contents/MacOS/<binary>`).
        var candidates: [URL] = []
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let imagePath = info.dli_fname {
            var products = URL(fileURLWithPath: String(cString: imagePath))
            while products.pathComponents.count > 1, products.pathExtension != "xctest" {
                products.deleteLastPathComponent()
            }
            candidates.append(products.deletingLastPathComponent().appendingPathComponent("photobench-engine"))
        }
        candidates.append(projectRoot.appendingPathComponent(".build/debug/photobench-engine"))
        guard let binary = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw TestFailure(description: "photobench-engine is not built (looked at \(candidates.map(\.path)))")
        }
        return binary
    }

    static func pixelSize(of jpeg: Data) -> [Int]? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return [width, height]
    }
}

/// A running `photobench-engine --stdio`, read as NIHO Desktop reads it.
final class EngineProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let logURL: URL
    private var buffer = [UInt8]()

    init(binary: URL, logDirectory: URL) throws {
        signal(SIGPIPE, SIG_IGN)
        logURL = logDirectory.appendingPathComponent("engine-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.executableURL = binary
        process.arguments = ["--stdio"]
        process.environment = [
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: logURL)
        try process.run()
    }

    /// The engine's standard error so far.
    var log: String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    func sendRaw(_ line: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func call(_ id: Int, _ method: String, _ params: [String: Any]? = nil, timeout: TimeInterval = 120) throws -> ParsedResponse {
        var request: [String: Any] = ["id": id, "method": method]
        if let params { request["params"] = params }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        try sendRaw(line)
        let response = try readResponse(timeout: timeout)
        guard response.id == id else {
            throw TestFailure(description: "expected the response to \(id), got \(response.header)")
        }
        return response
    }

    /// The next header line and, when it declares one, its binary body.
    func readResponse(timeout: TimeInterval = 120) throws -> ParsedResponse {
        let deadline = Date().addingTimeInterval(timeout)
        var newline = buffer.firstIndex(of: 0x0A)
        while newline == nil {
            try fill(until: deadline)
            newline = buffer.firstIndex(of: 0x0A)
        }
        let headerBytes = Data(buffer[..<newline!])
        buffer.removeFirst(newline! + 1)
        let header = try ParsedResponse(header: headerBytes, binary: nil)
        guard let length = header.binaryLength else { return header }
        while buffer.count < length {
            try fill(until: deadline)
        }
        let body = Data(buffer[..<length])
        buffer.removeFirst(length)
        return try ParsedResponse(header: headerBytes, binary: body)
    }

    private func fill(until deadline: Date) throws {
        let descriptor = output.fileHandleForReading.fileDescriptor
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw TestFailure(description: "no complete response in time; engine log: \(log)")
            }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 1) * 1_000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw TestFailure(description: "the engine closed its standard output; log: \(log)")
            }
            buffer.append(contentsOf: chunk[0..<count])
            return
        }
    }

    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    func waitForExit(timeout: TimeInterval) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else {
                throw TestFailure(description: "the engine did not exit; log: \(log)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return process.terminationStatus
    }

    func stop() {
        closeInput()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
