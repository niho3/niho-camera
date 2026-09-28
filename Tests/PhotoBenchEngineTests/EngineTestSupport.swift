import CoreImage
import Foundation
import ImageIO
import PhotoCore
import UniformTypeIdentifiers
@testable import PhotoBenchEngine

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

/// A response as the caller sees it: the parsed header and the body.
struct ParsedResponse {
    let id: Int
    let ok: Bool
    let header: [String: Any]
    let binary: Data?

    var result: [String: Any]? { header["result"] as? [String: Any] }
    var errorCode: String? { (header["error"] as? [String: Any])?["code"] as? String }
    var errorMessage: String? { (header["error"] as? [String: Any])?["message"] as? String }
    var binaryLength: Int? { (header["binaryLength"] as? NSNumber)?.intValue }
    var mime: String? { header["mime"] as? String }

    init(header data: Data, binary: Data?) throws {
        guard let header = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (header["id"] as? NSNumber)?.intValue,
              let ok = header["ok"] as? Bool
        else { throw TestFailure(description: "not a response header: \(String(decoding: data, as: UTF8.self))") }
        self.id = id
        self.ok = ok
        self.header = header
        self.binary = binary
    }

    init(_ response: EngineResponse) throws {
        try self.init(header: response.header, binary: response.binary)
    }
}

/// Collects a session's responses in order and lets a test wait for one.
final class CollectingSink: ResponseSink, @unchecked Sendable {
    private let condition = NSCondition()
    private var responses: [EngineResponse] = []

    @discardableResult
    func send(_ response: EngineResponse) -> Bool {
        condition.lock()
        responses.append(response)
        condition.broadcast()
        condition.unlock()
        return true
    }

    var all: [EngineResponse] {
        condition.lock()
        defer { condition.unlock() }
        return responses
    }

    func count(id: Int) -> Int {
        all.filter { $0.id == id }.count
    }

    /// The first response for `id`, waiting up to `timeout` seconds.
    func response(id: Int, timeout: TimeInterval = 20) throws -> ParsedResponse {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let found = responses.first(where: { $0.id == id }) {
                return try ParsedResponse(found)
            }
            guard condition.wait(until: deadline) else {
                throw TestFailure(description: "no response for id \(id) within \(timeout)s")
            }
        }
    }

    func hasResponse(id: Int) -> Bool {
        count(id: id) > 0
    }
}

/// Records how the session drives the image work, and can hold a render or
/// an export until the test releases it.
final class FakeBackend: EngineBackend, @unchecked Sendable {
    struct RenderCall {
        let photo: String
        let settings: EditSettings
        let maxDimension: Int
        let drag: PreviewDragSession?
    }

    private let lock = NSLock()
    private var opens: [String: Int] = [:]
    private var renderCalls: [RenderCall] = []
    private var exportCalls: [URL] = []
    private var workingCopyCalls: [WorkingCopyRequest] = []
    private var blockedRenders: Set<Int> = []
    private var blocksExports = false
    let renderGate = DispatchSemaphore(value: 0)
    let renderStarted = DispatchSemaphore(value: 0)
    let exportGate = DispatchSemaphore(value: 0)
    let exportStarted = DispatchSemaphore(value: 0)

    /// Render calls (0-based, in call order) that wait for `renderGate` or
    /// their cancellation.
    func blockRenders(_ indexes: Set<Int>) {
        lock.lock()
        blockedRenders = indexes
        lock.unlock()
    }

    /// Exports wait for `exportGate`.
    func blockExports() {
        lock.lock()
        blocksExports = true
        lock.unlock()
    }

    func openCount(_ fileName: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return opens[fileName] ?? 0
    }

    var renders: [RenderCall] {
        lock.lock()
        defer { lock.unlock() }
        return renderCalls
    }

