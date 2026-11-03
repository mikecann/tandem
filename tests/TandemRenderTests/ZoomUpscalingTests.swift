import AVFoundation
import CoreImage
import XCTest
import TandemCore
@testable import TandemMedia
@testable import TandemRender

/// Zooms into screen recordings: Lanczos when the picture scales up, and an
/// export playing a zoomed clip from its twice-the-size copy.
final class ZoomUpscalingTests: XCTestCase {
    let canvas = CGSize(width: 3840, height: 2160)

    func screen(role: MediaRole = .screen) -> MediaItem {
        MediaItem(id: "med_screen", path: "screen.mov", kind: .video, role: role, duration: t(60), frameRate: .fps30,
                  width: 3200, height: 1800, hasVideo: true)
    }

    func clip(scale: Double = 1, keyframes: [String: [Keyframe]] = [:]) -> Clip {
        Clip(id: "clip_screen", content: .media(mediaID: "med_screen"), start: t(5), duration: t(4), sourceStart: t(10),
             video: VideoProperties(transform: Transform(scale: scale)), keyframes: keyframes)
    }

    // MARK: - Which clips want a copy

    /// Mike's flagged zoom: 3200 px on a 4K timeline at 1.8x is 2.16x.
    func testAZoomIntoAScreenRecordingWantsACopy() {
        XCTAssertEqual(ZoomUpscaling.maxScale(clip(scale: 1.8), item: screen(), canvas: canvas, format: nil), 2.16, accuracy: 0.001)
        XCTAssertTrue(ZoomUpscaling.wants(clip(scale: 1.8), item: screen(), canvas: canvas, format: nil))
    }

    /// Unzoomed it's 1.2x, which the Lanczos resample is enough for.
    func testAnUnzoomedRecordingDoesNot() {
        XCTAssertFalse(ZoomUpscaling.wants(clip(), item: screen(), canvas: canvas, format: nil))
    }

    /// A 1080p review render of the same zoom draws the pixels at 1.08x.
    func testASmallerRenderDoesNot() {
        XCTAssertFalse(ZoomUpscaling.wants(clip(scale: 1.8), item: screen(), canvas: CGSize(width: 1920, height: 1080), format: nil))
    }

    /// The model paints on camera footage.
    func testOnlyScreenRecordings() {
        XCTAssertFalse(ZoomUpscaling.wants(clip(scale: 1.8), item: screen(role: .camera), canvas: canvas, format: nil))
    }

    /// zoomToRegion keyframes the scale; the zoomed end counts.
    func testAKeyframedZoomCounts() {
        let zoom = ["video.transform.scale": [
            Keyframe(time: .zero, value: .number(1), interpolation: .hold),
            Keyframe(time: t(1), value: .number(1), interpolation: .easeInOut),
            Keyframe(time: t(1.5), value: .number(1.8), interpolation: .easeInOut)
        ]]
        XCTAssertEqual(ZoomUpscaling.maxScale(clip(keyframes: zoom), item: screen(), canvas: canvas, format: nil), 2.16, accuracy: 0.001)
    }

    /// The copy covers the segment's source a second past each end, in
    /// whole seconds, so a small trim finds the same copy.
    func testTheSpanCoversTheSegmentWithAMargin() {
        let segment = PlannedSegment(clipID: "clip_screen", mediaID: "med_screen", role: .picture, timeline: TimeRange(start: t(5), end: t(9)),
                                     sourceStart: t(10), speed: 1, freeze: false)
        XCTAssertEqual(ZoomUpscaling.span(for: segment), UpscaleSpan(start: 9, end: 15))
        var trimmed = segment
        trimmed.sourceStart = t(10.2)
        trimmed.timeline = TimeRange(start: t(5), end: t(8.7))
        XCTAssertEqual(ZoomUpscaling.span(for: trimmed), UpscaleSpan(start: 9, end: 15))
        XCTAssertEqual(UpscaleSpan(covering: TimeRange(start: t(-0.5), end: t(0.2))), UpscaleSpan(start: 0, end: 1))
        XCTAssertTrue(UpscaleSpan(start: 9, end: 15).contains(TimeRange(start: t(9), end: t(15))))
        XCTAssertFalse(UpscaleSpan(start: 9, end: 15).contains(TimeRange(start: t(8.9), end: t(12))))
    }

