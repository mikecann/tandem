import Foundation
import TandemCore
import TandemMedia
import TandemRender

// Requests and results for every service operation. The same types travel
// over HTTP (as the JSON body and response), MCP (as tool arguments) and the
// CLI (built from flags), so all three stay in step. Times in requests may
// be seconds or `mm:ss.mmm` strings; times in results are seconds.

// MARK: - status

public struct StatusRequest: ServiceCall {
    public static let operation = ServiceOperation.status
    public init() {}

    public func run(on service: TandemService, context: CallContext) async throws -> StatusResult {
        service.status()
    }
}

/// Who has the project open, from its lock file.
public struct OwnerInfo: Codable, Equatable, Sendable {
    /// `app` or `cli`.
    public var owner: String
    public var pid: Int32
    public var started: Date
    /// The API port when the owner serves one.
    public var port: Int?

    public init(owner: String, pid: Int32, started: Date, port: Int?) {
        self.owner = owner
        self.pid = pid
        self.started = started
        self.port = port
    }
}

/// An agent edit Mike hasn't reviewed in the app yet. The app highlights
/// it on the timeline until he marks the agent edits reviewed.
public struct PendingReview: Codable, Equatable, Sendable {
    public var label: String
    public var author: String
    public var date: Date
    /// Clips it added or changed that are still on the timeline.
    public var clipIDs: [String]
    /// How many places it took something out.
    public var removals: Int

    public init(label: String, author: String, date: Date, clipIDs: [String], removals: Int) {
        self.label = label
        self.author = author
        self.date = date
        self.clipIDs = clipIDs
        self.removals = removals
    }

    init(_ entry: ReviewEntry) {
        self.init(label: entry.label, author: entry.author, date: entry.date, clipIDs: entry.clipIDs, removals: entry.removals.count)
    }
}

public struct StatusResult: Codable, Sendable {
    public var name: String
    public var path: String
    public var revision: Int
    public var savedRevision: Int
    /// True when edits haven't reached the file yet (autosave is a second behind).
    public var dirty: Bool
    public var duration: Time
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var tracks: Int
    public var clips: Int
    public var media: Int
    public var markers: Int
    /// Label of the edit `undo` would undo.
    public var undo: String?
    public var redo: String?
    public var openIn: OwnerInfo?
    /// True when nothing else had the project open and it was read straight
    /// from the file for this call.
    public var headless: Bool
    public var jobs: [JobStatus]
    public var exports: [ExportJob]
    /// True when the project was recovered from the journal after a crash.
    public var recoveredEdits: Bool
    public var apiVersion: String
    /// What won't look right, with the fix: titles in a font that isn't
    /// installed. Optional so an older app's answer still reads.
    public var warnings: [String]?
    /// Agent edits waiting for Mike's review, oldest first. Read-only:
    /// only Mark reviewed in the app clears them. Nil from an older app.
    public var reviewPending: [PendingReview]?
    /// What agents asked Mike to look at when they handed back, still
    /// waiting, in timeline order (`handback`). Nil from an older app.
    public var handback: [LookHere]?
}

// MARK: - media

public struct MediaRequest: ServiceCall {
    public static let operation = ServiceOperation.media
    /// Scan the folder for new files first.
    public var refresh: Bool?

    public init(refresh: Bool? = nil) {
        self.refresh = refresh
    }

    public func run(on service: TandemService, context: CallContext) async throws -> MediaResult {
        try await service.media(refresh: refresh ?? false)
    }
}

public struct AnalysisState: Codable, Equatable, Sendable {
    /// `ready`, `queued`, `running`, `failed`, `cancelled` or `none`.
    public var state: String
    public var progress: Double?
    /// Why it failed, when it did.
    public var message: String?

    public init(state: String, progress: Double? = nil, message: String? = nil) {
        self.state = state
        self.progress = progress
        self.message = message
    }
}

public struct MediaInfo: Codable, Sendable {
    public var id: String
    public var path: String
    public var kind: MediaKind
    public var role: MediaRole
    public var duration: Time?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// The video codec macOS can't decode ("rle " for QuickTime Animation,
    /// "png "), when it can't. The picture comes from a converted copy
    /// (`analysis.converted`).
    public var undecodableCodec: String?
    /// For a Live Photo's still, its motion clip (the short movie beside it).
    public var livePhotoVideo: String? = nil
    public var takeID: String?
    public var takeOffset: Time?
    /// How many timeline clips use this file.
    public var clips: Int
    /// False when the file is missing from disk.
    public var exists: Bool
    /// Analysis status by kind (`transcript`, `loudness`, `proxy`...).
    public var analysis: [String: AnalysisState]
    /// How late the file's picture is against its sound; every clip of it
    /// shows its picture that much later (`tandem sync`).
    public var pictureDelay: Time? = nil
    /// The lag its recorder already took out (Record It's Camera delay).
    public var pictureDelayCorrected: Time? = nil
}

public struct MediaResult: Codable, Sendable {
    public var revision: Int
    /// IDs of media a refresh added.
    public var added: [String]
    public var items: [MediaInfo]
}

// MARK: - timeline

public struct TimelineRequest: ServiceCall {
    public static let operation = ServiceOperation.timeline

