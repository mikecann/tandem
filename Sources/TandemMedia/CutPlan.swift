import Foundation

/// How a stretch of speech comes out of a take: where both edges of its cut
/// go, in the real pauses either side of it, or why it can't be cut cleanly.
public struct CutPlan: Equatable, Sendable {
    public enum Edge: String, Codable, Sendable {
        case start, end
    }

    /// Why a stretch isn't cut.
    public enum Problem: String, Codable, Sendable {
        /// A word that stays and a word cut run together with no pause
        /// between them (a filler or a repeat in running speech, #64), so
        /// any cut there clips one of them.
        case fluent
        /// The voice runs on past the transcript's edge of the words with no
        /// pause within `CutPlanner.slack`: sound the transcript doesn't
        /// account for, joined to them.
        case runsOn
        /// No speech in the sound where the words are said to be.
        case noSpeech
        /// A false start whose only pauses leave nothing to cut.
        case nothingLeft
        /// The planned edge didn't judge clean (`CutPlacer.judge`).
        case notClean
    }

    /// How one side of the finished join sounds, as `tandem check --cuts`
    /// would judge it.
    public struct Join: Equatable, Sendable {
        public var verdict: CutAudit.Verdict
        /// How far the clip's 25 ms beside the edge is under the speech, dB.
        public var margin: Float
    }

    /// The cut, in media time: from `from` to `to` comes out.
    public var from: Double?
    public var to: Double?
    /// The real pauses the edges are in.
    public var startPause: ClosedRange<Double>?
    public var endPause: ClosedRange<Double>?
    /// How much of each pause is left at the join: after the word before the
    /// cut, and before the word after it.
    public var keptBefore: Double = 0
    public var keptAfter: Double = 0
    /// Cut pause to pause as a long false start, bringing back the words
    /// in `broughtBack` (transcript times, or the stretch of sound when
    /// there's no transcript).
    public var falseStart = false
    public var broughtBack: [ClosedRange<Double>] = []
    /// Sound the cut keeps at each edge, in or within `CutPlanner.slack` of
    /// the stretch asked for, that no transcript word accounts for: kept
    /// because a word that stays is said after it (or before it, at the
    /// end), so cutting it would cut that word too.
    public var missed: [Edge: [ClosedRange<Double>]] = [:]
    public var start: Join?
    public var end: Join?
    public var problem: Problem?
    public var problemEdge: Edge?

    public var cuts: Bool { problem == nil && from != nil && to != nil }
}

/// Plans cuts pause to pause: the cut starts in the real pause before the
/// first word removed and ends in the one after the last, found in the
/// sound (`CutPlacer`'s pause map), never on a transcript time. The
/// transcript only says roughly where the words are and which of them stay.
///
/// The sound between pauses comes in islands: runs of voice with no real
/// pause in them (a word, or several said without a break). Each word
/// belongs to the island holding most of it, so a word the transcript has
/// 0.2 s late still lands in the right one. When a word that stays and a
/// word that goes share an island there's no pause between them, and the
/// stretch is left in rather than cut through running speech: on the Ian
/// video (#64) leaving a filler in sounded right, and every cut placed in
/// fluent speech was heard clipped.
public enum CutPlanner {
    /// How far an edge's pause can be from where the transcript (or the
    /// caller) puts the edge of the words. Transcript times were 30 to
    /// 100 ms off on the Ian video and "processed" 0.2 s (#64), and a word's
    /// sound starts up to 80 ms before its burst (`CutAudit.lead`), so
    /// 0.3 s; past that the sound there isn't the words asked for.
    public static let slack = 0.3
    /// A stretch longer than this is a long false start, cut pause to pause
    /// even when that brings a word of it back (#64's third fix): #64 found
    /// putting back a cut of 2 s or less (`CutAudit.putBackLimit`) sounded
    /// right, so anything longer costs more to keep than a repeated word.
    public static var falseStartFrom: Double { CutAudit.putBackLimit }
    /// The least of a pause kept after the word before a cut, and before
    /// the word after it: `CutAudit.pad` past a word's tail, and
    /// `CutAudit.lead` before a word, whose sound can start before its burst.
    public static var minimumTail: Double { CutAudit.pad }
    public static var minimumLead: Double { CutAudit.lead }
    /// Words this far from an island still say which side of a cut it's on.
    static let nearWord = 1.0

