import Foundation

// Double jumps, for `tandem check`.
//
// On the Batching Component video an agent placed full-screen B-roll by the
// pauses between words and didn't look at the take's camera cuts: 11 B-roll
// edges ended up 1 to 17 frames off a cut. Mike saw the first within 5 s of
// watching: "it cuts and then like a few frames later it shows the b-roll
// which makes it quite distracting" (2026-10-27). The skill already said it,
// from the Ian video ("a double jump... it's kind of a bit disorientating"),
// along with the same mistake between two shots: "A quick flash back to the
// camera looks like a glitch." Nothing checked either, so `tandem check` said
// "no problems" and the edit went back to him. Both are read from the model,
// so they're found by a quick check and a changed check too.

extension QualityCheck {
    /// A full-frame shot's edge this close to a camera cut, with the camera
    /// showing between them, is a double jump: the skill's "Within about
    /// 0.75 s, extend the B-roll to the cut, holding its edge frame." The
    /// farthest of the 11 on the batching video was 17 frames (0.58 s) off.
    public static let doubleJumpReach = Time(seconds: 0.75)
    /// Less camera than this between two full-frame shots is a flash: "If
    /// less than about 1.5 s of camera would show between two B-roll shots,
    /// join them. A quick flash back to the camera looks like a glitch."
    public static let cameraFlashLongest = Time(seconds: 1.5)
    /// Edges further than this off a cut are reported, however short:
    /// snapping one to the cut costs nothing, and under a millisecond is the
    /// same moment (agents' rounding).
    static let snapSlack = Time.overlapTolerance
    /// The label for a batch of these fixes.
    public static let doubleJumpLabel = "Run B-roll edges out to the camera cuts and over camera flashes"

    /// Full-frame pictures over the take (B-roll, a solid) that start just
    /// after a cut in the take or end just before one, so the viewer sees
    /// the camera change and a few frames later the shot (or the reverse),
    /// and less than `cameraFlashLongest` of the take between two of them.
    /// Each comes with the `updateClip` that runs the shot out to the cut
    /// (or the first shot on to the second), holding its edge frame where
    /// the file runs out, and moves a copy of the shot that starts or ends
    /// with it on another track (a sharp copy over a blurred one) the same.
    ///
    /// The take is the cut tracks (`RippleMode.cut`: Camera, Screen). A cut
    /// is where one of their clips doesn't carry straight on from the one
    /// before (not a through-edit, a speed change in a file that plays on,
    /// nor a frame held over a flicker) or is framed differently from it (a
    /// punch-in, a switch to picture-in-picture), unless the camera full
    /// frame hides it, a fade to or from black plays over it, or it's the
    /// start or end of the video. A push, dissolve, slide, wipe or zoom over
    /// a cut makes it last the whole transition, and an edge runs out to
    /// the far side of it. Black isn't the camera: a shot beside a gap in
    /// the take is the gap check's. A picture covers the
    /// frame when it's an enabled media clip with no alpha, or a solid, on
    /// a shown track that isn't a cut track, opaque and filling the canvas
    /// at that moment (scale, position, crop and keyframes). Phone
    /// mock-ups, stickers, logos, picture-in-picture, titles and section
    /// cards don't; the cards' wipes are made to sit across cuts, so an
    /// edge or cut under one isn't checked either.
    public static func doubleJumps(in project: Project, ranges: [TimeRange]) -> [CheckProblem] {
        let picture = TakePicture(project)
        var found: [DoubleJumpFinding] = []

        // Camera flashes first: a stretch both kinds describe (a shot ending
        // just before a cut and the next starting just after it) is one
        // flash, with one fix.
        var flashEdges = Set<String>()
        for cover in picture.covers where picture.exposedEdge(cover, .end) {
            let end = cover.clip.end
            // Covers are by start, so the first that starts after this one
            // ends and shows its start is the next shot.
            let after = picture.covers[picture.firstCover(startingAfter: end + snapSlack)...]
            guard let next = after.prefix(while: { $0.clip.start - end < cameraFlashLongest }).first(where: { picture.exposedEdge($0, .start) }) else { continue }
            let gap = TimeRange(start: end, end: next.clip.start)
            // A flash of black, with none of the take under it, is the gap
            // check's.
            guard picture.exposed(gap), let take = picture.takeClip(in: gap) else { continue }
            found.append(DoubleJumpFinding(clip: cover.clip, edge: .end, to: gap.end, stretch: gap, frames: picture.frames(in: gap), screen: picture.isScreen(take), next: next.clip))
            flashEdges.insert("\(cover.clip.id)|end")
            flashEdges.insert("\(next.clip.id)|start")
        }

        for cover in picture.covers {
            for edge in [ClipEdge.start, .end] where !flashEdges.contains("\(cover.clip.id)|\(edge.rawValue)") && picture.exposedEdge(cover, edge) {
                guard let reached = picture.reach(from: edge == .start ? cover.clip.start : cover.clip.end, edge: edge, over: cover.track) else { continue }
                found.append(DoubleJumpFinding(clip: cover.clip, edge: edge, to: reached.to, stretch: reached.stretch, frames: picture.frames(in: reached.stretch), screen: reached.screen, transition: reached.transition))
            }
        }

        found = picture.joiningFlashesTheFixesWouldLeave(found, flashEdges: flashEdges)

        // Only what's reported moves: a fix that also ran out an edge
        // outside the stretch checked would change what Mike may already
        // have reviewed, and the problem wouldn't say so.
        found = found.filter { finding in ranges.contains(where: { $0.start <= finding.stretch.end && finding.stretch.start <= $0.end }) }

        // One patch a clip, setting every edge the check moves, so both
        // edges of one shot are one edit and the fixes don't undo each other.
        var moves: [String: (clip: Clip, start: Time?, end: Time?)] = [:]
        var blocked: [Int: String] = [:]
        var copies: [Int: [Clip]] = [:]
        // Where each moved clip will be, so a move is checked against the
        // others as well as the timeline as it is: two that each fit can
        // still overlap each other, and one overlap fails the whole batch.
        var planned: [String: TimeRange] = [:]
        for (index, finding) in found.enumerated() {
            let moving = [finding.clip] + picture.copies(of: finding.clip, at: finding.edge)
            copies[index] = Array(moving.dropFirst())
            if let why = moving.lazy.compactMap({ picture.inTheWay(of: $0, movingEdge: finding.edge, to: finding.to) }).first {
                blocked[index] = why
                continue
            }
            func moved(_ clip: Clip) -> TimeRange {
                let range = planned[clip.id] ?? clip.range
                return finding.edge == .start ? TimeRange(start: finding.to, end: range.end) : TimeRange(start: range.start, end: finding.to)
            }
            if let why = moving.lazy.compactMap({ picture.clash(of: $0, at: moved($0), with: planned) }).first {
                blocked[index] = why
                continue
            }
            for clip in moving {
                var move = moves[clip.id] ?? (clip, nil, nil)
                if finding.edge == .start { move.start = finding.to } else { move.end = finding.to }
                moves[clip.id] = move
                planned[clip.id] = moved(clip)
            }
        }
        var fixes: [String: TakePicture.Fix] = [:]
        for (id, move) in moves {
            if let fix = picture.fix(move.clip, start: move.start, end: move.end) { fixes[id] = fix }
        }

        let problems: [CheckProblem] = found.enumerated().map { index, finding in
            let fix = blocked[index] == nil ? fixes[finding.clip.id] : nil
            let others = (copies[index] ?? []).compactMap { fixes[$0.id]?.command }
            var problem = CheckProblem(
                kind: .doubleJump, start: finding.stretch.start, end: finding.stretch.end, frames: finding.frames,
                message: picture.message(for: finding, copies: copies[index] ?? [], fix: fix, blocked: blocked[index]),
                clipIDs: [finding.clip.id] + (finding.next.map { [$0.id] } ?? [])
            )
            problem.fix = fix?.command
            if fix != nil, !others.isEmpty { problem.moreFixes = others }
            return problem
        }
        return problems.sorted { $0.start < $1.start }
    }

