import Foundation

// Dead air for `tandem check`: a still picture with nothing to hear.
//
// Mike only caught a silent second at 3:56 of Build Your Own Convex on his
// final watch, and fixing it cost a 13.7 GB re-export. Pauses that let a
// point land, or that run while something animates, are fine, so this is a
// note for the agent to cut or justify, never a failure.

extension QualityCheck {
    /// What's said on the timeline, for dead air.
    public struct Speech: Equatable, Sendable {
        public struct Word: Equatable, Sendable {
            public var text: String
            public var start: Time
            public var end: Time

            public init(text: String, start: Time, end: Time) {
                self.text = text
                self.start = start
                self.end = end
            }
        }

        /// Every word said, in timeline order, with its edges on the voice
        /// (as `tandem pauses` reads them).
        public var words: [Word]
        /// The audio clips the words come from: between their words they're
        /// silent. Every other clip that's heard counts as sound for as long
        /// as it plays (sound effects, demo sounds, a voice whose transcript
        /// isn't ready yet), and music only where it swells or comes in.
        public var clipIDs: Set<String>

        public init(words: [Word] = [], clipIDs: Set<String> = []) {
            self.words = words
            self.clipIDs = clipIDs
        }
    }

    /// A still, silent stretch this long is dead air: twice the 0.4 s
    /// Mike leaves between sentences, so a sentence pause never is.
    public static let deadAirMinimum = Time(seconds: 0.8)
    /// A tile whose luma moves by more than this (of 255) between two
    /// frames has moved. Mike's cursor does, and so does a small badge
    /// sliding across an explainer, which look the same at this size.
    static let stillNoise = 2
    /// At least this many tiles moving by more than `eventLevel` at once is
    /// something happening: a result appearing, a cut to a new picture.
    static let eventTiles = 5
    static let eventLevel = 6
    /// Movement in this many frames running (one quiet frame inside the run
    /// doesn't break it) is something animating. A click or a hover only
    /// moves a frame or two.
    static let motionFrames = 4
    /// A new music bed coming in counts as a swell for its fade in, and for
    /// at least this long.
    static let musicArrival = Time(seconds: 1)
    /// Gain keyframes rising by more than this many dB are a swell.
    static let swellRise = 1.0

    /// Stretches of `ranges` with no speech, no sound effect and no music
    /// swell, at least `deadAirMinimum` long, where the picture holds still,
    /// as notes. Section cards and gaps (which are reported as black) are
    /// never dead air.
    public static func deadAir(in project: Project, ranges: [TimeRange], frames: [FrameStats], speech: Speech) -> [CheckProblem] {
        let timeline = TimeRange(start: .zero, end: project.duration)
        let lively = merge(
            sounds(in: project, speech: speech) + cards(in: project)
                + gaps(in: project, ranges: ranges).map { TimeRange(start: $0.start, end: $0.end) }
        )
        var quiet: [TimeRange] = []
        for range in merge(ranges) {
            guard let wanted = range.intersection(timeline) else { continue }
            quiet += uncovered(wanted, by: lively).filter { $0.duration >= deadAirMinimum }
        }
        guard !quiet.isEmpty, !frames.isEmpty else { return [] }
        let frameDuration = project.settings.frameRate.frameDuration
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [CheckProblem] = []
        for stretch in quiet {
            // Every frame that shows during the stretch, including the one
            // already showing as it starts.
            let inside = slice(frames, within: TimeRange(start: stretch.start - frameDuration + Time(flicks: 1), end: stretch.end))
            for run in contiguousRuns(inside, frameDuration: frameDuration) {
                let shots = Array(inside[run])
                for still in stillRuns(shots, in: project, media: media) {
                    let span = TimeRange(start: shots[still.lowerBound].time, end: shots[still.upperBound - 1].time + frameDuration)
                    guard let dead = span.intersection(stretch), dead.duration >= deadAirMinimum else { continue }
                    found.append(deadAirNote(dead, speech: speech, project: project))
                }
            }
        }
        return found
    }

    private static func deadAirNote(_ range: TimeRange, speech: Speech, project: Project) -> CheckProblem {
        let before = speech.words.filter { $0.end <= range.start }.suffix(4).map(\.text).joined(separator: " ")
        let after = speech.words.filter { $0.start >= range.end }.prefix(4).map(\.text).joined(separator: " ")
        var message = "Dead air: \(seconds(range.duration)) with nothing said, no sound effect or music swell, and a still picture"
        if !before.isEmpty {
            message += " (after \"\(before)\")"
        } else if !after.isEmpty {
            message += " (before \"\(after)\")"
        }
        message += ". Cut it, or keep it if the pause earns it."
        return CheckProblem(kind: .deadAir, start: range.start, end: range.end, message: message, clipIDs: pictures(at: range.start, in: project))
    }

    // MARK: - What's heard

