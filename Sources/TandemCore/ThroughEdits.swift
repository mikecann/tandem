import Foundation

/// Joining through-edits. A through-edit is a cut where nothing changes: a
/// clip carries straight on into the next piece of the same file. Putting
/// cuts back with ripple trims leaves them behind, and the timeline then
/// looks cut up where the take plays on. A join makes the two pieces one
/// clip, with the left one's ID, start and link group, that plays exactly
/// what they did.
///
/// Two clips are a through-edit when the right one starts where the left
/// one ends on the same track, both play the same file at the same speed
/// (neither a freeze frame), and the right one starts in the file where
/// the left one stops, within half a frame (the rounding trims leave). A
/// join must never change what plays, so it's refused, with the reason,
/// for:
///
/// - different settings (`settingsDifference`). Effects that differ only by
///   their IDs are the same: `applyLayout` gives each clip its own shadow;
/// - a fade out of the left clip, or into the right one, at the cut;
/// - a transition on the cut. A through-edit has nothing to transition,
///   but a dissolve or a push there still plays, so it stays until it's
///   removed on purpose;
/// - a transition into the left clip or out of the right one that's longer
///   than its clip (a trim since), which the join would let grow;
/// - animation one list of keyframes can't play on both sides of the cut
///   (`mergedKeyframes`);
/// - the right clip playing a transition's sound, whose tie would go;
/// - a locked track.
///
/// Linked clips join together, so camera, screen and voice stay one take:
/// every clip linked to the left one must end at the cut and every clip
/// linked to the right one must start there, they pair up track by track,
/// and every pair has to join, or none does. Tags carry over; the name is
/// the left clip's.
public enum ThroughEdits {
    /// A clip and the clip after it, joined.
    public struct Pair: Equatable, Sendable {
        public var trackID: String
        /// The clip that stays, now playing both.
        public var clipID: String
        /// The clip that was after it, which is gone.
        public var nextClipID: String

        public init(trackID: String, clipID: String, nextClipID: String) {
            self.trackID = trackID
            self.clipID = clipID
            self.nextClipID = nextClipID
        }
    }

    /// One cut joined, on every track it ran through.
    public struct Join: Equatable, Sendable {
        /// Where the cut was.
        public var time: Time
        /// One pair per track, in track order (video bottom to top, then
        /// audio).
        public var pairs: [Pair]
    }

    /// A cut that looks like a through-edit but wasn't joined.
    public struct Skip: Equatable, Sendable {
        public var time: Time
        /// The clips either side of it, on the track it was found on.
        public var pair: Pair
        public var reason: String
    }

    /// What joining every through-edit did.
    public struct Report: Equatable, Sendable {
        /// Earliest first.
        public var joins: [Join] = []
        /// Earliest first, each cut once, however many tracks it runs through.
        public var skipped: [Skip] = []
    }

    // MARK: - Commands

    /// Joins `clipID` with the clip after it on its track (and their linked
    /// clips), or throws saying why not. The `join` command.
    static func join(_ p: inout Project, clipID: String) throws {
        let (location, index) = try Editing.requireClip(p, clipID)
        let track = p[location]
        guard index + 1 < track.clips.count else {
            throw EditError.invalid("\(clipID) is the last clip on \"\(track.name)\", so there's nothing after it to join it with")
        }
        var joiner = Joiner(p)
        switch joiner.join(track: joiner.trackIndex(of: location), index: index) {
        case .success:
            joiner.write(into: &p)
        case .failure(let refusal):
            let message = "can't join \(clipID) with \(track.clips[index + 1].id), the clip after it on \"\(track.name)\": \(refusal.reason)"
            throw refusal.locked ? EditError.locked(message) : EditError.invalid(message)
        }
    }

