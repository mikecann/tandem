import Foundation
import TandemCore
import TandemMedia

// MARK: - sync

/// Puts a take's picture back in step with its sound. A webcam's picture
/// lags its microphone (Mike's by about 0.08 s), so lips and voice drift
/// apart. This sets how late each file's picture is
/// (`MediaItem.pictureDelay`): every clip of the file then shows its
/// picture that much later in the file, in the app, frames, review clips,
/// checks and exports, while its sound and cuts stay put. Without `delay`
/// it says what's set.
///
/// With `files` it lines other recordings of the take up with the camera by
/// their sound instead (another camera angle, an external mic): it measures
/// each one's offset (`SoundSync`), puts it in the camera's take
/// (`takeID`, `takeOffset`) and, unless told not to, places it alongside
/// the take (`placeSynced`), all in one undo step. Then it measures the lip
/// sync that sound can't see (`check`).
///
/// With `check` it only measures: how far the voice is from the lips on each
/// camera file (`syncCheck`).
public struct SyncRequest: ServiceCall {
    public static let operation = ServiceOperation.sync
    /// How late the picture is, in seconds (0.08 for 80 ms). 0 puts it
    /// back as recorded.
    public var delay: Time?
    /// The files to set it on. Default: every camera take.
    public var media: [String]?
    /// Make it the delay new camera takes get too (Tandem's settings).
    public var makeDefault: Bool?
    /// Files to line up with the camera by their sound: media IDs or paths.
    public var files: [String]?
    /// The file they're lined up with. Default: the camera take.
    public var to: String?
    /// Put each file alongside the take on the timeline. Default true.
    public var place: Bool?
    /// Measure and check the edit, but change nothing.
    public var dryRun: Bool?
    /// True: measure lip sync and change nothing. With `files`, false skips
    /// the measurement that otherwise follows lining them up.
    public var check: Bool?
    /// With `check`: the stretch of the timeline to measure. Default: a
    /// sample of each file. (`until` because `to` is the file to line up with.)
    public var from: Time?
    public var until: Time?
    public var label: String?
    public var expectedRevision: Int?

    public init(
        delay: Time? = nil, media: [String]? = nil, makeDefault: Bool? = nil, files: [String]? = nil, to: String? = nil,
        place: Bool? = nil, dryRun: Bool? = nil, check: Bool? = nil, from: Time? = nil, until: Time? = nil,
        label: String? = nil, expectedRevision: Int? = nil
    ) {
        self.check = check
        self.from = from
        self.until = until
        self.delay = delay
        self.media = media
        self.makeDefault = makeDefault
        self.files = files
        self.to = to
        self.place = place
        self.dryRun = dryRun
        self.label = label
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delay = try c.decodeTime(.delay)
        media = try c.decodeIfPresent([String].self, forKey: .media)
        makeDefault = try c.decodeIfPresent(Bool.self, forKey: .makeDefault)
        files = try c.decodeIfPresent([String].self, forKey: .files)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        place = try c.decodeIfPresent(Bool.self, forKey: .place)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun)
        check = try c.decodeIfPresent(Bool.self, forKey: .check)
        from = try c.decodeTime(.from)
        until = try c.decodeTime(.until)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> SyncResult {
        if check == true { return try await service.syncCheck(self, context: context) }
        if let files, !files.isEmpty { return try await service.syncBySound(self, context: context) }
        return try service.sync(self, context: context)
    }
}

public struct SyncResult: Codable, Sendable {
    public var revision: Int
    /// Every file with a moving picture, camera takes first.
    public var files: [SyncFile]
    /// The delay new camera takes get (Tandem's settings).
    public var defaultDelay: Time
    /// The edit, when the delay changed or files were synced by sound.
    public var applied: ApplyResult?
    /// Files lined up by sound, and the file they were lined up with.
    public var matches: [SoundMatch]?
    public var reference: String?
    /// Files whose delay landed on a whole frame other than the one asked for.
    public var rounded: [SyncRounding]?
    /// True when this result is `tandem sync --check`'s, which lists no delays.
    public var check: Bool?
    /// The lip sync measured: by `--check`, or after lining files up by sound.
    public var lipSync: [LipSyncFile]?
    /// Why lining files up didn't go on to measure lip sync.
    public var lipSyncNote: String?

    /// "80 ms".
    static func milliseconds(_ time: Time) -> String {
        "\(Int((time.seconds * 1000).rounded())) ms"
    }
}

