import CoreGraphics
import Foundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia
import TandemRender

func t(_ seconds: Double) -> Time { Time(seconds: seconds) }

/// A temporary folder that removes itself.
final class TempFolder {
    let url: URL

    init(_ name: String = "tandem-api") {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// Mike's usual timeline with fixed IDs, so text output is stable:
/// a 60 s take in two pieces (screen, camera PiP and voice, linked), with
/// 2 s of the take cut out between them, a dissolve on the camera cut, a
/// title, a B-roll shot, a music bed and a section marker.
enum APIFixture {
    static let camera = MediaItem(
        id: "med_camera", path: "source/take1-camera.mov", kind: .video, role: .camera,
        takeID: "take1", takeOffset: t(0.5), duration: t(70), frameRate: .fps30,
        width: 3840, height: 2160, hasVideo: true, hasAudio: true
    )
    static let screen = MediaItem(
        id: "med_screen", path: "source/take1-screen.mov", kind: .video, role: .screen,
        takeID: "take1", takeOffset: t(0), duration: t(71), frameRate: .fps30,
        width: 3840, height: 2160, hasVideo: true, hasAudio: true, variableFrameRate: true
    )
    static let music = MediaItem(id: "med_music", path: "music/bed.m4a", kind: .audio, role: .music, duration: t(180), hasAudio: true)
    static let broll = MediaItem(
        id: "med_broll", path: "broll/servers.mp4", kind: .video, role: .broll,
        duration: t(10), frameRate: .fps30, width: 1920, height: 1080, hasVideo: true, hasAudio: true
    )

    static func pip() -> VideoProperties {
        VideoProperties(
            transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5),
            cutout: Cutout(),
            effects: [Effect(id: "fx_shadow1", type: "dropShadow")],
            layoutPreset: "pipRight"
        )
    }

    static func project() -> Project {
        var project = Project(id: "prj_fixture", name: "Decision Models")
        project.media = [camera, screen, music, broll]
        project.videoTracks = [
            Track(id: "trk_screen", kind: .video, name: "Screen", clips: [
                Clip(id: "clip_scr1", name: "take1-screen", content: .media(mediaID: "med_screen"), start: t(0), duration: t(30), sourceStart: t(0.5), linkGroup: "lnk_a"),
                Clip(id: "clip_scr2", name: "take1-screen", content: .media(mediaID: "med_screen"), start: t(30), duration: t(30), sourceStart: t(32.5), linkGroup: "lnk_b")
            ], rippleMode: .cut),
            Track(id: "trk_camera", kind: .video, name: "Camera", clips: [
                Clip(id: "clip_cam1", name: "take1-camera", content: .media(mediaID: "med_camera"), start: t(0), duration: t(30), sourceStart: t(0), linkGroup: "lnk_a", video: pip()),
                Clip(id: "clip_cam2", name: "take1-camera", content: .media(mediaID: "med_camera"), start: t(30), duration: t(30), sourceStart: t(32), linkGroup: "lnk_b", video: pip())
            ], transitions: [
                Transition(id: "tr_dissolve", type: .dissolve, duration: t(0.5), fromClipID: "clip_cam1", toClipID: "clip_cam2")
            ], rippleMode: .cut),
            Track(id: "trk_broll", kind: .video, name: "B-roll", clips: [
                Clip(id: "clip_brl1", name: "servers", content: .media(mediaID: "med_broll"), start: t(20), duration: t(5), sourceStart: t(1))
            ], rippleMode: .follow),
            Track(id: "trk_graphics", kind: .video, name: "Graphics", rippleMode: .follow),
            Track(id: "trk_text", kind: .video, name: "Text", clips: [
                Clip(id: "clip_txt1", content: .text(TextContent(text: "DECISION MODELS", preset: "callout", animationIn: "popIn")), start: t(2), duration: t(3))
            ], rippleMode: .follow)
        ]
        project.audioTracks = [
            Track(id: "trk_voice", kind: .audio, name: "Voice", clips: [
                Clip(id: "clip_voc1", name: "take1-camera", content: .media(mediaID: "med_camera"), start: t(0), duration: t(30), sourceStart: t(0), linkGroup: "lnk_a", audio: AudioProperties(normalizeTo: -14)),
                Clip(id: "clip_voc2", name: "take1-camera", content: .media(mediaID: "med_camera"), start: t(30), duration: t(30), sourceStart: t(32), linkGroup: "lnk_b", audio: AudioProperties(normalizeTo: -14))
            ], rippleMode: .cut),
            Track(id: "trk_music", kind: .audio, name: "Music", clips: [
                Clip(id: "clip_mus1", name: "bed", content: .media(mediaID: "med_music"), start: t(0), duration: t(60), audio: AudioProperties(gainDB: -31, fadeOut: t(2)))
            ], rippleMode: .follow),
            Track(id: "trk_sfx", kind: .audio, name: "SFX", rippleMode: .follow)
        ]
        project.markers = [Marker(id: "mk_s2", time: t(30), name: "Section 2", kind: .section)]
        return project
    }

    /// What the camera's microphone heard, in file time. Pauses: 3.6-5.0
    /// (1.4 s) and 6.3-7.0 (0.7 s) in the first piece; the cut between the
    /// pieces removes file time 30-32 ("um, wait"), so "section" (ends
    /// 29.9) and "now" (file 32.5, timeline 30.5) are 0.6 s apart.
    static let cameraTranscript = Transcript(language: "en", engine: "fake", words: [
        TranscriptWord(text: "So", start: t(1.0), end: t(1.2)),
        TranscriptWord(text: "today", start: t(1.25), end: t(1.6)),
        TranscriptWord(text: "we", start: t(1.65), end: t(1.8)),
        TranscriptWord(text: "talk", start: t(1.85), end: t(2.2)),
        TranscriptWord(text: "about", start: t(2.25), end: t(2.5)),
        TranscriptWord(text: "decision", start: t(2.55), end: t(3.0)),
        TranscriptWord(text: "models.", start: t(3.05), end: t(3.6)),
        TranscriptWord(text: "They", start: t(5.0), end: t(5.3)),
        TranscriptWord(text: "help", start: t(5.35), end: t(5.6)),
        TranscriptWord(text: "you", start: t(5.65), end: t(5.8)),
        TranscriptWord(text: "choose", start: t(5.85), end: t(6.3)),
        TranscriptWord(text: "fast.", start: t(7.0), end: t(7.5)),
        TranscriptWord(text: "Decision", start: t(7.55), end: t(8.0)),
        TranscriptWord(text: "models", start: t(8.05), end: t(8.5)),
        TranscriptWord(text: "matter.", start: t(8.55), end: t(9.0)),
        TranscriptWord(text: "Second", start: t(29.0), end: t(29.4)),
        TranscriptWord(text: "section.", start: t(29.45), end: t(29.9)),
        TranscriptWord(text: "Um,", start: t(30.5), end: t(30.7)),
        TranscriptWord(text: "wait.", start: t(31.0), end: t(31.4)),
        TranscriptWord(text: "Now", start: t(32.5), end: t(32.8)),
        TranscriptWord(text: "let's", start: t(32.85), end: t(33.1)),
        TranscriptWord(text: "look", start: t(33.15), end: t(33.4)),
        TranscriptWord(text: "at", start: t(33.45), end: t(33.6)),
        TranscriptWord(text: "decision", start: t(33.65), end: t(34.0)),
        TranscriptWord(text: "models", start: t(34.05), end: t(34.5)),
        TranscriptWord(text: "again.", start: t(34.55), end: t(35.0))
    ])

    /// Writes the fixture project to `folder` and returns its URL.
    static func write(to folder: URL, name: String = "Decision Models", project: Project = APIFixture.project()) throws -> URL {
        let url = folder.appendingPathComponent("\(name).tandem")
        try ProjectFile.save(project, revision: 1, to: url)
        return url
    }
}

/// Canned analysis results. Safe to change from another thread, as a
/// test does to finish a job while a call waits for it.
final class FakeAnalysis: AnalysisSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _transcripts: [String: Transcript] = ["med_camera": APIFixture.cameraTranscript]
    // The take is measured, as a real one is long before it's edited:
    // levelled clips from an unmeasured file are warned about and fail check.
    private var _measured: [String: Loudness] = ["med_camera": Loudness(integratedLUFS: -20, truePeakDBTP: -3, loudnessRange: 6)]
    private var _jobList: [JobStatus] = []
    private var _requests: [(kind: AnalysisKind, mediaID: String, priority: JobPriority)] = []
    private var _neededRequests = 0
    private var observers: [UUID: @Sendable ([JobStatus]) -> Void] = [:]
    /// What asking for an analysis does, like finishing it a moment later.
    var onRequest: (@Sendable (AnalysisKind, MediaItem) -> Void)?

