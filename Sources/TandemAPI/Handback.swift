import Foundation
import TandemCore

// MARK: - handback

/// What an agent asks Mike to look at when it hands a round back: the few
/// places that carry the round's risk, out of the hundreds of clips it
/// may have touched. Tandem's review chip walks him through them first,
/// before the rest of the highlights. Given `notes`, they take the place
/// of what this agent handed back before; without, it lists what's still
/// waiting, so the next round knows what he watched and what he didn't.
///
/// Handing back with notes is refused until the checks have run on the
/// round since the agents last edited it and every note they left is
/// answered (`HandbackGate`): `reasons` answers the notes that stay, and
/// `unchecked` hands back anyway, with the reason kept in the history.
public struct HandbackRequest: ServiceCall {
    public static let operation = ServiceOperation.handback
    public var notes: [HandbackNote]?
    /// Why each note the checks left stays as it is.
    public var reasons: [HandbackReason]?
    /// Hands back without the checks, for this reason, which goes in the
    /// history. Tell Mike so in your message.
    public var unchecked: String?

    public init(notes: [HandbackNote]? = nil, reasons: [HandbackReason]? = nil, unchecked: String? = nil) {
        self.notes = notes
        self.reasons = reasons
        self.unchecked = unchecked
    }

    public func run(on service: TandemService, context: CallContext) async throws -> HandbackResult {
        try service.handback(self, context: context)
    }
}

/// One thing to look at, as an agent gives it.
public struct HandbackNote: Codable, Equatable, Sendable {
    /// Where the stretch starts.
    public var at: Time
    /// Where it ends. Default 5 s after `at`.
    public var to: Time?
    /// A few words on what's there, like a commit subject: at most 40
    /// characters, so the card reads at a glance.
    public var name: String
    /// One short line more, at most 80 characters: the trade-off, what to
    /// listen for, or the question.
    public var note: String?
    /// True when Mike's answer is wanted (he'll leave a comment there).
    public var question: Bool?

    public init(at: Time, to: Time? = nil, name: String, note: String? = nil, question: Bool? = nil) {
        self.at = at
        self.to = to
        self.name = name
        self.note = note
        self.question = question
    }

    private enum CodingKeys: String, CodingKey { case at, to, name, note, question }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let at = try c.decodeTime(.at) else {
            throw DecodingError.keyNotFound(CodingKeys.at, DecodingError.Context(codingPath: c.codingPath, debugDescription: "Each thing to look at needs `at`, where it starts."))
        }
        self.at = at
        to = try c.decodeTime(.to)
        name = try c.decode(String.self, forKey: .name)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        question = try c.decodeIfPresent(Bool.self, forKey: .question)
    }
}

/// Why a note `tandem check` left stays: its kind (`deadAir`), a time in
/// its stretch, and the reason.
public struct HandbackReason: Codable, Equatable, Sendable {
    public var kind: String
    public var at: Time
    public var why: String

    public init(kind: String, at: Time, why: String) {
        self.kind = kind
        self.at = at
        self.why = why
    }

    private enum CodingKeys: String, CodingKey { case kind, at, why }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        guard let at = try c.decodeTime(.at) else {
            throw DecodingError.keyNotFound(CodingKeys.at, DecodingError.Context(codingPath: c.codingPath, debugDescription: "Each reason needs `at`, a time in the note's stretch."))
        }
        self.at = at
        why = try c.decode(String.self, forKey: .why)
    }
}

/// One thing to look at, as it waits in the review log.
public struct LookHere: Codable, Equatable, Sendable {
    public var id: String
    public var author: String
    public var date: Date
    /// The revision it was handed back at.
    public var revision: Int
    public var start: Time
    public var end: Time
    public var name: String
    public var note: String?
    public var question: Bool
    /// Mike's comments in or just beside the stretch: his answer, when it
    /// was a question.
    public var comments: [NoteComment]

    init(_ note: ReviewNote, comments: [NoteComment]) {
        id = note.id
        author = note.author
        date = note.date
        revision = note.revision
        start = note.start
        end = note.end
        name = note.name
        self.note = note.note
        question = note.question
        self.comments = comments
    }
}

public struct NoteComment: Codable, Equatable, Sendable {
    public var id: String
    public var time: Time
    public var text: String
}

