import Foundation
import TandemCore

// MARK: - rounds

/// How a video's review went, round by round: when each round was handed
/// back, how many agent edits went into it, what Mike said about it (his
/// comments, with their words), how long he took to start, and how much he
/// fixed himself. Then the whole video, and the comments by theme.
///
/// Before this, the only record of a video's review was the chat, and
/// reading eight videos' chats to learn how they went took seven agents.
/// The numbers say whether a change to the process worked: fewer rounds,
/// fewer comments of a kind, fewer trims Mike made himself.
///
/// It reads the files and opens nothing: the edit history (each edit's
/// author, and from this version on the words of each comment and a row
/// for each handback), plus the backups and the snapshot beside every
/// export, which hold the comments that were on the timeline when they
/// were saved. So it never holds a project the app has open, and writes
/// nothing but the `--log` file.
public enum ReviewRounds {
    /// Agent edits that start within `interjection` of Mike's last action,
    /// with his next no more than `pauseInReview` after it, are a quick fix
    /// made while he watched (he asked in the chat), not a new round.
    static let interjection: TimeInterval = 120
    static let pauseInReview: TimeInterval = 300
    /// Two trims of the take this close in time and place are one fix: a
    /// delete and the close gap after it, or a trim he redid after undoing.
    static let fixGap: TimeInterval = 90
    static let fixReach = Time(seconds: 3)

    public static func read(_ url: URL) throws -> RoundsResult {
        let url = url.standardizedFileURL
        let current: (project: Project, revision: Int)
        do {
            current = try ProjectFile.load(from: url)
        } catch {
            throw ServiceError(.invalid, "\(url.lastPathComponent) couldn't be read as a Tandem project: \(ServiceError.wrap(error).message)")
        }
        let records = EditHistoryLog(url: ProjectFile.historyURL(for: url)).records()
        var snapshots = [Snapshot(revision: current.revision, comments: current.project.comments)]
        for file in snapshotFiles(of: url) {
            guard let light = try? JSONDecoder().decode(SnapshotFile.self, from: Data(contentsOf: file)),
                  light.project.id == nil || light.project.id == current.project.id,
                  let revision = light.revision(in: records) else { continue }
            snapshots.append(Snapshot(revision: revision, comments: light.project.markers.filter { $0.kind == .comment }))
        }
        var result = analyse(records, snapshots: snapshots, takeTracks: takeTracks(current.project))
        result.name = current.project.name
        result.id = current.project.id
        result.path = url.path
        return result
    }

