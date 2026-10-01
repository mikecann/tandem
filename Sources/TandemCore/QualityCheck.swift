import Foundation

/// Something `tandem check` found wrong in a stretch of the timeline.
///
/// Mike caught these in the ESLint video before the agent did, and each
/// cost a review round: an eight-frame white box where a green screen
/// didn't key, a one-frame flicker from a stale still, and a 1080p shot
/// zoomed until it went soft on the 4K frame. An agent runs the check
/// before handing an edit back, so Mike's rounds go on the edit itself.
public struct CheckProblem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Nothing on any shown video track: black.
        case gap
        /// Frames that render black with something on the timeline.
        case black
        /// One to three frames unlike the frames either side.
        case flicker
        /// Flat green on screen: a green screen that didn't key.
        case unkeyed
        /// A flat white block that comes and goes.
        case whiteBlock
        /// A picture shown well past its own pixels, so it looks soft.
        case soft

        /// Worth knowing rather than wrong: Mike signed off softer zooms on
        /// cartoon B-roll than on screen recordings, so a soft picture
        /// doesn't fail a check.
        public var isNote: Bool { self == .soft }
    }

    public var kind: Kind
    public var start: Time
    public var end: Time
    /// How many frames, for problems found in rendered frames.
    public var frames: Int?
    public var message: String
    /// The clips there: the pictures on screen, top first, or the soft clip.
    public var clipIDs: [String]

    public init(kind: Kind, start: Time, end: Time, frames: Int? = nil, message: String, clipIDs: [String] = []) {
        self.kind = kind
        self.start = start
        self.end = end
        self.frames = frames
        self.message = message
        self.clipIDs = clipIDs
    }
}

/// One rendered frame's measurements, made by TandemRender's scanner from a
/// grid of tiles over a small render of the frame.
public struct FrameStats: Equatable, Sendable {
    /// One tile: its mean red, green and blue, and how far its luma
    /// spreads (the standard deviation), all 0 to 1.
    public struct Tile: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var spread: Double

        public init(red: Double, green: Double, blue: Double, spread: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.spread = spread
        }

        public var luma: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

        /// Green screen green, evenly lit: on screen, a key that didn't happen.
        public var isFlatGreen: Bool {
            spread < 0.05 && green > 0.55 && green - max(red, blue) > 0.3
        }

        public var isFlatWhite: Bool {
            spread < 0.03 && min(red, green, blue) > 0.92
        }
    }

    public var time: Time
    /// Mean luma, 0 to 1.
    public var luma: Double
    /// The brightest tile's mean luma: a black frame is dark everywhere.
    public var brightestTile: Double
    /// The share of tiles that are flat green, and flat white.
    public var flatGreen: Double
    public var flatWhite: Double
    /// Tile lumas, 0 to 255, row by row: a thumbnail to compare frames by.
    public var thumbnail: [UInt8]

    public init(time: Time, luma: Double, brightestTile: Double, flatGreen: Double, flatWhite: Double, thumbnail: [UInt8]) {
        self.time = time
        self.luma = luma
        self.brightestTile = brightestTile
        self.flatGreen = flatGreen
        self.flatWhite = flatWhite
        self.thumbnail = thumbnail
    }

    public init(time: Time, tiles: [Tile]) {
        let count = Double(max(tiles.count, 1))
        self.init(
            time: time,
            luma: tiles.reduce(0) { $0 + $1.luma } / count,
            brightestTile: tiles.map(\.luma).max() ?? 0,
            flatGreen: Double(tiles.filter(\.isFlatGreen).count) / count,
            flatWhite: Double(tiles.filter(\.isFlatWhite).count) / count,
            thumbnail: tiles.map { UInt8(clamping: Int(($0.luma * 255).rounded())) }
        )
    }

    /// How different two frames look, 0 to 1: the mean difference of their
    /// thumbnails.
    public func difference(from other: FrameStats) -> Double {
        guard thumbnail.count == other.thumbnail.count, !thumbnail.isEmpty else { return 1 }
        var total = 0
        for index in thumbnail.indices { total += abs(Int(thumbnail[index]) - Int(other.thumbnail[index])) }
        return Double(total) / Double(thumbnail.count * 255)
    }

    public var isBlack: Bool { luma < 0.02 && brightestTile < 0.05 }
}

