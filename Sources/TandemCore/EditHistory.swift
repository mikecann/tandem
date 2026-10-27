import Foundation

// What changed on the timeline, clip by clip, and the edit history that
// remembers it. `tandem history` says where each edit was, `tandem diff`
// says what changed since a revision, a backup or an export, and
// `tandem restore` puts clips back as they were. All three work on clips
// only: media, markers, transitions and settings aren't compared.

/// A clip and the track it's on.
public struct PlacedClip: Codable, Equatable, Sendable {
    public var clip: Clip
    public var trackID: String
    /// The track as `timeline` names it ("V2 Camera"), when this was read.
    public var track: String

    public init(clip: Clip, trackID: String, track: String) {
        self.clip = clip
        self.trackID = trackID
        self.track = track
    }
}

/// Every clip on a timeline, by ID, with its track.
public struct TimelineClips: Equatable, Sendable {
    public var clips: [String: PlacedClip]

    public init(_ clips: [String: PlacedClip] = [:]) {
        self.clips = clips
    }

    public init(_ project: Project) {
        let labels = TrackLabels.of(project)
        var clips: [String: PlacedClip] = [:]
        for track in project.allTracks {
            for clip in track.clips {
                clips[clip.id] = PlacedClip(clip: clip, trackID: track.id, track: labels[track.id] ?? track.name)
            }
        }
        self.clips = clips
    }

    public subscript(id: String) -> PlacedClip? {
        get { clips[id] }
        set { clips[id] = newValue }
    }

    /// The same clips in the same places, allowing for times that went
    /// through a save (which rounds them to the microsecond).
    public func matches(_ other: TimelineClips) -> Bool {
        guard clips.count == other.clips.count else { return false }
        return clips.allSatisfy { id, placed in
            guard let theirs = other.clips[id] else { return false }
            return placed.trackID == theirs.trackID && ClipChanges.same(placed.clip, theirs.clip)
        }
    }
}

/// Tracks named the way `timeline` names them.
public enum TrackLabels {
    /// "V2 Camera", "A1 Voice" by track ID.
    public static func of(_ project: Project) -> [String: String] {
        var labels: [String: String] = [:]
        for (index, track) in project.videoTracks.enumerated() { labels[track.id] = "V\(index + 1) \(track.name)" }
        for (index, track) in project.audioTracks.enumerated() { labels[track.id] = "A\(index + 1) \(track.name)" }
        return labels
    }

    /// The track `reference` names: its ID, its name ignoring case, or its
    /// label ("V2", "V2 Camera"). Nil when none does.
    public static func find(_ reference: String, in project: Project) -> Track? {
        if let track = project.track(reference) { return track }
        let named = project.allTracks.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
        if named.count == 1 { return named[0] }
        let labels = of(project)
        return project.allTracks.first { track in
            guard let label = labels[track.id] else { return false }
            return label.caseInsensitiveCompare(reference) == .orderedSame
                || String(label.prefix { $0 != " " }).caseInsensitiveCompare(reference) == .orderedSame
        }
    }
}

// MARK: - What changed

/// One clip that's different between two timelines.
public struct ClipChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, removed, changed }

    public var id: String
    public var kind: Kind
    /// Where it is now (where it was, for a removed clip).
    public var track: String
    public var trackID: String
    public var start: Time
    public var end: Time
    /// What it plays: the file's name, or a title's words.
    public var content: String
    /// Where it was, when that changed.
    public var wasTrack: String?
    public var wasStart: Time?
    public var wasEnd: Time?
    /// What changed, in words: "start +0.500s", "gain -6 -> -3 dB".
    public var details: [String]
    /// Set when all it did was move along its track by this much, as
    /// clips riding a ripple do.
    public var shift: Time?
    /// The clip either side.
    public var before: Clip?
    public var after: Clip?
}

public enum ClipChanges {
    /// Smaller differences are rounding, not edits.
    static let tolerance = Time(seconds: 0.0005)