    /// Backups in `.tandem/backups` and the snapshot every export writes
    /// beside itself in `exports/`.
    static func snapshotFiles(of url: URL) -> [URL] {
        let exports = url.deletingLastPathComponent().appendingPathComponent("exports", isDirectory: true)
        let beside = (try? FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil)) ?? []
        return ProjectFile.backups(of: url) + beside.filter { $0.pathExtension == ProjectFile.fileExtension }.sorted { $0.path < $1.path }
    }

    /// The names of the tracks the take is on (camera, screen, voice), which
    /// Mike's trims of the take touch. The privacy track rides the take but
    /// isn't it.
    static func takeTracks(_ project: Project) -> Set<String> {
        Set(project.allTracks.filter { $0.rippleMode == .cut && !Editing.isPrivacyTrack($0) }.map(\.name))
    }

    /// A project file read only for its comments, with the revision it was
    /// saved at. An export's snapshot says 0, so it goes by when the export
    /// started: the last edit before then.
    struct SnapshotFile: Decodable {
        struct Body: Decodable {
            var id: String?
            var markers: [Marker]
            var metadata: [String: String]

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decodeIfPresent(String.self, forKey: .id)
                markers = (try? c.decodeIfPresent([Marker].self, forKey: .markers)) ?? []
                metadata = (try? c.decodeIfPresent([String: String].self, forKey: .metadata)) ?? [:]
            }

            enum CodingKeys: String, CodingKey { case id, markers, metadata }
        }

        var revision: Int
        var project: Body

        func revision(in records: [HistoryRecord]) -> Int? {
            guard let stamp = project.metadata["export.date"] else { return revision }
            guard let date = ISO8601DateFormatter().date(from: stamp) else { return nil }
            return records.last { $0.isChange && $0.date <= date }?.revision
        }
    }

    struct Snapshot {
        var revision: Int
        var comments: [Marker]
    }

    // MARK: Rounds from the history

    /// Who a row is from, as far as rounds go.
    enum Actor {
        case handback, agent, person
    }

    static func actor(_ record: HistoryRecord) -> Actor? {
        if record.kind == .handback { return .handback }
        // Opening and a `tandem check` changed nothing, so neither is anyone's edit.
        if record.kind == .opened || record.kind == .check { return nil }
        if EditAuthor.isAgent(record.author) { return .agent }
        if EditAuthor.isPerson(record.author) { return .person }
        return nil
    }

    static func analyse(_ records: [HistoryRecord], snapshots: [Snapshot], takeTracks: Set<String>) -> RoundsResult {
        let rows = records.filter { actor($0) != nil }
        // Where agents hand back, the handbacks are the rounds; before the
        // first (history from an older Tandem), they're inferred.
        let explicitFrom = rows.firstIndex { $0.kind == .handback }
        var rounds: [RoundBuilder] = []
        var current: RoundBuilder?
        var pending: [HistoryRecord] = []

        func start(_ round: RoundBuilder) {
            if let current { rounds.append(current) }
            current = round
        }

        for (index, row) in rows.enumerated() {
            let explicit = explicitFrom.map { index >= $0 } ?? false
            switch actor(row)! {
            case .handback:
                start(RoundBuilder(handedBack: row.date, revision: row.revision, inferred: false, things: row.handedBack, agentRows: pending))
                pending = []
            case .agent:
                pending.append(row)
            case .person:
                if !pending.isEmpty {
                    if explicit, current != nil {
                        // Edits after the handback while he watches: the
                        // round he's watching carries them.
                        current!.duringReview += pending.count
                    } else if let last = current?.lastPerson,
                              pending[0].date.timeIntervalSince(last) < interjection,
                              row.date.timeIntervalSince(last) <= pauseInReview {
                        current!.duringReview += pending.count
                    } else {
                        let last = pending[pending.count - 1]
                        start(RoundBuilder(handedBack: last.date, revision: last.revision, inferred: true, things: nil, agentRows: pending))
                    }
                    pending = []
                }
                if current == nil {
                    // Mike editing before any agent had: a round of his own.
                    current = RoundBuilder(handedBack: nil, revision: nil, inferred: true, things: nil, agentRows: [])
                }
                current!.add(row, takeTracks: takeTracks)
            }
        }
        var unhanded = 0
        if !pending.isEmpty {
            if explicitFrom != nil {
                // Work since the last handback that hasn't been handed back.
                unhanded = pending.count
            } else {
                let last = pending[pending.count - 1]
                start(RoundBuilder(handedBack: last.date, revision: last.revision, inferred: true, things: nil, agentRows: pending))
            }
        }
        if let current { rounds.append(current) }

        attributeSnapshotText(&rounds, snapshots: snapshots)

        var result = RoundsResult()
        result.rounds = rounds.enumerated().map { $0.element.round(number: $0.offset + 1) }
        result.first = records.first(where: { $0.isChange })?.date
        result.last = records.last?.date
        result.historyStart = records.first?.revision
        result.agentEditsSinceHandback = unhanded > 0 ? unhanded : nil
        result.total = RoundsTotal(result.rounds)
        result.themes = RoundTheme.group(result.rounds.flatMap(\.comments))
        return result
    }

    /// Words for the comments the history kept none for (before this
    /// version of Tandem), from the saved files: each comment seen in a
    /// backup or an export's snapshot is matched to an "Add comment" row
    /// between the last save without it and the first with it.
    static func attributeSnapshotText(_ rounds: inout [RoundBuilder], snapshots: [Snapshot]) {
        let known = Set(rounds.flatMap { $0.comments.compactMap(\.id) })
        struct Seen { var id: String; var time: Time; var text: String; var first: Int; var lastWithout: Int }
        var seen: [String: Seen] = [:]
        let ordered = snapshots.sorted { $0.revision < $1.revision }
        for snapshot in ordered {
            for comment in snapshot.comments where !known.contains(comment.id) {
                if var was = seen[comment.id] {
                    // The newest words, as he last left them.
                    was.text = comment.name
                    seen[comment.id] = was
                } else {
                    let without = ordered.last { $0.revision < snapshot.revision && !$0.comments.contains { $0.id == comment.id } }?.revision ?? Int.min
                    seen[comment.id] = Seen(id: comment.id, time: comment.time, text: comment.name, first: snapshot.revision, lastWithout: without)
                }
            }
        }
        // He watches forward, so within one stretch of saves the earlier
        // comment on the timeline was left first.
        for comment in seen.values.sorted(by: { ($0.first, $0.time) < ($1.first, $1.time) }) {
            var best: (round: Int, slot: Int, revision: Int)?
            for (r, round) in rounds.enumerated() {
                for (s, slot) in round.comments.enumerated() where slot.text == nil {
                    guard slot.revision > comment.lastWithout, slot.revision <= comment.first else { continue }
                    if best == nil || slot.revision < best!.revision { best = (r, s, slot.revision) }
                }
            }
            guard let best else { continue }
            rounds[best.round].comments[best.slot].id = comment.id
            rounds[best.round].comments[best.slot].time = comment.time
            rounds[best.round].comments[best.slot].text = comment.text
            rounds[best.round].comments[best.slot].source = .snapshot
        }
    }

    /// One round as it's gathered.
    struct RoundBuilder {
        var handedBack: Date?
        var revision: Int?
        var inferred: Bool
        var things: Int?
        var agentRows: [HistoryRecord]
        var duringReview = 0
        var comments: [RoundComment] = []
        var reworded = 0
        var trimEdits = 0
        var trims = 0
        var otherEdits = 0
        var undos = 0
        var firstPerson: Date?
        var lastPerson: Date?
        /// The last trim of the take, to tell a new fix from more of one.
        var lastTrim: (date: Date, place: EditPlace?)?

        init(handedBack: Date?, revision: Int?, inferred: Bool, things: Int?, agentRows: [HistoryRecord]) {
            self.handedBack = handedBack
            self.revision = revision
            self.inferred = inferred
            self.things = things
            self.agentRows = agentRows
        }

        mutating func add(_ row: HistoryRecord, takeTracks: Set<String>) {
            if firstPerson == nil { firstPerson = row.date }
            lastPerson = row.date
            let label = row.label.lowercased()
            if row.kind == .undo {
                // An undone comment wasn't one he left; an undone rewording
                // brings the old words back. Neither is an edit he undid.
                if label.hasPrefix("add comment") {
                    if !comments.isEmpty { comments.removeLast() }
                } else if label == "edit comment" {
                    for said in row.comments ?? [] {
                        if let index = comments.lastIndex(where: { $0.id == said.id }) { comments[index].text = said.text }
                    }
                } else {
                    undos += 1
                }
                return
            }
            if label == "edit comment" {
                reworded += 1
                // From this version on, the new words come with it.
                for said in row.comments ?? [] {
                    if let index = comments.lastIndex(where: { $0.id == said.id }) {
                        comments[index].text = said.text
                    }
                }
                return
            }
            if label.hasPrefix("add comment") || !(row.comments ?? []).isEmpty {
                let said = row.comments ?? []
                if said.isEmpty {
                    comments.append(RoundComment(id: nil, time: nil, text: nil, date: row.date, revision: row.revision, source: nil))
                } else {
                    comments += said.map { RoundComment(id: $0.id, time: $0.time, text: $0.text, date: row.date, revision: row.revision, source: .history) }
                }
                return
            }
            // Deleting his own comment, or a to-do: not an edit to the video.
            if label.contains("comment") || label.contains("to-do") { return }
            if ReviewRounds.isTakeTrim(row, takeTracks: takeTracks) {
                trimEdits += 1
                if let last = lastTrim, row.date.timeIntervalSince(last.date) <= ReviewRounds.fixGap, ReviewRounds.near(last.place, row.place) {
                    // More of the same fix.
                } else {
                    trims += 1
                }
                lastTrim = (row.date, row.place)
            } else {
                otherEdits += 1
            }
        }

        func round(number: Int) -> ReviewRound {
            var round = ReviewRound(number: number)
            round.handedBack = handedBack
            round.revision = revision
            round.inferred = inferred
            round.handedBackThings = things
            round.agents = Array(Set(agentRows.map(\.author))).sorted()
            round.agentEdits = agentRows.filter { $0.kind == .edit }.count
            round.agentEditsDuringReview = duringReview > 0 ? duringReview : nil
            round.comments = comments.map { comment in
                var comment = comment
                comment.theme = comment.text.map(CommentTheme.classify)
                return comment
            }
            round.commentsReworded = reworded
            round.trims = trims
            round.trimEdits = trimEdits
            round.otherEdits = otherEdits
            round.undos = undos
            round.reviewStart = firstPerson
            round.reviewEnd = lastPerson
            if let handedBack, let first = comments.first?.date {
                round.firstCommentAfter = max(0, first.timeIntervalSince(handedBack))
            }
            return round
        }
    }

    /// A trim of the take: a ripple delete, trim, roll, close gap or
    /// deleted piece on the camera, screen or voice track. A blade alone
    /// changes nothing that plays, so it isn't one.
    static func isTakeTrim(_ row: HistoryRecord, takeTracks: Set<String>) -> Bool {
        guard row.kind == .edit || row.kind == .redo, let place = row.place, !place.tracks.isEmpty else { return false }
        let label = row.label.lowercased()
        let trimming = ["ripple", "trim", "roll edit", "close gap", "delete", "lift"].contains { label.hasPrefix($0) }
        guard trimming else { return false }
        // Names from the project as it is now, or the usual ones for a
        // track since renamed. Cutting the take cuts whatever sits over it
        // too (B-roll, angles, titles: a close gap touched every track in
        // the Threadbear launch), so touching the take is enough; a trim of
        // the B-roll alone isn't one.
        return place.tracks.map(trackName).contains { name in
            takeTracks.contains(name) || ["camera", "screen", "voice"].contains { name.lowercased().hasPrefix($0) }
        }
    }

    /// "V4 Camera" is the Camera track, whatever number it had then.
    static func trackName(_ label: String) -> String {
        guard let space = label.firstIndex(of: " "),
              label[label.startIndex..<space].range(of: #"^[VA]\d+$"#, options: .regularExpression) != nil else { return label }
        return String(label[label.index(after: space)...])
    }

    /// By where each starts: a close gap's place runs on to the end of the
    /// timeline, since everything after it moved.
    static func near(_ a: EditPlace?, _ b: EditPlace?) -> Bool {
        guard let a, let b else { return false }
        return abs((a.start - b.start).seconds) <= fixReach.seconds
    }

    // MARK: The channel log

    /// Adds the video's line to `file`, one JSON line per video, in place
    /// of any line it had before (by path or project ID), so it can be run
    /// again at sign-off.
    public static func log(_ result: RoundsResult, to file: URL, date: Date = Date()) throws -> RoundsLogLine {
        let line = RoundsLogLine(result, logged: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct Key: Decodable { var path: String?; var id: String? }
        var lines: [String] = []
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            for text in existing.split(separator: "\n", omittingEmptySubsequences: true) {
                if let key = try? JSONDecoder().decode(Key.self, from: Data(text.utf8)),
                   key.path == line.path || (key.id != nil && key.id == line.id) { continue }
                lines.append(String(text))
            }
        }
        lines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
        return line
    }
}

