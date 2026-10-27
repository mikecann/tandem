import Foundation
import TandemCore

// MARK: - handback

/// What an agent asks Mike to look at when it hands a round back: the few
/// places that carry the round's risk, out of the hundreds of clips it
/// may have touched. Tandem's review chip walks him through them first,
/// before the rest of the highlights. Given `notes`, they take the place
/// of what this agent handed back before; without, it lists what's still
/// waiting, so the next round knows what he watched and what he didn't.
public struct HandbackRequest: ServiceCall {
    public static let operation = ServiceOperation.handback
    public var notes: [HandbackNote]?

    public init(notes: [HandbackNote]? = nil) {
        self.notes = notes
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
}

extension HandbackResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if let recorded {
            lines.append("Handed back \(recorded == 1 ? "1 thing" : "\(recorded) things") to look at (revision \(revision)). Mike's review chip in Tandem reads \"\(recorded) to look at\": ] steps him through them first, in timeline order, playing each stretch, then through the rest of your highlighted changes. One goes once he's watched its stretch; Mark reviewed clears them all. Tell him in a line that Tandem will walk him through them, rather than listing the times again.")
            if recorded > 7 { lines.append("That's a lot for a walkthrough: two to five is the idea, the places that carry the round's risk.") }
        } else if notes.isEmpty {
            lines.append("Nothing handed back is waiting (revision \(revision)): Mike has watched them all or marked them reviewed, or nothing was handed back. Hand back with tandem handback '[{\"at\": \"2:45\", \"to\": \"3:10\", \"name\": \"...\"}]' before your final message.")
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
        if let given = request.notes {
            let notes = try given.map { try Self.reviewNote($0, author: context.author, revision: revision, duration: project.duration) }
            session.review.handBack(notes, by: context.author)
            recorded = notes.count
        } else {
            recorded = nil
        }
        let comments = project.comments
        let waiting = session.review.log.notes.map { note -> LookHere in
            let near = comments.filter { $0.time >= note.start - Self.noteCommentReach && $0.time <= note.end + Self.noteCommentReach }
            return LookHere(note, comments: near.map { NoteComment(id: $0.id, time: $0.time, text: $0.name) })
        }
        return HandbackResult(revision: revision, recorded: recorded, notes: waiting)
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