    /// Short names for media in `projects`, the first one that has an ID
    /// winning: the file name, or the path when two files share a name.
    public static func mediaNames(_ projects: Project...) -> [String: String] {
        var names: [String: String] = [:]
        for project in projects {
            var counts: [String: Int] = [:]
            for item in project.media { counts[(item.path as NSString).lastPathComponent, default: 0] += 1 }
            for item in project.media where names[item.id] == nil {
                let name = (item.path as NSString).lastPathComponent
                names[item.id] = (counts[name] ?? 0) > 1 ? item.path : name
            }
        }
        return names
    }

    /// The clips that differ, in timeline order.
    public static func between(_ old: TimelineClips, _ new: TimelineClips, names: [String: String] = [:]) -> [ClipChange] {
        var changes: [ClipChange] = []
        for (id, now) in new.clips {
            guard let was = old.clips[id] else {
                changes.append(ClipChange(
                    id: id, kind: .added, track: now.track, trackID: now.trackID, start: now.clip.start, end: now.clip.end,
                    content: content(now.clip, names: names), details: [], after: now.clip
                ))
                continue
            }
            guard was.trackID != now.trackID || !same(was.clip, now.clip) else { continue }
            var change = ClipChange(
                id: id, kind: .changed, track: now.track, trackID: now.trackID, start: now.clip.start, end: now.clip.end,
                content: content(now.clip, names: names), details: [], before: was.clip, after: now.clip
            )
            let movedTrack = was.trackID != now.trackID
            if movedTrack || !near(was.clip.start, now.clip.start) || !near(was.clip.end, now.clip.end) {
                change.wasStart = was.clip.start
                change.wasEnd = was.clip.end
                if movedTrack { change.wasTrack = was.track }
            }
            (change.details, change.shift) = describe(was, now, names: names)
            changes.append(change)
        }
        for (id, was) in old.clips where new.clips[id] == nil {
            changes.append(ClipChange(
                id: id, kind: .removed, track: was.track, trackID: was.trackID, start: was.clip.start, end: was.clip.end,
                content: content(was.clip, names: names), details: [], before: was.clip
            ))
        }
        markPieces(&changes)
        return changes.sorted {
            let a = EditPlace.order($0.track), b = EditPlace.order($1.track)
            return ($0.start, a.0, a.1, $0.id) < ($1.start, b.0, b.1, $1.id)
        }
    }

    /// A clip cut in two keeps its ID on the left and the right gets a new
    /// one, so a cut reads as a shorter clip and a new one. Say so instead:
    /// a new clip on the same track playing more of what a shortened clip
    /// played is the rest of it.
    private static func markPieces(_ changes: inout [ClipChange]) {
        for index in changes.indices where changes[index].kind == .added {
            guard let piece = changes[index].after, let mediaID = piece.mediaID else { continue }
            guard let left = changes.firstIndex(where: { change in
                guard change.kind == .changed, change.trackID == changes[index].trackID,
                      let was = change.before, let now = change.after, was.mediaID == mediaID, now.mediaID == mediaID,
                      now.duration < was.duration, near(now.start, was.start), piece.start >= now.end - tolerance,
                      was.speed == piece.speed else { return false }
                return piece.sourceStart >= now.sourceEnd - tolerance && piece.sourceEnd <= was.sourceEnd + tolerance
            }) else { continue }
            let leftID = changes[left].id
            changes[index].details = ["the rest of \(leftID) after a cut"]
            changes[left].details = changes[left].details.map { $0.hasPrefix("end ") ? "cut at \(changes[left].end), the rest is \(changes[index].id)" : $0 }
        }
    }

    /// Two clips the same, allowing for rounding in their times.
    public static func same(_ a: Clip, _ b: Clip) -> Bool {
        if a == b { return true }
        guard near(a.start, b.start), near(a.duration, b.duration), near(a.sourceStart, b.sourceStart) else { return false }
        var b = b
        b.start = a.start
        b.duration = a.duration
        b.sourceStart = a.sourceStart
        return a == b
    }

    static func near(_ a: Time, _ b: Time) -> Bool {
        abs(a.flicks - b.flicks) < tolerance.flicks
    }

    /// What the clip plays, as `timeline` says it.
    public static func content(_ clip: Clip, names: [String: String]) -> String {
        switch clip.content {
        case .media(let mediaID): return names[mediaID] ?? mediaID
        case .text(let text): return "text \"\(shorten(text.text.replacingOccurrences(of: "\n", with: " / "), 40))\""
        case .graphic(let graphic): return graphic.template == SectionCard.template ? "section card" : "graphic \(graphic.template)"
        case .solid: return "solid"
        case .adjustment: return "adjustment"
        }
    }