    var transcripts: [String: Transcript] {
        get { lock.withLock { _transcripts } }
        set { lock.withLock { _transcripts = newValue } }
    }
    var measured: [String: Loudness] {
        get { lock.withLock { _measured } }
        set { lock.withLock { _measured = newValue } }
    }
    var jobList: [JobStatus] {
        get { lock.withLock { _jobList } }
        set { lock.withLock { _jobList = newValue } }
    }
    /// Every single analysis asked for.
    var requests: [(kind: AnalysisKind, mediaID: String, priority: JobPriority)] { lock.withLock { _requests } }
    /// How many times the project's usual analysis was asked for.
    var neededRequests: Int { lock.withLock { _neededRequests } }

    func transcript(for item: MediaItem) -> Transcript? { transcripts[item.id] }
    func loudness(for item: MediaItem) -> Loudness? { measured[item.id] }

    func isReady(_ kind: AnalysisKind, for item: MediaItem) -> Bool {
        switch kind {
        case .transcript: return transcripts[item.id] != nil
        case .loudness: return measured[item.id] != nil
        default: return false
        }
    }

    var jobs: [JobStatus] { jobList }

    func observeJobs(_ handler: @escaping @Sendable ([JobStatus]) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = handler }
        return token
    }

    func removeJobsObserver(_ token: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }

    func request(_ kind: AnalysisKind, for item: MediaItem, priority: JobPriority) {
        lock.withLock { _requests.append((kind, item.id, priority)) }
        onRequest?(kind, item)
    }

    func requestNeeded(for project: Project) {
        lock.withLock { _neededRequests += 1 }
    }

    /// Pretends the job scheduler moved on.
    func emit(_ jobs: [JobStatus]) {
        let handlers = lock.withLock { () -> [@Sendable ([JobStatus]) -> Void] in
            _jobList = jobs
            return Array(observers.values)
        }
        for handler in handlers { handler(jobs) }
    }

    /// Pretends a transcript job ran and finished.
    func finishTranscript(_ mediaID: String, _ transcript: Transcript) {
        transcripts[mediaID] = transcript
        emit([JobStatus(id: "transcript-\(mediaID)", kind: .transcript, mediaID: mediaID, state: .done, progress: 1)])
    }
}

