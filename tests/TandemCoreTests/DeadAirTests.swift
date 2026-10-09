import XCTest
@testable import TandemCore

/// Dead air for `tandem check`: a still picture with nothing to hear, on
/// made-up frame measurements and projects.
final class DeadAirTests: XCTestCase {
    // MARK: - Helpers

    static let screen = MediaItem(id: "med_screen", path: "take-screen.mov", kind: .video, role: .screen, duration: t(600), width: 3840, height: 2160, hasVideo: true)
    static let camera = MediaItem(id: "med_camera", path: "take-camera.mov", kind: .video, role: .camera, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true)
    static let music = MediaItem(id: "med_music", path: "bed.wav", kind: .audio, role: .music, duration: t(600), hasAudio: true)
    static let whoosh = MediaItem(id: "med_whoosh", path: "whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)

    /// A 4K, 30 fps edit like Mike's: the screen full frame, his camera in
    /// the bottom right corner, his voice, a music bed from `musicFrom` and
    /// whatever sound effects are given.
    private func edit(musicFrom: Double = 0, music: Clip? = nil, sfx: [Clip] = [], graphics: [Clip] = [], camera: VideoProperties? = nil) -> Project {
        var project = Project.standard(name: "Dead air")
        project.settings.width = 3840
        project.settings.height = 2160
        project.settings.frameRate = .fps30
        project.media = [Self.screen, Self.camera, Self.music, Self.whoosh]
        let pip = VideoProperties(transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5), cutout: Cutout())
        project.videoTracks[0].clips = [Clip(id: "clip_screen", content: .media(mediaID: "med_screen"), start: .zero, duration: t(60))]
        project.videoTracks[1].clips = [Clip(id: "clip_camera", content: .media(mediaID: "med_camera"), start: .zero, duration: t(60), video: camera ?? pip)]
        project.videoTracks[3].clips = graphics
        project.audioTracks[0].clips = [Clip(id: "clip_voice", content: .media(mediaID: "med_camera"), start: .zero, duration: t(60))]
        project.audioTracks[1].clips = [music ?? Clip(id: "clip_music", content: .media(mediaID: "med_music"), start: t(musicFrom), duration: t(60 - musicFrom), audio: AudioProperties(gainDB: -31))]
        project.audioTracks[2].clips = sfx
        return project
    }

    /// Words said back to back from `start`, with `pauses` (seconds) after
    /// the words that end a sentence.
    private func speech(_ sentences: [(String, pauseAfter: Double)], from start: Double = 0, clipIDs: Set<String> = ["clip_voice"]) -> QualityCheck.Speech {
        var words: [QualityCheck.Speech.Word] = []
        var time = start
        for (sentence, pause) in sentences {
            for word in sentence.split(separator: " ") {
                words.append(.init(text: String(word), start: t(time), end: t(time + 0.25)))
                time += 0.3
            }
            time += pause - 0.05
        }
        return QualityCheck.Speech(words: words, clipIDs: clipIDs)
    }

    /// 30 fps frames from `start` to `end`, each a 32 x 18 tile thumbnail of
    /// a dim page, changed by `change` (frame index, time, tiles).
    private func frames(from start: Double, to end: Double, change: (Int, Double, inout [UInt8]) -> Void = { _, _, _ in }) -> [FrameStats] {
        var found: [FrameStats] = []
        var index = 0
        while true {
            let time = start + Double(index) / 30
            guard time < end - 0.0001 else { break }
            var tiles = (0..<(32 * 18)).map { (tile: Int) -> UInt8 in UInt8(20 + tile * 7 % 30) }
            change(index, time, &tiles)
            found.append(FrameStats(time: Time(seconds: time), luma: 0.1, brightestTile: 0.2, flatGreen: 0, flatWhite: 0, thumbnail: tiles, columns: 32))
            index += 1
        }
        return found
    }

    private func tile(_ row: Int, _ column: Int) -> Int { row * 32 + column }

    /// Dead air in `from` to `to`, by default from the first word to the
    /// last.
    private func deadAir(_ project: Project, _ speech: QualityCheck.Speech, _ frames: [FrameStats], from: Double? = nil, to: Double? = nil) -> [CheckProblem] {
        let start = from.map(t) ?? speech.words.first?.start ?? .zero
        let end = to.map(t) ?? speech.words.last?.end ?? t(6)
        return QualityCheck.deadAir(in: project, ranges: [TimeRange(start: start, end: end)], frames: frames, speech: speech)
    }

