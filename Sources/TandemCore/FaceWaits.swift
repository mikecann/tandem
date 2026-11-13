import Foundation

// Joins where Mike's face waits to talk, for `tandem tighten --lead-only`
// and `tandem check`.
//
// Reviewing the "Let's Build It technical" video (13 Nov 2026): "often what
// you do is you don't start the next clip soon enough. So you end up with
// like my gormless face on screen for like a couple of hundred
// milliseconds... it should start the next clip like one frame or two
// frames before the speech starts... you should add that extra time onto
// the end of the previous clip." `tighten` and `cut` now leave the pause on
// the outgoing side (`LeadIn` in TandemMedia), but an edit cut before that,
// or by hand, still has clips that open on him waiting. Here the model side:
// which joins can be rolled, and the check's notes once the sound says how
// long each one waits.

extension QualityCheck {
    /// Two clips of one take meeting at a cut, on every track the take
    /// plays at that join: the clips a roll moves together.
    public struct TakeJoin: Equatable, Sendable {
        public struct Pair: Equatable, Sendable {
            public var trackID: String
            public var outgoing: Clip
            public var incoming: Clip
            /// The track carries the take's sound (a speech track), so the
            /// join's words are heard on it.
            public var heard: Bool
        }

        /// Where the clips meet, timeline time.
        public var time: Time
        public var pairs: [Pair]
        /// The pairs a roll command is given for: a linked partner rolls
        /// with its pair, so it isn't given its own.
        public var rolled: [Pair]

        public var heard: [Pair] { pairs.filter(\.heard) }
    }

    /// The joins between two pieces of one take (the same file, cut between
    /// them, at normal speed) in `ranges`, with at least one on a speech
    /// track. Not a join a wipe, a section card or a transition sits over:
    /// its cut has to stay under the wipe, and the face isn't shown.
    public static func takeJoins(in project: Project, ranges: [TimeRange], speechTrackIDs: Set<String>) -> [TakeJoin] {
        let rate = project.settings.frameRate
        let tolerance = rate.flicksPerFrame / 2
        func touching(_ a: Time, _ b: Time) -> Bool { abs((a - b).flicks) <= tolerance }
        let frame = rate.frameDuration
        let cards = project.videoTracks.filter { !$0.hidden }.flatMap(\.clips).filter { $0.enabled && SectionCard.isCard($0.content) }.map(\.range)

        var byTime: [Int64: TakeJoin] = [:]
        // Clips meeting there that a roll can't move as one piece of the
        // take: another file, another speed, a freeze, or a hair apart
        // (`Editing.roll` needs them to meet exactly).
        var others: [Int64: [(Clip, Clip)]] = [:]
        for track in project.allTracks {
            let heard = speechTrackIDs.contains(track.id)
            if track.kind == .video, track.hidden { continue }
            if track.kind == .audio, track.muted { continue }
            let clips = track.clips.filter(\.enabled)
            for (left, right) in zip(clips, clips.dropFirst()) {
                guard touching(left.end, right.start), ranges.contains(where: { $0.start <= right.start && right.start <= $0.end }) else { continue }
                // Within a frame, joins on different tracks are one join.
                let key = (right.start.flicks + tolerance) / rate.flicksPerFrame
                guard left.end == right.start, let media = left.mediaID, media == right.mediaID,
                      left.speed == 1, right.speed == 1, !left.freezeFrame, !right.freezeFrame,
                      right.sourceStart - left.sourceEnd >= frame else {
                    others[key, default: []].append((left, right))
                    continue
                }
                var join = byTime[key] ?? TakeJoin(time: right.start, pairs: [], rolled: [])
                join.pairs.append(TakeJoin.Pair(trackID: track.id, outgoing: left, incoming: right, heard: heard))
                byTime[key] = join
            }
        }

        let transitions = project.allTracks.flatMap(\.transitions)
        var joins: [TakeJoin] = []
        for (key, var join) in byTime.sorted(by: { $0.value.time < $1.value.time }) {
            guard !join.heard.isEmpty else { continue }
            // A piece of the take there the roll would leave behind, or
            // that `Editing.roll` would move with a linked pair unjudged
            // (its partner at the join in another file or at another speed).
            let media = Set(join.pairs.compactMap(\.outgoing.mediaID))
            let links = Set(join.pairs.flatMap { [$0.outgoing.linkGroup, $0.incoming.linkGroup] }.compactMap { $0 })
            let stranded = (others[key] ?? []).contains { left, right in
                left.mediaID.map(media.contains) ?? false || right.mediaID.map(media.contains) ?? false
                    || left.linkGroup.map(links.contains) ?? false || right.linkGroup.map(links.contains) ?? false
            }
            if stranded { continue }
            // A transition on this join: out of a clip going out, or into
            // one coming in (not one at a clip's other end).
            let outgoing = Set(join.pairs.map(\.outgoing.id)), incoming = Set(join.pairs.map(\.incoming.id))
            if transitions.contains(where: { ($0.fromClipID.map(outgoing.contains) ?? false) || ($0.toClipID.map(incoming.contains) ?? false) }) { continue }
            let around = TimeRange(start: join.time - frame, end: join.time + frame)
            if cards.contains(where: { $0.overlaps(around) }) { continue }
            // A wipe is a short clip on a video track over the join (a
            // stinger from the library), which the take doesn't play on.
            let takeMedia = Set(join.pairs.compactMap(\.outgoing.mediaID))
            let wiped = project.videoTracks.contains { track in
                !track.hidden && track.clips.contains { clip in
                    clip.enabled && clip.duration <= wipeLongest && clip.range.overlaps(around)
                        && !(clip.mediaID.map(takeMedia.contains) ?? false) && !isCaption(clip, on: track)
                        && !isTextOnly(clip)
                }
            }
            if wiped { continue }
            // A roll on linked clips rolls their partners too.
            var covered: Set<String> = []
            for pair in join.pairs.sorted(by: { $0.heard && !$1.heard }) where !covered.contains(pair.outgoing.id) {
                join.rolled.append(pair)
                guard let left = pair.outgoing.linkGroup, let right = pair.incoming.linkGroup else { continue }
                for other in join.pairs where other.outgoing.linkGroup == left && other.incoming.linkGroup == right
                    && other.outgoing.end == pair.outgoing.end && other.incoming.start == pair.incoming.start {
                    covered.insert(other.outgoing.id)
                }
            }
            joins.append(join)
        }
        return joins
    }

