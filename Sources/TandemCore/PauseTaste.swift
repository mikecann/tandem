import Foundation

// How long Mike likes his pauses, learned from the ones he trims himself.
//
// On the Examples Page video (19 Nov 2026) he cut back three pauses the
// agent had kept and flagged three more as "awkward silence": "I have to
// keep telling you about these silences. Should we make something in
// tandem so that you can learn from it... I make the tweaks and then you
// learn the patterns that I'm employing." Every trim he makes is already
// in each project's edit history, so Tandem reads the silence either side
// of each one (`TandemService.learnPauses`) and keeps them here: what each
// pause was, and what he left. `tandem check` then flags a pause longer
// than he leaves, and the fix tightens it to what he usually leaves.

/// One pause Mike trimmed himself: the silence as he hears it before and
/// after (`GapSound.silence`), and the words either side.
public struct PauseTrim: Codable, Equatable, Sendable {
    /// The project's ID, or its path when it has none.
    public var project: String
    public var name: String
    /// The revision of his last edit in the trim.
    public var revision: Int
    public var date: Date
    /// Where the pause is on the timeline after his trim.
    public var at: Time
    public var before: String
    public var after: String
    /// What the pause follows (`SpokenPause.kind`).
    public var kind: SpokenPause.Kind
    /// The silence before his trim and after it, seconds.
    public var was: Double
    public var left: Double

    public init(project: String, name: String, revision: Int, date: Date, at: Time, before: String, after: String, kind: SpokenPause.Kind, was: Double, left: Double) {
        self.project = project
        self.name = name
        self.revision = revision
        self.date = date
        self.at = at
        self.before = before
        self.after = after
        self.kind = kind
        self.was = was
        self.left = left
    }
}

extension SpokenPause.Kind: Codable {}

/// A pause Mike left a comment on as too long ("too much silence at the
/// end here", "micropause mid-sentence here, get rid of that"), with its
/// silence as he heard it then. He trims few pauses himself and comments
/// on many (7 on the Convex Auth v2 cut, none trimmed), so these set the
/// line from which a pause is long as much as his trims do.
public struct PauseComplaint: Codable, Equatable, Sendable {
    public var project: String
    public var name: String
    /// The revision that added the comment, and the comment's ID.
    public var revision: Int
    public var comment: String
    public var date: Date
    public var at: Time
    public var text: String
    public var before: String
    public var after: String
    public var kind: SpokenPause.Kind
    /// The silence he heard there, seconds.
    public var silence: Double

    public init(project: String, name: String, revision: Int, comment: String, date: Date, at: Time, text: String, before: String, after: String, kind: SpokenPause.Kind, silence: Double) {
        self.project = project
        self.name = name
        self.revision = revision
        self.comment = comment
        self.date = date
        self.at = at
        self.text = text
        self.before = before
        self.after = after
        self.kind = kind
        self.silence = silence
    }
}

/// Every pause Mike has trimmed, and the rule for each kind of pause that
/// comes from them.
public struct PauseTaste: Codable, Equatable, Sendable {
    public var trims: [PauseTrim]
    public var complaints: [PauseComplaint]
    /// The last revision of each project already read (by `PauseTrim.project`),
    /// so a project's history is only read from there on.
    public var learned: [String: Int]

    public init(trims: [PauseTrim] = [], complaints: [PauseComplaint] = [], learned: [String: Int] = [:]) {
        self.trims = trims
        self.complaints = complaints
        self.learned = learned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trims = try c.decodeIfPresent([PauseTrim].self, forKey: .trims) ?? []
        complaints = try c.decodeIfPresent([PauseComplaint].self, forKey: .complaints) ?? []
        learned = try c.decodeIfPresent([String: Int].self, forKey: .learned) ?? [:]
    }

    /// How long a pause of a kind should be, and from when it's too long.
    public struct Rule: Equatable, Sendable {
        public var kind: SpokenPause.Kind
        /// What Mike leaves: the middle of his trims' lengths, or the
        /// usual when he hasn't trimmed enough of them.
        public var leave: Double
        /// A pause this long or longer is one he'd trim.
        public var flag: Double
        /// How many of his trims it comes from: under `fewest`, the usual.
        public var trims: Int
        /// How many of his comments brought the flag down.
        public var complaints: Int = 0
        public var learned: Bool { trims >= PauseTaste.fewest }
    }

