import Foundation
import TandemCore
import TandemMedia

// MARK: - wait

/// What `tandem wait` waits for.
public enum WaitTarget: String, Codable, Sendable, CaseIterable {
    case transcript, matte, proxy
    /// Every background analysis job.
    case jobs
    /// Exports and review clips running through this API.
    case export

    var analysisKind: AnalysisKind? {
        switch self {
        case .transcript: return .transcript
        case .matte: return .matte
        case .proxy: return .proxy
        case .jobs, .export: return nil
        }
    }
}

/// Waits until background work is done: the transcripts, mattes or
/// proxies the project needs (or one file's), every analysis job, or the
/// exports running. It asks for the work it waits for, so with nothing
/// else holding the project the CLI and MCP server make it themselves for
/// as long as the wait lasts (see `ProjectClient`).
public struct WaitRequest: ServiceCall {
    public static let operation = ServiceOperation.wait
    public static let defaultTimeout: Double = 600
    static let longestTimeout: Double = 24 * 3600

    /// Default: jobs.
    public var what: WaitTarget?
    /// Media IDs, clip IDs or paths. Default: everything the project makes.
    public var media: [String]?
    /// Seconds to wait before giving up and saying what's still going.
    /// Default 600.
    public var timeout: Double?

    public init(what: WaitTarget? = nil, media: [String]? = nil, timeout: Double? = nil) {
        self.what = what
        self.media = media
        self.timeout = timeout
    }

    public func run(on service: TandemService, context: CallContext) async throws -> WaitResult {
        try await service.wait(self)
    }
}

/// One piece of work a wait covers.
public struct WaitItem: Codable, Equatable, Sendable {
    /// transcript, matte, proxy, another analysis kind, or export.
    public var kind: String
    public var mediaID: String?
    /// The media file, or an export's output.
    public var path: String
    /// ready, done or failed when finished; waiting, queued or running when not.
    public var state: String
    public var progress: Double?
    public var message: String?
    /// How many words a ready transcript has (0: no speech).
    public var words: Int?
    /// A matte's cutout mode.
    public var mode: String?

    public init(kind: String, mediaID: String?, path: String, state: String, progress: Double? = nil, message: String? = nil, words: Int? = nil, mode: String? = nil) {
        self.kind = kind
        self.mediaID = mediaID
        self.path = path
        self.state = state
        self.progress = progress
        self.message = message
        self.words = words
        self.mode = mode
    }

    var failed: Bool { state == "failed" }
    var finished: Bool { ["ready", "done", "failed", "cancelled"].contains(state) }

    /// "ready, 12 words", "running 40%", "failed: why".
    var stateText: String {
        switch state {
        case "ready":
            guard let words else { return "ready" }
            return words == 0 ? "ready, no speech" : "ready, \(words) word\(words == 1 ? "" : "s")"
        case "running": return progress.map { "running \(Int(($0 * 100).rounded(.down)))%" } ?? "running"
        case "waiting": return "waiting to start"
        case "failed": return message.map { "failed: \($0)" } ?? "failed"
        default: return state
        }
    }
}

public struct WaitResult: Codable, Sendable {
    public var what: WaitTarget
    /// Nothing left to wait for.
    public var done: Bool
    /// The timeout passed first.
    public var timedOut: Bool
    /// Seconds the wait took.
    public var elapsed: Double
    /// What's done or failed.
    public var finished: [WaitItem]
    /// What's still going when the wait timed out.
    public var pending: [WaitItem]

    /// Done, and nothing failed.
    public var ok: Bool { done && !finished.contains(where: \.failed) }
}

