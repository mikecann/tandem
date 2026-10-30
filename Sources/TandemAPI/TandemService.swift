import CoreGraphics
import Foundation
import TandemAssets
import TandemCore
import TandemMedia
import TandemAssets
import TandemRender

/// The operations agents use, on one open project. The HTTP server, the
/// CLI and the MCP server are thin layers over this.
///
/// Every edit goes through the session's `ProjectCoordinator`, so it's
/// validated, undoable, journaled and announced like an edit made in the
/// app. The service is safe to call from any thread.
public final class TandemService: @unchecked Sendable {
    public enum Mode: Sendable {
        /// The app or `tandem serve` holds the project open for a while.
        case hosted
        /// The CLI or MCP server opened the project for one call and closes
        /// it straight after. Undo history lives on disk in this mode.
        case headless
    }

    public let session: ProjectSession
    public let mode: Mode
    public let analysis: AnalysisSource
    public let renderer: RenderBackend
    public let events = EventHub()
    /// Set by the app to capture its window for `screenshot`.
    public var screenshotProvider: (@Sendable () async throws -> Data)?
    /// Installs the fonts built-in title presets need (the caption preset's
    /// Tilt Warp) the first time the project uses one that's missing. The
    /// app, `tandem serve` and CLI commands set the asset library's; nil
    /// leaves them missing, with a warning.
    public var fontInstaller: FontInstalling?
    /// What `check --cuts --listen` hears with and renders by, in place of
    /// Bark (or SpeechAnalyzer) and the export mix: for tests.
    var cutListening: (ears: [CutCheck.Ear], mix: CutCheck.Mix)?
    /// Called for every call a client makes, reads included, with the
    /// operation's name (`status`, `apply`, `watch`...) and the author it's
    /// credited to, so the app can show which agent is connected. Runs on
    /// the server's threads; keep it quick.
    public var onCall: (@Sendable (_ operation: String, _ author: String) -> Void)? {
        get { hookLock.withLock { callHook } }
        set { hookLock.withLock { callHook = newValue } }
    }
    private let hookLock = NSLock()
    private var callHook: (@Sendable (_ operation: String, _ author: String) -> Void)?

    /// Reports a call to `onCall`.
    public func noteCall(_ operation: String, author: String) {
        onCall?(operation, author)
    }

    /// Finds the shared library (`~/Movies/Tandem Library`), which relink
    /// searches for what the given folders don't have and archive names
    /// its files by. Asked each time, so a library moved in Settings is
    /// found where it is now; tests point it at a temp folder.
    public var locateSharedLibrary: @Sendable () -> SharedLibrary? {
        get { hookLock.withLock { sharedLocator } }
        set { hookLock.withLock { sharedLocator = newValue } }
    }
    private var sharedLocator: @Sendable () -> SharedLibrary? = { SharedLibrary.locate() }

    /// Where the section cards' whooshes come from (`cards`). Nil, the
    /// default, opens the per-user asset library the first time a card
    /// needs them; tests set their own.
    public var soundLibrary: AssetLibrary? {
        get { hookLock.withLock { library } }
        set { hookLock.withLock { library = newValue } }
    }
    private var library: AssetLibrary?

    func cardSoundLibrary() -> AssetLibrary? {
        if let soundLibrary { return soundLibrary }
        guard let opened = try? AssetService.standard().library else { return nil }
        soundLibrary = opened
        return opened
    }

    public var coordinator: ProjectCoordinator { session.coordinator }
    public var folder: ProjectFolder { session.folder }

    let history: HeadlessHistory
    /// Serialises snapshot, apply and history bookkeeping so a before
    /// snapshot always belongs to the edit recorded with it.
    private let editLock = NSLock()
    private let stateLock = NSLock()
    private var exports: [String: ExportJob] = [:]
    private var pendingRestore: (kind: ServiceEvent.Kind, label: String, author: String)?
    private var coordinatorToken: UUID?
    private var jobsToken: UUID?

    public init(
        session: ProjectSession,
        mode: Mode = .hosted,
        analysis: AnalysisSource? = nil,
        renderer: RenderBackend = DefaultRenderBackend()
    ) {
        self.session = session
        self.mode = mode
        self.analysis = analysis ?? MediaAnalysisSource(session.analysis)
        self.renderer = renderer
        self.history = HeadlessHistory(projectURL: session.fileURL)
        // Level speech by what this service's analysis measured.
        session.coordinator.measureSound = { [analysis = self.analysis] project in
            ProjectSession.measuredSound(in: project) { analysis.loudness(for: $0) }
        }
        // Observers run inside the coordinator's queue, so they must not
        // call back into the coordinator. They only record the event.
        coordinatorToken = session.coordinator.observe { [weak self] change in
            self?.record(change)
        }
        jobsToken = self.analysis.observeJobs { [weak self] jobs in
            self?.events.publish { ServiceEvent(seq: $0, kind: .jobs, jobs: jobs) }
        }
    }

    /// Stops observing the project and ends watch streams. Call before
    /// closing the session.
    public func shutdown() {
        if let token = coordinatorToken { coordinator.removeObserver(token) }
        if let token = jobsToken { analysis.removeJobsObserver(token) }
        coordinatorToken = nil
        jobsToken = nil
        events.finishAll()
    }

    private func record(_ change: ProjectCoordinator.ChangeEvent) {
        stateLock.lock()
        let restore = change.kind == .reload ? pendingRestore : nil
        if restore != nil { pendingRestore = nil }
        stateLock.unlock()
        let kind: ServiceEvent.Kind
        switch change.kind {
        case .edit: kind = .edit
        case .undo: kind = .undo
        case .redo: kind = .redo
        case .reload: kind = restore?.kind ?? .reload
        }
        events.publish {
            ServiceEvent(
                seq: $0, kind: kind, revision: change.revision,
                label: restore?.label ?? change.label, author: restore?.author ?? change.author
            )
        }
    }

    /// Runs any call against this service with JSON in and out, for the
    /// HTTP server.
    public func handle(_ operation: ServiceOperation, body: Data, context: CallContext) async throws -> Data {
        noteCall(operation.rawValue, author: context.author)
        return try await handle(operation.callType, body: body, context: context)
    }

    private func handle<C: ServiceCall>(_ type: C.Type, body: Data, context: CallContext) async throws -> Data {
        let call = try ServiceJSON.decodeRequest(C.self, from: body)
        let result = try await call.run(on: self, context: context)
        return try ServiceJSON.encoder().encode(result)
    }

    // MARK: - status