/// The checks behind `tandem check`. The model checks (gaps, soft
/// pictures) read the project; the frame checks read `FrameStats` for each
/// rendered frame.
public enum QualityCheck {
    /// A picture shown at more than this many frame pixels for each of its
    /// own looks soft: 1080p is shown at 2x on a 4K frame, and zooming it
    /// past 150% goes beyond this. That's where Mike saw a shot go blurry in
    /// the ESLint video.
    public static let softUpscale = 3.0
    /// Frames this different from both neighbours, while the neighbours
    /// match each other, are a flicker.
    static let flickerJump = 0.1
    static let neighboursMatch = 0.03
    /// A flat white block counts while it covers this much of the frame and
    /// lasts at most this many frames, coming and going around it.
    static let whiteShare = 0.05
    static let whiteLongest = 45
    /// Flat green over this much of the frame is a key that didn't happen.
    static let greenShare = 0.01

    /// Every problem in `ranges`, by time. Without `frames` only the model
    /// checks run.
    public static func problems(in project: Project, ranges: [TimeRange], frames: [FrameStats]?) -> [CheckProblem] {
        let gapProblems = gaps(in: project, ranges: ranges)
        var found = gapProblems + softPictures(in: project, ranges: ranges)
        if let frames {
            found += frameProblems(frames, in: project, skipping: gapProblems.map { TimeRange(start: $0.start, end: $0.end) })
        }
        return found.sorted { ($0.start, $0.kind.rawValue) < ($1.start, $1.kind.rawValue) }
    }

    // MARK: - Model checks

    /// Stretches with nothing on any shown video track. Titles and
    /// adjustment layers don't count: they show over black.
    public static func gaps(in project: Project, ranges: [TimeRange]) -> [CheckProblem] {
        let frame = project.settings.frameRate.frameDuration
        var covered: [TimeRange] = []
        for track in project.videoTracks where !track.hidden {
            for clip in track.clips where clip.enabled {
                switch clip.content {
                case .media, .solid, .graphic: covered.append(clip.range)
                case .text, .adjustment: continue
                }
            }
        }
        let merged = merge(covered)
        let timeline = TimeRange(start: .zero, end: project.duration)
        var found: [CheckProblem] = []
        for range in ranges {
            guard let wanted = range.intersection(timeline) else { continue }
            var cursor = wanted.start
            for piece in merged where piece.end > cursor && piece.start < wanted.end {
                if piece.start - cursor >= frame {
                    found.append(gap(cursor, piece.start))
                }
                cursor = max(cursor, piece.end)
            }
            if wanted.end - cursor >= frame {
                found.append(gap(cursor, wanted.end))
            }
        }
        return found
    }

    private static func gap(_ start: Time, _ end: Time) -> CheckProblem {
        CheckProblem(kind: .gap, start: start, end: end, message: "Black: nothing on any video track for \(seconds(end - start)).")
    }