extension WaitResult: ReadableResult {
    public var readableText: String {
        if finished.isEmpty && pending.isEmpty {
            switch what {
            case .export: return "No exports running. (A `tandem export` run with the app closed renders in its own process and returns when it's done.)"
            case .jobs: return "No background jobs running."
            case .transcript: return "No transcripts to make."
            case .matte: return "No cutout mattes to make."
            case .proxy: return "No proxies to make."
            }
        }
        let seconds = String(format: "%.1f s", elapsed)
        let failures = finished.filter(\.failed).count
        var lines: [String] = []
        if done {
            lines.append(failures == 0 ? "Done after \(seconds):" : "Done after \(seconds), \(failures) failed:")
        } else {
            lines.append("Still going after \(seconds), when the wait timed out:")
        }
        for item in finished + pending { lines.append("  \(label(item)): \(item.stateText)") }
        if timedOut { lines.append("Run the same `tandem wait` again to keep waiting.") }
        return lines.joined(separator: "\n")
    }

    func label(_ item: WaitItem) -> String {
        var label = item.path
        if what == .jobs { label = "\(item.kind) \(label)" }
        if let mode = item.mode { label += " (\(mode))" }
        return label
    }
}

// MARK: - transcribe

/// Asks for transcripts of files Tandem wouldn't otherwise transcribe
/// (anything with sound, whatever its role or track), with the same
/// on-device engine as camera takes. The request is saved on the
/// media (`transcribe: true`), so it's made wherever the project is opened
/// next, and with `wait` the call waits for it.
public struct TranscribeRequest: ServiceCall {
    public static let operation = ServiceOperation.transcribe
    /// Media IDs, clip IDs or paths.
    public var media: [String]
    /// Wait for the transcripts to be made.
    public var wait: Bool?
    /// Seconds to wait, with `wait`. Default 600.
    public var timeout: Double?
    public var label: String?

    public init(media: [String], wait: Bool? = nil, timeout: Double? = nil, label: String? = nil) {
        self.media = media
        self.wait = wait
        self.timeout = timeout
        self.label = label
    }

    public func run(on service: TandemService, context: CallContext) async throws -> TranscribeResult {
        try await service.transcribe(self, context: context)
    }
}

public struct TranscribeResult: Codable, Sendable {
    public var revision: Int
    /// The edit that marked the files, when any needed marking.
    public var applied: ApplyResult?
    /// Each file's transcript, as it stands when the call returns.
    public var files: [WaitItem]
    /// The wait, with `wait`.
    public var waited: WaitResult?
    /// Opened for this call alone, so nothing makes the transcripts once it
    /// returns unless it waited.
    public var headless: Bool

    /// Nothing failed, and a wait finished.
    public var ok: Bool { !files.contains(where: \.failed) && waited?.done != false }
}

