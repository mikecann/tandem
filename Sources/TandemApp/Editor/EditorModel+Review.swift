import Foundation
import TandemCore

/// Reviewing what agents changed: stepping the playhead from one changed
/// stretch to the next, and marking them all reviewed.
extension EditorModel {
    /// Moves the playhead to the start of the next (or previous) change an
    /// agent made and scrolls it into view. With `wrap` (clicking the
    /// review chip's count) it goes round: after the last, the first. False
    /// when there's none that way, which beeps.
    @discardableResult
    func goToAgentChange(forward: Bool, wrap: Bool = false) -> Bool {
        let now = playback.time
        var found = forward ? review.stop(after: now) : review.stop(before: now)
        var wrapped = false
        if found == nil, wrap, let first = forward ? review.stops.first : review.stops.last {
            found = first
            wrapped = true
        }
        guard let stop = found else {
            if review.stops.isEmpty {
                show(.info, "No agent changes to review.")
            } else {
                show(.info, forward ? "No more agent changes after the playhead." : "No agent changes before the playhead.")
            }
            return false
        }
        playback.pause()
        playback.seek(to: stop.time)
        timeline.bringIntoView(stop.time)
        if let latest = stop.edits.last {
            let others = stop.edits.count > 1 ? " and \(stop.edits.count - 1) more" : ""
            let round = wrapped && review.stops.count > 1 ? "Back to the first change. " : ""
            show(.info, "\(round)\(ActivityLog.displayName(latest.author)): \(latest.label)\(others)")
        }
        return true
    }

    /// The playhead moved. Played forwards at up to double speed, the
    /// stretch it went through counts as watched, and the agent changes
    /// Mike has now watched in full are reviewed: their highlights go as
    /// he plays past them. A jump, a scrub, playing backwards or fast
    /// forwards doesn't count.
    func notePlayhead() {
        let now = playback.time
        guard playback.isPlaying, playback.rate > 0, playback.rate <= 2, !reviewLog.isEmpty else {
            lastWatched = nil
            return
        }
        if let last = lastWatched, now >= last, (now - last).seconds < 1 {
            noteWatched(from: last, to: now)
        }
        lastWatched = now
    }

    /// Mike watched `from` to `to` on the timeline as it is now: what he's
    /// watched in full is reviewed.
    func noteWatched(from: Time, to: Time) {
        // An edit moves things, so what he watched before it no longer
        // lines up with the timeline.
        if watchedRevision != revision {
            watched = []
            watchedRevision = revision
        }
        watched = TimeRange.union(watched + [TimeRange(start: from, end: to)])
        session.review.markWatched(watched, in: project)
    }

    /// Mike has seen what the agents changed: the log starts again empty
    /// and the highlights go.
    @discardableResult
    func markAgentChangesReviewed() -> Bool {
        guard !reviewLog.isEmpty else {
            show(.info, "No agent edits to review.")
            return false
        }
        let count = review.editCount
        session.review.markReviewed()
        reviewChanged(ReviewLog())
        show(.info, count == 1 ? "Marked 1 agent edit reviewed." : "Marked \(count) agent edits reviewed.")
        return true
    }
}

extension TimelineViewState {
    /// Scrolls `time` into view when it isn't showing, a quarter of the way
    /// in, so what follows it shows too.
    func bringIntoView(_ time: Time) {
        let x = scale.x(time)
        guard x < 0 || x > lanesWidth * 0.85 else { return }
        scale.scrollSeconds = max(0, time.seconds - Double(lanesWidth * 0.25) / scale.pixelsPerSecond)
    }
}