    public func status() -> StatusResult {
        let (project, revision) = coordinator.snapshot()
        let fonts = fontWarnings(project)
        let lock = ProjectSession.readLock(for: session.fileURL)
        let owner = lock.map { OwnerInfo(owner: $0.owner.rawValue, pid: $0.pid, started: $0.started, port: $0.port) }
        // What `undo` and `redo` would do: the coordinator's stacks, or the
        // on-disk history of headless edits while it still applies.
        let undo = coordinator.undoLabel ?? history.peekUndo(at: revision)?.label
        let redo = coordinator.redoLabel ?? history.peekRedo(at: revision)?.label
        stateLock.lock()
        let running = exports.values.sorted { $0.id < $1.id }
        stateLock.unlock()
        return StatusResult(
            name: project.name,
            path: session.fileURL.path,
            revision: revision,
            savedRevision: session.savedRevision,
            dirty: session.isDirty,
            duration: project.duration,
            width: project.settings.width,
            height: project.settings.height,
            frameRate: project.settings.frameRate.framesPerSecond,
            tracks: project.allTracks.count,
            clips: project.allTracks.reduce(0) { $0 + $1.clips.count },
            media: project.media.count,
            markers: project.markers.count,
            undo: undo,
            redo: redo,
            openIn: owner,
            headless: mode == .headless,
            jobs: analysis.jobs,
            exports: running,
            recoveredEdits: session.recoveredEdits,
            apiVersion: TandemAPI.version,
            warnings: fonts,
            reviewPending: session.review.log.entries.map(PendingReview.init),
            handback: session.review.log.notes.map { LookHere($0, comments: []) }
        )
    }

    /// Titles in a font this process can't draw, with the fix. The
    /// project's own fonts are registered first, so a font added to
    /// assets/font/ since (by `tandem assets use`, say) counts, and the app
    /// draws with it from then on.
    func fontWarnings(_ project: Project) -> [String] {
        ProjectFonts.registerNew(in: folder)
        return ProjectFonts.missing(in: project).map(\.warning)
    }

    // MARK: - media

    public func media(refresh: Bool) async throws -> MediaResult {
        var added: [String] = []
        if refresh {
            // Fonts aren't media, but a refresh is when new files are looked
            // for, and the renderer should have any new ones in assets/font/.
            ProjectFonts.registerNew(in: folder)
            added = try await session.refreshMedia()
        }
        let (project, revision) = coordinator.snapshot()
        var usage: [String: Int] = [:]
        for clip in project.allTracks.flatMap(\.clips) {
            if let id = clip.mediaID { usage[id, default: 0] += 1 }
        }
        let jobs = analysis.jobs
        let items = project.media.map { item in
            MediaInfo(
                id: item.id,
                path: item.path,
                kind: item.kind,
                role: item.role,
                duration: item.duration,
                width: item.width,
                height: item.height,
                frameRate: item.frameRate?.framesPerSecond,
                hasVideo: item.hasVideo,
                hasAudio: item.hasAudio,
                undecodableCodec: item.undecodableCodec,
                livePhotoVideo: item.livePhotoVideo,
                takeID: item.takeID,
                takeOffset: item.takeOffset,
                clips: usage[item.id] ?? 0,
                exists: FileManager.default.fileExists(atPath: folder.url(for: item).path),
                analysis: analysisStates(for: item, jobs: jobs),
                pictureDelay: item.pictureDelay,
                pictureDelayCorrected: item.pictureDelayCorrected
            )
        }
        return MediaResult(revision: revision, added: added, items: items, replaced: nil)
    }