    /// Joins every through-edit with its cut in `range` (both ends
    /// included), or on the whole timeline. Cuts that can't be joined are
    /// left as they are and reported, each once. Each track is walked from
    /// the start, and a joined clip is tried again with the clip after it,
    /// so a run of pieces becomes one clip.
    public static func joinAll(_ p: inout Project, in range: TimeRange? = nil) -> Report {
        var joiner = Joiner(p)
        var joins: [(join: Join, order: Int)] = []
        var skipped: [(skip: Skip, order: Int)] = []
        // Cuts already turned down, by the link groups either side, so a
        // take isn't tried (and reported) again from each of its tracks.
        var refused = Set<String>()
        for track in joiner.tracks.indices {
            var index = 0
            while index + 1 < joiner.tracks[track].clips.count {
                let left = joiner.tracks[track].clips[index]
                let right = joiner.tracks[track].clips[index + 1]
                let cut = left.end
                guard range.map({ $0.start <= cut && cut <= $0.end }) ?? true,
                      discontinuity(left, right, tolerance: joiner.halfFrame) == nil else {
                    index += 1
                    continue
                }
                let groups = left.linkGroup == nil && right.linkGroup == nil ? nil : "\(left.linkGroup ?? "")|\(right.linkGroup ?? "")"
                if let groups, refused.contains(groups) {
                    index += 1
                    continue
                }
                switch joiner.join(track: track, index: index) {
                case .success(let join):
                    // The joined clip is tried again with the one after it.
                    joins.append((join, joins.count))
                case .failure(let refusal):
                    let pair = Pair(trackID: joiner.tracks[track].id, clipID: left.id, nextClipID: right.id)
                    skipped.append((Skip(time: cut, pair: pair, reason: refusal.reason), skipped.count))
                    if let groups { refused.insert(groups) }
                    index += 1
                }
            }
        }
        joiner.write(into: &p)
        // Earliest first, in the order found where they're at one time.
        return Report(
            joins: joins.sorted { ($0.join.time, $0.order) < ($1.join.time, $1.order) }.map(\.join),
            skipped: skipped.sorted { ($0.skip.time, $0.order) < ($1.skip.time, $1.order) }.map(\.skip)
        )
    }

    /// What `joinThroughEdits` says about its report: that there was
    /// nothing to join, or the cuts it left and why (the first few; `tandem
    /// join` lists them all).
    public static func warnings(_ report: Report, in p: Project) -> [String] {
        if report.joins.isEmpty && report.skipped.isEmpty { return ["No through-edits to join."] }
        let shown = 3
        var lines = report.skipped.prefix(shown).map { skip in
            let track = p.track(skip.pair.trackID)?.name ?? skip.pair.trackID
            return "Didn't join the through-edit at \(skip.time) on \"\(track)\" (\(skip.pair.clipID) and \(skip.pair.nextClipID)): \(skip.reason)."
        }
        if report.skipped.count > shown {
            lines.append("Didn't join \(report.skipped.count - shown) more through-edits that would play differently joined; `tandem join` lists them all with the reasons.")
        }
        return lines
    }

    // MARK: - Is it a through-edit?

    /// Why `right` doesn't carry straight on from `left`, or nil when it
    /// does: it starts where `left` ends, in the same file at the same
    /// speed (neither a freeze frame), where `left` stops in the file
    /// (within `tolerance`).
    static func discontinuity(_ left: Clip, _ right: Clip, tolerance: Time) -> String? {
        guard let media = left.mediaID, right.mediaID == media else {
            return left.mediaID == nil || right.mediaID == nil
                ? "only clips that play part of a file can be joined"
                : "\(left.id) and \(right.id) play different files"
        }
        if right.start > left.end { return "there's a gap between them, from \(left.end) to \(right.start)" }
        if right.start < left.end { return "they overlap" }
        if left.freezeFrame || right.freezeFrame { return "\(left.freezeFrame ? left.id : right.id) is a freeze frame" }
        if left.speed != right.speed {
            return "\(left.id) and \(right.id) play at different speeds (\(number(left.speed))x and \(number(right.speed))x)"
        }
        if abs((right.sourceStart - left.sourceEnd).flicks) > tolerance.flicks {
            return "the file doesn't carry straight on: \(left.id) stops at \(left.sourceEnd) in it and \(right.id) starts at \(right.sourceStart)"
        }
        return nil
    }