    /// What's known about the words at one edge of a cut, in media time.
    public struct Boundary: Sendable {
        /// Where the words' edge is said to be: the start of the first word
        /// cut, or the end of the last.
        public var time: Double
        /// Transcript words before and after the edge. Both empty without a
        /// transcript: then the edge is placed from the sound and `time`.
        public var before: [ClosedRange<Double>]
        public var after: [ClosedRange<Double>]
        /// The stretch of the file the edge's clip plays. A pause outside it
        /// isn't heard there, so it isn't a pause for this edge.
        public var within: ClosedRange<Double>?
        /// How fast the edge's clip plays its file: the keep is timeline
        /// seconds, and at 2x a pause is half as long on the timeline.
        public var speed: Double

        public init(
            time: Double, before: [ClosedRange<Double>] = [], after: [ClosedRange<Double>] = [],
            within: ClosedRange<Double>? = nil, speed: Double = 1
        ) {
            self.time = time
            self.before = before
            self.after = after
            self.within = within
            self.speed = speed
        }

        var heard: Bool { !before.isEmpty || !after.isEmpty }

        /// The part of `pause` the edge's clip plays, if any.
        func played(_ pause: ClosedRange<Double>) -> ClosedRange<Double>? {
            guard let within else { return pause }
            let low = max(pause.lowerBound, within.lowerBound), high = min(pause.upperBound, within.upperBound)
            return high > low ? low...high : nil
        }

        /// Whether `island` is in the stretch asked for, allowing for the
        /// slack: reaching past the start edge's time, less the slack, or
        /// short of the end edge's, plus it.
        func inStretch(_ island: ClosedRange<Double>, edge: CutPlan.Edge) -> Bool {
            edge == .start ? island.upperBound > time - slack : island.lowerBound < time + slack
        }
    }

    /// Removes `stretch` of one file: words in `cut` go, words in `kept`
    /// stay (both empty without a transcript). `falseStart` nil cuts it as
    /// a false start when it's longer than `falseStartFrom`.
    public static func plan(
        _ placer: CutPlacer, removing stretch: ClosedRange<Double>, cut: [ClosedRange<Double>], kept: [ClosedRange<Double>],
        keep: Double, tightenFrom: Double = 0, falseStart: Bool?, snap: ((Double, CutPlan.Edge, ClosedRange<Double>) -> Double)? = nil
    ) -> CutPlan {
        let mid = { (word: ClosedRange<Double>) in (word.lowerBound + word.upperBound) / 2 }
        let before = kept.filter { mid($0) < stretch.lowerBound }
        let after = kept.filter { mid($0) > stretch.upperBound }
        let heard = !cut.isEmpty || !kept.isEmpty
        return plan(
            start: placer, Boundary(time: stretch.lowerBound, before: before, after: heard ? cut : []),
            end: placer, Boundary(time: stretch.upperBound, before: heard ? cut : [], after: after),
            keep: keep, tightenFrom: tightenFrom, falseStart: falseStart ?? (stretch.upperBound - stretch.lowerBound > falseStartFrom), snap: snap
        )
    }

