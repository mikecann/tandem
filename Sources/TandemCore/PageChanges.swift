import Foundation

// Page changes on the screen recording with no transition, for
// `tandem check`.
//
// Page changes in an explainer or slides push. An agent working from its
// cue list missed 10 of them on Build Your Own Convex, and Mike pushed them
// by hand. So the check finds them in the screen recording itself, scanned
// on its own (`screenOnly`), as the camera picture-in-picture sits over it
// in the composite: a large share of the picture changing at once, then
// holding. Typing, a moving cursor and a demo's animations change too
// little at once, or keep changing; a scroll is the same lines moved. It's
// a note, as a big change in a demo isn't always a page that should push.

extension QualityCheck {
    /// Scanlines are measured in this many bands across the frame, so a
    /// pane that scrolls beside a sidebar that doesn't still reads as a
    /// scroll.
    public static let scanlineBands = 4
    /// A tile changes when its luma moves by more than this (of 255). Mike's
    /// explainers are dim text on a dark page, so a new page moves its tiles
    /// by less than a bright one would.
    static let pageLevel = 6
    /// A new page changes at least this share of the recording's tiles
    /// (unzoomed, as recorded)...
    static let pageShare = 0.2
    /// ...or at least this share, changing them by `pageMean` (of 255)
    /// across the whole frame on average. In Build Your Own Convex the page
    /// flips changed 14 to 48% of the recording, by 2.6 to 12.6 on
    /// average; buttons that add rows or light up a step on the same page
    /// changed 12 to 19%, by 2.2 to 3.7.
    static let strongShare = 0.14
    static let pageMean = 4.0
    /// The change has to be over within this many frames after the first:
    /// an explainer's own quick fade between pages takes four or five, a
    /// scroll with momentum or an animation runs much longer.
    static let pageFrames = 5
    /// Then the new page holds for this long, with at most `holdShare` of
    /// it moving (a cursor, typing, a blinking caret)...
    static let pageHold = Time(seconds: 0.5)
    static let holdShare = 0.05
    /// ...after a picture that held for this long, with at most
    /// `settledShare` of it moving.
    static let pageSettled = Time(seconds: 0.3)
    static let settledShare = 0.1
    /// Where to start looking: this share of tiles changing in one frame.
    static let startShare = 0.05
    /// The page before, moved up or down, matching what's there now this
    /// much better than unmoved is a scroll: content that scrolls matches
    /// itself almost exactly, where the closest of Build Your Own Convex's
    /// page flips came to 0.13...
    static let scrollMatch = 0.1
    /// ...when its lines differ by at least this much (of 255, averaged over
    /// every line) unmoved. A new page laid out like the last one barely
    /// changes its lines, and moving them can't tell anything from that.
    static let scrollFloor = 1.0

    /// Screen recording page changes in `ranges` with no transition over
    /// them, as notes, from `screenFrames` (the recording scanned on its own,
    /// with scanlines). Only changes the viewer sees count: ones under a
    /// full-frame B-roll shot or the camera full frame don't.
    public static func pageChanges(in project: Project, ranges: [TimeRange], screenFrames: [FrameStats]) -> [CheckProblem] {
        let frameDuration = project.settings.frameRate.frameDuration
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hold = frameCount(pageHold, frameDuration)
        let settled = frameCount(pageSettled, frameDuration)
        var found: [CheckProblem] = []
        for run in contiguousRuns(screenFrames, frameDuration: frameDuration) {
            let frames = Array(screenFrames[run])
            var index = 1
            while index < frames.count {
                guard changedShare(frames[index - 1], frames[index]) >= startShare, let end = settle(frames, from: index, hold: hold) else {
                    index += 1
                    continue
                }
                let before = frames[index - 1], after = frames[end]
                let share = changedShare(before, after)
                let big = share >= pageShare || (share >= strongShare && meanChange(before, after) >= pageMean)
                let steady = frames[max(0, index - 1 - settled)..<(index - 1)].allSatisfy { changedShare($0, before) <= settledShare }
                if big, steady, !isScroll(before.scanlines, after.scanlines),
                   let note = pageNote(from: before.time, to: frames[index].time, settled: after.time + frameDuration, share: share, in: project, media: media) {
                    found.append(note)
                }
                index = end + 1
            }
        }
        return found.filter { note in ranges.contains { $0.contains(note.start) } }
    }