    /// Below this many trims of a kind, the usual rule holds.
    public static let fewest = 5

    /// The usual, from his trims before this was kept (the Threadbear
    /// launch landed at 0.1, 0.18 and 0.35 s; the Examples Page at 0.28 s
    /// after "Savages, right?") and the skill's pause rules. A flag is a
    /// little over what he leaves, so a pause is flagged only when he'd
    /// hear it as long.
    public static let usual: [SpokenPause.Kind: (leave: Double, flag: Double)] = [
        .mid: (0.12, 0.25),
        .comma: (0.2, 0.4),
        .sentence: (0.35, 0.6),
    ]

    /// How far over what he leaves a pause is flagged: the trims he made
    /// spread about this much either side of their middle, and the
    /// Examples Page ones he flagged were twice what he leaves.
    public static let flagOver = 1.6
    /// And never less than this over it: under a sixth of a second more
    /// is hard to hear.
    public static let flagMargin = 0.15

    /// A pause he left this long or longer is a beat he kept on purpose
    /// (the eye-shift on the Examples Page, cut from 2.7 s to 1.2 s), not
    /// the length he likes for its kind; and the transcript's punctuation
    /// can't say a beat's kind ("out. | and if you" reads as mid-sentence).
    public static let beatFrom = 0.8

    /// The beats he kept, cut back or not.
    public var beats: [PauseTrim] { trims.filter { $0.left >= Self.beatFrom } }

    /// The rule for `kind`, from the pauses he shortened to under a beat;
    /// then a pause as short as one he commented on as too long is long
    /// too (a little under it), though never within `complaintMargin` of
    /// what he leaves: a comment can land by a pause other than the one he
    /// meant.
    public func rule(for kind: SpokenPause.Kind) -> Rule {
        let usual = Self.usual[kind] ?? (0.35, 0.6)
        let lengths = trims.filter { $0.kind == kind && $0.left < $0.was && $0.left < Self.beatFrom }.map(\.left).sorted()
        var rule: Rule
        if lengths.count >= Self.fewest {
            let leave = lengths[lengths.count / 2]
            rule = Rule(kind: kind, leave: leave, flag: max(leave * Self.flagOver, leave + Self.flagMargin), trims: lengths.count)
        } else {
            rule = Rule(kind: kind, leave: usual.leave, flag: usual.flag, trims: lengths.count)
        }
        let heard = complaints.filter { $0.kind == kind && $0.silence >= rule.leave + Self.complaintMargin && $0.silence < Self.beatFrom }
        if let shortest = heard.map(\.silence).min(), shortest - Self.complaintUnder < rule.flag {
            rule.flag = max(rule.leave + Self.complaintMargin, shortest - Self.complaintUnder)
        }
        rule.complaints = heard.count
        return rule
    }

    /// A pause he called too long brings the flag to this much under it.
    public static let complaintUnder = 0.02
    /// And never nearer what he leaves than this.
    public static let complaintMargin = 0.08

    public var rules: [Rule] { [SpokenPause.Kind.mid, .comma, .sentence].map(rule(for:)) }

    /// Adds `found` and `heard` from `project`, read up to `revision`, in
    /// place of any already kept from the same edits and comments.
    public mutating func add(_ found: [PauseTrim], complaints heard: [PauseComplaint] = [], project: String, through revision: Int) {
        let revisions = Set(found.map(\.revision))
        trims.removeAll { $0.project == project && revisions.contains($0.revision) }
        trims += found
        trims.sort { ($0.date, $0.revision) < ($1.date, $1.revision) }
        let ids = Set(heard.map(\.comment))
        complaints.removeAll { $0.project == project && ids.contains($0.comment) }
        complaints += heard
        complaints.sort { ($0.date, $0.revision) < ($1.date, $1.revision) }
        learned[project] = max(learned[project] ?? 0, revision)
    }
}