    /// Removes the sound from `startBoundary` to `endBoundary`, each placed
    /// in its own file's sound (a stretch can run across clips). `keep` is
    /// how much pause the join leaves, split as `tighten` splits it, when
    /// the longer of the two pauses (the one the speaker left there anyway)
    /// is `tightenFrom` or more; a shorter one is kept as it was, as
    /// `tighten` leaves pauses under its minimum alone. Both are timeline
    /// seconds, so they're scaled by each boundary's `speed`.
    /// `snap` can move each edge within its pause (onto a frame, say)
    /// before the join is judged. `sameFile` when both edges are in one
    /// file's time, so the cut can be checked for being the right way round.
    /// `filled` when the stretch is fillers on their own: a filled pause,
    /// so `tightenFrom` goes by the whole pause, filler and all, as tighten
    /// would have heard it with no filler. "query, [um] we" with 0.3 s
    /// either side is a 0.9 s pause cut to a comma's 0.12 s, not a 0.3 s
    /// one kept as it was.
    public static func plan(
        start: CutPlacer, _ startBoundary: Boundary, end: CutPlacer, _ endBoundary: Boundary,
        keep: Double, tightenFrom: Double = 0, falseStart: Bool, sameFile: Bool = true, filled: Bool = false,
        snap: ((Double, CutPlan.Edge, ClosedRange<Double>) -> Double)? = nil
    ) -> CutPlan {
        var plan = CutPlan()
        var missed: [CutPlan.Edge: [ClosedRange<Double>]] = [:]
        var faint: [CutPlan.Edge: [ClosedRange<Double>]] = [:]
        var first = side(start, startBoundary, edge: .start, missed: &missed, faint: &faint)
        var last = side(end, endBoundary, edge: .end, missed: &missed, faint: &faint)
        if falseStart {
            // Pause to pause inside the false start, where there's none
            // round it: the words past that pause come back.
            func inSound(_ side: Result<ClosedRange<Double>, ProblemError>) -> Bool {
                side.problemValue == .fluent || side.problemValue == .runsOn
            }
            // The other edge only limits this one when both are in one run
            // of one file: otherwise their times aren't comparable.
            let startLimit = sameFile ? (try? last.get())?.lowerBound ?? endBoundary.time : .infinity
            if inSound(first), let pause = insidePause(start, startBoundary, edge: .start, limit: startLimit) {
                first = .success(pause)
                plan.falseStart = true
                plan.broughtBack += broughtBack(startBoundary, pause: pause, edge: .start)
            }
            let endLimit = sameFile ? (try? first.get())?.upperBound ?? startBoundary.time : -.infinity
            if inSound(last), let pause = insidePause(end, endBoundary, edge: .end, limit: endLimit) {
                last = .success(pause)
                plan.falseStart = true
                plan.broughtBack += broughtBack(endBoundary, pause: pause, edge: .end)
            }
        }
        let before: ClosedRange<Double>, after: ClosedRange<Double>
        switch (first, last) {
        case (.failure(let error), _):
            plan.problem = error.problem
            plan.problemEdge = .start
            return plan
        case (_, .failure(let error)):
            plan.problem = error.problem
            plan.problemEdge = .end
            return plan
        case (.success(let a), .success(let b)):
            (before, after) = (a, b)
        }
        plan.startPause = before
        plan.endPause = after
        plan.missed = missed

        // The pauses as they play: a clip at 2x plays a 0.4 s pause in 0.2.
        let lengths = (before: before.upperBound - before.lowerBound, after: after.upperBound - after.lowerBound)
        var natural = max(lengths.before / startBoundary.speed, lengths.after / endBoundary.speed)
        // A filled pause is measured in the sound, from the end of the word
        // before to the start of the word after, as tighten measures the
        // pauses it judges. The transcript's times for the filler are looser
        // than that, so adding them in made a 0.45 s pause read as 0.55 s.
        // Across two clips the times aren't comparable, so it goes by the
        // longer pause alone, which tightens less.
        if filled, sameFile {
            natural = max(natural, (after.upperBound - before.lowerBound) / startBoundary.speed)
        }
        let (tail, lead) = split(
            natural < tightenFrom ? natural : keep, before: lengths.before, after: lengths.after,
            speeds: (startBoundary.speed, endBoundary.speed)
        )
        var from = before.lowerBound + tail
        var to = after.upperBound - lead
        // Out of faint sound in the pause, into the quiet beside it, keeping
        // more of the pause: the join goes in the room's quiet rather than
        // halfway through a bump of it.
        if let sound = faint[.start]?.first(where: { $0.lowerBound < from && from < $0.upperBound }),
           sound.upperBound + CutAudit.pad <= before.upperBound - min(CutAudit.pad, lengths.before / 2) {
            from = sound.upperBound + CutAudit.pad
        }
        if let sound = faint[.end]?.first(where: { $0.lowerBound < to && to < $0.upperBound }),
           sound.lowerBound - CutAudit.pad >= after.lowerBound + min(CutAudit.pad, lengths.after / 2) {
            to = sound.lowerBound - CutAudit.pad
        }
        if let snap {
            from = snap(from, .start, before)
            to = snap(to, .end, after)
        }
        guard from < to || !sameFile else {
            plan.problem = .nothingLeft
            plan.problemEdge = .end
            return plan
        }
        plan.from = from
        plan.to = to
        plan.keptBefore = from - before.lowerBound
        plan.keptAfter = after.upperBound - to

        // Judged as `tandem check --cuts` will judge the join. It's in real
        // pauses by construction, but frames and floors move.
        plan.start = join(start, at: from, keeps: .before)
        plan.end = join(end, at: to, keeps: .after)
        if plan.start?.verdict != .clean {
            plan.problem = .notClean
            plan.problemEdge = .start
        } else if plan.end?.verdict != .clean {
            plan.problem = .notClean
            plan.problemEdge = .end
        }
        return plan
    }