    /// Where there's something to hear: the words, every other clip that's
    /// heard except music, and music where it swells or comes in. Tracks
    /// play as a render plays them: muted ones don't, and when any track is
    /// soloed only those do.
    static func sounds(in project: Project, speech: Speech) -> [TimeRange] {
        var heard = speech.words.map { TimeRange(start: $0.start, end: $0.end) }
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let soloing = project.audioTracks.contains { $0.solo && !$0.muted }
        for track in project.audioTracks where !track.muted && (!soloing || track.solo) {
            for clip in track.clips where clip.enabled && !(clip.audio?.muted ?? false) && !clip.freezeFrame {
                guard let id = clip.mediaID, let item = media[id], item.hasAudio else { continue }
                if item.role == .music {
                    heard += swells(of: clip)
                } else if !speech.clipIDs.contains(clip.id) {
                    heard.append(clip.range)
                }
            }
        }
        return heard
    }

    /// Where a music clip swells: from where its gain keyframes start to
    /// rise until they're back down (they set the gain outright, at times
    /// from the clip's start), and as it comes in, a new bed starting.
    static func swells(of clip: Clip) -> [TimeRange] {
        let arrival = max(clip.audio?.fadeIn ?? .zero, musicArrival)
        var found = [TimeRange(start: clip.start, duration: min(clip.duration, arrival))]
        let keys = (clip.keyframes["audio.gainDB"] ?? []).sorted { $0.time < $1.time }
        var index = 0
        while index + 1 < keys.count {
            guard let base = keys[index].value.number, let next = keys[index + 1].value.number, next > base + swellRise else {
                index += 1
                continue
            }
            var end = index + 1
            while end < keys.count, let value = keys[end].value.number, value > base + swellRise { end += 1 }
            let stop = end < keys.count ? clip.start + keys[end].time : clip.end
            if let swell = TimeRange(start: clip.start + keys[index].time, end: stop).intersection(clip.range) {
                found.append(swell)
            }
            index = end
        }
        return found
    }

    /// Where section cards play.
    static func cards(in project: Project) -> [TimeRange] {
        project.videoTracks.filter { !$0.hidden }.flatMap { track in
            track.clips.filter { $0.enabled && SectionCard.isCard($0.content) }.map(\.range)
        }
    }

    // MARK: - A still picture

    /// Runs of frames, as index ranges, that hold one picture: the steps
    /// between them neither change much of it at once nor keep moving.
    ///
    /// Mike's camera doesn't count where it's the picture on top (he moves
    /// in his corner while he's quiet), and nor does the frame's outer ring
    /// of tiles: on a screen recording that's where the Dock pops up and the
    /// menu bar ticks. The dead second at 3:56 of Build Your Own Convex had
    /// the Dock pop up in it. A cursor that moves now and then doesn't count
    /// either, but one that keeps moving does, as it looks just like a
    /// demo's animation at this size.
    static func stillRuns(_ frames: [FrameStats], in project: Project, media: [String: MediaItem]) -> [Range<Int>] {
        guard let first = frames.first else { return [] }
        let columns = first.columns, rows = first.rows
        let edge = edgeTiles(columns: columns, rows: rows)
        let camera = frames.map { cameraTiles(at: $0.time, in: project, media: media, columns: columns, rows: rows) }
        var moving = [Bool](repeating: false, count: frames.count)
        var busy = [Bool](repeating: false, count: frames.count)
        for index in frames.indices.dropFirst() {
            let a = frames[index - 1].thumbnail, b = frames[index].thumbnail
            guard a.count == b.count, a.count == edge.count else {
                busy[index] = true
                continue
            }
            var moved = 0, jumped = 0
            for tile in a.indices where !edge[tile] && !(camera[index - 1][tile] && camera[index][tile]) {
                let delta = abs(Int(a[tile]) - Int(b[tile]))
                if delta > stillNoise { moved += 1 }
                if delta > eventLevel { jumped += 1 }
            }
            moving[index] = moved > 0
            busy[index] = jumped >= eventTiles
        }
        var animating = moving
        for index in frames.indices.dropFirst().dropLast() where moving[index - 1] && moving[index + 1] {
            animating[index] = true
        }
        for run in runs(of: animating) where run.count >= motionFrames {
            for index in run { busy[index] = true }
        }
        // A slow fade or drift moves too little from frame to frame to show
        // above, so each frame is also held against the first of its run.
        func drifted(_ index: Int, from start: Int) -> Bool {
            let a = frames[start].thumbnail, b = frames[index].thumbnail
            var changed = 0
            for tile in a.indices where !edge[tile] && !camera[start][tile] && !camera[index][tile] {
                if abs(Int(a[tile]) - Int(b[tile])) > eventLevel { changed += 1 }
            }
            return changed >= eventTiles
        }
        var still: [Range<Int>] = []
        var start = 0
        for index in frames.indices.dropFirst() where busy[index] || drifted(index, from: start) {
            still.append(start..<index)
            start = index
        }
        still.append(start..<frames.count)
        return still
    }

    /// The frame's outer ring of tiles, when it's big enough to have an
    /// inside.
    static func edgeTiles(columns: Int, rows: Int) -> [Bool] {
        var edge = [Bool](repeating: false, count: columns * rows)
        guard columns >= 3, rows >= 3 else { return edge }
        for row in 0..<rows {
            for column in 0..<columns where row == 0 || row == rows - 1 || column == 0 || column == columns - 1 {
                edge[row * columns + column] = true
            }
        }
        return edge
    }

