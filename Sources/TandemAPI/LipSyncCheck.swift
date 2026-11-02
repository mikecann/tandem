import Foundation
import TandemCore
import TandemMedia
import TandemRender

// MARK: - tandem sync --check

/// One file's lip sync, measured.
public struct LipSyncFile: Codable, Sendable {
    public var id: String
    public var path: String
    public var pictureDelay: Time?
    /// `inSync`, `off`, `unclear`, or nil when it couldn't be measured
    /// (`reason` says why).
    public var state: LipSync.Assessment.State?
    public var reason: String?
    /// How far the voice is ahead of the lips as it plays, in seconds, from
    /// all the readings together, and what each half of them says on its
    /// own, the lower first. Negative: behind.
    public var voiceLead: Double?
    public var low: Double?
    public var high: Double?
    /// How far that is from what in-sync footage reads.
    public var offBy: Double?
    public var readings: Int
    /// Where on the timeline it looked, the starts of each stretch.
    public var at: [Time]
    /// The picture delay that closes it, and the command that sets it.
    public var fixDelay: Time?
    public var fix: String?
}

extension LipSyncFile {
    fileprivate var summary: String {
        guard let voiceLead, let low, let high else { return "not measured: \(reason ?? "nothing to read")" }
        func ms(_ seconds: Double) -> Int { Int((abs(seconds) * 1000).rounded()) }
        let side = voiceLead >= 0 ? "ahead of" : "behind"
        let range = "halves of the \(readings) reading\(readings == 1 ? "" : "s") say \(Int((low * 1000).rounded())) and \(Int((high * 1000).rounded()))"
        let verdict: String
        switch state {
        case .off: verdict = "OFF by \(ms(offBy ?? 0)) ms"
        case .inSync: verdict = "in sync"
        default: verdict = "unclear: \(reason ?? "the readings disagree")"
        }
        return "voice \(ms(voiceLead)) ms \(side) the lips (\(range)): \(verdict)"
    }
}

extension SyncResult {
    /// Whether a measurement found a file out, for the command's exit code,
    /// as `tandem check` exits 1 on what it finds.
    public var lipSyncIsOff: Bool { lipSync?.contains { $0.state == .off } == true }

    /// The lines `tandem sync --check` adds.
    var lipSyncLines: [String] {
        guard let lipSync else { return lipSyncNote.map { [$0] } ?? [] }
        var lines = ["Lip sync, from mouth opening against the voice as it plays (in-sync footage reads the voice about 13 ms ahead; within 30 ms of that counts):"]
        if lipSync.isEmpty { lines.append("  No camera file on the timeline to measure.") }
        let idWidth = lipSync.map(\.id.count).max() ?? 0
        for file in lipSync {
            lines.append("  \(file.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  \(file.path)  \(file.summary)")
            if let fix = file.fix { lines.append("    Fix: \(fix)") }
        }
        if let lipSyncNote { lines.append(lipSyncNote) }
        return lines
    }
}

/// Where a check gets its voice and its faces. Tests swap in their own.
struct LipSyncSources: Sendable {
    /// The voice as export plays it, mono, timeline seconds from and to.
    var rate: Double
    var voice: @Sendable (_ from: Double, _ to: Double) async throws -> [Float]
    /// Faces in the file, in file time.
    var faces: @Sendable (_ item: MediaItem, _ from: Double, _ to: Double) async throws -> [LipSync.Frame]
}

enum LipSyncCheck {
    /// A file is read a stretch at a time, up to this many (about 45 s for 3
    /// stretches of 20 s of 4K, mostly decoding and Vision), or more if they
    /// say little.
    static let stretches = 3
    static let stretchLength = 20.0
    static let mostStretches = 6
    static let enoughReadings = 6
    /// How many places it listens to before picking the talkiest.
    static let candidates = 9

    /// The files a check looks at by default: cameras, and anything recorded
    /// with them, except a screen (no face) or an image.
    static func measurable(_ project: Project) -> [MediaItem] {
        project.media.filter { item in
            guard item.kind == .video, item.hasVideo else { return false }
            return item.role == .camera || (item.takeID != nil && item.role != .screen)
        }
    }

