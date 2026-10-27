import Foundation
import TandemCore
import TandemMedia
import TandemRender

/// `tandem check`: looks for what Mike would otherwise catch in review
/// (`QualityCheck`), so an agent can fix it before handing an edit back.
public struct CheckRequest: ServiceCall {
    public static let operation = ServiceOperation.check
    public var from: Time?
    public var to: Time?
    /// Only the stretches agents changed that wait for Mike's review.
    public var changed: Bool?
    /// Only the checks that need no rendering: gaps, soft pictures, slivers
    /// and double jumps.
    public var quick: Bool?
    /// Only the cuts on the speech tracks: does the voice run right up to
    /// one (a clipped word)? Reads the files' sound, renders nothing.
    public var cuts: Bool?
    /// With `cuts`: also render the voice across each join, transcribe it
    /// and compare what's heard with the take's words (`CutListen`).
    public var listen: Bool?
    /// How wide frames are rendered for the scan. Default 384.
    public var width: Int?

    public init(from: Time? = nil, to: Time? = nil, changed: Bool? = nil, quick: Bool? = nil, cuts: Bool? = nil, listen: Bool? = nil, width: Int? = nil) {
        self.from = from
        self.to = to
        self.changed = changed
        self.quick = quick
        self.cuts = cuts
        self.listen = listen
        self.width = width
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        changed = try c.decodeIfPresent(Bool.self, forKey: .changed)
        quick = try c.decodeIfPresent(Bool.self, forKey: .quick)
        cuts = try c.decodeIfPresent(Bool.self, forKey: .cuts)
        listen = try c.decodeIfPresent(Bool.self, forKey: .listen)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> CheckResult {
        try await service.withPresetFonts(try service.prepareCheck(self))()
    }
}

extension CheckRequest: DeferredServiceCall {
    public func prepare(on service: TandemService, context: CallContext) throws -> @Sendable () async throws -> CheckResult {
        service.withPresetFonts(try service.prepareCheck(self))
    }
}

public struct CheckResult: Codable, Sendable {
    /// The stretches checked.
    public var ranges: [TimeRange]
    /// Frames rendered and measured: none for a quick check.
    public var frames: Int
    public var seconds: Double
    /// What's wrong: black frames, gaps, flickers, keys that didn't happen,
    /// double jumps.
    public var problems: [CheckProblem]
    /// Worth knowing but not wrong: pictures zoomed past their own pixels,
    /// clips and gaps shorter than a frame, dead air, page changes with no
    /// transition, and screen recordings at a low frame rate where they move.
    public var notes: [CheckProblem]
    /// Names for the clips the problems mention.
    public var clipNames: [String: String]
    /// Why nothing was checked, when nothing was.
    public var note: String?
    public var warnings: [String]
    /// With `cuts`: how many cut edges on the speech tracks were checked.
    public var cuts: Int?
    /// The edits that fix what the check can fix: with `cuts`, the trims
    /// that move each clipped edge into its pause, latest first; otherwise
    /// the `updateClip` that runs each double jump's shot out to its cut,
    /// then a `holdFrame` for each flicker it can tell the picture of,
    /// latest first. Pass them to `apply` with `revision`.
    public var commands: [EditCommand]
    /// The revision the check read, for `commands`.
    public var revision: Int?
    /// With `listen`: what was heard across each join.
    public var listened: ListenSummary?

    public var ok: Bool { problems.isEmpty }

    enum CodingKeys: String, CodingKey {
        case ranges, frames, seconds, problems, notes, clipNames, note, warnings, cuts, commands, revision, listened, ok
    }