    /// Tiles where Mike's camera is the picture on top at `time`: the whole
    /// box of it, cut out or not, and not a tile past it (a demo's badge
    /// slid along just above his head in Build Your Own Convex). A
    /// full-frame camera covers every tile. Tiles under something drawn over
    /// the camera (a sticker, a B-roll shot) aren't his.
    static func cameraTiles(at time: Time, in project: Project, media: [String: MediaItem], columns: Int, rows: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: columns * rows)
        let tracks = project.videoTracks
        for (index, track) in tracks.enumerated() where !track.hidden {
            guard let clip = track.clip(at: time), clip.enabled, let id = clip.mediaID, let item = media[id], item.role == .camera,
                  let camera = onScreen(clip, item: item, at: time, in: project) else { continue }
            let over = tracks[(index + 1)...].filter { !$0.hidden }.compactMap { track -> Box? in
                guard let clip = track.clip(at: time), clip.enabled else { return nil }
                return onScreen(clip, item: clip.mediaID.flatMap { media[$0] }, at: time, in: project)
            }
            for row in 0..<rows {
                for column in 0..<columns {
                    let tile = Box(
                        x0: Double(column) / Double(columns), y0: Double(row) / Double(rows),
                        x1: Double(column + 1) / Double(columns), y1: Double(row + 1) / Double(rows)
                    )
                    guard camera.overlaps(tile), !over.contains(where: { $0.contains(x: tile.midX, y: tile.midY) }) else { continue }
                    mask[row * columns + column] = true
                }
            }
        }
        return mask
    }

    // MARK: - Helpers

    /// A rectangle in fractions of the frame, y down.
    struct Box: Equatable {
        var x0: Double
        var y0: Double
        var x1: Double
        var y1: Double

        var area: Double { max(0, x1 - x0) * max(0, y1 - y0) }
        var midX: Double { (x0 + x1) / 2 }
        var midY: Double { (y0 + y1) / 2 }

        func overlaps(_ other: Box) -> Bool {
            x0 < other.x1 && other.x0 < x1 && y0 < other.y1 && other.y0 < y1
        }

        func contains(x: Double, y: Double) -> Bool {
            x0 <= x && x < x1 && y0 <= y && y < y1
        }
    }

    /// Where a clip's picture sits on the frame at `time`: the media fitted
    /// to the frame, scaled and cropped, about its position (rotation is
    /// ignored). Solids and graphics are drawn at the frame's size; text and
    /// adjustment layers have no box.
    static func onScreen(_ clip: Clip, item: MediaItem?, at time: Time, in project: Project) -> Box? {
        let canvasWidth = Double(project.settings.width), canvasHeight = Double(project.settings.height)
        var sourceWidth = canvasWidth, sourceHeight = canvasHeight
        switch clip.content {
        case .text, .adjustment:
            return nil
        case .solid, .graphic:
            break
        case .media:
            guard let item, item.hasVideo || item.kind == .image else { return nil }
            sourceWidth = Double(item.width ?? project.settings.width)
            sourceHeight = Double(item.height ?? project.settings.height)
        }
        let video = clip.resolvedVideo(at: time - clip.start)
        guard video.opacity > 0, sourceWidth > 0, sourceHeight > 0, canvasWidth > 0, canvasHeight > 0 else { return nil }
        let scale = min(canvasWidth / sourceWidth, canvasHeight / sourceHeight) * video.transform.scale
        let centreX = video.transform.position.x * canvasWidth
        let centreY = video.transform.position.y * canvasHeight
        let box = Box(
            x0: max(0, (centreX + (video.crop.left - 0.5) * sourceWidth * scale) / canvasWidth),
            y0: max(0, (centreY + (video.crop.top - 0.5) * sourceHeight * scale) / canvasHeight),
            x1: min(1, (centreX + (0.5 - video.crop.right) * sourceWidth * scale) / canvasWidth),
            y1: min(1, (centreY + (0.5 - video.crop.bottom) * sourceHeight * scale) / canvasHeight)
        )
        return box.area > 0 ? box : nil
    }

    /// The parts of `range` that none of `covered` (merged, by start)
    /// reaches.
    static func uncovered(_ range: TimeRange, by covered: [TimeRange]) -> [TimeRange] {
        var found: [TimeRange] = []
        var cursor = range.start
        for piece in covered where piece.end > cursor && piece.start < range.end {
            if piece.start > cursor { found.append(TimeRange(start: cursor, end: piece.start)) }
            cursor = max(cursor, piece.end)
        }
        if cursor < range.end { found.append(TimeRange(start: cursor, end: range.end)) }
        return found
    }

    /// The frames (sorted by time) inside `range`.
    static func slice(_ frames: [FrameStats], within range: TimeRange) -> [FrameStats] {
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].time < range.start { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < frames.count && frames[end].time < range.end { end += 1 }
        return Array(frames[low..<end])
    }
}