    /// Where a file's clips can be read at normal speed. An angle that's
    /// turned off still sits in step with the take, so a file that isn't
    /// showing anywhere yet is read from those.
    static func clips(of item: MediaItem, in project: Project, from: Time?, until: Time?) -> [Clip] {
        let all = project.videoTracks.flatMap(\.clips).filter { $0.mediaID == item.id && $0.speed == 1 && !$0.freezeFrame }
        let showing = all.filter(\.enabled)
        return (showing.isEmpty ? all : showing).sorted { $0.start < $1.start }.compactMap { clip in
            var part = clip
            let start = max(clip.start, from ?? clip.start), end = min(clip.end, until ?? clip.end)
            guard end - start >= Time(seconds: 4) else { return nil }
            part.sourceStart = clip.sourceStart + (start - clip.start)
            part.start = start
            part.duration = end - start
            return part
        }
    }

    /// The project without clips' audio effects, for reading the voice. Each
    /// is rendered offline for its whole clip before the first sample comes
    /// back, minutes on a 291-clip timeline with a compressor and a limiter
    /// on every cut, and neither moves the sound in time (they make up their
    /// own latency).
    static func withoutSoundEffects(_ project: Project) -> Project {
        var copy = project
        for track in copy.audioTracks.indices {
            for clip in copy.audioTracks[track].clips.indices {
                copy.audioTracks[track].clips[clip].audio?.effects = []
            }
        }
        return copy
    }

    /// When a file's frame reaches the screen. A timeline frame shows the
    /// last file frame at or before `timeline + sourceStart - start + delay`
    /// (`FrameComposer.mediaTime`), so a frame first appears on the next
    /// timeline frame after that moment, not at it.
    static func shownAt(fileTime: Double, clip: Clip, delay: Time, rate: FrameRate) -> Double {
        let exact = fileTime - clip.sourceStart.seconds - delay.seconds + clip.start.seconds
        let frame = rate.frameDuration.seconds
        // A hair of slack so a frame exactly on a boundary stays on it.
        return ((exact / frame) - 1e-6).rounded(.up) * frame
    }

    /// Evenly placed stretches across the clips, up to `candidates`.
    static func places(in clips: [Clip]) -> [(clip: Clip, start: Double, end: Double)] {
        var places: [(clip: Clip, start: Double, end: Double)] = []
        for clip in clips {
            var start = clip.start.seconds
            while start < clip.end.seconds - 4 {
                places.append((clip, start, min(start + stretchLength, clip.end.seconds)))
                start += stretchLength
            }
        }
        guard places.count > candidates else { return places }
        return (0..<candidates).map { places[$0 * places.count / candidates] }
    }

