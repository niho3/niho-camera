import Foundation
import PhotoCore

/// One open photo. Mutable state is guarded by `EngineSession`'s lock.
final class PhotoEntry: @unchecked Sendable {
    let id: String
    let url: URL
    let summary: PhotoSummary
    /// `nil` after the LRU dropped it; the next request that needs it
    /// decodes the photo again.
    var workingCopy: DecodedPhoto?
    /// The slider drag in progress (`drag: true` renders), if any.
    var dragSession: PreviewDragSession?
    /// The newest `render` request for this photo, until it has answered.
    var latestRender: RenderTicket?
    var lastUse: UInt64 = 0

    init(id: String, url: URL, summary: PhotoSummary) {
        self.id = id
        self.url = url
        self.summary = summary
    }
}

/// One `render` request, from arrival to its response.
final class RenderTicket: @unchecked Sendable {
    enum State {
        case queued
        case running
        /// Answered (or, during shutdown, dropped).
        case finished
    }

    let requestID: Int
    let entry: PhotoEntry
    let settings: EditSettings
    let maxDimension: Int
    let dragSession: PreviewDragSession?
    let cancellation = PreviewCancellation()
    /// Guarded by `EngineSession`'s lock.
    var state = State.queued

    init(requestID: Int, entry: PhotoEntry, settings: EditSettings, maxDimension: Int, dragSession: PreviewDragSession?) {
        self.requestID = requestID
        self.entry = entry
        self.settings = settings
        self.maxDimension = maxDimension
        self.dragSession = dragSession
    }
}

/// The engine's request handling (docs/ENGINE_PROTOCOL.md).
///
/// `handle(line:)` is called for each request line in order, from one
/// thread. Cheap requests (`hello`, `builtinPresets`, `presetSettings`,
/// `close`) answer on that thread; `profileStatus` looks at the disk on a
/// queue of its own; `open`, `render`, `export` and `renderWorkingCopy` run
/// one at a time on a serial work queue, so PhotoCore's `RenderEngine` (and
/// `WorkingCopyRenderer`) is used serially, as by the Photo Bench app's
/// `RenderCoordinator` actor, and at most one full-resolution decode is in
/// memory.
///
/// A `render` supersedes the photo's previous one: a queued one answers
/// `cancelled` at once, a running one is cancelled through its
/// `PreviewCancellation` and answers `cancelled` when it stops. Requests for
/// other photos, `export`s and `renderWorkingCopy`s are never cancelled.
final class EngineSession: @unchecked Sendable {
    static let maximumWorkingCopies = 4
    static let maximumPreviewDimension = 2_560
    static let defaultExportQuality = 0.92
    /// How long shutdown waits for the job in flight (an `open`, `export` or
    /// `renderWorkingCopy` cannot be interrupted; a render stops at its next
    /// step).
    static let shutdownGracePeriod: TimeInterval = 30

    private let backend: EngineBackend
    private let sink: ResponseSink
    private let terminate: @Sendable (Int32) -> Void
    private let workQueue: DispatchQueue
    private let profileStatus: @Sendable () -> AdobeProfileLocator.Status
    private let statusQueue = DispatchQueue(label: "life.niho.photobench.engine.status", qos: .utility)
    private let lock = NSLock()
    private var photos: [String: PhotoEntry] = [:]
    private var useClock: UInt64 = 0
    private var isShuttingDown = false

    init(
        backend: EngineBackend,
        sink: ResponseSink,
        terminate: @escaping @Sendable (Int32) -> Void,
        workQueue: DispatchQueue = DispatchQueue(
            label: "life.niho.photobench.engine.work",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        ),
        profileStatus: @escaping @Sendable () -> AdobeProfileLocator.Status = { AdobeProfileLocator().status() }
    ) {
        self.backend = backend
        self.sink = sink
        self.terminate = terminate
        self.workQueue = workQueue
        self.profileStatus = profileStatus
    }

    // MARK: - Input