    public init(
        ranges: [TimeRange], frames: Int, seconds: Double, problems: [CheckProblem], notes: [CheckProblem] = [], clipNames: [String: String],
        note: String? = nil, warnings: [String] = [], cuts: Int? = nil, commands: [EditCommand] = [], revision: Int? = nil,
        listened: ListenSummary? = nil
    ) {
        self.ranges = ranges
        self.frames = frames
        self.seconds = seconds
        self.problems = problems
        self.notes = notes
        self.clipNames = clipNames
        self.note = note
        self.warnings = warnings
        self.cuts = cuts
        self.commands = commands
        self.revision = revision
        self.listened = listened
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ranges = try c.decode([TimeRange].self, forKey: .ranges)
        frames = try c.decode(Int.self, forKey: .frames)
        seconds = try c.decode(Double.self, forKey: .seconds)
        problems = try c.decode([CheckProblem].self, forKey: .problems)
        notes = try c.decodeIfPresent([CheckProblem].self, forKey: .notes) ?? []
        clipNames = try c.decodeIfPresent([String: String].self, forKey: .clipNames) ?? [:]
        note = try c.decodeIfPresent(String.self, forKey: .note)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        cuts = try c.decodeIfPresent(Int.self, forKey: .cuts)
        commands = try c.decodeIfPresent([EditCommand].self, forKey: .commands) ?? []
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        listened = try c.decodeIfPresent(ListenSummary.self, forKey: .listened)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ranges, forKey: .ranges)
        try c.encode(frames, forKey: .frames)
        try c.encode(seconds, forKey: .seconds)
        try c.encode(problems, forKey: .problems)
        try c.encode(notes, forKey: .notes)
        try c.encode(clipNames, forKey: .clipNames)
        try c.encodeIfPresent(note, forKey: .note)
        if !warnings.isEmpty { try c.encode(warnings, forKey: .warnings) }
        try c.encodeIfPresent(cuts, forKey: .cuts)
        if cuts != nil || !commands.isEmpty { try c.encode(commands, forKey: .commands) }
        try c.encodeIfPresent(revision, forKey: .revision)
        try c.encodeIfPresent(listened, forKey: .listened)
        try c.encode(ok, forKey: .ok)
    }
}

extension CheckResult: ReadableResult {
    /// "Checked 05:40.000-06:20.000 (1200 frames) in 8.2 s: 2 problems:"
    /// and a line a problem, with the clips it's on.
    public var readableText: String {
        if ranges.isEmpty { return note ?? "Nothing to check." }
        let stretches = ranges.map { "\($0.start)-\($0.end)" }.joined(separator: ", ")
        let scanned = cuts.map { "\($0) cut edge\($0 == 1 ? "" : "s")" } ?? (frames > 0 ? "\(frames) frames" : "quick: no frames rendered")
        let verdict = problems.isEmpty ? "no problems." : "\(problems.count) problem\(problems.count == 1 ? "" : "s"):"
        var lines = ["Checked \(stretches) (\(scanned)) in \(String(format: "%.1f", seconds)) s: \(verdict)"]
        func line(_ problem: CheckProblem) -> String {
            let when = problem.start == problem.end ? "\(problem.start)" : "\(problem.start)-\(problem.end)"
            var line = "  \(when)  \(problem.message)"
            if !problem.clipIDs.isEmpty {
                let clips = problem.clipIDs.prefix(3).map { id in clipNames[id].map { "\(id) \($0)" } ?? id }
                line += "  On: " + clips.joined(separator: ", ")
            }
            return line
        }
        lines += problems.map(line)
        if !notes.isEmpty {
            lines.append("Notes (not problems):")
            lines += notes.map(line)
        }
        if let listened {
            // Every join's words, so an agent can read each one as the Ian
            // session did: what reads wrong there is worth a listen too.
            let timing = listened.secondsPerJoin.map { String(format: ", %.1f s a join", $0) } ?? ""
            lines.append("Heard across \(listened.joins.count) join\(listened.joins.count == 1 ? "" : "s") with \(listened.engine) (\(listened.heard) heard\(timing), \(listened.cached) unchanged since the last check):")
            for join in listened.joins {
                let mark = join.skipped.map { "  not compared: \($0)" } ?? (join.clipped ? "  cut off" : join.findings.isEmpty ? "" : "  differs")
                lines.append("  \(join.time)\(mark)")
                lines.append("    take:  \(join.said)")
                lines.append("    heard: \(join.heard)")
            }
        }
        lines += warnings.map { "Warning: \($0)" }
        if !commands.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let batch = (try? encoder.encode(commands)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            let expect = revision.map { " --expect \($0)" } ?? ""
            let label = cuts == nil ? QualityCheck.fixLabel(for: problems) : CutCheck.label
            lines.append("Fix: tandem apply\(expect) --label \"\(label)\" '\(batch)'")
        }
        return lines.joined(separator: "\n")
    }
}

extension TandemService {
    /// A check reaches this far past each changed stretch, to see the cuts
    /// into and out of it.
    static let checkMargin = Time(seconds: 0.5)