    /// The edits that fix `problems`, in the order to apply them: the double
    /// jumps' clip patches first, once each (each sets a clip's edges
    /// outright, as the check read them, so one that ran after a hold had
    /// cut its clip would undo the hold), then the rest latest first, so a
    /// hold that cuts a clip never takes the ID off the piece an earlier
    /// hold names.
    public static func commands(fixing problems: [CheckProblem]) -> [EditCommand] {
        var commands: [EditCommand] = []
        let wanted = problems.filter { !$0.kind.isNote }.sorted { $0.start > $1.start }
        let jumps = wanted.filter { $0.kind == .doubleJump }.flatMap { problem in (problem.fix.map { [$0] } ?? []) + (problem.moreFixes ?? []) }
        let rest = wanted.filter { $0.kind != .doubleJump }.compactMap(\.fix)
        for fix in jumps + rest where !commands.contains(fix) {
            commands.append(fix)
        }
        return commands
    }

    /// The flickers in `flickers` that a double jump's fix in `jumps` hides,
    /// left out. A frame of the take flickering in the camera flash between
    /// two shots of one file is the flash, seen in the frames: the shot run
    /// over it hides it, and its `holdFrame` would only freeze the take
    /// under the shot, a stutter waiting for the shot to move.
    static func withoutFlickersUnderFixedJumps(_ flickers: [CheckProblem], jumps: [CheckProblem], frame: Time) -> [CheckProblem] {
        let fixed = jumps.filter { $0.kind == .doubleJump && $0.fix != nil }.map { TimeRange(start: $0.start, end: $0.end) }
        guard !fixed.isEmpty else { return flickers }
        return flickers.filter { flicker in
            // Its frames all show inside the stretch: the first at or after
            // its start, the last (a frame before its end) before its end.
            flicker.kind != .flicker || !fixed.contains { flicker.start >= $0.start && flicker.end - frame < $0.end }
        }
    }