    /// How a join sounds from one side.
    public static func join(_ placer: CutPlacer, at time: Double, keeps side: CutAudit.Side) -> CutPlan.Join {
        let edge = placer.judge(at: time, keeps: side)
        return CutPlan.Join(verdict: edge.verdict, margin: placer.score(at: time, keeps: side).margin)
    }

    /// How `keep` is shared between the pause after the word before the cut
    /// and the pause before the word after it: half each, as `tighten`
    /// does, but at least `minimumTail` and `minimumLead` where the pauses
    /// have them, and never more than either pause has short of `pad`.
    /// `keep` is timeline seconds and the rest media seconds, played at
    /// `speeds` (the clips before and after the join); the minimums are
    /// about the sound, so they stay in media seconds.
    static func split(_ keep: Double, before: Double, after: Double, speeds: (before: Double, after: Double) = (1, 1)) -> (tail: Double, lead: Double) {
        // The edges stay a little way off the cut words too, so a soft
        // start or tail of theirs isn't left at the join.
        let before = before - min(CutAudit.pad, before / 2)
        let after = after - min(CutAudit.pad, after / 2)
        var tail = max(min(minimumTail, before), min(before, keep / 2 * speeds.before))
        let lead = max(min(minimumLead, after), min(after, (keep - tail / speeds.before) * speeds.after))
        if tail / speeds.before + lead / speeds.after < keep {
            tail = min(before, max(tail, (keep - lead / speeds.after) * speeds.before))
        }
        return (tail, lead)
    }

    // MARK: - Islands

    /// A run of sound with no real pause in it, as frame indices.
    struct Island {
        var start: Int
        var end: Int
        /// It runs past the frames read, so how far is unknown.
        var openStart: Bool
        var openEnd: Bool
    }

    /// An island has at least this much sound in it (`CutAudit.minSpeech`).
    /// Less is a blip of room noise or a click in a pause: on a quiet mic,
    /// 5 ms frames of the room's rumble reach a dB or so over the quiet line
    /// every so often, and a blip like that splits one pause into two.
    static var soundFrames: Int { Int((CutAudit.minSpeech / SpeechEnergy.frameSeconds).rounded()) }

    /// The islands in the frames read: the runs `CutPlacer` finds no real
    /// pause in, so an edge placed between them is in a pause as
    /// `tandem check --cuts` sees it. (Filling blips into the pauses there
    /// hid the bursts after closures on the Ian video: the check caught 42
    /// of its 64 clipped edges instead of 50.)
    static func islands(_ placer: CutPlacer, _ near: CutPlacer.Around) -> [Island] {
        let frames = near.frames
        var islands: [Island] = []
        var index = frames.lowerBound
        while index < frames.upperBound {
            guard !near.isPause(index) else { index += 1; continue }
            var end = index
            while end < frames.upperBound, !near.isPause(end) { end += 1 }
            // Too little sound to be speech: part of the pause.
            if (index..<end).filter({ !near.isQuiet($0) }).count >= soundFrames {
                islands.append(Island(
                    start: index, end: end,
                    openStart: index == frames.lowerBound && index > 0, openEnd: end == frames.upperBound && end < near.count
                ))
            }
            index = end
        }
        return islands
    }

    /// Where one edge of the cut can go: the pause between the sound that
    /// stays and the sound that goes, or why there isn't one.
    /// Sound in the stretch asked for that the chosen pause leaves on the
    /// side that stays goes in `missed`.
    static func side(
        _ placer: CutPlacer, _ boundary: Boundary, edge: CutPlan.Edge, missed: inout [CutPlan.Edge: [ClosedRange<Double>]],
        faint: inout [CutPlan.Edge: [ClosedRange<Double>]]
    ) -> Result<ClosedRange<Double>, ProblemError> {
        let near = placer.around(boundary.time)
        var islands = islands(placer, near)
        let step = SpeechEnergy.frameSeconds
        func time(_ index: Int) -> Double { placer.energy.start + Double(index) * step }
        func span(_ island: Island) -> ClosedRange<Double> { time(island.start)...time(island.end) }
        func overlap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
            max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        }
        func distance(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
            max(0, max(a.lowerBound, b.lowerBound) - min(a.upperBound, b.upperBound))
        }

