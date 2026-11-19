import Foundation

extension Editing {
    /// `holdFrame`: the picture `clipID` shows a frame before `range`
    /// starts, held over `range`, so a flash there (a stale frame, the
    /// preview jumping as Mike clicked) is gone. Only the picture changes:
    /// its sound and the clips linked to it play on as they were.
    ///
    /// The hold is kept on the clip (`Clip.holds`), by media time, not cut
    /// into pieces. Pieces of one clip shared its link group, and every
    /// linked edit then had to know which piece to move: on the workbench
    /// short (19 Nov 2026) a ripple trim of the voice moved each piece's
    /// edge, the held frame grew to 0.233 s and the camera fell 0.2 to 0.4 s
    /// behind the voice. Held by media time, it stays on the frames it
    /// covers whatever the clip goes through.
    static func holdFrame(_ p: inout Project, clipID: String, range: TimeRange, _ context: inout EditContext) throws {
        let (location, index) = try requireClip(p, clipID)
        let track = p[location]
        try requireUnlocked(track)
        let clip = track.clips[index]
        guard track.kind == .video, let mediaID = clip.mediaID, let item = p.media(mediaID), item.kind == .video, item.hasVideo else {
            throw EditError.invalid("clip \(clipID) isn't part of a video on a video track, so it has no frame to hold")
        }
        guard !clip.freezeFrame else { throw EditError.invalid("clip \(clipID) is a freeze frame already, so every frame of it is held") }
        guard !range.isEmpty else { throw EditError.invalid("hold a range at least a frame long") }
        guard range.start >= clip.start, range.end <= clip.end else {
            throw EditError.invalid("\(range.start)-\(range.end) isn't inside clip \(clipID) (\(clip.start)-\(clip.end))")
        }
        let frame = p.settings.frameRate.frameDuration
        let source = TimeRange(start: clip.sourceTime(atTimelineTime: range.start), end: clip.sourceTime(atTimelineTime: range.end))
        // The file's frame before the range: a frame of the file, not of
        // the timeline (in a slow clip a timeline frame back can still be
        // the flash), and before the clip's start the file's frame there,
        // as if the clip started a frame early. A frame already held there
        // stays the one shown.
        let fileFrame = item.frameRate?.frameDuration ?? frame
        var held = source.start - max(fileFrame, frame.scaled(by: clip.speed))
        if let earlier = clip.holds.first(where: { $0.source.contains(held) }) { held = earlier.frame }
        if let limit = p.sourceLimit(for: clip) { held = min(held, limit) }
        // Times are kept to the sample, so the file's first frame can come
        // out a hair under zero.
        guard held > -frame.scaled(by: 0.5) else {
            throw EditError.invalid("\(range.start) is the first frame of its file, so there's no frame before it to hold: trim the clip to start after it instead")
        }
        held = max(held, .zero)

        var edited = clip
        // A hold it overlaps or meets becomes part of this one, showing the
        // earlier hold's frame.
        var merged = HeldFrame(source: source, frame: held)
        var kept: [HeldFrame] = []
        for hold in clip.holds {
            if hold.source.end >= merged.source.start && hold.source.start <= merged.source.end {
                let earlier = hold.source.start < merged.source.start
                merged = HeldFrame(
                    source: TimeRange(start: min(hold.source.start, merged.source.start), end: max(hold.source.end, merged.source.end)),
                    frame: earlier ? hold.frame : merged.frame
                )
            } else {
                kept.append(hold)
            }
        }
        edited.holds = (kept + [merged]).sorted { $0.source.start < $1.source.start }
        p[location].clips[index] = edited
    }
}