    public enum Format: String, Codable, Sendable {
        /// The compact text view.
        case text
        /// The project JSON (filtered to the range).
        case json
    }

    public var from: Time?
    public var to: Time?
    public var format: Format?
    /// Add what's said in each speech clip (text form only).
    public var words: Bool?
    /// Just one line per track and the markers (text form only).
    public var summary: Bool?

    public init(from: Time? = nil, to: Time? = nil, format: Format? = nil, words: Bool? = nil, summary: Bool? = nil) {
        self.from = from
        self.to = to
        self.format = format
        self.words = words
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        format = try c.decodeIfPresent(Format.self, forKey: .format)
        words = try c.decodeIfPresent(Bool.self, forKey: .words)
        summary = try c.decodeIfPresent(Bool.self, forKey: .summary)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> TimelineResult {
        try service.timeline(from: from, to: to, format: format ?? .text, words: words ?? false, summary: summary ?? false)
    }
}

public struct TimelineResult: Codable, Sendable {
    public var revision: Int
    /// The text view, for `format: text`.
    public var text: String?
    /// The project, for `format: json`. Tracks keep only the clips that
    /// overlap the range.
    public var project: Project?
}

// MARK: - transcript, search, pauses, tighten

public struct TranscriptRequest: ServiceCall {
    public static let operation = ServiceOperation.transcript
    /// A media ID (media times), a clip ID (timeline times) or nothing for
    /// everything said on the timeline.
    public var id: String?
    public var from: Time?
    public var to: Time?

    public init(id: String? = nil, from: Time? = nil, to: Time? = nil) {
        self.id = id
        self.from = from
        self.to = to
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> TranscriptResult {
        try service.transcript(id: id, from: from, to: to)
    }
}

public struct WordTiming: Codable, Equatable, Sendable {
    public var text: String
    public var start: Time
    public var end: Time
    /// The clip the word plays in, for timeline transcripts.
    public var clipID: String?
    public var confidence: Double?

    public init(text: String, start: Time, end: Time, clipID: String? = nil, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.clipID = clipID
        self.confidence = confidence
    }
}

public struct TranscriptResult: Codable, Sendable {
    public var revision: Int
    /// `media`, `clip` or `timeline`.
    public var scope: String
    public var id: String?
    /// False when times are media times (a media transcript).
    public var timelineTimes: Bool
    public var words: [WordTiming]
    /// Media on the timeline whose transcript isn't ready yet.
    public var missing: [String]
}

public struct SearchRequest: ServiceCall {
    public static let operation = ServiceOperation.search
    public var phrase: String
    public var limit: Int?

    public init(phrase: String, limit: Int? = nil) {
        self.phrase = phrase
        self.limit = limit
    }

    public func run(on service: TandemService, context: CallContext) async throws -> SearchResult {
        try service.search(phrase: phrase, limit: limit)
    }
}

public struct SearchHit: Codable, Equatable, Sendable {
    /// The words as the transcript has them.
    public var text: String
    /// Timeline range of the match.
    public var start: Time
    public var end: Time
    /// Every clip playing the match: the voice clip and its linked picture.
    public var clipIDs: [String]
    public var mediaID: String
    public var mediaStart: Time
    public var mediaEnd: Time
    /// True when a cut runs through the phrase, so only part of it plays.
    public var partial: Bool
    /// A few words either side, for context.
    public var before: String
    public var after: String
}

/// A match in a file that the timeline doesn't use (cut out, or never placed).
public struct UnusedHit: Codable, Equatable, Sendable {
    public var mediaID: String
    public var path: String
    public var text: String
    public var mediaStart: Time
    public var mediaEnd: Time
    public var before: String
    public var after: String
}

public struct SearchResult: Codable, Sendable {
    public var revision: Int
    public var phrase: String
    public var hits: [SearchHit]
    public var unused: [UnusedHit]
    public var missing: [String]
}

public struct PausesRequest: ServiceCall {
    public static let operation = ServiceOperation.pauses
    /// Shortest gap to report, in seconds. Default 0.6.
    public var min: Double?
    public var from: Time?
    public var to: Time?