public struct SyncFile: Codable, Sendable {
    public var id: String
    public var path: String
    public var role: MediaRole
    public var pictureDelay: Time?
    /// The lag its recorder already took out (Record It's Camera delay).
    public var pictureDelayCorrected: Time?
    /// How many of its frames that moves the picture. Nil when its frames
    /// don't come at a steady rate, or the delay falls between two frames, so
    /// it moves by one or the other depending where each clip starts.
    public var frames: Int?
}

/// A delay asked for that isn't a whole number of a file's frames, and what it got.
public struct SyncRounding: Codable, Sendable {
    public var id: String
    public var asked: Time
    public var applied: Time
    public var frames: Int
    public var frameRate: Double
}

/// Picture delays move the picture by whole frames.
///
/// A timeline frame shows the last file frame at or before `sourceStart +
/// offset + delay`, so a delay between two frames moves a clip by one or the
/// other depending on where the clip starts between its file's frames. 57 ms
/// on a 23.976 fps file was one frame on some clips and two on others, and
/// overshot on the James interview. A whole number of frames moves every clip
/// by exactly that.
enum PictureDelay {
    /// The nearest whole frames of the file, or the delay as asked when its
    /// frames don't come at a steady rate (a screen recording). Stored Times
    /// sit on the 48 kHz grid; rounding up keeps a frame at 29.97 fps from
    /// landing a hair short of its boundary, which would lose it on a clip
    /// that starts on one.
    static func snapped(_ delay: Time, for item: MediaItem) -> (delay: Time, frames: Int?) {
        guard let rate = item.frameRate, !item.variableFrameRate, rate.flicksPerFrame > 0 else { return (delay, nil) }
        let frames = delay.roundedToFrame(rate).frameIndex(at: rate)
        return (onSampleGrid(Time.frames(frames, at: rate)), Int(frames))
    }

    private static func onSampleGrid(_ time: Time) -> Time {
        let sample = Time.flicksPerSample48k
        let samples = Int64((Double(time.flicks) / Double(sample)).rounded(.up))
        return Time(flicks: samples * sample)
    }

    /// The frames a stored delay is, when it's a whole number of them.
    static func frames(in delay: Time, of item: MediaItem) -> Int? {
        let snapped = snapped(delay, for: item)
        return snapped.delay == delay ? snapped.frames : nil
    }

    /// "0.0417": seconds, enough to land on the right frame when typed back.
    static func argument(_ delay: Time) -> String {
        delay == .zero ? "0" : String(format: "%.4f", delay.seconds)
    }

    /// "1 frame".
    static func count(_ frames: Int) -> String {
        "\(frames) frame\(abs(frames) == 1 ? "" : "s")"
    }
}

/// One file lined up with the camera by sound.
public struct SoundMatch: Codable, Sendable {
    public var id: String
    public var path: String
    /// How much further into this file a moment is than into the camera's,
    /// in seconds, at the middle of where they overlap. Positive: it
    /// started first.
    public var offset: Double
    /// How much that changes from the start of the overlap to its end
    /// (the two clocks running at slightly different speeds), in seconds.
    public var drift: Double?
    /// The correlation's peak over its noise: unrelated sound scores under
    /// 10, a refusal is under 15.
    public var confidence: Double
    /// Where the two overlap, in the camera file's time.
    public var overlapStart: Double
    public var overlapEnd: Double
    /// Its place in the camera's take.
    public var takeID: String
    public var takeOffset: Time
    /// The tracks its clips are on now, when it was placed.
    public var tracks: [String]?
    /// Anything worth knowing: it was on the timeline already, it drifts
    /// more than half a frame.
    public var notes: [String]
}

