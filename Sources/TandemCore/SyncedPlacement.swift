import Foundation

/// Files synced to a camera take by sound (another camera angle, an
/// external mic), put alongside the take's clips (`placeSynced`), and which
/// angle shows where (`showAngle`).
///
/// Everything stays one clip a track per link group: placing cuts the take
/// where the file starts and stops, and switching angles cuts it at the
/// range's edges. Those cuts are through-edits, so nothing plays any
/// differently, but trims, moves and later cuts then treat the camera, its
/// angles and the mic as one, the way they treat a take's camera and screen.
enum SyncedPlacement {
    static let cameraSoundTrack = "Camera sound"
    static let minimumPiece = Time(seconds: 0.5)

    // MARK: - placeSynced

    static func place(_ p: inout Project, mediaID: String, trackID: String?, _ context: inout EditContext) throws {
        guard let item = p.media(mediaID) else { throw EditError.notFound("media \(mediaID)") }
        guard let take = item.takeID else {
            throw EditError.invalid("\(item.path) isn't synced to a take yet; tandem sync \"\(item.path)\" lines it up with the camera by sound")
        }
        guard item.kind != .image, item.hasVideo || item.hasAudio, let length = item.duration, length > .zero else {
            throw EditError.invalid("\(item.path) has no picture or sound to place")
        }
        if p.allTracks.contains(where: { $0.clips.contains { $0.mediaID == mediaID } }) {
            throw EditError.invalid("\(item.path) is already on the timeline; remove its clips to place it again")
        }
        let (referenceLocation, references) = try referenceClips(p, take: take, excluding: mediaID)
        let referenceTrack = p[referenceLocation]
        try Editing.requireUnlocked(referenceTrack)
        let rate = p.settings.frameRate
        let itemOffset = item.takeOffset ?? .zero

        // Where the file plays against each camera clip: file time is
        // timeline time plus `delta`. Edges inside a clip go to whole frames
        // inside the file, so no frame shows before it starts.
        var spans: [(clipID: String, range: TimeRange, delta: Time)] = []
        for clip in references {
            guard clip.speed == 1, !clip.freezeFrame, let reference = clip.mediaID.flatMap(p.media) else {
                context.warn("Left \(clip.name ?? clip.id) alone: \(item.path) only lines up with clips playing at normal speed.")
                continue
            }
            let delta = clip.sourceStart - clip.start + (reference.takeOffset ?? .zero) - itemOffset
            var start = max(clip.start, Time.zero - delta)
            var end = min(clip.end, length - delta)
            if start > clip.start { start = ceilingFrame(start, rate) }
            if end < clip.end { end = floorFrame(end, rate) }
            // A sliver of a clip the file only just reaches into isn't worth
            // a cut: an angle a frame longer than its mic, say, placed after it.
            let partial = start > clip.start || end < clip.end
            guard end - start >= rate.frameDuration, !partial || end - start >= minimumPiece else { continue }
            spans.append((clip.id, TimeRange(start: start, end: end), delta))
        }
        guard !spans.isEmpty else {
            throw EditError.invalid("\(item.path) doesn't overlap any of the take's clips on \"\(referenceTrack.name)\"")
        }

        var target: TrackLocation?
        var cameraSound: TrackLocation?
        let name = URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
        for span in spans {
            let piece = try isolate(&p, clipID: span.clipID, to: span.range, on: referenceLocation, &context)
            let group: String
            if let existing = piece.linkGroup {
                group = existing
            } else {
                group = context.makeID("lnk")
                if let index = p[referenceLocation].index(ofClip: piece.id) { p[referenceLocation].clips[index].linkGroup = group }
            }
            var clip = Clip(
                id: context.makeID("clip"), name: name, content: .media(mediaID: item.id),
                start: piece.start, duration: piece.duration, sourceStart: piece.start + span.delta, linkGroup: group
            )
            let location: TrackLocation
            if item.hasVideo {
                location = try target ?? angleTrack(&p, trackID: trackID, above: referenceLocation, &context)
                // Off until an angle is picked, framed like the camera.
                clip.enabled = false
                if let video = piece.video {
                    clip.video = VideoProperties(
                        transform: video.transform, opacity: video.opacity, layoutPreset: video.layoutPreset,
                        formatOverrides: video.formatOverrides.mapValues { FormatOverride(transform: $0.transform, hidden: $0.hidden) }
                    )
                }
            } else {
                location = try target ?? soundTrack(p, trackID: trackID)
                try Editing.requireUnlocked(p[location])
                try moveTakeSound(&p, from: location, in: piece.range, group: group, into: &cameraSound, &context)
                clip.audio = AudioLevels.placedAudio(role: item.role, on: p[location], settings: p.settings)
            }
            target = location
            try Editing.checkSource(clip, in: p)
            guard p[location].isFree(clip.range) else {
                throw EditError.overlap("\"\(p[location].name)\" already has a clip between \(clip.start) and \(clip.end)")
            }
            p[location].add(clip)
            context.createdIDs.append(clip.id)
        }
    }