    /// Pictures shown past `softUpscale` times their own pixels, zoomed or
    /// keyframed there at any point in the clip.
    public static func softPictures(in project: Project, ranges: [TimeRange]) -> [CheckProblem] {
        let canvasWidth = Double(project.settings.width)
        let canvasHeight = Double(project.settings.height)
        var found: [CheckProblem] = []
        for track in project.videoTracks where !track.hidden {
            for clip in track.clips where clip.enabled && ranges.contains(where: { $0.overlaps(clip.range) }) {
                guard let mediaID = clip.mediaID, let item = project.media(mediaID),
                      let width = item.width, let height = item.height, width > 0, height > 0 else { continue }
                let fit = min(canvasWidth / Double(width), canvasHeight / Double(height))
                let scales = [clip.video?.transform.scale ?? 1] + (clip.keyframes["video.transform.scale"] ?? []).compactMap(\.value.number)
                let scale = scales.max() ?? 1
                let upscale = fit * scale
                guard upscale > softUpscale + 0.001 else { continue }
                let name = URL(fileURLWithPath: item.path).lastPathComponent
                let zoom = Int((scale * 100).rounded())
                found.append(CheckProblem(
                    kind: .soft, start: clip.start, end: clip.end,
                    message: "Soft: \(name) is shown at \(String(format: "%.1f", upscale))x its own pixels (\(width)x\(height) at \(zoom)% on a \(Int(canvasWidth))x\(Int(canvasHeight)) frame).",
                    clipIDs: [clip.id]
                ))
            }
        }
        return found
    }

    // MARK: - Frame checks

    /// Problems in rendered frames, by time. Frames in `skipping` (gaps,
    /// already reported) and in fades to and from black aren't black
    /// problems.
    public static func frameProblems(_ frames: [FrameStats], in project: Project, skipping: [TimeRange] = []) -> [CheckProblem] {
        guard !frames.isEmpty else { return [] }
        let frameDuration = project.settings.frameRate.frameDuration
        let runs = contiguousRuns(frames, frameDuration: frameDuration)
        let fades = fadeWindows(in: project)
        var found: [CheckProblem] = []
        for run in runs {
            let slice = Array(frames[run])
            let specific = black(slice, project: project, frameDuration: frameDuration, quiet: skipping + fades)
                + unkeyed(slice, project: project, frameDuration: frameDuration)
                + whiteBlocks(slice, project: project, frameDuration: frameDuration)
            // A frame of black or white between matching frames is a
            // flicker too; it's reported once, as what it is.
            let flickers = flickers(slice, project: project, frameDuration: frameDuration).filter { flicker in
                !specific.contains { $0.start == flicker.start && $0.end == flicker.end }
            }
            found += specific + flickers
        }
        return found.sorted { ($0.start, $0.kind.rawValue) < ($1.start, $1.kind.rawValue) }
    }

    /// Runs of black frames, outside the `quiet` stretches.
    static func black(_ frames: [FrameStats], project: Project, frameDuration: Time, quiet: [TimeRange]) -> [CheckProblem] {
        let flagged = frames.map { stats in stats.isBlack && !quiet.contains { $0.contains(stats.time) } }
        return runs(of: flagged).map { run in
            let count = run.count
            return problem(.black, frames, run, project: project, frameDuration: frameDuration,
                           message: "Black: \(count) frame\(count == 1 ? "" : "s") render black with something on the timeline.")
        }
    }

    /// One to three frames unlike the frames either side, while those two
    /// match: a stale still, a frame of the wrong shot, a frame that
    /// dropped out.
    static func flickers(_ frames: [FrameStats], project: Project, frameDuration: Time) -> [CheckProblem] {
        var found: [CheckProblem] = []
        var index = 1
        while index < frames.count - 1 {
            let before = frames[index - 1]
            var matched: Int?
            for length in 1...3 where index + length < frames.count {
                let after = frames[index + length]
                guard before.difference(from: after) < neighboursMatch else { continue }
                if frames[index].difference(from: before) > flickerJump && frames[index + length - 1].difference(from: after) > flickerJump {
                    matched = length
                    break
                }
            }
            guard let length = matched else {
                index += 1
                continue
            }
            let run = index..<(index + length)
            found.append(problem(.flicker, frames, run, project: project, frameDuration: frameDuration,
                                 message: "Flicker: \(length) frame\(length == 1 ? "" : "s") unlike the frames either side, which match each other."))
            index += length + 1
        }
        return found
    }

    static func unkeyed(_ frames: [FrameStats], project: Project, frameDuration: Time) -> [CheckProblem] {
        runs(of: frames.map { $0.flatGreen >= greenShare }).map { run in
            let share = run.map { frames[$0].flatGreen }.max() ?? 0
            return problem(.unkeyed, frames, run, project: project, frameDuration: frameDuration,
                           message: "Green screen: flat green covers \(percent(share)) of the frame (a key that didn't happen?).")
        }
    }

