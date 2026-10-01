import XCTest
@testable import TandemCore

/// `tandem check`'s judgements, on made-up frame measurements and projects.
final class QualityCheckTests: XCTestCase {
    // MARK: - Helpers

    /// A 4K, 30 fps project with one video track.
    private func project(_ clips: [Clip], media: [MediaItem] = [], transitions: [Transition] = [], text: [Clip] = []) -> Project {
        var project = Project.standard(name: "Check")
        project.settings.width = 3840
        project.settings.height = 2160
        project.settings.frameRate = .fps30
        project.media = media
        project.videoTracks = [
            Track(id: "trk_v1", kind: .video, name: "V1", clips: clips, transitions: transitions),
            Track(id: "trk_text", kind: .video, name: "Text", clips: text)
        ]
        project.audioTracks = []
        return project
    }

    private func solid(_ id: String, _ start: Double, _ end: Double) -> Clip {
        Clip(id: id, content: .solid(color: RGBA(r: 0.5, g: 0.5, b: 0.5)), start: t(start), duration: t(end - start))
    }

    /// Frames at 30 fps from `start` seconds, each a flat thumbnail of one
    /// grey level.
    private func frames(_ levels: [UInt8], from start: Double = 0, configure: (Int, inout FrameStats) -> Void = { _, _ in }) -> [FrameStats] {
        levels.enumerated().map { index, level in
            var stats = FrameStats(
                time: Time(seconds: start + Double(index) / 30), luma: Double(level) / 255, brightestTile: Double(level) / 255,
                flatGreen: 0, flatWhite: 0, thumbnail: [UInt8](repeating: level, count: 16)
            )
            configure(index, &stats)
            return stats
        }
    }

    private var shot: Project {
        project([Clip(id: "clip_a", content: .solid(color: RGBA(r: 0.5, g: 0.5, b: 0.5)), start: .zero, duration: t(60))])
    }

    // MARK: - Model checks

    func testGapsAreWhereNothingIsOnAVideoTrack() {
        let title = Clip(id: "clip_title", content: .text(TextContent(text: "Hi")), start: t(10), duration: t(2))
        let p = project([solid("clip_a", 0, 10), solid("clip_b", 12, 20)], text: [title])
        let gaps = QualityCheck.gaps(in: p, ranges: [TimeRange(start: .zero, end: t(20))])
        XCTAssertEqual(gaps.map(\.kind), [.gap])
        XCTAssertEqual(gaps.first?.start, t(10), "a title over nothing is still black behind")
        XCTAssertEqual(gaps.first?.end, t(12))
        XCTAssertTrue(QualityCheck.gaps(in: p, ranges: [TimeRange(start: .zero, end: t(9))]).isEmpty, "outside the range asked about")

        var hidden = p
        hidden.videoTracks[0].hidden = true
        XCTAssertEqual(QualityCheck.gaps(in: hidden, ranges: [TimeRange(start: .zero, end: t(20))]).first?.end, t(20), "a hidden track shows nothing")
    }

    func testPicturesBlownUpPastTheirPixelsAreSoft() {
        let hd = MediaItem(id: "med_hd", path: "broll/shot.mp4", kind: .video, role: .broll, duration: t(30), width: 1920, height: 1080, hasVideo: true)
        func clip(scale: Double, keyframes: [Double] = []) -> Clip {
            var clip = Clip(id: "clip_hd", content: .media(mediaID: "med_hd"), start: t(5), duration: t(4), video: VideoProperties(transform: Transform(scale: scale)))
            if !keyframes.isEmpty {
                clip.keyframes["video.transform.scale"] = keyframes.enumerated().map { Keyframe(time: t(Double($0.offset)), value: .number($0.element)) }
            }
            return clip
        }
        let range = [TimeRange(start: .zero, end: t(20))]
        XCTAssertTrue(QualityCheck.softPictures(in: project([clip(scale: 1)], media: [hd]), ranges: range).isEmpty, "1080p fitted to 4K is 2x: fine")
        XCTAssertTrue(QualityCheck.softPictures(in: project([clip(scale: 1.45)], media: [hd]), ranges: range).isEmpty, "145% is as far as Mike let it go")
        let zoomed = QualityCheck.softPictures(in: project([clip(scale: 1.67)], media: [hd]), ranges: range)
        XCTAssertEqual(zoomed.map(\.kind), [.soft])
        XCTAssertTrue(zoomed.first?.kind.isNote == true, "a note, not a failure")
        XCTAssertEqual(zoomed.first?.clipIDs, ["clip_hd"])
        XCTAssertTrue(zoomed.first?.message.contains("3.3x its own pixels (1920x1080 at 167% on a 3840x2160 frame)") == true, zoomed.first?.message ?? "")
        XCTAssertEqual(QualityCheck.softPictures(in: project([clip(scale: 1, keyframes: [1, 1.6])], media: [hd]), ranges: range).count, 1, "zoomed by a keyframe")
    }

    // MARK: - Frame checks