    public init(min: Double? = nil, from: Time? = nil, to: Time? = nil) {
        self.min = min
        self.from = from
        self.to = to
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        min = try c.decodeSeconds(.min)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> PausesResult {
        try await service.listenedPauses(minimum: Time(seconds: min ?? TranscriptTools.defaultMinimum), from: from, to: to)
    }
}

/// A silence between two words, in timeline time.
public struct Pause: Codable, Equatable, Sendable {
    public var start: Time
    public var end: Time
    public var duration: Time
    /// The last words before the pause and the first ones after it.
    public var before: String
    public var after: String
    /// Speech clips under the pause.
    public var clipIDs: [String]
    /// What the sound under it has, on every track the take plays there
    /// (`tandem pauses` and `tighten` listen). Nil when there's no sound to
    /// listen to, like a file that isn't there.
    public var sound: PauseSound? = nil
}

/// The sound under a gap between two words, heard on every unmuted track
/// of the take that plays there (`GapSound`).
public struct PauseSound: Codable, Equatable, Sendable {
    /// From the end of the last word's sound to the start of the next
    /// word's, in timeline time. The transcript's word times can be 30 to
    /// 200 ms off the sound, so this is the gap as it's heard.
    public var start: Time
    public var end: Time
    public var duration: Time
    /// The real pauses in it: quiet on every track.
    public var quiet: [TimeRange]
    /// Sound in it no transcript word accounts for: a breath, a second
    /// speaker off mic, an app talking, on the tracks named.
    public var heard: [HeardSound]
    /// The voice runs right through the gap with no real pause: the
    /// transcript's times are off, or the speech there is quiet.
    public var runsThrough: Bool
}

public struct HeardSound: Codable, Equatable, Sendable {
    public var start: Time
    public var end: Time
    /// The tracks it's heard on.
    public var tracks: [String]
}

public struct PausesResult: Codable, Sendable {
    public var revision: Int
    public var minimum: Time
    public var pauses: [Pause]
    public var total: Time
    public var missing: [String]
    public var warnings: [String]? = nil
}

/// What a pause follows: the end of a sentence (. ? !), a comma (, ; :) or
/// neither, a pause in the middle of a sentence.
public enum PauseKind: String, Codable, Sendable {
    case sentence, comma, mid
}

public struct TightenRequest: ServiceCall {
    public static let operation = ServiceOperation.tighten
    /// Pauses at least this long get shortened. Default 0.6 s, or 0.5 s for
    /// sentence pauses when tightening by what a pause follows.
    public var min: Double?
    /// How much of each pause to keep. Default 0.15 s. Not with `sentence`,
    /// `comma` or `mid`.
    public var keep: Double?
    /// Tighten by what a pause follows: keep this much after a sentence
    /// (a word ending . ? or !), after a comma (, ; or :) and mid-sentence.
    /// A kind with no keep is left alone; a comma falls back to `mid`.
    public var sentence: Double?
    public var comma: Double?
    public var mid: Double?
    /// Comma and mid-sentence pauses at least this long change, so breaths
    /// stay. Default 0.5 s.
    public var midMin: Double?
    /// Mike's rules (`TranscriptTools.mikeRules`); the other fields override them.
    public var mike: Bool?
    /// Pauses containing any of these timeline times are left alone.
    public var protect: [Time]?
    /// Widen joins between speech clips that leave less than the keep, from
    /// silence in the take either side.
    public var widen: Bool?
    /// Make the edit. Without it this is a dry run that returns the plan.
    public var apply: Bool?
    public var from: Time?
    public var to: Time?
    public var label: String?
    public var author: String?
    /// Refuse to apply if the project isn't at this revision.
    public var expectedRevision: Int?

    public init(
        min: Double? = nil, keep: Double? = nil, sentence: Double? = nil, comma: Double? = nil, mid: Double? = nil,
        midMin: Double? = nil, mike: Bool? = nil, protect: [Time]? = nil, widen: Bool? = nil,
        apply: Bool? = nil, from: Time? = nil, to: Time? = nil,
        label: String? = nil, author: String? = nil, expectedRevision: Int? = nil
    ) {
        self.min = min
        self.keep = keep
        self.sentence = sentence
        self.comma = comma
        self.mid = mid
        self.midMin = midMin
        self.mike = mike
        self.protect = protect
        self.widen = widen
        self.apply = apply
        self.from = from
        self.to = to
        self.label = label
        self.author = author
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        min = try c.decodeSeconds(.min)
        keep = try c.decodeSeconds(.keep)
        sentence = try c.decodeSeconds(.sentence)
        comma = try c.decodeSeconds(.comma)
        mid = try c.decodeSeconds(.mid)
        midMin = try c.decodeSeconds(.midMin)
        mike = try c.decodeIfPresent(Bool.self, forKey: .mike)
        protect = try c.decodeTimes(.protect)
        widen = try c.decodeIfPresent(Bool.self, forKey: .widen)
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    /// Whether the keeps depend on what each pause follows.
    public var bySentence: Bool { sentence != nil || comma != nil || mid != nil || mike == true }

    public func run(on service: TandemService, context: CallContext) async throws -> TightenResult {
        try await service.tighten(self, context: context)
    }
}

public struct PlannedCut: Codable, Equatable, Sendable {
    public var pause: Pause
    /// The time `rippleDeleteRange` removes, frame aligned.
    public var cut: TimeRange
    /// What the pause follows, and how much of it is kept.
    public var kind: PauseKind?
    public var keep: Time?
    /// How each side of the join sounds, as `check --cuts` judges it, on
    /// the track it's worst on. Set when the cut was placed from the sound.
    public var startEdge: CutJoinSide?
    public var endEdge: CutJoinSide?

    public init(pause: Pause, cut: TimeRange, kind: PauseKind? = nil, keep: Time? = nil, startEdge: CutJoinSide? = nil, endEdge: CutJoinSide? = nil) {
        self.pause = pause
        self.cut = cut
        self.kind = kind
        self.keep = keep
        self.startEdge = startEdge
        self.endEdge = endEdge
    }
}

/// A pause tighten would have shortened but left alone, and why.
public struct SkippedPause: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The voice runs right through it: no real pause in the sound.
        case speech
        /// Sound the transcript has no word for (`pause.sound.heard`) leaves
        /// no real pause long enough for the cut.
        case sound
        /// Measured from the sound, it's shorter than the minimum.
        case short
        /// A side of the join would be judged clipped or marginal.
        case notClean
    }