    /// A long transition's handle reaches past the clip; the copy covers it.
    func testACopyCoversTransitionHandles() async throws {
        let media = try TestMedia()
        var item = screen()
        item.path = "screen.mov"
        let a = Clip(id: "clip_a", content: .media(mediaID: "med_screen"), start: .zero, duration: t(10), sourceStart: t(20),
                     video: VideoProperties(transform: Transform(scale: 1.8)))
        let b = Clip(id: "clip_b", content: .media(mediaID: "med_screen"), start: t(10), duration: t(10), sourceStart: t(40),
                     video: VideoProperties(transform: Transform(scale: 1.8)))
        var track = Track(kind: .video, name: "V1", clips: [a, b])
        track.transitions = [Transition(type: .dissolve, duration: t(4), fromClipID: "clip_a", toClipID: "clip_b")]
        let project = Project(name: "Zoom", settings: ProjectSettings(width: 3840, height: 2160, frameRate: .fps30),
                              media: [item], videoTracks: [track], audioTracks: [])
        let context = RenderContext(project: project, folder: media.projectFolder)
        let plan = RenderPlanner.plan(project, format: nil, assets: nil)
        let wanted = ZoomUpscaling.wanted(context, range: nil)
        for segment in plan.videoSegments where segment.role == .picture {
            let range = ZoomUpscaling.sourceRange(of: segment)
            XCTAssertTrue(wanted.contains { $0.span.contains(range) }, "\(segment.clipID) plays \(range), wanted \(wanted.map(\.span))")
        }
    }

    /// Clips cut from one stretch of a take share a copy; one far off gets
    /// its own.
    func testNearbySpansJoin() {
        XCTAssertEqual(ZoomUpscaling.joined([UpscaleSpan(start: 20, end: 25), UpscaleSpan(start: 9, end: 15), UpscaleSpan(start: 14, end: 19),
                                             UpscaleSpan(start: 60, end: 64)]),
                       [UpscaleSpan(start: 9, end: 25), UpscaleSpan(start: 60, end: 64)])
    }

    // MARK: - Lanczos