    func testBlackFramesButNotInAFadeToBlack() {
        let levels: [UInt8] = [120, 120, 0, 0, 0, 0, 0, 120, 120]
        let found = QualityCheck.frameProblems(frames(levels), in: shot)
        XCTAssertEqual(found.map(\.kind), [.black])
        XCTAssertEqual(found.first?.frames, 5)
        XCTAssertEqual(found.first?.clipIDs, ["clip_a"])

        let fade = Transition(type: .fadeToBlack, duration: t(1), fromClipID: "clip_a", toClipID: nil)
        var faded = shot
        faded.videoTracks[0].transitions = [fade]
        let late = frames(levels, from: 59.6)
        XCTAssertTrue(QualityCheck.frameProblems(late, in: faded).isEmpty, "black on purpose")
    }

    func testFlickersAreFramesUnlikeMatchingNeighbours() {
        XCTAssertEqual(QualityCheck.frameProblems(frames([100, 100, 100, 200, 100, 100]), in: shot).map(\.frames), [1])
        XCTAssertEqual(QualityCheck.frameProblems(frames([100, 100, 200, 210, 100, 100]), in: shot).map(\.frames), [2])
        XCTAssertTrue(QualityCheck.frameProblems(frames([100, 100, 200, 200, 200]), in: shot).isEmpty, "a cut to a new shot")
        XCTAssertTrue(QualityCheck.frameProblems(frames([40, 80, 120, 160, 200, 240]), in: shot).isEmpty, "steady change")
    }

    func testAFlashOfBlackIsReportedOnceAsBlack() {
        let found = QualityCheck.frameProblems(frames([100, 100, 0, 100, 100]), in: shot)
        XCTAssertEqual(found.map(\.kind), [.black], "not a flicker as well")
    }

    func testFlickersDontSpanAJumpBetweenStretches() {
        // Two stretches read back to back: the last frame of one and the
        // first of the next aren't neighbours.
        let first = frames([100, 100, 100])
        let second = frames([200, 100, 100], from: 30)
        XCTAssertTrue(QualityCheck.frameProblems(first + second, in: shot).isEmpty)
    }

    func testFlatGreenIsAKeyThatDidntHappen() {
        let found = QualityCheck.frameProblems(frames([100, 100, 100, 100]) { index, stats in
            if index > 0 { stats.flatGreen = 0.05 }
        }, in: shot)
        XCTAssertEqual(found.map(\.kind), [.unkeyed])
        XCTAssertEqual(found.first?.frames, 3)
        XCTAssertTrue(found.first?.message.contains("5% of the frame") == true)
    }

    func testAWhiteBlockThatComesAndGoes() {
        func white(_ shares: [Double]) -> [CheckProblem] {
            QualityCheck.frameProblems(frames([UInt8](repeating: 100, count: shares.count)) { index, stats in
                stats.flatWhite = shares[index]
            }, in: shot)
        }
        let box = white([0, 0] + Array(repeating: 0.13, count: 8) + [0, 0])
        XCTAssertEqual(box.map(\.kind), [.whiteBlock])
        XCTAssertEqual(box.first?.frames, 8)
        XCTAssertTrue(white([0] + Array(repeating: 0.3, count: 120) + [0]).isEmpty, "a white page in a screen recording stays put")
        XCTAssertTrue(white([0.1, 0.1] + Array(repeating: 0.13, count: 8) + [0.1]).isEmpty, "it was there before and after")
    }

    // MARK: - Measuring

    func testTilesKnowGreenScreenAndWhite() {
        let green = FrameStats.Tile(red: 0.1, green: 0.8, blue: 0.15, spread: 0.01)
        let white = FrameStats.Tile(red: 0.97, green: 0.98, blue: 0.97, spread: 0.01)
        let grass = FrameStats.Tile(red: 0.3, green: 0.6, blue: 0.2, spread: 0.12)
        XCTAssertTrue(green.isFlatGreen)
        XCTAssertFalse(grass.isFlatGreen, "textured, and not that green")
        XCTAssertTrue(white.isFlatWhite)
        let stats = FrameStats(time: .zero, tiles: [green, white, grass, grass])
        XCTAssertEqual(stats.flatGreen, 0.25)
        XCTAssertEqual(stats.flatWhite, 0.25)
        XCTAssertEqual(stats.thumbnail.count, 4)
        XCTAssertEqual(stats.brightestTile, white.luma, accuracy: 0.0001)
    }

    // MARK: - What changed

    func testChangedRegionsMergeNearbyChanges() throws {
        let p = project([solid("clip_a", 0, 10), solid("clip_b", 11, 20), solid("clip_c", 40, 45)])
        var two = ReviewChanges()
        two.added = ["clip_a", "clip_b"]
        var one = ReviewChanges()
        one.changed = ["clip_c"]
        let log = ReviewLog(entries: [
            ReviewEntry(revision: 2, label: "Two shots", author: "claude", date: Date(), changes: two),
            ReviewEntry(revision: 3, label: "One more", author: "claude", date: Date(), changes: one)
        ])
        XCTAssertEqual(log.changedRegions(in: p), [TimeRange(start: .zero, end: t(20)), TimeRange(start: t(40), end: t(45))])
    }
}
