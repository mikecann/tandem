import Foundation
import TandemCore

/// An empty stretch between clips that Close gap (`closeGap`) can take
/// out: on one track, or across the take's tracks, which close together.
/// Hovering one shows a box over it with an × that closes it, as Filmora
/// does.
struct TimelineGap: Equatable {
    var range: TimeRange
    /// The tracks it closes on: the take's when the track ripples with
    /// them, else just the one.
    var trackIDs: [String]
    /// Where it was found, for `closeGap`.
    var trackID: String
    var at: Time

    /// The gap at `time` on `trackID`, when Close gap there would work:
    /// between two clips (or before the first), on an unlocked track, and
    /// for the take with every one of its tracks empty there, so closing it
    /// can't put picture and sound out of step.
    static func at(_ time: Time, onTrack trackID: String, in project: Project) -> TimelineGap? {
        guard let track = project.track(trackID), !track.locked, track.clip(at: time) == nil else { return nil }
        let start = track.clips.filter { $0.end <= time }.map(\.end).max() ?? .zero
        guard let end = track.clips.filter({ $0.start > time }).map(\.start).min(), end > start else { return nil }
        let range = TimeRange(start: start, end: end)
        guard track.rippleMode == .cut else {
            return TimelineGap(range: range, trackIDs: [trackID], trackID: trackID, at: time)
        }
        let take = project.allTracks.filter { $0.rippleMode == .cut }
        guard take.allSatisfy({ !$0.locked && $0.clips(intersecting: range).isEmpty }) else { return nil }
        return TimelineGap(range: range, trackIDs: take.map(\.id), trackID: trackID, at: time)
    }

    var batch: EditBatch {
        EditBatch(label: "Close gap", commands: [.closeGap(trackID: trackID, at: at)])
    }
}