    /// The take's clips to line a file up with: the camera's picture,
    /// failing that any picture from the take, failing that its sound. All
    /// from the lowest track that has some.
    static func referenceClips(_ p: Project, take: String, excluding mediaID: String) throws -> (TrackLocation, [Clip]) {
        let partners = Dictionary(p.media.filter { $0.takeID == take && $0.id != mediaID }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func find(_ kind: TrackKind, _ accept: (MediaItem) -> Bool) -> (TrackLocation, [Clip])? {
            for location in p.trackLocations where location.kind == kind {
                let found = p[location].clips.filter { clip in clip.mediaID.flatMap { partners[$0] }.map(accept) ?? false }
                if !found.isEmpty { return (location, found) }
            }
            return nil
        }
        guard let found = find(.video, { $0.role == .camera }) ?? find(.video, { _ in true }) ?? find(.audio, { _ in true }) else {
            throw EditError.invalid("nothing from its take is on the timeline to line it up with; place the camera take first")
        }
        return found
    }

    /// Cuts the take (every clip linked to `clipID`) at the edges of
    /// `range`, and returns the piece of `clipID`'s track inside it.
    static func isolate(_ p: inout Project, clipID: String, to range: TimeRange, on location: TrackLocation, _ context: inout EditContext) throws -> Clip {
        guard let clip = p.clip(clipID) else { throw EditError.notFound("clip \(clipID)") }
        if range.end < clip.end { try Editing.blade(&p, at: range.end, trackIDs: nil, clipIDs: [clipID], &context) }
        if range.start > clip.start { try Editing.blade(&p, at: range.start, trackIDs: nil, clipIDs: [clipID], &context) }
        guard let piece = p[location].clip(at: range.start), piece.range == range else {
            throw EditError.invalid("couldn't cut \"\(p[location].name)\" at \(range.start) and \(range.end)")
        }
        return piece
    }

    /// The video track an angle goes on: `trackID`, or a new `cut` track
    /// right above the camera's, "Angle 2" (or the next number free).
    static func angleTrack(_ p: inout Project, trackID: String?, above reference: TrackLocation, _ context: inout EditContext) throws -> TrackLocation {
        if let trackID {
            let location = try Editing.requireTrack(p, trackID)
            guard location.kind == .video else { throw EditError.invalid("\"\(p[location].name)\" is a sound track; a picture needs a video track") }
            try Editing.requireUnlocked(p[location])
            return location
        }
        let names = Set(p.videoTracks.map { $0.name.lowercased() })
        let number = (2...).first { !names.contains("angle \($0)") }!
        let index = reference.kind == .video ? reference.index + 1 : p.videoTracks.count
        try Editing.addTrack(&p, kind: .video, name: "Angle \(number)", index: index, id: nil, &context)
        p.videoTracks[index].rippleMode = .cut
        return TrackLocation(kind: .video, index: index)
    }

    /// Where a sound file goes: `trackID`, Voice, or the first `cut` sound track.
    static func soundTrack(_ p: Project, trackID: String?) throws -> TrackLocation {
        if let trackID {
            let location = try Editing.requireTrack(p, trackID)
            guard location.kind == .audio else { throw EditError.invalid("\"\(p[location].name)\" is a video track; sound needs a sound track") }
            return location
        }
        if let voice = p.track(named: "Voice", kind: .audio), let location = p.location(ofTrack: voice.id) { return location }
        guard let index = p.audioTracks.firstIndex(where: { $0.rippleMode == .cut }) else {
            throw EditError.invalid("there's no Voice track for the sound; name one with trackID")
        }
        return TrackLocation(kind: .audio, index: index)
    }

    /// Moves the take's own sound in `range` on `location` to the muted
    /// "Camera sound" track (made the first time, right under it), so the
    /// file placed there instead is what plays. Anything else there is in
    /// the way.
    static func moveTakeSound(_ p: inout Project, from location: TrackLocation, in range: TimeRange, group: String, into cameraSound: inout TrackLocation?, _ context: inout EditContext) throws {
        let inside = p[location].clips.filter { $0.range.clashes(with: range) }
        guard !inside.isEmpty else { return }
        for clip in inside where clip.linkGroup != group {
            throw EditError.overlap("\"\(p[location].name)\" already has \(clip.name ?? clip.id) between \(clip.start) and \(clip.end), which isn't the take's own sound")
        }
        var track = p[location]
        for edge in [range.start, range.end] where track.clips.contains(where: { $0.start < edge && edge < $0.end }) {
            track.split(at: edge, context: &context)
        }
        let moving = track.clips.filter { range.start <= $0.start && $0.end <= range.end }
        track.clips.removeAll { clip in moving.contains { $0.id == clip.id } }
        track.removeTransitions(referencing: Set(moving.map(\.id)))
        p[location] = track

        let destination: TrackLocation
        if let cameraSound {
            destination = cameraSound
        } else if let existing = p.track(named: cameraSoundTrack, kind: .audio), let found = p.location(ofTrack: existing.id) {
            destination = found
        } else {
            try Editing.addTrack(&p, kind: .audio, name: cameraSoundTrack, index: location.index + 1, id: nil, &context)
            destination = TrackLocation(kind: .audio, index: location.index + 1)
            p[destination].muted = true
            p[destination].rippleMode = .cut
        }
        cameraSound = destination
        try Editing.requireUnlocked(p[destination])
        for var clip in moving {
            clip.linkGroup = group
            guard p[destination].isFree(clip.range) else {
                throw EditError.overlap("\"\(p[destination].name)\" already has a clip between \(clip.start) and \(clip.end)")
            }
            p[destination].add(clip)
        }
    }

    /// Turns each redaction in `range` on or off with the picture it hides,
    /// its linked clip of the same file: one over an angle that's off would
    /// otherwise show a patch of it over the camera.
    static func followHiddenPictures(_ p: inout Project, in range: TimeRange) {
        var shown: [String: Bool] = [:]
        for clip in p.videoTracks.flatMap(\.clips) where !clip.isObscured {
            guard let group = clip.linkGroup, let media = clip.mediaID else { continue }
            shown["\(group) \(media)", default: false] = shown["\(group) \(media)", default: false] || clip.enabled
        }
        for t in p.videoTracks.indices {
            for i in p.videoTracks[t].clips.indices {
                let clip = p.videoTracks[t].clips[i]
                guard clip.isObscured, range.start <= clip.start, clip.end <= range.end,
                      let group = clip.linkGroup, let media = clip.mediaID, let on = shown["\(group) \(media)"] else { continue }
                p.videoTracks[t].clips[i].enabled = on
            }
        }
    }

    static func ceilingFrame(_ time: Time, _ rate: FrameRate) -> Time {
        let perFrame = rate.flicksPerFrame
        return Time(flicks: Int64((Double(time.flicks) / Double(perFrame)).rounded(.up)) * perFrame)
    }

    static func floorFrame(_ time: Time, _ rate: FrameRate) -> Time {
        let perFrame = rate.flicksPerFrame
        return Time(flicks: Int64((Double(time.flicks) / Double(perFrame)).rounded(.down)) * perFrame)
    }

    // MARK: - showAngle

    static func showAngle(_ p: inout Project, range: TimeRange, trackID: String, _ context: inout EditContext) throws {
        let location = try Editing.requireTrack(p, trackID)
        let shown = p[location]
        guard location.kind == .video else { throw EditError.invalid("\"\(shown.name)\" is a sound track; showAngle picks the picture") }
        let rate = p.settings.frameRate
        let range = TimeRange(start: range.start.roundedToFrame(rate), end: range.end.roundedToFrame(rate))
        guard range.duration > .zero else { throw EditError.invalid("the range is shorter than a frame") }

        let takes = Set(shown.clips(intersecting: range).compactMap { $0.mediaID.flatMap(p.media)?.takeID })
        guard takes.count == 1, let take = takes.first else {
            throw EditError.invalid(takes.isEmpty
                ? "\"\(shown.name)\" has nothing from a synced take between \(range.start) and \(range.end)"
                : "\"\(shown.name)\" has clips from more than one take between \(range.start) and \(range.end)")
        }
        // A redaction (`redact`) is the take too, but it's a patch over the
        // picture below it, not an angle; it follows that picture instead.
        func inTake(_ clip: Clip) -> Bool { !clip.isObscured && clip.mediaID.flatMap(p.media)?.takeID == take }
        func isCamera(_ clip: Clip) -> Bool { clip.mediaID.flatMap(p.media)?.role == .camera }
        // The camera's track is the lowest with the take's camera on it
        // there; its angles are the take's tracks above it.
        let takeTracks = p.videoTracks.indices.filter { p.videoTracks[$0].clips(intersecting: range).contains(where: inTake) }
        let base = takeTracks.first { p.videoTracks[$0].clips(intersecting: range).contains { inTake($0) && isCamera($0) } } ?? takeTracks[0]
        let angles = takeTracks.filter { $0 > base }
        guard location.index == base || angles.contains(location.index) else {
            throw EditError.invalid("\"\(shown.name)\" is under the take's camera track; angles go above it")
        }
        guard !angles.isEmpty else {
            throw EditError.invalid("the take has no other angle between \(range.start) and \(range.end); tandem sync <file> adds one")
        }
        for index in angles { try Editing.requireUnlocked(p.videoTracks[index]) }

        // Cut the take at the edges, so each piece stays linked one clip a
        // track and only the angles change.
        for edge in [range.start, range.end] {
            for index in [base] + angles {
                if let clip = p.videoTracks[index].clips.first(where: { $0.start < edge && edge < $0.end && inTake($0) }) {
                    try Editing.blade(&p, at: edge, trackIDs: nil, clipIDs: [clip.id], &context)
                }
            }
        }
        var covered = Time.zero
        for index in angles {
            for i in p.videoTracks[index].clips.indices {
                let clip = p.videoTracks[index].clips[i]
                guard inTake(clip), range.start <= clip.start, clip.end <= range.end else { continue }
                let on = index == location.index
                p.videoTracks[index].clips[i].enabled = on
                if on { covered += clip.duration }
            }
        }
        followHiddenPictures(&p, in: range)
        if location.index != base, covered < range.duration {
            context.warn("\"\(shown.name)\" only covers \(String(format: "%.1f", covered.seconds)) s of that; the camera shows the rest.")
        }
    }
}