    func handle(line: Data) {
        guard !shuttingDown else { return }
        switch RequestParser.parse(line) {
        case let .failure(failure):
            send(.failure(id: failure.id, error: failure.error))
        case let .success(request):
            dispatch(request)
        }
    }

    func rejectOversizedLine() {
        guard !shuttingDown else { return }
        send(.failure(
            id: 0,
            error: .invalidRequest("要求の行が長すぎます（\(RequestParser.maximumLineBytes) バイトまで）")
        ))
    }

    /// Standard input closed: cancel what runs and exit.
    func handleEndOfInput() {
        shutdown(answering: nil)
    }

    private func dispatch(_ request: EngineRequest) {
        guard let method = EngineMethod(rawValue: request.method) else {
            send(.failure(id: request.id, error: .invalidRequest("未知の method です: \(request.method)")))
            return
        }
        do {
            switch method {
            case .hello:
                send(.success(
                    id: request.id,
                    result: HelloResult(
                        engineVersion: EngineVersion.current,
                        protocolVersion: EngineVersion.protocolVersion
                    )
                ))
            case .profileStatus:
                // Lightroom may live on a slow external disk, so the checks
                // wait neither the input thread nor a render.
                let requestID = request.id
                statusQueue.async { [self] in
                    guard !shuttingDown else { return }
                    send(.success(id: requestID, result: ProfileStatusResult(profileStatus())))
                }
            case .builtinPresets:
                send(.success(id: request.id, result: BuiltinPresets.result))
            case .presetSettings:
                let params = try request.decodeParams(PresetSettingsParams.self)
                send(.success(id: request.id, result: try PresetSettingsService.apply(params)))
            case .open:
                try enqueueOpen(request)
            case .render:
                try enqueueRender(request)
            case .export:
                try enqueueExport(request)
            case .renderWorkingCopy:
                try enqueueRenderWorkingCopy(request)
            case .close:
                try close(request)
            case .shutdown:
                shutdown(answering: request.id)
            }
        } catch {
            send(.failure(id: request.id, error: .wrapping(error)))
        }
    }

    // MARK: - open

    private func enqueueOpen(_ request: EngineRequest) throws {
        let params = try request.decodeParams(OpenParams.self)
        let url = try Self.absoluteFileURL(params.path, field: "path")
        let requestID = request.id
        workQueue.async { [self] in
            guard !shuttingDown else { return }
            let started = DispatchTime.now()
            do {
                let opened = try backend.open(url: url)
                let entry = PhotoEntry(id: UUID().uuidString.lowercased(), url: url, summary: opened.summary)
                lock.lock()
                entry.workingCopy = opened.workingCopy
                photos[entry.id] = entry
                touch(entry)
                let evicted = evictWorkingCopies(keeping: entry)
                lock.unlock()
                logEvictions(evicted)
                let summary = opened.summary
                EngineLog.write(
                    "open \(summary.fileName) \(summary.width)x\(summary.height) \(summary.backend)"
                        + " profile=\(summary.profile?.rawValue ?? "-") \(Self.milliseconds(since: started))ms"
                )
                send(.success(
                    id: requestID,
                    result: OpenResult(
                        photoId: entry.id,
                        kind: summary.kind.rawValue,
                        fileName: summary.fileName,
                        width: summary.width,
                        height: summary.height,
                        asShotWhiteBalance: summary.asShotWhiteBalance,
                        profile: summary.profile?.rawValue,
                        settings: .neutral
                    )
                ))
            } catch {
                let engineError = EngineError.wrapping(error)
                EngineLog.write("open \(url.lastPathComponent) failed: \(engineError.message)")
                send(.failure(id: requestID, error: engineError))
            }
        }
    }

    // MARK: - render

