import AVFoundation
import XCTest
import TandemCore
@testable import TandemMedia
@testable import TandemRender

/// Frames through the real AVFoundation path: composition, custom
/// compositor and AVAssetImageGenerator at zero tolerance.
final class PipelineTests: XCTestCase {
    let size = CGSize(width: 320, height: 180)

    func grab(_ context: RenderContext, _ seconds: Double) async throws -> Bitmap {
        Bitmap(try await FrameRenderer(context: context).image(at: t(seconds)))
    }

    func indexMovie(_ media: TestMedia, seconds: Double = 3) async throws {
        try await media.movie("index.mov", seconds: seconds, draw: { TestMedia.drawIndex($0, $1) })
    }

    func testFrameGrabsAreExact() async throws {
        let media = try TestMedia()
        try await indexMovie(media)
        let clip = Clip(id: "clip_a", content: .media(mediaID: "med_i"), start: .zero, duration: t(2), sourceStart: t(0.5))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_i", "index.mov", seconds: 3)])
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        for (time, expected) in [(0.0, 15), (0.3, 24), (1.0, 45), (1.9667, 74)] {
            let frame = Bitmap(try await renderer.image(at: t(time)))
            XCTAssertEqual(TestMedia.readIndex(frame, in: CGRect(x: 0, y: 0, width: 320, height: 180)), expected, "at \(time)")
        }
        // Past the end clamps to the last frame.
        let last = Bitmap(try await renderer.image(at: t(9)))
        XCTAssertEqual(TestMedia.readIndex(last, in: CGRect(x: 0, y: 0, width: 320, height: 180)), 74)
    }