    /// Works out what to check from the open project and returns the slow
    /// part (rendering the frames), so a headless caller can close the
    /// project first.
    public func prepareCheck(_ request: CheckRequest) throws -> @Sendable () async throws -> CheckResult {
        let project = coordinator.project
        let timeline = TimeRange(start: .zero, end: project.duration)
        var ranges: [TimeRange] = []
        var note: String?
        if request.changed == true {
            if request.from != nil || request.to != nil {
                throw ServiceError(.badRequest, "Check what changed, or a stretch with from and to, not both.")
            }
            ranges = session.review.log.changedRegions(in: project).compactMap { region in
                TimeRange(start: region.start - Self.checkMargin, end: region.end + Self.checkMargin).intersection(timeline)
            }
            if ranges.isEmpty { note = "Nothing is waiting for Mike's review, so there was nothing to check." }
        } else {
            let start = request.from ?? .zero
            let end = min(request.to ?? project.duration, project.duration)
            guard start >= .zero else { throw ServiceError(.badRequest, "from can't be negative.") }
            guard end > start else { throw ServiceError(.badRequest, "Nothing to check between \(start) and \(end): the timeline is \(project.duration) long.") }
            ranges = [TimeRange(start: start, end: end)]
        }
        ranges = QualityCheck.merge(ranges)
        if request.cuts == true || request.listen == true {
            if request.quick == true { throw ServiceError(.badRequest, "A cuts check renders nothing already, so it doesn't take quick.") }
            let folder = self.folder
            let revision = coordinator.revision
            let toCheck = ranges
            let why = note
            let words = toCheck.isEmpty ? [:] : CutCheck.words(in: project, analysis: analysis)
            let listens = request.listen == true && !toCheck.isEmpty
            let said = listens ? CutCheck.said(in: project, analysis: analysis) : CutCheck.Said()
            let playsSpeech = !CutCheck.playedSpeechTracks(project).isEmpty
            let listening = cutListening
            let mediaAnalysis = session.analysis
            return {
                let started = Date()
                var outcome = toCheck.isEmpty ? CutCheck.Outcome() : await CutCheck.run(project: project, folder: folder, ranges: toCheck, words: words)
                var listened: ListenSummary?
                if listens, !playsSpeech {
                    outcome.warnings.append("Nothing was listened to: a soloed track that isn't speech plays alone, so export plays no voice.")
                } else if listens {
                    var mix = listening?.mix
                    if mix == nil {
                        do {
                            mix = try await CutCheck.Mix.speech(project, folder: folder, analysis: mediaAnalysis)
                        } catch {
                            outcome.warnings.append("Couldn't render the voice to listen to it: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                        }
                    }
                    let ears = listening?.ears ?? CutCheck.Ear.standard()
                    if let mix, !ears.isEmpty {
                        let heard = await CutCheck.listen(
                            project: project, edges: CutCheck.edges(in: project, ranges: toCheck), said: said, words: words, mix: mix, ears: ears,
                            cache: CutListenCache(project: folder)
                        )
                        listened = heard.summary
                        outcome.warnings += heard.warnings
                        // What's heard confirms or dismisses what the levels
                        // and the transcript's rules flagged (`CutEvidence`).
                        let combined = CutCheck.combine(problems: outcome.problems, notes: outcome.notes, summary: heard.summary)
                        outcome.problems = combined.problems
                        outcome.notes = combined.notes
                        outcome.commands = combined.commands
                        listened?.joins = combined.joins
                    } else if mix != nil {
                        outcome.warnings.append("Nothing to listen with: \(BarkListener.engine) isn't downloaded, and SpeechAnalyzer needs macOS 26.")
                    }
                }
                var names: [String: String] = [:]
                for id in Set((outcome.problems + outcome.notes).flatMap(\.clipIDs)) {
                    guard let clip = project.clip(id) else { continue }
                    names[id] = Self.checkName(clip, in: project)
                }
                return CheckResult(
                    ranges: toCheck, frames: 0, seconds: Date().timeIntervalSince(started), problems: outcome.problems, notes: outcome.notes,
                    clipNames: names, note: why, warnings: outcome.warnings, cuts: outcome.checked, commands: outcome.commands, revision: revision,
                    listened: listened
                )
            }
        }
        let width = request.width ?? 384
        guard (64...1920).contains(width) else { throw ServiceError(.badRequest, "width is 64 to 1920 pixels.") }
        // Proxies where they're ready: the check looks for what's wrong in
        // the edit, which they show the same, and they read far faster.
        let context = RenderContext(project: project, folder: folder, analysis: session.analysis, useProxies: true)
        let renderer = self.renderer
        let scans = request.quick != true && !ranges.isEmpty
        let toCheck = ranges
        let why = note
        let (speech, untranscribed) = Self.checkSpeech(project, analysis: analysis)
        var warnings: [String] = []
        if scans, !untranscribed.isEmpty {
            let names = untranscribed.compactMap { project.media($0).map { URL(fileURLWithPath: $0.path).lastPathComponent } }
            warnings.append("No transcript yet for \(names.joined(separator: ", ")), so dead air isn't checked where it plays.")
        }
        // Page changes are judged from the screen recordings on their own,
        // scanned beside the composite.
        var screenContext: RenderContext?
        var screenRanges: [TimeRange] = []
        if scans, let screens = QualityCheck.screenOnly(project) {
            screenRanges = QualityCheck.screenRanges(in: project, within: toCheck)
            if !screenRanges.isEmpty {
                screenContext = context
                screenContext?.project = screens
            }
        }
        let screenScan = screenContext
        let screenStretches = screenRanges
        // The screen recordings that play there, whose own frame times say
        // where they drop to a low frame rate.
        let recordings = screenScan == nil ? [] : project.media.filter { item in
            item.role == .screen && item.hasVideo && project.videoTracks.contains { track in
                !track.hidden && track.clips.contains { $0.enabled && $0.mediaID == item.id && screenStretches.contains(where: $0.range.overlaps) }
            }
        }
        let projectFolder = folder
        let cache = CheckCache(folder: folder)
        let analysis = self.analysis
        let notices = warnings
        let revision = coordinator.revision
        return {
            let started = Date()
            var frames: [FrameStats]?
            var screenFrames: [FrameStats]?
            var frameTimes: [String: [Time]] = [:]
            for item in recordings {
                frameTimes[item.id] = await FrameTimes.read(item, in: projectFolder)
            }
            if scans {
                do {
                    // Side by side: the screen recording on its own reads far
                    // less than the composite (no camera, no mattes), so it's
                    // done first and adds little to the wait.
                    // Each from the cache where nothing in a piece has
                    // changed since the last check (`CheckCache`).
                    async let composite = cache.scan(project: project, analysis: analysis, ranges: toCheck, width: width, scanlines: false) { ranges in
                        try await renderer.scan(context: context, ranges: ranges, width: width, scanlines: false)
                    }
                    if let screenScan {
                        screenFrames = try await cache.scan(project: screenScan.project, analysis: analysis, ranges: screenStretches, width: width, scanlines: true) { ranges in
                            try await renderer.scan(context: screenScan, ranges: ranges, width: width, scanlines: true)
                        }
                    }
                    frames = try await composite
                } catch {
                    throw ServiceError.wrap(error)
                }
            }
            let found = QualityCheck.problems(in: project, ranges: toCheck, frames: frames, screenFrames: screenFrames, speech: speech, frameTimes: frameTimes)
            var names: [String: String] = [:]
            for id in Set(found.flatMap(\.clipIDs)) {
                guard let clip = project.clip(id) else { continue }
                names[id] = Self.checkName(clip, in: project)
            }
            // The double jumps' patches first, then holds latest first, so
            // a hold that cuts a clip never takes the ID off the piece an
            // earlier hold names (`QualityCheck.commands(fixing:)`).
            let fixes = QualityCheck.commands(fixing: found)
            return CheckResult(
                ranges: toCheck, frames: frames?.count ?? 0, seconds: Date().timeIntervalSince(started),
                problems: found.filter { !$0.kind.isNote }, notes: found.filter(\.kind.isNote), clipNames: names, note: why,
                warnings: notices, commands: fixes, revision: fixes.isEmpty ? nil : revision
            )
        }
    }

    /// What the check hears said, for dead air: the words `tandem pauses`
    /// reads (edges on the voice), and the voice clips they come from. A
    /// sound effect on a voice track isn't a voice, so it counts as sound
    /// for as long as it plays, as does a voice whose transcript isn't
    /// ready. Also returns the voices' media with no transcript yet.
    static func checkSpeech(_ project: Project, analysis: AnalysisSource) -> (speech: QualityCheck.Speech, untranscribed: [String]) {
        let map = TranscriptTools.speechMap(project, analysis: analysis)
        let missing = Set(map.missing)
        func isVoice(_ mediaID: String?) -> Bool {
            guard let mediaID, let item = project.media(mediaID) else { return false }
            return item.role != .sfx && item.role != .music
        }
        let voices = Set(map.clips.filter { isVoice($0.mediaID) && !missing.contains($0.mediaID ?? "") }.map(\.id))
        let words = map.words.filter { voices.contains($0.clipID) }.map {
            QualityCheck.Speech.Word(text: $0.text, start: $0.start, end: $0.end)
        }
        return (QualityCheck.Speech(words: words, clipIDs: voices), map.missing.filter(isVoice))
    }

    /// What a problem's clip is called in the check's words.
    static func checkName(_ clip: Clip, in project: Project) -> String {
        if let name = clip.name, !name.isEmpty { return name }
        switch clip.content {
        case .media(let id): return project.media(id).map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? id
        case .text(let text): return "title \"\(text.text.prefix(30))\""
        case .graphic(let graphic): return graphic.template == SectionCard.template ? "section card" : "graphic \(graphic.template)"
        case .solid: return "solid"
        case .adjustment: return "adjustment layer"
        }
    }
}
