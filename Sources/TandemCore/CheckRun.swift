import Foundation

// Every `tandem check` run, kept in the edit history, and the gate on
// `tandem handback` that reads them.
//
// The skill told agents to run `check --changed` (and `check --cuts
// --listen` after cutting the take) and to go through every note before
// handing back, and in Mike's last eight videos they often didn't: his
// comments stopped coming back once Tandem itself checked for something,
// and kept coming back while the rule only lived in the skill. Export
// already refuses a final preset while agent edits wait for review, so a
// hand-back now refuses until the checks have run on what it hands back.

/// One `tandem check`, as the edit history keeps it: what it read, how,
/// and what it found.
public struct CheckRun: Codable, Equatable, Sendable {
    /// What it looked at.
    public enum Scope: String, Codable, Sendable {
        /// The whole timeline.
        case timeline
        /// A stretch given with from and to.
        case stretch
        /// The stretches agents changed that wait for Mike's review
        /// (`--changed`).
        case changed
    }

    /// How it looked.
    public enum Mode: String, Codable, Sendable {
        /// `--quick`: read the timeline, rendered nothing.
        case quick
        /// Rendered the frames: what `check` does by default.
        case full
        /// `--cuts`: read the voice's levels at each cut.
        case cuts
        /// `--cuts --listen`: also heard each join.
        case listen
        /// `--privacy`: read the text on screen.
        case privacy
    }

    /// A note it left, as the gate matches answers to it.
    public struct Note: Codable, Equatable, Sendable {
        /// `CheckProblem.Kind`'s name, like `deadAir`.
        public var kind: String
        public var start: Time
        public var end: Time
        /// The note's first sentence.
        public var message: String

        public init(kind: String, start: Time, end: Time, message: String) {
            self.kind = kind
            self.start = start
            self.end = end
            self.message = message
        }

        public init(_ problem: CheckProblem) {
            self.init(kind: problem.kind.rawValue, start: problem.start, end: problem.end, message: Self.short(problem.message))
        }

        /// The first sentence, at most about 140 characters: enough to say
        /// which note it is in a refusal, without the whole paragraph.
        static func short(_ message: String) -> String {
            let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
            var end = line.endIndex
            var index = line.startIndex
            while index < line.endIndex {
                let next = line.index(after: index)
                if ".!?".contains(line[index]), next == line.endIndex || line[next] == " " {
                    // "0.80 s" and "e.g." don't end a sentence; a full stop
                    // with a space after does.
                    end = next
                    break
                }
                index = next
            }
            let sentence = String(line[..<end])
            return sentence.count <= 140 ? sentence : String(sentence.prefix(139)) + "…"
        }
    }

    public var scope: Scope
    public var mode: Mode
    /// The stretches it checked, in the timeline's times at the revision
    /// it read.
    public var ranges: [TimeRange]
    public var problems: Int
    public var notes: [Note]
    /// The agent batches waiting for review that it covered, by the
    /// revision each made (`ReviewEntry.revision`): with `full`, every
    /// change in them lay in the stretches checked; with `listen` or
    /// `cuts`, every cut they made in the take did. Kept so the gate needn't
    /// work out where those stretches are now, after Mike's own edits.
    public var covers: [Int]

    public init(scope: Scope, mode: Mode, ranges: [TimeRange], problems: Int, notes: [Note], covers: [Int] = []) {
        self.scope = scope
        self.mode = mode
        self.ranges = ranges
        self.problems = problems
        self.notes = notes
        self.covers = covers
    }

    /// The way it was asked for, as the history lists it:
    /// "check --changed --cuts --listen".
    public var command: String {
        var words = ["check"]
        switch scope {
        case .timeline: break
        case .changed: words.append("--changed")
        case .stretch:
            if let first = ranges.first { words.append("--from \(first.start) --to \(first.end)") }
        }
        switch mode {
        case .full: break
        case .quick: words.append("--quick")
        case .cuts: words.append("--cuts")
        case .listen: words.append("--cuts --listen")
        case .privacy: words.append("--privacy")
        }
        return words.joined(separator: " ")
    }