extension SyncResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if check == true { return lipSyncLines.joined(separator: "\n") }
        if let matches {
            lines.append("Lined up with \(reference ?? "the camera") by sound (how much further into each file the same moment is):")
            let idWidth = matches.map(\.id.count).max() ?? 0
            for match in matches {
                var line = "  \(match.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  \(match.path)  " + String(format: "%+.3f s", match.offset)
                if let drift = match.drift {
                    line += ", drift \(Self.milliseconds(Time(seconds: drift))) over \(TimeText.duration(Time(seconds: match.overlapEnd - match.overlapStart)))"
                }
                line += String(format: ", confidence %.0f.", match.confidence)
                if let tracks = match.tracks, !tracks.isEmpty {
                    line += " On \(tracks.map { "\"\($0)\"" }.joined(separator: " and "))."
                }
                lines.append(line)
                for note in match.notes { lines.append("    \(note)") }
            }
            if let applied {
                lines.append(applied.dryRun
                    ? "Dry run: nothing changed. Without --dry-run it sets their takes\(applied.added.isEmpty ? "" : " and places them") as one undo step."
                    : "Applied \"\(applied.label)\" by \(applied.author) as revision \(applied.revision).")
                for warning in applied.warnings { lines.append("Warning: \(warning)") }
            }
            lines += lipSyncLines
            return lines.joined(separator: "\n")
        }
        if let applied { lines.append("Applied \"\(applied.label)\" by \(applied.author) as revision \(applied.revision).") }
        for round in rounded ?? [] {
            lines.append("\(round.id): \(Self.milliseconds(round.asked)) rounds to \(Self.milliseconds(round.applied)), \(PictureDelay.count(round.frames)) at \(String(format: "%.3f", round.frameRate)) fps. The picture moves by whole frames.")
        }
        if files.isEmpty {
            lines.append("No files with a moving picture yet.")
        } else {
            lines.append("How late each file's picture is against its sound (each clip shows its picture that much later, so lips match the voice):")
            let idWidth = files.map(\.id.count).max() ?? 0
            for file in files {
                let delay = file.pictureDelay.flatMap { $0 == .zero ? nil : $0 }
                var state = delay.map(Self.milliseconds) ?? "as recorded"
                if delay != nil {
                    state += file.frames.map { " (\(PictureDelay.count($0)))" } ?? " (between frames, so it depends on the clip)"
                }
                if let corrected = file.pictureDelayCorrected { state += ", in sync as recorded (Record It took out \(Self.milliseconds(corrected)))" }
                lines.append("  \(file.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  \(file.path)  \(file.role.rawValue)  \(state)")
            }
        }
        lines.append(defaultDelay == .zero
            ? "New camera takes keep their picture as recorded (tandem sync <seconds> --default sets a delay for them)."
            : "New camera takes get \(Self.milliseconds(defaultDelay)) (Tandem's settings).")
        return lines.joined(separator: "\n")
    }
}

extension TandemService {
    public func sync(_ request: SyncRequest, context: CallContext) throws -> SyncResult {
        var settings = TandemSettings.load()
        var applied: ApplyResult?
        var rounded: [SyncRounding] = []
        if let delay = request.delay {
            guard abs(delay.seconds) <= 1 else {
                throw ServiceError(.badRequest, "\(delay.seconds) s is more than a second. Webcams run about 0.04 to 0.15 s behind their mic; the delay is in seconds, so 80 ms is 0.08.")
            }
            let (project, revision) = coordinator.snapshot()
            try checkExpected(request.expectedRevision, at: revision)
            let targets: [MediaItem]
            if let ids = request.media {
                targets = try ids.map { id in
                    guard let item = project.media(id) else { throw ServiceError(.notFound, "No media with ID \(id). tandem sync lists the files.") }
                    guard item.kind == .video, item.hasVideo else { throw ServiceError(.badRequest, "\(item.path) has no moving picture to delay.") }
                    return item
                }
            } else {
                // Takes Record It already corrected are in sync as they are.
                targets = project.media.filter { Self.isCameraTake($0) && $0.pictureDelayCorrected == nil }
            }
            let wanted = targets.map { (item: $0, snapped: PictureDelay.snapped(delay, for: $0)) }
            for target in wanted where target.snapped.delay != delay {
                guard let frames = target.snapped.frames, let rate = target.item.frameRate else { continue }
                rounded.append(SyncRounding(id: target.item.id, asked: delay, applied: target.snapped.delay, frames: frames, frameRate: rate.framesPerSecond))
            }
            let commands = wanted.filter { ($0.item.pictureDelay ?? .zero) != $0.snapped.delay }.map { target in
                let applied = target.snapped.delay
                return EditCommand.updateMedia(mediaID: target.item.id, patch: .object(["pictureDelay": applied == .zero ? .null : .number(applied.seconds)]))
            }
            if !commands.isEmpty {
                let files = commands.count == 1 ? "1 file" : "\(commands.count) files"
                // What it does when the files agree; what was asked when their frames differ.
                let landed = Set(wanted.map(\.snapped.delay))
                let named = landed.count == 1 ? landed.first ?? delay : delay
                let label = request.label ?? (named == .zero ? "Picture as recorded on \(files)" : "Picture delay \(SyncResult.milliseconds(named)) on \(files)")
                applied = try apply(ApplyRequest(label: label, commands: commands, expectedRevision: request.expectedRevision), context: context)
            }
            if request.makeDefault == true {
                settings.cameraPictureDelay = delay.seconds
                do {
                    try settings.save()
                } catch {
                    throw ServiceError(.unavailable, "Couldn't save Tandem's settings: \(error.localizedDescription)")
                }
            }
        } else if request.media != nil || request.makeDefault == true {
            throw ServiceError(.badRequest, "Give the delay in seconds too, like tandem sync 0.08.")
        }
        let (project, revision) = coordinator.snapshot()
        let files = project.media.filter { $0.kind == .video && $0.hasVideo }
            .sorted { (Self.isCameraTake($0) ? 0 : 1, $0.path) < (Self.isCameraTake($1) ? 0 : 1, $1.path) }
            .map { SyncFile(id: $0.id, path: $0.path, role: $0.role, pictureDelay: $0.pictureDelay, pictureDelayCorrected: $0.pictureDelayCorrected, frames: PictureDelay.frames(in: $0.pictureDelay ?? .zero, of: $0)) }
        var result = SyncResult(revision: revision, files: files, defaultDelay: Time(seconds: settings.cameraPictureDelay), applied: applied)
        if !rounded.isEmpty { result.rounded = rounded }
        return result
    }