    private func enqueueRender(_ request: EngineRequest) throws {
        let params = try request.decodeParams(RenderParams.self)
        let original = params.original ?? false
        let drag = params.drag ?? false
        let settings: EditSettings
        if original {
            settings = .neutral
        } else if let requested = params.settings {
            settings = requested
        } else {
            throw EngineError.invalidRequest("params.settings がありません")
        }
        let maxDimension = try Self.previewDimension(params.maxDimension)

        lock.lock()
        guard let entry = photos[params.photoId] else {
            lock.unlock()
            throw EngineError.notFound(photoID: params.photoId)
        }
        // The drag session starts with the first drag frame's settings and
        // ends with the next exact render. `original` frames leave it alone.
        let dragSession: PreviewDragSession?
        if original {
            dragSession = nil
        } else if drag {
            let session = entry.dragSession ?? PreviewDragSession(startSettings: settings)
            entry.dragSession = session
            dragSession = session
        } else {
            entry.dragSession = nil
            dragSession = nil
        }
        let ticket = RenderTicket(
            requestID: request.id,
            entry: entry,
            settings: settings,
            maxDimension: maxDimension,
            dragSession: dragSession
        )
        let superseded = supersede(entry.latestRender)
        entry.latestRender = ticket
        lock.unlock()

        if let superseded {
            send(.failure(id: superseded.requestID, error: .cancelled))
        }
        workQueue.async { [self] in
            runRender(ticket)
        }
    }

    /// Cancels `ticket` (caller holds the lock). Returns it when it had not
    /// started: it is finished here and the caller answers it.
    private func supersede(_ ticket: RenderTicket?) -> RenderTicket? {
        guard let ticket, ticket.state != .finished else { return nil }
        ticket.cancellation.cancel()
        guard ticket.state == .queued else { return nil }
        ticket.state = .finished
        return ticket
    }

    private func runRender(_ ticket: RenderTicket) {
        let entry = ticket.entry
        lock.lock()
        if ticket.state == .finished || isShuttingDown {
            ticket.state = .finished
            lock.unlock()
            return
        }
        guard photos[entry.id] === entry else {
            ticket.state = .finished
            lock.unlock()
            send(.failure(id: ticket.requestID, error: .notFound(photoID: entry.id)))
            return
        }
        ticket.state = .running
        touch(entry)
        let cachedWorkingCopy = entry.workingCopy
        lock.unlock()

        let outcome: Result<RenderedJPEG, Error>
        do {
            let workingCopy = try cachedWorkingCopy ?? reopenWorkingCopy(for: entry, cancellation: ticket.cancellation)
            outcome = .success(try backend.render(
                workingCopy: workingCopy,
                settings: ticket.settings,
                maxDimension: ticket.maxDimension,
                drag: ticket.dragSession,
                cancellation: ticket.cancellation
            ))
        } catch {
            outcome = .failure(error)
        }

        lock.lock()
        ticket.state = .finished
        if entry.latestRender === ticket {
            entry.latestRender = nil
        }
        let closed = photos[entry.id] !== entry
        let cancelled = ticket.cancellation.isCancelled
        lock.unlock()

        if closed {
            send(.failure(id: ticket.requestID, error: .notFound(photoID: entry.id)))
        } else if cancelled {
            send(.failure(id: ticket.requestID, error: .cancelled))
        } else {
            switch outcome {
            case let .success(jpeg):
                send(.binary(
                    id: ticket.requestID,
                    result: RenderResult(width: jpeg.width, height: jpeg.height),
                    body: jpeg.data,
                    mime: "image/jpeg"
                ))
            case let .failure(error):
                let engineError = EngineError.wrapping(error)
                if engineError.code != .cancelled {
                    EngineLog.write("render \(entry.summary.fileName) failed: \(engineError.message)")
                }
                send(.failure(id: ticket.requestID, error: engineError))
            }
        }
    }

    /// Decodes a photo whose working copy the LRU dropped (on the work queue).
    private func reopenWorkingCopy(for entry: PhotoEntry, cancellation: PreviewCancellation) throws -> DecodedPhoto {
        if cancellation.isCancelled { throw CancellationError() }
        let started = DispatchTime.now()
        let opened = try backend.open(url: entry.url)
        lock.lock()
        var evicted: [PhotoEntry] = []
        if photos[entry.id] === entry {
            entry.workingCopy = opened.workingCopy
            touch(entry)
            evicted = evictWorkingCopies(keeping: entry)
        }
        lock.unlock()
        logEvictions(evicted)
        EngineLog.write("reopen \(entry.summary.fileName) \(Self.milliseconds(since: started))ms")
        return opened.workingCopy
    }