    /// What a batch of `commands(fixing:)` is called in the history.
    public static func fixLabel(for problems: [CheckProblem]) -> String {
        let fixed = problems.filter { !$0.kind.isNote && $0.fix != nil }
        let jumps = fixed.contains { $0.kind == .doubleJump }
        let holds = fixed.contains { $0.kind != .doubleJump }
        switch (holds, jumps) {
        case (true, true): return "\(holdLabel), and \(doubleJumpLabel.prefix(1).lowercased())\(doubleJumpLabel.dropFirst())"
        case (false, true): return doubleJumpLabel
        default: return holdLabel
        }
    }
}

/// A double jump `doubleJumps` found, before it's worded: `clip`'s `edge`
/// should move `to` a cut (or, with `next`, on to the next shot).
private struct DoubleJumpFinding {
    var clip: Clip
    var edge: ClipEdge
    var to: Time
    /// Where the take shows: between the cut and the edge, or the shots.
    var stretch: TimeRange
    /// The project's frames that land in `stretch`.
    var frames: Int
    /// Whether the take there is the screen recording rather than the
    /// camera (or another angle of it).
    var screen: Bool
    /// For a camera flash, the shot after it.
    var next: Clip?
    /// The transition over the cut, when the take moves into the next shot
    /// rather than cutting to it.
    var transition: TransitionType?
    /// For a camera flash the edges' own fixes would have left, how much
    /// of the take they'd leave (under zero when they'd cross), and which
    /// of the two shots they moved.
    var left: Time?
    var leftFrames = 0
    var movedFirst = false
    var movedSecond = false
}

/// What the viewer sees of the take and over it, for `doubleJumps`.
private struct TakePicture {
    /// A clip that can cover the whole frame, on track `track` (an index
    /// into `videoTracks`, bottom first).
    struct Cover {
        var track: Int
        var clip: Clip
    }

    /// A cut in the take, on cut track `track`, in a screen recording or
    /// the camera (or another angle of it). It plays over `span`: the
    /// moment of the cut, or the whole of the transition over it, where
    /// the picture is on its way from one shot to the next.
    struct Cut {
        var span: TimeRange
        var track: Int
        var screen: Bool
        var transition: TransitionType?
    }

    /// A clip's patch, and whether it holds a frame at each end that it
    /// didn't before.
    struct Fix {
        var command: EditCommand
        var holdsHead: Bool
        var holdsTail: Bool
    }

    let project: Project
    let media: [String: MediaItem]
    let frame: Time
    let fps: String
    /// Where the video ends (`Project.duration` walks every clip, so it's
    /// read once).
    let end: Time
    /// Every clip that could cover the frame, by start.
    var covers: [Cover] = []
    /// Where section cards play: an edge or cut under one isn't checked.
    var cards: [TimeRange] = []
    /// By the start of their spans.
    var cuts: [Cut] = []
    /// The longest span of a cut, so a cut whose transition starts before a
    /// stretch is still found in it.
    var longestCut: Time = .zero
    /// Where some of the take plays, joined up, by time.
    var take: [TimeRange] = []

    /// A frame held over a flicker (`holdFrame`) covers up to three frames
    /// and holds the one before them, so the file is at most four frames
    /// of the shot off either side of it; half a frame more for rounding.
    /// On a sped-up clip those frames run through more of the file: a
    /// three-frame hold on a screen recording at 2x leaves the piece after
    /// it eight frames on, and it's still the same shot carrying on. The
    /// held piece itself plays at 1x, so the faster side sets it.
    func heldFrameSlack(_ left: Clip, _ right: Clip) -> Time {
        Time(flicks: Int64((Double(frame.flicks) * 4.5 * max(left.speed, right.speed, 1)).rounded()))
    }

    init(_ project: Project) {
        self.project = project
        media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rate = project.settings.frameRate
        frame = rate.frameDuration
        end = project.duration
        fps = rate.denominator == 1 ? "\(rate.numerator)" : String(format: "%.2f", rate.framesPerSecond)
        for (index, track) in project.videoTracks.enumerated() where !track.hidden {
            for clip in track.clips where clip.enabled {
                if SectionCard.isCard(clip.content) {
                    cards.append(clip.range)
                } else if track.rippleMode != .cut, canCover(clip) {
                    covers.append(Cover(track: index, clip: clip))
                }
            }
        }
        covers.sort { $0.clip.start < $1.clip.start }
        take = Self.joined(project.videoTracks.filter { !$0.hidden && $0.rippleMode == .cut }.flatMap { $0.clips.filter(\.enabled).map(\.range) })
        cuts = findCuts()
        longestCut = cuts.map(\.span.duration).max() ?? .zero
    }

