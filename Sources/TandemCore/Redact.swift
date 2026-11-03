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
        video?.effects.contains { $0.enabled && RedactStyle(rawValue: $0.type) != nil } == true
    }
}

extension Editing {
    /// The tracks `redact` puts its copies on are named "Privacy (Screen)"
    /// after the track they hide part of; this is how they're recognised,
    /// hand-made ones included.
    static let privacyTrackPrefix = "privacy ("

    static func isPrivacyTrack(_ track: Track) -> Bool {
        track.name.lowercased().hasPrefix(privacyTrackPrefix)
    }

    /// `redact`: hides `rect` (fractions of the source frame, from the top
    /// left) of every clip of `mediaID` (or every clip on `trackID`) over
    /// `range`, behind a pixelate or blur. Each clip there gets a copy of
    /// itself on a `cut` track right above its own ("Privacy (Screen)"):
    /// the same file, start, length, source time, speed and placement
    /// (keyframes and format layouts too, so a phone shown as a PiP is
    /// hidden where it's shown), cropped to the region, with the effect on.
    /// The take is cut at the range's edges, like `showAngle`, so each copy
    /// is linked one clip a track with the piece it hides, and ripple cuts,
    /// trims, slips and moves keep it on it.
    ///
    /// An edge less than half a second inside a clip goes out to the clip's
    /// edge, so hiding a little more is preferred to leaving a sliver of a
    /// cut. The copies are new IDs in `createdIDs`.
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
        guard range.duration > .zero else { throw EditError.invalid("the range is shorter than a frame") }

        var sources: [TrackLocation]
        if let trackID {
            let location = try requireTrack(p, trackID)
            guard location.kind == .video else { throw EditError.invalid("\"\(p[location].name)\" is a sound track; redact hides part of a picture") }
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
            for clip in track.clips where clip.range.overlaps(range) && !clip.isObscured {
                guard let id = clip.mediaID, mediaID == nil || id == mediaID,
                      let item = p.media(id), item.hasVideo, var span = clip.range.intersection(range) else { continue }
                if span.start - clip.start < SyncedPlacement.minimumPiece { span = TimeRange(start: clip.start, end: span.end) }
                if clip.end - span.end < SyncedPlacement.minimumPiece { span = TimeRange(start: span.start, end: clip.end) }
                // A format's own crop replaces the main one there, so the
                // region's only already hidden when every layout crops it out.
                let mainCrop = clip.video?.crop ?? Crop()
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
        let mainCrop = video.crop
        // Where a layout already crops the region out, the copy draws
        // nothing there (an empty crop), rather than hiding the whole shot.
        video.crop = redactedCrop(mainCrop, rect) ?? nothingShown
        video.cutout = nil
        let drawnRound = Set(["border", "dropShadow", "roundedCorners"])
        video.effects = video.effects.filter { !drawnRound.contains($0.type) }.map { effect in
            var effect = effect
            effect.id = context.makeID("fx")
            return effect
        } + [Effect(id: context.makeID("fx"), type: style.rawValue, params: [style.parameter: .number(size)])]
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
        // crop animation, which would uncover the picture round the region.
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
        p.videoTracks[index].rippleMode = .cut
        return TrackLocation(kind: .video, index: index)
    }
}