    public var pause: Pause
    public var reason: Reason
    public var kind: PauseKind
    public var keep: Time
    /// For `notClean`: how each side of the join would have sounded.
    public var startEdge: CutJoinSide?
    public var endEdge: CutJoinSide?
}

/// A join between two speech clips widened back to its keep with silence
/// from the take either side.
public struct PlannedWiden: Codable, Equatable, Sendable {
    /// The silence between the words either side of the join, before.
    public var pause: Pause
    public var kind: PauseKind
    public var keep: Time
    /// Where the two clips meet, in the timeline's current times.
    public var at: Time
    /// The clip before the join, whose end gets `tail` more of the take.
    public var clipID: String
    /// The clip after it, whose start gets `head` more of the take.
    public var nextClipID: String
    public var tail: Time
    public var head: Time

    public var added: Time { tail + head }
}

public struct TightenResult: Codable, Sendable {
    /// The revision the plan was made against.
    public var revision: Int
    /// The shortest pause that changes (a sentence pause, when tightening by
    /// what a pause follows).
    public var minimum: Time
    /// What every pause keeps; when tightening by what a pause follows, the
    /// first of the sentence, comma and mid keeps given.
    public var keep: Time
    /// Set when tightening by what a pause follows.
    public var sentence: Time?
    public var comma: Time?
    public var mid: Time?
    public var midMinimum: Time?
    public var cuts: [PlannedCut]
    /// Joins widened back out (`widen`).
    public var widened: [PlannedWiden]
    /// Pauses left alone because they contain a `protect` time.
    public var protected: [Pause]
    /// Pauses left alone because of what the sound under them has: sound
    /// in them, too short once measured from the sound, or a join that
    /// wouldn't be clean.
    public var skipped: [SkippedPause]
    public var removed: Time
    public var added: Time
    public var durationBefore: Time
    public var durationAfter: Time
    /// The batch that makes the cut, latest first so each range is still in
    /// the current timeline's times. Pass it to `apply` to run it yourself.
    public var commands: [EditCommand]
    /// Set when the plan was applied.
    public var applied: ApplyResult?
    public var warnings: [String]
    public var missing: [String]
}

extension TightenResult {
    /// An app or server from before tighten listened sends no `skipped`, so
    /// it's empty when it's not there: a newer CLI or MCP client talking to
    /// it, maybe after it applied the edit, still reads the result.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int.self, forKey: .revision)
        minimum = try c.decode(Time.self, forKey: .minimum)
        keep = try c.decode(Time.self, forKey: .keep)
        sentence = try c.decodeIfPresent(Time.self, forKey: .sentence)
        comma = try c.decodeIfPresent(Time.self, forKey: .comma)
        mid = try c.decodeIfPresent(Time.self, forKey: .mid)
        midMinimum = try c.decodeIfPresent(Time.self, forKey: .midMinimum)
        cuts = try c.decode([PlannedCut].self, forKey: .cuts)
        widened = try c.decode([PlannedWiden].self, forKey: .widened)
        protected = try c.decode([Pause].self, forKey: .protected)
        skipped = try c.decodeIfPresent([SkippedPause].self, forKey: .skipped) ?? []
        removed = try c.decode(Time.self, forKey: .removed)
        added = try c.decode(Time.self, forKey: .added)
        durationBefore = try c.decode(Time.self, forKey: .durationBefore)
        durationAfter = try c.decode(Time.self, forKey: .durationAfter)
        commands = try c.decode([EditCommand].self, forKey: .commands)
        applied = try c.decodeIfPresent(ApplyResult.self, forKey: .applied)
        warnings = try c.decode([String].self, forKey: .warnings)
        missing = try c.decode([String].self, forKey: .missing)
    }

    /// How many pauses the cuts are in: a pause with sound in it can have a
    /// cut either side of the sound.
    public var pausesCut: Int { Set(cuts.map(\.pause.start)).count }
}

// MARK: - apply, undo, redo, history, validate

public struct ApplyRequest: ServiceCall {
    public static let operation = ServiceOperation.apply
    public var label: String?
    public var author: String?
    public var commands: [EditCommand]
    public var expectedRevision: Int?
    public var idempotencyKey: String?
    /// Check the batch on a copy and report what it would do.
    public var dryRun: Bool?

    public init(
        label: String? = nil, author: String? = nil, commands: [EditCommand],
        expectedRevision: Int? = nil, idempotencyKey: String? = nil, dryRun: Bool? = nil
    ) {
        self.label = label
        self.author = author
        self.commands = commands
        self.expectedRevision = expectedRevision
        self.idempotencyKey = idempotencyKey
        self.dryRun = dryRun
    }