    /// A wipe clip is no longer than this: a section's stinger is about a
    /// second, and B-roll that short isn't over a join on purpose.
    static let wipeLongest = Time(seconds: 2)

    static func isTextOnly(_ clip: Clip) -> Bool {
        if case .text = clip.content { return true }
        if case .adjustment = clip.content { return true }
        return false
    }

    /// How long one join's clip runs before his first word, heard in the
    /// take's sound, and the roll that moves the pause onto the clip before.
    public struct FaceWait: Equatable, Sendable {
        public var time: Time
        /// From the join to the first word's sound.
        public var wait: Time
        /// How far the cut moves later (whole frames), nil when it can't
        /// move (no quiet after the clip before to grow into, say).
        public var roll: Time?
        public var commands: [EditCommand]
        /// The first words said after the join.
        public var words: String
        public var clipIDs: [String]

        public init(time: Time, wait: Time, roll: Time?, commands: [EditCommand], words: String, clipIDs: [String]) {
            self.time = time
            self.wait = wait
            self.roll = roll
            self.commands = commands
            self.words = words
            self.clipIDs = clipIDs
        }
    }

    /// A clip that runs longer than this before his first word shows his
    /// face waiting (`LeadIn.longestWait` in TandemMedia, which this
    /// module can't see).
    public static let faceWaitLongest = 0.1

    /// The most a check lists; past that it says how many more.
    static let faceWaitsListed = 40

    /// Notes for joins in `ranges` where the camera shows him for more than
    /// `longest` before he speaks, each with the roll that fixes it.
    public static func faceWaits(_ waits: [FaceWait], in project: Project, ranges: [TimeRange], longest: Time) -> [CheckProblem] {
        let found = waits.filter { wait in
            wait.wait > longest && ranges.contains { $0.start <= wait.time && wait.time <= $0.end }
                && faceShown(in: project, from: wait.time, to: wait.time + wait.wait)
        }.sorted { $0.time < $1.time }
        guard !found.isEmpty else { return [] }
        func quote(_ wait: FaceWait) -> String { wait.words.isEmpty ? "his first word" : "\"\(wait.words)\"" }
        var notes = found.prefix(faceWaitsListed).map { wait -> CheckProblem in
            let from = wait.time - Time(seconds: 0.5), to = wait.time + Time(seconds: 0.5)
            var message = "Face waits \(seconds(wait.wait)) before \(quote(wait)). Mike: start the clip a frame or two before he speaks, and put the pause on the end of the clip before. "
            if let roll = wait.roll {
                message += "The fix rolls the cut \(seconds(roll)) later (or tandem tighten --lead-only --from \(max(.zero, from)) --to \(to) --apply)."
            } else {
                message += "There's no quiet after the clip before to move the pause into: trim the start of this clip by hand and listen."
            }
            return CheckProblem(
                kind: .faceWaits, start: wait.time, end: wait.time + wait.wait, message: message, clipIDs: wait.clipIDs,
                fix: wait.commands.first, moreFixes: wait.commands.count > 1 ? Array(wait.commands.dropFirst()) : nil
            )
        }
        let rest = found.dropFirst(faceWaitsListed)
        if let first = rest.first, let last = rest.last {
            notes.append(CheckProblem(
                kind: .faceWaits, start: first.time, end: last.time + last.wait,
                message: "\(rest.count) more join\(rest.count == 1 ? "" : "s") where his face waits to talk, \(found.count) in all. tandem tighten --lead-only --apply rolls every one.",
                clipIDs: first.clipIDs
            ))
        }
        return notes
    }

    /// Whether the take's camera is what's seen through some of `from` to
    /// `to`: not under a full-frame picture or a section card the whole time.
    static func faceShown(in project: Project, from: Time, to: Time) -> Bool {
        let step = Time(seconds: 0.02)
        var time = from
        while time < to {
            if cameraOnTop(in: project, at: time) { return true }
            time = time + step
        }
        return false
    }

    /// The take's camera is the top picture at `time` that covers the frame
    /// or shows him: nothing opaque and full-frame over it, and no card.
    static func cameraOnTop(in project: Project, at time: Time) -> Bool {
        for track in project.videoTracks.reversed() where !track.hidden {
            guard let clip = track.clip(at: time), clip.enabled else { continue }
            if SectionCard.isCard(clip.content) { return false }
            let item = clip.mediaID.flatMap(project.media)
            if track.rippleMode == .cut, !Editing.isPrivacyTrack(track), let item, item.role != .screen, item.hasVideo { return true }
            if isTextOnly(clip) { continue }
            guard let box = onScreen(clip, item: item, at: time, in: project) else { continue }
            let video = clip.resolvedVideo(at: time - clip.start)
            let opaque = video.opacity >= 0.99 && video.cutout?.enabled != true && !(item?.hasAlpha ?? false)
            if opaque, box.x0 <= 0.01, box.y0 <= 0.01, box.x1 >= 0.99, box.y1 >= 0.99 { return false }
        }
        return false
    }
}