    /// A flat white block that appears and goes within a second and a half,
    /// where the frames either side have far less of it. White pages in a
    /// screen recording stay, so they don't count.
    static func whiteBlocks(_ frames: [FrameStats], project: Project, frameDuration: Time) -> [CheckProblem] {
        runs(of: frames.map { $0.flatWhite >= whiteShare }).compactMap { run in
            // One that runs off either end of what was read may not come
            // and go at all.
            guard run.count <= whiteLongest, run.lowerBound > 0, run.upperBound < frames.count else { return nil }
            let least = run.map { frames[$0].flatWhite }.min() ?? 0
            let before = frames[run.lowerBound - 1].flatWhite
            let after = frames[run.upperBound].flatWhite
            guard before < least / 3 && after < least / 3 else { return nil }
            let share = run.map { frames[$0].flatWhite }.max() ?? 0
            return problem(.whiteBlock, frames, run, project: project, frameDuration: frameDuration,
                           message: "White block: a flat white patch over \(percent(share)) of the frame comes and goes in \(run.count) frame\(run.count == 1 ? "" : "s") (a key or matte that failed?).")
        }
    }

    // MARK: - Helpers

    private static func problem(_ kind: CheckProblem.Kind, _ frames: [FrameStats], _ run: Range<Int>, project: Project, frameDuration: Time, message: String) -> CheckProblem {
        let start = frames[run.lowerBound].time
        let end = frames[run.upperBound - 1].time + frameDuration
        return CheckProblem(kind: kind, start: start, end: end, frames: run.count, message: message, clipIDs: pictures(at: start, in: project))
    }

    /// The pictures on screen at `time`, top first.
    public static func pictures(at time: Time, in project: Project) -> [String] {
        project.videoTracks.reversed().filter { !$0.hidden }.compactMap { track in
            track.clip(at: time).flatMap { clip -> String? in
                guard clip.enabled else { return nil }
                if case .adjustment = clip.content { return nil }
                return clip.id
            }
        }
    }

    /// Where fades to and from black play, which are black on purpose.
    static func fadeWindows(in project: Project) -> [TimeRange] {
        var windows: [TimeRange] = []
        for track in project.videoTracks where !track.hidden {
            let clips = Dictionary(track.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for transition in track.transitions where transition.type == .fadeToBlack || transition.type == .fadeFromBlack {
                if let span = ReviewLog.span(of: transition, clips: clips) {
                    windows.append(TimeRange(start: span.start, end: span.end))
                }
            }
        }
        return windows
    }

    /// Index ranges of frames that follow each other with no time skipped
    /// (a check of several stretches reads each on its own).
    static func contiguousRuns(_ frames: [FrameStats], frameDuration: Time) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = 0
        for index in 1..<max(frames.count, 1) where frames[index].time - frames[index - 1].time > frameDuration.scaled(by: 1.5) {
            runs.append(start..<index)
            start = index
        }
        if start < frames.count { runs.append(start..<frames.count) }
        return runs
    }

    /// Runs of true values, as index ranges.
    static func runs(of flags: [Bool]) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var start: Int?
        for (index, flag) in flags.enumerated() {
            if flag, start == nil { start = index }
            if !flag, let first = start {
                found.append(first..<index)
                start = nil
            }
        }
        if let first = start { found.append(first..<flags.count) }
        return found
    }

    /// Ranges with overlapping and touching ones joined, by start.
    public static func merge(_ ranges: [TimeRange]) -> [TimeRange] {
        var merged: [TimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func seconds(_ time: Time) -> String {
        let value = time.seconds
        return value < 10 ? String(format: "%.2f s", value) : String(format: "%.1f s", value)
    }

    static func percent(_ share: Double) -> String {
        "\(max(1, Int((share * 100).rounded())))%"
    }
}