    /// "That gets pretty messy." then 1.4 s of nothing before "So editing
    /// data", the silent second at 3:56 of Build Your Own Convex.
    private var messy: QualityCheck.Speech {
        speech([("That gets pretty messy.", 1.4), ("So editing data in place", 0.4)], from: 1)
    }

    // MARK: - Tests

    func testAStillPictureWithNothingToHearIsDeadAir() throws {
        let found = deadAir(edit(), messy, frames(from: 0, to: 6))
        XCTAssertEqual(found.map(\.kind), [.deadAir])
        let note = try XCTUnwrap(found.first)
        XCTAssertTrue(note.kind.isNote, "a pause can let a point land")
        XCTAssertEqual(note.start.seconds, 2.15, accuracy: 0.001, "from the end of \"messy.\"")
        XCTAssertEqual(note.end.seconds, 3.55, accuracy: 0.001, "to the start of \"So\"")
        XCTAssertTrue(note.message.hasPrefix("Dead air: 1.40 s with nothing said, no sound effect or music swell, and a still picture (after \"That gets pretty messy.\")"), note.message)
        XCTAssertTrue(note.message.hasSuffix("Cut it, or keep it if the pause earns it."), note.message)
        XCTAssertEqual(note.clipIDs, ["clip_camera", "clip_screen"], "the pictures there, top first")
    }

    func testASentencePauseIsNeverDeadAir() {
        let pauses = speech([("One sentence here.", 0.4), ("And another one.", 0.4), ("And the last.", 0.4)], from: 1)
        XCTAssertTrue(deadAir(edit(), pauses, frames(from: 0, to: 6)).isEmpty)
        let long = speech([("One sentence here.", 0.79), ("And another one.", 0.4)], from: 1)
        XCTAssertTrue(deadAir(edit(), long, frames(from: 0, to: 6)).isEmpty, "under 0.8 s")
    }

    func testSomethingToHearFillsThePause() {
        let still = frames(from: 0, to: 6)
        let whoosh = Clip(id: "clip_whoosh", content: .media(mediaID: "med_whoosh"), start: t(2.6), duration: t(0.5))
        XCTAssertTrue(deadAir(edit(sfx: [whoosh]), messy, still).isEmpty, "a sound effect splits it into bits under 0.8 s")

        var swelling = Clip(id: "clip_music", content: .media(mediaID: "med_music"), start: .zero, duration: t(60), audio: AudioProperties(gainDB: -31))
        swelling.keyframes["audio.gainDB"] = [
            Keyframe(time: .zero, value: .number(-31)), Keyframe(time: t(2.3), value: .number(-31)),
            Keyframe(time: t(2.6), value: .number(-25)), Keyframe(time: t(3.2), value: .number(-25)), Keyframe(time: t(3.5), value: .number(-31))
        ]
        XCTAssertTrue(deadAir(edit(music: swelling), messy, still).isEmpty, "the music swells in the pause")
        XCTAssertEqual(QualityCheck.swells(of: swelling).last, TimeRange(start: t(2.3), end: t(3.5)), "from where it starts rising until it's back down")

        XCTAssertTrue(deadAir(edit(musicFrom: 2.5), messy, still).isEmpty, "a new bed comes in")

        let card = Clip(id: "clip_card", content: SectionCard.content(SectionCard.Props(title: "Updates")), start: t(2), duration: t(1.6))
        XCTAssertTrue(deadAir(edit(graphics: [card]), messy, still).isEmpty, "a section card is never dead air")

        let notReady = QualityCheck.Speech(words: messy.words, clipIDs: [])
        XCTAssertTrue(deadAir(edit(), notReady, still).isEmpty, "a voice whose transcript isn't ready could be saying anything")
    }

    func testAMusicBedUnderThePauseIsStillDeadAir() {
        XCTAssertEqual(deadAir(edit(musicFrom: 0), messy, frames(from: 0, to: 6)).count, 1, "music at its usual level doesn't fill a pause")
    }

