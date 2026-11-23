import Foundation

/// How `redact` hides a region: a mosaic, or a blur.
public enum RedactStyle: String, Codable, CaseIterable, Sendable {
    case pixelate, blur

    /// The effect parameter `size` sets: the block size or the radius.
    var parameter: String { self == .pixelate ? "scale" : "radius" }

    /// The effect's own default, from the registry.
    var defaultSize: Double {
        let definition = EffectRegistry.builtIn.first { $0.type == rawValue }
        if case .number(let value)? = definition?.params.first(where: { $0.key == parameter })?.defaultValue { return value }
        return 24
    }
}

extension Clip {
    /// A copy of a picture that hides it, or part of it, behind a pixelate
    /// or blur: a redaction over a QR code or an email, or the blurred fill
    /// behind a shot that doesn't cover the frame. It's the same file at
    /// the same moment as the clip it sits on, on purpose, so it isn't a
    /// second shot (`sameShotTwice`) or another angle (`showAngle`).
    public var isObscured: Bool {
        RedactionSafety.effect(on: self) != nil
    }
}

extension Track {
    /// Whether this is a track `redact` puts its copies on, "Privacy
    /// (Screen)" (`Editing.isPrivacyTrack`).
    public var isPrivacy: Bool { Editing.isPrivacyTrack(self) }

    /// Whether `clip`, on this track, is a `redact` copy hiding nothing:
    /// its blur or pixelate turned off or removed. Named "Privacy..." by
    /// `redact`, so a solid, a title or anything else put on a privacy
    /// track by hand is never taken for one.
    public func isSwitchedOffRedaction(_ clip: Clip) -> Bool {
        guard isPrivacy, case .media = clip.content, !clip.isObscured else { return false }
        return clip.video?.redaction != nil || clip.video?.redactionSources != nil || clip.video?.redactionEffectID != nil
    }
}

extension Editing {
    /// The tracks `redact` puts its copies on are named "Privacy (Screen)"
    /// after the track they hide part of; this is how they're recognised,
    /// hand-made ones included.
    static let privacyTrackPrefix = "privacy ("

    public static func isPrivacyTrack(_ track: Track) -> Bool {
        track.name.lowercased().hasPrefix(privacyTrackPrefix) || track.clips.contains { $0.video?.redaction != nil || $0.video?.redactionSources != nil }
    }

