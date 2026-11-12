import Foundation
import TandemCore
import TandemMedia

// MARK: - cut

/// `tandem cut`: takes words out of the take with both edges of each cut in
/// a real pause, so nothing that stays is clipped.
///
/// Agents used to cut a phrase by sending `rippleDeleteRange` or
/// `cutRanges` at the times `tandem search` gave, and those are 30 to
/// 200 ms off the sound, so Mike kept hearing words chopped (#64). This
/// plans each cut from the voice's own sound with `CutPlacer`, the same
/// pause map `tandem check --cuts` judges joins with: the transcript only
/// says roughly where the words are and which ones stay. A stretch with no
/// pause round it (a filler in running speech) is left in and said why,
/// unless it's a long false start. Then it's one `cutRanges`, so the whole
/// take (camera, screen and voice) loses the same time, and one undo step.
public struct CutRequest: ServiceCall {
    public static let operation = ServiceOperation.cut
    /// What to take out: phrases and timeline ranges, in any order.
    public var remove: [CutTarget]
    /// Also take out every filler the transcript has ("um", "uh" and the
    /// rest of `TranscriptTools.fillers`) between `from` and `to`.
    public var fillers: Bool?
    public var from: Time?
    public var to: Time?
    /// Leave in a filler with any of these times in it or in the pauses
    /// either side of it, as tighten's protect leaves a pause alone.
    public var protect: [Time]?
    /// Cut every stretch asked for as a long false start: pause to pause
    /// even when that brings a word of it back. A stretch's own
    /// `falseStart` wins. Without either, stretches over 2 s are false
    /// starts. Fillers on their own never are.
    public var falseStart: Bool?
    /// Make the cut. Without it this is a dry run that returns the plan.
    public var apply: Bool?
    public var label: String?
    public var author: String?
    /// Refuse to apply if the project isn't at this revision.
    public var expectedRevision: Int?

    public init(
        remove: [CutTarget], fillers: Bool? = nil, from: Time? = nil, to: Time? = nil, protect: [Time]? = nil,
        falseStart: Bool? = nil, apply: Bool? = nil,
        label: String? = nil, author: String? = nil, expectedRevision: Int? = nil
    ) {
        self.remove = remove
        self.fillers = fillers
        self.from = from
        self.to = to
        self.protect = protect
        self.falseStart = falseStart
        self.apply = apply
        self.label = label
        self.author = author
        self.expectedRevision = expectedRevision
    }

    // `remove` can be left out when it's only fillers.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remove = try c.decodeIfPresent([CutTarget].self, forKey: .remove) ?? []
        fillers = try c.decodeIfPresent(Bool.self, forKey: .fillers)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        protect = try c.decodeTimes(.protect)
        falseStart = try c.decodeIfPresent(Bool.self, forKey: .falseStart)
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> CutResult {
        try await service.cut(self, context: context)
    }
}

/// One stretch to take out: a phrase, found as `search` finds it, or a
/// timeline range.
public struct CutTarget: Codable, Equatable, Sendable {
    public var phrase: String?
    /// A timeline range, instead of a phrase.
    public var start: Time?
    public var end: Time?
    /// For a phrase said more than once: the one at (or nearest) this
    /// timeline time.
    public var at: Time?
    public var falseStart: Bool?

    public init(phrase: String? = nil, start: Time? = nil, end: Time? = nil, at: Time? = nil, falseStart: Bool? = nil) {
        self.phrase = phrase
        self.start = start
        self.end = end
        self.at = at
        self.falseStart = falseStart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phrase = try c.decodeIfPresent(String.self, forKey: .phrase)
        start = try c.decodeTime(.start)
        end = try c.decodeTime(.end)
        at = try c.decodeTime(.at)
        falseStart = try c.decodeIfPresent(Bool.self, forKey: .falseStart)
    }
}

public struct CutResult: Codable, Sendable {
    /// The revision the plan was made against.
    public var revision: Int
    /// Each stretch asked for, in the order asked: cut, or kept and why.
    public var cuts: [CutStretch]
    public var removed: Time
    public var durationBefore: Time
    public var durationAfter: Time
    /// The `cutRanges` that makes the cuts. Pass it to `apply` to run it
    /// yourself.
    public var commands: [EditCommand]
    /// Set when the plan was applied.
    public var applied: ApplyResult?
    public var warnings: [String]
    /// How the fillers went, with `fillers: true`.
    public var fillers: CutFillers?
}

/// The fillers `tandem cut --fillers` found, and what became of them.
public struct CutFillers: Codable, Equatable, Sendable {
    /// Filler words the transcript has between from and to. One heard on
    /// two mics is one.
    public var found: Int
    public var cut: Int
    /// The ones left in, by why: a `CutPlan.Problem` (`fluent` for one in
    /// running speech), `protected`, `broughtBack` when a false start's
    /// cut brought it back, or `unplaced` when the sound couldn't be read.
    public var leftIn: [String: Int]
    /// What the stretches cutting fillers take out, a phrase cut with a
    /// filler included.
    public var removed: Time
}

