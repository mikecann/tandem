import Foundation
import TandemCore
import TandemMedia

/// A render call whose slow part doesn't need the project open. Headless
/// callers take what they need, close the project (so the app can open it)
/// and then render.
public protocol DeferredServiceCall: ServiceCall {
    func prepare(on service: TandemService, context: CallContext) throws -> @Sendable () async throws -> Result
}

extension FrameRequest: DeferredServiceCall {
    public func prepare(on service: TandemService, context: CallContext) throws -> @Sendable () async throws -> ImageResult {
        try service.withPresetFonts(try service.prepareFrame(self))
    }
}

extension ClipRequest: DeferredServiceCall {
    public func prepare(on service: TandemService, context: CallContext) throws -> @Sendable () async throws -> ExportOutcome {
        try service.withPresetFonts(try service.prepareClip(self))
    }
}

extension ExportRequest: DeferredServiceCall {
    public func prepare(on service: TandemService, context: CallContext) throws -> @Sendable () async throws -> ExportOutcome {
        try service.withPresetFonts(try service.prepareExport(self))
    }
}

/// Hosts the API for an open project: the service, the HTTP server, and
/// the port and token in the lock file. The app starts one per open
/// project; `tandem serve` starts one headless.
public final class TandemAPIHost: @unchecked Sendable {
    public let session: ProjectSession
    public let service: TandemService
    public let server: TandemHTTPServer

    private init(session: ProjectSession, service: TandemService, server: TandemHTTPServer) {
        self.session = session
        self.service = service
        self.server = server
    }

    public var port: Int { server.port }
    public var token: String { server.token }

    /// Starts serving `session` on a free port (or `port`) and advertises it.
    public static func start(
        session: ProjectSession,
        analysis: AnalysisSource? = nil,
        renderer: RenderBackend = DefaultRenderBackend(),
        fontInstaller: FontInstalling? = nil,
        port: UInt16 = 0
    ) async throws -> TandemAPIHost {
        let service = TandemService(session: session, mode: .hosted, analysis: analysis, renderer: renderer)
        service.fontInstaller = fontInstaller
        let server = TandemHTTPServer(service: service)
        do {
            let bound = try await server.start(port: port)
            try session.advertise(port: bound, token: server.token)
        } catch {
            server.stop()
            service.shutdown()
            throw error
        }
        session.startWatching()
        return TandemAPIHost(session: session, service: service, server: server)
    }