    var exports: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return exportCalls
    }

    var workingCopies: [WorkingCopyRequest] {
        lock.lock()
        defer { lock.unlock() }
        return workingCopyCalls
    }

    func open(url: URL) throws -> OpenedPhoto {
        if url.lastPathComponent.hasPrefix("broken") {
            throw EngineError(.decodeFailed, "写真を読めません: \(url.lastPathComponent)")
        }
        lock.lock()
        opens[url.lastPathComponent, default: 0] += 1
        lock.unlock()
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 6))
        let workingCopy = DecodedPhoto(
            sourceURL: url,
            image: image,
            metadata: [:],
            info: DecodeInfo(backend: "fake", width: 8, height: 6, durationMilliseconds: 0, isRAW: false)
        )
        return OpenedPhoto(
            summary: PhotoSummary(
                kind: url.pathExtension == "RW2" ? .raw : .raster,
                fileName: url.lastPathComponent,
                width: 6_000,
                height: 4_000,
                asShotWhiteBalance: url.pathExtension == "RW2" ? AsShotWhiteBalance(temperature: 5_200, tint: 3) : nil,
                profile: url.pathExtension == "RW2" ? .adobe : nil,
                backend: "fake"
            ),
            workingCopy: workingCopy
        )
    }

    func render(
        workingCopy: DecodedPhoto,
        settings: EditSettings,
        maxDimension: Int,
        drag: PreviewDragSession?,
        cancellation: PreviewCancellation
    ) throws -> RenderedJPEG {
        lock.lock()
        let index = renderCalls.count
        renderCalls.append(RenderCall(
            photo: workingCopy.sourceURL.lastPathComponent, settings: settings, maxDimension: maxDimension, drag: drag
        ))
        let blocks = blockedRenders.contains(index)
        lock.unlock()
        renderStarted.signal()
        if blocks {
            let deadline = Date().addingTimeInterval(20)
            while true {
                if cancellation.isCancelled { throw CancellationError() }
                if renderGate.wait(timeout: .now() + .milliseconds(5)) == .success { break }
                if Date() > deadline { throw EngineError(.internal, "fake render was never released") }
            }
        }
        if cancellation.isCancelled { throw CancellationError() }
        let body = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: UInt8(index & 0xFF), count: 16) + Data([0xFF, 0xD9])
        return RenderedJPEG(data: body, width: maxDimension, height: maxDimension * 2 / 3)
    }

    func export(
        url: URL,
        settings: EditSettings,
        destination: URL,
        quality: Double,
        protectedSources: [URL]
    ) throws -> ExportedJPEG {
        lock.lock()
        exportCalls.append(destination)
        let blocks = blocksExports
        lock.unlock()
        exportStarted.signal()
        if blocks, exportGate.wait(timeout: .now() + 20) == .timedOut {
            throw EngineError(.internal, "fake export was never released")
        }
        if destination.lastPathComponent.hasPrefix("unwritable") {
            throw EngineError(.exportFailed, "書き出せません: \(destination.lastPathComponent)")
        }
        return ExportedJPEG(path: destination.path, width: 6_000, height: 4_000, bytes: 1_234)
    }

    /// A fixed 6000x4000 result: `.RW2` is a RAW without lens correction,
    /// anything else a raster without an ICC profile. Sources named
    /// `broken-icc*`, `broken*` and `unsupported-camera*`, and working copy
    /// paths named `unwritable*`, fail with the matching code.
    func renderWorkingCopy(_ request: WorkingCopyRequest) throws -> WorkingCopyResult {
        lock.lock()
        workingCopyCalls.append(request)
        lock.unlock()
        let name = request.sourceURL.lastPathComponent
        if name.hasPrefix("broken-icc") {
            throw WorkingCopyError(.unsupportedProfile, "ICC が壊れています: \(name)")
        }
        if name.hasPrefix("broken") {
            throw WorkingCopyError(.decodeFailed, "写真を読めません: \(name)")
        }
        if name.hasPrefix("unsupported-camera") {
            throw WorkingCopyError(.unsupportedCamera, "この機種に対応していません: \(name)")
        }
        if request.workingCopyURL.lastPathComponent.hasPrefix("unwritable") {
            throw WorkingCopyError(.exportFailed, "書き出せません: \(request.workingCopyURL.lastPathComponent)")
        }
        let isRAW = request.sourceURL.pathExtension == "RW2"
        let meta: WorkingCopyMeta = isRAW
            ? .raw(.init(
                engine: "apple-raw", decoderVersion: "8", baselineEV: 0, calibration: "none",
                asShotWhite: .init(x: 0.3457, y: 0.3585, temperature: 5_200, tint: 3),
                orientationApplied: true, lensCorrection: nil,
                noiseReduction: .init(luminance: 0.77, color: 0.5), sharpness: 0.9,
                encoding: .png16, colorSpace: "linear-prophoto-d50", sourceExtension: "rw2"
            ))
            : .raster(.init(
                cms: "ci1", icc: .assumedSRGB, orientationApplied: true, encoding: .png16,
                colorSpace: "linear-prophoto-d50", sourceExtension: request.sourceURL.pathExtension.lowercased()
            ))
        let longEdge = min(request.maxDimension, 6_000)
        let previewLongEdge = min(request.previewMaxDimension, 6_000)
        return WorkingCopyResult(
            kind: isRAW ? .raw : .raster,
            baseVersion: isRAW ? "raw-apple.d8.p1.e1.cal-none" : "raster.ci1.p1.e1.icc-srgb",
            width: longEdge,
            height: longEdge * 2 / 3,
            sourceWidth: 6_000,
            sourceHeight: 4_000,
            bytes: 4_321,
            preview: request.previewURL.map { _ in
                .init(width: previewLongEdge, height: previewLongEdge * 2 / 3, bytes: 321)
            },
            meta: meta,
            timings: .init(
                decodeMilliseconds: 12,
                workingCopyMilliseconds: 34,
                previewMilliseconds: request.previewURL == nil ? 0 : 5
            )
        )
    }
}