// MARK: - Themes

/// What a comment is about, from its words: a keyword classifier tuned on
/// the 69 comments still in the saved files of Mike's videos (Oct and Nov
/// 2026). The theme whose words come first wins, since his first sentence
/// is the ask and the rest is reasoning ("Can you justify that by showing
/// a thread... Hiding anything private" is B-roll, not privacy).
public enum CommentTheme: String, Codable, CaseIterable, Sendable {
    case pauses, clipped, broll, music, levels, transitions, text, layout, privacy, other

    public var title: String {
        switch self {
        case .pauses: return "pauses and silence"
        case .clipped: return "clipped or cut words and takes"
        case .broll: return "B-roll, show it, proof"
        case .music: return "music and sound effects"
        case .levels: return "voice and sound levels"
        case .transitions: return "wipes and transitions"
        case .text: return "text, titles and captions"
        case .layout: return "layout, PiP, cutout and camera"
        case .privacy: return "blur and privacy"
        case .other: return "other"
        }
    }

    /// In the order ties go: at the same word, "show my face" is layout,
    /// not B-roll.
    static let patterns: [(CommentTheme, [String])] = [
        (.privacy, [#"\bblur"#, #"\bprivate\b"#, #"\bprivacy\b"#, #"\bhid(e|ing)\b"#, #"\bredact"#, #"\bemail"#]),
        (.transitions, [#"\bs?wipes?\b"#, #"\btransition"#, #"\bfades?\b"#, #"\bdissolve"#, #"\bcross ?fade"#]),
        (.text, [#"\btext\b"#, #"\btitles?\b"#, #"\bcaptions?\b"#, #"\bsubtitles?\b"#, #"\bfont"#, #"\blower third"#, #"\bunderneath (his|my) face"#]),
        (.music, [#"\bmusic"#, #"\bsong"#, #"\bsoundtrack"#, #"\bswell"#, #"\bsound effects?\b"#, #"\bsfx\b"#, #"\bwhoosh"#, #"\bswoosh"#, #"\brecord scratch"#]),
        (.levels, [#"\bloud"#, #"\bquiet"#, #"\bvolume"#, #"\blevels?\b"#, #"\baudio\b"#, #"\bmic\b"#, #"\bnoise\b"#, #"\becho"#, #"\bhum\b"#, #"\bdb\b"#, #"\blufs\b"#, #"\bmuffled"#, #"\bvoice\b"#]),
        (.layout, [#"\bshow my face"#, #"\bcuts? my face"#, #"picture[- ]in[- ]picture"#, #"\bpip\b"#, #"\bcut ?out\b(?! (this|that|the|some))"#, #"\bcorner\b"#, #"\bmy face\b"#, #"\bmy picture\b"#, #"\bcamera\b"#, #"\bzoom"#, #"\bcrop"#, #"\bsquare\b"#, #"\bfull ?screen"#, #"\bfram(e|ing)\b"#]),
        (.pauses, [#"\bpauses?\b"#, #"\bsilences?\b"#, #"\bgormless"#, #"\bdead air"#, #"\btoo long\b"#, #"\btighten"#, #"\bgap\b"#, #"\bwaiting\b"#]),
        (.clipped, [#"\bclipped"#, #"\bcut (off|short)\b"#, #"\bbad take"#, #"\bretake"#, #"\bfumbl"#, #"\bduplicate"#, #"\bthroat"#, #"\blaugh"#, #"\bgetting it wrong"#, #"\bdrop (that|this)"#, #"\bcut (out )?(this|that|it|some)\b"#, #"\bget rid of this bit"#, #"\bcut (it|this|that) out"#, #"\bfinish"#, #"\bmy words\b"#, #"\bstumbl"#, #"\bum+\b"#, #"\buh+\b"#]),
        (.broll, [#"\bshow"#, #"\bb-?roll"#, #"\bon (the )?screen\b"#, #"\bmotion graphics?\b"#, #"\bgraphic"#, #"\bscreenshot"#, #"\bjustify"#, #"\bproof\b"#, #"\bflash"#, #"\blogos?\b"#, #"\btweets?\b"#, #"\bdocs\b"#, #"\bdocumentation"#, #"\bwebsite"#, #"\brepo\b"#, #"\bpop (up|in)"#, #"\bcome up\b"#, #"\bwhizz"#, #"\bslide in"#, #"\bstatic screen"#, #"\bdashboard"#, #"\banimation"#, #"\bcartoon"#, #"\bthumbnail"#, #"\bgiga ?chad"#, #"\bimage\b"#])
    ]

    static let compiled: [(CommentTheme, [NSRegularExpression])] = patterns.map { theme, list in
        (theme, list.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) })
    }

    public static func classify(_ text: String) -> CommentTheme {
        let range = NSRange(text.startIndex..., in: text)
        var best: (at: Int, theme: CommentTheme)?
        for (theme, expressions) in compiled {
            for expression in expressions {
                guard let match = expression.firstMatch(in: text, range: range) else { continue }
                if best == nil || match.range.location < best!.at { best = (match.range.location, theme) }
            }
        }
        return best?.theme ?? .other
    }
}

// MARK: - Results

public struct RoundComment: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// The history kept its words (this version of Tandem on).
        case history
        /// Found in a backup or an export's snapshot.
        case snapshot
    }

    public var id: String?
    /// Where it was on the timeline when he left it (or when it was saved).
    public var time: Time?
    /// Nil when its words weren't kept anywhere: the history from before
    /// this version keeps none, and no saved file had it.
    public var text: String?
    /// When he left it.
    public var date: Date
    public var revision: Int
    public var source: Source?
    public var theme: CommentTheme?
}

public struct ReviewRound: Codable, Equatable, Sendable {
    public var number: Int
    /// When it was handed back: the handback's time, or (inferred) the last
    /// agent edit before Mike's review. Nil for edits of his own before any
    /// agent's.
    public var handedBack: Date?
    public var revision: Int?
    /// True where there was no handback row and the history's authors say
    /// where the round was.
    public var inferred = true
    /// How many things the handback gave him to look at.
    public var handedBackThings: Int?
    public var agents: [String] = []
    /// Agent edit batches that went into the round.
    public var agentEdits = 0
    /// Agent edits while he was reviewing it (a fix he asked for in chat).
    public var agentEditsDuringReview: Int?
    /// Mike's comments, in the order he left them.
    public var comments: [RoundComment] = []
    /// Times he reworded one.
    public var commentsReworded = 0
    /// Fixes he made to the take himself (a delete and its close gap are one).
    public var trims = 0
    /// The edits those took.
    public var trimEdits = 0
    /// His other edits: blurs, B-roll, levels, colour.
    public var otherEdits = 0
    public var undos = 0
    public var reviewStart: Date?
    public var reviewEnd: Date?
    /// Seconds from the handback to his first comment.
    public var firstCommentAfter: Double?

    public init(number: Int) {
        self.number = number
    }

    /// Comments whose words weren't found.
    public var missingText: Int { comments.filter { $0.text == nil }.count }
}

public struct RoundsTotal: Codable, Equatable, Sendable {
    public var rounds = 0
    /// Rounds Mike left comments in.
    public var roundsWithComments = 0
    public var comments = 0
    public var commentsWithText = 0
    public var agentEdits = 0
    public var trims = 0
    public var trimEdits = 0
    public var otherEdits = 0

    public init() {}

    init(_ rounds: [ReviewRound]) {
        self.rounds = rounds.count
        roundsWithComments = rounds.filter { !$0.comments.isEmpty }.count
        comments = rounds.map(\.comments.count).reduce(0, +)
        commentsWithText = rounds.map { $0.comments.count - $0.missingText }.reduce(0, +)
        agentEdits = rounds.map(\.agentEdits).reduce(0, +)
        trims = rounds.map(\.trims).reduce(0, +)
        trimEdits = rounds.map(\.trimEdits).reduce(0, +)
        otherEdits = rounds.map(\.otherEdits).reduce(0, +)
    }
}

public struct RoundTheme: Codable, Equatable, Sendable {
    public var theme: CommentTheme
    public var title: String
    public var count: Int
    public var comments: [String]

    /// Most first; comments without words aren't in any.
    static func group(_ comments: [RoundComment]) -> [RoundTheme] {
        var by: [CommentTheme: [String]] = [:]
        for comment in comments {
            guard let text = comment.text, let theme = comment.theme else { continue }
            by[theme, default: []].append(text)
        }
        let order = CommentTheme.allCases
        return by.map { RoundTheme(theme: $0.key, title: $0.key.title, count: $0.value.count, comments: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : order.firstIndex(of: $0.theme)! < order.firstIndex(of: $1.theme)! }
    }
}

public struct RoundsResult: Codable, Sendable {
    public var name = ""
    public var id = ""
    public var path = ""
    /// The first and last rows of the history.
    public var first: Date?
    public var last: Date?
    /// The revision the history starts at; rounds before it aren't known.
    public var historyStart: Int?
    public var rounds: [ReviewRound] = []
    public var total = RoundsTotal()
    public var themes: [RoundTheme] = []
    /// Agent edits since the last handback, not handed back yet.
    public var agentEditsSinceHandback: Int?
    /// The line `--log` wrote, when it did.
    public var logged: RoundsLogLine?
}

/// One video in the channel's review log (`--log`).
public struct RoundsLogLine: Codable, Equatable, Sendable {
    public var project: String
    public var id: String
    public var path: String
    public var first: Date?
    public var last: Date?
    public var rounds: Int
    public var roundsWithComments: Int
    public var comments: Int
    /// Mike's comments in each round, in order.
    public var commentsPerRound: [Int]
    public var missingText: Int
    public var byTheme: [String: Int]
    public var trims: Int
    public var otherEdits: Int
    public var agentEdits: Int
    public var logged: Date

    init(_ result: RoundsResult, logged: Date) {
        project = result.name
        id = result.id
        path = result.path
        first = result.first
        last = result.last
        rounds = result.total.rounds
        roundsWithComments = result.total.roundsWithComments
        comments = result.total.comments
        commentsPerRound = result.rounds.map(\.comments.count)
        missingText = result.total.comments - result.total.commentsWithText
        byTheme = Dictionary(uniqueKeysWithValues: result.themes.map { ($0.theme.rawValue, $0.count) })
        trims = result.total.trims
        otherEdits = result.total.otherEdits
        agentEdits = result.total.agentEdits
        self.logged = logged
    }
}

extension RoundsResult: ReadableResult {
    public var readableText: String {
        let day = DateFormatter()
        day.dateFormat = "d MMM HH:mm"
        func when(_ date: Date?) -> String { date.map(day.string(from:)) ?? "?" }
        func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String { "\(n) \(n == 1 ? one : (many ?? one + "s"))" }
        var lines: [String] = []
        if rounds.isEmpty {
            lines.append("\(name): no review rounds in the edit history yet\(historyStart.map { " (it starts at revision \($0))" } ?? "").")
            return lines.joined(separator: "\n")
        }
        let start = historyStart.map { $0 > 0 ? " The history starts at revision \($0), so earlier rounds aren't counted." : "" } ?? ""
        lines.append("\(name): \(plural(rounds.count, "review round")), \(when(first)) to \(when(last)).\(start)")
        for round in rounds {
            lines.append("")
            var head = "Round \(round.number): "
            if let handed = round.handedBack {
                head += "handed back \(when(handed))"
                if let revision = round.revision { head += " at r\(revision)" }
                head += round.inferred ? " (inferred)" : ""
                if let things = round.handedBackThings { head += " with \(plural(things, "thing")) to look at" }
                head += ", \(plural(round.agentEdits, "agent edit"))"
                if !round.agents.isEmpty { head += " by \(round.agents.joined(separator: ", "))" }
            } else {
                head += "Mike's own edits before any agent's"
            }
            lines.append(head)
            var mike = "  Mike: \(plural(round.comments.count, "comment"))"
            if round.commentsReworded > 0 { mike += " (\(round.commentsReworded) reworded)" }
            if let after = round.firstCommentAfter { mike += ", the first \(Self.duration(after)) after" }
            mike += "; \(plural(round.trims, "trim")) of the take"
            if round.trimEdits != round.trims { mike += " (\(plural(round.trimEdits, "edit")))" }
            mike += ", \(plural(round.otherEdits, "other edit"))"
            if round.undos > 0 { mike += ", \(plural(round.undos, "undo"))" }
            if round.comments.isEmpty && round.trims == 0 && round.otherEdits == 0 { mike = "  Mike: nothing on the timeline yet (not watched, or answered in the chat)" }
            lines.append(mike)
            if let during = round.agentEditsDuringReview { lines.append("  \(plural(during, "agent edit")) while he reviewed") }
            for comment in round.comments {
                let at = comment.time.map { "\($0)  " } ?? ""
                if let text = comment.text {
                    lines.append("  \(at)[\(comment.theme?.rawValue ?? "?")] \(ClipChanges.shorten(CommentEdits.oneLine(text), 110))")
                }
            }
            if round.missingText > 0 {
                lines.append("  (\(plural(round.missingText, "comment")) without words: not in the history, a backup or an export's snapshot)")
            }
        }
        lines.append("")
        var total = "Total: \(plural(self.total.comments, "comment")) in \(self.total.roundsWithComments) of \(plural(self.total.rounds, "round"))"
        let missing = self.total.comments - self.total.commentsWithText
        if missing > 0 { total += " (words for \(self.total.commentsWithText); \(missing) not kept anywhere)" }
        total += ", \(plural(self.total.trims, "trim")) of the take by Mike (\(plural(self.total.trimEdits, "edit"))), \(plural(self.total.otherEdits, "other edit")) by him, \(plural(self.total.agentEdits, "agent edit"))."
        lines.append(total)
        if let since = agentEditsSinceHandback { lines.append("\(plural(since, "agent edit")) since the last handback, not handed back yet.") }
        if !themes.isEmpty {
            lines.append("By theme:")
            for theme in themes { lines.append("  \(theme.title): \(theme.count)") }
        }
        if let logged { lines.append("Logged the video to the review log (\(plural(logged.comments, "comment")), \(plural(logged.rounds, "round"))).") }
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(Int(seconds.rounded())) s" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return "\(hours / 24) days"
    }
}