extension TranscribeResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if let applied { lines.append("Applied \"\(applied.label)\" by \(applied.author) as revision \(applied.revision).") }
        if let waited {
            lines.append(waited.readableText)
        } else {
            lines.append("Asked for transcripts of:")
            for file in files { lines.append("  \(file.path) (\(file.mediaID ?? "?")): \(file.stateText)") }
            let waiting = files.filter { !$0.finished }.compactMap(\.mediaID)
            if let id = waiting.first {
                let more = waiting.count > 1 ? " --media \(waiting.dropFirst().joined(separator: " --media "))" : ""
                if headless {
                    lines.append("Nothing has the project open, so they're made when the app or `tandem serve` opens it, or now with `tandem wait transcript --media \(id)\(more)`.")
                } else {
                    lines.append("`tandem wait transcript --media \(id)\(more)` waits for them.")
                }
            }
        }
        if let id = files.first(where: { $0.state == "ready" })?.mediaID {
            lines.append("`tandem transcript \(id)` reads it.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Service

extension TandemService {
    public func transcribe(_ request: TranscribeRequest, context: CallContext) async throws -> TranscribeResult {
        guard !request.media.isEmpty else {
            throw ServiceError(.badRequest, "Name the media to transcribe, like tandem transcribe med_x or a path.")
        }
        let project = coordinator.project
        let items = try resolveMedia(request.media, in: project)
        if let silent = items.first(where: { !$0.hasAudio }) {
            throw ServiceError(.invalid, "\(silent.path) has no sound, so there's nothing to transcribe.")
        }
        // Mark only what nothing else transcribes, so camera takes and the
        // voice don't get an edit for asking.
        let wanted = Set(analysis.needs(for: project).filter { $0.kind == .transcript }.map(\.mediaID))
        let unmarked = items.filter { !wanted.contains($0.id) && $0.transcribe != true }
        var applied: ApplyResult?
        if !unmarked.isEmpty {
            let commands = unmarked.map { EditCommand.updateMedia(mediaID: $0.id, patch: .object(["transcribe": .bool(true)])) }
            let label = request.label ?? (unmarked.count == 1 ? "Transcribe \((unmarked[0].path as NSString).lastPathComponent)" : "Transcribe \(unmarked.count) files")
            applied = try apply(ApplyRequest(label: label, commands: commands), context: context)
        }
        let current = coordinator.project
        for item in items {
            analysis.request(.transcript, for: current.media(item.id) ?? item, priority: .interactive)
        }
        let ids = items.map(\.id)
        if request.wait == true {
            let waited = try await wait(WaitRequest(what: .transcript, media: ids, timeout: request.timeout))
            let byID = Dictionary((waited.finished + waited.pending).map { ($0.mediaID ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            return TranscribeResult(revision: coordinator.revision, applied: applied, files: ids.compactMap { byID[$0] }, waited: waited, headless: mode == .headless)
        }
        let files = items.map { item in
            waitItem(AnalysisNeeds.Need(mediaID: item.id, kind: .transcript, priority: .interactive), current.media(item.id) ?? item)
        }
        return TranscribeResult(revision: coordinator.revision, applied: applied, files: files, waited: nil, headless: mode == .headless)
    }

    public func wait(_ request: WaitRequest) async throws -> WaitResult {
        let what = request.what ?? .jobs
        let started = Date()
        let deadline = started.addingTimeInterval(min(max(request.timeout ?? WaitRequest.defaultTimeout, 0), WaitRequest.longestTimeout))
        let project = coordinator.project
        let items = try resolveMedia(request.media ?? [], in: project)
        // Whoever holds the project queues this as it edits; asking again
        // is cheap, and it's what starts the work when this call holds it.
        analysis.requestNeeded(for: project)

        let outcome: (finished: [WaitItem], pending: [WaitItem], timedOut: Bool)
        switch what {
        case .transcript, .matte, .proxy:
            let targets = try analysisTargets(what.analysisKind!, items: items, project: project)
            outcome = try await waitUntil(deadline) {
                let states = targets.map { self.waitItem($0.need, $0.item) }
                return (states.filter(\.finished), states.filter { !$0.finished })
            }
        case .jobs:
            let ids = Set(items.map(\.id))
            var seen: [String] = []
            outcome = try await waitUntil(deadline) {
                let paths = Dictionary(self.coordinator.project.media.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
                let jobs = self.analysis.jobs.filter { ids.isEmpty || ids.contains($0.mediaID) }
                let active = jobs.filter { $0.state == .queued || $0.state == .running }
                for job in active where !seen.contains(job.id) { seen.append(job.id) }
                let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
                let finished = seen.compactMap { id -> WaitItem? in
                    guard let job = byID[id] else { return nil }
                    return job.state == .queued || job.state == .running ? nil : Self.waitItem(job, path: paths[job.mediaID])
                }
                return (finished, active.map { Self.waitItem($0, path: paths[$0.mediaID]) })
            }
        case .export:
            let log = ExportLog()
            let stream = events.subscribe()
            let collector = Task {
                for await event in stream where event.kind == .export {
                    if let job = event.export { log.record(job) }
                }
            }
            defer { collector.cancel() }
            var seen: [String] = []
            outcome = try await waitUntil(deadline) {
                let running = self.runningExports
                for job in running where !seen.contains(job.id) { seen.append(job.id) }
                let finished = seen.filter { id in !running.contains { $0.id == id } }.map { id in
                    Self.waitItem(log.last(id) ?? ExportJob(id: id, output: "", preset: "", progress: 1, state: .done))
                }
                return (finished, running.map { Self.waitItem($0) })
            }
        }
        return WaitResult(
            what: what, done: outcome.pending.isEmpty, timedOut: outcome.timedOut,
            elapsed: Date().timeIntervalSince(started), finished: outcome.finished, pending: outcome.pending
        )
    }

    /// Checks until nothing's pending or the deadline passes. Polled rather
    /// than driven by job events, since a result can land in the cache (or a
    /// need get queued) without one.
    private func waitUntil(_ deadline: Date, _ check: () -> (finished: [WaitItem], pending: [WaitItem])) async throws -> (finished: [WaitItem], pending: [WaitItem], timedOut: Bool) {
        while true {
            let state = check()
            if state.pending.isEmpty { return (state.finished, [], false) }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return (state.finished, state.pending, true) }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.25) * 1_000_000_000))
        }
    }

    /// The analyses of one kind a wait covers: what the project makes of
    /// that kind, or for the files named, theirs. A file nothing makes it
    /// for is an error that says how to get it made, rather than a wait
    /// that can only time out.
    private func analysisTargets(_ kind: AnalysisKind, items: [MediaItem], project: Project) throws -> [(need: AnalysisNeeds.Need, item: MediaItem)] {
        let needs = analysis.needs(for: project).filter { $0.kind == kind }
        let byID = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard !items.isEmpty else {
            return needs.compactMap { need in byID[need.mediaID].map { (need, $0) } }
        }
        var targets: [(need: AnalysisNeeds.Need, item: MediaItem)] = []
        for item in items {
            let own = needs.filter { $0.mediaID == item.id }
            if !own.isEmpty {
                targets += own.map { ($0, item) }
            } else if analysis.isReady(kind, for: item) {
                targets.append((AnalysisNeeds.Need(mediaID: item.id, kind: kind, priority: .background), item))
            } else {
                throw ServiceError(.invalid, Self.nothingMakes(kind, item))
            }
        }
        return targets
    }

    static func nothingMakes(_ kind: AnalysisKind, _ item: MediaItem) -> String {
        switch kind {
        case .transcript where !item.hasAudio:
            return "\(item.path) has no sound, so it has no transcript."
        case .transcript:
            return "Nothing makes a transcript of \(item.path): Tandem makes them for camera takes, what's on a speech track and files someone asked for. `tandem transcribe \(item.id)` asks for one and waits for it."
        case .matte:
            return "Nothing makes a cutout matte of \(item.path): no clip of it on the timeline has its cutout on. Turn one on (updateClip with video.cutout.enabled) and the matte is made."
        case .proxy:
            return "\(item.path) gets no proxy: they're made for large video on the timeline, and it isn't one."
        default:
            return "Nothing makes \(kind.rawValue) for \(item.path)."
        }
    }

    func waitItem(_ need: AnalysisNeeds.Need, _ item: MediaItem) -> WaitItem {
        var result = WaitItem(kind: need.kind.rawValue, mediaID: item.id, path: item.path, state: "waiting", mode: need.matteMode?.rawValue)
        switch analysis.state(of: need, for: item) {
        case .ready:
            result.state = "ready"
            if need.kind == .transcript { result.words = analysis.transcript(for: item)?.words.count }
        case .failed(let message):
            result.state = "failed"
            result.message = message
        case .unreadable:
            result.state = "failed"
            result.message = "Tandem can't read the file. Is it missing? (`tandem relink` finds moved files.)"
        case .notApplicable:
            result.state = "failed"
            result.message = "\(need.kind.rawValue) doesn't apply to this file."
        case .missing:
            result.state = "waiting"
        case .queued:
            result.state = "queued"
        case .running(let progress):
            result.state = "running"
            result.progress = progress
        }
        return result
    }

    static func waitItem(_ job: JobStatus, path: String?) -> WaitItem {
        WaitItem(
            kind: job.kind.rawValue, mediaID: job.mediaID, path: path ?? job.mediaID, state: job.state.rawValue,
            progress: job.state == .running ? job.progress : nil, message: job.state == .failed ? job.message : nil
        )
    }

    static func waitItem(_ job: ExportJob) -> WaitItem {
        WaitItem(
            kind: "export", mediaID: nil, path: job.output, state: job.state.rawValue,
            progress: job.state == .running ? job.progress : nil, message: job.message
        )
    }

    /// Media named by ID, by a clip that plays it, or by path (relative to
    /// the project folder, or absolute).
    func resolveMedia(_ references: [String], in project: Project) throws -> [MediaItem] {
        var found: [MediaItem] = []
        for reference in references {
            var item = project.media(reference)
            if item == nil, let clip = project.clip(reference), let id = clip.mediaID { item = project.media(id) }
            if item == nil {
                let url = folder.url(forPath: reference)
                item = project.media.first { media in
                    let own = folder.url(for: media)
                    return media.path == reference || own.standardizedFileURL == url.standardizedFileURL
                        || own.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
                }
            }
            guard let item else {
                throw ServiceError(.notFound, "No media with ID or path \(reference). `tandem media` lists them, and `tandem media --refresh` adds new files in the folder.")
            }
            if !found.contains(where: { $0.id == item.id }) { found.append(item) }
        }
        return found
    }
}

/// The last word on each export a wait saw.
private final class ExportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [String: ExportJob] = [:]

    func record(_ job: ExportJob) { lock.withLock { jobs[job.id] = job } }
    func last(_ id: String) -> ExportJob? { lock.withLock { jobs[id] } }
}

// MARK: - Progress

/// Progress lines for a wait, from the service's job and export events:
/// one when a job starts, every 10%, when it goes back to the start of
/// another stage (a transcript that waited for Bark's model to download,
/// then transcribes) and when it ends. Running lines carry the job's message,
/// so a long wait says what it's waiting for.
public final class WaitProgress: @unchecked Sendable {
    private let what: WaitTarget
    private let media: Set<String>
    private let lock = NSLock()
    private var last: [String: (state: String, step: Int)] = [:]

    public init(_ request: WaitRequest) {
        what = request.what ?? .jobs
        // Paths can't be matched against events, which only carry IDs.
        let references = request.media ?? []
        media = references.contains { $0.contains("/") || $0.contains(".") } ? [] : Set(references)
    }

    public func lines(for event: ServiceEvent) -> [String] {
        switch event.kind {
        case .jobs:
            guard what != .export else { return [] }
            return (event.jobs ?? []).compactMap { job in
                if let kind = what.analysisKind, job.kind != kind { return nil }
                if !media.isEmpty, !media.contains(job.mediaID) { return nil }
                return line(id: job.id, name: "\(job.kind.rawValue) \(job.mediaID)", state: job.state.rawValue, progress: job.progress, message: job.message)
            }
        case .export:
            guard what == .export, let job = event.export else { return [] }
            return [line(id: job.id, name: "export \((job.output as NSString).lastPathComponent)", state: job.state.rawValue, progress: job.progress, message: job.message)].compactMap { $0 }
        default:
            return []
        }
    }

    private func line(id: String, name: String, state: String, progress: Double, message: String?) -> String? {
        let step = Int((progress * 10).rounded(.down))
        let terminal = !["queued", "running"].contains(state)
        return lock.withLock {
            let previous = last[id]
            // A job that ended before the wait began isn't news.
            if terminal && previous == nil { return nil }
            if let previous, previous.state == state, state != "running" || step == previous.step { return nil }
            last[id] = (state, step)
            switch state {
            case "running": return "\(name) running \(Int((progress * 100).rounded(.down)))%" + (message.map { ": \($0)" } ?? "")
            case "failed": return "\(name) failed" + (message.map { ": \($0)" } ?? "")
            default: return "\(name) \(state)"
            }
        }
    }
}
