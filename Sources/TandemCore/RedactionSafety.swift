import Foundation

public struct RedactionSourceIdentity: Codable, Equatable, Sendable {
    public var mediaID: String
    public var path: String
    public var fingerprint: String?
    public var fileIdentity: String? = nil

    func matches(_ item: MediaItem) -> Bool {
        mediaID == item.id || (fingerprint?.isEmpty == false && fingerprint == item.fingerprint)
            || (path as NSString).standardizingPath == (item.path as NSString).standardizingPath
    }
}

/// Protection belongs to source frames. Links are an editing convenience,
/// not permission to show those frames elsewhere without their redaction.
public struct SourceRedaction: Codable, Equatable, Sendable {
    public var mediaID: String
    public var sourcePath: String
    public var fingerprint: String?
    public var identities: [RedactionSourceIdentity]? = nil
    public var pictureDelay: Time?
    public var sourceDuration: Time?
    public var sourceFrameRate: FrameRate?
    public var sourceVariableFrameRate: Bool?
    public var sourceKind: MediaKind
    public var sourceWidth: Int?
    public var sourceHeight: Int?
    public var sources: [TimeRange]
    public var region: Rect
    public var effect: Effect
    public var sourcePixelsPerUnit: Double
    public var originID: String? = nil

    public func matches(_ item: MediaItem) -> Bool {
        identities?.contains(where: { $0.matches(item) }) == true || mediaID == item.id || (fingerprint?.isEmpty == false && fingerprint == item.fingerprint)
            || (sourcePath as NSString).standardizingPath == (item.path as NSString).standardizingPath
    }

    func sharesSource(with other: SourceRedaction) -> Bool {
        let left = [RedactionSourceIdentity(mediaID: mediaID, path: sourcePath, fingerprint: fingerprint)] + (identities ?? [])
        let right = [RedactionSourceIdentity(mediaID: other.mediaID, path: other.sourcePath, fingerprint: other.fingerprint)] + (other.identities ?? [])
        return left.contains { a in right.contains { b in
            a.mediaID == b.mediaID || (!a.path.isEmpty && (a.path as NSString).standardizingPath == (b.path as NSString).standardizingPath)
                || (a.fingerprint?.isEmpty == false && a.fingerprint == b.fingerprint)
                || (a.fileIdentity != nil && a.fileIdentity == b.fileIdentity)
        } }
    }
}