    /// The ranges joined where they overlap or touch, by time.
    private static func joined(_ ranges: [TimeRange]) -> [TimeRange] {
        var joined: [TimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = joined.last, range.start <= last.end + QualityCheck.snapSlack {
                joined[joined.count - 1] = TimeRange(start: last.start, end: max(last.end, range.end))
            } else {
                joined.append(range)
            }
        }
        return joined
    }

    /// Whether some of the take plays at every moment of `range`: a
    /// stretch with black in it isn't the camera flashing, it's a gap.
    func takeShows(across range: TimeRange) -> Bool {
        var low = 0, high = take.count
        while low < high {
            let middle = (low + high) / 2
            if take[middle].start <= range.start + QualityCheck.snapSlack { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return false }
        return take[low - 1].end >= range.end - QualityCheck.snapSlack
    }

    /// The index of the first cover that starts after `time` (`covers` is
    /// by start).
    func firstCover(startingAfter time: Time) -> Int {
        var low = 0, high = covers.count
        while low < high {
            let middle = (low + high) / 2
            if covers[middle].clip.start > time { high = middle } else { low = middle + 1 }
        }
        return low
    }

    // MARK: Cuts

    /// The cuts that play at some moment from the start of `range` to its
    /// end, both included.
    func cuts(around range: TimeRange) -> [Cut] {
        let from = range.start - longestCut
        var low = 0, high = cuts.count
        while low < high {
            let middle = (low + high) / 2
            if cuts[middle].span.start < from { low = middle + 1 } else { high = middle }
        }
        var found: [Cut] = []
        var index = low
        while index < cuts.count && cuts[index].span.start <= range.end {
            if cuts[index].span.end >= range.start { found.append(cuts[index]) }
            index += 1
        }
        return found
    }

    /// The cuts in the take the viewer would see, by the start of their
    /// spans.
    private func findCuts() -> [Cut] {
        let tiny = QualityCheck.snapSlack
        let fades = QualityCheck.fadeWindows(in: project)
        var found: [Cut] = []
        for (index, track) in project.videoTracks.enumerated() where !track.hidden && track.rippleMode == .cut {
            let clips = track.clips.filter(\.enabled)
            // A fade to or from black is the fade windows'; every other
            // transition carries the picture from one shot to the next.
            let moving = track.transitions.filter { $0.type != .fadeToBlack && $0.type != .fadeFromBlack }
            var here: [(time: Time, clip: Clip)] = []
            for (i, clip) in clips.enumerated() {
                // A push or a wipe between two pieces of a file that carries
                // on still moves the picture; a dissolve between them shows
                // nothing.
                let pushed = i > 0 && moving.contains { $0.type != .dissolve && $0.fromClipID == clips[i - 1].id && $0.toClipID == clip.id }
                if i == 0 || pushed || !carriesOn(clips[i - 1], into: clip) { here.append((clip.start, clip)) }
                // An end the next clip starts at is that clip's start.
                if i + 1 == clips.count || clips[i + 1].start > clip.end + tiny { here.append((clip.end, clip)) }
            }
            for (time, clip) in here where time > tiny && time < end - tiny {
                guard !fades.contains(where: { $0.start <= time && time <= $0.end }), !hiddenByTake(time, above: index) else { continue }
                // Tandem centres a transition on its cut (`window(on:)`), so
                // a 0.5 s push at 10 plays from 9.75 to 10.25. Treated as
                // the cut at 10, a shot starting there cut in mid-push, and
                // one starting as it landed was "fixed" back to its middle.
                let over = moving.lazy.compactMap { transition -> (TransitionType, TimeRange)? in
                    let names = time == clip.start ? transition.toClipID == clip.id : transition.fromClipID == clip.id
                    guard names, let window = transition.window(on: track), window.start <= time, time <= window.end else { return nil }
                    return (transition.type, window)
                }.first
                found.append(Cut(span: over?.1 ?? TimeRange(start: time, duration: .zero), track: index, screen: isScreen(clip), transition: over?.0))
            }
        }
        return found.sorted { $0.span.start < $1.span.start }
    }

    /// Whether `right` plays on from `left` with nothing changing on
    /// screen: framed the same (`samePicture`), and the file carrying on
    /// where `left` leaves it (a through-edit, or a change of speed, which
    /// shows as the shot speeding up, not a cut), or either side a frame
    /// held from the file about where the other is in it.
    private func carriesOn(_ left: Clip, into right: Clip) -> Bool {
        guard left.mediaID != nil, left.mediaID == right.mediaID, left.end == right.start, samePicture(left, right) else { return false }
        guard left.freezeFrame || right.freezeFrame else {
            return abs((right.sourceStart - left.sourceEnd).flicks) <= frame.flicks / 2
        }
        let leaving = left.freezeFrame ? left.sourceStart : left.sourceEnd
        return abs((right.sourceStart - leaving).flicks) <= heldFrameSlack(left, right).flicks
    }

    /// Whether the picture at the end of `left` is the one at the start of
    /// `right`, as they're placed: the same position, scale, rotation and
    /// flip, crop, opacity, cutout and effects, keyframes included. A piece
    /// of the take that carries straight on in its file but is framed
    /// closer (a zoomToRegion punch-in, the W to M angles) or moved to the
    /// corner (applyLayout pipRight) jumps on screen like any cut: the Ian
    /// video has 59 punch-ins on its wide camera. The layout's name isn't
    /// compared: it's only the preset the clip was last set to (a zoom
    /// clears it), and what the preset did is in the rest.
    private func samePicture(_ left: Clip, _ right: Clip) -> Bool {
        let a = left.resolvedVideo(at: left.duration), b = right.resolvedVideo(at: .zero)
        // Keyframes read at either side of a split land a hair apart.
        func near(_ x: Double, _ y: Double) -> Bool { abs(x - y) < 0.0001 }
        let (x, y) = (a.transform, b.transform)
        guard near(x.position.x, y.position.x), near(x.position.y, y.position.y), near(x.scale, y.scale),
              near(x.rotation, y.rotation), x.flipped == y.flipped,
              near(a.crop.left, b.crop.left), near(a.crop.top, b.crop.top), near(a.crop.right, b.crop.right), near(a.crop.bottom, b.crop.bottom),
              near(a.opacity, b.opacity), (a.cutout?.enabled == true) == (b.cutout?.enabled == true) else { return false }
        return ThroughEdits.effectIDs(of: b.effects, as: a.effects) != nil
    }

    /// Where the `edge` of a shot on track `track`, at `at`, should run out
    /// to, and the stretch of take that shows between them: the far side
    /// of the farthest cut in reach with the take showing, uncovered, all
    /// the way from it to the edge (running out to a nearer one would leave
    /// the shot before that cut flashing instead). From there it keeps
    /// going while another cut is in reach, so a shot past a one-word bite
    /// of the take lands clear of both in one fix rather than one a check.
    /// A cut is in reach when the edge is inside its span or less than
    /// `doubleJumpReach` past its near side. Nil when none is.
    func reach(from at: Time, edge: ClipEdge, over track: Int) -> (to: Time, stretch: TimeRange, screen: Bool, transition: TransitionType?)? {
        let reach = QualityCheck.doubleJumpReach, slack = QualityCheck.snapSlack
        let starts = edge == .start
        func stretch(to target: Time) -> TimeRange { starts ? TimeRange(start: target, end: at) : TimeRange(start: at, end: target) }
        func farthest(from edgeAt: Time) -> (cut: Cut, to: Time)? {
            let window = starts ? TimeRange(start: edgeAt - reach, end: edgeAt) : TimeRange(start: edgeAt, end: edgeAt + reach)
            let inReach = cuts(around: window).compactMap { cut -> (cut: Cut, to: Time)? in
                // A start runs back to where the cut starts and an end on
                // to where it ends, so the shot hides the whole of it.
                let target = starts ? cut.span.start : cut.span.end
                let off = starts ? edgeAt - target : target - edgeAt
                let past = starts ? edgeAt - cut.span.end : cut.span.start - edgeAt
                guard cut.track < track, off > slack, past <= reach else { return nil }
                return (cut, target)
            }
            return inReach.sorted { starts ? $0.to < $1.to : $0.to > $1.to }.first { exposed(stretch(to: $0.to)) && takeShows(across: stretch(to: $0.to)) }
        }
        var reached: (cut: Cut, to: Time)?
        while let next = farthest(from: reached?.to ?? at) { reached = next }
        guard let (cut, to) = reached else { return nil }
        // A camera cut where the screen recording cuts with it.
        let together = cuts(around: TimeRange(start: to, duration: .zero)).filter { $0.track < track && (starts ? $0.span.start : $0.span.end) == to }
        return (to, stretch(to: to), together.allSatisfy(\.screen), cut.transition)
    }

    /// Whether a cut track above `track` shows one unbroken full-frame shot
    /// across `time`: the camera full frame hides a cut in the screen
    /// recording under it.
    private func hiddenByTake(_ time: Time, above track: Int) -> Bool {
        for index in project.videoTracks.indices where index > track {
            let over = project.videoTracks[index]
            guard !over.hidden, over.rippleMode == .cut,
                  let before = over.clip(at: time - Time(flicks: 1)), let after = over.clip(at: time),
                  before.enabled, after.enabled, canCover(before), canCover(after),
                  covers(before, at: time), covers(after, at: time) else { continue }
            if before.id == after.id || carriesOn(before, into: after) { return true }
        }
        return false
    }

    /// The take's clip on top in the middle of `range`, or nil when none of
    /// the take plays there.
    func takeClip(in range: TimeRange) -> Clip? {
        let middle = range.start + Time(flicks: range.duration.flicks / 2)
        for track in project.videoTracks.reversed() where !track.hidden && track.rippleMode == .cut {
            if let clip = track.clip(at: middle), clip.enabled { return clip }
        }
        return nil
    }

    /// Whether the clip plays a screen recording. Anything else in the take
    /// is the camera, or another angle of it (a close-up synced by sound
    /// comes in as B-roll).
    func isScreen(_ clip: Clip) -> Bool {
        clip.mediaID.flatMap { media[$0] }?.role == .screen
    }

    // MARK: Covering the frame

    /// Whether the clip could ever cover the frame: a picture with no alpha
    /// (a media file, a solid). Titles and adjustment layers show the take
    /// through; the only graphic that draws is the section card, handled on
    /// its own.
    private func canCover(_ clip: Clip) -> Bool {
        switch clip.content {
        case .text, .adjustment, .graphic:
            return false
        case .solid(let color):
            return color.a >= 0.99
        case .media(let id):
            guard let item = media[id], item.hasVideo || item.kind == .image, !item.hasAlpha else { return false }
            return clip.video?.cutout?.enabled != true
        }
    }

    /// Whether the clip covers the whole frame at `time` (inside it or at
    /// its end), opaque, as it's placed then.
    func covers(_ clip: Clip, at time: Time) -> Bool {
        let video = clip.resolvedVideo(at: time - clip.start)
        guard video.opacity >= 0.99, video.cutout?.enabled != true else { return false }
        // A quarter turn leaves corners uncovered; whole and half turns
        // cover what the box says.
        let turn = video.transform.rotation.truncatingRemainder(dividingBy: 180)
        guard abs(turn) < 0.01 || abs(abs(turn) - 180) < 0.01 else { return false }
        guard let box = QualityCheck.onScreen(clip, item: clip.mediaID.flatMap { media[$0] }, at: time, in: project) else { return false }
        // A pixel's slack: a shot zoomed to just fill the frame lands a hair
        // inside it.
        let slackX = 1 / Double(max(project.settings.width, 1)), slackY = 1 / Double(max(project.settings.height, 1))
        return box.x0 <= slackX && box.y0 <= slackY && box.x1 >= 1 - slackX && box.y1 >= 1 - slackY
    }

    /// Whether something other than `except` hides the take at `time`: a
    /// covering clip (on a track above `above`, when given), or a section
    /// card.
    private func covered(at time: Time, except: String, above: Int? = nil) -> Bool {
        if above == nil, cards.contains(where: { $0.contains(time) }) { return true }
        return covers.contains { cover in
            cover.clip.id != except && (above.map { cover.track > $0 } ?? true) && cover.clip.range.contains(time) && covers(cover.clip, at: time)
        }
    }

    /// Whether the edge shows the take beside it: the clip covers the frame
    /// there and is on top, the take shows on the other side, the video goes
    /// on past it, and no section card plays over it.
    func exposedEdge(_ cover: Cover, _ edge: ClipEdge) -> Bool {
        let clip = cover.clip
        let at = edge == .start ? clip.start : clip.end
        let tick = Time(flicks: 1)
        guard at > QualityCheck.snapSlack, at < end - QualityCheck.snapSlack, covers(clip, at: at),
              !cards.contains(where: { $0.start - frame <= at && at <= $0.end + frame }) else { return false }
        let outside = edge == .start ? at - tick : at
        let inside = edge == .start ? at : at - tick
        return !covered(at: outside, except: clip.id) && !covered(at: inside, except: clip.id, above: cover.track)
    }

    /// Whether nothing hides the take anywhere in `range`: no covering clip
    /// covers the frame where it overlaps it, and no section card plays.
    func exposed(_ range: TimeRange) -> Bool {
        if cards.contains(where: { $0.overlaps(range) }) { return false }
        let tick = Time(flicks: 1)
        return !covers.contains { cover in
            guard let overlap = cover.clip.range.intersection(range) else { return false }
            return covers(cover.clip, at: overlap.start) || covers(cover.clip, at: overlap.end - tick)
        }
    }

    /// How many of the project's frames land in `range`: the ones the
    /// viewer sees there.
    func frames(in range: TimeRange) -> Int {
        let perFrame = frame.flicks
        func firstAtOrAfter(_ time: Time) -> Int64 {
            time.flicks >= 0 ? (time.flicks + perFrame - 1) / perFrame : -((-time.flicks) / perFrame)
        }
        return Int(max(0, firstAtOrAfter(range.end) - firstAtOrAfter(range.start)))
    }

    // MARK: Fixing

    /// Copies of the clip's picture that move with it: other clips of the
    /// same file, not on the take, with that edge at the same moment. A
    /// portrait shot is a sharp copy over a blurred full-frame one (Convex
    /// 1.48), and running only one out to the cut leaves the other popping
    /// in a moment later.
    func copies(of clip: Clip, at edge: ClipEdge) -> [Clip] {
        guard let mediaID = clip.mediaID else { return [] }
        let at = edge == .start ? clip.start : clip.end
        return project.videoTracks.filter { !$0.hidden && $0.rippleMode != .cut }.flatMap(\.clips).filter { other in
            other.id != clip.id && other.enabled && other.mediaID == mediaID
                && abs(((edge == .start ? other.start : other.end) - at).flicks) <= QualityCheck.snapSlack.flicks
        }
    }

    /// `found` with each pair of edge fixes that would leave less than
    /// `cameraFlashLongest` of the take between a shot and the next (a
    /// flash the next check would report, against its own fix) made one
    /// camera flash instead: the first shot runs on to where the second
    /// starts, and the second stays. The same when the two fixes would
    /// cross, with cuts too near both shots to run each to its own.
    func joiningFlashesTheFixesWouldLeave(_ found: [DoubleJumpFinding], flashEdges: Set<String>) -> [DoubleJumpFinding] {
        var planned: [String: Time] = [:]
        for finding in found where finding.next == nil { planned["\(finding.clip.id)|\(finding.edge.rawValue)"] = finding.to }
        guard !planned.isEmpty else { return found }
        var replaced = Set<String>()
        var flashes: [DoubleJumpFinding] = []
        for cover in covers where !flashEdges.contains("\(cover.clip.id)|end") && exposedEdge(cover, .end) {
            let end = cover.clip.end
            guard let next = covers[firstCover(startingAfter: end + QualityCheck.snapSlack)...].first(where: { exposedEdge($0, .start) }) else { continue }
            let (first, second) = ("\(cover.clip.id)|end", "\(next.clip.id)|start")
            guard !flashEdges.contains(second), !replaced.contains(first), !replaced.contains(second) else { continue }
            let ends = planned[first], starts = planned[second]
            guard ends != nil || starts != nil else { continue }
            let left = (starts ?? next.clip.start) - (ends ?? end)
            // Run out to the same cut, they meet.
            guard abs(left.flicks) > QualityCheck.snapSlack.flicks, left < QualityCheck.cameraFlashLongest else { continue }
            let gap = TimeRange(start: end, end: next.clip.start)
            guard exposed(gap), let take = takeClip(in: left > .zero ? TimeRange(start: ends ?? end, duration: left) : gap) else { continue }
            replaced.formUnion([first, second])
            flashes.append(DoubleJumpFinding(
                clip: cover.clip, edge: .end, to: next.clip.start, stretch: gap, frames: frames(in: gap), screen: isScreen(take),
                next: next.clip, left: left, leftFrames: left > .zero ? frames(in: TimeRange(start: ends ?? end, duration: left)) : 0,
                movedFirst: ends != nil, movedSecond: starts != nil
            ))
        }
        return found.filter { $0.next != nil || !replaced.contains("\($0.clip.id)|\($0.edge.rawValue)") } + flashes
    }

    /// The track the clip is on.
    func track(of clip: Clip) -> Track? {
        project.videoTracks.first { $0.clips.contains { $0.id == clip.id } }
    }

    /// Why the clip can't move to `range` given where the other moves put
    /// their clips (`planned`), or nil when it can: one on its track would
    /// end up overlapping it. Two shots either side of one stretch can
    /// each be run into it, and `inTheWay` only sees them where they are.
    func clash(of clip: Clip, at range: TimeRange, with planned: [String: TimeRange]) -> String? {
        guard let track = track(of: clip),
              let other = track.clips.first(where: { $0.id != clip.id && planned[$0.id]?.clashes(with: range) == true }) else { return nil }
        return "The fix for \(name(other)) on \"\(track.name)\" is in the way."
    }

    /// Why the clip's edge can't move `to` there, or nil when it can: its
    /// track is locked, or another clip on it is in the way.
    func inTheWay(of clip: Clip, movingEdge edge: ClipEdge, to: Time) -> String? {
        guard let track = track(of: clip) else { return nil }
        if track.locked { return "\"\(track.name)\" is locked." }
        let range = edge == .start ? TimeRange(start: to, end: clip.start) : TimeRange(start: clip.end, end: to)
        guard let blocker = track.clips.first(where: { $0.id != clip.id && $0.range.clashes(with: range) }) else { return nil }
        return "\(name(blocker)) on \"\(track.name)\" is in the way."
    }

    /// The `updateClip` that moves the clip's start to `start` and its end
    /// to `end`, keeping what plays where it was: the file starts earlier
    /// with it, keyframes stay at their times on the timeline, and the clip
    /// holds its edge frame (`holdEdges`) where it now runs off its file.
    func fix(_ clip: Clip, start: Time?, end: Time?) -> Fix? {
        guard start != nil || end != nil else { return nil }
        var moved = clip
        // A still shows the same picture wherever it starts, and a solid
        // has no file to start earlier in.
        let playsFile = clip.mediaID.flatMap { media[$0] }?.kind == .video && !clip.freezeFrame
        if let start {
            moved.moveHead(to: start)
            if !playsFile { moved.sourceStart = clip.sourceStart }
        }
        if let end { moved.moveTail(to: end) }
        var holdsHead = false, holdsTail = false
        if playsFile {
            let limit = project.sourceLimit(for: clip)
            let runsOffHead = start != nil && moved.sourceStart < .zero
            let runsOffTail = end != nil && limit.map { moved.sourceEnd > $0 } == true
            holdsHead = runsOffHead && clip.sourceStart >= .zero
            holdsTail = runsOffTail && limit.map { clip.sourceEnd <= $0 } == true
            if runsOffHead || runsOffTail { moved.holdEdges = true }
        }
        guard let before = try? JSONValue.from(clip), let after = try? JSONValue.from(moved),
              let patch = JSONValue.mergePatch(from: before, to: after) else { return nil }
        return Fix(command: .updateClip(clipID: clip.id, patch: patch), holdsHead: holdsHead, holdsTail: holdsTail)
    }

    // MARK: Words

    /// What a clip is called in a message: its file, or what it is.
    func name(_ clip: Clip) -> String {
        if let id = clip.mediaID, let item = media[id] { return URL(fileURLWithPath: item.path).lastPathComponent }
        if let name = clip.name, !name.isEmpty { return name }
        switch clip.content {
        case .solid: return "a solid"
        case .text(let text): return "the title \"\(text.text.prefix(30))\""
        default: return "a clip"
        }
    }

    /// The problem's words, in the style of the other checks: what the
    /// viewer sees, then what to do.
    func message(for finding: DoubleJumpFinding, copies: [Clip], fix: Fix?, blocked: String?) -> String {
        let track = { (clip: Clip) in project.videoTracks.first { $0.clips.contains { $0.id == clip.id } }?.name ?? "" }
        let copyNames = copies.map { "\"\(track($0))\"" }
        let withCopies = copyNames.isEmpty ? "" : " and its cop\(copyNames.count == 1 ? "y" : "ies") on \(copyNames.joined(separator: " and "))"
        let holds = finding.edge == .start ? fix?.holdsHead == true : fix?.holdsTail == true
        let holding = holds ? ", holding its \(finding.edge == .start ? "first" : "last") frame" : ""
        let seconds = finding.stretch.duration.seconds
        var words: String
        if let next = finding.next {
            func amount(_ duration: Time, frames: Int) -> String {
                frames == 0 ? String(format: "%.3f s", duration.seconds)
                    : frames < 10 ? "\(frames) frame\(frames == 1 ? "" : "s")" : String(format: "%.1f s", duration.seconds)
            }
            let (kind, take) = finding.screen ? ("Screen flash", "the screen recording") : ("Camera flash", "camera")
            let between = "of \(take) between \(name(finding.clip)) and \(name(next))"
            let what: String
            if let left = finding.left, left > .zero {
                // Honest about where it came from: there's more than a
                // flash of camera now, but the edges' own fixes would leave
                // one.
                let running = finding.movedFirst && finding.movedSecond ? "running both out to the cuts"
                    : finding.movedFirst ? "running \(name(finding.clip)) on to the cut" : "extending \(name(next)) back to the cut"
                what = "\(running) would leave \(amount(left, frames: finding.leftFrames)) \(between)"
            } else if finding.left != nil {
                what = "\(amount(finding.stretch.duration, frames: finding.frames)) \(between), with cuts too near both to run each out to its own"
            } else {
                what = "\(amount(finding.stretch.duration, frames: finding.frames)) \(between)"
            }
            words = "\(kind): \(what). Run the first\(withCopies) on to the second\(holding)."
        } else {
            let age = finding.edge == .start ? "new" : "old"
            let source = finding.screen ? "the screen recording" : "the camera"
            let (cut, shot): (String, String)
            if let transition = finding.transition {
                // The shot is measured from the far side of the transition,
                // where the fix runs it out to.
                let kind = transition == .cutSlide ? "cut slide" : transition.rawValue
                (cut, shot) = ("a \(kind) on \(source) \(finding.edge == .start ? "starts" : "ends")", source)
            } else {
                (cut, shot) = finding.screen ? ("a cut in the screen recording", "its \(age) shot") : ("a camera cut", "the \(age) camera shot")
            }
            let side = finding.edge == .start ? "after" : "before"
            let off: String
            if finding.frames == 0 {
                off = "\(String(format: "%.3f s", seconds)) \(side) \(cut), under a frame at \(fps) fps, but it's free to close"
            } else {
                let count = "\(finding.frames) frame\(finding.frames == 1 ? "" : "s")"
                let shows = finding.transition == nil ? "flashes" : "shows"
                off = "\(count) \(side) \(cut), so \(shot) \(shows) for \(QualityCheck.seconds(finding.stretch.duration)) \(finding.edge == .start ? "before" : "after") it"
            }
            let target = finding.transition.map { "\(finding.edge == .start ? "the start" : "the end") of the \($0 == .cutSlide ? "cut slide" : $0.rawValue)" } ?? "the cut"
            let action = finding.edge == .start ? "Extend it\(withCopies) back to \(target)\(holding)." : "Run it\(withCopies) on to \(target)\(holding)."
            words = "Double jump: \(name(finding.clip)) \(finding.edge == .start ? "starts" : "ends") \(off). \(action)"
        }
        if let blocked { words += " \(blocked)" }
        return words
    }
}