    /// The first frame from `index` (within `pageFrames`) that the frames
    /// after it hold to for `hold` frames, or nil when the picture keeps
    /// changing or the scan ends before it can tell.
    static func settle(_ frames: [FrameStats], from index: Int, hold: Int) -> Int? {
        for end in index..<min(frames.count, index + pageFrames + 1) {
            let last = end + hold
            guard last < frames.count else { return nil }
            if frames[(end + 1)...last].allSatisfy({ changedShare(frames[end], $0) <= holdShare }) { return end }
        }
        return nil
    }

    private static func pageNote(from before: Time, to change: Time, settled: Time, share: Double, in project: Project, media: [String: MediaItem]) -> CheckProblem? {
        guard let old = screenClip(at: before, in: project, media: media), let new = screenClip(at: change, in: project, media: media),
              screenShows(at: before, in: project, media: media), screenShows(at: change, in: project, media: media),
              !transitionCovers(change, in: project, media: media) else { return nil }
        let atCut = old.clip.id != new.clip.id
        let how = "\(percent(share)) of the screen recording changes at once, then holds."
        let message = atCut
            ? "Page change at a cut, with no transition: \(how) If it's a new page, push it (0.7 s, on the Screen track)."
            : "Page change inside a clip, with no transition: \(how) If it's a new page, push it: freeze 0.35 s either side and push between the freezes."
        return CheckProblem(kind: .pageChange, start: change, end: settled, message: message, clipIDs: atCut ? [old.clip.id, new.clip.id] : [new.clip.id])
    }

    /// The share of tiles that changed between two frames.
    static func changedShare(_ a: FrameStats, _ b: FrameStats) -> Double {
        guard a.thumbnail.count == b.thumbnail.count, !a.thumbnail.isEmpty else { return 1 }
        var changed = 0
        for tile in a.thumbnail.indices where abs(Int(a.thumbnail[tile]) - Int(b.thumbnail[tile])) > pageLevel { changed += 1 }
        return Double(changed) / Double(a.thumbnail.count)
    }

    /// How much two frames' tiles differ on average, 0 to 255.
    static func meanChange(_ a: FrameStats, _ b: FrameStats) -> Double {
        guard a.thumbnail.count == b.thumbnail.count, !a.thumbnail.isEmpty else { return 255 }
        var total = 0
        for tile in a.thumbnail.indices { total += abs(Int(a.thumbnail[tile]) - Int(b.thumbnail[tile])) }
        return Double(total) / Double(a.thumbnail.count)
    }

    /// Whether `after` is `before` moved up or down: a scroll.
    static func isScroll(_ before: [UInt8], _ after: [UInt8]) -> Bool {
        guard let match = scrolledMatch(before, after) else { return false }
        return match <= scrollMatch
    }

    /// How well `before`, each band moved up or down by whatever suits it
    /// best (in half lines, from 2 lines to a third of the height), matches
    /// `after` on the lines that changed: their difference moved over their
    /// difference unmoved, 0 for a perfect scroll. Lines that didn't change,
    /// like a header that stays put while the page scrolls, don't count.
    /// Nil when too little changed to tell.
    static func scrolledMatch(_ before: [UInt8], _ after: [UInt8]) -> Double? {
        let bands = scanlineBands
        guard before.count == after.count, before.count % bands == 0, before.count / bands >= 12 else { return nil }
        let height = before.count / bands
        var unmoved = 0.0, matched = 0.0
        for band in 0..<bands {
            let a = before[(band * height)..<((band + 1) * height)].map(Double.init)
            let b = after[(band * height)..<((band + 1) * height)].map(Double.init)
            let changed = (0..<height).filter { abs(a[$0] - b[$0]) > 2 }
            guard changed.count >= height / 10 else { continue }
            let still = changed.reduce(0) { $0 + abs(a[$1] - b[$1]) } / Double(changed.count)
            var best = still
            for halves in 4...max(4, height * 2 / 3) {
                for shift in [halves, -halves] {
                    best = min(best, lineDifference(a, b, halves: shift, on: changed))
                }
            }
            unmoved += still * Double(changed.count)
            matched += best * Double(changed.count)
        }
        guard unmoved / Double(before.count) >= scrollFloor else { return nil }
        return matched / unmoved
    }

