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
        // `slivers` are what's left of a clip either side of the file when
        // that's under `minimumPiece`: files of one take end a few frames
        // apart. For a sound file their camera sound is muted too (below).
        var spans: [(clipID: String, range: TimeRange, delta: Time)] = []
        var slivers: [TimeRange] = []
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
            if start > clip.start, start - clip.start < minimumPiece { slivers.append(TimeRange(start: clip.start, end: start)) }
            if end < clip.end, clip.end - end < minimumPiece { slivers.append(TimeRange(start: end, end: clip.end)) }
        }
        guard !spans.isEmpty else {
            throw EditError.invalid("\(item.path) doesn't overlap any of the take's clips on \"\(referenceTrack.name)\"")
        }

        // Tracks by ID: making Voice 2 or Camera sound moves the ones under it.
        var targetID: String?
        var cameraSound: String?
        // Where the take's own sound plays, for a sound file: Voice, or the
        // track asked for. It stays put, as new tracks go under it.
        let home = item.hasVideo ? nil : try soundTrack(p, trackID: trackID)
        if let home {
            // Decided before any camera sound moves, against every span.
            targetID = p[try voiceTrack(&p, home: home, named: trackID != nil, for: spans.map(\.range), &context)].id
        }
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
                location = try targetID.flatMap { p.location(ofTrack: $0) } ?? angleTrack(&p, trackID: trackID, above: referenceLocation, &context)
                // Off until an angle is picked, framed like the camera.
                clip.enabled = false
                if let video = piece.video {
                    clip.video = VideoProperties(
                        transform: video.transform, opacity: video.opacity, layoutPreset: video.layoutPreset,
                        formatOverrides: video.formatOverrides.mapValues { FormatOverride(transform: $0.transform, hidden: $0.hidden) }
                    )
                }
            } else {
                guard let home else { throw EditError.invalid("\(item.path) has no sound track to go on") }
                try Editing.requireUnlocked(p[home])
                try moveTakeSound(&p, from: home, in: piece.range, group: group, into: &cameraSound, &context)
                guard let found = targetID.flatMap({ p.location(ofTrack: $0) }) else { throw EditError.invalid("lost the track for \(item.path)") }
                location = found
                try Editing.requireUnlocked(p[location])
                clip.audio = AudioLevels.placedAudio(role: item.role, on: p[location], settings: p.settings)
            }
            targetID = p[location].id
            try Editing.checkSource(clip, in: p)
            guard p[location].isFree(clip.range) else {
                throw EditError.overlap("\"\(p[location].name)\" already has a clip between \(clip.start) and \(clip.end)")
            }
            p[location].add(clip)
            context.createdIDs.append(clip.id)
        }

        // A fade out on the take's end (or in on its start) went to the
        // sliver with the cut, and plays in its 67 ms instead of over its
        // second. Where nothing follows the sliver (precedes, for a fade
        // in), it goes, and the fade goes back on the piece the file covers.
        for sliver in slivers {
            let track = p[referenceLocation]
            guard let piece = track.clips.first(where: { $0.range == sliver }) else { continue }
            let main = track.clips.first { $0.end == sliver.start } ?? track.clips.first { $0.start == sliver.end }
            guard let main else { continue }
            let atEnd = main.end == sliver.start
            let fades = track.transitions.indices.filter { i in
                let t = track.transitions[i]
                return atEnd ? t.fromClipID == piece.id && t.toClipID == nil : t.toClipID == piece.id && t.fromClipID == nil
            }
            let beyond = atEnd ? track.clips.contains { $0.start == sliver.end } : track.clips.contains { $0.end == sliver.start }
            guard !fades.isEmpty, !beyond else { continue }
            for i in fades {
                if atEnd { p[referenceLocation].transitions[i].fromClipID = main.id } else { p[referenceLocation].transitions[i].toClipID = main.id }
            }
            try Editing.removeClips(&p, [piece.id], ripple: false, includeLinked: true, &context)
            let kinds = fades.map { track.transitions[$0].type.rawValue }.joined(separator: " and ")
            context.warn("Took the \(atEnd ? "last" : "first") \(Int((sliver.duration.seconds * 1000).rounded())) ms of the take off \"\(track.name)\", where \(item.path) \(atEnd ? "has stopped" : "hasn't started"), so its \(kinds) plays in full rather than in that sliver.")
        }

        // A sliver of the take the file doesn't reach (it ended a couple of
        // frames before the camera) would play a blip of the camera's own
        // sound after the mic. Databased S2E7 had 17-67 ms of them at the
        // end of each take, and removing them took the camera's fade to
        // black with them. So their sound is muted with the rest of the
        // camera's; the picture carries on, through-edited, fade and all.
        guard let home else { return }
        for sliver in slivers {
            let own = p[home].clips.filter { $0.range == sliver && isTakeOwnSound($0, in: p) }
            guard let group = own.first?.linkGroup else { continue }
            try moveTakeSound(&p, from: home, in: sliver, group: group, into: &cameraSound, &context)
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

    /// The track a sound file goes on: `home` (Voice, or the track asked
    /// for), unless another of the take's sound files is already there
    /// where this one plays, as a second guest's mic finds the first's. Then
    /// the next "Voice 2" (or 3...), made right under Voice, so each mic
    /// keeps a track of its own. A track asked for is used as it is.
    static func voiceTrack(_ p: inout Project, home: TrackLocation, named: Bool, for ranges: [TimeRange], _ context: inout EditContext) throws -> TrackLocation {
        if named { return home }
        let taken = p[home].clips.contains { clip in
            ranges.contains { clip.range.clashes(with: $0) } && !isTakeOwnSound(clip, in: p)
        }
        guard taken else { return home }
        let names = Set(p.audioTracks.map { $0.name.lowercased() })
        let number = (2...).first { !names.contains("voice \($0)") }!
        let index = home.index + 1
        try Editing.addTrack(&p, kind: .audio, name: "Voice \(number)", index: index, id: nil, &context)
        p.audioTracks[index].rippleMode = .cut
        return TrackLocation(kind: .audio, index: index)
    }

    /// A clip of a picture file's sound (the camera's, an angle's), as
    /// opposed to a sound file synced to the take (a mic).
    static func isTakeOwnSound(_ clip: Clip, in p: Project) -> Bool {
        clip.mediaID.flatMap(p.media)?.hasVideo ?? false
    }

    /// Moves the take's own sound in `range` on `location` to the muted
    /// "Camera sound" track (made the first time, right under it), so the
    /// file placed there instead is what plays. Anything else there is in
    /// the way.
    static func moveTakeSound(_ p: inout Project, from location: TrackLocation, in range: TimeRange, group: String, into cameraSound: inout String?, _ context: inout EditContext) throws {
        let inside = p[location].clips.filter { $0.range.clashes(with: range) }
        guard !inside.isEmpty else { return }
        for clip in inside where clip.linkGroup != group {
            throw EditError.overlap("\"\(p[location].name)\" already has \(clip.name ?? clip.id) between \(clip.start) and \(clip.end), which isn't the take's own sound")
        }
        // Another mic of the take placed before stays where it is; only the
        // camera's own sound moves.
        guard inside.contains(where: { isTakeOwnSound($0, in: p) }) else { return }
        var track = p[location]
        for edge in [range.start, range.end] where track.clips.contains(where: { $0.start < edge && edge < $0.end }) {
            track.split(at: edge, context: &context)
        }
        let moving = track.clips.filter { range.start <= $0.start && $0.end <= range.end && isTakeOwnSound($0, in: p) }
        track.clips.removeAll { clip in moving.contains { $0.id == clip.id } }
        track.removeTransitions(referencing: Set(moving.map(\.id)))
        p[location] = track

        let destination: TrackLocation
        if let found = cameraSound.flatMap({ p.location(ofTrack: $0) }) {
            destination = found
        } else if let existing = p.track(named: cameraSoundTrack, kind: .audio), let found = p.location(ofTrack: existing.id) {
            destination = found
        } else {
            try Editing.addTrack(&p, kind: .audio, name: cameraSoundTrack, index: location.index + 1, id: nil, &context)
            destination = TrackLocation(kind: .audio, index: location.index + 1)
            p[destination].muted = true
            p[destination].rippleMode = .cut
        }
        cameraSound = p[destination].id
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
        let pictures = p.videoTracks.flatMap(\.clips).filter { !$0.isObscured && $0.linkGroup != nil && $0.range.overlaps(range) }
        for t in p.videoTracks.indices {
            for i in p.videoTracks[t].clips.indices {
                let clip = p.videoTracks[t].clips[i]
                guard clip.isObscured, range.start <= clip.start, clip.end <= range.end, let group = clip.linkGroup else { continue }
                // The picture it hides is the same file, linked, at the same time.
                let under = pictures.filter { $0.linkGroup == group && $0.mediaID == clip.mediaID && $0.range.overlaps(clip.range) }
                guard !under.isEmpty else { continue }
                p.videoTracks[t].clips[i].enabled = under.contains(where: \.enabled)
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