    /// The agent batches whose changes all lie in `ranges`, by revision:
    /// with `takeCutsOnly`, the batches that cut the take, judged by their
    /// cuts alone.
    public static func covered(by ranges: [TimeRange], log: ReviewLog, in project: Project, takeCutsOnly: Bool) -> [Int] {
        let slack = Time(seconds: 0.001)
        func inside(_ start: Time, _ end: Time) -> Bool {
            ranges.contains { $0.start - slack <= start && end <= $0.end + slack }
        }
        if takeCutsOnly {
            return HandbackGate.takeCuts(log, in: project).filter { _, times in times.allSatisfy { inside($0, $0) } }.keys.sorted()
        }
        var spans: [Int: [(Time, Time)]] = [:]
        for change in log.changes(in: project) { spans[change.entry.revision, default: []].append((change.start, change.end)) }
        return spans.filter { _, list in list.allSatisfy { inside($0.0, $0.1) } }.keys.sorted()
    }
}

/// What `tandem handback` asks of a round before it hands it back with
/// things to look at: the checks ran on it since the agents last edited,
/// found nothing wrong, and every note they left is answered.
public enum HandbackGate {
    /// An agent's answer to a note it keeps: the note's kind, a time in it
    /// (within about a second of its stretch), and why it stays.
    public struct Answer: Equatable, Sendable {
        public var kind: String
        public var at: Time
        public var why: String

        public init(kind: String, at: Time, why: String) {
            self.kind = kind
            self.at = at
            self.why = why
        }
    }

    /// How far from a note's stretch an answer's time can be and still be
    /// about it: agents copy the time off the check's line, rounded.
    public static let answerReach = Time(seconds: 1.1)

    /// Notes that say the check found nothing wrong, so they need no answer.
    static let needsNoAnswer: Set<String> = [CheckProblem.Kind.heardWhole.rawValue]

    public enum Need: Equatable, Sendable {
        /// No rendering check covers these batches since the agents' last
        /// edit. `stale` is the revision of a check that did, before it.
        case render(uncovered: [Int], stale: Int?)
        /// The newest rendering check that covers them found problems.
        case renderProblems(count: Int, revision: Int)
        /// No `--cuts --listen` check covers these batches' cuts in the take.
        case listen(uncovered: [Int], stale: Int?)
        case listenProblems(count: Int, revision: Int)
    }

    public struct Verdict: Equatable, Sendable {
        /// The agent batches waiting for review, by revision.
        public var waiting: [Int] = []
        /// What's not done yet, in the order to do it.
        public var needs: [Need] = []
        /// The checks' notes with no answer.
        public var unanswered: [CheckRun.Note] = []
        /// How many notes the answers covered.
        public var answered = 0
        /// Answers that match no note the checks left.
        public var unmatched: [Answer] = []
        /// The newest agent edit after the checks the gate looked at, when
        /// there is one: why an earlier check doesn't count.
        public var lastAgentEdit: Int?

        public var passes: Bool { needs.isEmpty && unanswered.isEmpty }
    }

    /// The cuts each waiting batch made in the take, where they are now:
    /// a ripple delete or trim on a `cut` track takes a stretch out of it.
    public static func takeCuts(_ log: ReviewLog, in project: Project) -> [Int: [Time]] {
        guard !log.entries.isEmpty else { return [:] }
        let take = Set(project.allTracks.filter { $0.rippleMode == .cut }.map(\.id))
        var found: [Int: [Time]] = [:]
        for entry in log.entries {
            for removal in entry.removals where removal.duration > .zero && take.contains(removal.trackID) {
                found[entry.revision, default: []].append(removal.time(in: project))
            }
        }
        return found
    }

    /// Whether `record` is an agent's change to what the checks read. Mike's
    /// edits and Tandem's own (new media found) aren't, and nor is an
    /// agent's edit that only moved markers (a comment resolved) or added
    /// media without placing it.
    static func isAgentEdit(_ record: HistoryRecord) -> Bool {
        guard record.kind.changesProject, record.kind != .opened, EditAuthor.isAgent(record.author) else { return false }
        if record.place != nil { return true }
        guard let summary = record.summary else { return false }
        return summary.components(separatedBy: ", ").contains { part in part != "markers" && !part.hasSuffix("media added") }
    }

