import XCTest
@testable import TandemCore

/// Page changes on the screen recording with no transition, on made-up
/// frame measurements of the recording scanned on its own.
final class PageChangeTests: XCTestCase {
    // MARK: - Helpers

    static let screen = MediaItem(id: "med_screen", path: "take-screen.mov", kind: .video, role: .screen, duration: t(600), width: 3840, height: 2160, hasVideo: true)
    static let camera = MediaItem(id: "med_camera", path: "take-camera.mov", kind: .video, role: .camera, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true)
    static let broll = MediaItem(id: "med_broll", path: "servers.mp4", kind: .video, role: .broll, duration: t(30), width: 3840, height: 2160, hasVideo: true)

    /// A 4K, 30 fps edit: the screen recording cut into `screen` clips on
    /// the Screen track (each playing the recording from where the last
    /// stopped), Mike's camera in the corner, and `broll` over them.
    private func edit(cuts: [Double] = [], transitions: [Transition] = [], broll: [Clip] = [], camera: VideoProperties? = nil) -> Project {
        var project = Project.standard(name: "Pages")
        project.settings.width = 3840
        project.settings.height = 2160
        project.settings.frameRate = .fps30
        project.media = [Self.screen, Self.camera, Self.broll]
        let edges = [0] + cuts + [30]
        project.videoTracks[0].clips = zip(edges, edges.dropFirst()).enumerated().map { index, span in
            Clip(id: "clip_s\(index + 1)", content: .media(mediaID: "med_screen"), start: t(span.0), duration: t(span.1 - span.0), sourceStart: t(span.0))
        }
        project.videoTracks[0].transitions = transitions
        let pip = VideoProperties(transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5), cutout: Cutout())
        project.videoTracks[1].clips = [Clip(id: "clip_camera", content: .media(mediaID: "med_camera"), start: .zero, duration: t(30), video: camera ?? pip)]
        project.videoTracks[2].clips = broll
        return project
    }

    /// A page of dim text lines on a dark background, as 32 x 18 tiles:
    /// `layout` picks which tiles carry text.
    private func page(_ layout: Int) -> [UInt8] {
        (0..<(32 * 18)).map { (tile: Int) -> UInt8 in
            let row = tile / 32, column = tile % 32
            let mark: Int = (row * 3 + column * (layout + 2) + layout * 5) % 7
            return mark < 3 ? 45 : 20
        }
    }

    /// Scanlines in four bands for a page of text, each line of text its own
    /// brightness: `offset` scrolls it up by that many lines, and another
    /// `seed` is another page.
    private func lines(offset: Int = 0, seed: Int = 0) -> [UInt8] {
        (0..<4).flatMap { band in
            (0..<216).map { line -> UInt8 in
                let y = line + offset
                return y % 6 < 3 ? UInt8(20 + noise(y / 6 + seed * 1000 + band * 100_000) % 40) : 15
            }
        }
    }

    /// A number from 0 to 2^32 that looks random for each `n`.
    private func noise(_ n: Int) -> Int {
        var x = UInt32(truncatingIfNeeded: n &* 2_654_435_761)
        x ^= x >> 15
        x = x &* 2_246_822_519
        x ^= x >> 13
        return Int(x)
    }

    /// 30 fps frames of the screen recording alone from `start` to `end`.
    /// `shown` gives each frame's thumbnail and scanlines.
    private func frames(from start: Double = 0, to end: Double, _ shown: (Int, Double) -> (tiles: [UInt8], lines: [UInt8])) -> [FrameStats] {
        var found: [FrameStats] = []
        var index = 0
        while true {
            let time = start + Double(index) / 30
            guard time < end - 0.0001 else { break }
            let (tiles, lines) = shown(index, time)
            found.append(FrameStats(time: Time(seconds: time), luma: 0.1, brightestTile: 0.2, flatGreen: 0, flatWhite: 0, thumbnail: tiles, columns: 32, scanlines: lines))
            index += 1
        }
        return found
    }

    /// Page 0 until `at`, then page 1.
    private func flip(at: Double, to end: Double = 4) -> [FrameStats] {
        frames(to: end) { _, time in time < at ? (page(0), lines(seed: 0)) : (page(1), lines(seed: 1)) }
    }

    private func pages(_ project: Project, _ frames: [FrameStats], from: Double = 0, to: Double = 4) -> [CheckProblem] {
        QualityCheck.pageChanges(in: project, ranges: [TimeRange(start: t(from), end: t(to))], screenFrames: frames)
    }

    // MARK: - Tests

    func testANewPageWithNoTransitionIsANote() throws {
        XCTAssertGreaterThan(QualityCheck.changedShare(flip(at: 0)[0], flip(at: 1)[0]), 0.3, "the two pages really differ")
        let found = pages(edit(), flip(at: 2))
        XCTAssertEqual(found.map(\.kind), [.pageChange])
        let note = try XCTUnwrap(found.first)
        XCTAssertTrue(note.kind.isNote, "a big change in a demo isn't always a page")
        XCTAssertEqual(note.start.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(note.clipIDs, ["clip_s1"])
        XCTAssertTrue(note.message.hasPrefix("Page change inside a clip, with no transition: "), note.message)
        XCTAssertTrue(note.message.contains("of the screen recording changes at once, then holds."), note.message)
        XCTAssertTrue(note.message.contains("freeze 0.35 s either side and push between the freezes"), note.message)
    }

    func testAtACutItSaysWhichClips() throws {
        let found = pages(edit(cuts: [2]), flip(at: 2))
        let note = try XCTUnwrap(found.first)
        XCTAssertEqual(note.clipIDs, ["clip_s1", "clip_s2"])
        XCTAssertTrue(note.message.hasPrefix("Page change at a cut, with no transition: "), note.message)
        XCTAssertTrue(note.message.hasSuffix("If it's a new page, push it (0.7 s, on the Screen track)."), note.message)
    }

    func testATransitionOverItIsFine() {
        let push = Transition(type: .push, direction: .left, duration: t(0.7), fromClipID: "clip_s1", toClipID: "clip_s2")
        XCTAssertTrue(pages(edit(cuts: [2], transitions: [push]), flip(at: 2)).isEmpty)
        // The page flips after the push is over: a borrowed frame shows the
        // old page, and the flip is bare.
        XCTAssertEqual(pages(edit(cuts: [2], transitions: [push]), flip(at: 2.5)).count, 1)
    }

    func testOnlyPageChangesTheViewerSees() {
        let shot = Clip(id: "clip_broll", content: .media(mediaID: "med_broll"), start: t(1), duration: t(2))
        XCTAssertTrue(pages(edit(broll: [shot]), flip(at: 2)).isEmpty, "under a full-frame B-roll shot")
        XCTAssertTrue(pages(edit(camera: VideoProperties()), flip(at: 2)).isEmpty, "under the camera full frame")
        let small = Clip(id: "clip_broll", content: .media(mediaID: "med_broll"), start: t(1), duration: t(2), video: VideoProperties(transform: Transform(position: Point(x: 0.2, y: 0.2), scale: 0.3)))
        XCTAssertEqual(pages(edit(broll: [small]), flip(at: 2)).count, 1, "a small shot leaves the page showing")
        XCTAssertTrue(pages(edit(), flip(at: 2), from: 2.5, to: 4).isEmpty, "outside the range asked about")
    }

    func testTypingIsntAPageChange() {
        // A line typed a character every other frame for two seconds: in
        // the end a fifth of the page changed, never much at once.
        let typing = frames(to: 4) { index, time in
            var tiles = page(0)
            let typed = time < 1 ? 0 : min(60, (index - 30) / 2)
            for character in 0..<typed { tiles[(4 + character / 30) * 32 + 1 + character % 30] = 70 }
            return (tiles, lines())
        }
        XCTAssertTrue(pages(edit(), typing).isEmpty)
    }

    func testScrollingIsntAPageChange() {
        // A smooth scroll with momentum: the page moves for most of a second.
        let smooth = frames(to: 4) { index, time in
            let offset = time < 1 ? 0 : min(45, (index - 30) * 2)
            return (page(offset / 9 % 5), lines(offset: offset))
        }
        XCTAssertTrue(pages(edit(), smooth).isEmpty)

        // A jump of 27 lines at once: the same lines, moved up.
        let jump = frames(to: 4) { _, time in
            time < 2 ? (page(0), lines(offset: 0)) : (page(3), lines(offset: 27))
        }
        XCTAssertTrue(QualityCheck.isScroll(lines(offset: 0), lines(offset: 27)))
        XCTAssertFalse(QualityCheck.isScroll(lines(seed: 0), lines(seed: 1)), "a new page isn't a scroll")
        XCTAssertFalse(QualityCheck.isScroll(lines(), lines()), "nor is the same page")
        XCTAssertTrue(pages(edit(), jump).isEmpty)
    }

    func testAnAnimationIsntAPageChange() {
        // A diagram whose boxes light up one after another for a second and
        // a half: never holding long enough to be a page.
        let animation = frames(to: 4) { index, time in
            var tiles = page(0)
            if time >= 1, time < 2.5 {
                for tile in tiles.indices where (tile + index * 5) % 4 == 0 { tiles[tile] = 60 }
            }
            return (tiles, lines())
        }
        XCTAssertTrue(pages(edit(), animation).isEmpty)
    }

    func testTheScreenRecordingOnItsOwn() throws {
        let push = Transition(type: .push, direction: .left, duration: t(0.7), fromClipID: "clip_s1", toClipID: "clip_s2")
        var project = edit(cuts: [2], transitions: [push], broll: [Clip(id: "clip_broll", content: .media(mediaID: "med_broll"), start: t(1), duration: t(2))])
        project.videoTracks[0].clips[0].video = VideoProperties(transform: Transform(scale: 1.3))
        project.videoTracks[0].clips[0].keyframes["video.transform.scale"] = [Keyframe(time: .zero, value: .number(1.2))]
        let screens = try XCTUnwrap(QualityCheck.screenOnly(project))
        XCTAssertEqual(screens.videoTracks.flatMap(\.clips).map(\.id), ["clip_s1", "clip_s2"], "only the screen recording")
        XCTAssertNil(screens.videoTracks[0].clips[0].video, "as recorded, not zoomed")
        XCTAssertTrue(screens.videoTracks[0].clips[0].keyframes.isEmpty)
        XCTAssertTrue(screens.videoTracks.allSatisfy { $0.transitions.isEmpty })
        XCTAssertTrue(screens.audioTracks.allSatisfy { $0.clips.isEmpty })
        XCTAssertEqual(screens.videoTracks[0].clips[1].sourceStart, t(2), "cut as the timeline cuts it")

        XCTAssertEqual(QualityCheck.screenRanges(in: project, within: [TimeRange(start: t(1), end: t(40))]), [TimeRange(start: t(1), end: t(30))])
        var noScreen = project
        noScreen.videoTracks[0].clips = []
        XCTAssertNil(QualityCheck.screenOnly(noScreen))
    }
}