    static func shorten(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 3)) + "..." : text
    }

    // MARK: Describing a change

    static func describe(_ was: PlacedClip, _ now: PlacedClip, names: [String: String]) -> (details: [String], shift: Time?) {
        let a = was.clip, b = now.clip
        var details: [String] = []
        var shift: Time?
        if was.trackID != now.trackID { details.append("track \(was.track) -> \(now.track)") }

        let dStart = b.start - a.start
        let dEnd = b.end - a.end
        let dSource = b.sourceStart - a.sourceStart
        if near(dStart, dEnd) && !near(dStart, .zero) && near(dSource, .zero) {
            details.append("moved \(signed(dStart))")
            shift = dStart
        } else if let trimmed = rippledHeadTrim(a, b) {
            details.append("start trimmed \(signed(trimmed)), rippled")
        } else {
            if !near(dStart, .zero) { details.append("start \(signed(dStart))") }
            if !near(dEnd, .zero) { details.append("end \(signed(dEnd))") }
            // Trimming the start moves the source in by as much (times the
            // speed); anything more is a slip.
            let slip = dSource - (a.speed == b.speed ? dStart.scaled(by: b.speed) : dSource)
            if !near(slip, .zero) && !b.freezeFrame { details.append("slipped \(signed(slip))") }
        }
        if a.speed != b.speed { details.append("speed \(number(a.speed)) -> \(number(b.speed))") }
        if a.enabled != b.enabled { details.append(b.enabled ? "turned on" : "turned off") }
        if a.freezeFrame != b.freezeFrame { details.append(b.freezeFrame ? "freeze frame on" : "freeze frame off") }
        if a.holdEdges != b.holdEdges { details.append(b.holdEdges ? "holds its edges" : "stops holding its edges") }
        if a.content != b.content { details.append(contentChange(a, b, names: names)) }
        if a.name != b.name { details.append("name \(quoted(a.name)) -> \(quoted(b.name))") }
        if a.linkGroup != b.linkGroup {
            details.append(a.linkGroup == nil ? "linked" : b.linkGroup == nil ? "unlinked" : "linked to other clips")
        }
        if a.video != b.video { details += videoChanges(a.video ?? VideoProperties(), b.video ?? VideoProperties()) }
        if a.audio != b.audio { details += audioChanges(a.audio ?? AudioProperties(), b.audio ?? AudioProperties()) }
        for key in Set(a.keyframes.keys).union(b.keyframes.keys).sorted() where a.keyframes[key] != b.keyframes[key] {
            let before = a.keyframes[key] ?? [], after = b.keyframes[key] ?? []
            if before.isEmpty {
                details.append("keyframes \(key) (\(after.count))")
            } else if after.isEmpty {
                details.append("keyframes \(key) removed")
            } else {
                details.append(before.count == after.count ? "keyframes \(key) changed" : "keyframes \(key) (\(before.count) -> \(after.count))")
            }
        }
        if a.tags != b.tags { details.append("tags \(a.tags.joined(separator: ",")) -> \(b.tags.joined(separator: ","))") }
        if details.isEmpty { details.append("settings") }
        if details.count > 1 || was.trackID != now.trackID { shift = nil }
        return (details, shift)
    }

    /// How much a ripple trim took off the start: the clip still starts
    /// where it did, its source starts later and its end came in by as much.
    static func rippledHeadTrim(_ a: Clip, _ b: Clip) -> Time? {
        guard a.speed == b.speed, !b.freezeFrame, near(a.start, b.start) else { return nil }
        let source = b.sourceStart - a.sourceStart
        guard !near(source, .zero) else { return nil }
        let timeline = source.scaled(by: 1 / b.speed)
        return near(b.end - a.end, -timeline) ? timeline : nil
    }

    private static func contentChange(_ a: Clip, _ b: Clip, names: [String: String]) -> String {
        switch (a.content, b.content) {
        case (.media(let x), .media(let y)):
            return "media \(names[x] ?? x) -> \(names[y] ?? y)"
        case (.text(let x), .text(let y)):
            return x.text == y.text ? "title style" : "text \(quoted(x.text)) -> \(quoted(y.text))"
        case (.graphic, .graphic):
            return "graphic settings"
        default:
            return "content \(content(a, names: names)) -> \(content(b, names: names))"
        }
    }

    private static func videoChanges(_ a: VideoProperties, _ b: VideoProperties) -> [String] {
        var details: [String] = []
        if a.transform.position != b.transform.position {
            details.append("position \(number(a.transform.position.x)),\(number(a.transform.position.y)) -> \(number(b.transform.position.x)),\(number(b.transform.position.y))")
        }
        if a.transform.scale != b.transform.scale { details.append("scale \(number(a.transform.scale)) -> \(number(b.transform.scale))") }
        if a.transform.rotation != b.transform.rotation { details.append("rotation \(number(a.transform.rotation)) -> \(number(b.transform.rotation))") }
        if a.transform.flipped != b.transform.flipped { details.append(b.transform.flipped ? "flipped" : "unflipped") }
        if a.crop != b.crop { details.append("crop") }
        if a.opacity != b.opacity { details.append("opacity \(number(a.opacity)) -> \(number(b.opacity))") }
        if a.cutout != b.cutout { details.append(a.cutout == nil ? "cutout on" : b.cutout == nil ? "cutout off" : "cutout settings") }
        if a.effects != b.effects { details.append(effectChange(a.effects, b.effects, what: "effects")) }
        if a.layoutPreset != b.layoutPreset { details.append("layout \(a.layoutPreset ?? "none") -> \(b.layoutPreset ?? "none")") }
        if a.formatOverrides != b.formatOverrides {
            let formats = Set(a.formatOverrides.keys).union(b.formatOverrides.keys).filter { a.formatOverrides[$0] != b.formatOverrides[$0] }
            details.append("placement in \(formats.sorted().joined(separator: ", "))")
        }
        if details.isEmpty { details.append("picture settings") }
        return details
    }

    private static func audioChanges(_ a: AudioProperties, _ b: AudioProperties) -> [String] {
        var details: [String] = []
        if a.gainDB != b.gainDB { details.append("gain \(number(a.gainDB)) -> \(number(b.gainDB)) dB") }
        if !near(a.fadeIn, b.fadeIn) { details.append("fade in \(seconds(a.fadeIn)) -> \(seconds(b.fadeIn))") }
        if !near(a.fadeOut, b.fadeOut) { details.append("fade out \(seconds(a.fadeOut)) -> \(seconds(b.fadeOut))") }
        if a.muted != b.muted { details.append(b.muted ? "muted" : "unmuted") }
        if a.normalizeTo != b.normalizeTo {
            details.append("level \(a.normalizeTo.map { "\(number($0)) LUFS" } ?? "off") -> \(b.normalizeTo.map { "\(number($0)) LUFS" } ?? "off")")
        }
        if a.voiceIsolation != b.voiceIsolation { details.append("voice isolation \(number(a.voiceIsolation)) -> \(number(b.voiceIsolation))") }
        if a.effects != b.effects { details.append(effectChange(a.effects, b.effects, what: "audio effects")) }
        if details.isEmpty { details.append("sound settings") }
        return details
    }

    private static func effectChange(_ a: [Effect], _ b: [Effect], what: String) -> String {
        let before = Set(a.map(\.id)), after = Set(b.map(\.id))
        let added = b.filter { !before.contains($0.id) }.map { "+\($0.type)" }
        let removed = a.filter { !after.contains($0.id) }.map { "-\($0.type)" }
        let listed = added + removed
        return listed.isEmpty ? "\(what) settings" : "\(what) \(listed.joined(separator: " "))"
    }

    static func signed(_ time: Time) -> String {
        String(format: "%+.3fs", time.seconds)
    }

    static func seconds(_ time: Time) -> String {
        String(format: "%.3fs", time.seconds)
    }

    static func number(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 { return String(Int(value)) }
        return String(format: "%g", (value * 10000).rounded() / 10000)
    }

    private static func quoted(_ text: String?) -> String {
        text.map { "\"\(shorten($0.replacingOccurrences(of: "\n", with: " / "), 32))\"" } ?? "none"
    }
}