/// A renderer that makes a 1x1 PNG and a small "movie" file, and says
/// whatever `warnings` holds, as the real one does about the whole project.
struct FakeRenderer: RenderBackend {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    var warnings: [String] = []
    /// What a scan measures, frame by frame; nil makes plain grey frames
    /// over every range.
    var scanned: [FrameStats]?
    /// What a scan of the screen recordings on their own measures (the
    /// scan that asks for scanlines); nil makes plain grey frames.
    var screenScanned: [FrameStats]?
    /// The ranges each scan was asked for, screen scans marked.
    let scans = ScanLog()
    /// The times frames were asked for, and how big.
    let frames = FrameLog()
    /// What each loudness curve, gain check and export was asked for: the
    /// range, and which audio tracks were muted in the project it got.
    let measures = Log<(range: TimeRange, step: Time, muted: [Bool])>()
    let gainRequests = Log<(range: TimeRange, trackIDs: [String])>()
    let exports = Log<(preset: ExportPreset, output: URL, muted: [Bool])>()
    /// What a gain check finds; nil follows every lane.
    var gainChecks: [GainFollow]?

    final class Log<Entry>: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Entry] = []
        func add(_ entry: Entry) { lock.withLock { entries.append(entry) } }
        var all: [Entry] { lock.withLock { entries } }
    }

    /// -30 LUFS every step, silent at the end.
    func loudness(context: RenderContext, range: TimeRange, step: Time) async throws -> MixLoudness {
        measures.add((range, step, context.project.audioTracks.map(\.muted)))
        var points: [LoudnessPoint] = []
        var time = range.start
        while time <= range.end {
            let last = time + step > range.end
            points.append(LoudnessPoint(time: time, momentaryLUFS: last ? nil : -30, shortTermLUFS: last ? nil : -31, peakDBFS: last ? nil : -12))
            time += step
        }
        return MixLoudness(start: range.start, end: range.end, step: step, points: points, integratedLUFS: -30.5, truePeakDBTP: -11)
    }

    func checkGains(context: RenderContext, range: TimeRange, trackIDs: [String]) async throws -> [GainFollow] {
        gainRequests.add((range, trackIDs))
        if let gainChecks { return gainChecks }
        return trackIDs.map { id in
            GainFollow(trackID: id, track: context.project.audioTracks.first { $0.id == id }?.name ?? id, compared: range.duration.seconds, lateBy: nil, worstDB: 0.1, mismatches: [])
        }
    }

    final class FrameLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(time: Time, maxSize: CGSize?)] = []
        func add(_ time: Time, _ maxSize: CGSize?) { lock.withLock { entries.append((time, maxSize)) } }
        var all: [(time: Time, maxSize: CGSize?)] { lock.withLock { entries } }
    }

    final class ScanLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(ranges: [TimeRange], screen: Bool)] = []
        func add(_ ranges: [TimeRange], screen: Bool) { lock.withLock { entries.append((ranges, screen)) } }
        var all: [(ranges: [TimeRange], screen: Bool)] { lock.withLock { entries } }
    }

    func scan(context: RenderContext, ranges: [TimeRange], width: Int, scanlines: Bool) async throws -> [FrameStats] {
        scans.add(ranges, screen: scanlines)
        if scanlines, let screenScanned { return screenScanned }
        if !scanlines, let scanned { return scanned }
        let step = context.project.settings.frameRate.frameDuration
        var frames: [FrameStats] = []
        for range in ranges {
            var time = range.start
            while time < range.end {
                frames.append(FrameStats(time: time, luma: 0.5, brightestTile: 0.5, flatGreen: 0, flatWhite: 0, thumbnail: [UInt8](repeating: 128, count: 4)))
                time += step
            }
        }
        return frames
    }

    func frame(context: RenderContext, at time: Time, maxSize: CGSize?) async throws -> RenderedFrame {
        frames.add(time, maxSize)
        return RenderedFrame(png: Self.png, warnings: warnings)
    }

    func export(context: RenderContext, preset: ExportPreset, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedExport {
        exports.add((preset, output, context.project.audioTracks.map(\.muted)))
        for step in 1...4 { progress(Double(step) / 4) }
        // What reached the renderer, for tests to read back.
        let size = preset.width.map { "\($0)x\(preset.height ?? 0)" } ?? "canvas"
        try Data("fake movie \(preset.name) \(size) \(preset.codec.rawValue) \(preset.videoBitrate) \(context.format ?? "main")".utf8).write(to: output)
        let duration = preset.range?.duration ?? context.project.duration
        let result = ExportResult(path: output.path, duration: duration, integratedLUFS: -14.1, truePeakDBTP: -1.2, elapsed: 0.01)
        return RenderedExport(result: result, warnings: warnings)
    }
}