    /// One file: the talkiest of its places in each third of the timeline
    /// first, so a lag that creeps along the take shows, then the rest until
    /// there are enough readings.
    static func measure(_ item: MediaItem, in project: Project, from: Time?, until: Time?, sources: LipSyncSources) async -> LipSyncFile {
        var file = LipSyncFile(id: item.id, path: item.path, pictureDelay: item.pictureDelay, readings: 0, at: [])
        let found = places(in: clips(of: item, in: project, from: from, until: until))
        guard !found.isEmpty else {
            file.reason = from == nil && until == nil ? "no stretch of it on the timeline long enough, at normal speed" : "no stretch of it long enough in that range"
            return file
        }
        var scored: [(index: Int, voiced: Double, loudness: [Float])] = []
        var failure: String?
        for (index, place) in found.enumerated() {
            do {
                let loudness = LipSync.loudness(try await sources.voice(place.start, place.end), rate: sources.rate)
                scored.append((index, LipSync.voicedShare(loudness), loudness))
            } catch {
                failure = "couldn't render the voice: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
        }
        let thirds = stretches
        var order: [Int] = []
        for third in 0..<thirds {
            let inThird = scored.filter { $0.index * thirds / found.count == third }.max { $0.voiced < $1.voiced }
            if let inThird, inThird.voiced >= LipSync.minimumVoiced { order.append(inThird.index) }
        }
        order += scored.sorted { $0.voiced > $1.voiced }.filter { $0.voiced >= LipSync.minimumVoiced && !order.contains($0.index) }.map(\.index)
        guard !order.isEmpty else {
            file.reason = failure ?? "the voice is quiet everywhere it was sampled"
            return file
        }

        let delay = item.pictureDelay ?? .zero
        var readings: [LipSync.Reading] = []
        var sawFrames = false
        for index in order.prefix(mostStretches) {
            if file.at.count >= stretches, readings.count >= enoughReadings { break }
            let place = found[index]
            let offset = place.clip.sourceStart.seconds - place.clip.start.seconds + delay.seconds
            do {
                let frames = try await sources.faces(item, place.start + offset, place.end + offset)
                sawFrames = sawFrames || frames.contains { !$0.faces.isEmpty }
                let shown = frames.map { LipSync.Frame(time: shownAt(fileTime: $0.time, clip: place.clip, delay: delay, rate: project.settings.frameRate), faces: $0.faces) }
                let loudness = scored.first { $0.index == index }?.loudness ?? []
                readings += LipSync.measure(frames: shown, loudness: loudness, start: place.start)
                file.at.append(Time(seconds: place.start))
            } catch {
                file.reason = "couldn't read its frames: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                return file
            }
        }
        let frameRate = item.frameRate ?? project.settings.frameRate
        guard let assessment = LipSync.assess(readings, frame: frameRate.frameDuration.seconds) else {
            file.reason = sawFrames
                ? "no face's mouth moved with the voice (nobody talking on this camera, or a face too small)"
                : "no face in the stretches read"
            return file
        }
        file.state = assessment.state
        file.voiceLead = assessment.voiceLead
        file.low = assessment.low
        file.high = assessment.high
        file.offBy = assessment.offBy
        file.readings = readings.count
        switch assessment.state {
        case .unclear:
            file.reason = readings.count < 2 ? "only one reading; give it a stretch where one person talks with --from and --to" : "the readings disagree; give it a stretch where one person talks with --from and --to"
        case .off:
            // Lips late means showing later in the file brings them forward.
            // A file with no steady frames has no whole frame to land on, so
            // it gets what was measured.
            let steady = item.frameRate != nil && !item.variableFrameRate
            let fixed = steady
                ? PictureDelay.snapped(delay + Time.frames(Int64(assessment.frames), at: frameRate), for: item).delay
                : delay + Time(seconds: assessment.offBy)
            file.fixDelay = fixed
            file.fix = "tandem sync \(PictureDelay.argument(fixed)) --media \(item.id)"
        case .inSync:
            break
        }
        return file
    }
}

extension TandemService {
    /// `tandem sync --check`: how far the voice is from the lips on each
    /// camera file. Reads only; the fix is `tandem sync <delay> --media`.
    public func syncCheck(_ request: SyncRequest, context: CallContext) async throws -> SyncResult {
        guard request.delay == nil, request.files == nil, request.makeDefault == nil else {
            throw ServiceError(.badRequest, "--check only measures. Run it on its own, with --from, --to and --media if you like.")
        }
        if let from = request.from, let until = request.until, until <= from {
            throw ServiceError(.badRequest, "--to has to be after --from.")
        }
        let (project, revision) = coordinator.snapshot()
        let items: [MediaItem]
        if let ids = request.media {
            items = try resolveMedia(ids, in: project)
            for item in items where !(item.kind == .video && item.hasVideo) {
                throw ServiceError(.badRequest, "\(item.path) has no moving picture to measure.")
            }
        } else {
            items = LipSyncCheck.measurable(project)
        }
        let settings = TandemSettings.load()
        var result = SyncResult(revision: revision, files: [], defaultDelay: Time(seconds: settings.cameraPictureDelay), applied: nil)
        result.check = true
        do {
            result.lipSync = try await lipSync(items, project: project, from: request.from, until: request.until)
        } catch {
            throw ServiceError(.invalid, "Couldn't render the voice to measure lip sync: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        return result
    }

    /// The voice comes from the timeline, as export plays it (the speech
    /// tracks alone, so music doesn't count), and the picture straight from
    /// each file, so an angle that's turned off can still be read.
    func lipSync(_ items: [MediaItem], project: Project, from: Time?, until: Time?) async throws -> [LipSyncFile] {
        guard !items.isEmpty else { return [] }
        let mix = try await CutCheck.Mix.speech(LipSyncCheck.withoutSoundEffects(project), folder: folder, analysis: session.analysis)
        let folder = self.folder
        let sources = LipSyncSources(rate: mix.rate, voice: mix.render) { item, start, end in
            try await LipSync.readFaces(folder.url(for: item), from: start, to: end)
        }
        return await lipSync(items, project: project, from: from, until: until, sources: sources)
    }

    func lipSync(_ items: [MediaItem], project: Project, from: Time?, until: Time?, sources: LipSyncSources) async -> [LipSyncFile] {
        var files: [LipSyncFile] = []
        for item in items {
            files.append(await LipSyncCheck.measure(item, in: project, from: from, until: until, sources: sources))
        }
        return files
    }
}