    /// `redact`: hides `rect` (fractions of the source frame, from the top
    /// left) of every clip of `mediaID` (or every clip on `trackID`) over
    /// `range`, behind a pixelate or blur. Each clip there gets a copy of
    /// itself on a track right above its own ("Privacy (Screen)"), with
    /// the source's ripple mode:
    /// the same file, start, length, source time, speed and placement
    /// (keyframes and format layouts too, so a phone shown as a PiP is
    /// hidden where it's shown), cropped to the region, with the effect on.
    /// The take is cut at the range's edges, like `showAngle`, so each copy
    /// is linked one clip a track with the piece it hides, and ripple cuts,
    /// trims, slips and moves keep it on it.
    ///
    /// The edges are where asked (to the frame): one less than a frame from
    /// a clip's edge goes to it, so no sliver of take is cut off, and a
    /// clip the range overlaps by less than a frame gets no copy. Past
    /// that, the take's cut where asked, and the through-edit plays
    /// straight on. The copies are new IDs in `createdIDs`.
    static func redact(
        _ p: inout Project, range requested: TimeRange, rect: Rect, trackID: String?, mediaID: String?,
        style: RedactStyle, size: Double?, name: String?, _ context: inout EditContext
    ) throws {
        guard trackID != nil || mediaID != nil else {
            throw EditError.invalid("redact needs the mediaID of the recording to hide part of, or the trackID it's on")
        }
        let slack = 1e-6
        guard rect.x >= -slack, rect.y >= -slack, rect.width > 0, rect.height > 0,
              rect.x + rect.width <= 1 + slack, rect.y + rect.height <= 1 + slack else {
            throw EditError.invalid("rect is fractions of the source frame from the top left: x and y from 0, width and height above 0, inside 1")
        }
        if let size, !(size > 0) { throw EditError.invalid("size must be above 0") }
        if let mediaID, p.media(mediaID) == nil { throw EditError.notFound("media \(mediaID)") }
        let rate = p.settings.frameRate
        let range = TimeRange(start: requested.start.roundedToFrame(rate), end: requested.end.roundedToFrame(rate))
        let frame = rate.frameDuration
        guard range.duration > .zero else { throw EditError.invalid("the range is shorter than a frame") }

        var sources: [TrackLocation]
        if let trackID {
            let location = try requireTrack(p, trackID)
            guard location.kind == .video else { throw EditError.invalid("\"\(p[location].name)\" is a sound track; redact hides part of a picture") }
            guard !p[location].isPrivacy else { throw EditError.invalid("Redact the source picture, not its privacy copy.") }
            sources = [location]
        } else {
            // Not the privacy tracks themselves: their copies are the
            // redactions, not something to redact.
            sources = p.videoTracks.indices.map { TrackLocation(kind: .video, index: $0) }.filter { !isPrivacyTrack(p[$0]) }
        }

        // What to hide, by ID, since the tracks move as privacy tracks are added.
        struct Target { var trackID: String; var clipID: String; var span: TimeRange }
        var targets: [Target] = []
        for location in sources {
            let track = p[location]
            for clip in track.clips where clip.range.overlaps(range) {
                guard let id = clip.mediaID, mediaID == nil || id == mediaID,
                      let item = p.media(id), item.hasVideo, var span = clip.range.intersection(range) else { continue }
                // Never past the time asked for, except to a clip edge
                // less than a frame away: that's rounding (a take tightened
                // off the frame grid), and cutting there would leave a
                // sliver of take. Snapping half a second out, as this once
                // did, blurred the next window in the launch video for
                // 0.35 s as it opened.
                if span.start - clip.start < frame { span = TimeRange(start: clip.start, end: span.end) }
                if clip.end - span.end < frame { span = TimeRange(start: span.start, end: clip.end) }
                // A copy under a frame long is a clip the range only grazes
                // through rounding: it would show, at most, one blurred
                // frame over the wrong picture.
                guard span.duration >= frame else {
                    context.warn("Left \(clip.name ?? clip.id) on \"\(track.name)\" alone: the range only takes \(String(format: "%.3f", span.duration.seconds)) s of it, under a frame. Widen the range if that clip shows what needs hiding.")
                    continue
                }
                // A format's own crop replaces the main one there, so the
                // region's only already hidden when every layout crops it out.
                let mainCrop = widestCrop(of: clip, override: nil)
                let formatCrops = (clip.video?.formatOverrides.values).map { $0.filter { !$0.hidden }.map { $0.crop ?? mainCrop } } ?? []
                guard ([mainCrop] + formatCrops).contains(where: { redactedCrop($0, rect) != nil }) else {
                    context.warn("Left \(clip.name ?? clip.id) on \"\(track.name)\" alone: its crop already hides that region.")
                    continue
                }
                targets.append(Target(trackID: track.id, clipID: clip.id, span: span))
            }
        }
        guard !targets.isEmpty else {
            let what = mediaID.flatMap { p.media($0) }.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "a picture"
            let place = trackID.flatMap { id in p.location(ofTrack: id).map { " on \"\(p[$0].name)\"" } } ?? ""
            throw EditError.invalid("there's no clip of \(what)\(place) between \(range.start) and \(range.end) to hide part of")
        }

        let amount = size ?? style.defaultSize
        var trackOrder: [String] = []
        for target in targets where !trackOrder.contains(target.trackID) { trackOrder.append(target.trackID) }
        for sourceID in trackOrder {
            guard let location = p.location(ofTrack: sourceID) else { throw EditError.notFound("track \(sourceID)") }
            try requireUnlocked(p[location])
            var copies: [Clip] = []
            for target in targets where target.trackID == sourceID {
                guard let at = p.location(ofTrack: sourceID) else { throw EditError.notFound("track \(sourceID)") }
                var piece = try SyncedPlacement.isolate(&p, clipID: target.clipID, to: target.span, on: at, &context)
                if piece.linkGroup == nil, let index = p[at].index(ofClip: piece.id) {
                    piece.linkGroup = context.makeID("lnk")
                    p[at].clips[index].linkGroup = piece.linkGroup
                }
                copies.append(redactedCopy(of: piece, rect: rect, style: style, size: amount, name: name, &context))
            }
            let destination = try privacyTrack(&p, above: sourceID, fitting: copies.map(\.range), &context)
            for copy in copies {
                try checkSource(copy, in: p)
                p[destination].add(copy)
                context.createdIDs.append(copy.id)
            }
        }
    }