    /// For the app, when opening a project fails because `tandem serve`
    /// (or a stuck CLI command) has it: asks a serving owner to save and
    /// let go, and waits up to `timeout` seconds for the lock to clear.
    /// Returns true when the project is free to open.
    public static func askOwnerToRelease(_ projectURL: URL, timeout: TimeInterval = 5) async -> Bool {
        guard let lock = ProjectSession.liveLock(for: projectURL) else { return true }
        guard lock.owner == .cli, let port = lock.port, let token = lock.token else { return false }
        do {
            try await TandemHTTPClient(port: port, token: token).requestRelease()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ProjectSession.liveLock(for: projectURL) == nil { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Stops serving. The project stays open; close the session separately.
    /// Calls already running get up to `grace` seconds to answer; new ones
    /// wait for the project (the lock no longer names a port) and then go
    /// wherever it's open next.
    public func stop(finishing grace: TimeInterval = 2) {
        session.stopWatching()
        try? session.stopAdvertising()
        server.stop(finishing: grace)
        service.shutdown()
    }
}

extension ProjectSession {
    /// Opens a project the way the app should: when a CLI command has it
    /// for a moment, waits for it to finish; when `tandem serve` has it,
    /// asks it to save and let go. Gives up after `timeout` seconds with the
    /// usual "is open in Tandem" error.
    public static func open(_ url: URL, owner: Owner, waitingUpTo timeout: TimeInterval) async throws -> ProjectSession {
        let deadline = Date().addingTimeInterval(timeout)
        var asked = false
        while true {
            do {
                return try open(url, owner: owner)
            } catch let error as EditError {
                guard case .locked = error, Date() < deadline else { throw error }
                if !asked, let lock = liveLock(for: url), lock.owner == .cli, lock.port != nil {
                    asked = true
                    _ = await TandemAPIHost.askOwnerToRelease(url, timeout: max(0, deadline.timeIntervalSinceNow))
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

/// Finds the project a command means.
public enum ProjectLocator {
    /// An explicit path (a `.tandem` file, or a folder holding exactly
    /// one), else `$TANDEM_PROJECT`, else the single `.tandem` in the
    /// current folder or the nearest parent that has one.
    public static func find(_ path: String?, in directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let path = path ?? environment["TANDEM_PROJECT"], !path.isEmpty {
            let expanded = NSString(string: path).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                throw ServiceError(.notFound, "No project at \(url.path).")
            }
            if !isFolder.boolValue { return url.standardizedFileURL }
            return try single(in: url.standardizedFileURL, explicit: true)!
        }
        var folder = directory.standardizedFileURL
        while true {
            if let found = try single(in: folder, explicit: false) { return found }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        throw ServiceError(.notFound, "No .tandem project in \(directory.path) or its parents. Pass --project <file.tandem>, or create one with `tandem new <name>.tandem`.")
    }

    private static func single(in folder: URL, explicit: Bool) throws -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let projects = files.filter { $0.pathExtension == ProjectFile.fileExtension }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if projects.count == 1 { return projects[0].standardizedFileURL }
        if projects.count > 1 {
            let names = projects.map(\.lastPathComponent).joined(separator: ", ")
            throw ServiceError(.badRequest, "\(folder.path) has \(projects.count) projects (\(names)). Pick one with --project.")
        }
        if explicit { throw ServiceError(.notFound, "No .tandem project in \(folder.path).") }
        return nil
    }
}

/// Runs service calls against a project wherever it lives: over HTTP when
/// the app (or `tandem serve`) has it open, otherwise by opening the file
/// directly as owner `cli` for just that call. The CLI and the MCP server
/// both go through this.
public final class ProjectClient: @unchecked Sendable {
    public let projectURL: URL
    public let author: String
    /// Overrides for tests: what a headless service uses.
    var analysis: AnalysisSource?
    var renderer: RenderBackend = DefaultRenderBackend()
    /// Where a headless command gets the fonts built-in presets need.
    var fontInstaller: FontInstalling? = LibraryFontInstaller.shared
    /// How long to wait for a project another command is busy with.
    var lockWait: TimeInterval = 15
    /// How long to wait for the app when it has the project but isn't
    /// answering: it's opening it (after a restart, or a new build going
    /// in) or closing it. A big project can take a while to open.
    var appWait: TimeInterval = 90
    /// Told once when a call has been waiting a couple of seconds for the
    /// app, so whoever's at the terminal knows why nothing's happening. The
    /// CLI prints it to stderr.
    public static var waitNotice: ((String) -> Void)?
    /// How long a call waits for the app before saying so.
    var noticeAfter: TimeInterval = 2

    public init(projectURL: URL, author: String) {
        // One spelling per file (/tmp and /private/tmp are the same folder),
        // so calls in this process share one open project.
        self.projectURL = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        self.author = author
    }

    public enum Route: Equatable, Sendable {
        case remote(port: Int, owner: String, pid: Int32)
        case headless
    }

    /// Where the next call would go.
    public var route: Route {
        if let lock = ProjectSession.liveLock(for: projectURL), let port = lock.port, lock.token != nil {
            return .remote(port: port, owner: lock.owner.rawValue, pid: lock.pid)
        }
        return .headless
    }

    public func call<C: ServiceCall>(_ call: C) async throws -> C.Result {
        if let watch = call as? WatchRequest {
            return try await self.watch(watch) as! C.Result
        }
        let started = Date()
        var noticed = false
        var delay: UInt64 = 20_000_000
        while true {
            let lock = ProjectSession.liveLock(for: projectURL)
            let deadline = started.addingTimeInterval(lock?.owner == .app ? appWait : lockWait)
            if let lock {
                if let port = lock.port, let token = lock.token {
                    do {
                        return try await TandemHTTPClient(port: port, token: token, author: author).call(call)
                    } catch let error as ServiceError where Self.mayRetry(call, after: error) && Date() < deadline {
                        // The owner may have just quit; look again.
                    }
                } else if Date() >= deadline {
                    throw ServiceError(.locked, Self.busyMessage(lock, projectURL))
                } else if lock.owner == .app, !noticed, Date().timeIntervalSince(started) >= noticeAfter {
                    noticed = true
                    Self.waitNotice?("Tandem has \(projectURL.lastPathComponent) open but isn't answering yet (it's opening or closing it). Waiting for it…")
                }
            } else {
                do {
                    return try await runHeadless(call)
                } catch let error as EditError {
                    guard case .locked = error, Date() < deadline else { throw ServiceError.wrap(error) }
                    // Someone opened it between our look and our open.
                }
            }
            try await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 250_000_000)
        }
    }

    /// Whether a call the owner's API failed can be sent again: always when
    /// the API couldn't be reached, but after the owner went away mid-call
    /// (it quit or crashed before answering) only when the call changes
    /// nothing. An edit may already be applied and journaled by then, and
    /// sending it again would apply it twice.
    static func mayRetry<C: ServiceCall>(_ call: C, after error: ServiceError) -> Bool {
        switch error.knownCode {
        case .unavailable: return true
        case .interrupted: return !call.changesProject
        default: return false
        }
    }

    static func busyMessage(_ lock: ProjectSession.Lock, _ url: URL) -> String {
        switch lock.owner {
        case .app:
            return "\(url.lastPathComponent) is open in the Tandem app (pid \(lock.pid)), but the app isn't serving its API. Update or restart the app."
        case .cli:
            return "\(url.lastPathComponent) is busy in another tandem command (pid \(lock.pid)). Try again when it finishes."
        }
    }

    private func runHeadless<C: ServiceCall>(_ call: C) async throws -> C.Result {
        let context = CallContext(author: author)
        if let deferred = call as? any DeferredServiceCall {
            let work = try HeadlessPool.shared.with(projectURL, analysis: analysis, renderer: renderer, fontInstaller: fontInstaller) { service in
                try Self.prepare(deferred, on: service, context: context)
            }
            // The project is closed again while the render runs.
            return try await work() as! C.Result
        }
        let service = try HeadlessPool.shared.acquire(projectURL, analysis: analysis, renderer: renderer, fontInstaller: fontInstaller)
        defer { HeadlessPool.shared.release(projectURL) }
        return try await call.run(on: service, context: context)
    }

    private static func prepare<D: DeferredServiceCall>(_ call: D, on service: TandemService, context: CallContext) throws -> @Sendable () async throws -> Any {
        let work = try call.prepare(on: service, context: context)
        return { try await work() }
    }

    /// Waits for the project to change. Uses the owner's API when there is
    /// one; otherwise watches the file, without holding the project open.
    private func watch(_ request: WatchRequest) async throws -> WatchResult {
        let deadline = Date().addingTimeInterval(min(max(request.timeout ?? 30, 0), 600))
        var start = request.revision
        while true {
            if let lock = ProjectSession.liveLock(for: projectURL), let port = lock.port, let token = lock.token {
                let remaining = max(0, deadline.timeIntervalSinceNow)
                do {
                    return try await TandemHTTPClient(port: port, token: token, author: author)
                        .call(WatchRequest(revision: start, timeout: remaining))
                } catch let error as ServiceError where Self.mayRetry(request, after: error) && Date() < deadline {
                    // The app quit mid-wait (a restart, a new build going
                    // in): keep waiting wherever the project is now.
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
            }
            let revision = try Self.fileRevision(projectURL)
            if start == nil { start = revision }
            if let start, revision > start {
                return WatchResult(revision: revision, changed: true, events: [], jobs: [])
            }
            if Date() >= deadline {
                return WatchResult(revision: revision, changed: false, events: [], jobs: [])
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// The revision saved in the project file.
    static func fileRevision(_ url: URL) throws -> Int {
        struct Header: Decodable { var revision: Int }
        return try JSONDecoder().decode(Header.self, from: Data(contentsOf: url)).revision
    }

    /// Server-sent events from the owner, or file changes polled once a
    /// second when nothing serves the project. Runs until the consumer
    /// stops: when the app quits and opens again (a new build going in), it
    /// watches the file in between and then picks up the app's events.
    public func events() -> AsyncThrowingStream<ServiceEvent, Error> {
        let url = projectURL
        let author = author
        return AsyncThrowingStream { continuation in
            let task = Task {
                var last = (try? Self.fileRevision(url)) ?? 0
                var seq = 0
                while !Task.isCancelled {
                    if let lock = ProjectSession.liveLock(for: url), let port = lock.port, let token = lock.token {
                        do {
                            for try await event in TandemHTTPClient(port: port, token: token, author: author).events() {
                                continuation.yield(event)
                            }
                        } catch let error as ServiceError where error.knownCode == .unavailable || error.knownCode == .interrupted {
                            // The owner went away; look again.
                        } catch is CancellationError {
                            break
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                        // The owner saves as it closes, which isn't news.
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        last = (try? Self.fileRevision(url)) ?? last
                        continue
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let revision = try? Self.fileRevision(url), revision != last else { continue }
                    last = revision
                    seq += 1
                    continuation.yield(ServiceEvent(seq: seq, kind: .reload, revision: revision, label: "Saved by another process", author: nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ServiceCall {
    /// True when running the call twice could change the project twice: an
    /// edit, an undo or redo, or a tool asked to apply its cuts.
    var changesProject: Bool {
        switch self {
        case let apply as ApplyRequest: return apply.dryRun != true
        case is UndoRequest, is RedoRequest: return true
        case let tighten as TightenRequest: return tighten.apply == true
        case let captions as CaptionsRequest: return captions.apply == true
        case let short as ShortRequest: return short.apply == true
        case let cards as CardsRequest: return cards.apply == true
        default: return false
        }
    }
}

/// Projects this process has open headless, shared by concurrent calls (an
/// MCP client may send several at once). A project is closed again as soon
/// as its last call finishes, so the app can open it between calls.
final class HeadlessPool: @unchecked Sendable {
    static let shared = HeadlessPool()

    private struct Entry {
        var session: ProjectSession
        var service: TandemService
        var users: Int
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func acquire(_ url: URL, analysis: AnalysisSource?, renderer: RenderBackend, fontInstaller: FontInstalling? = nil) throws -> TandemService {
        lock.lock()
        defer { lock.unlock() }
        if var entry = entries[url] {
            entry.users += 1
            entries[url] = entry
            return entry.service
        }
        let session = try ProjectSession.open(url, owner: .cli)
        let service = TandemService(session: session, mode: .headless, analysis: analysis, renderer: renderer)
        service.fontInstaller = fontInstaller
        entries[url] = Entry(session: session, service: service, users: 1)
        return service
    }

    func release(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[url] else { return }
        entry.users -= 1
        if entry.users > 0 {
            entries[url] = entry
            return
        }
        // Closed under the lock so a call arriving now waits for the save
        // and reopens, instead of finding the file still locked.
        entries.removeValue(forKey: url)
        entry.service.shutdown()
        entry.session.close()
    }

    func with<T>(_ url: URL, analysis: AnalysisSource?, renderer: RenderBackend, fontInstaller: FontInstalling? = nil, _ body: (TandemService) throws -> T) throws -> T {
        let service = try acquire(url, analysis: analysis, renderer: renderer, fontInstaller: fontInstaller)
        defer { release(url) }
        return try body(service)
    }
}
