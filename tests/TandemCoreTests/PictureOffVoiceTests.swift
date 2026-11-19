import XCTest
@testable import TandemCore

/// `pictureOffVoice`: the camera and the voice of one take playing the same
/// file at different moments, which Mike saw as lips out of step on the
/// workbench short (19 Nov 2026) and no check noticed.
final class PictureOffVoiceTests: XCTestCase {
    private func all(_ project: Project) -> [TimeRange] { [TimeRange(start: .zero, end: project.duration)] }

    func testACameraSlippedOffItsVoiceIsAProblemWithTheSlipThatFixesIt() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(20), end: t(21))], trackIDs: nil))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [], "in step as placed")

        let camera = c.clips("Camera")[1]
        try c.run("Drift", .slip(clipID: camera.id, delta: t(-0.3), includeLinked: false))
        let found = QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project))
        XCTAssertEqual(found.count, 1)
        let problem = try XCTUnwrap(found.first)
        XCTAssertEqual(problem.kind, .pictureOffVoice)
        XCTAssertFalse(problem.kind.isNote, "it fails the check")
        XCTAssertEqual(problem.start, camera.start)
        XCTAssertEqual(problem.clipIDs.first, camera.id)
        XCTAssertTrue(problem.message.contains("0.30 s behind"), problem.message)
        let fix = try XCTUnwrap(problem.fix)
        guard case .slip(camera.id, let delta, false) = fix else { return XCTFail("\(fix)") }
        XCTAssertEqual(delta.seconds, 0.3, accuracy: 0.0001)

        // In the check, and its Fix batch puts it right.
        XCTAssertTrue(QualityCheck.problems(in: c.project, ranges: all(c.project), frames: nil).contains { $0.kind == .pictureOffVoice })
        XCTAssertEqual(QualityCheck.fixLabel(for: found), QualityCheck.pictureOffVoiceLabel)
        try c.apply(EditBatch(label: QualityCheck.fixLabel(for: found), commands: QualityCheck.commands(fixing: found)))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [])
    }

    func testOnlyTheRangesCheckedAndNotHeldFrames() throws {
        let (f, c) = try Fixture.edited()
        let camera = c.clips("Camera")[0]
        try c.run("Hold", .holdFrame(clipID: camera.id, range: TimeRange(start: t(10), duration: f.project.settings.frameRate.frameDuration.scaled(by: 3))))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [], "a held frame is off its voice on purpose")

        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(40), end: t(41))], trackIDs: nil))
        let late = c.clips("Camera").last!
        try c.run("Drift", .slip(clipID: late.id, delta: t(-0.2), includeLinked: false))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: [TimeRange(start: t(0), end: t(30))]), [])
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: [TimeRange(start: t(30), end: t(50))]).count, 1)
    }

    func testSoundThatIsntHeardIsntTheVoice() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(40), end: t(41))], trackIDs: nil))
        let camera = c.clips("Camera")[0]
        try c.run("Drift", .slip(clipID: camera.id, delta: t(0.3), includeLinked: false))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)).count, 1)
        let voice = c.clips("Voice")[0]
        try c.run("Mute", .updateClip(clipID: voice.id, patch: .object(["audio": .object(["muted": .bool(true)])])))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [], "a muted clip isn't heard")
        try c.run("Unmute", .updateClip(clipID: voice.id, patch: .object(["audio": .object(["muted": .bool(false), "gainDB": .number(-100)])])))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [], "nor one turned all the way down, as Filmora mutes")
    }

    func testSilenceIsJudgedOverWhatTheClipPlays() {
        var clip = Clip(id: "clip_v", content: .media(mediaID: "med_camera"), start: .zero, duration: t(10))
        clip.keyframes["audio.gainDB"] = [Keyframe(time: .zero, value: .number(-100), interpolation: .hold), Keyframe(time: t(20), value: .number(0))]
        XCTAssertTrue(QualityCheck.silent(clip), "the 0 dB keyframe kept past the end is never reached")
        clip.keyframes["audio.gainDB"] = [Keyframe(time: .zero, value: .number(-100)), Keyframe(time: t(20), value: .number(0))]
        XCTAssertFalse(QualityCheck.silent(clip), "easing up towards it, it's heard before the end")
        clip.keyframes = [:]
        XCTAssertFalse(QualityCheck.silent(clip))
    }

    func testNoFixWhereTheSlipWouldReachPastTheVoiceOrTheTrackIsLocked() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(40), end: t(41))], trackIDs: nil))
        // The voice under only part of the camera: an L-cut.
        let voice = c.clips("Voice")[0]
        try c.run("Shorter", .trim(clipID: voice.id, edge: .end, to: t(30), ripple: false, includeLinked: false))
        let camera = c.clips("Camera")[0]
        try c.run("Drift", .slip(clipID: camera.id, delta: t(0.3), includeLinked: false))
        var found = QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project))
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found.first?.fix, "a slip would move 10 s the voice isn't under")

        try c.run("Longer", .trim(clipID: voice.id, edge: .end, to: t(40), ripple: false, includeLinked: false))
        XCTAssertNotNil(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)).first?.fix)
        try c.run("Lock", .updateTrack(trackID: f.track("Camera").id, patch: .object(["locked": .bool(true)])))
        found = QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project))
        XCTAssertNil(found.first?.fix, "it would fail the whole batch")
        XCTAssertTrue(found.first?.message.contains("locked") ?? false)
    }

    func testDifferentSpeedsAreComparedAtBothEnds() throws {
        let (_, c) = try Fixture.edited()
        // In step at the middle only: the camera at 1x from 10 s, the voice
        // at 1.2x from 9 s, over 0-10 s.
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(10), end: t(11))], trackIDs: nil))
        let camera = c.clips("Camera")[0], voice = c.clips("Voice")[0]
        var project = c.project
        for (id, start, speed) in [(camera.id, 10.0, 1.0), (voice.id, 9.0, 1.2)] {
            let (location, i) = project.location(ofClip: id)!
            project[location].clips[i].sourceStart = t(start)
            project[location].clips[i].speed = speed
        }
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: project, ranges: [TimeRange(start: t(0), end: t(10))]).count, 1)
    }

    func testTheSlipGoesLast() throws {
        let slip = CheckProblem(kind: .pictureOffVoice, start: t(0), end: t(20), message: "off", fix: .slip(clipID: "clip_c", delta: t(0.3), includeLinked: false))
        let hold = CheckProblem(kind: .flicker, start: t(10), end: t(10.033), message: "Flicker", fix: .holdFrame(clipID: "clip_c", range: TimeRange(start: t(10), end: t(10.033))))
        let jump = CheckProblem(kind: .doubleJump, start: t(2), end: t(2.2), message: "Jump", fix: .updateClip(clipID: "clip_c", patch: .object(["sourceStart": .number(12.3)])))
        XCTAssertEqual(QualityCheck.commands(fixing: [hold, slip]), [hold.fix!, slip.fix!], "the hold, by the time the flash was seen at, before the slip moves it")
        XCTAssertEqual(QualityCheck.commands(fixing: [hold, slip, jump]), [jump.fix!, hold.fix!, slip.fix!], "a patch sets the source start outright, so the slip goes after it")
        XCTAssertEqual(QualityCheck.fixLabel(for: [hold, slip]), "Put the picture back in step with the voice, and hold the frame before each flicker")
    }

    func testASlowClipIsJudgedOnTheTimeline() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(10), end: t(11))], trackIDs: nil))
        let camera = c.clips("Camera")[0], voice = c.clips("Voice")[0]
        var project = c.project
        // 10 ms of file apart at 0.1x is 100 ms on the timeline: 3 frames.
        for (id, start) in [(camera.id, 1.010), (voice.id, 1.0)] {
            let (location, i) = project.location(ofClip: id)!
            project[location].clips[i].sourceStart = t(start)
            project[location].clips[i].speed = 0.1
        }
        let found = QualityCheck.pictureOffVoice(in: project, ranges: [TimeRange(start: t(0), end: t(10))])
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first?.message.contains("0.10 s ahead") ?? false, found.first?.message ?? "")
    }

    func testACutawayOnAFollowTrackAndAnLCutArentOffTheVoice() throws {
        let (f, c) = try Fixture.edited()
        // B-roll from the same take (his hands), unlinked, on a follow track.
        let broll = f.track("B-roll")
        try c.run("Cutaway", .insertClip(trackID: broll.id, clip: Clip(id: "clip_hands", content: .media(mediaID: "med_camera"), start: t(3), duration: t(5), sourceStart: t(50))))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [], "a cutaway is shown as it is")

        // An L-cut: the camera runs 0.2 s into the next clip's sound.
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(20), end: t(30))], trackIDs: nil))
        let camera = c.clips("Camera")[0]
        try c.run("L-cut", .trim(clipID: c.clips("Voice")[0].id, edge: .end, to: t(19.8), ripple: false, includeLinked: false))
        _ = camera
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [], "the next clip's sound under it isn't its voice")
    }

    func testSoundSilentWhereItsUnderThePictureIsntTheVoice() {
        var voice = Clip(id: "clip_v", content: .media(mediaID: "med_camera"), start: .zero, duration: t(20))
        voice.keyframes["audio.gainDB"] = [Keyframe(time: .zero, value: .number(0), interpolation: .hold), Keyframe(time: t(10), value: .number(-100))]
        XCTAssertFalse(QualityCheck.silent(voice))
        XCTAssertTrue(QualityCheck.silent(voice, over: TimeRange(start: t(10), end: t(20))))
        // Down until the very end, where it comes up: the end isn't played.
        var held = Clip(id: "clip_h", content: .media(mediaID: "med_camera"), start: .zero, duration: t(10))
        held.keyframes["audio.gainDB"] = [Keyframe(time: .zero, value: .number(-100), interpolation: .hold), Keyframe(time: t(10), value: .number(0))]
        XCTAssertTrue(QualityCheck.silent(held))
    }

    func testAnLCutWithTheNextVoiceUnderThePictureIsntOff() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(20), end: t(30))], trackIDs: nil))
        let voices = c.clips("Voice")
        // The next phrase starts 0.2 s early, under the outgoing picture.
        try c.run("L-cut", .trim(clipID: voices[0].id, edge: .end, to: t(19.8), ripple: false, includeLinked: false),
                  .trim(clipID: voices[1].id, edge: .start, to: t(19.8), ripple: false, includeLinked: false))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [])
        // Unlinked, it's still in step with its own sound, so the next
        // clip's under it isn't counted.
        try c.run("Unlink", .updateClip(clipID: c.clips("Camera")[0].id, patch: .object(["linkGroup": .null])))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [])
    }

    func testAHoldAndASlipInOneFixBothLandOnTheirFrames() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(40), end: t(41))], trackIDs: nil))
        let camera = c.clips("Camera")[0]
        try c.run("Drift", .slip(clipID: camera.id, delta: t(0.3), includeLinked: false))
        let drifted = c.clips("Camera")[0]
        // The check sees a flash at 10 s on the drifted picture.
        let flashSource = drifted.sourceTime(atTimelineTime: t(10))
        let hold = CheckProblem(kind: .flicker, start: t(10), end: t(10) + frame, message: "Flicker", fix: .holdFrame(clipID: camera.id, range: TimeRange(start: t(10), duration: frame)))
        let found = QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)) + [hold]
        try c.apply(EditBatch(label: QualityCheck.fixLabel(for: found), commands: QualityCheck.commands(fixing: found)))
        let fixed = c.clips("Camera")[0]
        XCTAssertEqual(fixed.holds.first?.source.start, flashSource, "the hold is on the flash's frames, wherever the slip put them")
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)), [])
    }

    func testACameraWhoseVoiceWasUnlinkedIsStillChecked() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(40), end: t(41))], trackIDs: nil))
        try c.run("Unlink voice", .updateClip(clipID: c.clips("Voice")[0].id, patch: .object(["linkGroup": .null])))
        try c.run("Drift", .slip(clipID: c.clips("Camera")[0].id, delta: t(0.3), includeLinked: false))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)).count, 1, "linked to the screen, but none of its sound")
    }

    func testAnUnlinkedCameraInStepWithOneVoiceAndOffTheNextIsOff() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(40), end: t(41))], trackIDs: nil))
        let camera = c.clips("Camera")[0]
        try c.run("Unlink", .updateClip(clipID: camera.id, patch: .object(["linkGroup": .null])))
        // The voice is cut at 20 and its second half slipped 0.3 s: the
        // camera is in step with the first half only.
        try c.run("Blade", .blade(at: t(20), trackIDs: [c.project.track(named: "Voice")!.id], clipIDs: nil))
        let second = c.clips("Voice")[1]
        try c.run("Drift", .slip(clipID: second.id, delta: t(0.3), includeLinked: false))
        let found = QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project))
        XCTAssertEqual(found.map(\.start), [t(20)], "20 s off isn't an L-cut's tail")
    }

    func testAShortDriftedTailThatIsntAnotherShotsSoundIsOff() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(40), end: t(41))], trackIDs: nil))
        try c.run("Unlink", .updateClip(clipID: c.clips("Camera")[0].id, patch: .object(["linkGroup": .null])))
        try c.run("Blade", .blade(at: t(39.5), trackIDs: [c.project.track(named: "Voice")!.id], clipIDs: nil))
        try c.run("Drift", .slip(clipID: c.clips("Voice")[1].id, delta: t(-0.3), includeLinked: false))
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: all(c.project)).map(\.start), [t(39.5)], "half a second of its own take, off")
    }
}