    /// The piece, cropped down to `rect` and hidden: it keeps its file,
    /// times, link, placement and animation, loses what draws round its
    /// edges (border, shadow, rounded corners, cutout: on a cropped copy
    /// those would frame the redaction, or show the picture round it), and
    /// gets the pixelate or blur after its own looks.
    static func redactedCopy(of piece: Clip, rect: Rect, style: RedactStyle, size: Double, name: String?, _ context: inout EditContext) -> Clip {
        var copy = piece
        copy.id = context.makeID("clip")
        copy.name = name.map { "Privacy: \($0)" } ?? "Privacy"
        var video = piece.video ?? VideoProperties()
        // The least the picture's crop ever hides, its animation included:
        // the copy doesn't animate its crop, so it covers the region
        // wherever the picture might show it.
        let mainCrop = widestCrop(of: piece, override: nil)
        // Where a layout already crops the region out, the copy draws
        // nothing there (an empty crop), rather than hiding the whole shot.
        video.crop = redactedCrop(mainCrop, rect) ?? nothingShown
        video.redaction = rect
        video.cutout = nil
        let drawnRound = Set(["border", "dropShadow", "roundedCorners"])
        video.effects = video.effects.filter { !drawnRound.contains($0.type) }.map { effect in
            var effect = effect
            effect.id = context.makeID("fx")
            return effect
        } + [Effect(id: context.makeID("fx"), type: style.rawValue, params: [style.parameter: .number(size)])]
        video.redactionEffectID = video.effects.last?.id
        // A format's own crop replaces the main one there, so the region
        // has to be cut from it too, or the short would show the copy uncropped.
        video.formatOverrides = video.formatOverrides.mapValues { override in
            var override = override
            if let crop = redactedCrop(override.crop ?? mainCrop, rect) { override.crop = crop } else { override.hidden = true }
            override.cutout = nil
            return override
        }
        // Solid whatever the picture's opacity: a see-through patch over a
        // see-through picture lets the sharp one show through it. At 50% each
        // that's a quarter of the private text, readable.
        if video.opacity < 1 || piece.keyframes["video.opacity"] != nil {
            context.warn("Kept the patch over \(piece.name ?? piece.id) solid: it fades or shows through, and a see-through patch would let the picture under it show.")
        }
        video.opacity = 1
        copy.video = video
        // The effects have new IDs, so their animation goes, and so does any
        // crop animation (the still crop covers all of it, above).
        copy.keyframes = piece.keyframes.filter {
            !$0.key.hasPrefix("video.crop") && !$0.key.hasPrefix("video.effects") && $0.key != "video.opacity"
        }
        return copy
    }

    /// A crop that leaves nothing, so the layer isn't drawn.
    static let nothingShown = Crop(left: 0.5, top: 0.5, right: 0.5, bottom: 0.5)

    /// `crop` narrowed to `rect`, or nil when the crop already hides all of it.
    static func redactedCrop(_ crop: Crop, _ rect: Rect) -> Crop? {
        let narrowed = Crop(
            left: max(crop.left, rect.x),
            top: max(crop.top, rect.y),
            right: max(crop.right, 1 - rect.x - rect.width),
            bottom: max(crop.bottom, 1 - rect.y - rect.height)
        )
        guard narrowed.left + narrowed.right < 1, narrowed.top + narrowed.bottom < 1 else { return nil }
        return narrowed
    }