/// A session over `FakeBackend`, with its own work queue so a test can
/// hold the queue, a recorded `terminate`, and a fixed `profileStatus` (no
/// Adobe install unless the test gives one).
final class SessionHarness: @unchecked Sendable {
    let backend = FakeBackend()
    let sink = CollectingSink()
    let queue = DispatchQueue(label: "PhotoBenchEngineTests.work")
    let profileStatus: AdobeProfileLocator.Status
    private let lock = NSLock()
    private var terminationStatus: Int32?
    private var nextID = 1_000
    lazy var session = EngineSession(
        backend: backend,
        sink: sink,
        terminate: { [weak self] status in self?.recordTermination(status) },
        workQueue: queue,
        profileStatus: { [profileStatus] in profileStatus }
    )

    init(profileStatus: AdobeProfileLocator.Status = .init(lookSource: nil, dcpSources: [])) {
        self.profileStatus = profileStatus
    }

    var terminated: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return terminationStatus
    }

    private func recordTermination(_ status: Int32) {
        lock.lock()
        terminationStatus = status
        lock.unlock()
    }

    /// Sends a request and returns its id.
    @discardableResult
    func send(_ method: String, _ params: [String: Any]? = nil, id: Int? = nil) -> Int {
        let requestID: Int
        lock.lock()
        if let id {
            requestID = id
        } else {
            nextID += 1
            requestID = nextID
        }
        lock.unlock()
        var object: [String: Any] = ["id": requestID, "method": method]
        if let params { object["params"] = params }
        let line = try! JSONSerialization.data(withJSONObject: object)
        session.handle(line: line)
        return requestID
    }

    func sendRaw(_ text: String) {
        session.handle(line: Data(text.utf8))
    }

    func call(_ method: String, _ params: [String: Any]? = nil) throws -> ParsedResponse {
        try sink.response(id: send(method, params))
    }

    /// Opens `fileName` (the fake never touches the disk) and returns its id.
    func open(_ fileName: String) throws -> String {
        let response = try call("open", ["path": "/photos/\(fileName)"])
        guard response.ok, let photoID = response.result?["photoId"] as? String else {
            throw TestFailure(description: "open \(fileName) failed: \(response.header)")
        }
        return photoID
    }

    /// Blocks the work queue until the returned semaphore is signaled.
    func holdQueue() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        let held = DispatchSemaphore(value: 0)
        queue.async {
            held.signal()
            gate.wait()
        }
        held.wait()
        return gate
    }

    /// Waits until every job queued so far has run.
    func drainQueue() {
        queue.sync {}
    }
}

func settingsJSON(_ settings: EditSettings) -> [String: Any] {
    let data = try! JSONEncoder().encode(settings)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

func decodeSettings(_ object: Any?) throws -> EditSettings {
    let data = try JSONSerialization.data(withJSONObject: object as Any)
    return try JSONDecoder().decode(EditSettings.self, from: data)
}

/// A small sRGB JPEG with a gradient, written with ImageIO (the tests never
/// use private photos).
func writeSyntheticJPEG(to url: URL, width: Int, height: Int) throws {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            pixels[index] = UInt8(x * 255 / max(width - 1, 1))
            pixels[index + 1] = UInt8(y * 255 / max(height - 1, 1))
            pixels[index + 2] = UInt8((x + y) * 127 / max(width + height - 2, 1))
        }
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let image = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = context.makeImage() else {
            throw TestFailure(description: "cannot draw the synthetic image")
        }
        return image
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw TestFailure(description: "cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw TestFailure(description: "cannot write \(url.path)")
    }
}

func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotoBenchEngineTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