    public init(batch: EditBatch, dryRun: Bool? = nil) {
        self.init(
            label: batch.label, author: batch.author, commands: batch.commands,
            expectedRevision: batch.expectedRevision, idempotencyKey: batch.idempotencyKey, dryRun: dryRun
        )
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun)
        let raw = try c.decode([JSONValue].self, forKey: .commands)
        commands = try raw.enumerated().flatMap { index, value in
            try CommandJSON.decodeAll(value, path: "commands[\(index)]")
        }
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ApplyResult {
        try service.apply(self, context: context)
    }
}

public struct ApplyResult: Codable, Equatable, Sendable {
    public var revision: Int
    public var label: String
    public var author: String
    /// IDs the batch created, in order (clips, tracks, transitions, markers).
    public var createdIDs: [String]
    public var warnings: [String]
    /// True when nothing was committed.
    public var dryRun: Bool
    /// True when an idempotency key matched an earlier batch, which wasn't
    /// applied again.
    public var repeated: Bool
    /// Clips that are new, gone, or different after the batch.
    public var added: [String]
    public var removed: [String]
    public var changed: [String]
    /// Timeline duration after the batch.
    public var duration: Time
}

public struct UndoRequest: ServiceCall {
    public static let operation = ServiceOperation.undo
    /// Refuse if the project has moved on, so an agent never undoes
    /// someone else's edit.
    public var expectedRevision: Int?
    /// How many steps to undo, newest first. Defaults to 1.
    public var count: Int?

    public init(expectedRevision: Int? = nil, count: Int? = nil) {
        self.expectedRevision = expectedRevision
        self.count = count
    }

    public func run(on service: TandemService, context: CallContext) async throws -> UndoResult {
        try service.undo(expectedRevision: expectedRevision, count: count)
    }
}

public struct RedoRequest: ServiceCall {
    public static let operation = ServiceOperation.redo
    public var expectedRevision: Int?
    public var count: Int?

    public init(expectedRevision: Int? = nil, count: Int? = nil) {
        self.expectedRevision = expectedRevision
        self.count = count
    }

    public func run(on service: TandemService, context: CallContext) async throws -> UndoResult {
        try service.redo(expectedRevision: expectedRevision, count: count)
    }
}

public struct UndoResult: Codable, Sendable {
    /// `undo` or `redo`.
    public var action: String
    public var revision: Int
    /// The label of the edit that was undone or redone (the last one, with
    /// `count`).
    public var label: String
    public var author: String
    /// How many steps were undone or redone, which can be fewer than asked
    /// for when the history ran out.
    public var count: Int?
    /// Each step's edit label and author, in the order they were undone or
    /// redone.
    public var labels: [String]?
    public var authors: [String]?
}

public struct HistoryRequest: ServiceCall {
    public static let operation = ServiceOperation.history
    public var limit: Int?

    public init(limit: Int? = nil) {
        self.limit = limit
    }

    public func run(on service: TandemService, context: CallContext) async throws -> HistoryResult {
        service.history(limit: limit ?? 20)
    }
}

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var label: String
    public var author: String
    /// Where the edit was on the timeline, and on which tracks ("V2 Camera").
    public var start: Time?
    public var end: Time?
    public var tracks: [String]?

    public init(label: String, author: String, place: EditPlace? = nil) {
        self.label = label
        self.author = author
        start = place?.start
        end = place?.end
        tracks = place?.tracks
    }
}

/// One change from the edit history (`.tandem/<name>.history.jsonl`),
/// which lasts across restarts and from one CLI command to the next.
public struct HistoryEdit: Codable, Equatable, Sendable {
    public var revision: Int
    /// `edit`, `undo`, `redo`, `reload`, or `opened` where the history
    /// starts again (the project was changed by something that kept none).
    public var kind: HistoryRecord.Kind
    public var label: String
    public var author: String
    public var date: Date
    public var start: Time?
    public var end: Time?
    public var tracks: [String]?
    /// Counts, like "1 changed, 14 moved", and anything else it changed.
    public var summary: String?

    public init(_ record: HistoryRecord) {
        revision = record.revision
        kind = record.kind
        label = record.label
        author = record.author
        date = record.date
        start = record.place?.start
        end = record.place?.end
        tracks = record.place?.tracks
        summary = record.summary
    }
}

public struct HistoryResult: Codable, Sendable {
    public var revision: Int
    /// What `undo` would undo, newest first.
    public var undo: [HistoryEntry]
    public var redo: String?
    /// Recent changes seen by this server, oldest first.
    public var events: [ServiceEvent]
    /// The edit history, newest first.
    public var edits: [HistoryEdit]?
}

public struct ValidateRequest: ServiceCall {
    public static let operation = ServiceOperation.validate
    public init() {}

    public func run(on service: TandemService, context: CallContext) async throws -> ValidateResult {
        service.validate()
    }
}

public struct ValidateResult: Codable, Sendable {
    public var revision: Int
    /// True when there are no errors (warnings are fine).
    public var ok: Bool
    public var issues: [ValidationIssue]
}

// MARK: - frames and renders

public struct FrameRequest: ServiceCall {
    public static let operation = ServiceOperation.frame
    public var time: Time
    public var maxWidth: Int?
    public var maxHeight: Int?
    /// Write the PNG here (absolute, or relative to the project folder)
    /// instead of returning it as base64.
    public var output: String?
    /// An alternate output format ID, like `portrait`.
    public var format: String?