    /// Scaled up 3x, a hard edge spreads over fewer in-between pixels with
    /// Lanczos than with Core Image's bilinear filter, in the same place.
    func testLanczosKeepsEdgesSharperThanBilinear() {
        let edge = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20)))
        let scale = CGAffineTransform(scaleX: 3, y: 3).concatenating(CGAffineTransform(translationX: 0.25, y: 0))
        let lanczos = edge.tandemLanczos(scale)
        let bilinear = edge.transformed(by: scale)
        XCTAssertTrue(lanczos.extent.contains(bilinear.extent))
        let size = CGSize(width: 120, height: 60)
        func softPixels(_ image: CIImage) -> Int {
            let bitmap = Bitmap(image, size: size)
            return (0..<bitmap.width).filter { x in
                let value = bitmap.bytes[(30 * bitmap.width + x) * 4]
                return value > 20 && value < 235
            }.count
        }
        let sharp = softPixels(lanczos), soft = softPixels(bilinear)
        XCTAssertLessThan(sharp, soft, "Lanczos \(sharp) soft pixels, bilinear \(soft)")
        // The edge is where it was: white left of x = 60, black right.
        let bitmap = Bitmap(lanczos, size: size)
        XCTAssertGreaterThan(bitmap.bytes[(30 * 120 + 50) * 4], 240)
        XCTAssertLessThan(bitmap.bytes[(30 * 120 + 70) * 4], 15)
    }

    /// Nothing leaks past the picture: Core Image clamps reads past an
    /// image's pixels to its edge, which spread a still's edge colour
    /// across the whole frame.
    func testLanczosLeavesTheRestClear() {
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let cg = RenderEngine.context.createCGImage(green, from: green.extent)!
        let still = CIImage(cgImage: cg)
        let placed = still.tandemLanczos(CGAffineTransform(scaleX: 2.8125, y: 2.8125).concatenating(CGAffineTransform(translationX: 70, y: 0)))
        let bitmap = Bitmap(placed, size: CGSize(width: 320, height: 180))
        func greenAt(_ x: Int) -> UInt8 { bitmap.bytes[(90 * 320 + x) * 4 + 1] }
        XCTAssertEqual(greenAt(40), 0)
        XCTAssertGreaterThan(greenAt(160), 250)
    }

    // MARK: - Exports play the copy

    /// A zoomed screen clip plays from its copy when the render asks for
    /// copies (exports do), and from the original otherwise. The copy here
    /// is green and the original red, so the frame says which played.
    func testAZoomedClipPlaysFromItsCopy() async throws {
        let media = try TestMedia()
        try await media.movie("screen.mov", seconds: 3, draw: { _, context in TestMedia.fill(context, 1, 0, 0) })
        let copy = try await media.movie("copy.mov", seconds: 3, size: CGSize(width: 640, height: 360), draw: { _, context in
            TestMedia.fill(context, 0, 1, 0, size: CGSize(width: 640, height: 360))
        })
        var item = media.item("med_screen", "screen.mov", role: .screen, seconds: 3)
        item.width = 320
        item.height = 180
        func project(scale: Double) -> Project {
            let clip = Clip(id: "clip_screen", content: .media(mediaID: "med_screen"), start: .zero, duration: t(2), sourceStart: t(0.5),
                            video: VideoProperties(transform: Transform(scale: scale)))
            return Project(name: "Zoom", settings: ProjectSettings(width: 320, height: 180, frameRate: .fps30),
                           media: [item], videoTracks: [Track(kind: .video, name: "V1", clips: [clip])], audioTracks: [])
        }
        let assets = FakeAssets()
        assets.upscaled["med_screen"] = [(UpscaleSpan(start: 0, end: 4), copy)]

        func green(_ project: Project, copies: Bool) async throws -> Bool {
            var context = RenderContext(project: project, folder: media.projectFolder, assets: assets)
            context.upscalesZooms = copies
            let image = try await FrameRenderer(context: context).image(at: t(1))
            let bitmap = Bitmap(image)
            let i = (bitmap.height / 2 * bitmap.width + bitmap.width / 2) * 4
            return bitmap.bytes[i + 1] > 200 && bitmap.bytes[i] < 60
        }
        let zoomed = project(scale: 2)
        var result = try await green(zoomed, copies: true)
        XCTAssertTrue(result, "the export plays the copy")
        result = try await green(zoomed, copies: false)
        XCTAssertFalse(result, "the viewer plays the original")
        result = try await green(project(scale: 1), copies: true)
        XCTAssertFalse(result, "an unzoomed clip plays the original")
    }

    // MARK: - The job

    /// The copy is twice the size, at the source's frame times with a black
    /// frame held before the span, and the picture survives the model. The
    /// source is still but for a moving square, so after the first frame
    /// only the tiles it crosses go back through the model.
    func testTheJobMakesATwiceTheSizeCopyAtTheSourcesTimes() async throws {
        let media = try TestMedia()
        let size = CGSize(width: 640, height: 520)
        let source = try await media.movie("screen.mov", seconds: 2, size: size, draw: { index, context in
            TestMedia.fill(context, 0.1, 0.1, 0.12, size: size)
            context.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 40, y: 300, width: 200, height: 160))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 30 + index * 2, y: 40, width: 12, height: 12))
        })
        let folder = media.folder.appendingPathComponent("upscaled")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = JobContext(id: "upscale", kind: .upscale, scheduler: nil)
        try await UpscaleJob.run(source: source, span: UpscaleSpan(start: 1, end: 2), into: folder, context: context)

        let copy = AVURLAsset(url: folder.appendingPathComponent(UpscaleJob.file))
        let track = try await copy.loadTracks(withMediaType: .video)[0]
        let natural = try await track.load(.naturalSize)
        XCTAssertEqual(natural, CGSize(width: 1280, height: 1040))
        let times = try XCTUnwrap(MediaProbe.presentationTimes(of: track))
        let sourceTrack = try await AVURLAsset(url: source).loadTracks(withMediaType: .video)[0]
        let sourceTimes = try XCTUnwrap(MediaProbe.presentationTimes(of: sourceTrack))
        let timescale = try await track.load(.naturalTimeScale), sourceScale = try await sourceTrack.load(.naturalTimeScale)
        let shown = sourceTimes.map { Double($0) / Double(sourceScale) }.filter { $0 >= 1 - 1e-6 && $0 < 2 }
        XCTAssertEqual(times.map { Double($0) / Double(timescale) }, [0] + shown)

        // The red block is still red, in the same place at twice the size.
        let generator = AVAssetImageGenerator(asset: copy)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600))
        let bitmap = Bitmap(frame)
        let i = ((380 * 2) * bitmap.width + 140 * 2) * 4
        XCTAssertGreaterThan(bitmap.bytes[i], 180, "red")
        XCTAssertLessThan(bitmap.bytes[i + 1], 90, "red")
    }

    /// On a real project: makes the copies for a stretch of the timeline
    /// (as an export of it would), times them, and writes the frame at
    /// `TANDEM_UPSCALE_AT` from the original and from the copy, as PNGs in
    /// `TANDEM_UPSCALE_OUT`. The copies stay in the project's cache.
    ///
    ///   TANDEM_UPSCALE_PROJECT=path.tandem TANDEM_UPSCALE_RANGE=757.2-759.5 TANDEM_UPSCALE_AT=758 \
    ///   TANDEM_UPSCALE_OUT=/tmp/zoom swift test --filter testARealZoom
    func testARealZoom() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TANDEM_UPSCALE_PROJECT"], let rangeText = env["TANDEM_UPSCALE_RANGE"],
              let at = env["TANDEM_UPSCALE_AT"].flatMap(Double.init), let out = env["TANDEM_UPSCALE_OUT"] else {
            throw XCTSkip("set TANDEM_UPSCALE_PROJECT, _RANGE, _AT and _OUT to run")
        }
        let bounds = rangeText.split(separator: "-").compactMap { Double($0) }
        guard bounds.count == 2, bounds[0] < bounds[1] else {
            return XCTFail("TANDEM_UPSCALE_RANGE should be start-end in seconds, like 757.2-759.5")
        }
        let range = TimeRange(start: t(bounds[0]), end: t(bounds[1]))
        let file = URL(fileURLWithPath: path)
        let project = try ProjectFile.load(from: file).project
        let folder = ProjectFolder(projectFile: file)
        let analysis = MediaAnalysis(folder: folder)
        var context = RenderContext(project: project, folder: folder, analysis: analysis)
        context.upscalesZooms = true
        let wanted = ZoomUpscaling.wanted(context, range: range)
        print("UPSCALE wanted", wanted.map { "\($0.item.path) \($0.span.start)-\($0.span.end)" })
        let started = Date()
        var notes: [String] = []
        for copy in ZoomUpscaling.missingCopies(context, range: range) {
            let last = LastMessage()
            let state = await analysis.waitForUpscale(of: copy.item, span: copy.span) { _, message in last.set(message) }
            notes.append("\(copy.span.start)-\(copy.span.end): \(state), \(last.value ?? "")")
        }
        print("UPSCALE made in \(String(format: "%.1f", Date().timeIntervalSince(started))) s", notes)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for copies in [false, true] {
            context.upscalesZooms = copies
            let png = try await FrameRenderer(context: context).pngData(at: t(at))
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent(copies ? "upscaled.png" : "original.png"))
        }
    }

    /// A rotated recording's transform moves it by its own pixels, so the
    /// copy's moves twice as far and turns the same way.
    func testTheCopyOfARotatedRecordingKeepsItsTurn() {
        let turned = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1800, ty: 0)
        XCTAssertEqual(UpscaleJob.doubled(turned), CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 3600, ty: 0))
        XCTAssertEqual(UpscaleJob.doubled(.identity), .identity)
    }

    /// A small screen recording and an analysis for it, for the waits below.
    func screenRecording(_ media: TestMedia) async throws -> (analysis: MediaAnalysis, item: MediaItem) {
        let size = CGSize(width: 640, height: 520)
        try await media.movie("screen.mov", seconds: 2, size: size, draw: { index, context in
            TestMedia.fill(context, 0.1, 0.1, 0.12, size: size)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 30 + index * 4, y: 40, width: 12, height: 12))
        })
        var item = media.item("med_screen", "screen.mov", role: .screen, seconds: 2)
        item.width = 640
        item.height = 520
        return (MediaAnalysis(folder: media.projectFolder, encoderLock: EncoderLock()), item)
    }

    /// An export that joins a copy another export stopped (the job still
    /// winding down) asks for it again and gets it.
    func testAnExportRejoinsACopyAnotherExportStopped() async throws {
        let media = try TestMedia()
        let (analysis, item) = try await screenRecording(media)
        let span = UpscaleSpan(start: 0, end: 2)
        let waiting = Task { await analysis.waitForUpscale(of: item, span: span) }
        // Stop the job once it's running, as the last other export would.
        var running: JobStatus?
        for _ in 0..<500 where running == nil {
            running = analysis.jobs.first { $0.kind == .upscale && $0.state == .running }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let id = try XCTUnwrap(running?.id, "the copy never started")
        analysis.cancel(jobID: id)
        let state = await waiting.value
        XCTAssertEqual(state, .ready)
        XCTAssertNotNil(analysis.upscaledURL(for: item, covering: span.timeRange))
    }

    /// A stopped export doesn't start a copy.
    func testAStoppedExportStartsNoCopy() async throws {
        let media = try TestMedia()
        let (analysis, item) = try await screenRecording(media)
        let state = await analysis.waitForUpscale(of: item, span: UpscaleSpan(start: 0, end: 2), cancelled: { true })
        XCTAssertEqual(state, .missing)
        XCTAssertTrue(analysis.jobs.filter { $0.kind == .upscale }.isEmpty)
    }

    /// Tiles count as changed past the tolerance, not at HEVC's wobble.
    func testTileComparisonHasATolerance() {
        let a = [UInt8](repeating: 100, count: 200)
        var b = a
        b[150] = 104
        XCTAssertFalse(UpscaleTiles.differs(a, b, by: 6))
        b[3] = 120
        XCTAssertTrue(UpscaleTiles.differs(a, b, by: 6))
        b = a
        b[199] = 90
        XCTAssertTrue(UpscaleTiles.differs(a, b, by: 6), "past the last full 64 bytes")
    }
}

private final class LastMessage: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ message: String?) { lock.withLock { if let message { stored = message } } }
    var value: String? { lock.withLock { stored } }
}