public struct HandbackResult: Codable, Sendable {
    public var revision: Int
    /// How many were just handed back, when some were.
    public var recorded: Int?
    /// What's still waiting for Mike to look at, in timeline order.
    public var notes: [LookHere]
    /// How many of the checks' notes the reasons answered.
    public var answered: Int?
    /// Reasons that matched no note the checks left, as "deadAir at 01:00.000".
    public var unmatched: [String]?
    /// The checks' problems the reasons called false alarms, each as
    /// "kind at time: why".
    public var overruled: [String]?
    /// Handed back without the checks, for this reason.
    public var unchecked: String?
    /// Why Mike may not see it: nothing has the project open in the app,
    /// or the app is an older build (`AppBuild.noting`). Added by the
    /// command that asked, since an old app serving it couldn't know.
    public var warnings: [String]?
}

extension HandbackResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if let recorded {
            lines.append("Handed back \(recorded == 1 ? "1 thing" : "\(recorded) things") to look at (revision \(revision)). Mike's review chip in Tandem reads \"\(recorded) to look at\": ] steps him through them first, in timeline order, playing each stretch, then through the rest of your highlighted changes. One goes once he's watched its stretch; Mark reviewed clears them all. Tell him in a line that Tandem will walk him through them, rather than listing the times again.")
            if recorded > 7 { lines.append("That's a lot for a walkthrough: two to five is the idea, the places that carry the round's risk.") }
            if let unchecked {
                lines.append("Handed back without Tandem's checks (\"\(CommentEdits.oneLine(unchecked))\"), which the history keeps. Say so to Mike in your message: that this round wasn't checked, and why.")
            }
            if let overruled, !overruled.isEmpty {
                let count = overruled.count
                lines.append("Your reasons answered \(count == 1 ? "a problem" : "\(count) problems") the checks found, as false alarms, which the history keeps: \(overruled.map(CommentEdits.oneLine).joined(separator: "; ")). Tell Mike in your message which ones and why, so he can look.")
            }
            if let answered, answered > 0 {
                lines.append("Your reasons answered \(answered == 1 ? "the 1 note" : "the \(answered) notes") the checks left.")
            }
            if let unmatched, !unmatched.isEmpty {
                lines.append("These reasons matched no note the checks left, so they did nothing: \(unmatched.joined(separator: "; ")).")
            }
        } else if notes.isEmpty {
            lines.append("Nothing handed back is waiting (revision \(revision)): Mike has watched them all or marked them reviewed, or nothing was handed back. Hand back with tandem handback '[{\"at\": \"2:45\", \"to\": \"3:10\", \"name\": \"...\"}]' before your final message.")
            for warning in warnings ?? [] { lines.append("Warning: \(warning)") }
            return lines.joined(separator: "\n")
        } else {
            let waiting = notes.count == 1 ? "1 thing" : "\(notes.count) things"
            lines.append("\(waiting) still waiting for Mike to look at (revision \(revision)), earliest first. Each goes once he's watched its stretch, so these are what he hasn't got to yet:")
        }
        for note in notes {
            lines.append("")
            let kind = note.question ? "question" : "look"
            lines.append("\(note.id)  \(note.start)-\(note.end)  \(kind) from \(note.author): \(CommentEdits.oneLine(note.name))")
            if let more = note.note, !more.isEmpty { lines.append("  note: \(CommentEdits.oneLine(more))") }
            for comment in note.comments {
                lines.append("  Mike's comment at \(comment.time): \"\(CommentEdits.oneLine(comment.text))\"")
            }
        }
        for warning in warnings ?? [] { lines.append("Warning: \(warning)") }
        return lines.joined(separator: "\n")
    }
}

extension TandemService {
    /// Half a second either side of a note counts as beside it... and a
    /// couple more, since Mike comments where he paused, not on the frame.
    static let noteCommentReach = Time(seconds: 2)