    /// `tandem sync <file>...`: lines files up with the camera by sound,
    /// puts them in its take and places them, as one undo step.
    public func syncBySound(_ request: SyncRequest, context: CallContext) async throws -> SyncResult {
        guard request.delay == nil, request.media == nil, request.makeDefault == nil else {
            throw ServiceError(.badRequest, "Give either a picture delay or files to line up by sound, not both.")
        }
        let (project, revision) = coordinator.snapshot()
        try checkExpected(request.expectedRevision, at: revision)
        let items = try resolveMedia(request.files ?? [], in: project)
        let reference = try soundReference(request.to, for: items, in: project)
        for item in items + [reference] where !item.hasAudio || item.kind == .image {
            throw ServiceError(.badRequest, "\(item.path) has no sound to line up by.")
        }

        let camera = try await loadSound(reference)
        var measured: [(MediaItem, SoundSync.Match)] = []
        for item in items {
            do {
                measured.append((item, try await SoundSync.match(camera, try await loadSound(item))))
            } catch let error as SoundSync.NoMatch {
                throw ServiceError(.invalid, error.localizedDescription)
            }
        }

        // Every file of the take, the camera's included, gets a take
        // offset; if one starts before the take did, they all move up.
        let take = reference.takeID ?? IDs.make("take")
        let cameraOffset = reference.takeID == nil ? Time.zero : (reference.takeOffset ?? .zero)
        var offsets: [String: Time] = [reference.id: cameraOffset]
        for item in project.media where item.takeID == take && offsets[item.id] == nil {
            offsets[item.id] = item.takeOffset ?? .zero
        }
        for (item, match) in measured { offsets[item.id] = cameraOffset - Time(seconds: match.offset) }
        let shift = max(.zero, .zero - (offsets.values.min() ?? .zero))
        // A recorder's file the scan took for music is a voice now.
        let voices = Set(measured.map(\.0).filter { !$0.hasVideo && ($0.role == .music || $0.role == .sfx) }.map(\.id))
        var commands: [EditCommand] = []
        for item in project.media {
            guard let offset = offsets[item.id].map({ $0 + shift }),
                  item.takeID != take || item.takeOffset != offset || voices.contains(item.id) else { continue }
            var patch: [String: JSONValue] = ["takeID": .string(take), "takeOffset": .number(offset.seconds)]
            if voices.contains(item.id) { patch["role"] = .string(MediaRole.other.rawValue) }
            commands.append(.updateMedia(mediaID: item.id, patch: .object(patch)))
        }
        var notes: [String: [String]] = [:]
        let halfFrame = project.settings.frameRate.frameDuration.seconds / 2
        // The file that covers least goes first, so one a frame longer
        // stops at its cut rather than leaving a sliver after it.
        for (item, match) in measured.sorted(by: { $0.1.overlapEnd - $0.1.overlapStart < $1.1.overlapEnd - $1.1.overlapStart }) {
            if let drift = match.drift, abs(drift) > halfFrame {
                notes[item.id, default: []].append("It drifts more than half a frame over the overlap, so it's in step at the middle and slips towards the ends.")
            }
            let placed = project.allTracks.contains { $0.clips.contains { $0.mediaID == item.id } }
            if request.place == false { continue }
            if placed {
                notes[item.id, default: []].append("It was on the timeline already, so its clips were left where they were; check they're in step.")
            } else {
                commands.append(.placeSynced(mediaID: item.id))
            }
        }

        var applied: ApplyResult?
        if !commands.isEmpty {
            let names = measured.count == 1 ? URL(fileURLWithPath: measured[0].0.path).deletingPathExtension().lastPathComponent : "\(measured.count) files"
            let label = request.label ?? "Sync \(names) to \(URL(fileURLWithPath: reference.path).deletingPathExtension().lastPathComponent) by sound"
            applied = try apply(ApplyRequest(label: label, commands: commands, expectedRevision: request.expectedRevision ?? revision, dryRun: request.dryRun), context: context)
        }
        let after = coordinator.snapshot()
        let matches = measured.map { item, match in
            let tracks = applied?.dryRun == false
                ? after.project.allTracks.filter { $0.clips.contains { $0.mediaID == item.id } }.map(\.name)
                : nil
            return SoundMatch(
                id: item.id, path: item.path, offset: match.offset, drift: match.drift, confidence: match.confidence,
                overlapStart: match.overlapStart, overlapEnd: match.overlapEnd, takeID: take,
                takeOffset: (offsets[item.id] ?? .zero) + shift, tracks: tracks, notes: notes[item.id] ?? []
            )
        }
        let settings = TandemSettings.load()
        var result = SyncResult(
            revision: after.revision, files: [], defaultDelay: Time(seconds: settings.cameraPictureDelay),
            applied: applied, matches: matches, reference: reference.path
        )
        // Matching sound says nothing about the sound against the picture: a
        // far camera mic and a camera's own offset both leave a lag it can't
        // see. It's a look, so trouble here doesn't undo the edit just made.
        if request.check != false, request.dryRun != true, request.place != false {
            let pictures = after.project.media.filter { $0.takeID == take && $0.kind == .video && $0.hasVideo && $0.role != .screen }
            do {
                result.lipSync = try await lipSync(pictures, project: after.project, from: nil, until: nil)
            } catch {
                result.lipSyncNote = "Couldn't measure lip sync: \((error as? LocalizedError)?.errorDescription ?? "\(error)"). tandem sync --check tries again."
            }
        }
        return result
    }