    func testAFilesPictureDelayShowsLaterFrames() async throws {
        let media = try TestMedia()
        try await indexMovie(media)
        var item = media.item("med_i", "index.mov", seconds: 3)
        item.pictureDelay = t(0.1)
        let clip = Clip(id: "clip_a", content: .media(mediaID: "med_i"), start: .zero, duration: t(2), sourceStart: t(0.5))
        // Used up to the file's end: the delay reaches past its last frame.
        let tail = Clip(id: "clip_b", content: .media(mediaID: "med_i"), start: t(2), duration: t(0.5), sourceStart: t(2.5))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip, tail])], media: [item])
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        // 0.1 s is three frames at 30 fps: frame 15 becomes 18. Past the
        // file's last frame (89), that frame holds.
        for (time, expected) in [(0.0, 18), (1.0, 48), (2.0, 78), (2.45, 89)] {
            let frame = Bitmap(try await renderer.image(at: t(time)))
            XCTAssertEqual(TestMedia.readIndex(frame, in: CGRect(x: 0, y: 0, width: 320, height: 180)), expected, "at \(time)")
        }
    }

    /// Why `tandem sync` rounds to whole frames: a delay between two frames
    /// moves a clip by one or the other depending where it starts between its
    /// file's frames, and a whole number of frames moves every clip the same.
    func testAWholeFrameDelayMovesEveryClipTheSameAndOneBetweenFramesDoesnt() async throws {
        let media = try TestMedia()
        try await indexMovie(media)
        let whole = CGRect(x: 0, y: 0, width: 320, height: 180)
        func moved(delay: Double, phase: Double) async throws -> Int {
            func index(_ delay: Double) async throws -> Int {
                var item = media.item("med_i", "index.mov", seconds: 3)
                item.pictureDelay = t(delay)
                let clip = Clip(id: "clip_a", content: .media(mediaID: "med_i"), start: .zero, duration: t(1), sourceStart: t(0.5 + phase))
                let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [item])
                return TestMedia.readIndex(Bitmap(try await FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder)).image(at: .zero)), in: whole)
            }
            let shifted = try await index(delay)
            let plain = try await index(0)
            return shifted - plain
        }
        for phase in [0.0, 0.01, 0.02, 0.03] {
            let two = try await moved(delay: 2.0 / 30, phase: phase)
            XCTAssertEqual(two, 2, "two frames from \(phase) past a frame")
        }
        let onAFrame = try await moved(delay: 0.057, phase: 0)
        let pastAFrame = try await moved(delay: 0.057, phase: 0.02)
        XCTAssertEqual(onAFrame, 1)
        XCTAssertEqual(pastAFrame, 2, "the same delay, a frame further")
    }

    func testSpeedAndFreezeFrames() async throws {
        let media = try TestMedia()
        try await indexMovie(media, seconds: 4)
        let fast = Clip(id: "clip_f", content: .media(mediaID: "med_i"), start: .zero, duration: t(1), sourceStart: t(0.2), speed: 2)
        var frozen = Clip(id: "clip_z", content: .media(mediaID: "med_i"), start: t(1), duration: t(1), sourceStart: t(1.5))
        frozen.freezeFrame = true
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [fast, frozen])], media: [media.item("med_i", "index.mov", seconds: 4)])
        let context = RenderContext(project: project, folder: media.projectFolder)
        let whole = CGRect(x: 0, y: 0, width: 320, height: 180)
        // Twice as fast: 0.5 s into the clip is 1 s into the media after 0.2.
        let fastFrame = try await grab(context, 0.5)
        XCTAssertEqual(TestMedia.readIndex(fastFrame, in: whole), 36)
        let frozenStart = try await grab(context, 1.1)
        let frozenEnd = try await grab(context, 1.9)
        XCTAssertEqual(TestMedia.readIndex(frozenStart, in: whole), 45)
        XCTAssertEqual(TestMedia.readIndex(frozenEnd, in: whole), 45)
    }

    func testPiPOverScreen() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 2, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.movie("blue.mov", seconds: 2, draw: { TestMedia.fill($1, 0, 0, 1) })
        let screen = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(2))
        let camera = Clip(id: "clip_c", content: .media(mediaID: "med_b"), start: .zero, duration: t(2),
                          video: VideoProperties(transform: Transform(position: Point(x: 0.75, y: 0.75), scale: 0.5)))
        let project = smallProject(
            video: [Track(kind: .video, name: "Screen", clips: [screen]), Track(kind: .video, name: "Camera", clips: [camera])],
            media: [media.item("med_r", "red.mov", seconds: 2), media.item("med_b", "blue.mov", seconds: 2)]
        )
        let frame = try await grab(RenderContext(project: project, folder: media.projectFolder), 1)
        assertColor(frame[240, 135], [0, 0, 255], tolerance: 8)
        assertColor(frame[60, 60], [255, 0, 0], tolerance: 8)
        assertColor(frame[150, 135], [255, 0, 0], tolerance: 8)
    }

    func testDissolveUsesBothClipsAtOnce() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 4, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.movie("green.mov", seconds: 4, draw: { TestMedia.fill($1, 0, 1, 0) })
        let a = Clip(id: "clip_a", content: .media(mediaID: "med_r"), start: .zero, duration: t(2), sourceStart: t(1))
        let b = Clip(id: "clip_b", content: .media(mediaID: "med_g"), start: t(2), duration: t(1), sourceStart: t(1))
        let dissolve = Transition(type: .dissolve, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b")
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [a, b], transitions: [dissolve])],
            media: [media.item("med_r", "red.mov", seconds: 4), media.item("med_g", "green.mov", seconds: 4)]
        )
        let context = RenderContext(project: project, folder: media.projectFolder)
        let built = try await CompositionBuilder.build(context)
        // Base plus A and B.
        XCTAssertEqual(built.composition.tracks(withMediaType: .video).count, 3)
        assertColor(try await grab(context, 2)[160, 90], [128, 128, 0], tolerance: 8)
        assertColor(try await grab(context, 1.2)[160, 90], [255, 0, 0], tolerance: 8)
        assertColor(try await grab(context, 2.8)[160, 90], [0, 255, 0], tolerance: 8)
    }

    /// A push up at the end of an overlay with nothing after it: the
    /// overlay leaves upwards and the track below shows where it was, as
    /// Filmora does.
    func testAPushAtAnOverlaysEndRevealsTheTrackBelow() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 4, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.movie("green.mov", seconds: 4, draw: { TestMedia.fill($1, 0, 1, 0) })
        let below = Clip(id: "clip_below", content: .media(mediaID: "med_r"), start: .zero, duration: t(3))
        let overlay = Clip(id: "clip_over", content: .media(mediaID: "med_g"), start: .zero, duration: t(2))
        let out = Transition(type: .push, direction: .up, duration: t(1), fromClipID: "clip_over", toClipID: nil)
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [below]), Track(kind: .video, name: "V2", clips: [overlay], transitions: [out])],
            media: [media.item("med_r", "red.mov", seconds: 4), media.item("med_g", "green.mov", seconds: 4)]
        )
        let context = RenderContext(project: project, folder: media.projectFolder)
        assertColor(try await grab(context, 0.5)[160, 170], [0, 255, 0], tolerance: 8, "the overlay, before it goes")
        let leaving = try await grab(context, 1.75)
        assertColor(leaving[160, 10], [0, 255, 0], tolerance: 8, "what's left of it, at the top")
        assertColor(leaving[160, 170], [255, 0, 0], tolerance: 8, "the track below, where it was")
        assertColor(try await grab(context, 2.5)[160, 90], [255, 0, 0], tolerance: 8, "gone")
    }

    /// A transition on a cut where neither clip has frames past it: the
    /// first clip is used to its last frame and the second from its first.
    /// Each holds its edge frame, so the dissolve blends the two the whole
    /// way through instead of fading from or to black.
    func testATransitionHoldsTheEdgeFramesWhereTheFilesEnd() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 2, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.movie("green.mov", seconds: 2, draw: { TestMedia.fill($1, 0, 1, 0) })
        let a = Clip(id: "clip_a", content: .media(mediaID: "med_r"), start: .zero, duration: t(2))
        let b = Clip(id: "clip_b", content: .media(mediaID: "med_g"), start: t(2), duration: t(1.5))
        let dissolve = Transition(type: .dissolve, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b")
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [a, b], transitions: [dissolve])],
            media: [media.item("med_r", "red.mov", seconds: 2), media.item("med_g", "green.mov", seconds: 2)]
        )
        let context = RenderContext(project: project, folder: media.projectFolder)
        // A quarter in: the green clip's first frame, held, is a quarter of it.
        assertColor(try await grab(context, 1.75)[160, 90], [191, 64, 0], tolerance: 10)
        assertColor(try await grab(context, 2)[160, 90], [128, 128, 0], tolerance: 10)
        // Three quarters in: the red clip's last frame, held.
        assertColor(try await grab(context, 2.25)[160, 90], [64, 191, 0], tolerance: 10)
    }

    /// A clip that holds its edges runs past both ends of its file: its
    /// first frame shows before the file starts and its last after it ends.
    func testAClipThatHoldsItsEdgesShowsItsFirstAndLastFrames() async throws {
        let media = try TestMedia()
        // Red for the first second, green for the second.
        try await media.movie("turns.mov", seconds: 2, draw: { frame, c in
            frame < 30 ? TestMedia.fill(c, 1, 0, 0) : TestMedia.fill(c, 0, 1, 0)
        })
        let clip = Clip(id: "clip_h", content: .media(mediaID: "med_t"), start: .zero, duration: t(4), sourceStart: t(-1), holdEdges: true)
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [clip])],
            media: [media.item("med_t", "turns.mov", seconds: 2)]
        )
        XCTAssertTrue(ProjectValidator.validate(project).filter { $0.severity == .error }.isEmpty)
        let context = RenderContext(project: project, folder: media.projectFolder)
        assertColor(try await grab(context, 0.5)[160, 90], [255, 0, 0], tolerance: 8)
        assertColor(try await grab(context, 1.5)[160, 90], [255, 0, 0], tolerance: 8)
        assertColor(try await grab(context, 2.5)[160, 90], [0, 255, 0], tolerance: 8)
        assertColor(try await grab(context, 3.5)[160, 90], [0, 255, 0], tolerance: 8)
    }

    func testCutoutWithAMatteFile() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 2, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.movie("blue.mov", seconds: 2, draw: { TestMedia.fill($1, 0, 0, 1) })
        // The matte: the "person" is the left half.
        let matte = try await media.movie("matte.mov", seconds: 2, size: CGSize(width: 160, height: 90), draw: { _, c in
            TestMedia.fill(c, 0, 0, 0, size: CGSize(width: 160, height: 90))
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 80, height: 90))
        })
        let screen = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(2))
        let camera = Clip(id: "clip_c", content: .media(mediaID: "med_b"), start: .zero, duration: t(2),
                          video: VideoProperties(cutout: Cutout(edgeFeather: 0)))
        let project = smallProject(
            video: [Track(kind: .video, name: "Screen", clips: [screen]), Track(kind: .video, name: "Camera", clips: [camera])],
            media: [media.item("med_r", "red.mov", seconds: 2), media.item("med_b", "blue.mov", seconds: 2)]
        )
        let assets = FakeAssets()
        assets.mattes["med_b"] = matte
        let frame = try await grab(RenderContext(project: project, folder: media.projectFolder, assets: assets), 1)
        assertColor(frame[60, 90], [0, 0, 255], tolerance: 8)
        assertColor(frame[260, 90], [255, 0, 0], tolerance: 8)
    }

    func testCutoutUsesTheMatteMadeInItsMode() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 1, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.movie("blue.mov", seconds: 1, draw: { TestMedia.fill($1, 0, 0, 1) })
        func matte(_ name: String, leftHalf: Bool) async throws -> URL {
            try await media.movie(name, seconds: 1, size: CGSize(width: 160, height: 90), draw: { _, c in
                TestMedia.fill(c, 0, 0, 0, size: CGSize(width: 160, height: 90))
                c.setFillColor(CGColor(gray: 1, alpha: 1))
                c.fill(CGRect(x: leftHalf ? 0 : 80, y: 0, width: 80, height: 90))
            })
        }
        let withProps = try await matte("props.mov", leftHalf: true)
        let personOnly = try await matte("person.mov", leftHalf: false)
        let screen = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(1))
        let camera = Clip(id: "clip_c", content: .media(mediaID: "med_b"), start: .zero, duration: t(1),
                          video: VideoProperties(cutout: Cutout(mode: .person, edgeFeather: 0)))
        let project = smallProject(
            video: [Track(kind: .video, name: "Screen", clips: [screen]), Track(kind: .video, name: "Camera", clips: [camera])],
            media: [media.item("med_r", "red.mov", seconds: 1), media.item("med_b", "blue.mov", seconds: 1)]
        )
        let assets = FakeAssets()
        assets.mattes["med_b"] = withProps
        assets.personMattes["med_b"] = personOnly
        let frame = try await grab(RenderContext(project: project, folder: media.projectFolder, assets: assets), 0.5)
        assertColor(frame[60, 90], [255, 0, 0], tolerance: 8)
        assertColor(frame[260, 90], [0, 0, 255], tolerance: 8)
        // Only the default matte made so far: use it rather than no cutout.
        assets.personMattes = [:]
        let fallback = try await grab(RenderContext(project: project, folder: media.projectFolder, assets: assets), 0.5)
        assertColor(fallback[60, 90], [0, 0, 255], tolerance: 8)
        assertColor(fallback[260, 90], [255, 0, 0], tolerance: 8)
    }

    func testProxiesAreUsedForPlaybackOnly() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 2, draw: { TestMedia.fill($1, 1, 0, 0) })
        let proxy = try await media.movie("proxy.mov", seconds: 2, draw: { TestMedia.fill($1, 0, 1, 0) })
        let clip = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_r", "red.mov", seconds: 2)])
        let assets = FakeAssets()
        assets.proxies["med_r"] = proxy
        let playback = RenderContext(project: project, folder: media.projectFolder, useProxies: true, assets: assets)
        assertColor(try await grab(playback, 1)[160, 90], [0, 255, 0], tolerance: 8)
        let export = RenderContext(project: project, folder: media.projectFolder, useProxies: false, assets: assets)
        assertColor(try await grab(export, 1)[160, 90], [255, 0, 0], tolerance: 8)
    }

    func testRotatedPhoneClipIsShownUpright() async throws {
        let media = try TestMedia()
        let url = media.folder.appendingPathComponent("phone.mov")
        // Encoded landscape: top half red, bottom half blue.
        try await media.movie("phone-raw.mov", seconds: 1, draw: { _, c in
            TestMedia.fill(c, 0, 0, 1)
            c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 320, height: 90))
        })
        // Copy with a 90 degree preferred transform, as a phone writes it.
        let raw = AVURLAsset(url: media.folder.appendingPathComponent("phone-raw.mov"))
        let composition = AVMutableComposition()
        let source = try await raw.loadTracks(withMediaType: .video)[0]
        let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try track.insertTimeRange(try await source.load(.timeRange), of: source, at: .zero)
        track.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await export.export(to: url, as: .mov)

        let clip = Clip(id: "clip_p", content: .media(mediaID: "med_p"), start: .zero, duration: t(1))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_p", "phone.mov", seconds: 1)])
        let frame = try await grab(RenderContext(project: project, folder: media.projectFolder), 0.5)
        // Upright 180x320 fitted into 320x180: about 101 wide, centred.
        // The encoded top edge is now on the right.
        assertColor(frame[190, 90], [255, 0, 0], tolerance: 8)
        assertColor(frame[130, 90], [0, 0, 255], tolerance: 8)
        assertColor(frame[20, 90], [0, 0, 0], tolerance: 4)
    }

    func testGrabsScaleDownToAMaximumSize() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 1, draw: { TestMedia.fill($1, 1, 0, 0) })
        let clip = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(1))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_r", "red.mov", seconds: 1)])
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        let small = try await renderer.image(at: t(0.5), maxSize: CGSize(width: 160, height: 160))
        XCTAssertEqual(small.width, 160)
        XCTAssertEqual(small.height, 90)
        assertColor(Bitmap(small)[80, 45], [255, 0, 0], tolerance: 8)
        let png = try await renderer.pngData(at: t(0.5))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testVideoCompositionPassesAVFoundationValidation() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 4, draw: { TestMedia.fill($1, 1, 0, 0) }, sound: { _ in 0.05 })
        let a = Clip(id: "clip_a", content: .media(mediaID: "med_r"), start: .zero, duration: t(2), sourceStart: t(1))
        let b = Clip(id: "clip_b", content: .media(mediaID: "med_r"), start: t(2), duration: t(1), sourceStart: t(2))
        let title = Clip(id: "clip_t", content: .text(TextContent(text: "Hi")), start: t(0.5), duration: t(3))
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [a, b], transitions: [Transition(type: .push, duration: t(0.6), fromClipID: "clip_a", toClipID: "clip_b")]),
                    Track(kind: .video, name: "Text", clips: [title])],
            audio: [Track(kind: .audio, name: "A1", clips: [Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(3))])],
            media: [media.item("med_r", "red.mov", seconds: 4, audio: true)]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        let tracks = try await built.composition.load(.tracks)
        let valid = built.videoComposition.isValid(for: tracks, assetDuration: built.composition.duration, timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), validationDelegate: nil)
        XCTAssertTrue(valid)
    }

    /// The coordinators Shorts (20 Nov 2026) ended at 66.666 s, under a
    /// millisecond short of frame 2000. The last clip's end moves onto that
    /// frame, so the timeline's end has to as well: with the clip running
    /// past the last instruction AVFoundation rejects the video composition
    /// and the viewer plays black, while export and stills look fine.
    func testATimelineEndingJustShortOfAFrameStillPlays() async throws {
        let media = try TestMedia()
        try await media.movie("green.mov", seconds: 3, draw: { TestMedia.fill($1, 0, 1, 0) })
        let end = t(2 - 0.0007)
        let clip = Clip(id: "clip_g", content: .media(mediaID: "med_g"), start: .zero, duration: end)
        let title = Clip(id: "clip_t", content: .text(TextContent(text: "Hi")), start: t(1), duration: end - t(1))
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [clip]), Track(kind: .video, name: "Text", clips: [title])],
            media: [media.item("med_g", "green.mov", seconds: 3)]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        let tracks = try await built.composition.load(.tracks)
        let valid = built.videoComposition.isValid(for: tracks, assetDuration: built.composition.duration, timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), validationDelegate: nil)
        XCTAssertTrue(valid, "instructions end at \(built.videoComposition.instructions.last?.timeRange.end.seconds ?? 0), tracks at \(built.composition.duration.seconds)")
        XCTAssertEqual(built.warnings, [])

        // Had it been invalid, the viewer's status bar would say so.
        let short = AVMutableVideoComposition()
        short.renderSize = CGSize(width: 320, height: 180)
        short.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        short.instructions = [instruction]
        let problem = await CompositionAssembler.invalidity(of: short, in: built.composition)
        XCTAssertEqual(problem, "no instruction for 1.0000-2.0000 s")

        let playerItem = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        playerItem.add(output)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        await player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = 1
        var frames = 0
        let started = Date()
        while Date().timeIntervalSince(started) < 0.6 {
            let now = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: now), output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil { frames += 1 }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        player.pause()
        XCTAssertGreaterThan(frames, 5, "frames shown while playing")
    }

    /// A dissolve longer than twice the last clip: the clip before plays its
    /// handle on past the timeline's end, so the instructions run that far.
    func testATransitionHandlePastTheEndStillPlays() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 8, draw: { TestMedia.fill($1, 1, 0, 0) })
        let a = Clip(id: "clip_a", content: .media(mediaID: "med_r"), start: .zero, duration: t(5), sourceStart: t(1))
        let b = Clip(id: "clip_b", content: .media(mediaID: "med_r"), start: t(5), duration: t(0.2), sourceStart: t(6))
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [a, b], transitions: [Transition(type: .dissolve, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b")])],
            media: [media.item("med_r", "red.mov", seconds: 8)]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        let tracks = try await built.composition.load(.tracks)
        let valid = built.videoComposition.isValid(for: tracks, assetDuration: built.composition.duration, timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), validationDelegate: nil)
        XCTAssertTrue(valid, "instructions end at \(built.videoComposition.instructions.last?.timeRange.end.seconds ?? 0), tracks at \(built.composition.duration.seconds)")
    }

    /// A 3 s movie of numbered frames, proxied as the app does (a keyframe
    /// every 15 frames, P-frames between), and a context reading the proxy.
    func proxied(_ media: TestMedia, _ project: (MediaItem) -> Project) async throws -> RenderContext {
        let source = try await media.movie("screen.mov", seconds: 3, draw: { TestMedia.drawIndex($0, $1) })
        let folder = media.folder.appendingPathComponent("proxy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await ProxyJob.run(source: source, settings: .standard, into: folder, context: JobContext(id: "proxy", kind: .proxy, scheduler: nil))
        let assets = FakeAssets()
        assets.proxies["med_s"] = folder.appendingPathComponent(ProxyJob.file)
        return RenderContext(project: project(media.item("med_s", "screen.mov", seconds: 3)), folder: media.projectFolder, useProxies: true, assets: assets)
    }

    func index(_ pixels: CVPixelBuffer) -> Int {
        TestMedia.readIndex(Bitmap(CIImage(cvPixelBuffer: pixels), size: CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))),
                            in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)))
    }

    /// The coordinators Schedules Short (20 Nov 2026) held one screen frame
    /// at 7:45 under 23 cuts in the talk. On the composition's track, as one
    /// proxy P-frame stretched, a player or reader starting partway through
    /// it could stall before asking for a frame, and showed black. A freeze
    /// isn't on the track now: the compositor decodes its picture itself.
    func testAReaderStartingInsideALongFreezeOfAProxyFrameGetsItsPicture() async throws {
        let media = try TestMedia()
        let context = try await proxied(media) { item in
            let freeze = Clip(id: "clip_f", content: .media(mediaID: "med_s"), start: .zero, duration: t(12.87), sourceStart: t(1.3), freezeFrame: true)
            return smallProject(video: [Track(kind: .video, name: "Screen", clips: [freeze])], media: [item])
        }
        let built = try await CompositionBuilder.build(context)
        let indices = try await withDeadline(seconds: 30, "reading from 10 s") {
            let reader = try AVAssetReader(asset: built.composition)
            reader.timeRange = CMTimeRange(start: t(10).cmTime, end: t(10.5).cmTime)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video), videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            output.videoComposition = built.videoComposition
            reader.add(output)
            reader.startReading()
            var found: [Int] = []
            while let sample = output.copyNextSampleBuffer() {
                if let pixels = CMSampleBufferGetImageBuffer(sample) { found.append(self.index(pixels)) }
            }
            return found
        }
        XCTAssertGreaterThan(indices.count, 10)
        XCTAssertEqual(Set(indices), [39], "frame 39 is the one at 1.3 s")
    }

    /// Freezes of two P-frames by turns (cuts in the talk over two held
    /// screens): the player, started partway into one, shows each picture.
    func testThePlayerShowsFreezesOfProxyFramesByTurns() async throws {
        let media = try TestMedia()
        let context = try await proxied(media) { item in
            let clips = (0..<12).map { i in
                Clip(id: "clip_\(i)", content: .media(mediaID: "med_s"), start: t(Double(i) * 0.5), duration: t(0.5), sourceStart: t(i % 2 == 0 ? 1.3 : 1.7), freezeFrame: true)
            }
            return smallProject(video: [Track(kind: .video, name: "Screen", clips: clips)], media: [item])
        }
        let built = try await CompositionBuilder.build(context)
        let playerItem = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        playerItem.add(output)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        await player.seek(to: t(2.3).cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        var shown: [(time: Double, index: Int)] = []
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, player.currentTime().seconds < 4.4 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let now = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: now), let pixels = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) {
                shown.append((now.seconds, index(pixels)))
            }
        }
        player.pause()
        XCTAssertGreaterThan(shown.count, 10, "frames shown while playing")
        // Clips change every half second, even ones on 1.3 s (frame 39).
        // Away from the cuts, so a frame's own timing can't blur it.
        for frame in shown {
            let phase = frame.time.truncatingRemainder(dividingBy: 0.5)
            guard phase > 0.05, phase < 0.45 else { continue }
            let expected = Int(frame.time / 0.5) % 2 == 0 ? 39 : 51
            XCTAssertEqual(frame.index, expected, "at \(frame.time)")
        }
    }

    /// A freeze shows one frame of its file: the one at its time, however
    /// fast the file runs. A project frame's worth of a 60 fps file used to
    /// play its two frames across the freeze.
    func testAFreezeOfAFastFileShowsOneFrame() async throws {
        let media = try TestMedia()
        try await media.movie("fast.mov", seconds: 2, fps: 60, draw: { TestMedia.drawIndex($0, $1) })
        let freeze = Clip(id: "clip_f", content: .media(mediaID: "med_f"), start: .zero, duration: t(2), sourceStart: t(1), freezeFrame: true)
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [freeze])], media: [media.item("med_f", "fast.mov", seconds: 2)])
        let context = RenderContext(project: project, folder: media.projectFolder)
        for time in [0.0, 0.5, 1.0, 1.9] {
            let frame = try await grab(context, time)
            XCTAssertEqual(TestMedia.readIndex(frame, in: CGRect(x: 0, y: 0, width: 320, height: 180)), 60, "at \(time)")
        }
        let frames = try await FrameScanner.scan(context, ranges: [TimeRange(start: .zero, end: t(2))], width: 64)
        XCTAssertEqual(frames.count, 60)
        XCTAssertTrue(QualityCheck.frameProblems(frames, in: project).isEmpty, "\(QualityCheck.frameProblems(frames, in: project).map(\.message))")
    }

    /// An HLG take (an iPhone's HDR) looks the same paused, playing and
    /// exported, and as exports always have. AVFoundation used to convert
    /// it brighter for stills and the player than for an export's reader
    /// (a warm grey 154/116/78 in a still, 135/83/52 exported, 20 Nov 2026).
    func testAnHLGTakeLooksTheSameInStillsThePlayerAndExports() async throws {
        let fills: [(String, (CGFloat, CGFloat, CGFloat), [Int])] = [
            ("warm", (0.6, 0.45, 0.3), [135, 83, 52]),
            ("bright", (0.9, 0.9, 0.9), [215, 213, 213]),
            ("dark", (0.15, 0.2, 0.1), [23, 47, 14])
        ]
        for (label, fill, exported) in fills {
            let media = try TestMedia()
            try await media.movie("hlg.mov", seconds: 2, hlg: true, draw: { _, c in TestMedia.fill(c, fill.0, fill.1, fill.2) })
            let clip = Clip(id: "clip_h", content: .media(mediaID: "med_h"), start: .zero, duration: t(2))
            let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_h", "hlg.mov", seconds: 2)])
            let context = RenderContext(project: project, folder: media.projectFolder)
            let still = try await grab(context, 1)[160, 90]
            let playing = try await playerFrame(context, at: t(1))[160, 90]
            let built = try await CompositionBuilder.build(context)
            let reader = try AVAssetReader(asset: built.composition)
            reader.timeRange = CMTimeRange(start: .zero, end: t(1.1).cmTime)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video), videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            output.videoComposition = built.videoComposition
            reader.add(output)
            reader.startReading()
            var last: CVPixelBuffer?
            while let sample = output.copyNextSampleBuffer() { last = CMSampleBufferGetImageBuffer(sample) ?? last }
            let read = Bitmap(CIImage(cvPixelBuffer: try XCTUnwrap(last)), size: size)[160, 90]
            for channel in 0..<3 {
                XCTAssertEqual(read[channel], exported[channel], accuracy: 3, "\(label) exported, as it always has been")
                XCTAssertEqual(still[channel], read[channel], accuracy: 3, "\(label) still")
                XCTAssertEqual(playing[channel], read[channel], accuracy: 3, "\(label) playing")
            }
        }
    }

    /// A freeze of an HDR take (an iPhone's HLG) looks like the same frame
    /// playing, though its picture comes through the compositor's own
    /// reader: in a still, the player and a scan.
    func testAFreezeOfAnHLGTakeMatchesItPlaying() async throws {
        let media = try TestMedia()
        try await media.movie("hlg.mov", seconds: 3, hlg: true, draw: { _, c in TestMedia.fill(c, 0.6, 0.45, 0.3) })
        let clips = [
            Clip(id: "clip_p", content: .media(mediaID: "med_h"), start: .zero, duration: t(3)),
            Clip(id: "clip_f", content: .media(mediaID: "med_h"), start: t(3), duration: t(1), sourceStart: t(2.5), freezeFrame: true),
            Clip(id: "clip_e", content: .media(mediaID: "med_h"), start: t(4), duration: t(1), sourceStart: t(0.1), freezeFrame: true)
        ]
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: clips)], media: [media.item("med_h", "hlg.mov", seconds: 3)])
        let context = RenderContext(project: project, folder: media.projectFolder)
        let playing = try await grab(context, 2.5)
        for time in [3.5, 4.5] {
            let frozen = try await grab(context, time)
            for (x, y) in [(40, 40), (160, 90), (280, 140)] {
                for channel in 0..<3 {
                    XCTAssertEqual(Int(frozen[x, y][channel]), Int(playing[x, y][channel]), accuracy: 3, "at \(time), \(x),\(y)")
                }
            }
        }
        let playerPlaying = try await playerFrame(context, at: t(2.5))
        let playerFrozen = try await playerFrame(context, at: t(3.5))
        for channel in 0..<3 {
            XCTAssertEqual(Int(playerFrozen[160, 90][channel]), Int(playerPlaying[160, 90][channel]), accuracy: 3, "in the player")
        }
        // And read straight through, as an export or check reads.
        let stats = try await FrameScanner.scan(context, ranges: [TimeRange(start: t(2), end: t(5))], width: 64)
        let means = stats.map(\.luma)
        let reference = try XCTUnwrap(means.first)
        for (index, mean) in means.enumerated() {
            XCTAssertEqual(mean, reference, accuracy: 0.02, "frame \(index) of the scan")
        }
    }

    /// A freeze's picture is kept between frames, but not past its file
    /// changing: a file replaced at the same path shows its own frame.
    func testAFreezeShowsANewFileAtTheSamePath() async throws {
        let media = try TestMedia()
        try await indexMovie(media)
        let freeze = Clip(id: "clip_f", content: .media(mediaID: "med_i"), start: .zero, duration: t(2), sourceStart: t(1))
        var project = smallProject(video: [Track(kind: .video, name: "V1", clips: [freeze])], media: [media.item("med_i", "index.mov", seconds: 3)])
        project.videoTracks[0].clips[0].freezeFrame = true
        let whole = CGRect(x: 0, y: 0, width: 320, height: 180)
        let before = try await grab(RenderContext(project: project, folder: media.projectFolder), 0.5)
        XCTAssertEqual(TestMedia.readIndex(before, in: whole), 30)
        let url = media.folder.appendingPathComponent("index.mov")
        try FileManager.default.removeItem(at: url)
        try await media.movie("index.mov", seconds: 3, draw: { TestMedia.drawIndex($0 + 100, $1) })
        let after = try await grab(RenderContext(project: project, folder: media.projectFolder), 0.5)
        XCTAssertEqual(TestMedia.readIndex(after, in: whole), 130)
    }

    /// Freezes stay off the composition's tracks, and the instructions
    /// over them don't wait on those tracks.
    func testFreezesAreDecodedNotPlacedOnTheTracks() async throws {
        let media = try TestMedia()
        try await indexMovie(media)
        let clips = [
            Clip(id: "clip_a", content: .media(mediaID: "med_i"), start: .zero, duration: t(1), sourceStart: t(0.5)),
            Clip(id: "clip_f", content: .media(mediaID: "med_i"), start: t(1), duration: t(1), sourceStart: t(1.3), freezeFrame: true),
            Clip(id: "clip_g", content: .media(mediaID: "med_i"), start: t(2), duration: t(1), sourceStart: t(2), freezeFrame: true)
        ]
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: clips)], media: [media.item("med_i", "index.mov", seconds: 3)])
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        let edits = built.composition.tracks(withMediaType: .video).flatMap(\.segments).filter { $0.sourceURL?.lastPathComponent == "index.mov" }
        XCTAssertEqual(edits.map { Time(cmTime: $0.timeMapping.target.end) }, [t(1)], "only the playing clip")
        for instruction in built.videoComposition.instructions where Time(cmTime: instruction.timeRange.start) >= t(1) {
            XCTAssertEqual(instruction.requiredSourceTrackIDs?.count ?? 0, 0, "at \(instruction.timeRange.start.seconds)")
        }
        let invalidity = await CompositionAssembler.invalidity(of: built.videoComposition, in: built.composition)
        XCTAssertNil(invalidity)
        for (time, expected) in [(0.5, 30), (1.0, 39), (1.6, 39), (2.0, 60), (2.9, 60)] {
            let frame = try await grab(RenderContext(project: project, folder: media.projectFolder), time)
            XCTAssertEqual(TestMedia.readIndex(frame, in: CGRect(x: 0, y: 0, width: 320, height: 180)), expected, "at \(time)")
        }
    }

    func testThePlayerItemPlaysThroughTheCompositor() async throws {
        let media = try TestMedia()
        try await media.movie("blue.mov", seconds: 2, draw: { TestMedia.fill($1, 0, 0, 1) }, sound: { _ in 0.05 })
        let item = media.item("med_b", "blue.mov", seconds: 2, audio: true)
        let picture = Clip(id: "clip_v", content: .media(mediaID: "med_b"), start: .zero, duration: t(2),
                           video: VideoProperties(transform: Transform(position: Point(x: 0.25, y: 0.5), scale: 0.5)))
        let sound = Clip(id: "clip_a", content: .media(mediaID: "med_b"), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [picture])], audio: [Track(kind: .audio, name: "A1", clips: [sound])], media: [item])
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        let playerItem = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        playerItem.add(output)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        player.play()
        var frame: CVPixelBuffer?
        let deadline = Date().addingTimeInterval(5)
        while frame == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            let now = output.itemTime(forHostTime: CACurrentMediaTime())
            if now.seconds > 0.2, output.hasNewPixelBuffer(forItemTime: now) {
                frame = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil)
            }
        }
        player.pause()
        let pixels = try XCTUnwrap(frame, "the player produced no frames")
        let bitmap = Bitmap(CIImage(cvPixelBuffer: pixels), size: CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)))
        // Half-size layer centred a quarter across: blue on the left, black on the right.
        assertColor(bitmap[80, 90], [0, 0, 255], tolerance: 10)
        assertColor(bitmap[240, 90], [0, 0, 0], tolerance: 6)
    }

    func testTitlesOnlyTimeline() async throws {
        let media = try TestMedia()
        let title = Clip(id: "clip_t", content: .text(TextContent(text: "v1.46.0", preset: "version")), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "Text", clips: [title])], media: [])
        let frame = try await grab(RenderContext(project: project, folder: media.projectFolder), 1)
        XCTAssertGreaterThan(frame.litPixels(), 1_000)
        assertColor(frame[2, 2], [0, 0, 0])
    }

    func testMissingMediaIsAWarningNotAFailure() async throws {
        let media = try TestMedia()
        let clip = Clip(id: "clip_x", content: .media(mediaID: "med_x"), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_x", "gone.mov", seconds: 2)])
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        let frame = Bitmap(try await renderer.image(at: t(1)))
        assertColor(frame[160, 90], [0, 0, 0])
        let warnings = try await renderer.warnings()
        XCTAssertTrue(warnings.contains { $0.contains("gone.mov") }, "\(warnings)")
    }

    func testEmptyTimelineThrows() async throws {
        let media = try TestMedia()
        let project = smallProject(video: [Track(kind: .video, name: "V1")], media: [])
        do {
            _ = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RenderError, .emptyTimeline)
        }
    }

    func testCompositionStructure() async throws {
        let media = try TestMedia()
        try await media.movie("av.mov", seconds: 3, draw: { TestMedia.fill($1, 1, 1, 1) }, sound: { _ in 0.1 })
        let item = media.item("med_av", "av.mov", seconds: 3, audio: true)
        let picture = Clip(id: "clip_v", content: .media(mediaID: "med_av"), start: .zero, duration: t(2), linkGroup: "lnk_a")
        let sound = Clip(id: "clip_a", content: .media(mediaID: "med_av"), start: .zero, duration: t(2), linkGroup: "lnk_a")
        let music = Clip(id: "clip_m", content: .media(mediaID: "med_av"), start: t(1), duration: t(2))
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [picture])],
            audio: [Track(kind: .audio, name: "Voice", clips: [sound]), Track(kind: .audio, name: "Music", clips: [music])],
            media: [item]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        XCTAssertEqual(built.duration, t(3))
        XCTAssertEqual(built.renderSize, size)
        XCTAssertEqual(built.composition.tracks(withMediaType: .video).count, 2)
        XCTAssertEqual(built.composition.tracks(withMediaType: .audio).count, 2)
        XCTAssertEqual(built.videoComposition.frameDuration, CMTime(value: 1, timescale: 30))
        let ranges = built.videoComposition.instructions.map(\.timeRange)
        XCTAssertEqual(ranges.first?.start, .zero)
        XCTAssertEqual(ranges.last.map { Time(cmTime: $0.end) }, t(3))
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
        }
        XCTAssertEqual((built.audioMix.inputParameters).count, 2)
        // The blocking builder gives the same shape.
        let sync = try buildBlocking(RenderContext(project: project, folder: media.projectFolder))
        XCTAssertEqual(sync.duration, built.duration)
    }

    /// Synchronous callers get the blocking overload.
    func buildBlocking(_ context: RenderContext) throws -> BuiltComposition {
        try CompositionBuilder.build(context)
    }
}