    func handback(_ request: HandbackRequest, context: CallContext) throws -> HandbackResult {
        let (project, revision) = coordinator.snapshot()
        let recorded: Int?
        var answered: Int?
        var unmatched: [String]?
        var uncheckedReason: String?
        var overruled: [String]?
        if let given = request.notes {
            let notes = try given.map { try Self.reviewNote($0, author: context.author, revision: revision, duration: project.duration) }
            // Withdrawing (an empty list) hands nothing back, so it isn't
            // gated; nor is listing what's waiting.
            if !notes.isEmpty {
                if let why = request.unchecked {
                    let reason = CommentEdits.oneLine(why).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !reason.isEmpty else {
                        throw ServiceError(.badRequest, "--unchecked needs the reason you're handing back without the checks, for Mike and the history.")
                    }
                    uncheckedReason = reason
                } else {
                    let verdict = handbackVerdict(request.reasons ?? [], project: project)
                    if let refusal = Self.refusal(verdict, log: session.review.log) { throw ServiceError(.invalid, refusal) }
                    answered = verdict.answered
                    overruled = verdict.overruled.isEmpty ? nil : verdict.overruled
                    unmatched = verdict.unmatched.isEmpty ? nil : verdict.unmatched.map { "\($0.kind) at \($0.at)" }
                }
            }
            session.review.handBack(notes, by: context.author)
            // The review log keeps only the latest handback; the history
            // keeps each one, which is where `tandem rounds` finds them.
            // One row per hand-back, with the reason when it skipped the
            // checks. Withdrawing (an empty list) isn't one: `tandem rounds`
            // would read it as a round handed back.
            if !notes.isEmpty {
                session.history.handedBack(by: context.author, count: notes.count, unchecked: uncheckedReason, overruled: overruled)
            }
            recorded = notes.count
        } else {
            recorded = nil
        }
        let comments = project.comments
        let waiting = session.review.log.notes.map { note -> LookHere in
            let near = comments.filter { $0.time >= note.start - Self.noteCommentReach && $0.time <= note.end + Self.noteCommentReach }
            return LookHere(note, comments: near.map { NoteComment(id: $0.id, time: $0.time, text: $0.name) })
        }
        return HandbackResult(
            revision: revision, recorded: recorded, notes: waiting, answered: answered, unmatched: unmatched, overruled: overruled,
            unchecked: recorded.map { $0 > 0 } == true ? request.unchecked.map { CommentEdits.oneLine($0).trimmingCharacters(in: .whitespacesAndNewlines) } : nil
        )
    }

    /// The gate's view of the round as it stands (`HandbackGate.judge`).
    func handbackVerdict(_ reasons: [HandbackReason], project: Project) -> HandbackGate.Verdict {
        HandbackGate.judge(
            records: session.history.records(), log: session.review.log, project: project,
            answers: reasons.map { HandbackGate.Answer(kind: $0.kind, at: $0.at, why: $0.why) },
            cutsMatter: !TranscriptTools.speechTracks(project).isEmpty
        )
    }

    /// A check from before 18 Nov 2026 counted its problems without keeping
    /// them, so a reason can't answer one: on the Coordinators video an
    /// agent tried --reason, then handed back --unchecked.
    static let olderCheck = "That check only counted its problems, so --reason can't answer them: run it again, and if one is still a false alarm, answer it with --reason \"<kind> <time> <why>\"."