        // Faint sound no word calls home (`FaintSound`) is part of the pause
        // it's in: a foot tapping or a fan all through a pause left no pause
        // within the slack of the words on the Threadbear launch video. Its
        // islands go, and the edge is kept out of them when it's placed.
        if boundary.heard {
            let words = boundary.before + boundary.after
            let homes = Set(words.compactMap { word in
                islands.indices.filter { overlap(span(islands[$0]), word) > 0 }.max { overlap(span(islands[$0]), word) < overlap(span(islands[$1]), word) }
            })
            let line = near.highFloor + GapSound.highOverFloor
            let voices = homes.map { islands[$0].start..<islands[$0].end }
            let speech = FaintSound.speech(in: placer.energy, around: boundary.time)
            let quiet = Set(islands.indices.filter { index in
                !homes.contains(index)
                    && FaintSound.isFaint(islands[index].start..<islands[index].end, beside: voices, in: placer.energy, highLine: line, speech: speech)
            })
            // And faint sound running straight into a word's island is
            // trimmed off it (`FaintSound.faintEnds`), on the sides read whole.
            // The edge isn't kept out of what's trimmed: it runs on to the
            // word, and the edge's least before the word (`minimumLead`) is
            // measured from where its voice starts.
            for index in homes {
                let ends = FaintSound.faintEnds(of: islands[index].start..<islands[index].end, beside: voices, in: placer.energy, highLine: line, speech: speech)
                if !islands[index].openStart, ends.start > 0 {
                    islands[index].start += ends.start
                }
                if !islands[index].openEnd, ends.end > 0 {
                    islands[index].end -= ends.end
                }
            }
            if !quiet.isEmpty {
                faint[edge, default: []] += quiet.sorted().map { span(islands[$0]) }
                islands = islands.indices.filter { !quiet.contains($0) }.map { islands[$0] }
            }
        }

        // Which side of the edge each island is on: `false` before, `true`
        // after. Without a transcript, the side holding more of it.
        var sides: [Bool?] = []
        var orphans: Set<Int> = []
        if boundary.heard {
            // Each word's home: the island holding most of it.
            func home(_ word: ClosedRange<Double>) -> Int? {
                let best = islands.indices.max { overlap(span(islands[$0]), word) < overlap(span(islands[$1]), word) }
                return best.flatMap { overlap(span(islands[$0]), word) > 0 ? $0 : nil }
            }
            let beforeHomes = Set(boundary.before.compactMap(home))
            let afterHomes = Set(boundary.after.compactMap(home))
            if !beforeHomes.isDisjoint(with: afterHomes) { return .failure(.init(.fluent)) }
            let removed = edge == .start ? afterHomes : beforeHomes
            if removed.isEmpty { return .failure(.init(.noSpeech)) }
            sides = islands.indices.map { index in
                if beforeHomes.contains(index) { return false }
                if afterHomes.contains(index) { return true }
                // Sound no word calls home: a word the transcript missed, or
                // one it has well off. Islands come in order, so sound
                // before a word on the side before the edge is on that side
                // too, and sound after one on the side after is on that one.
                orphans.insert(index)
                if let last = beforeHomes.max(), index < last { return false }
                if let first = afterHomes.min(), index > first { return true }
                // Between the two, sound in the stretch asked for (allowing
                // for the slack) is cut: a removed word whose late time lands
                // on the next removed word's sound leaves its own unclaimed,
                // and going with the nearer word kept it.
                let island = span(islands[index])
                if boundary.inStretch(island, edge: edge) { return edge == .start }
                // Otherwise with the nearer word.
                let nearest = (boundary.before.map { (distance($0, island), false) } + boundary.after.map { (distance($0, island), true) })
                    .filter { $0.0 <= nearWord }
                    .min { $0.0 < $1.0 }
                return nearest?.1
            }
        } else {
            sides = islands.map { island in
                let span = span(island)
                if span.upperBound <= boundary.time { return false }
                if span.lowerBound >= boundary.time { return true }
                return boundary.time - span.lowerBound < span.upperBound - boundary.time
            }
        }

