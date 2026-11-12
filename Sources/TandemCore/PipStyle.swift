import Foundation

// Picture-in-picture that isn't Mike's usual, for `tandem check`.
//
// Mike's PiP is the camera cut out of its background in the bottom corner
// (`pipRight`, or `pipLeft` flipped to face the screen), at the size and
// place his Filmora projects had it. On the Convex Auth v2 video (12 Nov
// 2026) the agent swapped it for a cropped, framed box of his face because
// the cutout's matte wasn't made yet, and Mike: "what's going on with the
// picture in picture here? This is not our usual way". The skill said so;
// the check now does too. A Short's face box (cutout off, cropped to his
// face) is the layout he passed for portrait, so portrait isn't checked.

extension QualityCheck {
    /// A camera picture covering less of the frame than this is shown
    /// small: a PiP of some kind. Full frame is 1.
    static let pipLargest = 0.9
    /// How far scale and position can be from the preset's and still be it.
    static let pipSlack = 0.03

    /// Notes for camera clips shown smaller than the frame that aren't
    /// `pipRight` or `pipLeft` with the cutout on, in a landscape project,
    /// one for each run of them on a track, with the `applyLayout` that
    /// puts them back. A split screen is a layout of its own and left alone.
    public static func offStylePip(in project: Project, ranges: [TimeRange]) -> [CheckProblem] {
        guard project.settings.width >= project.settings.height, !conversation(project) else { return [] }
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        struct Found { var clip: Clip; var reason: String; var left: Bool }
        var notes: [CheckProblem] = []
        for (index, track) in project.videoTracks.enumerated() where !track.hidden && !Editing.isPrivacyTrack(track) {
            // Tracks are bottom to top, so these draw over this one.
            let above = Array(project.videoTracks[(index + 1)...])
            var run: [Found] = []
            func close() {
                guard let first = run.first, let last = run.last else { return }
                notes.append(note(run.map(\.clip), reasons: run.map(\.reason), left: first.left, start: first.clip.start, end: last.clip.end))
                run = []
            }
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                guard let found = offStyle(clip, item: clip.mediaID.flatMap { media[$0] }, above: above, in: project, ranges: ranges) else {
                    // Anything else shown between two that aren't Mike's
                    // usual (his PiP, full frame) ends the run.
                    close()
                    continue
                }
                if let last = run.last, found.clip.start - last.clip.end > Time(seconds: 0.5) { close() }
                run.append(Found(clip: found.clip, reason: found.reason, left: found.left))
            }
            close()
        }
        return notes
    }

    /// Why `clip` is a camera PiP that isn't Mike's usual, if it is one.
    /// Judged at moments through each stretch it's in, where it's on screen
    /// small and nothing full frame on a track above hides it: the cutout
    /// off anywhere is off-style; so is a size or place that's never the
    /// preset's for most of the time it shows, so a PiP that slides in from
    /// off the edge to its corner (Threadbear launch, 10:31) is fine and
    /// one keyframed to 70% isn't. A
    /// crop with the cutout on is a repair, and fine.
    static func offStyle(_ clip: Clip, item: MediaItem?, above: [Track], in project: Project, ranges: [TimeRange]) -> (clip: Clip, reason: String, left: Bool)? {
        guard clip.enabled, !clip.isObscured, let item, item.role == .camera, item.hasVideo else { return nil }
        // The whole clip, once any of it is in the stretches: a stretch
        // that only takes in a slide-in would never see where it settles.
        guard ranges.contains(where: { clip.range.intersection($0).map { $0.duration > .zero } ?? false }) else { return nil }
        let shown = [clip.range]
        var cutoutOff = false, cropped = false, anyShown = false
        // Where it sits at the moments it's on screen small and at rest.
        var resting: [Transform] = []
        func small(at time: Time) -> Bool {
            guard let box = onScreen(clip, item: item, at: time, in: project) else { return false }
            return box.area < pipLargest
        }
        for piece in shown {
            for step in 0..<pipSamples {
                let share = (Double(step) + 0.5) / Double(pipSamples)
                let time = piece.start + Time(seconds: piece.duration.seconds * share)
                guard small(at: time), !hidden(at: time, by: above, in: project),
                      !otherCameraSmall(at: time, besides: item.id, in: project) else { continue }
                let video = clip.resolvedVideo(at: time - clip.start)
                if video.layoutPreset == LayoutPreset.split.rawValue { return nil }
                anyShown = true
                if video.cutout?.enabled != true {
                    cutoutOff = true
                    if !video.crop.isIdentity { cropped = true }
                }
                // Only where it's at rest: part way through a slide says
                // nothing about where it sits.
                let soon = clip.resolvedVideo(at: min(clip.duration, time - clip.start + Time(seconds: 0.1))).transform
                if same(soon, video.transform) { resting.append(video.transform) }
            }
        }
        guard anyShown else { return nil }
        // Never at rest while it shows (a slide out that starts at once, or
        // a size that changes all along): where its moves start and end.
        if resting.isEmpty {
            let keys = (clip.keyframes["video.transform.position"] ?? []) + (clip.keyframes["video.transform.scale"] ?? [])
            resting = keys.map(\.time).filter { small(at: clip.start + $0) }.map { clip.resolvedVideo(at: $0).transform }
        }
        // The corner it rests in most, then whether it's at the preset's
        // size and place there for most of that time: a slide in or out
        // passes, a PiP that settles at another size doesn't.
        let left = resting.filter { $0.position.x < 0.5 }.count * 2 > resting.count
        let place = left ? LayoutPreset.pipLeftPosition : LayoutPreset.pipRightPosition
        func placed(_ transform: Transform) -> Bool {
            abs(transform.scale - LayoutPreset.pipScale) <= pipSlack
                && abs(transform.position.x - place.x) <= pipSlack && abs(transform.position.y - place.y) <= pipSlack
        }
        var reasons: [String] = []
        if cutoutOff { reasons.append("cutout off") }
        if cropped { reasons.append("cropped") }
        if resting.filter(placed).count * 2 < resting.count, let off = resting.first(where: { !placed($0) }) {
            let preset = left ? LayoutPreset.pipLeft : .pipRight
            reasons.append(String(format: "%.0f%% at (%.2f, %.2f), not %@'s 50%% in the corner", off.scale * 100, off.position.x, off.position.y, preset.rawValue))
        }
        return reasons.isEmpty ? nil : (clip, reasons.joined(separator: ", "), left)
    }

    static func same(_ a: Transform, _ b: Transform) -> Bool {
        abs(a.scale - b.scale) < 0.001 && abs(a.position.x - b.position.x) < 0.001 && abs(a.position.y - b.position.y) < 0.001
    }

    /// Another camera file shown small at the same moment: a conversation's
    /// boxes side by side, laid out for the people in them, not Mike's
    /// corner. Only those moments are left alone, so a second angle
    /// somewhere else in the edit doesn't switch the check off.
    static func otherCameraSmall(at time: Time, besides mediaID: String, in project: Project) -> Bool {
        project.videoTracks.contains { track in
            guard !track.hidden, let clip = track.clip(at: time), clip.enabled, let id = clip.mediaID, id != mediaID,
                  let item = project.media(id), item.role == .camera, let box = onScreen(clip, item: item, at: time, in: project) else { return false }
            return box.area < pipLargest
        }
    }

    /// Moments looked at in each clip.
    static let pipSamples = 9

    /// Whether something on `above` covers the whole frame at `time`, so
    /// nothing under it shows: an opaque picture (not a file with alpha, a
    /// sticker or a graphic, which can be see-through) or a solid, full
    /// frame and fully opaque.
    static func hidden(at time: Time, by above: [Track], in project: Project) -> Bool {
        above.contains { track in
            guard !track.hidden, !Editing.isPrivacyTrack(track), let clip = track.clip(at: time), clip.enabled, !clip.isObscured else { return false }
            let item = clip.mediaID.flatMap { project.media($0) }
            switch clip.content {
            case .media:
                guard let item, !item.hasAlpha, item.role != .sticker, item.role != .graphic,
                      clip.resolvedVideo(at: time - clip.start).cutout?.enabled != true else { return false }
            case .solid(let color):
                guard color.a >= 0.99 else { return false }
            case .text, .graphic, .adjustment: return false
            }
            guard clip.resolvedVideo(at: time - clip.start).opacity >= 0.99, let box = onScreen(clip, item: item, at: time, in: project) else { return false }
            let slack = 0.01
            return box.x0 <= slack && box.y0 <= slack && box.x1 >= 1 - slack && box.y1 >= 1 - slack
        }
    }

    static func note(_ clips: [Clip], reasons: [String], left: Bool, start: Time, end: Time) -> CheckProblem {
        let preset = left ? LayoutPreset.pipLeft : .pipRight
        let ids = clips.map(\.id)
        let quoted = ids.map { "\"\($0)\"" }.joined(separator: ", ")
        var distinct: [String] = []
        for reason in reasons where !distinct.contains(reason) { distinct.append(reason) }
        let count = clips.count == 1 ? "A camera clip" : "\(clips.count) camera clips"
        let message = "\(count) shown small but not Mike's usual picture-in-picture (\(distinct.joined(separator: "; "))). "
            + "His PiP is \(preset.rawValue) with the cutout, always: \"This is not our usual way\". If the matte isn't made yet, start it and wait "
            + "(tandem wait matte) rather than framing his face in a box. "
            + "Fix: tandem apply '{\"applyLayout\": {\"clipIDs\": [\(quoted)], \"preset\": \"\(preset.rawValue)\"}}'"
        return CheckProblem(kind: .offStylePip, start: start, end: end, message: message, clipIDs: ids)
    }
}