    /// Points a media item at another file of the same length, such as a
    /// processed copy of a voice, as one undo step: every clip stays where
    /// it is, and the item takes the new file's probe and fingerprint, so
    /// loudness, transcript, waveform and the rest are made again from it.
    /// Refuses a file whose length differs by more than a frame, or that
    /// lacks the sound or picture the old one had, since clips cut against
    /// the old file would land on the wrong words.
    public func replaceMedia(_ mediaID: String, with file: String, label: String?, author: String?, context: CallContext) async throws -> ReplacedMedia {
        let project = coordinator.project
        guard let item = project.media(mediaID) else { throw ServiceError(.notFound, "There's no media \(mediaID).") }
        let url = outputURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ServiceError(.notFound, "There's no file at \(url.path).") }
        var replaced: MediaItem
        do {
            replaced = try await MediaScanner.probe(url, replacing: item, folder: folder)
        } catch {
            throw ServiceError(.invalid, "Couldn't read \(url.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        replaced.path = MediaRelinker.storedPath(for: url, in: folder)
        replaced.replaces = MediaItem.replaces(item, with: replaced.path)
        guard replaced.path != item.path else { throw ServiceError(.invalid, "\(mediaID) already plays \(item.path).") }
        if item.hasAudio && !replaced.hasAudio { throw ServiceError(.invalid, "\(replaced.path) has no sound and \(item.path) did.") }
        if item.hasVideo && !replaced.hasVideo { throw ServiceError(.invalid, "\(replaced.path) has no picture and \(item.path) did.") }
        let frame = project.settings.frameRate.frameDuration
        if let old = item.duration, let new = replaced.duration, abs((new - old).seconds) > frame.seconds {
            throw ServiceError(.invalid, "\(replaced.path) is \(TimeText.duration(new)) long and \(item.path) is \(TimeText.duration(old)), more than a frame apart, so clips cut against the old file would play the wrong moments. To use it anyway, apply updateMedia with the new path.")
        }
        let before = try JSONValue.from(item)
        let after = try JSONValue.from(replaced)
        guard let patch = JSONValue.mergePatch(from: before, to: after) else { throw ServiceError(.invalid, "\(mediaID) already plays \(item.path).") }
        // Media a folder scan added for the new file before the swap goes in
        // the same step, unless a clip plays it.
        let used = Set(project.allTracks.flatMap(\.clips).compactMap(\.mediaID))
        let copies = project.media.filter { $0.id != mediaID && $0.path == replaced.path && !used.contains($0.id) }
        let name = (replaced.path as NSString).lastPathComponent
        let applied = try apply(ApplyRequest(label: label ?? "Replace \((item.path as NSString).lastPathComponent) with \(name)", author: author,
                                             commands: [.updateMedia(mediaID: mediaID, patch: patch)] + copies.map { .removeMedia(mediaID: $0.id) }), context: context)
        let clips = coordinator.project.allTracks.flatMap(\.clips).filter { $0.mediaID == mediaID }.count
        return ReplacedMedia(mediaID: mediaID, from: item.path, to: replaced.path, oldDuration: item.duration, newDuration: replaced.duration, clips: clips, applied: applied)
    }

    /// The analyses that apply to a file, and how far along each is.
    func analysisStates(for item: MediaItem, jobs: [JobStatus]) -> [String: AnalysisState] {
        var kinds: [AnalysisKind] = []
        if AnalysisKind.converted.applies(to: item) { kinds.append(.converted) }
        if item.hasVideo || item.kind == .image { kinds.append(.thumbnails) }
        if item.hasVideo && item.kind == .video { kinds.append(.proxy) }
        if item.hasAudio { kinds += [.waveform, .loudness, .transcript] }
        if item.role == .camera {
            if item.hasVideo { kinds.append(.matte) }
            if item.hasAudio { kinds.append(.isolatedVoice) }
        }
        var states: [String: AnalysisState] = [:]
        for kind in kinds {
            if analysis.isReady(kind, for: item) {
                states[kind.rawValue] = AnalysisState(state: "ready")
            } else if let job = jobs.last(where: { $0.mediaID == item.id && $0.kind == kind }) {
                states[kind.rawValue] = AnalysisState(state: job.state.rawValue, progress: job.state == .running ? job.progress : nil,
                                                      message: job.state == .failed ? job.message : nil)
            } else {
                states[kind.rawValue] = AnalysisState(state: "none")
            }
        }
        return states
    }

    // MARK: - timeline

    public func timeline(from: Time?, to: Time?, format: TimelineRequest.Format, words: Bool, summary: Bool = false) throws -> TimelineResult {
        if let from, let to, to <= from {
            throw ServiceError(.badRequest, "`to` (\(to)) must be after `from` (\(from)).")
        }
        let (project, revision) = coordinator.snapshot()
        switch format {
        case .json:
            return TimelineResult(revision: revision, text: nil, project: TimelineDump.filtered(project, from: from, to: to))
        case .text where summary:
            return TimelineResult(revision: revision, text: TimelineDump.summary(project, revision: revision), project: nil)
        case .text:
            var options = TimelineDump.Options()
            options.from = from
            options.to = to
            if words {
                options.transcripts = { [analysis] item in analysis.transcript(for: item) }
            }
            let text = TimelineDump.render(project, revision: revision, options: options)
            return TimelineResult(revision: revision, text: text, project: nil)
        }
    }

    // MARK: - transcripts

    /// What to say when a file has no transcript yet: whether anything is
    /// making one, and the command that gets it made or waits for it.
    func noTranscriptYet(_ item: MediaItem, in project: Project) -> String {
        let wanted = analysis.needs(for: project).contains { $0.mediaID == item.id && $0.kind == .transcript }
        switch mode {
        case .hosted where wanted:
            return "\(item.path) has no transcript yet. It's being made in the background; `tandem wait transcript --media \(item.id)` waits for it."
        case .hosted:
            return "\(item.path) has no transcript: Tandem only makes them for camera takes, what's on a speech track and files someone asked for. `tandem transcribe \(item.id)` makes one and waits for it."
        case .headless:
            return "\(item.path) has no transcript yet, and nothing is making one, since the project isn't open in the app. `tandem transcribe \(item.id)` makes it now and waits for it."
        }
    }

    public func transcript(id: String?, from: Time?, to: Time?) throws -> TranscriptResult {
        let (project, revision) = coordinator.snapshot()
        func keep(_ start: Time, _ end: Time) -> Bool {
            if let from, end <= from { return false }
            if let to, start >= to { return false }
            return true
        }
        guard let id else {
            let map = TranscriptTools.speechMap(project, analysis: analysis)
            let words = map.words.filter { keep($0.start, $0.end) }.map {
                WordTiming(text: $0.text, start: $0.start, end: $0.end, clipID: $0.clipID, confidence: $0.confidence)
            }
            return TranscriptResult(revision: revision, scope: "timeline", id: nil, timelineTimes: true, words: words, missing: map.missing)
        }
        if let item = project.media(id) {
            guard let transcript = analysis.transcript(for: item) else {
                throw ServiceError(.unavailable, noTranscriptYet(item, in: project))
            }
            let words = transcript.words.filter { keep($0.start, $0.end) }.map {
                WordTiming(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence)
            }
            return TranscriptResult(revision: revision, scope: "media", id: id, timelineTimes: false, words: words, missing: [])
        }
        if let clip = project.clip(id) {
            guard let mediaID = clip.mediaID, let item = project.media(mediaID) else {
                throw ServiceError(.invalid, "Clip \(id) isn't a media clip, so it has no transcript.")
            }
            guard item.hasAudio else {
                throw ServiceError(.invalid, "Clip \(id) plays \(item.path), which has no sound.")
            }
            guard let transcript = analysis.transcript(for: item) else {
                throw ServiceError(.unavailable, noTranscriptYet(item, in: project))
            }
            guard let track = project.allTracks.first(where: { $0.clips.contains { $0.id == id } }) else {
                throw ServiceError(.notFound, "No media or clip with ID \(id).")
            }
            let words = TranscriptTools.words(transcript, playedBy: clip, on: track).filter { keep($0.start, $0.end) }.map {
                WordTiming(text: $0.text, start: $0.start, end: $0.end, clipID: $0.clipID, confidence: $0.confidence)
            }
            return TranscriptResult(revision: revision, scope: "clip", id: id, timelineTimes: true, words: words, missing: [])
        }
        throw ServiceError(.notFound, "No media or clip with ID \(id).")
    }

    public func search(phrase: String, limit: Int?) throws -> SearchResult {
        guard !TranscriptTools.tokens(phrase).isEmpty else {
            throw ServiceError(.badRequest, "Search for at least one word.")
        }
        let (project, revision) = coordinator.snapshot()
        var found = TranscriptTools.search(phrase, in: project, analysis: analysis)
        if let limit, limit >= 0 {
            found.hits = Array(found.hits.prefix(limit))
            found.unused = Array(found.unused.prefix(limit))
        }
        return SearchResult(revision: revision, phrase: phrase, hits: found.hits, unused: found.unused, missing: found.missing)
    }

    public func pauses(minimum: Time, from: Time?, to: Time?) throws -> PausesResult {
        guard minimum > .zero else { throw ServiceError(.badRequest, "`min` must be more than 0 seconds.") }
        let (project, revision) = coordinator.snapshot()
        let map = TranscriptTools.speechMap(project, analysis: analysis)
        let pauses = TranscriptTools.pauses(in: map, minimum: minimum, from: from, to: to)
        let total = pauses.reduce(Time.zero) { $0 + $1.duration }
        return PausesResult(revision: revision, minimum: minimum, pauses: pauses, total: total, missing: map.missing)
    }

    /// Pauses with what the sound under each has (`tandem pauses`): the gap
    /// as it's heard, its real pauses, and sound in it no word accounts for.
    public func listenedPauses(minimum: Time, from: Time?, to: Time?) async throws -> PausesResult {
        var result = try pauses(minimum: minimum, from: from, to: to)
        let (project, _) = coordinator.snapshot()
        let map = TranscriptTools.speechMap(project, analysis: analysis)
        let heard = await SoundTightening.listened(result.pauses, map: map, project: project, folder: folder)
        result.pauses = heard.pauses
        result.warnings = heard.warnings
        return result
    }

    public func tighten(_ request: TightenRequest, context: CallContext) async throws -> TightenResult {
        let rules = try pauseRules(for: request)
        let (project, revision) = coordinator.snapshot()
        try checkExpected(request.expectedRevision, at: revision)
        let map = TranscriptTools.speechMap(project, analysis: analysis)
        let protect = request.protect ?? []
        // Each cut placed in the sound under its pause, on every track the
        // take plays there (`SoundTightening`). The minimum, the range and
        // the protect times all apply to the pause as it's heard, which can
        // reach past the transcript's gap.
        let found = SoundTightening.candidates(in: map, rules: rules, from: request.from, to: request.to)
        let planned = await SoundTightening.plan(
            found, rules: rules, snug: request.bySentence, protect: protect, from: request.from, to: request.to,
            map: map, project: project, folder: folder
        )
        let cuts = planned.cuts
        let protected = planned.protected
        let widened = request.widen == true
            ? TranscriptTools.widening(in: map, project: project, rules: rules, protect: protect, from: request.from, to: request.to) { analysis.transcript(for: $0) }
            : []
        let commands = TranscriptTools.commands(for: cuts, widening: widened)
        let removed = cuts.reduce(Time.zero) { $0 + $1.cut.duration }
        let added = widened.reduce(Time.zero) { $0 + $1.added }

        var warnings = planned.warnings
        if !map.missing.isEmpty {
            let names = map.missing.compactMap { project.media($0)?.path }.joined(separator: ", ")
            warnings.append("No transcript yet for \(names), so pauses there aren't included.")
        }
        let locked = project.allTracks.filter { $0.rippleMode == .cut && $0.locked }.map(\.name)
        if !locked.isEmpty && !commands.isEmpty {
            let message = "Track \(locked.map { "\"\($0)\"" }.joined(separator: ", ")) is locked, so tightening would put the take out of sync. Unlock it first."
            if request.apply == true { throw ServiceError(.locked, message) }
            warnings.append(message)
        }