// MARK: - Where an edit was

/// The stretch of the timeline an edit touched, and on which tracks.
public struct EditPlace: Codable, Equatable, Sendable, CustomStringConvertible {
    public var start: Time
    public var end: Time
    /// Track labels ("V2 Camera"), in timeline order.
    public var tracks: [String]

    public init(start: Time, end: Time, tracks: [String]) {
        self.start = start
        self.end = end
        self.tracks = tracks
    }

    /// "00:12.000-00:14.000 on V2 Camera, A1 Voice", or "at 00:12.500 on
    /// A2 Music" for a cut.
    public var description: String {
        let when = start == end ? "at \(start)" : "\(start)-\(end)"
        return tracks.isEmpty ? when : "\(when) on \(tracks.joined(separator: ", "))"
    }

    /// Where the change from `before` to `after` was. The review diff
    /// tells an edit from what rode along with it (clips a ripple moved,
    /// a music bed it shortened), so it decides which clips count; a cut,
    /// which it doesn't count as news, falls back to `of(_:)`.
    public static func between(_ before: Project, _ after: Project) -> EditPlace? {
        between(before, after, changes: ClipChanges.between(TimelineClips(before), TimelineClips(after)))
    }

    static func between(_ before: Project, _ after: Project, changes: [ClipChange]) -> EditPlace? {
        guard !changes.isEmpty else { return nil }
        let review = ReviewDiff.between(before, after)
        let byID = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let labels = TrackLabels.of(after).merging(TrackLabels.of(before)) { now, _ in now }
        var ranges: [(Time, Time)] = []
        var tracks: [String] = []
        func note(_ track: String) { if !tracks.contains(track) { tracks.append(track) } }
        for id in review.added + review.changed {
            guard let change = byID[id] else { continue }
            ranges.append(range(of: change))
            note(change.track)
            if let wasTrack = change.wasTrack { note(wasTrack) }
        }
        for removal in review.removals {
            ranges.append((removal.time, removal.time + removal.duration))
            note(labels[removal.trackID] ?? removal.trackID)
        }
        guard let start = ranges.map(\.0).min(), let end = ranges.map(\.1).max() else { return of(changes) }
        return EditPlace(start: start, end: end, tracks: tracks.sorted { order($0) < order($1) })
    }