    /// The region a `redact` copy hides, or nil when `clip` isn't one.
    /// Copies made before `redaction` was kept have only their crops: each
    /// is the region narrowed by what the picture's crop hid there, so the
    /// least cropped is the closest to it, and never outside it. A whole
    /// frame crop is a layout that once lost the region (the short did
    /// that), not the region, so it's left out unless it's all there is.
    static func redactionRegion(of clip: Clip, on track: Track, inferLegacy: Bool = false) -> Rect? {
        guard track.isPrivacy, case .media = clip.content, let video = clip.video,
              video.redaction != nil || video.redactionSources != nil || (inferLegacy && clip.name?.hasPrefix("Privacy") == true),
              clip.isObscured || track.isSwitchedOffRedaction(clip) else { return nil }
        if let region = video.redaction { return region }
        let crops = ([video.crop] + video.formatOverrides.values.filter { !$0.hidden }.compactMap(\.crop))
            .filter { $0.left + $0.right < 1 && $0.top + $0.bottom < 1 }
        let narrowed = crops.filter { $0 != Crop() }
        guard let first = narrowed.first ?? crops.first else { return nil }
        let crop = narrowed.dropFirst().reduce(first) { a, b in
            Crop(left: min(a.left, b.left), top: min(a.top, b.top), right: min(a.right, b.right), bottom: min(a.bottom, b.bottom))
        }
        return Rect(x: crop.left, y: crop.top, width: 1 - crop.left - crop.right, height: 1 - crop.top - crop.bottom)
    }

    /// The track holding the picture a `redact` copy hides: the one with
    /// the clip it's linked to (of its file, at its time), the one under
    /// its run of privacy tracks first when the file's on more than one.
    /// Without a linked clip (it was cut away under a locked copy), the
    /// track under the run, if it shows the file there.
    static func redactedPictureTrack(of copy: Clip, on location: TrackLocation, in p: Project) -> TrackLocation? {
        func shows(_ clip: Clip) -> Bool {
            clip.mediaID == copy.mediaID && clip.range.overlaps(copy.range)
        }
        var below = location.index - 1
        while below >= 0, isPrivacyTrack(p.videoTracks[below]) { below -= 1 }
        let candidates = (below >= 0 ? [below] : []) + p.videoTracks.indices.filter { $0 != below }
        if let group = copy.linkGroup, let index = candidates.first(where: { index in
            !isPrivacyTrack(p.videoTracks[index]) && p.videoTracks[index].clips.contains { $0.linkGroup == group && shows($0) }
        }) {
            return TrackLocation(kind: .video, index: index)
        }
        if below >= 0, p.videoTracks[below].clips.contains(where: shows) { return TrackLocation(kind: .video, index: below) }
        return nil
    }

    /// The least `picture`'s crop hides on each side: `override`'s crop in
    /// a format that sets one (animation doesn't apply there), otherwise
    /// its still crop or any keyframe, whichever shows more.
    static func widestCrop(of picture: Clip, override: FormatOverride?) -> Crop {
        if let crop = override?.crop { return crop }
        let still = picture.video?.crop ?? Crop()
        func least(_ key: String, _ value: Double) -> Double {
            (picture.keyframes["video.crop.\(key)"] ?? []).compactMap(\.value.number).reduce(value, min)
        }
        return Crop(left: least("left", still.left), top: least("top", still.top), right: least("right", still.right), bottom: least("bottom", still.bottom))
    }

