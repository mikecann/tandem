import Foundation
import TandemCore
import TandemRender

/// `tandem check`: looks for what Mike would otherwise catch in review
/// (`QualityCheck`), so an agent can fix it before handing an edit back.
public struct CheckRequest: ServiceCall {
    public static let operation = ServiceOperation.check
    public var from: Time?
    public var to: Time?
    /// Only the stretches agents changed that wait for Mike's review.
    public var changed: Bool?
    /// Only the checks that need no rendering: gaps and soft pictures.
    public var quick: Bool?
    /// How wide frames are rendered for the scan. Default 384.
    public var width: Int?

    public init(from: Time? = nil, to: Time? = nil, changed: Bool? = nil, quick: Bool? = nil, width: Int? = nil) {
        self.from = from
        self.to = to
        self.changed = changed
        self.quick = quick
        self.width = width
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        changed = try c.decodeIfPresent(Bool.self, forKey: .changed)
        quick = try c.decodeIfPresent(Bool.self, forKey: .quick)
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
    /// What's wrong: black frames, gaps, flickers, keys that didn't happen.
    public var problems: [CheckProblem]
    /// Worth knowing but not wrong: pictures zoomed past their own pixels,
    /// dead air, and page changes with no transition.
    public var notes: [CheckProblem]
    /// Names for the clips the problems mention.
    public var clipNames: [String: String]
    /// Why nothing was checked, when nothing was.
    public var note: String?
    public var warnings: [String]

    public var ok: Bool { problems.isEmpty }

    enum CodingKeys: String, CodingKey {
        case ranges, frames, seconds, problems, notes, clipNames, note, warnings, ok
    }

    public init(ranges: [TimeRange], frames: Int, seconds: Double, problems: [CheckProblem], notes: [CheckProblem] = [], clipNames: [String: String], note: String? = nil, warnings: [String] = []) {
        self.ranges = ranges
        self.frames = frames
        self.seconds = seconds
        self.problems = problems
        self.notes = notes
        self.clipNames = clipNames
        self.note = note
        self.warnings = warnings
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
        try c.encode(ok, forKey: .ok)
    }
}

extension CheckResult: ReadableResult {
    /// "Checked 05:40.000-06:20.000 (1200 frames) in 8.2 s: 2 problems:"
    /// and a line a problem, with the clips it's on.
    public var readableText: String {
        if ranges.isEmpty { return note ?? "Nothing to check." }
        let stretches = ranges.map { "\($0.start)-\($0.end)" }.joined(separator: ", ")
        let scanned = frames > 0 ? "\(frames) frames" : "quick: no frames rendered"
        let verdict = problems.isEmpty ? "no problems." : "\(problems.count) problem\(problems.count == 1 ? "" : "s"):"
        var lines = ["Checked \(stretches) (\(scanned)) in \(String(format: "%.1f", seconds)) s: \(verdict)"]
        func line(_ problem: CheckProblem) -> String {
            var line = "  \(problem.start)-\(problem.end)  \(problem.message)"
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
        lines += warnings.map { "Warning: \($0)" }
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
        let notices = warnings
        return {
            let started = Date()
            var frames: [FrameStats]?
            var screenFrames: [FrameStats]?
            if scans {
                do {
                    // Side by side: the screen recording on its own reads far
                    // less than the composite (no camera, no mattes), so it's
                    // done first and adds little to the wait.
                    async let composite = renderer.scan(context: context, ranges: toCheck, width: width, scanlines: false)
                    if let screenScan {
                        screenFrames = try await renderer.scan(context: screenScan, ranges: screenStretches, width: width, scanlines: true)
                    }
                    frames = try await composite
                } catch {
                    throw ServiceError.wrap(error)
                }
            }
            let found = QualityCheck.problems(in: project, ranges: toCheck, frames: frames, screenFrames: screenFrames, speech: speech)
            var names: [String: String] = [:]
            for id in Set(found.flatMap(\.clipIDs)) {
                guard let clip = project.clip(id) else { continue }
                names[id] = Self.checkName(clip, in: project)
            }
            return CheckResult(
                ranges: toCheck, frames: frames?.count ?? 0, seconds: Date().timeIntervalSince(started),
                problems: found.filter { !$0.kind.isNote }, notes: found.filter(\.kind.isNote), clipNames: names, note: why,
                warnings: notices
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