    func testAnAnimationIsntStill() {
        // A small badge sliding along the page, a tile every other frame,
        // barely brighter than the page: a demo's "read result" arrow.
        let badge = frames(from: 0, to: 6) { index, time, tiles in
            guard time >= 2.2, time < 3.5 else { return }
            tiles[self.tile(5, 3 + index / 2 % 20)] &+= 8
        }
        XCTAssertTrue(deadAir(edit(), messy, badge).isEmpty)

        // A result popping in halfway through: the picture before and after
        // are each still, but too short.
        let result = frames(from: 0, to: 6) { _, time, tiles in
            guard time >= 2.85 else { return }
            for column in 4..<14 { tiles[self.tile(7, column)] &+= 20 }
        }
        XCTAssertTrue(deadAir(edit(), messy, result).isEmpty)

        // A panel's highlight fading up a level a frame: never much from one
        // frame to the next, but the picture changes.
        let fade = frames(from: 0, to: 6) { _, time, tiles in
            let level = UInt8(max(0, min(30, Int((time - 2.5) * 30))))
            for column in 4..<14 { tiles[self.tile(6, column)] &+= level }
        }
        XCTAssertTrue(deadAir(edit(), messy, fade).isEmpty)
    }

    func testMikeInHisCornerTheDockAndTheCursorDontCount() throws {
        let busyCorner = frames(from: 0, to: 6) { index, time, tiles in
            // Mike shifts about in his corner every frame.
            for row in 10..<17 { tiles[self.tile(row, 22 + index % 6)] &+= 30 }
            // The Dock pops up along the bottom for a quarter of a second.
            if time >= 2.5, time < 2.75 {
                for column in 0..<14 { tiles[self.tile(17, column)] &+= 60 }
            }
            // The cursor nudges now and then.
            if time >= 2.9, time < 3.2, index % 5 == 0 { tiles[self.tile(9, 12)] &+= 5 }
        }
        let found = deadAir(edit(), messy, busyCorner)
        XCTAssertEqual(found.map(\.kind), [.deadAir])
        XCTAssertEqual(try XCTUnwrap(found.first).duration.seconds, 1.4, accuracy: 0.001)

        // Full frame, his camera is the whole picture: him sitting there
        // quiet is dead air too.
        let full = edit(camera: VideoProperties())
        XCTAssertEqual(deadAir(full, messy, busyCorner).count, 1)
    }

    func testOnlyTheRangesAskedFor() {
        XCTAssertTrue(deadAir(edit(), messy, frames(from: 0, to: 6), from: 0, to: 2.5).isEmpty, "only 0.35 s of it is in the range")
        XCTAssertEqual(deadAir(edit(), messy, frames(from: 1.5, to: 4.5), from: 1.5, to: 4.5).count, 1)
    }

    func testCheckProblemsIncludesDeadAirAsANote() {
        let project = edit()
        let range = [TimeRange(start: t(1), end: t(5))]
        let still = frames(from: 0, to: 6)
        XCTAssertTrue(QualityCheck.problems(in: project, ranges: range, frames: still).isEmpty, "without speech it isn't judged")
        let found = QualityCheck.problems(in: project, ranges: range, frames: still, speech: messy)
        XCTAssertEqual(found.map(\.kind), [.deadAir])
        XCTAssertTrue(QualityCheck.problems(in: project, ranges: range, frames: nil, speech: messy).isEmpty, "a quick check renders nothing")
    }

    func testCameraTilesFollowThePictureInPicture() {
        let project = edit()
        let media = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })
        let mask = QualityCheck.cameraTiles(at: t(1), in: project, media: media, columns: 32, rows: 18)
        XCTAssertTrue(mask[tile(12, 25)], "inside the corner")
        XCTAssertTrue(mask[tile(9, 19)], "the tiles its box reaches into")
        XCTAssertFalse(mask[tile(8, 25)], "just above it, where a demo's badge slid along")
        XCTAssertFalse(mask[tile(5, 5)], "the screen")
        XCTAssertEqual(mask.filter { $0 }.count, 13 * 9)

        var covered = project
        covered.videoTracks[2].clips = [Clip(id: "clip_broll", content: .solid(color: RGBA(r: 1, g: 0, b: 0)), start: .zero, duration: t(10))]
        XCTAssertFalse(QualityCheck.cameraTiles(at: t(1), in: covered, media: media, columns: 32, rows: 18).contains(true), "B-roll over him")
    }
}

private extension CheckProblem {
    var duration: Time { end - start }
}