    public init(time: Time, maxWidth: Int? = nil, maxHeight: Int? = nil, output: String? = nil, format: String? = nil) {
        self.time = time
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.output = output
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let time = try c.decodeTime(.time) else {
            throw DecodingError.keyNotFound(CodingKeys.time, .init(codingPath: c.codingPath, debugDescription: "time is required"))
        }
        self.time = time
        maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth)
        maxHeight = try c.decodeIfPresent(Int.self, forKey: .maxHeight)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        format = try c.decodeIfPresent(String.self, forKey: .format)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ImageResult {
        try await service.withPresetFonts(try service.prepareFrame(self))()
    }
}

/// Several frames on one contact sheet, each labelled with its time.
public struct FramesRequest: ServiceCall {
    public static let operation = ServiceOperation.frames
    public var times: [Time]?
    /// A frame every this many seconds from `from` (default 0) to `to`
    /// (default the end of the timeline), as well as any `times`.
    public var every: Time?
    public var from: Time?
    public var to: Time?
    /// Each tile's width in pixels. Default 480.
    public var width: Int?
    /// Write the PNG here (absolute, or relative to the project folder)
    /// instead of returning it as base64.
    public var output: String?
    /// An alternate output format ID, like `portrait`.
    public var format: String?

    public init(times: [Time]? = nil, every: Time? = nil, from: Time? = nil, to: Time? = nil, width: Int? = nil, output: String? = nil, format: String? = nil) {
        self.times = times
        self.every = every
        self.from = from
        self.to = to
        self.width = width
        self.output = output
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.times), try !c.decodeNil(forKey: .times) {
            var list = try c.nestedUnkeyedContainer(forKey: .times)
            var times: [Time] = []
            while !list.isAtEnd {
                if let seconds = try? list.decode(Double.self) {
                    times.append(Time(seconds: seconds))
                    continue
                }
                let text = try list.decode(String.self)
                guard let time = TimeText.parse(text) else {
                    throw DecodingError.dataCorruptedError(in: list, debugDescription: "\"\(text)\" isn't a time. Use seconds (83.5) or mm:ss.mmm (01:23.500).")
                }
                times.append(time)
            }
            self.times = times
        }
        every = try c.decodeTime(.every)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        format = try c.decodeIfPresent(String.self, forKey: .format)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ImageResult {
        try await service.withPresetFonts(try service.prepareFrames(self))()
    }
}

public struct ScreenshotRequest: ServiceCall {
    public static let operation = ServiceOperation.screenshot
    public var output: String?

    public init(output: String? = nil) {
        self.output = output
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ImageResult {
        try await service.screenshot(output: output)
    }
}

public struct ImageResult: Codable, Sendable {
    public var time: Time?
    /// Where the PNG was written, when an output path was given.
    public var path: String?
    /// The PNG as base64, when no output path was given.
    public var png: String?
    public var bytes: Int
    /// What the picture shows differently from the project, like a camera
    /// without its cutout because the matte isn't made yet.
    public var warnings: [String]
    /// The frames on a contact sheet (`frames`), in order.
    public var times: [Time]?

    public init(time: Time?, path: String?, png: String?, bytes: Int, warnings: [String] = [], times: [Time]? = nil) {
        self.time = time
        self.path = path
        self.png = png
        self.bytes = bytes
        self.warnings = warnings
        self.times = times
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decodeIfPresent(Time.self, forKey: .time)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        png = try c.decodeIfPresent(String.self, forKey: .png)
        bytes = try c.decode(Int.self, forKey: .bytes)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        times = try c.decodeIfPresent([Time].self, forKey: .times)
    }
}

public struct ClipRequest: ServiceCall {
    public static let operation = ServiceOperation.clip
    public var start: Time
    public var end: Time
    public var output: String?
    /// Defaults to the 720p review preset.
    public var preset: String?
    /// Only these audio tracks play (names or IDs), at the timeline's own
    /// level: a stem isn't mastered.
    public var tracks: [String]?
    /// Sound alone, as a .m4a (or a .wav when `output` says so).
    public var audioOnly: Bool?

    public init(start: Time, end: Time, output: String? = nil, preset: String? = nil, tracks: [String]? = nil, audioOnly: Bool? = nil) {
        self.start = start
        self.end = end
        self.output = output
        self.preset = preset
        self.tracks = tracks
        self.audioOnly = audioOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let start = try c.decodeTime(.start) else {
            throw DecodingError.keyNotFound(CodingKeys.start, .init(codingPath: c.codingPath, debugDescription: "start is required"))
        }
        guard let end = try c.decodeTime(.end) else {
            throw DecodingError.keyNotFound(CodingKeys.end, .init(codingPath: c.codingPath, debugDescription: "end is required"))
        }
        self.start = start
        self.end = end
        output = try c.decodeIfPresent(String.self, forKey: .output)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        tracks = try c.decodeList(.tracks)
        audioOnly = try c.decodeIfPresent(Bool.self, forKey: .audioOnly)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ExportOutcome {
        try await service.withPresetFonts(try service.prepareClip(self))()
    }
}

public struct ExportRequest: ServiceCall {
    public static let operation = ServiceOperation.export
    /// A preset name (`youtube4k`, `youtube1080`, `review`, `short`). Nil
    /// picks the one that fits the canvas (`ExportPreset.standard(for:)`).
    public var preset: String?
    public var output: String?
    public var from: Time?
    public var to: Time?
    /// An alternate output format ID, like `portrait`.
    public var format: String?