public enum RedactionSafety {
    /// Device and inode identify hard links as well as resolved symlinks.
    public static func fileIdentity(at url: URL) -> String? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              let device = values[.systemNumber] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device.stringValue):\(inode.stringValue)"
    }

    static func matches(_ scope: SourceRedaction, _ item: MediaItem, in p: Project) -> Bool {
        if scope.matches(item) { return true }
        let owners = Set([scope.mediaID] + (scope.identities ?? []).map(\.mediaID))
        return p.media.contains { current in
            owners.contains(current.id) && ((current.fingerprint?.isEmpty == false && current.fingerprint == item.fingerprint)
                || (current.path as NSString).standardizingPath == (item.path as NSString).standardizingPath)
        }
    }
    public static func effect(on clip: Clip) -> Effect? {
        let effects = clip.video?.effects ?? []
        let preferred = effects.filter { $0.id == clip.video?.redactionEffectID }
        for effect in preferred + effects.reversed().filter({ $0.id != clip.video?.redactionEffectID }) {
            guard effect.enabled, let style = RedactStyle(rawValue: effect.type) else { continue }
            let values = strengths(effect, on: clip, style: style)
            guard let amount = values.min(), amount > style.minimumSize else { continue }
            var result = effect
            result.params[style.parameter] = .number(amount)
            return result
        }
        return nil
    }

    static func rememberEffect(_ clip: inout Clip) {
        guard clip.isRedaction else { return }
        if let active = effect(on: clip) {
            clip.video?.redactionEffectID = active.id
        } else if !(clip.video?.effects.contains { $0.id == clip.video?.redactionEffectID } ?? false) {
            let fallback = clip.video?.effects.last { RedactStyle(rawValue: $0.type) != nil }?.id
            clip.video?.redactionEffectID = fallback
        }
    }

    private struct EffectControl: Equatable {
        var effects: [Effect]
        var keyframes: [String: [Keyframe]]

        init(_ clip: Clip, watching ids: Set<String>) {
            let effects = (clip.video?.effects ?? []).filter { ids.contains($0.id) && RedactStyle(rawValue: $0.type) != nil }
            self.effects = effects
            keyframes = clip.keyframes.filter { key, _ in effects.contains { key.hasPrefix("video.effects.\($0.id).") } }
        }
    }

    static func strengths(_ effect: Effect, on clip: Clip, style: RedactStyle) -> [Double] {
        let keys = clip.keyframes["video.effects.\(effect.id).\(style.parameter)"] ?? []
        if keys.isEmpty { return [effect.params[style.parameter]?.number ?? style.defaultSize] }
        let visible = keys.filter { $0.time >= .zero && $0.time <= clip.duration }.map(\.value)
            + [keys.value(at: .zero), keys.value(at: clip.duration)].compactMap { $0 }
        return visible.map { $0.number ?? 0 }
    }

    /// Includes nominal frames and the frame actually displayed by a hold.
    /// A hold may select the frame just before a clip's nominal source span.
    public static func displayedSource(_ requested: Time, media: MediaItem?, frame: Time) -> Time {
        if media?.kind == .image { return .zero }
        let delay = media?.pictureDelay ?? .zero
        let last = media?.duration.map { max(.zero, $0 - (media?.frameRate?.frameDuration ?? frame)) }
        let physical = max(.zero, requested + delay)
        return min(physical, last ?? physical) - delay
    }

    public static func heldSource(_ requested: Time, media: MediaItem?, frame: Time) -> Time {
        let rate = media?.frameRate ?? FrameRate(Time.flicksPerSecond, max(1, frame.flicks))
        let delay = media?.pictureDelay ?? .zero
        let physical = max(.zero, requested + delay - min(Time(seconds: 0.001), frame))
        return displayedSource(Time.frames(physical.frameIndex(at: rate), at: rate) - delay, media: media, frame: frame)
    }

    public static func frozenSources(_ requested: Time, media: MediaItem?, frame: Time) -> [Time] {
        let rate = media?.frameRate ?? FrameRate(Time.flicksPerSecond, max(1, frame.flicks))
        let delay = media?.pictureDelay ?? .zero
        return [.zero, Time(seconds: 0.001)].map { slack in
            let physical = max(.zero, requested + delay + slack)
            return displayedSource(Time.frames(physical.frameIndex(at: rate), at: rate) - delay, media: media, frame: frame)
        }
    }

    static func sources(of clip: Clip, frame: Time, media: MediaItem?, rate: FrameRate) -> [TimeRange] {
        if media?.kind == .image { return [TimeRange(start: .zero, duration: frame)] }
        var result = [TimeRange(start: clip.sourceStart, duration: clip.freezeFrame ? frame : clip.sourceDuration)]
        if !clip.freezeFrame, media?.variableFrameRate != true {
            let fileRate = media?.frameRate ?? rate
            let fileFrame = fileRate.frameDuration
            let delay = media?.pictureDelay ?? .zero
            let start = max(.zero, clip.sourceStart + delay)
            let end = max(start, clip.sourceEnd + delay)
            // A fractional cut can display the sample preceding its head,
            // and that sample can be reused beyond the nominal tail too.
            result.append(TimeRange(start: Time.frames(start.frameIndex(at: fileRate), at: fileRate) - delay,
                                    end: Time.frames((end + fileFrame - Time(flicks: 1)).frameIndex(at: fileRate), at: fileRate) - delay))
        }
        if clip.freezeFrame || clip.holdEdges {
            result.append(TimeRange(start: displayedSource(clip.sourceStart, media: media, frame: frame), duration: frame))
            if clip.freezeFrame { result += frozenSources(clip.sourceStart, media: media, frame: frame).map { TimeRange(start: $0, duration: frame) } }
            if !clip.freezeFrame { result.append(TimeRange(start: displayedSource(clip.sourceEnd - frame, media: media, frame: frame), duration: frame)) }
        }
        if !clip.freezeFrame {
            result += clip.renderedHolds(rate: rate, within: clip.range).flatMap { hold in
                [displayedSource(hold.frame, media: media, frame: frame), heldSource(hold.frame, media: media, frame: frame)].map { TimeRange(start: $0, duration: frame) }
            }
        }
        return TimeRange.union(result)
    }

    public static func protections(in project: Project) -> [SourceRedaction] {
        if let remembered = project.sourceRedactions { return remembered.filter { !$0.sources.isEmpty } }
        var captured = project
        rememberSources(&captured)
        rememberPolicies(&captured)
        return captured.sourceRedactions ?? []
    }

    /// A temporarily hidden picture still owns privacy. An explicit copy,
    /// effect or track switch-off cannot later erase someone else's policy.
    static func ownsProtection(_ copy: Clip, on track: Track) -> Bool {
        !track.hidden && copy.video?.redactionVisibility != .disabled
            && (copy.enabled || copy.video?.redactionVisibility == .followingPicture)
            && copy.video?.redactionSources?.isEmpty != true && effect(on: copy) != nil
    }

    static func copies(in project: Project) -> [SourceRedaction] {
        project.videoTracks.filter { $0.isPrivacy && !$0.hidden }.flatMap { track in
            track.clips.compactMap { copy in
                guard ownsProtection(copy, on: track),
                      let mediaID = copy.mediaID, let region = Editing.redactionRegion(of: copy, on: track),
                      let effect = effect(on: copy) else { return nil }
                let frame = project.media(mediaID)?.frameRate?.frameDuration ?? project.settings.frameRate.frameDuration
                let item = project.media(mediaID)
                let selected = copy.video?.redactionSources ?? sources(of: copy, frame: frame, media: item, rate: project.settings.frameRate)
                guard !selected.isEmpty else { return nil }
                let scales = [copy.video?.transform.scale ?? 1] + (copy.keyframes["video.transform.scale"] ?? []).compactMap(\.value.number)
                let smallest = scales.filter { $0 > 0.0001 }.min() ?? 1
                func unit(width: Int, height: Int, scale: Double) -> Double {
                    let fit = min(Double(width) / Double(max(1, item?.width ?? width)), Double(height) / Double(max(1, item?.height ?? height)))
                    return Double(min(width, height)) / 1080 / max(0.0001, fit * scale)
                }
                var strongest = unit(width: project.settings.width, height: project.settings.height, scale: smallest)
                for format in project.settings.alternateFormats {
                    let override = copy.video?.formatOverrides[format.id]
                    if override?.hidden != true { strongest = max(strongest, unit(width: format.width, height: format.height, scale: override?.transform?.scale ?? smallest)) }
                }
                return SourceRedaction(mediaID: mediaID, sourcePath: item?.path ?? "", fingerprint: item?.fingerprint, pictureDelay: item?.pictureDelay, sourceDuration: item?.duration, sourceFrameRate: item?.frameRate, sourceVariableFrameRate: item?.variableFrameRate, sourceKind: item?.kind ?? .video, sourceWidth: item?.width, sourceHeight: item?.height, sources: selected, region: region, effect: effect, sourcePixelsPerUnit: strongest, originID: copy.video?.redactionOriginID)
            }
        }
    }

    static func rememberIdentities(_ scope: inout SourceRedaction, in p: Project, sourceFolder: URL?) {
        var identities = scope.identities ?? []
        func resolved(_ path: String) -> URL {
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : (sourceFolder ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).appendingPathComponent(expanded)
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        let owners = Set([scope.mediaID] + identities.map(\.mediaID))
        let paths = [scope.sourcePath] + identities.map(\.path) + p.media.filter { owners.contains($0.id) }.map(\.path)
        let files = Set(paths.map(resolved))
        let fileIDs = Set(identities.compactMap(\.fileIdentity) + files.compactMap { fileIdentity(at: $0) })
        for item in p.media {
            let url = resolved(item.path)
            let fileID = fileIdentity(at: url)
            guard matches(scope, item, in: p) || files.contains(url) || fileID.map(fileIDs.contains) == true else { continue }
            let identity = RedactionSourceIdentity(mediaID: item.id, path: item.path, fingerprint: item.fingerprint, fileIdentity: fileID)
            let sameReference: (RedactionSourceIdentity) -> Bool = { $0.mediaID == item.id && $0.path == item.path && $0.fingerprint == item.fingerprint }
            if fileID == nil, identities.contains(where: sameReference) { continue }
            if let index = identities.firstIndex(where: { sameReference($0) && $0.fileIdentity == nil }) { identities[index] = identity }
            else if !identities.contains(identity) { identities.append(identity) }
        }
        scope.identities = identities.isEmpty ? nil : identities
    }

    /// Union equal source-region policies without tying them to a timeline
    /// clip or a link group. Removing a take segment must not forget privacy.
    static func rememberPolicies(_ p: inout Project, keepingCalibrationFrom previous: [SourceRedaction] = [], sourceFolder: URL? = nil) {
        let captured = copies(in: p)
        var policies: [SourceRedaction] = []
        // Persist each encountered identity before a later repoint can make
        // the current-path association disappear, even without live copies.
        for (index, saved) in (p.sourceRedactions ?? []).filter({ !$0.sources.isEmpty }).enumerated() {
            var policy = saved
            rememberIdentities(&policy, in: p, sourceFolder: sourceFolder)
            if policy.originID != nil { policies.append(policy); continue }
            // Unreleased development builds merged independent requests
            // without their origins. Neither matching effect IDs/settings
            // nor current selections can prove who owns that history. Keep
            // it separate; current copies cannot silently relinquish it.
            let owners = Set(captured.compactMap(\.originID) + policies.compactMap(\.originID))
            var origin = "legacy-policy-\(index)-\(policy.effect.id)"
            while owners.contains(origin) { origin += "-historical" }
            policy.originID = origin
            policies.append(policy)
        }
        for var scope in captured {
            rememberIdentities(&scope, in: p, sourceFolder: sourceFolder)
            // Changing an effect's amount or style must not recalibrate its
            // units at a later zoom. A larger radius must stay stronger.
            for prior in previous where prior.sharesSource(with: scope) && prior.region == scope.region {
                scope.sourcePixelsPerUnit = max(scope.sourcePixelsPerUnit, prior.sourcePixelsPerUnit)
            }
            if let index = policies.firstIndex(where: { $0.originID == scope.originID && $0.mediaID == scope.mediaID && $0.sourcePath == scope.sourcePath && $0.fingerprint == scope.fingerprint && $0.pictureDelay == scope.pictureDelay && $0.region == scope.region && $0.effect.type == scope.effect.type && $0.effect.params == scope.effect.params }) {
                policies[index].sources = TimeRange.union(policies[index].sources + scope.sources)
                policies[index].sourcePixelsPerUnit = max(policies[index].sourcePixelsPerUnit, scope.sourcePixelsPerUnit)
            } else { policies.append(scope) }
        }
        p.sourceRedactions = policies.isEmpty ? nil : policies
    }

    static func subtract(_ ranges: [TimeRange], from originals: [TimeRange]) -> [TimeRange] {
        var result = originals
        for cut in ranges {
            result = result.flatMap { range -> [TimeRange] in
                guard range.overlaps(cut) else { return [range] }
                var pieces: [TimeRange] = []
                if range.start < cut.start { pieces.append(TimeRange(start: range.start, end: min(range.end, cut.start))) }
                if range.end > cut.end { pieces.append(TimeRange(start: max(range.start, cut.end), end: range.end)) }
                return pieces
            }
        }
        return result
    }

    /// A copy's explicit controls affect its own scope only. A ripple made
    /// by removing it still has to preserve all other source policies.
    static func applyControls(_ command: EditCommand, before: Project, to p: inout Project) {
        let changed = before.videoTracks.filter(\.isPrivacy).flatMap { track in
            track.clips.filter { copy in
                guard ownsProtection(copy, on: track) else { return false }
                if explicitlyEditsCopy(command, id: copy.id), let after = p.clip(copy.id) {
                    // Ignore unused effects. Only definitions controlling the
                    // before/after concealment can replace a source policy.
                    let ids = Set([copy.video?.redactionEffectID, after.video?.redactionEffectID].compactMap { $0 })
                    return EffectControl(after, watching: ids) != EffectControl(copy, watching: ids) || after.enabled != copy.enabled || after.video?.redactionVisibility != copy.video?.redactionVisibility
                }
                switch command {
                case .removeClips(let ids, _, _): return ids.contains(copy.id)
                case .removeTrack(let id): return track.id == id
                case .updateTrack(let id, _): return track.id == id && p.track(id)?.hidden != track.hidden
                default: return false
                }
            }
        }
        var policies = p.sourceRedactions ?? protections(in: before)
        var replacements: [SourceRedaction] = []
        var visible = p
        rememberSources(&visible)
        for copy in changed {
            guard let mediaID = copy.mediaID, let media = before.media(mediaID), let region = copy.video?.redaction else { continue }
            let owned = copy.video?.redactionSources ?? []
            let after = visible.clip(copy.id)
            let relinquished = after == nil || after?.video?.redactionVisibility == .disabled || after.flatMap(effect(on:)) == nil || visible.track(containingClip: copy.id)?.hidden == true
            // An active effect edit replaces only the source selection the
            // copy still owns. A simultaneous trim must retain the old tail.
            let affected = relinquished ? owned : owned.flatMap { range in (after?.video?.redactionSources ?? []).compactMap { range.intersection($0) } }
            for index in policies.indices where policies[index].region == region && policies[index].matches(media)
                && policies[index].originID == copy.video?.redactionOriginID {
                // Controls belong to a request, not every historical
                // redaction of the same pixels, even with identical effects.
                if !relinquished, let active = after.flatMap(effect(on:)) {
                    var replacement = policies[index]
                    replacement.sources = TimeRange.union(replacement.sources.flatMap { range in affected.compactMap { range.intersection($0) } })
                    replacement.effect = active
                    // Strength edits change concealment, not its file or
                    // clock. Retain every historical identity and mapping,
                    // including offline sources and earlier batch commands.
                    if !replacement.sources.isEmpty { replacements.append(replacement) }
                }
                policies[index].sources = subtract(affected, from: policies[index].sources)
            }
        }
        p.sourceRedactions = policies.filter { !$0.sources.isEmpty } + replacements
    }

    private static func picturePartners(of copy: Clip, in project: Project) -> [Clip] {
        guard let group = copy.linkGroup else { return [] }
        return project.videoTracks.flatMap { track in track.clips.filter {
            !$0.isRedaction && Editing.redactionRegion(of: $0, on: track, inferLegacy: project.schemaVersion < 3) == nil
                && $0.mediaID == copy.mediaID && $0.linkGroup == group
        } }
    }

    private static func sourceMappingChanged(from prior: Clip, to picture: Clip) -> Bool {
        prior.range != picture.range || prior.sourceStart != picture.sourceStart || prior.speed != picture.speed
            || prior.freezeFrame != picture.freezeFrame || prior.holdEdges != picture.holdEdges || prior.holds != picture.holds
    }

    private static func visibleSources(of picture: Clip, over range: TimeRange, in project: Project) -> [TimeRange] {
        guard let shared = picture.range.intersection(range) else { return [] }
        var shown = picture
        shown.sourceStart = picture.sourceTime(atTimelineTime: shared.start)
        shown.start = shared.start
        shown.duration = shared.duration
        let item = picture.mediaID.flatMap(project.media)
        let frame = item?.frameRate?.frameDuration ?? project.settings.frameRate.frameDuration
        return sources(of: shown, frame: frame, media: item, rate: project.settings.frameRate)
    }

    /// Old projects are captured before their first edit, including copies
    /// made before `video.redaction` existed. Journal replay uses this too.
    static func rememberSources(_ project: inout Project, restoringFrom previous: Project? = nil) {
        for ti in project.videoTracks.indices where project.videoTracks[ti].isPrivacy || (project.schemaVersion < 3 && project.videoTracks[ti].name.lowercased().hasPrefix(Editing.privacyTrackPrefix)) {
            for ci in project.videoTracks[ti].clips.indices {
                let copy = project.videoTracks[ti].clips[ci]
                guard let region = Editing.redactionRegion(of: copy, on: project.videoTracks[ti], inferLegacy: project.schemaVersion < 3), let mediaID = copy.mediaID else { continue }
                if project.videoTracks[ti].locked, copy.video?.redactionOriginID != nil,
                   copy.video?.redactionSources != nil, copy.video?.redactionVisibility != nil,
                   !ownsProtection(copy, on: project.videoTracks[ti]) {
                    // Inactive copies do not follow the picture while locked.
                    // Initial legacy capture still fills missing metadata.
                    continue
                }
                let frame = project.media(mediaID)?.frameRate?.frameDuration ?? project.settings.frameRate.frameDuration
                let item = project.media(mediaID)
                let origin = copy.video?.redactionOriginID ?? copy.id
                let ownSources = sources(of: copy, frame: frame, media: item, rate: project.settings.frameRate)
                let pictures = picturePartners(of: copy, in: project)
                let visibility = copy.video?.redactionVisibility ?? (!copy.enabled && pictures.first?.enabled != false ? .disabled : .followingPicture)
                if copy.video?.redactionSources == nil {
                    // The original copy is evidence of its whole selection,
                    // even if an old picture partner was already trimmed or
                    // slipped. Persist that intent once before bounding the
                    // copy's later controls to the picture it now protects.
                    var original = copy
                    original.video?.redaction = region
                    original.video?.redactionOriginID = origin
                    original.video?.redactionVisibility = visibility
                    var capture = project
                    capture.videoTracks = [project.videoTracks[ti]]
                    capture.videoTracks[0].clips = [original]
                    let initial = copies(in: capture)
                    if !initial.isEmpty { project.sourceRedactions = (project.sourceRedactions ?? []) + initial }
                }
                var visible = pictures.isEmpty ? ownSources : []
                var ranges = copy.video?.redactionSources ?? ownSources
                var history: [TimeRange] = []
                if let previous, let oldCopy = previous.clip(copy.id), pictures.count == 1, let picture = pictures.first {
                    let priorPictures = picturePartners(of: oldCopy, in: previous)
                    if priorPictures.count == 1, let prior = priorPictures.first, prior.id == picture.id,
                       sourceMappingChanged(from: prior, to: picture) {
                        history = (project.sourceRedactions ?? []).filter { $0.originID == origin && $0.region == region && item.map($0.matches) == true }.flatMap(\.sources)
                    }
                }
                // Only the actual picture can bring a request's historical
                // selection back through a source or timing edit. Link
                // membership, reloads and copy edits cannot grant ownership.
                for picture in pictures {
                    guard let shared = picture.range.intersection(copy.range) else { continue }
                    let pictureSources = visibleSources(of: picture, over: copy.range, in: project)
                    visible += pictureSources
                    ranges += history.flatMap { range in pictureSources.compactMap { range.intersection($0) } }
                    // A picture-only hold may show a frame outside the
                    // nominal selection, so capture that frame too.
                    if picture.freezeFrame {
                        let frames = [displayedSource(picture.sourceStart, media: item, frame: frame)] + frozenSources(picture.sourceStart, media: item, frame: frame)
                        let extras = frames.map { TimeRange(start: $0, duration: frame) }
                        if pictures.count == 1 { ranges += extras }
                        visible += extras
                    } else {
                        let source = TimeRange(start: picture.sourceTime(atTimelineTime: shared.start), end: picture.sourceTime(atTimelineTime: shared.end))
                        visible.append(source)
                        let extras = picture.renderedHolds(rate: project.settings.frameRate, within: shared).flatMap { hold in
                            [displayedSource(hold.frame, media: item, frame: frame), heldSource(hold.frame, media: item, frame: frame)].map { TimeRange(start: $0, duration: frame) }
                        }
                        if pictures.count == 1 { ranges += extras }
                        visible += extras
                    }
                }
                project.videoTracks[ti].clips[ci].video?.redaction = region
                project.videoTracks[ti].clips[ci].video?.redactionOriginID = origin
                project.videoTracks[ti].clips[ci].video?.redactionSources = TimeRange.union(ranges.flatMap { range in visible.compactMap { range.intersection($0) } })
                project.videoTracks[ti].clips[ci].video?.redactionVisibility = visibility
                rememberEffect(&project.videoTracks[ti].clips[ci])
            }
        }
    }

    /// Repairs the one-picture partners. More complicated changes must pass
    /// the same coverage check; an unsupported edit is refused atomically.
    static func reconcile(_ project: inout Project, before: Project, command: EditCommand, validateCoverage: Bool, sourceFolder: URL?, cutFrom: [String: String] = [:]) throws {
        let old = protections(in: before)
        // Media timing is part of every privacy mapping. Check it after each
        // command, not only at batch end, so a batch can't change a frame
        // rate, let later commands remember wider sources, then change it
        // back. Each changed file is judged on its own, so it may still be
        // repaired onto its recorded mapping.
        try requireUnchangedClocks(project, before: before, protecting: old)
        // A clip cut off another (a blade, an overwrite) has a new ID. Judge
        // it, and its picture partners, by the clip it was cut from.
        func ancestor(_ id: String) -> String {
            var current = id
            var seen: Set<String> = []
            while before.clip(current) == nil, let origin = cutFrom[current], seen.insert(current).inserted { current = origin }
            return current
        }
        // Privacy guards compare each copy with its prior video-track self.
        // A copy that crossed track kinds would escape that comparison.
        let priorVideo = Set(before.videoTracks.flatMap(\.clips).map(\.id))
        let priorAudio = Set(before.audioTracks.flatMap(\.clips).map(\.id))
        for clip in project.audioTracks.flatMap(\.clips) where clip.isRedaction && !priorAudio.contains(clip.id) {
            throw EditError.invalid("Privacy copy \(clip.id) can't move to an audio track; it stays on its privacy track.")
        }
        for clip in project.videoTracks.flatMap(\.clips) where clip.isRedaction && priorAudio.contains(clip.id) && !priorVideo.contains(clip.id) {
            throw EditError.invalid("Privacy copy \(clip.id) can't return from an audio track. Remove it and redact the picture again.")
        }
        for ti in project.videoTracks.indices {
            for ci in project.videoTracks[ti].clips.indices {
                rememberEffect(&project.videoTracks[ti].clips[ci])
                if project.videoTracks[ti].clips[ci].video?.redactionVisibility == .disabled {
                    project.videoTracks[ti].clips[ci].enabled = false
                }
                let copy = project.videoTracks[ti].clips[ci]
                if copy.isRedaction, let prior = before.clip(ancestor(copy.id)), prior.isRedaction {
                    let priorPartners = picturePartners(of: prior, in: before)
                    let existing = Set(priorPartners.map(\.id))
                    let partners = picturePartners(of: copy, in: project)
                    // The copy's range participates in the ownership proof.
                    // Keep that evidence fixed until ambiguity is resolved,
                    // including commands that narrow the group at once.
                    if (priorPartners.count > 1 || partners.count > 1), sourceMappingChanged(from: prior, to: copy) {
                        throw EditError.invalid("This privacy copy has ambiguous picture partners. Unlink the extra pictures before changing the copy's source or timing.")
                    }
                    guard partners.allSatisfy({ existing.contains(ancestor($0.id)) }) else {
                        throw EditError.invalid("A privacy copy must keep its existing picture partners. Redact another picture to create its own privacy request instead of assigning it through links.")
                    }
                    if priorPartners.count > 1, partners.count < priorPartners.count, !partners.isEmpty {
                        // Narrowing a group cannot promote a dummy into the
                        // original owner's place. Establish that identity
                        // from the selection before any partners disappear.
                        let owned = prior.video?.redactionSources ?? []
                        let owners: [Clip] = owned.isEmpty ? [] : priorPartners.filter { picture in
                            let visible = visibleSources(of: picture, over: prior.range, in: before)
                            return owned.allSatisfy { selection in visible.contains { $0.start <= selection.start && $0.end >= selection.end } }
                        }
                        guard owners.count == 1, partners.contains(where: { ancestor($0.id) == owners[0].id }) else {
                            throw EditError.invalid("This privacy copy's original picture is ambiguous. Keep its original picture, or unlink all partners and redact the intended picture again.")
                        }
                    }
                    if partners.count > 1, partners.contains(where: { picture in
                        before.clip(ancestor(picture.id)).map { sourceMappingChanged(from: $0, to: picture) } == true
                    }) {
                        throw EditError.invalid("A privacy copy has multiple picture partners, so their source timing is ambiguous. Unlink the extra pictures and redact each picture separately before changing its timing.")
                    }
                }
            }
            if project.videoTracks[ti].clips.contains(where: \.isRedaction),
               project.videoTracks[ti].clips.contains(where: { $0.mediaID != nil && !$0.isRedaction }) {
                throw EditError.invalid("Privacy copies need a separate track from ordinary footage. Move the copy to a dedicated privacy track.")
            }
        }
        applyControls(command, before: before, to: &project)
        for track in project.videoTracks where track.isPrivacy {
            for copy in track.clips where copy.video?.redaction != nil {
                for effect in copy.video?.effects ?? [] where effect.enabled {
                    guard let style = RedactStyle(rawValue: effect.type) else { continue }
                    let values = strengths(effect, on: copy, style: style)
                    let minimum = style.minimumSize
                    if values.contains(where: { $0 <= minimum }) && values.contains(where: { $0 > minimum }) {
                        throw EditError.invalid("A privacy effect cannot animate through a zero-strength redaction. Keep the blur effective for the whole protected clip, or explicitly switch the effect off.")
                    }
                }
            }
        }
        // Picture delay changes the identity of every displayed source frame.
        // Existing protection is in the old file mapping: refuse rather than
        // silently moving private frames into neighbouring placements.
        guard before.videoTracks.contains(where: { track in track.clips.contains { Editing.redactionRegion(of: $0, on: track) != nil } }) else {
            rememberSources(&project)
            rememberPolicies(&project, keepingCalibrationFrom: old, sourceFolder: sourceFolder)
            if validateCoverage { try requireCoverage(project, protecting: protections(in: project)) }
            return
        }
        for ti in project.videoTracks.indices where project.videoTracks[ti].isPrivacy && !project.videoTracks[ti].hidden {
            for ci in project.videoTracks[ti].clips.indices {
                var copy = project.videoTracks[ti].clips[ci]
                guard copy.video?.redactionVisibility != .disabled,
                      let region = Editing.redactionRegion(of: copy, on: project.videoTracks[ti]) else { continue }
                let pictures = picturePartners(of: copy, in: project)
                guard pictures.count == 1, let picture = pictures.first else { continue }
                var placed = Editing.aligned(copy, over: picture, region: region, format: nil)
                placed.enabled = picture.enabled
                // Animation is relative to each clip's head, including rolls
                // whose picture and patch have different bounds.
                for key in ["video.transform.position", "video.transform.scale", "video.transform.rotation"] {
                    placed.keyframes[key] = picture.keyframes[key].map { list in list.map { var k = $0; k.time += picture.start - copy.start; return k } }
                }
                switch command {
                case .updateClip(let id, _) where id == picture.id:
                    if let previous = before.clip(copy.id), let priorPicture = before.clip(picture.id), previous.range == priorPicture.range {
                        placed.start = picture.start
                        placed.duration = picture.duration
                        placed.sourceStart = picture.sourceStart
                        placed.speed = picture.speed
                        placed.freezeFrame = picture.freezeFrame
                        placed.holdEdges = picture.holdEdges
                        placed.holds = picture.holds
                        for key in ["video.transform.position", "video.transform.scale", "video.transform.rotation"] { placed.keyframes[key] = picture.keyframes[key] }
                    }
                case .holdFrame(let id, _) where id == picture.id:
                    placed.holds = picture.holds
                default: break
                }
                // Explicit edits to the copy are intentional controls (for
                // example switching off a blur), not a picture to realign.
                if editsCopyPlacement(command, id: copy.id) || effect(on: copy) == nil { continue }
                if placed != copy {
                    guard !project.videoTracks[ti].locked else { throw EditError.invalid("Privacy track \(project.videoTracks[ti].name) is locked; unlock it so its redaction can follow the picture.") }
                    copy = placed
                    project.videoTracks[ti].clips[ci] = copy
                }
            }
        }
        for ti in project.videoTracks.indices { project.videoTracks[ti].sortClips() }
        // A blade skipped under a locked patch can look covered now but
        // leave the right piece unlinked. Refuse before committing that state.
        for track in before.videoTracks where track.isPrivacy && track.locked {
            for copy in track.clips where ownsProtection(copy, on: track) {
                let partners = before.videoTracks.flatMap(\.clips).filter { $0.video?.redaction == nil && $0.linkGroup != nil && $0.linkGroup == copy.linkGroup && $0.mediaID == copy.mediaID }
                if partners.contains(where: { original in
                    guard var after = project.clip(original.id) else { return true }
                    after.name = original.name
                    after.tags = original.tags
                    return after != original
                }) {
                    throw EditError.invalid("Privacy track \(track.name) is locked; the protected picture cannot change without its redaction.")
                }
            }
        }
        rememberSources(&project, restoringFrom: before)
        for track in before.videoTracks where track.isPrivacy && track.locked {
            if let after = project.track(track.id), after.clips != track.clips {
                throw EditError.invalid("Privacy track \(track.name) is locked; its copies cannot change.")
            }
        }
        rememberPolicies(&project, keepingCalibrationFrom: old, sourceFolder: sourceFolder)
        if validateCoverage { try requireCoverage(project, protecting: protections(in: project)) }
    }

    static func explicitlyEditsCopy(_ command: EditCommand, id: String) -> Bool {
        switch command {
        case .updateClip(let clipID, _), .setKeyframes(let clipID, _, _), .addEffect(let clipID, _, _), .updateEffect(let clipID, _, _), .removeEffect(let clipID, _), .moveEffect(let clipID, _, _): return clipID == id
        default: return false
        }
    }

    static func mappingDiffers(_ scope: SourceRedaction, _ item: MediaItem) -> Bool {
        (item.pictureDelay ?? .zero) != (scope.pictureDelay ?? .zero) || item.duration != scope.sourceDuration || item.frameRate != scope.sourceFrameRate
            || item.variableFrameRate != (scope.sourceVariableFrameRate ?? item.variableFrameRate) || item.kind != scope.sourceKind
            || item.width != scope.sourceWidth || item.height != scope.sourceHeight
    }

    static let mappingMessage = "A protected file's frame timing, boundaries and dimensions cannot change while it has redactions. Keep its privacy source mapping unchanged."

    static func requireSourceMappings(_ project: Project) throws {
        for scope in protections(in: project) {
            if project.media.contains(where: { matches(scope, $0, in: project) && mappingDiffers(scope, $0) }) {
                throw EditError.invalid(mappingMessage)
            }
        }
    }

    /// The per-command half of `requireSourceMappings`. It judges each file
    /// on its own, so another file's broken mapping (an alias waiting to be
    /// removed) can't switch the check off for the rest of a batch.
    static func requireUnchangedClocks(_ project: Project, before: Project, protecting scopes: [SourceRedaction]) throws {
        for item in project.media {
            let prior = before.media(item.id)
            let changed = prior.map { ($0.pictureDelay ?? .zero) != (item.pictureDelay ?? .zero) || $0.duration != item.duration || $0.frameRate != item.frameRate
                || $0.variableFrameRate != item.variableFrameRate || $0.kind != item.kind || $0.width != item.width || $0.height != item.height } ?? true
            guard changed else { continue }
            // A changed file may only move onto the mapping its redactions recorded.
            // A scope saved before the variable-rate flag was recorded keeps
            // the flag the file had, rather than accepting any new value.
            let flagMoved = prior.map { $0.variableFrameRate != item.variableFrameRate } ?? false
            if scopes.contains(where: { matches($0, item, in: project) && (mappingDiffers($0, item) || ($0.sourceVariableFrameRate == nil && flagMoved)) }) {
                throw EditError.invalid(mappingMessage)
            }
        }
        // The project's frame grid times held frames and files without a
        // rate of their own, so changing it can move what a copy owns
        // without any picture changing. Keep it fixed while redactions exist.
        // A project saved with an unusable rate may still be repaired: no
        // batch can end on one, so this can't be used to launder a mapping.
        if project.settings.frameRate != before.settings.frameRate, before.settings.frameRate.isUsable, !scopes.isEmpty {
            throw EditError.invalid("The project's frame rate can't change while it has redactions: it times their held frames and source mapping. Set the frame rate before redacting.")
        }
    }

    static func editsCopyPlacement(_ command: EditCommand, id: String) -> Bool {
        switch command {
        case .updateClip(let clipID, let patch) where clipID == id:
            return Editing.patchSets(patch, "video", "transform") || Editing.patchSets(patch, "video", "crop") || Editing.patchSets(patch, "video", "formatOverrides") || Editing.patchSets(patch, "keyframes")
        case .setKeyframes(let clipID, let parameter, _) where clipID == id:
            return parameter.hasPrefix("video.transform.") || parameter.hasPrefix("video.crop.")
        default: return false
        }
    }

    /// Timeline intervals where either the nominal or held frame is protected.
    /// This uses exact time maps, not a sampling grid that can miss a sliver.
    static func intervals(_ clip: Clip, sources: [TimeRange], media: MediaItem?, frame: Time) -> [TimeRange] {
        if media?.kind == .image { return sources.isEmpty ? [] : [clip.range] }
        if clip.freezeFrame {
            let candidates = frozenSources(clip.sourceStart, media: media, frame: frame) + [displayedSource(clip.sourceStart, media: media, frame: frame), clip.sourceStart]
            return sources.contains { scope in candidates.contains(where: scope.contains) } ? [clip.range] : []
        }
        let speed = max(clip.speed, 0.0001)
        func timeline(_ range: TimeRange) -> TimeRange? {
            TimeRange(start: clip.start + (range.start - clip.sourceStart).scaled(by: 1 / speed), end: clip.start + (range.end - clip.sourceStart).scaled(by: 1 / speed)).intersection(clip.range)
        }
        var result = sources.compactMap(timeline)
        if frozenSources(clip.sourceStart, media: media, frame: frame).contains(where: { sample in sources.contains { $0.contains(sample) } }),
           let head = clip.range.intersection(TimeRange(start: clip.start, duration: frame)) { result.append(head) }
        let rate = FrameRate(Time.flicksPerSecond, max(1, frame.flicks))
        for hold in clip.renderedHolds(rate: rate, within: clip.range) where sources.contains(where: { $0.contains(displayedSource(hold.frame, media: media, frame: frame)) || $0.contains(heldSource(hold.frame, media: media, frame: frame)) }) {
            result.append(hold.timeline)
        }
        let first = displayedSource(Time(seconds: -1e9), media: media, frame: frame)
        let last = displayedSource(Time(seconds: 1e9), media: media, frame: frame)
        if sources.contains(where: { $0.contains(first) }), let head = timeline(TimeRange(start: min(clip.sourceStart, first), end: first)) { result.append(head) }
        if media?.duration != nil, sources.contains(where: { $0.contains(last) }), let tail = timeline(TimeRange(start: last, end: max(clip.sourceEnd, last))) { result.append(tail) }
        return TimeRange.union(result)
    }

    static func requireCoverage(_ p: Project, protecting scopes: [SourceRedaction]) throws {
        // A coordinator/journal batch may repair an invalid alias in steps.
        // Validate the complete result at the same gate as pixel coverage.
        try requireSourceMappings(p)
        for (ti, track) in p.videoTracks.enumerated() where !track.hidden {
            for picture in track.clips where picture.enabled && picture.video?.redaction == nil {
                for scope in scopes where picture.mediaID.flatMap(p.media).map({ matches(scope, $0, in: p) }) == true {
                    let needed = intervals(picture, sources: scope.sources, media: picture.mediaID.flatMap(p.media), frame: p.settings.frameRate.frameDuration)
                    guard !needed.isEmpty else { continue }
                    let formats: [String?] = [nil] + Set(p.settings.alternateFormats.map(\.id) + Array(picture.video?.formatOverrides.keys ?? [:].keys)).sorted().map { Optional($0) }
                    for format in formats {
                        guard picture.resolvedVideo(at: .zero, format: format) != nil else { continue }
                        let widest = Editing.widestCrop(of: picture, override: format.flatMap { picture.video?.formatOverrides[$0] })
                        guard let visible = Editing.redactedCrop(widest, scope.region) else { continue }
                        var covered: [TimeRange] = []
                        for masks in p.videoTracks.dropFirst(ti + 1) where masks.isPrivacy && !masks.hidden {
                            for mask in masks.clips where mask.enabled && mask.mediaID.flatMap(p.media).map({ matches(scope, $0, in: p) }) == true && mask.video?.redaction != nil && effect(on: mask) != nil {
                                guard let mv = mask.resolvedVideo(at: .zero, format: format), mv.opacity == 1, mask.keyframes["video.opacity"] == nil,
                                      !mask.keyframes.keys.contains(where: { $0.hasPrefix("video.crop.") }), mv.cutout?.enabled != true,
                                      !mv.effects.contains(where: { $0.enabled && $0.type == "roundedCorners" }),
                                      samePlacement(picture, mask, format: format),
                                      mv.crop.left <= visible.left + 1e-8, mv.crop.top <= visible.top + 1e-8,
                                      mv.crop.right <= visible.right + 1e-8, mv.crop.bottom <= visible.bottom + 1e-8 else { continue }
                                covered.append(mask.range)
                            }
                        }
                        let union = TimeRange.union(covered)
                        guard needed.allSatisfy({ range in union.contains { $0.start <= range.start + Time.overlapTolerance && $0.end >= range.end - Time.overlapTolerance } }) else {
                            throw EditError.invalid("This edit would expose a protected source region on \(track.name). Keep its privacy copy above the picture, aligned and enabled; unlock the privacy track if needed.")
                        }
                    }
                }
            }
        }
    }

    static func samePlacement(_ a: Clip, _ b: Clip, format: String?) -> Bool {
        let shared = max(a.start, b.start)
        guard a.resolvedVideo(at: shared - a.start, format: format)?.transform == b.resolvedVideo(at: shared - b.start, format: format)?.transform else { return false }
        if let format {
            let ao = a.video?.formatOverrides[format]?.transform != nil
            let bo = b.video?.formatOverrides[format]?.transform != nil
            if ao && bo { return true }
            if ao != bo { return false }
        }
        for key in ["video.transform.position", "video.transform.scale", "video.transform.rotation"] {
            func absolute(_ c: Clip) -> [Keyframe] {
                (c.keyframes[key] ?? []).map { var k = $0; k.time += c.start; return k }
            }
            guard absolute(a) == absolute(b) else { return false }
        }
        return true
    }
}