    // MARK: - export

    private func enqueueExport(_ request: EngineRequest) throws {
        let params = try request.decodeParams(ExportParams.self)
        let destination = try Self.absoluteFileURL(params.destinationPath, field: "destinationPath")
        let quality = try Self.exportQuality(params.jpegQuality)
        lock.lock()
        guard let entry = photos[params.photoId] else {
            lock.unlock()
            throw EngineError.notFound(photoID: params.photoId)
        }
        let source = entry.url
        // Never overwrite any photo the caller has open.
        let protectedSources = photos.values.map(\.url)
        lock.unlock()

        let requestID = request.id
        let settings = params.settings
        workQueue.async { [self] in
            guard !shuttingDown else { return }
            let started = DispatchTime.now()
            do {
                let exported = try backend.export(
                    url: source,
                    settings: settings,
                    destination: destination,
                    quality: quality,
                    protectedSources: protectedSources
                )
                EngineLog.write(
                    "export \(source.lastPathComponent) -> \(destination.lastPathComponent)"
                        + " \(exported.width)x\(exported.height) \(exported.bytes) bytes \(Self.milliseconds(since: started))ms"
                )
                send(.success(
                    id: requestID,
                    result: ExportResult(
                        path: exported.path,
                        width: exported.width,
                        height: exported.height,
                        bytes: exported.bytes
                    )
                ))
            } catch {
                let engineError = EngineError.wrapping(error)
                EngineLog.write("export \(source.lastPathComponent) failed: \(engineError.message)")
                send(.failure(id: requestID, error: engineError))
            }
        }
    }

    // MARK: - renderWorkingCopy

    private func enqueueRenderWorkingCopy(_ request: EngineRequest) throws {
        let params = try request.decodeParams(RenderWorkingCopyParams.self)
        let source = try Self.absoluteFileURL(params.path, field: "path")
        let workingCopy = try Self.absoluteFileURL(params.workingCopyPath, field: "workingCopyPath")
        let preview = try params.previewPath.map { try Self.absoluteFileURL($0, field: "previewPath") }
        let maxDimension = try Self.previewDimension(params.maxDimension)
        let previewMaxDimension = try Self.workingCopyPreviewDimension(params.previewMaxDimension)
        // As `export`: never overwrite any photo the caller has open.
        lock.lock()
        let protectedSources = photos.values.map(\.url)
        lock.unlock()

        let requestID = request.id
        let job = WorkingCopyRequest(
            sourceURL: source,
            workingCopyURL: workingCopy,
            previewURL: preview,
            maxDimension: maxDimension,
            previewMaxDimension: previewMaxDimension,
            protectedSourceURLs: protectedSources
        )
        workQueue.async { [self] in
            guard !shuttingDown else { return }
            let started = DispatchTime.now()
            do {
                let rendered = try backend.renderWorkingCopy(job)
                EngineLog.write(
                    "renderWorkingCopy \(source.lastPathComponent) \(rendered.width)x\(rendered.height)"
                        + " \(rendered.kind.rawValue) \(rendered.baseVersion) \(Self.milliseconds(since: started))ms"
                )
                send(.success(id: requestID, result: RenderWorkingCopyResult(rendered)))
            } catch {
                let engineError = EngineError.wrapping(error)
                EngineLog.write("renderWorkingCopy \(source.lastPathComponent) failed: \(engineError.message)")
                send(.failure(id: requestID, error: engineError))
            }
        }
    }

    // MARK: - close / shutdown