    /// Where `changes` were, without the projects either side. Clips that
    /// only moved along their track (riding a ripple) don't count unless
    /// that's all there is. A clip cut in two counts as the point of the
    /// cut, not the half that got a new ID.
    public static func of(_ changes: [ClipChange]) -> EditPlace? {
        guard !changes.isEmpty else { return nil }
        let core = changes.filter { $0.shift == nil }
        let used = core.isEmpty ? changes : core
        // Cuts: a new clip that starts where a clip on its track now ends
        // and runs to where that clip used to end.
        var cutLeft = Set<String>()
        var cutRight = Set<String>()
        for added in used where added.kind == .added {
            if let left = used.first(where: {
                $0.kind == .changed && $0.trackID == added.trackID && $0.wasEnd.map { ClipChanges.near($0, added.end) } == true
                    && ClipChanges.near($0.end, added.start)
            }) {
                cutLeft.insert(left.id)
                cutRight.insert(added.id)
            }
        }
        var ranges: [(Time, Time)] = []
        var tracks: [String] = []
        for change in used {
            if !tracks.contains(change.track) { tracks.append(change.track) }
            if let wasTrack = change.wasTrack, !tracks.contains(wasTrack) { tracks.append(wasTrack) }
            if cutRight.contains(change.id) {
                ranges.append((change.start, change.start))
            } else if cutLeft.contains(change.id) {
                ranges.append((change.end, change.end))
            } else {
                ranges.append(range(of: change))
            }
        }
        let start = ranges.map(\.0).min() ?? .zero
        let end = ranges.map(\.1).max() ?? .zero
        return EditPlace(start: start, end: end, tracks: tracks.sorted { order($0) < order($1) })
    }