    public init(preset: String? = nil, output: String? = nil, from: Time? = nil, to: Time? = nil, format: String? = nil) {
        self.preset = preset
        self.output = output
        self.from = from
        self.to = to
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        format = try c.decodeIfPresent(String.self, forKey: .format)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ExportOutcome {
        try await service.withPresetFonts(try service.prepareExport(self))()
    }
}

public struct ExportOutcome: Codable, Sendable {
    public var path: String
    public var preset: String
    /// The frame size, codec and bitrates it rendered with. An older app
    /// answering the CLI leaves them out.
    public var width: Int?
    public var height: Int?
    public var codec: ExportPreset.Codec?
    public var videoBitrate: Int?
    public var audioBitrate: Int?
    /// The alternate format rendered, like `portrait`; nil for the canvas.
    public var format: String?
    public var duration: Time
    /// The loudness it mastered to (the project's `loudnessTarget`), and
    /// the limiter's ceiling; nil when the mix was left as it is.
    public var loudnessTarget: Double?
    public var truePeakCeiling: Double?
    /// Measured on the mix before AAC encoding.
    public var integratedLUFS: Double?
    public var truePeakDBTP: Double?
    /// Seconds the render took.
    public var elapsed: Double
    /// What the render shows or plays differently from the project, and
    /// anything about the preset worth knowing, like an upscale.
    public var warnings: [String]
    /// The only audio tracks that played (`clip --tracks`), or nil for the
    /// whole mix.
    public var tracks: [String]?

    public init(path: String, preset: String, duration: Time, integratedLUFS: Double?, truePeakDBTP: Double?, elapsed: Double, warnings: [String] = []) {
        self.path = path
        self.preset = preset
        self.duration = duration
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.elapsed = elapsed
        self.warnings = warnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        preset = try c.decode(String.self, forKey: .preset)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        codec = try c.decodeIfPresent(ExportPreset.Codec.self, forKey: .codec)
        videoBitrate = try c.decodeIfPresent(Int.self, forKey: .videoBitrate)
        audioBitrate = try c.decodeIfPresent(Int.self, forKey: .audioBitrate)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        duration = try c.decode(Time.self, forKey: .duration)
        loudnessTarget = try c.decodeIfPresent(Double.self, forKey: .loudnessTarget)
        truePeakCeiling = try c.decodeIfPresent(Double.self, forKey: .truePeakCeiling)
        integratedLUFS = try c.decodeIfPresent(Double.self, forKey: .integratedLUFS)
        truePeakDBTP = try c.decodeIfPresent(Double.self, forKey: .truePeakDBTP)
        elapsed = try c.decode(Double.self, forKey: .elapsed)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        tracks = try c.decodeIfPresent([String].self, forKey: .tracks)
    }

    /// True when it wrote sound alone (a .m4a or .wav).
    var soundOnly: Bool { ExportOutcome.soundExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }

    static let soundExtensions: Set<String> = ["m4a", "wav"]
}

// MARK: - loudness, watch, effects

public struct LoudnessRequest: ServiceCall {
    public static let operation = ServiceOperation.loudness
    public var mediaID: String?
    /// With any of these it measures the rendered mix over time instead of
    /// reporting each file: from `from` (0) to `to` (the end) every `step`
    /// (picked to give about 50 rows), playing only `tracks` (names or
    /// IDs) when given. `gains` also checks each track's render against
    /// its gain lane. `over` lists the windows whose peak is over that
    /// many dBFS, merged into stretches (`peaks`).
    public var from: Time?
    public var to: Time?
    public var step: Time?
    public var tracks: [String]?
    public var gains: Bool?
    public var over: Double?

    public init(mediaID: String? = nil, from: Time? = nil, to: Time? = nil, step: Time? = nil, tracks: [String]? = nil, gains: Bool? = nil, over: Double? = nil) {
        self.mediaID = mediaID
        self.from = from
        self.to = to
        self.step = step
        self.tracks = tracks
        self.gains = gains
        self.over = over
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaID = try c.decodeIfPresent(String.self, forKey: .mediaID)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        step = try c.decodeTime(.step)
        tracks = try c.decodeList(.tracks)
        gains = try c.decodeIfPresent(Bool.self, forKey: .gains)
        over = try c.decodeIfPresent(Double.self, forKey: .over)
    }

    /// True when this asks about the rendered mix rather than the files.
    var overTime: Bool {
        from != nil || to != nil || step != nil || !(tracks ?? []).isEmpty || gains == true || over != nil
    }

