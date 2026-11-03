import CoreGraphics
import Foundation
import TandemCore

/// Which clip's picture is really on screen, so the inspector and the viewer
/// land on the picture Mike is looking at, not a turned-off angle above it.
///
/// Mike turned the close-up angle off and graded "the start of the video":
/// the linked close-up was the clip in the inspector, so seven contrast edits
/// went to a clip that wasn't showing and nothing changed on screen.
@MainActor
enum PictureVisibility {
    static func isOn(_ clip: Clip, in project: Project) -> Bool {
        clip.enabled && project.track(containingClip: clip.id)?.hidden != true
    }

    /// Whether nothing under this clip can show through. It errs towards
    /// false: telling Mike a clip is hidden when it isn't sends him off to
    /// grade the wrong one, so anything that might leave a hole counts as
    /// not covering (a style effect's rounded corners, a blur's soft edge).
    static func covers(_ clip: Clip, at time: Time, in project: Project, registry: EffectRegistry = .standard) -> Bool {
        guard case .media = clip.content, let item = clip.mediaID.flatMap({ project.media($0) }),
              item.kind == .video || item.kind == .image, !item.hasAlpha else { return false }
        let video = clip.resolvedVideo(at: time - clip.start)
        guard video.opacity >= 1, video.cutout?.enabled != true,
              video.transform.rotation.truncatingRemainder(dividingBy: 360) == 0 else { return false }
        let onlyColour = (item.look + video.effects).allSatisfy { !$0.enabled || registry.definition($0.type)?.category == "Colour" }
        guard onlyColour else { return false }
        let canvas = CGRect(x: 0, y: 0, width: project.settings.width, height: project.settings.height)
        let frame = CanvasGeometry.frame(source: CanvasGeometry.sourceSize(of: clip, in: project), transform: video.transform, canvas: canvas)
        return CanvasGeometry.cropped(frame, crop: video.crop).insetBy(dx: -0.5, dy: -0.5).contains(canvas)
    }

    /// The topmost clip that hides this one at `time`.
    static func coveringClip(of clip: Clip, at time: Time, in project: Project) -> Clip? {
        let tracks = project.videoTracks
        guard let index = tracks.firstIndex(where: { $0.clips.contains { $0.id == clip.id } }) else { return nil }
        for track in tracks[(index + 1)...].reversed() where !track.hidden {
            if let above = track.clip(at: time), above.enabled, covers(above, at: time, in: project) { return above }
        }
        return nil
    }

    /// The picture on screen at `time`: the topmost clip that fills the frame,
    /// or failing that the topmost footage. Titles and small overlays above
    /// it don't count, since nobody grades a lower third to fix the shot.
    static func picture(at time: Time, in project: Project) -> Clip? {
        var topmost: Clip?
        for track in project.videoTracks.reversed() where !track.hidden {
            guard let clip = track.clip(at: time), clip.enabled, case .media = clip.content else { continue }
            if covers(clip, at: time, in: project) { return clip }
            if topmost == nil { topmost = clip }
        }
        return topmost
    }

    /// The selected picture to show in place of a turned-off one: clicking
    /// a linked group by its turned-off angle still means the group, so the
    /// inspector goes to the angle that's on. Nil when `clipID` is on, isn't
    /// a picture, or was selected without its group (Option-click), which is
    /// how to get at a turned-off clip on purpose. An unrelated clip selected
    /// alongside doesn't count: that's not another angle of this shot.
    ///
    /// It works from the clips' ranges rather than the playhead, because the
    /// inspector calls this on every redraw and shouldn't follow playback.
    static func onInstead(of clipID: String, among selection: Set<String>, in project: Project) -> String? {
        guard let clip = project.clip(clipID), selection.count > 1, let group = clip.linkGroup,
              project.track(containingClip: clipID)?.kind == .video, !isOn(clip, in: project) else { return nil }
        for track in project.videoTracks.reversed() where !track.hidden {
            for other in track.clips where selection.contains(other.id) && other.linkGroup == group && other.enabled && other.range.overlaps(clip.range) {
                if case .media = other.content { return other.id }
            }
        }
        return nil
    }

    /// Whether this clip's picture is what you'd see, at the playhead or, when
    /// the playhead is elsewhere, at the clip's own start.
    static func isShowing(_ clip: Clip, playhead: Time, in project: Project) -> Bool {
        isOn(clip, in: project) && coveringClip(of: clip, at: judgedTime(of: clip, playhead: playhead), in: project) == nil
    }

    /// The selected pictures an inspector could act on, top track first: the
    /// angles of a linked group.
    static func pictures(in selection: Set<String>, of project: Project) -> [Clip] {
        project.videoTracks.reversed().flatMap { track in
            track.clips.filter { clip in
                guard selection.contains(clip.id), case .media = clip.content else { return false }
                return true
            }
        }
    }

    private static func judgedTime(of clip: Clip, playhead: Time) -> Time {
        clip.start <= playhead && playhead < clip.end ? playhead : clip.start
    }

    /// Says a clip isn't what's on screen, and what is.
    struct Notice: Equatable {
        var text: String
        /// The clip to edit instead, when something else is showing.
        var instead: String?
        /// Where that's true, for a clip the playhead isn't on.
        var time: Time
    }

    /// Nil when editing this clip will show. `look` is true for an edit to
    /// the file's look, which reaches every clip of that file, so a hidden
    /// clip is no problem when another clip of the same file is on screen.
    static func notice(for clip: Clip, editingLook look: Bool, playhead: Time, in project: Project) -> Notice? {
        let time = judgedTime(of: clip, playhead: playhead)
        let replacement: Clip?
        let reason: String
        if !isOn(clip, in: project) {
            replacement = linkedPicture(of: clip, at: time, in: project) ?? picture(at: time, in: project)
            reason = clip.enabled ? "its track is hidden" : "it's turned off"
        } else if let cover = coveringClip(of: clip, at: time, in: project) {
            replacement = cover
            reason = "\(name(cover, in: project)) is on top of it"
        } else {
            return nil
        }
        if look, let replacement, replacement.mediaID != nil, replacement.mediaID == clip.mediaID { return nil }
        guard let replacement else {
            return Notice(text: "This clip isn't showing here: \(reason), and nothing else is on screen.", instead: nil, time: time)
        }
        let seeing = isOn(clip, in: project) ? "" : " You're seeing \(name(replacement, in: project))."
        return Notice(text: "This clip isn't showing here: \(reason).\(seeing)", instead: replacement.id, time: time)
    }

    private static func linkedPicture(of clip: Clip, at time: Time, in project: Project) -> Clip? {
        guard clip.linkGroup != nil else { return nil }
        let linked = Set(project.linkedClipIDs(of: clip.id))
        for track in project.videoTracks.reversed() where !track.hidden {
            // Not one that's under something else: "you're seeing" has to be true.
            if let other = track.clip(at: time), linked.contains(other.id), other.enabled, case .media = other.content,
               coveringClip(of: other, at: time, in: project) == nil { return other }
        }
        return nil
    }

    private static func name(_ clip: Clip, in project: Project) -> String {
        // Non-breaking hyphens, so a wrap doesn't split the file name.
        ClipRenderer.name(of: clip, in: project).replacingOccurrences(of: "-", with: "\u{2011}")
    }
}