        let bySentence = request.bySentence
        var result = TightenResult(
            revision: revision, minimum: rules.minimum,
            keep: rules.sentence ?? rules.comma ?? rules.mid ?? .zero,
            sentence: bySentence ? rules.sentence : nil, comma: bySentence ? rules.comma : nil,
            mid: bySentence ? rules.mid : nil, midMinimum: bySentence ? rules.midMinimum : nil,
            cuts: cuts, widened: widened, protected: protected, skipped: planned.skipped, removed: removed, added: added,
            durationBefore: project.duration, durationAfter: project.duration - removed + added,
            commands: commands, applied: nil, warnings: warnings, missing: map.missing
        )
        guard !commands.isEmpty else { return result }
        let apply = ApplyRequest(
            label: request.label ?? tightenLabel(result), author: request.author, commands: commands,
            expectedRevision: revision, dryRun: request.apply != true
        )
        let applied = try self.apply(apply, context: context)
        result.durationAfter = applied.duration
        result.warnings += applied.warnings
        if request.apply == true { result.applied = applied }
        return result
    }

    /// The keeps and minimums a tighten request asks for: one keep for every
    /// pause, or one for each kind of pause (`sentence`, `comma`, `mid`, or
    /// Mike's rules with `mike`, which the others override).
    func pauseRules(for request: TightenRequest) throws -> TranscriptTools.PauseRules {
        func time(_ seconds: Double?) -> Time? { seconds.map { Time(seconds: $0) } }
        guard request.bySentence else {
            if request.midMin != nil {
                throw ServiceError(.badRequest, "`midMin` is for comma and mid-sentence pauses; give `mid` or `comma` (or `mike`) with it.")
            }
            let minimum = Time(seconds: request.min ?? TranscriptTools.defaultMinimum)
            let keep = Time(seconds: request.keep ?? TranscriptTools.defaultKeep)
            guard minimum > .zero else { throw ServiceError(.badRequest, "`min` must be more than 0 seconds.") }
            guard keep >= .zero, keep < minimum else {
                throw ServiceError(.badRequest, "`keep` (\(TimeText.duration(keep))) must be shorter than `min` (\(TimeText.duration(minimum))).")
            }
            return .uniform(keep: keep, minimum: minimum)
        }
        if request.keep != nil {
            throw ServiceError(.badRequest, "`keep` is one keep for every pause. With `sentence`, `comma`, `mid` or `mike`, give each kind its own instead.")
        }
        let preset = request.mike == true ? TranscriptTools.mikeRules : nil
        let rules = TranscriptTools.PauseRules(
            sentence: time(request.sentence) ?? preset?.sentence,
            comma: time(request.comma) ?? preset?.comma,
            mid: time(request.mid) ?? preset?.mid,
            minimum: time(request.min) ?? preset?.minimum ?? Time(seconds: TranscriptTools.defaultSentenceMinimum),
            midMinimum: time(request.midMin) ?? preset?.midMinimum ?? Time(seconds: TranscriptTools.defaultMidMinimum)
        )
        for (name, keep) in [("sentence", rules.sentence), ("comma", rules.comma), ("mid", rules.mid)] {
            if let keep, keep < .zero { throw ServiceError(.badRequest, "`\(name)` can't be less than 0 seconds.") }
        }
        guard rules.minimum > .zero else { throw ServiceError(.badRequest, "`min` must be more than 0 seconds.") }
        guard rules.midMinimum > .zero else { throw ServiceError(.badRequest, "`midMin` must be more than 0 seconds.") }
        return rules
    }

    func tightenLabel(_ result: TightenResult) -> String {
        let cuts = result.pausesCut, widened = result.widened.count
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        guard result.sentence != nil || result.comma != nil || result.mid != nil else {
            return "Tighten \(plural(cuts, "pause")) to \(TimeText.duration(result.keep))"
                + (widened > 0 ? ", widen \(plural(widened, "join"))" : "")
        }
        var parts: [String] = []
        if cuts > 0 { parts.append("Tighten \(plural(cuts, "pause"))") }
        if widened > 0 { parts.append(parts.isEmpty ? "Widen \(plural(widened, "join"))" : "widen \(plural(widened, "join"))") }
        return parts.joined(separator: ", ") + ": " + result.keepsText
    }

    // MARK: - apply

    /// Refuses a call made from a stale read. Media scans since the read
    /// don't count (see `ProjectCoordinator.isCurrent`).
    func checkExpected(_ expected: Int?, at revision: Int) throws {
        if let expected, !coordinator.isCurrent(expected, at: revision) {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
    }

    public func apply(_ request: ApplyRequest, context: CallContext) throws -> ApplyResult {
        guard !request.commands.isEmpty else {
            throw ServiceError(.badRequest, "The batch has no commands.")
        }
        let batch = EditBatch(
            label: request.label ?? CommandText.label(for: request.commands),
            author: request.author ?? context.author,
            commands: request.commands,
            expectedRevision: request.expectedRevision,
            idempotencyKey: request.idempotencyKey
        )
        if request.dryRun == true {
            return try dryRun(batch)
        }
        editLock.lock()
        defer { editLock.unlock() }
        // Keys are kept on disk as well as by the coordinator, so a retry
        // gets the first result whichever process took the first call: the
        // app may quit before the agent hears back, and the retry then
        // reaches the CLI (or the other way round).
        if let key = batch.idempotencyKey, var previous = history.result(forKey: key) {
            previous.repeated = true
            return previous
        }
        let (before, beforeRevision) = coordinator.snapshot()
        let commit: ProjectCoordinator.CommitResult
        do {
            commit = try coordinator.apply(batch)
        } catch {
            throw ServiceError.wrap(error)
        }
        let repeated = commit.revision <= beforeRevision
        let after = coordinator.project
        let diff = repeated ? ClipDiff() : ClipDiff(before, after)
        let result = ApplyResult(
            revision: commit.revision, label: commit.label, author: commit.author,
            createdIDs: commit.createdIDs, warnings: commit.warnings, dryRun: false, repeated: repeated,
            added: diff.added, removed: diff.removed, changed: diff.changed, duration: after.duration
        )
        if !repeated {
            if mode == .headless {
                history.recordEdit(label: batch.label, author: batch.author, before: before, after: after, beforeRevision: beforeRevision, afterRevision: commit.revision)
            }
            if let key = batch.idempotencyKey { history.remember(key: key, result: result) }
        }
        return result
    }

    /// Applies a batch to a copy of the project, the way the coordinator
    /// would, and reports the outcome without committing.
    func dryRun(_ batch: EditBatch) throws -> ApplyResult {
        let (project, revision) = coordinator.snapshot()
        if batch.changesMedia, let expected = batch.expectedRevision, expected != revision {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
        try checkExpected(batch.expectedRevision, at: revision)
        var working = project
        var context = EditContext()
        for (index, command) in batch.commands.enumerated() {
            do {
                try Editing.apply(command, to: &working, context: &context)
            } catch let error as EditError where batch.commands.count > 1 {
                throw ServiceError.wrap(EditError.invalid("command \(index + 1) of \(batch.commands.count): \(error.description)"))
            } catch {
                throw ServiceError.wrap(error)
            }
        }
        let issues = ProjectValidator.validate(working)
        if let first = issues.first(where: { $0.severity == .error }) {
            throw ServiceError(.invalid, "Invalid edit: \(first.message)")
        }
        let diff = ClipDiff(project, working)
        return ApplyResult(
            revision: revision, label: batch.label, author: batch.author,
            createdIDs: context.createdIDs,
            warnings: context.warnings + ProjectValidator.newWarnings(issues, since: project),
            dryRun: true, repeated: false,
            added: diff.added, removed: diff.removed, changed: diff.changed, duration: working.duration
        )
    }

    // MARK: - undo and redo

    public func undo(expectedRevision: Int?, count: Int? = nil) throws -> UndoResult {
        try steps(.undo, expectedRevision: expectedRevision, count: count)
    }

    public func redo(expectedRevision: Int?, count: Int? = nil) throws -> UndoResult {
        try steps(.redo, expectedRevision: expectedRevision, count: count)
    }

    /// Undoes or redoes `count` steps under one lock, so an agent backing
    /// out several of its edits doesn't have to chase the revision each
    /// step makes. Stops early, without failing, when it runs out.
    private func steps(_ kind: ServiceEvent.Kind, expectedRevision: Int?, count: Int?) throws -> UndoResult {
        let count = count ?? 1
        guard count >= 1 else { throw ServiceError(.badRequest, "`count` must be 1 or more.") }
        editLock.lock()
        defer { editLock.unlock() }
        let revision = coordinator.revision
        // Strict, unlike edits: after a media scan the step on top of the
        // stack is the scan, not the edit the caller read.
        if let expected = expectedRevision, expected != revision {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
        var done: [UndoResult] = []
        while done.count < count {
            do {
                done.append(try step(kind))
            } catch let error as ServiceError where !done.isEmpty && (error.code == "nothingToUndo" || error.code == "nothingToRedo") {
                break
            }
        }
        var result = done[done.count - 1]
        result.count = done.count
        result.labels = done.map(\.label)
        result.authors = done.map(\.author)
        return result
    }

    private func step(_ kind: ServiceEvent.Kind) throws -> UndoResult {
        let (current, revision) = coordinator.snapshot()
        let action = kind == .undo ? "undo" : "redo"
        if let result = kind == .undo ? coordinator.undo() : coordinator.redo() {
            // The coordinator labels the step "Undo <label>"; report the edit's own label.
            let prefix = kind == .undo ? "Undo " : "Redo "
            let label = result.label.hasPrefix(prefix) ? String(result.label.dropFirst(prefix.count)) : result.label
            return UndoResult(action: action, revision: result.revision, label: label, author: result.author)
        }
        // Nothing in memory: fall back to the history of headless edits,
        // which is only used while the project hasn't moved on since.
        let entry = kind == .undo ? history.peekUndo(at: revision) : history.peekRedo(at: revision)
        guard let entry else {
            throw kind == .undo
                ? ServiceError(.nothingToUndo, "Nothing to undo.", revision: revision)
                : ServiceError(.nothingToRedo, "Nothing to redo.", revision: revision)
        }
        stateLock.lock()
        pendingRestore = (kind, entry.label, entry.author)
        stateLock.unlock()
        coordinator.reload(entry.project, label: "\(kind == .undo ? "Undo" : "Redo") \(entry.label)", author: entry.author)
        let newRevision = coordinator.revision
        if kind == .undo {
            history.didUndo(at: revision, replaced: current, newRevision: newRevision)
        } else {
            history.didRedo(at: revision, replaced: current, newRevision: newRevision)
            session.review.redid(label: entry.label, author: entry.author, revision: newRevision, before: current, after: entry.project)
        }
        return UndoResult(action: action, revision: newRevision, label: entry.label, author: entry.author)
    }

    // MARK: - history and validate

    public func history(limit: Int) -> HistoryResult {
        let revision = coordinator.revision
        var undo = coordinator.undoSteps(limit: limit).map { HistoryEntry(label: $0.label, author: $0.author, place: EditPlace.between($0.before, $0.after)) }
        var redo = coordinator.redoLabel
        if undo.isEmpty && redo == nil {
            undo = history.undoEntries(at: revision).prefix(limit).map { HistoryEntry(label: $0.label, author: $0.author, place: $0.place) }
            redo = history.peekRedo(at: revision)?.label
        }
        let changes = events.recentChanges().suffix(limit)
        let edits = session.history.records().suffix(limit).reversed().map(HistoryEdit.init)
        return HistoryResult(revision: revision, undo: undo, redo: redo, events: Array(changes), edits: edits.isEmpty ? nil : edits)
    }

    public func validate() -> ValidateResult {
        let (project, revision) = coordinator.snapshot()
        var issues = ProjectValidator.validate(project)
        for item in project.media where !FileManager.default.fileExists(atPath: folder.url(for: item).path) {
            let users = project.allTracks.flatMap(\.clips).filter { $0.mediaID == item.id }.count
            let severity: ValidationIssue.Severity = users > 0 ? .error : .warning
            issues.append(ValidationIssue(severity, "Media file \(item.path) is missing\(users > 0 ? " and \(users) clip(s) use it" : "").", objectID: item.id))
        }
        ProjectFonts.registerNew(in: folder)
        for font in ProjectFonts.missing(in: project) {
            issues.append(ValidationIssue(.warning, font.warning, objectID: font.clipIDs.first))
        }
        return ValidateResult(revision: revision, ok: !issues.contains { $0.severity == .error }, issues: issues)
    }

    // MARK: - frames and renders

    /// Resolves an output path: absolute, `~/`, or relative to the project folder.
    public func outputURL(_ path: String) -> URL {
        folder.url(forPath: path).standardizedFileURL
    }

    /// Refuses to write a render over the project's media or a Tandem
    /// project file (see `RenderOutputs`).
    func checkOutput(_ output: URL, what: String) throws {
        if let reason = RenderOutputs.protectedReason(output, project: coordinator.project, folder: folder) {
            throw ServiceError(.invalid, "\(reason); save the \(what) somewhere else.")
        }
    }

    func renderContext(_ project: Project, format: String?) throws -> RenderContext {
        // "portrait" on a project whose canvas is 9:16 is the canvas.
        let resolved: String?
        do {
            resolved = try OutputFrames.resolve(format, in: project.settings)
        } catch {
            throw ServiceError.wrap(error)
        }
        return RenderContext(project: project, folder: folder, analysis: session.analysis, useProxies: false, format: resolved)
    }

    /// Takes what a frame grab needs from the open project and returns the
    /// slow part, so a headless caller can close the project first.
    public func prepareFrame(_ request: FrameRequest) throws -> @Sendable () async throws -> ImageResult {
        let project = coordinator.project
        guard request.time >= .zero else { throw ServiceError(.badRequest, "The time can't be negative.") }
        let context = try renderContext(project, format: request.format)
        let size = context.renderSize
        var maxSize: CGSize?
        switch (request.maxWidth, request.maxHeight) {
        case let (w?, h?): maxSize = CGSize(width: w, height: h)
        case let (w?, nil): maxSize = CGSize(width: Double(w), height: Double(w) * size.height / max(size.width, 1))
        case let (nil, h?): maxSize = CGSize(width: Double(h) * size.width / max(size.height, 1), height: Double(h))
        case (nil, nil): maxSize = nil
        }
        let output = request.output.map(outputURL)
        if let output { try checkOutput(output, what: "frame") }
        let renderer = self.renderer
        let time = request.time
        let frame = TimeRange(start: time, duration: project.settings.frameRate.frameDuration)
        return { [maxSize] in
            let rendered: RenderedFrame
            do {
                rendered = try await renderer.frame(context: context, at: time, maxSize: maxSize)
            } catch {
                throw ServiceError.wrap(error)
            }
            var result = try Self.deliver(rendered.png, to: output, time: time)
            result.warnings = RenderWarnings.relevant(rendered.warnings, in: project, range: frame)
            return result
        }
    }

    /// The same for a contact sheet: every frame rendered as `frame` would
    /// render it, then laid out on one PNG.
    public func prepareFrames(_ request: FramesRequest) throws -> @Sendable () async throws -> ImageResult {
        let project = coordinator.project
        let times = try Self.sheetTimes(request, duration: project.duration)
        let width = request.width ?? ContactSheet.defaultTileWidth
        guard ContactSheet.tileWidths.contains(width) else {
            throw ServiceError(.badRequest, "Each frame's width is \(ContactSheet.tileWidths.lowerBound) to \(ContactSheet.tileWidths.upperBound) pixels, not \(width).")
        }
        let context = try renderContext(project, format: request.format)
        let layout = ContactSheet.Layout(count: times.count, tileWidth: width, canvas: context.renderSize)
        let maxSize = CGSize(width: layout.tileWidth, height: layout.tileHeight)
        let output = request.output.map(outputURL)
        if let output { try checkOutput(output, what: "contact sheet") }
        let renderer = self.renderer
        let frameDuration = project.settings.frameRate.frameDuration
        return {
            var frames: [(time: Time, png: Data)] = []
            var warnings: [String] = []
            // One at a time: each frame builds a whole composition, and doing
            // several at once only fights over the decoders.
            for time in times {
                let rendered: RenderedFrame
                do {
                    rendered = try await renderer.frame(context: context, at: time, maxSize: maxSize)
                } catch {
                    throw ServiceError.wrap(error)
                }
                frames.append((time, rendered.png))
                for warning in RenderWarnings.relevant(rendered.warnings, in: project, range: TimeRange(start: time, duration: frameDuration)) where !warnings.contains(warning) {
                    warnings.append(warning)
                }
            }
            let sheet = try ContactSheet.compose(frames, layout: layout)
            var result = try Self.deliver(sheet, to: output, time: nil)
            result.times = times
            result.warnings = warnings
            return result
        }
    }

    /// The times a contact sheet shows, in order and once each: the ones
    /// asked for, and one every `every` seconds through the range.
    static func sheetTimes(_ request: FramesRequest, duration: Time) throws -> [Time] {
        var times = request.times ?? []
        if let every = request.every {
            guard every > .zero else { throw ServiceError(.badRequest, "--every needs a positive number of seconds, not \(every.seconds).") }
            let start = request.from ?? .zero
            let end = request.to ?? duration
            guard end >= start else { throw ServiceError(.badRequest, "The range is backwards (\(start) to \(end)).") }
            // An explicit end is shown; the timeline's own end is an empty
            // frame, so it isn't.
            var time = start
            var count = 0
            while time < end || (request.to != nil && time == end) {
                times.append(time)
                count += 1
                // Stops runaway steps (every 0.001 over an hour) before they
                // allocate; the count check below says why.
                if count > ContactSheet.maxTiles * 4 { break }
                time = start + Time(flicks: every.flicks * Int64(count))
            }
        } else if request.from != nil || request.to != nil {
            throw ServiceError(.badRequest, "--from and --to go with --every, like --every 5 --from 1:00 --to 2:00.")
        }
        guard !times.isEmpty else {
            if request.every != nil { throw ServiceError(.badRequest, "There are no frames between \(request.from ?? .zero) and \(request.to ?? duration).") }
            throw ServiceError(.badRequest, "Give some times, or --every <seconds> (with --from and --to for part of the timeline).")
        }
        if let negative = times.first(where: { $0 < .zero }) {
            throw ServiceError(.badRequest, "The time can't be negative (\(negative)).")
        }
        let unique = Array(Set(times)).sorted()
        guard unique.count <= ContactSheet.maxTiles else {
            let shown = unique.count > ContactSheet.maxTiles * 4 ? "More than \(ContactSheet.maxTiles * 4)" : "\(unique.count)"
            throw ServiceError(.badRequest, "That's \(shown) frames; a sheet takes at most \(ContactSheet.maxTiles). Use a bigger --every, a shorter range or fewer times, or make more than one sheet.")
        }
        return unique
    }

    public func screenshot(output: String?) async throws -> ImageResult {
        guard let provider = screenshotProvider else {
            throw ServiceError(.unavailable, "Screenshots capture the Tandem app's window, so they need the app open. Use `frame` for a rendered frame.")
        }
        let output = output.map(outputURL)
        if let output { try checkOutput(output, what: "screenshot") }
        let data = try await provider()
        return try Self.deliver(data, to: output, time: nil)
    }

    static func deliver(_ data: Data, to output: URL?, time: Time?) throws -> ImageResult {
        guard let output else {
            return ImageResult(time: time, path: nil, png: data.base64EncodedString(), bytes: data.count)
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        return ImageResult(time: time, path: output.path, png: nil, bytes: data.count)
    }

    public func prepareClip(_ request: ClipRequest) throws -> @Sendable () async throws -> ExportOutcome {
        guard request.end > request.start else {
            throw ServiceError(.badRequest, "The clip's end (\(request.end)) must be after its start (\(request.start)).")
        }
        guard request.start >= .zero else { throw ServiceError(.badRequest, "The clip can't start before 0.") }
        var preset = try preset(named: request.preset) ?? .review
        preset.range = TimeRange(start: request.start, end: request.end)
        var project = coordinator.project
        var soloed: [String]?
        if let names = request.tracks, !names.isEmpty {
            let tracks = try audioTracks(named: names, in: project)
            project = AudioLevels.soloing(project, audioTrackIDs: Set(tracks.map(\.id)))
            // Mastering a stem on its own would bring it up to the target
            // and hide how it sits in the mix.
            preset.loudnessTarget = nil
            preset.truePeakCeiling = nil
            soloed = tracks.map(\.name)
        }
        let given = request.output.map(outputURL)
        if request.audioOnly == true, let given, !ExportOutcome.soundExtensions.contains(given.pathExtension.lowercased()) {
            throw ServiceError(.badRequest, "Sound alone goes in a .m4a or .wav file, not \(given.lastPathComponent).")
        }
        let name = "review \(TimeText.fileSafe(request.start))-\(TimeText.fileSafe(request.end))" + (soloed.map { " " + $0.joined(separator: "+") } ?? "")
        let output = given ?? folder.exportsFolder.appendingPathComponent(name + (request.audioOnly == true ? ".m4a" : ".mp4"))
        return try prepareRender(plan: try exportPlan(preset, format: nil), output: output, project: project, tracks: soloed)
    }

    public func prepareExport(_ request: ExportRequest) throws -> @Sendable () async throws -> ExportOutcome {
        let project = coordinator.project
        // Without a preset the frame decides: 1080p for 1080x1920, 4K for
        // a 4K canvas.
        var preset = try preset(named: request.preset) ?? .standard(for: project.settings, format: request.format)
        if request.from != nil || request.to != nil {
            let start = request.from ?? .zero
            let end = request.to ?? project.duration
            guard end > start else { throw ServiceError(.badRequest, "The export range is empty (\(start) to \(end)).") }
            preset.range = TimeRange(start: start, end: end)
        }
        let plan = try exportPlan(preset, format: request.format)
        let output: URL
        if let path = request.output {
            output = outputURL(path)
        } else {
            let (project, revision) = coordinator.snapshot()
            output = uniqueURL(folder.exportsFolder.appendingPathComponent("\(project.name) r\(revision).mp4"))
        }
        return try prepareRender(plan: plan, output: output)
    }

    /// A preset by name, or nil for none.
    func preset(named name: String?) throws -> ExportPreset? {
        guard let name else { return nil }
        guard let preset = PresetNames.find(name) else {
            let known = ExportPreset.all.map(\.cliName).joined(separator: ", ")
            throw ServiceError(.notFound, "No export preset \"\(name)\". Presets: \(known).")
        }
        return preset
    }

    /// What the preset renders for the open project: the same plan the
    /// app's Export dialog shows.
    func exportPlan(_ preset: ExportPreset, format: String?) throws -> ExportPlan {
        do {
            return try preset.plan(for: coordinator.project.settings, format: format)
        } catch {
            throw ServiceError.wrap(error)
        }
    }

    func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }

    private func prepareRender(plan: ExportPlan, output: URL, project: Project? = nil, tracks: [String]? = nil) throws -> @Sendable () async throws -> ExportOutcome {
        // The exporter refuses these too; this says so before anything starts.
        try checkOutput(output, what: "export")
        let project = project ?? coordinator.project
        let context = try renderContext(project, format: plan.format)
        let preset = plan.preset
        let renderer = self.renderer
        let id = IDs.make("exp")
        let path = output.path
        return { [weak self] in
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            self?.track(ExportJob(id: id, output: path, preset: preset.name))
            let reporter = ProgressReporter { progress in
                self?.track(ExportJob(id: id, output: path, preset: preset.name, progress: progress))
            }
            do {
                let rendered = try await renderer.export(context: context, preset: preset, output: output) { reporter.report($0) }
                self?.finish(ExportJob(id: id, output: path, preset: preset.name, progress: 1, state: .done))
                let result = rendered.result
                var outcome = ExportOutcome(
                    path: result.path, preset: preset.name, duration: result.duration,
                    integratedLUFS: result.integratedLUFS, truePeakDBTP: result.truePeakDBTP, elapsed: result.elapsed,
                    warnings: RenderWarnings.relevant(plan.warnings + rendered.warnings, in: project, range: preset.range)
                )
                if !outcome.soundOnly {
                    outcome.width = plan.width
                    outcome.height = plan.height
                    outcome.codec = plan.codec
                    outcome.videoBitrate = plan.videoBitrate
                }
                outcome.tracks = tracks
                outcome.audioBitrate = preset.audioBitrate
                outcome.format = plan.format
                outcome.loudnessTarget = preset.loudnessTarget
                outcome.truePeakCeiling = preset.truePeakCeiling
                return outcome
            } catch {
                let wrapped = ServiceError.wrap(error)
                self?.finish(ExportJob(id: id, output: path, preset: preset.name, state: .failed, message: wrapped.message))
                throw wrapped
            }
        }
    }

    private func track(_ job: ExportJob) {
        stateLock.lock()
        exports[job.id] = job
        stateLock.unlock()
        events.publish { ServiceEvent(seq: $0, kind: .export, export: job) }
    }

    /// Exports and review clips rendering through this service now.
    var runningExports: [ExportJob] {
        stateLock.withLock { exports.values.sorted { $0.id < $1.id } }
    }

    private func finish(_ job: ExportJob) {
        stateLock.lock()
        exports.removeValue(forKey: job.id)
        stateLock.unlock()
        events.publish { ServiceEvent(seq: $0, kind: .export, export: job) }
    }

    // MARK: - loudness

    public func loudness(mediaID: String?) throws -> LoudnessResult {
        let project = coordinator.project
        var items = project.media.filter(\.hasAudio)
        if let mediaID {
            guard let item = project.media(mediaID) else { throw ServiceError(.notFound, "No media with ID \(mediaID).") }
            items = [item]
        }
        let jobs = analysis.jobs
        var measured: [String: Loudness] = [:]
        let media = items.map { item -> MediaLoudness in
            let loudness = analysis.loudness(for: item)
            measured[item.id] = loudness
            let state = loudness != nil ? "ready" : (jobs.last { $0.mediaID == item.id && $0.kind == .loudness }?.state.rawValue ?? "none")
            return MediaLoudness(
                mediaID: item.id, path: item.path, integratedLUFS: loudness?.integratedLUFS,
                truePeakDBTP: loudness?.truePeakDBTP, loudnessRange: loudness?.loudnessRange, state: state
            )
        }
        let wanted = Set(items.map(\.id))
        var clips: [ClipLevel] = []
        for track in project.audioTracks {
            for clip in track.clips {
                guard let id = clip.mediaID, wanted.contains(id) else { continue }
                let audio = clip.audio ?? AudioProperties()
                // The same sum the render makes, so this is what plays.
                let normalizeGain = audio.normalizeTo.flatMap {
                    AudioLevels.normalizeGainDB(target: $0, measuredLUFS: measured[id]?.integratedLUFS)
                }
                let peak = measured[id].flatMap { loudness in
                    AudioLevels.levelledPeak(audio, measured: MeasuredSound(integratedLUFS: loudness.integratedLUFS, truePeakDBTP: loudness.truePeakDBTP))
                }
                let ceiling = audio.effects.filter { $0.type == "limiter" && $0.enabled }.compactMap { limiter in
                    EffectRegistry.standard.definition("limiter")?.resolvedParams(limiter)["ceiling"]?.number
                }.min()
                clips.append(ClipLevel(
                    clipID: clip.id, mediaID: id, track: track.name, gainDB: audio.gainDB,
                    normalizeTo: audio.normalizeTo, normalizeGainDB: normalizeGain,
                    speech: AudioLevels.isSpeech(clip, on: track, in: project),
                    peakDBTP: peak, limiterCeiling: ceiling, muted: track.muted || audio.muted
                ))
            }
        }
        return LoudnessResult(
            target: project.settings.loudnessTarget, truePeakCeiling: project.settings.truePeakCeiling,
            speechLoudness: project.settings.speechLoudness, media: media, clips: clips
        )
    }

    // MARK: - watch

    /// Waits until the project moves past `after` (default: now) or the
    /// timeout passes.
    public func watch(after: Int?, timeout: Double) async -> WatchResult {
        let start = after ?? coordinator.revision
        let limit = min(max(timeout, 0), 600)
        let coordinator = self.coordinator
        _ = await events.next(timeout: limit, unless: { coordinator.revision > start }) {
            $0.isChange && ($0.revision ?? 0) > start
        }
        let revision = coordinator.revision
        let changes = events.recentChanges().filter { ($0.revision ?? 0) > start }
        return WatchResult(revision: revision, changed: revision > start, events: changes, jobs: analysis.jobs)
    }
}

/// Throttles progress callbacks to about one per percent.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let handler: (Double) -> Void

    init(_ handler: @escaping (Double) -> Void) {
        self.handler = handler
    }

    func report(_ progress: Double) {
        lock.lock()
        let due = progress >= 1 || progress - last >= 0.01
        if due { last = progress }
        lock.unlock()
        if due { handler(progress) }
    }
}

/// Which clips a batch added, removed or changed.
struct ClipDiff {
    var added: [String] = []
    var removed: [String] = []
    var changed: [String] = []

    init() {}

    init(_ before: Project, _ after: Project) {
        let old = Dictionary(before.allTracks.flatMap { track in track.clips.map { ($0.id, ($0, track.id)) } }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(after.allTracks.flatMap { track in track.clips.map { ($0.id, ($0, track.id)) } }, uniquingKeysWith: { a, _ in a })
        for track in after.allTracks {
            for clip in track.clips {
                if let (previous, previousTrack) = old[clip.id] {
                    if previous != clip || previousTrack != track.id { changed.append(clip.id) }
                } else {
                    added.append(clip.id)
                }
            }
        }
        for track in before.allTracks {
            for clip in track.clips where new[clip.id] == nil { removed.append(clip.id) }
        }
    }
}