    /// The file synced files are lined up with: `to`, or the camera take
    /// (the one on the timeline, when there are several).
    func soundReference(_ to: String?, for items: [MediaItem], in project: Project) throws -> MediaItem {
        if let to {
            guard let found = try resolveMedia([to], in: project).first else { throw ServiceError(.notFound, "No media \(to).") }
            guard !items.contains(where: { $0.id == found.id }) else { throw ServiceError(.badRequest, "\(found.path) can't be lined up with itself.") }
            return found
        }
        let chosen = Set(items.map(\.id))
        let cameras = project.media.filter { Self.isCameraTake($0) && !chosen.contains($0.id) }
        let placed = cameras.filter { camera in project.allTracks.contains { $0.clips.contains { $0.mediaID == camera.id } } }
        if placed.count == 1 { return placed[0] }
        if placed.isEmpty, cameras.count == 1 { return cameras[0] }
        let which = (placed.isEmpty ? cameras : placed).map(\.path).joined(separator: ", ")
        throw ServiceError(.badRequest, cameras.isEmpty
            ? "There's no camera take to line them up with. Name the file with --to."
            : "Which camera take? There are several (\(which)); name one with --to.")
    }

    private func loadSound(_ item: MediaItem) async throws -> SoundSync.Recording {
        let url = folder.url(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ServiceError(.notFound, "\(item.path) is missing. tandem relink finds moved files.")
        }
        do {
            return try await SoundSync.load(url)
        } catch let error as MediaError {
            throw ServiceError(.invalid, "Couldn't read the sound of \(item.path): \(error.localizedDescription)")
        }
    }

    static func isCameraTake(_ item: MediaItem) -> Bool {
        item.role == .camera && item.kind == .video && item.hasVideo
    }
}