    private func close(_ request: EngineRequest) throws {
        let params = try request.decodeParams(CloseParams.self)
        lock.lock()
        guard let entry = photos.removeValue(forKey: params.photoId) else {
            lock.unlock()
            throw EngineError.notFound(photoID: params.photoId)
        }
        let queued = supersede(entry.latestRender)
        entry.latestRender = nil
        entry.workingCopy = nil
        entry.dragSession = nil
        lock.unlock()
        if let queued {
            send(.failure(id: queued.requestID, error: .notFound(photoID: entry.id)))
        }
        send(.success(id: request.id, result: EmptyResult()))
    }

    /// Stops taking requests, cancels every render, waits for the job in
    /// flight (up to `shutdownGracePeriod`), answers `shutdown` and exits.
    /// Requests that have not started get no answer.
    private func shutdown(answering requestID: Int?) {
        lock.lock()
        guard !isShuttingDown else {
            lock.unlock()
            return
        }
        isShuttingDown = true
        for entry in photos.values {
            entry.latestRender?.cancellation.cancel()
        }
        lock.unlock()

        let drained = DispatchSemaphore(value: 0)
        workQueue.async { drained.signal() }
        if drained.wait(timeout: .now() + Self.shutdownGracePeriod) == .timedOut {
            EngineLog.write("shutdown: 走行中の処理が \(Int(Self.shutdownGracePeriod)) 秒で終わらないため終了します")
        }
        if let requestID {
            send(.success(id: requestID, result: EmptyResult()))
        }
        EngineLog.write(requestID == nil ? "標準入力が閉じたので終了します" : "shutdown")
        terminate(0)
    }

    // MARK: - Helpers

    private var shuttingDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShuttingDown
    }

    private func send(_ response: EngineResponse) {
        sink.send(response)
    }

    /// Caller holds the lock.
    private func touch(_ entry: PhotoEntry) {
        useClock &+= 1
        entry.lastUse = useClock
    }

    /// Drops the least recently used working copies beyond
    /// `maximumWorkingCopies` (caller holds the lock). Their photo ids stay
    /// valid; the next request that needs one decodes it again.
    private func evictWorkingCopies(keeping kept: PhotoEntry) -> [PhotoEntry] {
        let holders = photos.values.filter { $0.workingCopy != nil }
        let excess = holders.count - Self.maximumWorkingCopies
        guard excess > 0 else { return [] }
        let victims = holders.filter { $0 !== kept }.sorted { $0.lastUse < $1.lastUse }.prefix(excess)
        for victim in victims {
            victim.workingCopy = nil
            // A drag session keeps statistics of (and so references) the
            // working copy it measured.
            victim.dragSession = nil
        }
        return Array(victims)
    }

    private func logEvictions(_ entries: [PhotoEntry]) {
        for entry in entries {
            EngineLog.write("作業コピーを捨てました（次の要求で読み直します）: \(entry.summary.fileName)")
        }
    }

    static func absoluteFileURL(_ path: String, field: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw EngineError.invalidRequest("params.\(field) は絶対パスにしてください")
        }
        return URL(fileURLWithPath: path)
    }

    /// `maxDimension`: default and upper bound 2560 (the working copy's size).
    static func previewDimension(_ value: Int?) throws -> Int {
        guard let value else { return maximumPreviewDimension }
        guard value > 0 else { throw EngineError.invalidRequest("params.maxDimension は 1 以上にしてください") }
        return min(value, maximumPreviewDimension)
    }

    /// `renderWorkingCopy`'s `previewMaxDimension`: 1024 when left out,
    /// otherwise 1...2560.
    static func workingCopyPreviewDimension(_ value: Int?) throws -> Int {
        guard let value else { return WorkingCopyRenderer.defaultPreviewMaxDimension }
        guard (1...maximumPreviewDimension).contains(value) else {
            throw EngineError.invalidRequest("params.previewMaxDimension は 1〜\(maximumPreviewDimension) にしてください")
        }
        return value
    }

    static func exportQuality(_ value: Double?) throws -> Double {
        guard let value else { return defaultExportQuality }
        guard value.isFinite else { throw EngineError.invalidRequest("params.jpegQuality は 0〜1 にしてください") }
        return min(max(value, 0), 1)
    }

    static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }
}