        // The pauses between the last island before and the first after. A
        // pause is named by the island after it (islands.count: after them all).
        let firstAfter = sides.firstIndex { $0 == true }
        let lastBefore = sides.indices.last { sides[$0] == false && $0 < (firstAfter ?? islands.count) }
        let candidates: [Int]
        switch (lastBefore, firstAfter) {
        case let (low?, high?): candidates = Array((low + 1)...high)
        case let (low?, nil): candidates = [low + 1]
        case let (nil, high?): candidates = [high]
        case (nil, nil): return .failure(.init(.noSpeech))
        }
        // Only what the clip plays: a pause in the file past the clip's end
        // is under another clip's sound on the timeline.
        let pauses = candidates.compactMap { index in
            pause(before: index, islands, near, placer).flatMap(boundary.played).map { (index: index, pause: $0) }
        }
        guard let best = pauses.min(by: { distance($0.pause, boundary.time...boundary.time) < distance($1.pause, boundary.time...boundary.time) }),
              distance(best.pause, boundary.time...boundary.time) <= slack + 1e-9 else {
            return .failure(.init(.runsOn))
        }
        // Sound no word claims, in the stretch, that has to stay because a
        // word that stays is on the far side of it.
        let kept = orphans.sorted().filter { edge == .start ? $0 < best.index : $0 >= best.index }.map { span(islands[$0]) }
            .filter { island in boundary.inStretch(island, edge: edge) && (boundary.within.map { island.overlaps($0) } ?? true) }
        if !kept.isEmpty { missed[edge] = kept }
        return .success(best.pause)
    }

    /// The pause before island `index` (or after them all), in media time,
    /// when it's whole: not running out of the frames read into sound.
    static func pause(before index: Int, _ islands: [Island], _ near: CutPlacer.Around, _ placer: CutPlacer) -> ClosedRange<Double>? {
        let step = SpeechEnergy.frameSeconds
        func time(_ frame: Int) -> Double { placer.energy.start + Double(frame) * step }
        let low: Int, high: Int
        if index == 0 {
            if islands.first?.openStart == true { return nil }
            low = near.frames.lowerBound
        } else {
            if islands[index - 1].openEnd { return nil }
            low = islands[index - 1].end
        }
        if index == islands.count {
            high = near.frames.upperBound
        } else {
            if islands[index].openStart { return nil }
            high = islands[index].start
        }
        return high >= low ? time(low)...time(high) : nil
    }

    /// For a false start with no pause round it: the last pause inside it
    /// (at its end), or the first (at its start), short of `limit`, the
    /// other edge.
    static func insidePause(_ placer: CutPlacer, _ boundary: Boundary, edge: CutPlan.Edge, limit: Double) -> ClosedRange<Double>? {
        let near = placer.around(boundary.time)
        let islands = islands(placer, near)
        let pauses = (0...islands.count).compactMap { pause(before: $0, islands, near, placer).flatMap(boundary.played) }
        // Long enough to hold the join's least keep either side.
        let room = minimumTail + minimumLead
        switch edge {
        case .end:
            return pauses.last { $0.upperBound <= boundary.time + 1e-9 && $0.lowerBound > limit && $0.upperBound - $0.lowerBound >= min(room, CutAudit.minPause) }
        case .start:
            return pauses.first { $0.lowerBound >= boundary.time - 1e-9 && $0.upperBound < limit && $0.upperBound - $0.lowerBound >= min(room, CutAudit.minPause) }
        }
    }

    /// The cut words a false start's pause brings back, or the stretch of
    /// sound when there's no transcript.
    static func broughtBack(_ boundary: Boundary, pause: ClosedRange<Double>, edge: CutPlan.Edge) -> [ClosedRange<Double>] {
        let mid = { (word: ClosedRange<Double>) in (word.lowerBound + word.upperBound) / 2 }
        switch edge {
        case .end:
            guard boundary.heard else { return [pause.upperBound...max(pause.upperBound, boundary.time)] }
            return boundary.before.filter { mid($0) > pause.upperBound }
        case .start:
            guard boundary.heard else { return [min(pause.lowerBound, boundary.time)...pause.lowerBound] }
            return boundary.after.filter { mid($0) < pause.lowerBound }
        }
    }

    struct ProblemError: Error {
        var problem: CutPlan.Problem
        init(_ problem: CutPlan.Problem) { self.problem = problem }
    }
}

private extension Result where Failure == CutPlanner.ProblemError {
    var problemValue: CutPlan.Problem? {
        if case .failure(let error) = self { return error.problem }
        return nil
    }
}
