import Foundation

extension QualityCheck {
    /// How close two clips' source times must be to be the same moment of
    /// the same camera: the stacked layout's crops are cut from one file at
    /// one time, so they line up exactly; a second off is a deliberate echo.
    static let sameMomentSlack = Time(seconds: 0.5)

    /// The same camera at the same moment on screen twice at once: two
    /// enabled clips on shown tracks, from one file, overlapping on the
    /// timeline at matching source times. In a Short's stacked layout that's
    /// one person twice, like Nipunn's arm drawing on the board in the top
    /// window over his face below, or Mike pointing at the board up top over
    /// Mike talking below. Mike, 30 Oct 2026: "there's awkward moments where
    /// you can see both my arm and my face talking at the same time. It seems
    /// a bit odd." A copy under a blur (the blurred fill behind a shot that
    /// doesn't cover the frame) is the same picture on purpose, so it's left
    /// out.
    public static func sameShotTwice(in project: Project, ranges: [TimeRange]) -> [CheckProblem] {
        struct Shown { var clip: Clip; var track: String }
        var byMedia: [String: [Shown]] = [:]
        for track in project.videoTracks where !track.hidden {
            for clip in track.clips where clip.enabled && clip.duration > .zero {
                guard let mediaID = clip.mediaID, let item = project.media(mediaID), item.hasVideo, !clip.freezeFrame else { continue }
                if clip.video?.effects.contains(where: { $0.enabled && $0.type == "blur" }) == true { continue }
                if (clip.video?.opacity ?? 1) <= 0.01 { continue }
                byMedia[mediaID, default: []].append(Shown(clip: clip, track: track.name))
            }
        }
        var found: [CheckProblem] = []
        for (mediaID, shown) in byMedia where shown.count > 1 {
            let name = URL(fileURLWithPath: project.media(mediaID)?.path ?? mediaID).lastPathComponent
            for i in 0..<shown.count {
                for j in (i + 1)..<shown.count where shown[i].track != shown[j].track {
                    let a = shown[i].clip, b = shown[j].clip
                    guard let both = a.range.intersection(b.range), both.duration > .zero,
                          ranges.contains(where: { $0.overlaps(both) }) else { continue }
                    let mid = both.start + Time(seconds: both.duration.seconds / 2)
                    let apart = a.sourceTime(atTimelineTime: mid) - b.sourceTime(atTimelineTime: mid)
                    guard abs(apart.seconds) < sameMomentSlack.seconds else { continue }
                    found.append(CheckProblem(
                        kind: .sameShotTwice, start: both.start, end: both.end,
                        message: "Same shot twice: \(name) is on \"\(shown[i].track)\" and \"\(shown[j].track)\" at the same moment, so whoever's in it is on screen twice. Swap one for a graphic or another angle, or go full frame on one.",
                        clipIDs: [a.id, b.id]
                    ))
                }
            }
        }
        return found
    }
}