    public func run(on service: TandemService, context: CallContext) async throws -> LoudnessResult {
        try await service.loudness(self)
    }
}

public struct MediaLoudness: Codable, Sendable {
    public var mediaID: String
    public var path: String
    public var integratedLUFS: Double?
    public var truePeakDBTP: Double?
    public var loudnessRange: Double?
    /// `ready`, or the analysis job's state.
    public var state: String
}

/// How loud a timeline clip plays relative to its file.
public struct ClipLevel: Codable, Sendable {
    public var clipID: String
    public var mediaID: String
    public var track: String
    /// Clip gain, added after normalisation.
    public var gainDB: Double
    public var normalizeTo: Double?
    /// The gain normalisation adds (target minus measured, within ±30 dB;
    /// 0 for a silent file), once the file's loudness is known.
    public var normalizeGainDB: Double?
    /// Speech (camera or voice sound, or on a take track): what
    /// `normalizeSpeech` levels.
    public var speech: Bool
    /// The highest true peak it plays at, in dBTP, once its file is
    /// measured: the file's peak plus levelling and clip gain (before any
    /// limiter, fades or gain keyframes).
    public var peakDBTP: Double?
    /// The ceiling of the limiter holding its peaks, when it has one on.
    public var limiterCeiling: Double?
    /// The clip or its track is muted, so it isn't heard.
    public var muted: Bool
}

public struct LoudnessResult: Codable, Sendable {
    /// The master's loudness target, in LUFS.
    public var target: Double
    public var truePeakCeiling: Double
    /// The level speech clips are normalised to, in LUFS.
    public var speechLoudness: Double
    public var media: [MediaLoudness]
    public var clips: [ClipLevel]
    /// The rendered mix over time, when a range, step or tracks were asked
    /// for.
    public var curve: MixLoudness?
    /// The audio tracks that played for `curve`, or nil for the whole mix.
    public var tracks: [String]?
    /// Each track's render against its gain lane, when asked.
    public var gains: [GainFollow]?
    /// Where the mix peaks over the level asked for (`over`).
    public var peaks: LoudnessPeaks?
}

/// The windows of a loudness curve whose peak is over a level, merged into
/// stretches: the direct answer to "where does this clip".
public struct LoudnessPeaks: Codable, Equatable, Sendable {
    /// The level, in dBFS.
    public var threshold: Double
    /// How many windows peak over it.
    public var windows: Int
    public var stretches: [PeakStretch]
}

/// Neighbouring windows over the level, from the first one's start to the
/// last one's end (each window is the 400 ms centred on its time).
public struct PeakStretch: Codable, Equatable, Sendable {
    public var start: Time
    public var end: Time
    /// The highest sample in the stretch.
    public var peakDBFS: Double
    public var windows: Int
}

public struct WatchRequest: ServiceCall {
    public static let operation = ServiceOperation.watch
    /// Wait for the project to move past this revision. Defaults to the
    /// current revision, so the call waits for the next change.
    public var revision: Int?
    /// Seconds to wait before giving up. Default 30, at most 600.
    public var timeout: Double?

    public init(revision: Int? = nil, timeout: Double? = nil) {
        self.revision = revision
        self.timeout = timeout
    }

    public func run(on service: TandemService, context: CallContext) async throws -> WatchResult {
        await service.watch(after: revision, timeout: timeout ?? 30)
    }
}

public struct WatchResult: Codable, Sendable {
    public var revision: Int
    /// False when the wait timed out with no change.
    public var changed: Bool
    /// The changes this server saw after the requested revision.
    public var events: [ServiceEvent]
    public var jobs: [JobStatus]
}

public struct EffectsRequest: ServiceCall {
    public static let operation = ServiceOperation.effects
    /// One effect type, or all of them.
    public var type: String?

    public init(type: String? = nil) {
        self.type = type
    }

    public func run(on service: TandemService, context: CallContext) async throws -> EffectsResult {
        try EffectsResult.catalog(type: type)
    }
}

public struct TransitionInfo: Codable, Sendable {
    public var type: TransitionType
    public var defaultDuration: Time
}

public struct LayoutInfo: Codable, Sendable {
    public var preset: LayoutPreset
    public var name: String
}

public struct EffectsResult: Codable, Sendable {
    public var effects: [EffectDefinition]
    public var transitions: [TransitionInfo]
    public var layouts: [LayoutInfo]
    /// Parameter paths `setKeyframes` animates.
    public var animatable: [String]

    /// The built-in catalogue, which doesn't need a project.
    public static func catalog(type: String? = nil) throws -> EffectsResult {
        var effects = EffectRegistry.standard.sorted
        if let type {
            effects = effects.filter { $0.type.caseInsensitiveCompare(type) == .orderedSame }
            guard !effects.isEmpty else {
                let known = EffectRegistry.standard.sorted.map(\.type).joined(separator: ", ")
                throw ServiceError(.notFound, "No effect called \"\(type)\". Known effects: \(known).")
            }
        }
        return EffectsResult(
            effects: effects,
            transitions: TransitionType.allCases.map { TransitionInfo(type: $0, defaultDuration: $0.defaultDuration) },
            layouts: LayoutPreset.allCases.map { LayoutInfo(preset: $0, name: $0.name) },
            animatable: AnimatableParameter.fixed + ["video.effects.<effectID>.<param>", "audio.effects.<effectID>.<param>"]
        )
    }
}