    // MARK: - Settings

    /// What a clip plays with: everything but where it is, which part of
    /// its file it plays, and what a join deals with itself (fades,
    /// keyframes, the name, tags and link group). Effects count by what
    /// they are, not their IDs, and a clip without video or audio settings
    /// has the defaults, as it plays.
    static func settings(_ clip: Clip) -> Clip {
        var shape = clip
        shape.id = ""
        shape.name = nil
        shape.start = .zero
        shape.duration = .zero
        shape.sourceStart = .zero
        shape.linkGroup = nil
        shape.keyframes = [:]
        shape.tags = []
        var video = clip.video ?? VideoProperties()
        video.effects = video.effects.map { var effect = $0; effect.id = ""; return effect }
        shape.video = video
        var audio = clip.audio ?? AudioProperties()
        audio.fadeIn = .zero
        audio.fadeOut = .zero
        audio.effects = audio.effects.map { var effect = $0; effect.id = ""; return effect }
        shape.audio = audio
        return shape
    }

    /// What two clips set differently, in a few words, or nil when their
    /// settings (`settings`) are the same.
    static func settingsDifference(_ a: Clip, _ b: Clip) -> String? {
        guard settings(a) != settings(b) else { return nil }
        if a.enabled != b.enabled { return "one is turned off" }
        if a.holdEdges != b.holdEdges { return "holding its edges" }
        let (x, y) = (a.video ?? VideoProperties(), b.video ?? VideoProperties())
        if x.transform != y.transform { return "position, scale or rotation" }
        if x.crop != y.crop { return "crop" }
        if x.opacity != y.opacity { return "opacity" }
        if x.cutout != y.cutout { return "cutout" }
        if effectIDs(of: y.effects, as: x.effects) == nil { return "video effects" }
        if x.layoutPreset != y.layoutPreset { return "layout" }
        if x.formatOverrides != y.formatOverrides { return "placement in other formats" }
        let (m, n) = (a.audio ?? AudioProperties(), b.audio ?? AudioProperties())
        if m.gainDB != n.gainDB { return "gain" }
        if m.muted != n.muted { return "mute" }
        if m.normalizeTo != n.normalizeTo { return "loudness levelling" }
        if m.voiceIsolation != n.voiceIsolation { return "voice isolation" }
        if effectIDs(of: n.effects, as: m.effects) == nil { return "audio effects" }
        return "settings"
    }

    /// `other`'s effect IDs to `own`'s, position by position, when the two
    /// lists are the same effects apart from their IDs; nil when they aren't.
    static func effectIDs(of other: [Effect], as own: [Effect]) -> [String: String]? {
        guard other.count == own.count else { return nil }
        var map: [String: String] = [:]
        for (theirs, ours) in zip(other, own) {
            guard theirs.type == ours.type, theirs.enabled == ours.enabled, theirs.params == ours.params else { return nil }
            map[theirs.id] = ours.id
        }
        return map
    }

    // MARK: - Keyframes