/// An open fixture project with a service over it.
final class ServiceHarness {
    let folder = TempFolder()
    let url: URL
    let session: ProjectSession
    let service: TandemService
    let analysis = FakeAnalysis()

    init(mode: TandemService.Mode = .hosted, project: Project = APIFixture.project(), renderer: FakeRenderer = FakeRenderer()) throws {
        url = try APIFixture.write(to: folder.url, project: project)
        session = try ProjectSession.open(url, owner: .cli)
        session.autosaveDelay = 3600
        service = TandemService(session: session, mode: mode, analysis: analysis, renderer: renderer)
    }

    func close() {
        service.shutdown()
        session.close()
    }

    var context: CallContext { CallContext(author: "claude") }

    @discardableResult
    func apply(_ commands: EditCommand..., label: String? = nil) throws -> ApplyResult {
        try service.apply(ApplyRequest(label: label, commands: commands), context: context)
    }
}

/// Opens the project headless for one call, the way the CLI does.
func headless<R>(_ url: URL, analysis: FakeAnalysis = FakeAnalysis(), _ body: (TandemService) throws -> R) throws -> R {
    let session = try ProjectSession.open(url, owner: .cli)
    let service = TandemService(session: session, mode: .headless, analysis: analysis, renderer: FakeRenderer())
    defer {
        service.shutdown()
        session.close()
    }
    return try body(service)
}

func assertServiceErrorAsync(_ code: ServiceError.Code, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected a \(code.rawValue) error", file: file, line: line)
    } catch {
        XCTAssertEqual((error as? ServiceError)?.code, code.rawValue, "\(error)", file: file, line: line)
    }
}

func assertServiceError(_ code: ServiceError.Code, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
        XCTAssertEqual((error as? ServiceError)?.code, code.rawValue, "\(error)", file: file, line: line)
    }
}

func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}