    /// Judges a hand-back. `records` is the edit history, oldest first, with
    /// the checks in it. `cutsMatter` is false when nothing in the edit is
    /// speech, so a cut in the take has no words to clip.
    public static func judge(records: [HistoryRecord], log: ReviewLog, project: Project, answers: [Answer], cutsMatter: Bool = true) -> Verdict {
        var verdict = Verdict()
        let waiting = Set(log.changes(in: project).map(\.entry.revision))
        verdict.waiting = waiting.sorted()
        guard !waiting.isEmpty else { return verdict }
        let cutting = cutsMatter ? Set(takeCuts(log, in: project).keys).intersection(waiting) : []

        // Checks count from the agents' last edit on. An `opened` record
        // means the project changed somewhere that kept no history, so
        // nothing before it counts either.
        var since = Int.min
        for record in records where record.kind == .opened || isAgentEdit(record) {
            since = max(since, record.revision)
            if record.kind != .opened { verdict.lastAgentEdit = max(verdict.lastAgentEdit ?? record.revision, record.revision) }
        }
        let checks = records.compactMap { record -> (revision: Int, run: CheckRun)? in
            guard record.kind == .check, let run = record.check else { return nil }
            return (record.revision, run)
        }
        let current = checks.filter { $0.revision >= since }.reversed()
        let earlier = checks.filter { $0.revision < since }

        /// The newest checks of `modes` that together cover `wanted`, and
        /// what's still missing.
        func cover(_ wanted: Set<Int>, modes: Set<CheckRun.Mode>) -> (chosen: [CheckRun], need: Need?) {
            guard !wanted.isEmpty else { return ([], nil) }
            var left = wanted
            var chosen: [CheckRun] = []
            for check in current where modes.contains(check.run.mode) && check.run.problems == 0 {
                let mine = left.intersection(check.run.covers)
                guard !mine.isEmpty else { continue }
                chosen.append(check.run)
                left.subtract(mine)
                if left.isEmpty { return (chosen, nil) }
            }
            let listening = modes.contains(.listen)
            if let failed = current.first(where: { modes.contains($0.run.mode) && $0.run.problems > 0 && !left.isDisjoint(with: $0.run.covers) }) {
                return (chosen, listening ? .listenProblems(count: failed.run.problems, revision: failed.revision) : .renderProblems(count: failed.run.problems, revision: failed.revision))
            }
            let stale = earlier.last { modes.contains($0.run.mode) && !left.isDisjoint(with: $0.run.covers) }?.revision
            return (chosen, listening ? .listen(uncovered: left.sorted(), stale: stale) : .render(uncovered: left.sorted(), stale: stale))
        }

        let render = cover(waiting, modes: [.full])
        let listen = cover(cutting, modes: [.listen])
        verdict.needs = [render.need, listen.need].compactMap { $0 }
        guard verdict.needs.isEmpty else { return verdict }

        // Every note the checks relied on, once: two checks of the same
        // stretch leave the same notes.
        var notes: [CheckRun.Note] = []
        for note in (render.chosen + listen.chosen).flatMap(\.notes) where !needsNoAnswer.contains(note.kind) {
            if !notes.contains(where: { $0.kind == note.kind && $0.start == note.start && $0.end == note.end }) { notes.append(note) }
        }
        var used = Set<Int>()
        for note in notes {
            let answer = answers.indices.first { index in
                let given = answers[index]
                return sameKind(given.kind, note.kind) && note.start - answerReach <= given.at && given.at <= note.end + answerReach
                    && !given.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if let answer {
                used.insert(answer)
                verdict.answered += 1
            } else {
                verdict.unanswered.append(note)
            }
        }
        verdict.unanswered.sort { ($0.start, $0.kind) < ($1.start, $1.kind) }
        verdict.unmatched = answers.indices.filter { !used.contains($0) }.map { answers[$0] }
        return verdict
    }

    /// "deadAir", "dead air" and "Dead-Air" are the same kind.
    static func sameKind(_ given: String, _ kind: String) -> Bool {
        func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return plain(given) == plain(kind)
    }
}
