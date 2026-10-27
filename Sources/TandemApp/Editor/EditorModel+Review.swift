import Foundation
import TandemCore

/// Reviewing what agents changed: stepping the playhead from one changed
/// stretch to the next, the walkthrough of the things an agent asked Mike
/// to look at first, and marking them all reviewed.
extension EditorModel {
    /// Moves the playhead to the start of the next (or previous) change an
    /// agent made and scrolls it into view. While an agent's things to look
    /// at wait and Mike hasn't skipped them, they come first, in timeline
    /// order, each played through with its line on a card over the viewer;
    /// after the last, stepping goes on through the other changes from the
    /// start. With `wrap` (clicking the review chip's count) it goes round:
    /// after the last, the first, and it starts the walkthrough again when
    /// there's one to have. False when there's none that way, which beeps.
    @discardableResult
    func goToAgentChange(forward: Bool, wrap: Bool = false) -> Bool {
        if wrap, walkthroughDone, !review.notes.isEmpty {
            walkthroughDone = false
            walkthroughOrder = []
            walkthrough = nil
        }
        if !walkthroughDone, !walkthroughOrder.isEmpty || !review.notes.isEmpty {
            if let step = nextWalkthroughStep(forward: forward) {
                go(to: step)
                return true
            }
            if forward {
                // The walkthrough's over: on through the rest from the top.
                let count = walkthroughOrder.count
                walkthrough = nil
                walkthroughDone = true
                let key = Shortcuts.symbol(for: .nextAgentChange) ?? "]"
                if let first = review.stops.first {
                    go(to: first.time)
                    show(.info, "That's all \(count == 1 ? "1 thing" : "\(count) things") to look at. \(key) now steps through the other changes, from the first.")
                    return true
                }
                show(.info, "That's all \(count == 1 ? "1 thing" : "\(count) things") to look at, and there are no other changes to step through.")
                return false
            }
        }
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
        go(to: stop.time)
        if let latest = stop.edits.last {
            let others = stop.edits.count > 1 ? " and \(stop.edits.count - 1) more" : ""
            let round = wrapped && review.stops.count > 1 ? "Back to the first change. " : ""
            show(.info, "\(round)\(ActivityLog.displayName(latest.author)): \(latest.label)\(others)")
        }
        return true
    }

    /// The playhead to `time`, paused, with it in view.
    private func go(to time: Time) {
        playback.pause()
        playback.seek(to: time)
        timeline.bringIntoView(time)
    }

    /// The walkthrough's next step that way: the next thing to look at in
    /// the round's order that's still waiting (one Mike watched on his own
    /// is skipped), or nil past either end.
    private func nextWalkthroughStep(forward: Bool) -> WalkthroughStep? {
        if walkthroughOrder.isEmpty { walkthroughOrder = review.notes.map(\.id) }
        let count = walkthroughOrder.count
        var index = walkthrough.map { $0.index + (forward ? 1 : -1) } ?? (forward ? 0 : count - 1)
        while walkthroughOrder.indices.contains(index) {
            if let note = review.notes.first(where: { $0.id == walkthroughOrder[index] }) {
                return WalkthroughStep(note: note, index: index, count: count)
            }
            index += forward ? 1 : -1
        }
        return nil
    }

    /// Goes to a thing to look at and plays its stretch; the card shows
    /// its line, and `notePlayhead` pauses at its end.
    private func go(to step: WalkthroughStep) {
        go(to: step.note.start)
        walkthrough = step
        if step.note.end > step.note.start { playback.play() }
    }

    /// Mike doesn't want the walkthrough (Escape while a card shows): the
    /// card goes and stepping is the ordinary kind until the next round, or
    /// until he clicks the chip's count. False when there's no card.
    @discardableResult
    func skipWalkthrough() -> Bool {
        guard walkthrough != nil else { return false }
        walkthrough = nil
        walkthroughDone = true
        let key = Shortcuts.symbol(for: .nextAgentChange) ?? "]"
        show(.info, "Walkthrough skipped. \(key) steps through every change; click the count on the review chip to start it again.")
        return true
    }

    /// The playhead moved. Played forwards at up to double speed, the
    /// stretch it went through counts as watched, and the agent changes
    /// Mike has now watched in full are reviewed: their highlights go as
    /// he plays past them. A jump, a scrub, playing backwards or fast
    /// forwards doesn't count. Pausing and playing on from the same spot
    /// does: Mike often stops halfway through a change to think.
    func notePlayhead() {
        let now = playback.time
        // The walkthrough plays a stretch and stops at its end, once;
        // playing on from there is Mike's own.
        if var step = walkthrough, !step.held, playback.isPlaying, playback.rate > 0, now >= step.note.end {
            playback.pause()
            step.held = true
            walkthrough = step
        }
        guard !reviewLog.isEmpty else {
            lastWatched = nil
            return
        }
        let ahead = lastWatched.map { now >= $0 && (now - $0).seconds < 1 } ?? false
        if playback.isPlaying {
            guard playback.rate > 0, playback.rate <= 2 else {
                lastWatched = nil
                return
            }
            if ahead, let last = lastWatched { noteWatched(from: last, to: now) }
            lastWatched = now
            pausedWatching = false
        } else if ahead, !pausedWatching, let last = lastWatched {
            // Pausing: the picture stops a moment after the last tick.
            // Up to there counts, and the spot is kept, so playing on
            // carries on from it without a gap.
            noteWatched(from: last, to: now)
            lastWatched = now
            pausedWatching = true
        } else {
            // Moved while paused: a jump or a scrub.
            lastWatched = nil
            pausedWatching = false
        }
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
    /// and the highlights go, and the walkthrough with them.
    @discardableResult
    func markAgentChangesReviewed() -> Bool {
        guard !reviewLog.isEmpty else {
            show(.info, "No agent edits to review.")
            return false
        }
        let count = review.editCount
        let looked = review.notes.count
        session.review.markReviewed()
        reviewChanged(ReviewLog())
        walkthrough = nil
        walkthroughDone = false
        walkthroughOrder = []
        var what = count == 1 ? "1 agent edit" : "\(count) agent edits"
        if count == 0 { what = looked == 1 ? "1 thing to look at" : "\(looked) things to look at" }
        show(.info, "Marked \(what) reviewed.")
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