/// One stretch: where its cut goes, or why it's left in.
public struct CutStretch: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case cut, kept
    }

    /// The phrase, or the range, as asked.
    public var asked: String
    /// What the transcript has said in the stretch.
    public var text: String
    /// The stretch asked for, on the timeline.
    public var start: Time
    public var end: Time
    public var status: Status
    /// Why it's kept, for a stretch that isn't cut.
    public var reason: String?
    public var problem: CutPlan.Problem?
    public var problemEdge: CutPlan.Edge?
    /// What comes out, on the timeline (whole frames where they land in
    /// the pauses) and in the voice's file.
    public var cut: TimeRange?
    public var mediaID: String?
    public var mediaStart: Time?
    public var mediaEnd: Time?
    /// The pause left after the word before the cut, and before the word
    /// after it.
    public var keptBefore: Time?
    public var keptAfter: Time?
    /// Cut pause to pause as a long false start, bringing back these words
    /// (or this much sound, with no transcript).
    public var falseStart: Bool
    public var broughtBack: String?
    /// How many fillers the stretch is or has in it, with `fillers: true`.
    public var fillers: Int?
    /// Sound in the stretch asked for (or within the transcript's slack of
    /// it) that the cut keeps, because a word that stays is said on the far
    /// side of it: a word the transcript has well off, or missed.
    public var missed: String?
    /// How each side of the join sounds, as `check --cuts` judges it.
    public var startEdge: CutJoinSide?
    public var endEdge: CutJoinSide?
    /// A few words either side that stay.
    public var before: String
    public var after: String
}

public struct CutJoinSide: Codable, Equatable, Sendable {
    public var verdict: CutAudit.Verdict
    /// How far the clip's 25 ms beside the edge is under the speech, dB:
    /// 15 or more is clean, under 9 clipped.
    public var margin: Double
}

extension CutResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let mode = applied == nil ? "dry run" : "applied"
        let made = cuts.filter { $0.status == .cut }
        let kept = cuts.filter { $0.status == .kept }
        func quoted(_ stretch: CutStretch) -> String {
            stretch.text.isEmpty ? stretch.asked : "\"\(stretch.text)\""
        }
        if cuts.isEmpty {
            lines.append("No fillers to cut: the transcript has none there.")
        } else if made.isEmpty {
            lines.append(cuts.count == 1 ? "Nothing to cut:" : "Nothing to cut, all \(cuts.count) stretches are left in:")
        } else {
            let count = made.count == 1 ? "1 stretch" : "\(made.count) stretches"
            lines.append("Cut \(count) pause to pause (\(mode), revision \(revision)), removing \(TimeText.duration(removed)): \(durationBefore) -> \(durationAfter).")
            for stretch in made {
                guard let cut = stretch.cut else { continue }
                let kept = (stretch.keptBefore ?? .zero) + (stretch.keptAfter ?? .zero)
                var line = "  \(cut.start)-\(cut.end)  \(quoted(stretch))  ...\(stretch.before) | \(stretch.after)...  keeps \(TimeText.duration(kept)) of pause"
                let margins = [stretch.startEdge, stretch.endEdge].compactMap { $0.map { String(format: "%.0f", $0.margin) } }
                if stretch.startEdge?.verdict == .clean, stretch.endEdge?.verdict == .clean {
                    line += "; join clean (\(margins.joined(separator: " and ")) dB under the speech)"
                }
                if stretch.falseStart {
                    line += stretch.broughtBack.map { "; a false start, so \"\($0)\" comes back" } ?? "; cut as a false start"
                }
                if let missed = stretch.missed {
                    line += "; but \(missed) in the stretch asked for stays, as a word that stays is past it. Listen with tandem clip"
                }
                lines.append(line)
            }
            if !kept.isEmpty { lines.append("Left in:") }
        }
        for stretch in kept {
            lines.append("  \(stretch.start)-\(stretch.end)  \(quoted(stretch)): \(stretch.reason ?? "kept")")
        }
        if let fillers, fillers.found > 0 {
            var line = "Fillers: \(fillers.found) found, \(fillers.cut) cut (removing \(TimeText.duration(fillers.removed)))"
            let left = fillers.leftIn.values.reduce(0, +)
            if left > 0 {
                let why: [(String, String)] = [
                    ("fluent", "in running speech"), ("runsOn", "with the voice running on"), ("notClean", "whose join wouldn't be clean"),
                    ("protected", "protected"), ("broughtBack", "brought back by a false start's cut"), ("noSpeech", "not heard in the sound"), ("nothingLeft", "with nothing left to cut"), ("unplaced", "where the sound couldn't be read")
                ]
                let reasons = why.compactMap { key, text in fillers.leftIn[key].map { "\($0) \(text)" } }
                line += ", \(left) left in (\(reasons.joined(separator: ", ")))"
            }
            lines.append(line + ".")
        }
        for warning in warnings { lines.append("Warning: \(warning)") }
        if let applied {
            lines.append("Applied as revision \(applied.revision) (\"\(applied.label)\"). Undo with `tandem undo`.")
        } else if !made.isEmpty {
            lines.append("Nothing changed yet. Run again with --apply (or apply: true) to make the cut.")
        }
        return lines.joined(separator: "\n")
    }
}