    /// The stretch one change touched: a clip added or removed, where a
    /// moved clip was and is, the stretch between where a trimmed edge was
    /// and is, or the clip itself when only its settings changed.
    static func range(of change: ClipChange) -> (Time, Time) {
        guard change.kind == .changed, let wasStart = change.wasStart, let wasEnd = change.wasEnd else {
            if let before = change.before, let after = change.after, let trimmed = ClipChanges.rippledHeadTrim(before, after) {
                return (before.start, before.start + trimmed)
            }
            return (change.start, change.end)
        }
        if let before = change.before, let after = change.after, let trimmed = ClipChanges.rippledHeadTrim(before, after) {
            return (before.start, before.start + trimmed)
        }
        if change.wasTrack != nil || change.shift != nil || ClipChanges.near(change.start - wasStart, change.end - wasEnd) {
            return (min(wasStart, change.start), max(wasEnd, change.end))
        }
        var ranges: [(Time, Time)] = []
        if !ClipChanges.near(wasStart, change.start) { ranges.append((min(wasStart, change.start), max(wasStart, change.start))) }
        if !ClipChanges.near(wasEnd, change.end) { ranges.append((min(wasEnd, change.end), max(wasEnd, change.end))) }
        guard let start = ranges.map(\.0).min(), let end = ranges.map(\.1).max() else { return (change.start, change.end) }
        return (start, end)
    }

    /// V tracks top down (V5 before V1), then A tracks in order, as the
    /// timeline shows them.
    static func order(_ label: String) -> (Int, Int, String) {
        let code = label.prefix { $0 != " " }
        guard let kind = code.first, let index = Int(code.dropFirst()) else { return (2, 0, label) }
        return kind == "V" ? (0, -index, label) : (1, index, label)
    }
}

// MARK: - The edit history