    /// Puts `redact` copies back over the pictures they hide, in `format`
    /// (nil for the main layout): the same place and size, cut to their
    /// region within what the picture shows there. Layouts (`applyLayout`,
    /// `setFormatLayout`, `tandem short`) move and uncrop the picture; a
    /// copy laid out like a plain clip would blur the whole picture, and
    /// one left behind would leave the region showing beside it.
    ///
    /// `follows` picks which (copy, picture) pairs to line up. A copy that
    /// can't follow (on a locked track when `respectLocks`, or over two
    /// pictures now laid out differently) stops the edit rather than
    /// leaving private content in view.
    static func alignRedactions(
        _ p: inout Project, format: String?, respectLocks: Bool = true,
        where follows: (_ copy: Clip, _ picture: Clip) -> Bool
    ) throws {
        for trackIndex in p.videoTracks.indices where isPrivacyTrack(p.videoTracks[trackIndex]) {
            let location = TrackLocation(kind: .video, index: trackIndex)
            for index in p[location].clips.indices {
                let copy = p[location].clips[index]
                guard let region = redactionRegion(of: copy, on: p[location]) else { continue }
                guard let at = redactedPictureTrack(of: copy, on: location, in: p) else { continue }
                let pictures = p[at].clips.filter { $0.mediaID == copy.mediaID && $0.range.overlaps(copy.range) }
                guard pictures.contains(where: { follows(copy, $0) }) else { continue }
                let placements = pictures.map { aligned(copy, over: $0, region: region, format: format) }
                guard let placed = placements.first, placements.contains(where: { $0 != copy }) else { continue }
                let name = copy.name ?? copy.id
                guard placements.allSatisfy({ $0 == placed }) else {
                    throw EditError.invalid("The blur \(name) on \"\(p[location].name)\" covers \(pictures.count) clips that are now laid out differently, so it can't follow them all. Blade it where they meet (unlock its track first if it's locked), then lay them out again.")
                }
                if respectLocks, p[location].locked {
                    throw EditError.invalid("\"\(p[location].name)\" is locked, and its blur \(name) has to move with the picture it hides, or that part would show. Unlock the track first.")
                }
                p[location].clips[index] = placed
            }
        }
    }

    /// `copy` placed like `picture` in `format` (nil: the main layout).
    static func aligned(_ copy: Clip, over picture: Clip, region: Rect, format: String?) -> Clip {
        var copy = copy
        var video = copy.video ?? VideoProperties()
        let source = picture.video ?? VideoProperties()
        video.redaction = region
        if let format {
            // A format's crop replaces the animated one there.
            if var override = source.formatOverrides[format] {
                if !override.hidden {
                    if let crop = redactedCrop(widestCrop(of: picture, override: override), region) { override.crop = crop } else { override.hidden = true }
                }
                override.cutout = nil
                video.formatOverrides[format] = override
            } else {
                // The picture shows there as in the main layout, so the copy does too.
                video.formatOverrides.removeValue(forKey: format)
            }
            copy.video = video
        } else {
            video.transform = source.transform
            video.layoutPreset = source.layoutPreset
            video.crop = redactedCrop(widestCrop(of: picture, override: nil), region) ?? nothingShown
            for key in ["video.transform.position", "video.transform.scale", "video.transform.rotation"] {
                copy.keyframes[key] = picture.keyframes[key]
            }
            for key in ["video.crop.left", "video.crop.top", "video.crop.right", "video.crop.bottom"] {
                copy.keyframes.removeValue(forKey: key)
            }
            copy.video = video
            // A format that only moves the picture shows its main crop, so
            // a new main crop changes what the copy has to cover there too.
            for format in Set(source.formatOverrides.keys).union(video.formatOverrides.keys).sorted() {
                copy = aligned(copy, over: picture, region: region, format: format)
            }
        }
        return copy
    }

    /// Where the copies of `sourceID`'s clips go: the first privacy track in
    /// the run of them right above it with room for every copy, or a new
    /// `cut` track at the top of that run, "Privacy (Screen)" (numbered when
    /// that's taken), so nothing else sits between a redaction and the
    /// picture it hides, and a PiP above still covers both.
    static func privacyTrack(_ p: inout Project, above sourceID: String, fitting ranges: [TimeRange], _ context: inout EditContext) throws -> TrackLocation {
        guard let source = p.location(ofTrack: sourceID) else { throw EditError.notFound("track \(sourceID)") }
        var index = source.index + 1
        while index < p.videoTracks.count, isPrivacyTrack(p.videoTracks[index]) {
            let track = p.videoTracks[index]
            if !track.locked, ranges.allSatisfy({ track.isFree($0) }) { return TrackLocation(kind: .video, index: index) }
            index += 1
        }
        let stem = "Privacy (\(p[source].name))"
        let names = Set(p.allTracks.map { $0.name.lowercased() })
        let name = names.contains(stem.lowercased())
            ? (2...).lazy.map { "\(stem) \($0)" }.first { !names.contains($0.lowercased()) }!
            : stem
        try addTrack(&p, kind: .video, name: name, index: index, id: nil, &context)
        p.videoTracks[index].rippleMode = p[source].rippleMode
        return TrackLocation(kind: .video, index: index)
    }
}