extension TandemService {
    /// The sound read either side of each edge: the floor and speech level
    /// `CutPlacer` takes over 3 s, room to reach a pause, and the slack
    /// transcript times get.
    static var cutWindow: Double { CutAudit.around + CutAudit.reach + CutPlanner.slack }

    public func cut(_ request: CutRequest, context: CallContext) async throws -> CutResult {
        guard !request.remove.isEmpty || request.fillers == true else {
            throw ServiceError(.badRequest, "Say what to cut: a phrase, like {\"remove\": [{\"phrase\": \"as I said before\"}]}, a range with start and end, or fillers: true.")
        }
        if request.fillers != true, request.from != nil || request.to != nil || request.protect != nil {
            throw ServiceError(.badRequest, "from, to and protect say which fillers to cut, so they go with fillers: true.")
        }
        if let from = request.from, let to = request.to, to <= from {
            throw ServiceError(.badRequest, "from (\(from)) has to be before to (\(to)).")
        }
        let (project, revision) = coordinator.snapshot()
        try checkExpected(request.expectedRevision, at: revision)
        let map = TranscriptTools.speechMap(project, analysis: analysis)

        // What each target is on the timeline.
        var asks: [CutAsk] = []
        for (order, target) in request.remove.enumerated() {
            let name: String, range: TimeRange
            if let phrase = target.phrase {
                guard target.start == nil, target.end == nil else {
                    throw ServiceError(.badRequest, "Give a stretch to cut as a phrase or as start and end, not both.")
                }
                (name, range) = (phrase, try Self.find(phrase, at: target.at, in: map, project: project))
            } else {
                guard let start = target.start, let end = target.end else {
                    throw ServiceError(.badRequest, "Give a stretch to cut as a phrase, or as start and end.")
                }
                guard start >= .zero, end > start, start < project.duration else {
                    throw ServiceError(.badRequest, "Nothing to cut between \(start) and \(end): the timeline is \(project.duration) long.")
                }
                (name, range) = ("\(start)-\(end)", TimeRange(start: start, end: min(end, project.duration)))
            }
            let falseStart = target.falseStart ?? request.falseStart ?? (range.duration.seconds > CutPlanner.falseStartFrom)
            asks.append(CutAsk(names: [name], range: range, order: order, falseStart: falseStart))
        }
        var fillersFound = 0
        if request.fillers == true {
            let fillers = Self.fillers(in: map, from: request.from, to: request.to, protect: request.protect ?? [])
            fillersFound = fillers.count
            asks = Self.joining(fillers, to: asks, in: map)
        }

        var warnings: [String] = []
        var stretches: [CutStretch] = []
        var plans: [Planned] = []
        for ask in asks {
            if let protected = ask.protected {
                plans.append(Planned(
                    range: ask.range, falseStart: false, keep: 0, tightenFrom: 0, removedText: ask.names.joined(separator: " "), before: "", after: "",
                    reason: "a protect time (\(protected)) is in it or the pauses round it, so it's left in."
                ))
            } else {
                var planned = plan(ask.range, falseStart: ask.falseStart, in: project)
                planned.filled = ask.order == nil && ask.fillers > 0
                // A filler on its own is a filled pause, kept as tight as
                // tighten would leave it; anything else asked for gets
                // Filmora's join where it has one.
                if !planned.filled, !planned.onlyFillers, let keep = planned.filmoraKeep { planned.keep = keep }
                plans.append(planned)
            }
            stretches.append(CutStretch(
                asked: ask.names.joined(separator: " + "), text: "", start: ask.range.start, end: ask.range.end, status: .kept,
                falseStart: false, fillers: ask.fillers > 0 ? ask.fillers : nil, before: "", after: ""
            ))
        }

        // The sound round every edge, read once per stretch of each file.
        var readings: [String: [CutPlacer]] = [:]
        var unread: [String: String] = [:]
        let edges = plans.flatMap { plan in [plan.first, plan.last].compactMap { $0 } }
        for (mediaID, group) in Dictionary(grouping: edges, by: \.media.id) {
            guard let item = group.first?.media else { continue }
            var windows: [ClosedRange<Double>] = []
            for time in group.map(\.time).sorted() {
                let window = max(0, time - Self.cutWindow)...(time + Self.cutWindow)
                if let last = windows.last, window.lowerBound <= last.upperBound {
                    windows[windows.count - 1] = last.lowerBound...window.upperBound
                } else {
                    windows.append(window)
                }
            }
            do {
                var energies: [SpeechEnergy] = []
                for window in windows {
                    energies.append(try await SpeechEnergy.read(url: folder.url(for: item), from: window.lowerBound, to: window.upperBound))
                }
                let levels = SpeechLevels(of: energies)
                guard levels.isVoice else {
                    unread[mediaID] = "there's no voice in the sound of \(URL(fileURLWithPath: item.path).lastPathComponent)"
                    continue
                }
                readings[mediaID] = energies.map { CutPlacer($0, levels: levels) }
            } catch {
                unread[mediaID] = "couldn't read the sound of \(URL(fileURLWithPath: item.path).lastPathComponent)"
            }
        }
        for item in Set(edges.filter { !$0.heard }.map(\.media.path)).sorted() {
            warnings.append("No transcript yet for \(URL(fileURLWithPath: item).lastPathComponent), so cuts there were placed from the sound alone.")
        }

        var ranges: [TimeRange] = []
        for index in plans.indices {
            stretches[index] = settle(plans[index], stretches[index], readings: readings, unread: unread, rate: project.settings.frameRate)
            if let cut = stretches[index].cut, stretches[index].status == .cut { ranges.append(cut) }
        }
        let removed = TimeRange.union(ranges).reduce(Time.zero) { $0 + $1.duration }
        let commands: [EditCommand] = ranges.isEmpty ? [] : [.cutRanges(ranges: ranges.sorted { $0.start < $1.start }, trackIDs: nil)]

        let locked = project.allTracks.filter { $0.rippleMode == .cut && $0.locked }.map(\.name)
        if !locked.isEmpty && !commands.isEmpty {
            let message = "Track \(locked.map { "\"\($0)\"" }.joined(separator: ", ")) is locked, so cutting would put the take out of sync. Unlock it first."
            if request.apply == true { throw ServiceError(.locked, message) }
            warnings.append(message)
        }

        var result = CutResult(
            revision: revision, cuts: stretches, removed: removed,
            durationBefore: project.duration, durationAfter: project.duration - removed,
            commands: commands, applied: nil, warnings: warnings
        )
        if request.fillers == true {
            var summary = CutFillers(found: fillersFound, cut: 0, leftIn: [:], removed: .zero)
            var cut: [TimeRange] = []
            for (ask, stretch) in zip(asks, stretches) where ask.fillers > 0 {
                // Each filler by what the cut takes out, not what was asked:
                // a false start's pause fallback can bring one back.
                let made = stretch.status == .cut ? stretch.cut : nil
                var any = false
                for filler in ask.fillerRanges {
                    let mid = (filler.start.seconds + filler.end.seconds) / 2
                    if let made, made.start.seconds <= mid, mid <= made.end.seconds {
                        summary.cut += 1
                        any = true
                    } else {
                        let why = ask.protected != nil ? "protected" : made != nil ? "broughtBack" : stretch.problem?.rawValue ?? "unplaced"
                        summary.leftIn[why, default: 0] += 1
                    }
                }
                if any, let made { cut.append(made) }
            }
            summary.removed = TimeRange.union(cut).reduce(.zero) { $0 + $1.duration }
            result.fillers = summary
        }
        guard !commands.isEmpty else { return result }
        let made = stretches.filter { $0.status == .cut }
        let label = made.count == 1
            ? "Cut \(made[0].text.isEmpty ? made[0].asked : "\"\(made[0].text)\"") pause to pause"
            : "Cut \(made.count) stretches pause to pause"
        let applied = try self.apply(
            ApplyRequest(label: request.label ?? label, author: request.author, commands: commands, expectedRevision: revision, dryRun: request.apply != true),
            context: context
        )
        result.durationAfter = applied.duration
        result.warnings += applied.warnings
        if request.apply == true { result.applied = applied }
        return result
    }

    /// A stretch to plan: one asked for, fillers, or one asked for with the
    /// fillers beside it joined on.
    struct CutAsk {
        /// What was asked for, then the fillers, as `TranscriptTools.filler`
        /// names them.
        var names: [String]
        var range: TimeRange
        /// Where it was asked, for the order the result lists it in; nil
        /// for fillers on their own, which come after, in timeline order.
        var order: Int?
        var falseStart: Bool
        /// The fillers in it, each as the transcript has it.
        var fillerRanges: [TimeRange] = []
        /// The protect time a filler has round it, which leaves it in.
        var protected: Time?

        var fillers: Int { fillerRanges.count }
    }

    /// The fillers the transcript has from `from` to `to`, each its own
    /// stretch. One heard on two mics is one.
    static func fillers(in map: TranscriptTools.SpeechMap, from: Time?, to: Time?, protect: [Time]) -> [CutAsk] {
        let words = map.words.sorted { $0.start < $1.start }
        let clips = Dictionary(map.clips.map { ($0.id, $0.range) }, uniquingKeysWith: { first, _ in first })
        var found: [CutAsk] = []
        var heardIn: [TimeRange] = []
        for word in words {
            guard let name = TranscriptTools.filler(word.text),
                  from.map({ $0 <= word.start }) ?? true, to.map({ word.end <= $0 }) ?? true else { continue }
            let range = TimeRange(start: word.start, end: word.end)
            if let last = found.last, last.range.overlaps(range) {
                let merged = TimeRange(start: last.range.start, end: max(last.range.end, range.end))
                found[found.count - 1].range = merged
                found[found.count - 1].fillerRanges = [merged]
                continue
            }
            found.append(CutAsk(names: [name], range: range, order: nil, falseStart: false, fillerRanges: [range]))
            heardIn.append(clips[word.clipID] ?? range)
        }
        // A protect time in a filler, or in the pause either side of it out
        // to the next word, leaves it in: the beat it's part of is meant,
        // as tighten's protect leaves a pause alone. With no word before or
        // after it, that pause runs to its clip's edge, so a last "um" in a
        // take is protected by a time in the quiet after it.
        for index in found.indices {
            let range = found[index].range
            let before = words.last { $0.end <= range.start }?.end ?? heardIn[index].start
            let after = words.first { $0.start >= range.end }?.start ?? heardIn[index].end
            found[index].protected = protect.first { before <= $0 && $0 <= after }
        }
        return found
    }

    /// Joins each filler to the stretch beside it, a filler or one asked
    /// for, when no word that stays is between them: "um, uh" is one cut,
    /// not two with a sliver of pause between them, and so is "as I said,
    /// uh". Not across more than `CutPlanner.falseStartFrom` of pause,
    /// where sound with no word (someone off mic) would go with it, and
    /// only in one run of the take (`oneTake`), never across sound nobody
    /// has a transcript for. Stretches asked for are never joined to each
    /// other.
    static func joining(_ fillers: [CutAsk], to asked: [CutAsk], in map: TranscriptTools.SpeechMap) -> [CutAsk] {
        let words = map.words
        let reach = Time(seconds: CutPlanner.falseStartFrom)
        // A stretch asked for is the caller's choice, so a protected filler
        // inside one goes with it and is counted as cut, rather than said
        // to be left in while the range takes it out.
        var fillers = fillers
        for index in fillers.indices where fillers[index].protected != nil {
            let filler = fillers[index].range
            let mid = (filler.start.seconds + filler.end.seconds) / 2
            if asked.contains(where: { $0.range.start.seconds <= mid && mid <= $0.range.end.seconds }) {
                fillers[index].protected = nil
            }
        }
        // By start, a stretch asked for before a filler at the same time,
        // so it's named first.
        let ordered = (asked + fillers.filter { $0.protected == nil }).sorted { a, b in
            a.range.start != b.range.start ? a.range.start < b.range.start : a.order != nil && b.order == nil
        }
        var joined: [CutAsk] = []
        for ask in ordered {
            if let last = joined.last, last.fillers > 0 || ask.fillers > 0, last.order == nil || ask.order == nil,
               ask.range.start <= last.range.end || (
                   ask.range.start - last.range.end <= reach
                   && !words.contains(where: { word in
                       let mid = (word.start.seconds + word.end.seconds) / 2
                       return last.range.end.seconds < mid && mid < ask.range.start.seconds
                   })
                   && oneTake(TimeRange(start: last.range.end, end: ask.range.start), in: map)
               ) {
                joined[joined.count - 1] = CutAsk(
                    names: last.names + ask.names, range: TimeRange(start: last.range.start, end: max(last.range.end, ask.range.end)),
                    order: last.order ?? ask.order, falseStart: last.falseStart || ask.falseStart, fillerRanges: last.fillerRanges + ask.fillerRanges
                )
            } else {
                joined.append(ask)
            }
        }
        let protected = fillers.filter { $0.protected != nil }
        return (joined + protected).sorted { a, b in
            switch (a.order, b.order) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.range.start < b.range.start
            }
        }
    }

    /// Whether `gap` plays in one run of a take: in one clip, or clips that
    /// carry straight on from each other (`oneRun`), with no clip nobody
    /// has a transcript for playing over it. A cut across anything else
    /// would take out sound no one has read: another clip's speech, or
    /// both sides of a join an earlier cut made.
    static func oneTake(_ gap: TimeRange, in map: TranscriptTools.SpeechMap) -> Bool {
        guard !map.unknown.contains(where: { $0.overlaps(gap) }) else { return false }
        for first in map.clips where first.start <= gap.start && gap.start <= first.end {
            var clip = first
            while clip.end < gap.end, let next = map.clips.first(where: { $0.id != clip.id && oneRun(clip, $0) }) {
                clip = next
            }
            if gap.end <= clip.end { return true }
        }
        return false
    }

    /// Where `phrase` is said on the timeline: the one match, or the one at
    /// (or nearest) `at`.
    static func find(_ phrase: String, at: Time?, in map: TranscriptTools.SpeechMap, project: Project) throws -> TimeRange {
        guard !TranscriptTools.tokens(phrase).isEmpty else { throw ServiceError(.badRequest, "Give at least one word to cut.") }
        // Each track's words on their own: two mics that both hear "as I
        // said" would otherwise interleave as "as as I I said said".
        var trackOf: [String: Int] = [:]
        for (index, track) in TranscriptTools.speechTracks(project).enumerated() {
            for clip in track.clips where trackOf[clip.id] == nil { trackOf[clip.id] = index }
        }
        let byTrack = Dictionary(grouping: map.words, by: { trackOf[$0.clipID] ?? -1 })
        // One said on several tracks is the same words: a match joins the
        // one it overlaps most from another track. Matches that overlap on
        // one track ("very very" in "very very very") are each their own.
        var found: [(range: TimeRange, tracks: Set<Int>)] = []
        for track in byTrack.keys.sorted() {
            let words = byTrack[track] ?? []
            for match in TranscriptTools.matches(of: phrase, in: words.map(\.text), overlapping: true) {
                let range = TimeRange(start: words[match.lowerBound].start, end: words[match.upperBound].end)
                func overlap(_ other: TimeRange) -> Time { min(range.end, other.end) - max(range.start, other.start) }
                let same = found.indices
                    .filter { !found[$0].tracks.contains(track) && overlap(found[$0].range) > .zero }
                    .max { overlap(found[$0].range) < overlap(found[$1].range) }
                if let same {
                    found[same].tracks.insert(track)
                } else {
                    found.append((range, [track]))
                }
            }
        }
        let ranges = found.map(\.range).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        return try pick(ranges, phrase: phrase, at: at)
    }

    /// The one place `phrase` is said, or the one at (or nearest) `at`.
    static func pick(_ found: [TimeRange], phrase: String, at: Time?) throws -> TimeRange {
        guard !found.isEmpty else {
            throw ServiceError(.notFound, "\"\(phrase)\" isn't said on the timeline. tandem search \"\(phrase)\" finds it, in cut material too.")
        }
        if let at {
            func distance(_ range: TimeRange) -> Time { at < range.start ? range.start - at : (at > range.end ? at - range.end : .zero) }
            return found.min { distance($0) < distance($1) }!
        }
        guard found.count == 1 else {
            let times = found.map { "\($0.start)" }.joined(separator: ", ")
            throw ServiceError(.badRequest, "\"\(phrase)\" is said \(found.count) times, at \(times). Give the time of the one to cut as at (--at).")
        }
        return found[0]
    }

    /// One edge of a stretch: the voice clip it's in and what the
    /// transcript says either side, in that clip's file time.
    struct CutEdge {
        var clip: Clip
        var media: MediaItem
        var time: Double
        var boundary: CutPlanner.Boundary
        /// The transcript's words, for naming what's cut and kept.
        var words: [TranscriptWord]
        var heard: Bool
    }

    struct Planned {
        var range: TimeRange
        var first: CutEdge?
        var last: CutEdge?
        var falseStart: Bool
        var keep: Double
        /// Pauses under this are kept as they were, as tighten leaves them.
        var tightenFrom: Double
        /// Fillers on their own are a filled pause, the minimum going by
        /// the whole of it (`CutPlanner.plan`'s `filled`).
        var filled = false
        /// The keep Filmora's join gives this stretch, when it isn't only
        /// fillers (see `filmoraJoin`).
        var filmoraKeep: Double?
        /// Every word it cuts is a filler, however it was asked for
        /// (`tandem cut "um"` as much as `--fillers`).
        var onlyFillers = false
        var removedText: String
        var before: String
        var after: String
        /// Why there's nothing to plan, when there isn't.
        var reason: String?
    }

    /// The voice clip playing `time`, as `check --cuts` picks the clips it
    /// judges: heard clips with sound on the speech tracks, not music or
    /// sound effects. `ending` for the clip a stretch ends in.
    static func voiceClip(at time: Time, ending: Bool, in project: Project) -> (Clip, MediaItem)? {
        for track in TranscriptTools.speechTracks(project) {
            for clip in track.clips where TranscriptTools.isHeard(clip) {
                guard let id = clip.mediaID, let item = project.media(id), item.hasAudio, item.role != .sfx, item.role != .music else { continue }
                if ending ? (clip.start < time && time <= clip.end) : (clip.start <= time && time < clip.end) { return (clip, item) }
            }
        }
        return nil
    }

    /// The stretch of its file a clip plays.
    static func played(_ clip: Clip) -> ClosedRange<Double> { clip.sourceStart.seconds...clip.sourceEnd.seconds }

    /// Whether a stretch's two edges are in one run of one file, so the
    /// start has to come before the end in file time too: the same clip, or
    /// one that carries straight on from the other in both timeline and file.
    /// Clips of a file played out of order (the end of it, then the start)
    /// are ordered by the timeline, not the file.
    static func oneRun(_ first: Clip, _ last: Clip) -> Bool {
        if first.id == last.id { return true }
        return first.mediaID == last.mediaID && first.speed == last.speed
            && abs((first.end - last.start).seconds) < 1e-6 && abs((first.sourceEnd - last.sourceStart).seconds) < 1e-6
    }

    /// A join between sentences or round a false start: Filmora's 0.4 s
    /// softening buffer on each side (`VolumeTightening.Settings.filmora`).
    static var filmoraJoin: Double { VolumeTightening.Settings.filmora.buffer * 2 }

    func plan(_ range: TimeRange, falseStart: Bool?, in project: Project) -> Planned {
        var planned = Planned(
            range: range, falseStart: falseStart ?? (range.duration.seconds > CutPlanner.falseStartFrom),
            keep: (TranscriptTools.mikeRules.sentence ?? Time(seconds: 0.4)).seconds,
            tightenFrom: TranscriptTools.mikeRules.minimum.seconds, removedText: "", before: "", after: ""
        )
        guard let (first, firstMedia) = Self.voiceClip(at: range.start, ending: false, in: project),
              let (last, lastMedia) = Self.voiceClip(at: range.end, ending: true, in: project) else {
            planned.reason = "no voice clip plays at \(Self.voiceClip(at: range.start, ending: false, in: project) == nil ? range.start : range.end), so there's no sound to place the cut by. Cut it with cutRanges."
            return planned
        }
        func media(_ time: Time, _ clip: Clip) -> Double { clip.sourceStart.seconds + (time - clip.start).seconds * clip.speed }
        let from = media(range.start, first), to = media(range.end, last)
        let same = first.id == last.id
        func words(_ item: MediaItem) -> [TranscriptWord]? {
            analysis.transcript(for: item)?.words.filter { $0.end > $0.start }
        }
        func mid(_ word: TranscriptWord) -> Double { (word.start.seconds + word.end.seconds) / 2 }
        func span(_ word: TranscriptWord) -> ClosedRange<Double> { word.start.seconds...word.end.seconds }
        let reach = Self.cutWindow

        let firstWords = words(firstMedia)
        let firstEnd = same ? to : first.sourceEnd.seconds
        let cutFirst = firstWords?.filter { from <= mid($0) && mid($0) <= firstEnd } ?? []
        let keptBefore = firstWords?.filter { mid($0) < from && first.sourceStart.seconds <= mid($0) && $0.end.seconds > from - reach } ?? []
        planned.first = CutEdge(
            clip: first, media: firstMedia, time: from,
            boundary: CutPlanner.Boundary(
                time: from, before: keptBefore.map(span), after: firstWords == nil ? [] : cutFirst.map(span),
                within: Self.played(first), speed: first.speed
            ),
            words: cutFirst, heard: firstWords != nil
        )

        let lastWords = words(lastMedia)
        let lastStart = same ? from : last.sourceStart.seconds
        let cutLast = lastWords?.filter { lastStart <= mid($0) && mid($0) <= to } ?? []
        let keptAfter = lastWords?.filter { mid($0) > to && mid($0) <= last.sourceEnd.seconds && $0.start.seconds < to + reach } ?? []
        planned.last = CutEdge(
            clip: last, media: lastMedia, time: to,
            boundary: CutPlanner.Boundary(
                time: to, before: lastWords == nil ? [] : cutLast.map(span), after: keptAfter.map(span),
                within: Self.played(last), speed: last.speed
            ),
            words: cutLast, heard: lastWords != nil
        )

        let removed = same ? cutFirst : cutFirst + cutLast
        planned.onlyFillers = !removed.isEmpty && removed.allSatisfy { TranscriptTools.filler($0.text) != nil }
        planned.removedText = removed.map(\.text).joined(separator: " ")
        planned.before = keptBefore.suffix(4).map(\.text).joined(separator: " ")
        planned.after = keptAfter.prefix(4).map(\.text).joined(separator: " ")
        // The pause the join leaves: Mike's tighten rules for what the word
        // before it ends with (0.4 s after a sentence, 0.12 s after a comma,
        // 0.08 s mid-sentence). With no word before, it's the take's start.
        // Pauses under 0.5 s are left as they are, as tighten leaves them.
        if let word = keptBefore.last {
            let kind = TranscriptTools.pauseKind(after: word.text)
            if let keep = TranscriptTools.mikeRules.keep(for: kind) { planned.keep = keep.seconds }
            planned.tightenFrom = TranscriptTools.mikeRules.shortest(for: kind).seconds
            // Between sentences, or round a false start, the join leaves what
            // Filmora did when Mike deleted a retake's clip: the 0.4 s
            // softening buffer either side, so it matches every other pause
            // `tighten --filmora` leaves (he picked that by ear, 12 Nov 2026).
            // Mid-sentence and comma joins stay tight: Filmora never split
            // there.
            if kind == .sentence || planned.falseStart { planned.filmoraKeep = max(planned.keep, Self.filmoraJoin) }
        } else {
            planned.filmoraKeep = max(planned.keep, Self.filmoraJoin)
        }
        return planned
    }

    /// Places a planned stretch in its sound, and says how it went.
    func settle(_ planned: Planned, _ stretch: CutStretch, readings: [String: [CutPlacer]], unread: [String: String], rate: FrameRate) -> CutStretch {
        var stretch = stretch
        stretch.text = planned.removedText
        stretch.before = planned.before
        stretch.after = planned.after
        guard let first = planned.first, let last = planned.last else {
            stretch.reason = planned.reason
            return stretch
        }
        stretch.mediaID = first.media.id
        if let why = unread[first.media.id] ?? unread[last.media.id] {
            stretch.reason = "\(why), so the cut can't be placed in a pause. Cut it with cutRanges and listen."
            return stretch
        }
        func placer(_ edge: CutEdge) -> CutPlacer? {
            readings[edge.media.id]?.first { $0.energy.start <= edge.time && edge.time <= $0.energy.end }
        }
        guard let startPlacer = placer(first), let endPlacer = placer(last) else {
            stretch.reason = "couldn't read the sound there."
            return stretch
        }

        // Each edge onto a frame where one lands in its pause, and inside
        // its clip: kept pause rounds up, as tighten's does.
        func timeline(_ media: Double, _ clip: Clip) -> Time { clip.start + Time(seconds: (media - clip.sourceStart.seconds) / clip.speed) }
        func media(_ time: Time, _ clip: Clip) -> Double { clip.sourceStart.seconds + (time - clip.start).seconds * clip.speed }
        var times: [CutPlan.Edge: Time] = [:]
        let snap: (Double, CutPlan.Edge, ClosedRange<Double>) -> Double = { time, edge, pause in
            let clip = edge == .start ? first.clip : last.clip
            let source = clip.sourceStart.seconds...clip.sourceEnd.seconds
            let low = max(pause.lowerBound, source.lowerBound), high = min(pause.upperBound, source.upperBound)
            guard low <= high else { return time }
            let at = timeline(min(max(time, low), high), clip)
            let floor = TimeText.floorToFrame(at, rate), ceil = TimeText.ceilToFrame(at, rate)
            for candidate in edge == .start ? [ceil, floor] : [floor, ceil] {
                let moved = media(candidate, clip)
                if low - 1e-6 <= moved, moved <= high + 1e-6 {
                    times[edge] = candidate
                    return moved
                }
            }
            times[edge] = at
            return min(max(time, low), high)
        }
        let plan = CutPlanner.plan(
            start: startPlacer, first.boundary, end: endPlacer, last.boundary, keep: planned.keep, tightenFrom: planned.tightenFrom,
            falseStart: planned.falseStart, sameFile: Self.oneRun(first.clip, last.clip),
            filled: planned.filled, snap: snap
        )
        stretch.falseStart = plan.falseStart
        stretch.problem = plan.problem
        stretch.problemEdge = plan.problemEdge
        stretch.startEdge = plan.start.map { CutJoinSide(verdict: $0.verdict, margin: (Double($0.margin) * 10).rounded() / 10) }
        stretch.endEdge = plan.end.map { CutJoinSide(verdict: $0.verdict, margin: (Double($0.margin) * 10).rounded() / 10) }
        let words = first.words + (first.clip.id == last.clip.id ? [] : last.words)
        if !plan.broughtBack.isEmpty {
            let back = words.filter { word in plan.broughtBack.contains { $0.lowerBound <= word.start.seconds + 1e-6 && word.end.seconds <= $0.upperBound + 1e-6 } }
            stretch.broughtBack = back.isEmpty
                ? String(format: "%.2f s of sound", plan.broughtBack.reduce(0) { $0 + $1.upperBound - $1.lowerBound })
                : back.map(\.text).joined(separator: " ")
        }

        guard plan.cuts, let from = plan.from, let to = plan.to else {
            stretch.reason = reason(plan, planned)
            return stretch
        }
        let start = times[.start] ?? timeline(from, first.clip)
        let end = times[.end] ?? timeline(to, last.clip)
        // Each edge inside its own clip: the planner only places them in
        // pauses the clip plays, so this is a last guard.
        func inside(_ time: Double, _ clip: Clip) -> Bool {
            clip.sourceStart.seconds - 1e-6 <= time && time <= clip.sourceEnd.seconds + 1e-6
        }
        guard inside(from, first.clip), inside(to, last.clip), end > start else {
            stretch.reason = "the pause round it is already cut away at the join, so there's no pause to put the cut in. Cut it with cutRanges and listen."
            return stretch
        }
        stretch.status = .cut
        stretch.cut = TimeRange(start: start, end: end)
        stretch.mediaStart = Time(seconds: from)
        stretch.mediaEnd = Time(seconds: to)
        // The planner's pauses are file seconds: on the timeline a 2x clip
        // plays them in half the time.
        stretch.keptBefore = Time(seconds: (plan.keptBefore / first.clip.speed * 1000).rounded() / 1000)
        stretch.keptAfter = Time(seconds: (plan.keptAfter / last.clip.speed * 1000).rounded() / 1000)
        let missed = (plan.missed[.start] ?? []).map { ($0, first.clip.speed) } + (plan.missed[.end] ?? []).map { ($0, last.clip.speed) }
        if !missed.isEmpty {
            stretch.missed = String(format: "%.2f s of sound", missed.reduce(0) { $0 + ($1.0.upperBound - $1.0.lowerBound) / $1.1 })
        }
        return stretch
    }

    func reason(_ plan: CutPlan, _ planned: Planned) -> String {
        let atStart = plan.problemEdge != .end
        switch plan.problem {
        case .fluent:
            let word = atStart ? planned.before.split(separator: " ").last : planned.after.split(separator: " ").first
            let neighbour = word.map { "\"\($0)\"" } ?? (atStart ? "the word before" : "the word after")
            return "no pause between it and \(neighbour): they run together, so a cut there would clip a word. Left in: on the Ian video, leaving a filler like this in sounded right."
                + (plan.falseStart || planned.falseStart ? "" : " If it's a false start, cut it with falseStart to go pause to pause.")
        case .runsOn:
            let side = atStart ? "into it from before" : "on past it"
            return "the voice runs \(side) with no pause within \(String(format: "%.1f", CutPlanner.slack)) s of where the transcript has the words. Left in: listen with tandem clip, or cut a wider stretch."
        case .noSpeech:
            return "there's no speech in the sound where the transcript has these words."
        case .nothingLeft:
            return "a false start with no pause inside it to cut to."
        case .notClean:
            let edge = atStart ? plan.start : plan.end
            let margin = edge.map { String(format: "%.1f", $0.margin) } ?? "?"
            return "the \(atStart ? "start" : "end") of the cut would be judged \(edge?.verdict.rawValue ?? "not clean") (\(margin) dB under the speech), so it's left in. Listen with tandem clip."
        case nil:
            return "kept."
        }
    }
}