    /// The joined clip's keyframes: each parameter animated as `left` plays
    /// it up to the cut and as `right` does after it, measured from `left`'s
    /// start, so keyframes keep their timeline times. `right`'s keyframes
    /// on its effects are renamed to `left`'s (`video` and `audio` map the
    /// IDs, from `effectIDs`).
    ///
    /// One list of keyframes has to play both sides as they played, or the
    /// join would change the animation, so:
    ///
    /// - a parameter both clips animate merges when neither side's
    ///   keyframes change the other side's curve. A clip cut through its
    ///   animation joins back whole: each half kept the keyframes either
    ///   side of it, which are the other half's.
    /// - a parameter only one clip animates joins when that animation sits
    ///   still, at the value the other clip has, right across the other
    ///   clip. Otherwise it would carry on past the cut (or start before
    ///   it), so that's refused. A zoom in that zooms back out before the
    ///   cut joins; one still zoomed in at the cut doesn't.
    /// - keyframes that don't play (an effect the clip doesn't have) come
    ///   along as they are.
    static func mergedKeyframes(_ left: Clip, _ right: Clip, video: [String: String], audio: [String: String]) -> Result<[String: [Keyframe]], Joiner.Refusal> {
        func refuse(_ reason: String) -> Result<[String: [Keyframe]], Joiner.Refusal> { .failure(Joiner.Refusal(reason: reason)) }
        let cut = left.duration
        let end = left.duration + right.duration
        var own: [String: [Keyframe]] = [:]
        for (path, list) in left.keyframes where !list.isEmpty { own[path] = list }
        var shifted: [String: [Keyframe]] = [:]
        for (path, list) in right.keyframes where !list.isEmpty {
            let name = renamed(path, video: video, audio: audio)
            // Keyframes for an effect the right clip doesn't have would
            // start playing on one of the left clip's.
            if !plays(path, on: right) && plays(name, on: left) {
                return refuse("\(right.id) has \(path) keyframes for an effect it doesn't have")
            }
            shifted[name] = list.map { var keyframe = $0; keyframe.time += cut; return keyframe }
        }
        var result: [String: [Keyframe]] = [:]
        for path in Set(own.keys).union(shifted.keys).sorted() {
            let a = own[path], b = shifted[path]
            guard plays(path, on: left) else {
                result[path] = a ?? b
                continue
            }
            switch (a.map(byTime), b.map(byTime)) {
            case let (a?, b?):
                guard let merged = union(a, b),
                      relevant(merged, .zero, cut) == relevant(a, .zero, cut),
                      relevant(merged, cut, end) == relevant(b, cut, end) else {
                    return refuse("their \(path) animations don't carry on into each other at the cut")
                }
                result[path] = merged
            case let (sorted?, nil):
                guard let still = staticValue(path, of: left), relevant(sorted, cut, end).allSatisfy({ $0.value == still }) else {
                    return refuse("\(left.id) animates \(path) and \(right.id) doesn't, so the animation would carry on past the cut")
                }
                result[path] = a
            case let (nil, sorted?):
                guard let still = staticValue(path, of: left), relevant(sorted, .zero, cut).allSatisfy({ $0.value == still }) else {
                    return refuse("\(right.id) animates \(path) and \(left.id) doesn't, so the animation would reach back before the cut")
                }
                result[path] = b
            case (nil, nil):
                break
            }
        }
        return .success(result)
    }

    /// The keyframes that shape `list`'s curve over `from...to` (it's sorted
    /// by time): those inside, and the nearest either side unless one sits
    /// right on that end. Two lists with the same play the same there.
    static func relevant(_ list: [Keyframe], _ from: Time, _ to: Time) -> [Keyframe] {
        var result = list.filter { $0.time >= from && $0.time <= to }
        if result.first?.time != from, let before = list.last(where: { $0.time < from }) { result.insert(before, at: 0) }
        if result.last?.time != to, let after = list.first(where: { $0.time > to }) { result.append(after) }
        return result
    }

    /// Both lists in one, by time, or nil when they put different
    /// keyframes at one time (which would leave the curve to the sort).
    static func union(_ a: [Keyframe], _ b: [Keyframe]) -> [Keyframe]? {
        let merged = byTime(a + b.filter { !a.contains($0) })
        for (first, second) in zip(merged, merged.dropFirst()) where first.time == second.time { return nil }
        return merged
    }