/// One change to the project, as `.tandem/<name>.history.jsonl` keeps it:
/// who made it, where it was, and enough to take its clips back to how they
/// were before it.
public struct HistoryRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case edit, undo, redo, reload
        /// The project was opened at this revision and the history before
        /// it doesn't lead here (it was edited by something that kept none).
        case opened
    }

    /// The revision the change made.
    public var revision: Int
    public var kind: Kind
    public var label: String
    public var author: String
    public var date: Date
    public var place: EditPlace?
    /// Counts, like "1 changed, 14 moved", and what else changed ("2 media added").
    public var summary: String?
    /// Going back: the clips it added,
    public var added: [String]?
    /// the clips it changed or removed, as they were,
    public var before: [PlacedClip]?
    /// and the clips that only moved along their track, by how much.
    public var shifted: [String: Time]?

    public init(revision: Int, kind: Kind, label: String, author: String, date: Date = Date()) {
        self.revision = revision
        self.kind = kind
        self.label = label
        self.author = author
        self.date = date
    }

    /// The record of a change from `before` to `after`.
    public static func change(_ kind: Kind, revision: Int, label: String, author: String, date: Date = Date(), before: Project, after: Project) -> HistoryRecord {
        var record = HistoryRecord(revision: revision, kind: kind, label: label, author: author, date: date)
        let old = TimelineClips(before)
        let changes = ClipChanges.between(old, TimelineClips(after))
        record.place = EditPlace.between(before, after, changes: changes)
        var added: [String] = [], previous: [PlacedClip] = [], shifted: [String: Time] = [:]
        for change in changes {
            if change.kind == .added {
                added.append(change.id)
            } else if let shift = change.shift {
                shifted[change.id] = shift
            } else if let was = old[change.id] {
                previous.append(was)
            }
        }
        record.added = added.isEmpty ? nil : added
        record.before = previous.isEmpty ? nil : previous
        record.shifted = shifted.isEmpty ? nil : shifted
        record.summary = summary(changes, before: before, after: after)
        return record
    }

    /// The clips as they were before this change, given them after it.
    func undoing(_ clips: TimelineClips) -> TimelineClips {
        var clips = clips
        for id in added ?? [] { clips[id] = nil }
        for (id, shift) in shifted ?? [:] { clips[id]?.clip.start -= shift }
        for placed in before ?? [] { clips[placed.clip.id] = placed }
        return clips
    }

    static func summary(_ changes: [ClipChange], before: Project, after: Project) -> String? {
        var parts: [String] = []
        func count(_ n: Int, _ what: String) { if n > 0 { parts.append("\(n) \(what)") } }
        count(changes.filter { $0.kind == .added }.count, "added")
        count(changes.filter { $0.kind == .removed }.count, "removed")
        count(changes.filter { $0.kind == .changed && $0.shift == nil }.count, "changed")
        count(changes.filter { $0.shift != nil }.count, "moved")
        let oldMedia = Set(before.media.map(\.id)), newMedia = Set(after.media.map(\.id))
        count(newMedia.subtracting(oldMedia).count, "media added")
        count(oldMedia.subtracting(newMedia).count, "media removed")
        if oldMedia == newMedia && before.media != after.media { parts.append("media details") }
        if before.markers != after.markers { parts.append("markers") }
        func shape(_ track: Track) -> Track { var track = track; track.clips = []; track.transitions = []; return track }
        if before.allTracks.map(shape) != after.allTracks.map(shape) { parts.append("tracks") }
        if before.allTracks.map(\.transitions) != after.allTracks.map(\.transitions) { parts.append("transitions") }
        if before.settings != after.settings { parts.append("settings") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The history before a revision isn't kept.
public struct HistoryGap: Error, Equatable, Sendable {
    /// The earliest revision the history goes back to.
    public var earliest: Int
}

public enum HistoryChain {
    /// Walks the history back from `currentRevision` to `revision`: the
    /// records in between, oldest first, and the clips at each step
    /// (`states[0]` at `revision`, `states[i + 1]` after `records[i]`).
    ///
    /// Each record is the change that made its revision, so going back
    /// means finding the record of each revision in turn, newest first. A
    /// revision with no record, or an `opened` record in the way (the
    /// project changed somewhere that kept no history), ends the walk.
    public static func walk(_ records: [HistoryRecord], current: TimelineClips, currentRevision: Int, back revision: Int) throws -> (records: [HistoryRecord], states: [TimelineClips]) {
        guard revision <= currentRevision else {
            throw EditError.invalid("Revision \(revision) is newer than the project, which is at revision \(currentRevision).")
        }
        var chain: [HistoryRecord] = []
        var states = [current]
        var at = currentRevision
        var index = records.count - 1
        while at > revision {
            var found: HistoryRecord?
            while index >= 0 {
                let record = records[index]
                index -= 1
                if record.kind == .opened { break }
                if record.revision == at {
                    found = record
                    break
                }
            }
            guard let record = found else { throw HistoryGap(earliest: at) }
            chain.append(record)
            states.append(record.undoing(states[states.count - 1]))
            at -= 1
        }
        return (chain.reversed(), states.reversed())
    }

    /// The earliest revision `records` reach back to from `currentRevision`.
    public static func earliest(_ records: [HistoryRecord], currentRevision: Int) -> Int {
        var at = currentRevision
        var index = records.count - 1
        while index >= 0 {
            let record = records[index]
            index -= 1
            if record.kind == .opened { break }
            if record.revision == at { at -= 1 }
        }
        return at
    }
}

/// `.tandem/<name>.history.jsonl`: one line per change to the project,
/// appended as it commits, whoever has the project open (the app, `tandem
/// serve`, each CLI command). It outlives restarts, unlike the undo stack.
public final class EditHistoryLog: @unchecked Sendable {
    /// When the file grows past this, the older half goes.
    public static let maxBytes = 24 << 20

    public var url: URL { folder.url.appendingPathComponent(fileName) }
    private let folder: FolderAnchor
    private let fileName: String

    public init(url: URL) {
        folder = FolderAnchor(url.deletingLastPathComponent())
        fileName = url.lastPathComponent
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func append(_ record: HistoryRecord) {
        guard var line = try? Self.encoder().encode(record) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // A last line cut short by a crash would swallow this one.
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, info.st_size - 1) == 1, last != 0x0A { line.insert(0x0A, at: 0) }
        }
        line.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// Every record, oldest first. A line that doesn't read (cut short by
    /// a crash) is skipped.
    public func records() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = Self.decoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(HistoryRecord.self, from: Data($0)) }
    }

    /// The revision of the last record, read from the end of the file so a
    /// long history doesn't slow every CLI command down.
    public func lastRevision() -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        var chunk: UInt64 = 64 << 10
        while true {
            let offset = size > chunk ? size - chunk : 0
            try? handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            var lines = data.split(separator: 0x0A)
            // Unless the chunk starts the file, its first line may be partial.
            if offset > 0, !lines.isEmpty { lines.removeFirst() }
            struct Header: Decodable { var revision: Int }
            for line in lines.reversed() {
                if let header = try? JSONDecoder().decode(Header.self, from: Data(line)) { return header.revision }
            }
            if offset == 0 { return nil }
            chunk *= 4
        }
    }

    /// Drops the older half once the file passes `maxBytes`.
    public func trim(maxBytes: Int = EditHistoryLog.maxBytes) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        var kept = Data()
        for line in lines.suffix(lines.count / 2) {
            kept.append(contentsOf: line)
            kept.append(0x0A)
        }
        try? kept.write(to: url, options: .atomic)
    }
}