    /// Why a hand-back is refused, saying exactly what to run, or nil when
    /// it can go. Mike's comments stopped coming back once Tandem checked
    /// for a thing itself, and kept coming back while the rule to check
    /// lived only in the skill, so this is the skill's step 4 enforced.
    static func refusal(_ verdict: HandbackGate.Verdict, log: ReviewLog) -> String? {
        guard !verdict.passes else { return nil }
        let labels = Dictionary(log.entries.map { ($0.revision, $0.label) }, uniquingKeysWith: { a, _ in a })
        func batches(_ revisions: [Int]) -> String {
            var names = revisions.suffix(4).map { revision in labels[revision].map { "\"\(CommentEdits.oneLine($0))\" (r\(revision))" } ?? "r\(revision)" }
            if revisions.count > names.count { names.insert("\(revisions.count - names.count) more", at: 0) }
            return names.joined(separator: ", ")
        }
        func since(_ stale: Int?) -> String {
            guard let stale else { return "" }
            let edit = verdict.lastAgentEdit.map { " at revision \($0)" } ?? ""
            return " The last one (revision \(stale)) ran before an agent's edit\(edit), so it doesn't count."
        }
        var lines: [String] = []
        for need in verdict.needs {
            switch need {
            case .render(let uncovered, let stale):
                let some = uncovered.count < verdict.waiting.count ? " (the checks since the last agent edit missed \(batches(uncovered)))" : ""
                lines.append("Tandem hasn't checked this round since the last agent edit\(some). Run tandem check --changed, fix every problem it finds, then hand back again.\(since(stale))")
            case .renderProblems(let count, let revision):
                // Only a check from before checks kept their problems.
                lines.append("tandem check (revision \(revision)) found \(count == 1 ? "a problem" : "\(count) problems"). Fix \(count == 1 ? "it" : "them"), run tandem check --changed again, then hand back. \(Self.olderCheck)")
            case .listen(let uncovered, let stale):
                lines.append("This round cut the take (\(batches(uncovered))), so also run tandem check --changed --cuts --listen and judge each cut it flags by ear.\(since(stale))")
            case .listenProblems(let count, let revision):
                lines.append("tandem check --cuts --listen (revision \(revision)) found \(count == 1 ? "a problem" : "\(count) problems") at the cuts. Fix \(count == 1 ? "it" : "them") and run it again. \(Self.olderCheck)")
            }
        }
        if !verdict.unansweredProblems.isEmpty {
            let count = verdict.unansweredProblems.count
            lines.append("The checks found \(count == 1 ? "a problem" : "\(count) problems"). Fix each one and check again. If one is a false alarm (look at the frames, or listen with tandem clip, first), say what you saw: --reason \"<kind> <time> <why>\" for it, which the history keeps for Mike:")
            for problem in verdict.unansweredProblems {
                let when = problem.start == problem.end ? "\(problem.start)" : "\(problem.start)-\(problem.end)"
                lines.append("  \(problem.kind)  \(when)  \(problem.message)")
                lines.append("    --reason \"\(problem.kind) \(problem.start) <why>\"")
            }
        }
        if !verdict.unanswered.isEmpty {
            let count = verdict.unanswered.count
            lines.append("The checks left \(count == 1 ? "a note" : "\(count) notes") with no answer. Fix each one (then check again), or say why it stays: --reason \"<kind> <time> <why>\" for each (JSON reasons: [{\"kind\": \"deadAir\", \"at\": \"3:56\", \"why\": \"...\"}]):")
            for note in verdict.unanswered {
                let when = note.start == note.end ? "\(note.start)" : "\(note.start)-\(note.end)"
                lines.append("  \(note.kind)  \(when)  \(note.message)")
                lines.append("    --reason \"\(note.kind) \(note.start) <why>\"")
            }
        }
        lines.append("If the checks can't run here, hand back with --unchecked \"<why>\" (JSON unchecked) and tell Mike so in your message.")
        return "Not handed back. " + lines.joined(separator: "\n")
    }

    /// The card over the viewer has to read at a glance (Mike: "you have to
    /// read so much to understand what it wants"), so the limits are tight
    /// and the command refuses rather than truncating.
    public static let nameLimit = 40
    public static let noteLimit = 80

    /// Checks one thing to look at and gives it its place in the log.
    static func reviewNote(_ given: HandbackNote, author: String, revision: Int, duration: Time, defaultLength: Time = Time(seconds: 5)) throws -> ReviewNote {
        let name = CommentEdits.oneLine(given.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ServiceError(.badRequest, "Each thing to look at needs a name: a few words saying what's there.") }
        guard name.count <= nameLimit else {
            throw ServiceError(.badRequest, "\"\(name)\" is \(name.count) characters. Mike reads the name off a small card at a glance, so keep it to \(nameLimit) (a few words, like \"Angles: ten zooms became two\") and put the rest in note.")
        }
        guard given.at >= .zero else { throw ServiceError(.badRequest, "\"\(name)\" starts before the timeline does (at \(given.at)).") }
        guard given.at <= duration else { throw ServiceError(.badRequest, "\"\(name)\" starts at \(given.at), past the end of the timeline (\(duration)).") }
        var end = given.to ?? min(given.at + defaultLength, max(duration, given.at))
        if let to = given.to, to < given.at { throw ServiceError(.badRequest, "\"\(name)\" ends (\(to)) before it starts (\(given.at)).") }
        end = min(end, max(duration, given.at))
        let note = given.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note, note.count > noteLimit {
            throw ServiceError(.badRequest, "The note on \"\(name)\" is \(note.count) characters. It's one short line under the name (what to listen for, or the trade-off), so keep it to \(noteLimit); the detail belongs in your final message.")
        }
        return ReviewNote(author: author, revision: revision, start: given.at, end: end, name: name, note: note.flatMap { $0.isEmpty ? nil : $0 }, question: given.question ?? false)
    }
}