    /// The mean difference, over the `lines` both have, between `after` and
    /// `before` moved up by `halves` half lines (down when negative).
    static func lineDifference(_ before: [Double], _ after: [Double], halves: Int, on lines: [Int]) -> Double {
        let whole = halves >= 0 ? halves / 2 : -((-halves + 1) / 2)
        let half = halves - whole * 2
        var total = 0.0, count = 0
        for line in lines {
            let from = line + whole
            guard from >= 0, from + half < before.count else { continue }
            let moved = half == 0 ? before[from] : (before[from] + before[from + 1]) / 2
            total += abs(after[line] - moved)
            count += 1
        }
        return count * 2 >= lines.count ? total / Double(count) : .infinity
    }

    /// The screen recording on top at `time`, as `screenOnly` draws them,
    /// and its track's index.
    static func screenClip(at time: Time, in project: Project, media: [String: MediaItem]) -> (track: Int, clip: Clip)? {
        for (index, track) in project.videoTracks.enumerated().reversed() where !track.hidden {
            if let clip = track.clip(at: time), clip.enabled, let id = clip.mediaID, media[id]?.role == .screen {
                return (index, clip)
            }
        }
        return nil
    }

    /// Whether the screen recording shows at `time`: nothing over it covers
    /// half the frame (a full-frame B-roll shot, the camera full frame, a
    /// card). A cut-out camera leaves the screen showing around Mike.
    static func screenShows(at time: Time, in project: Project, media: [String: MediaItem]) -> Bool {
        guard let screen = screenClip(at: time, in: project, media: media) else { return false }
        for track in project.videoTracks[(screen.track + 1)...] where !track.hidden {
            guard let clip = track.clip(at: time), clip.enabled, clip.video?.cutout?.enabled != true,
                  let box = onScreen(clip, item: clip.mediaID.flatMap { media[$0] }, at: time, in: project) else { continue }
            if box.area >= 0.5 { return false }
        }
        return true
    }

    /// Whether a transition into or out of a screen recording plays over
    /// `time`, give or take a frame.
    static func transitionCovers(_ time: Time, in project: Project, media: [String: MediaItem]) -> Bool {
        let slack = project.settings.frameRate.frameDuration
        for track in project.videoTracks where !track.hidden {
            for transition in track.transitions {
                guard let window = transition.window(on: track), window.start - slack <= time, time <= window.end + slack else { continue }
                let ends = [transition.fromClipID, transition.toClipID].compactMap { id in track.clips.first { $0.id == id } }
                if ends.contains(where: { $0.mediaID.flatMap { media[$0] }?.role == .screen }) { return true }
            }
        }
        return false
    }

    /// Where screen recordings play within `ranges`: what a scan of
    /// `screenOnly` needs to read.
    public static func screenRanges(in project: Project, within ranges: [TimeRange]) -> [TimeRange] {
        let screens = Set(project.media.filter { $0.role == .screen && $0.hasVideo }.map(\.id))
        let playing = merge(project.videoTracks.filter { !$0.hidden }.flatMap { track in
            track.clips.filter { clip in clip.enabled && clip.mediaID.map(screens.contains) == true }.map(\.range)
        })
        return merge(ranges).flatMap { range in playing.compactMap { $0.intersection(range) } }
    }

    static func frameCount(_ time: Time, _ frameDuration: Time) -> Int {
        max(1, Int((time.seconds / frameDuration.seconds).rounded()))
    }
}