/// Keeps a project's edit history as its coordinator commits, on its own
/// queue. Every session has one, so the history carries on from the app
/// to the CLI and back, and across restarts.
public final class HistoryRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.history")
    private let coordinator: ProjectCoordinator
    public let log: EditHistoryLog?
    private var token: UUID?
    private var closed = false
    /// Where the history starts again, written with the first change so
    /// that opening a project to read it leaves the folder as it was.
    private var opening: HistoryRecord?

    /// `url` is `ProjectFile.historyURL(for:)`; nil keeps no history.
    /// `replayed` is what the journal put back after a crash, which no
    /// recorder heard committing.
    public init(coordinator: ProjectCoordinator, url: URL?, replayed: [(entry: ProjectJournal.Entry, before: Project, after: Project)] = []) {
        self.coordinator = coordinator
        log = url.map(EditHistoryLog.init(url:))
        if let log {
            let revision = coordinator.revision
            queue.sync {
                log.trim()
                let last = log.lastRevision()
                let base = replayed.first.map { $0.entry.revision - 1 } ?? revision
                if last != base {
                    opening = HistoryRecord(revision: base, kind: .opened, label: "Opened", author: EditAuthor.system)
                }
                for (entry, before, after) in replayed {
                    writeOpening()
                    let (kind, label, author) = Self.describe(entry)
                    log.append(.change(kind, revision: entry.revision, label: label, author: author, date: entry.date, before: before, after: after))
                }
            }
        }
        token = coordinator.observe { [weak self] event in self?.heard(event) }
    }

    /// Every record, oldest first, once the changes already heard are in.
    public func records() -> [HistoryRecord] {
        queue.sync { (log?.records() ?? []) + (opening.map { [$0] } ?? []) }
    }

    /// On the queue.
    private func writeOpening() {
        guard let record = opening else { return }
        log?.append(record)
        opening = nil
    }

    /// Finishes what it has heard and stops listening.
    public func close() {
        if let token { coordinator.removeObserver(token) }
        token = nil
        queue.sync { closed = true }
    }

    private static func describe(_ entry: ProjectJournal.Entry) -> (HistoryRecord.Kind, String, String) {
        if let batch = entry.batch { return (.edit, batch.label, batch.author) }
        let reason = entry.reason ?? "reload"
        if reason.hasPrefix("undo ") { return (.undo, String(reason.dropFirst(5)), EditAuthor.system) }
        if reason.hasPrefix("redo ") { return (.redo, String(reason.dropFirst(5)), EditAuthor.system) }
        return (.reload, "Reload", EditAuthor.system)
    }

    /// Runs inside the coordinator's queue, so it only queues the work.
    private func heard(_ event: ProjectCoordinator.ChangeEvent) {
        queue.async { [weak self] in
            guard let self, !self.closed, let log = self.log, let before = event.before, let after = event.after else { return }
            let kind: HistoryRecord.Kind
            switch event.kind {
            case .edit: kind = .edit
            case .undo: kind = .undo
            case .redo: kind = .redo
            case .reload: kind = .reload
            }
            self.writeOpening()
            log.append(.change(kind, revision: event.revision, label: event.label, author: event.author, before: before, after: after))
        }
    }
}