    /// Sorted by time, keeping the order of keyframes at one time.
    static func byTime(_ list: [Keyframe]) -> [Keyframe] {
        list.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// Whether keyframes on `path` change how `clip` plays: a parameter the
    /// renderer reads, of an effect the clip has.
    static func plays(_ path: String, on clip: Clip) -> Bool {
        if AnimatableParameter.fixed.contains(path) { return true }
        let parts = path.split(separator: ".", maxSplits: 3).map(String.init)
        guard parts.count == 4, parts[1] == "effects" else { return false }
        switch parts[0] {
        case "video": return clip.video?.effects.contains { $0.id == parts[2] } ?? false
        case "audio": return clip.audio?.effects.contains { $0.id == parts[2] } ?? false
        default: return false
        }
    }

    /// `path` with the effect it animates renamed by `video` or `audio`.
    static func renamed(_ path: String, video: [String: String], audio: [String: String]) -> String {
        let parts = path.split(separator: ".", maxSplits: 3).map(String.init)
        guard parts.count == 4, parts[1] == "effects" else { return path }
        let map = parts[0] == "video" ? video : parts[0] == "audio" ? audio : [:]
        guard let id = map[parts[2]] else { return path }
        return "\(parts[0]).effects.\(id).\(parts[3])"
    }

    /// What `clip` shows for `path` when it isn't animated: its own setting,
    /// or for an effect's parameter the default it renders with. Nil when
    /// that isn't known.
    static func staticValue(_ path: String, of clip: Clip) -> ParamValue? {
        let video = clip.video ?? VideoProperties()
        let audio = clip.audio ?? AudioProperties()
        switch path {
        case "video.transform.position": return .point(video.transform.position)
        case "video.transform.scale": return .number(video.transform.scale)
        case "video.transform.rotation": return .number(video.transform.rotation)
        case "video.opacity": return .number(video.opacity)
        case "video.crop.left": return .number(video.crop.left)
        case "video.crop.top": return .number(video.crop.top)
        case "video.crop.right": return .number(video.crop.right)
        case "video.crop.bottom": return .number(video.crop.bottom)
        case "audio.gainDB": return .number(audio.gainDB)
        default:
            let parts = path.split(separator: ".", maxSplits: 3).map(String.init)
            guard parts.count == 4, parts[1] == "effects" else { return nil }
            let effects = parts[0] == "video" ? video.effects : audio.effects
            guard let effect = effects.first(where: { $0.id == parts[2] }) else { return nil }
            return effect.params[parts[3]] ?? EffectRegistry.standard.definition(effect.type)?.param(parts[3])?.defaultValue
        }
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    // MARK: - Joining

    /// Joins clips on the project's tracks, taken out of it, so hundreds of
    /// joins change each track's clips in place instead of copying them.
    struct Joiner {
        /// Why two clips can't be joined.
        struct Refusal: Error {
            var reason: String
            var locked = false
        }

        struct Member: Equatable {
            var track: Int
            var id: String
        }

        /// The project without its tracks, for its media and settings.
        let base: Project
        /// Video tracks bottom to top, then audio tracks.
        var tracks: [Track]
        let videoCount: Int
        let halfFrame: Time
        /// The clips in each link group, by track and ID.
        var groups: [String: [Member]] = [:]
        /// Clips that play a transition's sound, to that transition.
        var sounds: [String: String] = [:]

        init(_ p: Project) {
            var base = p
            base.videoTracks = []
            base.audioTracks = []
            self.base = base
            tracks = p.videoTracks + p.audioTracks
            videoCount = p.videoTracks.count
            halfFrame = Time(flicks: p.settings.frameRate.flicksPerFrame / 2)
            for (index, track) in tracks.enumerated() {
                for clip in track.clips {
                    if let group = clip.linkGroup { groups[group, default: []].append(Member(track: index, id: clip.id)) }
                }
                for transition in track.transitions {
                    if let sound = transition.soundClipID { sounds[sound] = transition.id }
                }
            }
        }

        func trackIndex(of location: TrackLocation) -> Int {
            location.kind == .video ? location.index : videoCount + location.index
        }

        func write(into p: inout Project) {
            p.videoTracks = Array(tracks[..<videoCount])
            p.audioTracks = Array(tracks[videoCount...])
        }

        /// Joins the clip at `index` on track `t` with the clip after it,
        /// and the clips linked to them across the same cut. Changes
        /// nothing when any of them can't be joined.
        mutating func join(track t: Int, index: Int) -> Result<Join, Refusal> {
            let left = tracks[t].clips[index]
            let right = tracks[t].clips[index + 1]
            var joined: [(track: Int, index: Int, clip: Clip)] = []
            switch pair(left, right, on: t) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let clip): joined.append((t, index, clip))
            }
            switch partners(of: left, right) {
            case .failure(let refusal):
                return .failure(refusal)
            case .success(let found):
                for (track, at) in found {
                    let l = tracks[track].clips[at]
                    let r = tracks[track].clips[at + 1]
                    switch pair(l, r, on: track) {
                    case .failure(let refusal):
                        return .failure(Refusal(reason: "the linked clips on \"\(tracks[track].name)\" can't join: \(refusal.reason)", locked: refusal.locked))
                    case .success(let clip):
                        joined.append((track, at, clip))
                    }
                }
            }
            // Every pair can join, so they all do.
            var pairs: [Pair] = []
            for (track, at, clip) in joined.sorted(by: { $0.track < $1.track }) {
                let next = tracks[track].clips[at + 1]
                tracks[track].clips[at] = clip
                tracks[track].clips.remove(at: at + 1)
                // A transition out of the far end of the right clip now
                // leaves the joined one.
                for k in tracks[track].transitions.indices where tracks[track].transitions[k].fromClipID == next.id {
                    tracks[track].transitions[k].fromClipID = clip.id
                }
                if let group = next.linkGroup {
                    groups[group]?.removeAll { $0.id == next.id }
                    if groups[group]?.isEmpty == true { groups.removeValue(forKey: group) }
                }
                pairs.append(Pair(trackID: tracks[track].id, clipID: clip.id, nextClipID: next.id))
            }
            return .success(Join(time: left.end, pairs: pairs))
        }

        /// The clips linked to `left` and `right` that meet across the same
        /// cut, as the track and index of the one before it: every clip
        /// linked to `left` has to end at the cut, every clip linked to
        /// `right` has to start there, and they pair up track by track.
        func partners(of left: Clip, _ right: Clip) -> Result<[(track: Int, index: Int)], Refusal> {
            guard left.linkGroup != nil || right.linkGroup != nil else { return .success([]) }
            let cut = left.end
            func clip(_ member: Member) -> Clip? { tracks[member.track].clips.first { $0.id == member.id } }
            func name(_ member: Member) -> String { "\(member.id) on \"\(tracks[member.track].name)\"" }
            func refuse(_ reason: String) -> Result<[(track: Int, index: Int)], Refusal> { .failure(Refusal(reason: reason)) }
            var before: [Member] = []
            var after: [Member] = []
            if let group = left.linkGroup, group == right.linkGroup {
                // Linked to each other: the group's clips either side of the cut pair up.
                for member in groups[group] ?? [] where member.id != left.id && member.id != right.id {
                    guard let found = clip(member) else { continue }
                    if found.end == cut {
                        before.append(member)
                    } else if found.start == cut {
                        after.append(member)
                    } else {
                        return refuse("\(name(member)) is linked to them but doesn't meet the cut")
                    }
                }
            } else {
                for member in left.linkGroup.flatMap({ groups[$0] }) ?? [] where member.id != left.id {
                    guard let found = clip(member) else { continue }
                    guard found.end == cut else {
                        return refuse("\(name(member)), linked to \(left.id), ends at \(found.end), not at the cut at \(cut)")
                    }
                    before.append(member)
                }
                for member in right.linkGroup.flatMap({ groups[$0] }) ?? [] where member.id != right.id {
                    guard let found = clip(member) else { continue }
                    guard found.start == cut else {
                        return refuse("\(name(member)), linked to \(right.id), starts at \(found.start), not at the cut at \(cut)")
                    }
                    after.append(member)
                }
            }
            var following: [Int: Member] = [:]
            for member in after {
                guard following[member.track] == nil else { return refuse("two clips linked to \(right.id) start at the cut on \"\(tracks[member.track].name)\"") }
                following[member.track] = member
            }
            var found: [(track: Int, index: Int)] = []
            for member in before {
                guard let next = following.removeValue(forKey: member.track) else {
                    return refuse("\(name(member)) is linked to \(left.id), but nothing linked to \(right.id) comes after it")
                }
                // Clips never overlap, so the one starting where it ends is the next one.
                guard let at = tracks[member.track].clips.firstIndex(where: { $0.id == member.id }),
                      at + 1 < tracks[member.track].clips.count, tracks[member.track].clips[at + 1].id == next.id else {
                    return refuse("\(name(next)) doesn't come straight after \(member.id)")
                }
                found.append((member.track, at))
            }
            if let member = following.values.min(by: { ($0.track, $0.id) < ($1.track, $1.id) }) {
                return refuse("\(name(member)) is linked to \(right.id), but nothing linked to \(left.id) comes before it")
            }
            return .success(found)
        }

        /// `left` and `right`, touching on track `t`, as one clip, or why
        /// that would play differently.
        func pair(_ left: Clip, _ right: Clip, on t: Int) -> Result<Clip, Refusal> {
            func refuse(_ reason: String) -> Result<Clip, Refusal> { .failure(Refusal(reason: reason)) }
            if let reason = ThroughEdits.discontinuity(left, right, tolerance: halfFrame) { return refuse(reason) }
            let track = tracks[t]
            if track.locked { return .failure(Refusal(reason: "track \"\(track.name)\" is locked", locked: true)) }
            if let transition = sounds[right.id] {
                return refuse("\(right.id) is the sound of transition \(transition), which would lose it")
            }
            for transition in track.transitions {
                let what = "\(transition.type.rawValue) (\(transition.id))"
                if transition.fromClipID == left.id && transition.toClipID == right.id {
                    return refuse("there's a \(what) on the cut; remove it first if it should go")
                }
                if transition.fromClipID == left.id {
                    return refuse("\(left.id) has a \(what) at its end; remove it first if it should go")
                }
                if transition.toClipID == right.id {
                    return refuse("\(right.id) has a \(what) at its start; remove it first if it should go")
                }
                // One at the far end plays as it did while it fits its own
                // clip, as it does unless a trim made the clip shorter.
                let reach = transition.fromClipID == nil || transition.toClipID == nil
                    ? transition.duration
                    : Time(flicks: transition.duration.flicks / 2)
                if transition.toClipID == left.id && reach > left.duration {
                    return refuse("the \(what) into \(left.id) is longer than \(left.id), so it would play on past the cut")
                }
                if transition.fromClipID == right.id && reach > right.duration {
                    return refuse("the \(what) out of \(right.id) is longer than \(right.id), so it would reach back past the cut")
                }
            }
            let (a, b) = (left.audio ?? AudioProperties(), right.audio ?? AudioProperties())
            if a.fadeOut > .zero { return refuse("\(left.id) fades out at the cut") }
            if b.fadeIn > .zero { return refuse("\(right.id) fades in at the cut") }
            if a.fadeIn > left.duration { return refuse("\(left.id) fades in for longer than it lasts, so the fade would carry on past the cut") }
            if b.fadeOut > right.duration { return refuse("\(right.id) fades out for longer than it lasts, so the fade would reach back past the cut") }
            if let difference = ThroughEdits.settingsDifference(left, right) {
                return refuse("\(left.id) and \(right.id) have different settings (\(difference))")
            }
            let video = ThroughEdits.effectIDs(of: right.video?.effects ?? [], as: left.video?.effects ?? []) ?? [:]
            let audio = ThroughEdits.effectIDs(of: b.effects, as: a.effects) ?? [:]
            let keyframes: [String: [Keyframe]]
            switch ThroughEdits.mergedKeyframes(left, right, video: video, audio: audio) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let merged): keyframes = merged
            }

            var joined = left
            joined.duration = left.duration + right.duration
            joined.keyframes = keyframes
            for tag in right.tags where !joined.tags.contains(tag) { joined.tags.append(tag) }
            if joined.audio != nil || b.fadeOut > .zero {
                var sound = joined.audio ?? AudioProperties()
                sound.fadeOut = b.fadeOut
                joined.audio = sound
            }
            joined.tidy()
            // Half a frame of rounding at the cut moves the end a little.
            do {
                try Editing.checkSource(joined, in: base)
            } catch {
                return refuse("joined, \(left.id) would run past the end of its file")
            }
            return .success(joined)
        }
    }
}
