import XCTest
@testable import TandemCore

/// Another camera angle and an external mic, synced to the camera take by
/// sound (`tandem sync <file>` sets their take), put alongside it with
/// `placeSynced`, and `showAngle` to pick which angle shows where.
final class SyncedPlacementTests: XCTestCase {
    /// A 120 s camera take on Camera and Voice, plus a 60 s close-up and a
    /// 60 s mic that started 3 s before the camera (their take offsets say
    /// so, as `tandem sync` sets them).
    static func project(angleOffset: Double = 0, micOffset: Double = 0, micLength: Double = 60, secondMicLength: Double = 60) throws -> ProjectCoordinator {
        var project = Project.standard(name: "Interview")
        project.media = [
            MediaItem(id: "med_cam", path: "source/wide.mov", kind: .video, role: .camera, takeID: "take_i", takeOffset: t(3),
                      duration: t(120), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_angle", path: "source/close-up.mov", kind: .video, role: .broll, takeID: "take_i", takeOffset: t(angleOffset),
                      duration: t(60), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_mic", path: "source/mic.wav", kind: .audio, role: .other, takeID: "take_i", takeOffset: t(micOffset),
                      duration: t(micLength), hasAudio: true),
            // The other guest's own mic on a remote podcast.
            MediaItem(id: "med_mic2", path: "source/guest mic.m4a", kind: .audio, role: .other, takeID: "take_i", takeOffset: t(0),
                      duration: t(secondMicLength), hasAudio: true)
        ]
        let c = ProjectCoordinator(project: project)
        try c.run("Place the camera", .placeMedia(mediaIDs: ["med_cam"], at: .zero))
        return c
    }

    func testAnAnglePlacesHiddenOnItsOwnTrackAboveTheCameraLinkedToIt() throws {
        let c = try Self.project()
        let result = try c.run("Add the close-up", .placeSynced(mediaID: "med_angle"))
        let names = c.project.videoTracks.map(\.name)
        XCTAssertEqual(names, ["Screen", "Camera", "Angle 2", "B-roll", "Graphics", "Text"], "right above Camera")
        let track = try XCTUnwrap(c.project.track(named: "Angle 2"))
        XCTAssertEqual(track.rippleMode, .cut, "it's part of the take")
        XCTAssertTrue(result.createdIDs.contains(track.id))

        // The close-up runs out at 57 s on the timeline, so the take is cut there.
        XCTAssertEqual(c.clips("Camera").map(\.range), [TimeRange(start: t(0), end: t(57)), TimeRange(start: t(57), end: t(120))])
        XCTAssertEqual(c.clips("Voice").map(\.range), c.clips("Camera").map(\.range))
        let angle = try XCTUnwrap(track.clips.first)
        XCTAssertEqual(track.clips.count, 1)
        XCTAssertEqual(angle.range, TimeRange(start: t(0), end: t(57)))
        XCTAssertEqual(angle.sourceStart, t(3), "the close-up started 3 s before the camera")
        XCTAssertFalse(angle.enabled, "the camera still shows until an angle is picked")
        XCTAssertEqual(angle.linkGroup, c.clips("Camera")[0].linkGroup)
        XCTAssertNotNil(angle.linkGroup)
        XCTAssertFalse(c.project.audioTracks.flatMap(\.clips).contains { $0.mediaID == "med_angle" }, "its own sound doesn't play")
        assertValid(c.project)
    }

    func testAMicGoesOnVoiceAndTheCamerasSoundMovesToAMutedTrack() throws {
        let c = try Self.project()
        try c.run("Add the mic", .placeSynced(mediaID: "med_mic"))
        let voice = c.clips("Voice")
        XCTAssertEqual(voice.map(\.mediaID), ["med_mic", "med_cam"], "the camera's sound carries on after the mic stops")
        XCTAssertEqual(voice[0].range, TimeRange(start: t(0), end: t(57)))
        XCTAssertEqual(voice[0].sourceStart, t(3))
        XCTAssertEqual(voice[0].audio?.normalizeTo, -20, "levelled like speech")
        XCTAssertEqual(voice[0].linkGroup, c.clips("Camera")[0].linkGroup)

        let cameraSound = try XCTUnwrap(c.project.track(named: "Camera sound", kind: .audio))
        XCTAssertTrue(cameraSound.muted)
        XCTAssertEqual(cameraSound.rippleMode, .cut)
        XCTAssertEqual(c.project.audioTracks.map(\.name), ["Voice", "Camera sound", "Music", "SFX"])
        XCTAssertEqual(cameraSound.clips.map(\.range), [TimeRange(start: t(0), end: t(57))])
        XCTAssertEqual(cameraSound.clips[0].linkGroup, c.clips("Camera")[0].linkGroup)
        assertValid(c.project)
    }

    func testAFileThatStartsPartWayThroughTheClipCutsTheTakeAtBothEnds() throws {
        // The close-up started 10.01 s after the camera's first frame: its
        // first full frame on the timeline is at 10.0333.
        let c = try Self.project(angleOffset: 13.01)
        try c.run("Add the close-up", .placeSynced(mediaID: "med_angle"))
        let frame = FrameRate.fps30.frameDuration
        let start = Time.frames(301, at: .fps30)
        XCTAssertEqual(c.clips("Camera").map(\.start), [t(0), start, Time.frames(2100, at: .fps30)], "and back to the camera alone at 70 s")
        XCTAssertEqual(c.clips("Angle 2").first?.end, Time.frames(2100, at: .fps30))
        XCTAssertLessThan(Time.frames(2100, at: .fps30), t(70.01) + frame)
        let angle = c.clips("Angle 2")
        XCTAssertEqual(angle.count, 1)
        XCTAssertEqual(angle[0].start, start)
        XCTAssertEqual(angle[0].sourceStart.seconds, (start - t(10.01)).seconds, accuracy: 0.0001)
        XCTAssertLessThanOrEqual((angle[0].sourceStart + angle[0].duration).seconds, 60)
        assertValid(c.project)
    }

    func testASecondMicGoesOnItsOwnVoiceTrackAndLeavesTheCameraSoundAlone() throws {
        // tandem sync micA, then tandem sync micB later, as Databased S2E7
        // (two guests, each with their own mic) did.
        for batched in [false, true] {
            let c = try Self.project()
            if batched {
                try c.apply(EditBatch(label: "Both", commands: [.placeSynced(mediaID: "med_mic"), .placeSynced(mediaID: "med_mic2")]))
            } else {
                try c.run("First guest", .placeSynced(mediaID: "med_mic"))
                try c.run("Second guest", .placeSynced(mediaID: "med_mic2"))
            }
            XCTAssertEqual(c.project.audioTracks.map(\.name), ["Voice", "Voice 2", "Camera sound", "Music", "SFX"])
            XCTAssertEqual(c.clips("Voice").map(\.mediaID), ["med_mic", "med_cam"])
            let second = c.clips("Voice 2")
            XCTAssertEqual(second.map(\.mediaID), ["med_mic2"])
            XCTAssertEqual(second[0].range, TimeRange(start: t(0), end: t(57)))
            XCTAssertEqual(second[0].sourceStart, t(3))
            XCTAssertEqual(second[0].linkGroup, c.clips("Camera")[0].linkGroup)
            XCTAssertEqual(second[0].audio?.normalizeTo, -20, "levelled like speech")
            XCTAssertEqual(c.project.track(named: "Voice 2")?.rippleMode, .cut, "part of the take")
            XCTAssertEqual(c.clips("Camera sound").map(\.range), [TimeRange(start: t(0), end: t(57))])
            assertValid(c.project)
        }
    }

    func testASecondMicThatRunsLongerMovesTheRestOfTheCameraSoundToo() throws {
        let c = try Self.project(secondMicLength: 80)
        try c.run("First guest", .placeSynced(mediaID: "med_mic"))
        try c.run("Second guest", .placeSynced(mediaID: "med_mic2"))
        XCTAssertEqual(c.clips("Camera").map(\.start), [t(0), t(57), t(77)])
        XCTAssertEqual(c.clips("Voice").map(\.mediaID), ["med_mic", "med_cam"])
        XCTAssertEqual(c.clips("Voice").map(\.start), [t(0), t(77)])
        XCTAssertEqual(c.clips("Voice 2").map(\.range), [TimeRange(start: t(0), end: t(57)), TimeRange(start: t(57), end: t(77))])
        XCTAssertEqual(c.clips("Camera sound").map(\.range), [TimeRange(start: t(0), end: t(57)), TimeRange(start: t(57), end: t(77))])
        assertValid(c.project)
    }

    func testASecondMicThatStartsBeforeTheFirstPlacesWhereTheFirstHasNoClip() throws {
        // The first guest's mic covers 20-80 s, the second's 0-100 s, so
        // Voice 2 is made while the camera's sound is being moved.
        let c = try Self.project(micOffset: 23, secondMicLength: 103)
        try c.run("First guest", .placeSynced(mediaID: "med_mic"))
        try c.run("Second guest", .placeSynced(mediaID: "med_mic2"))
        XCTAssertEqual(c.project.audioTracks.map(\.name), ["Voice", "Voice 2", "Camera sound", "Music", "SFX"])
        XCTAssertEqual(c.clips("Camera").map(\.start), [t(0), t(20), t(80), t(100)])
        XCTAssertEqual(c.clips("Voice").map(\.mediaID), ["med_mic", "med_cam"])
        XCTAssertEqual(c.clips("Voice").map(\.start), [t(20), t(100)])
        XCTAssertEqual(c.clips("Voice 2").map(\.mediaID), ["med_mic2", "med_mic2", "med_mic2"])
        XCTAssertEqual(c.clips("Voice 2").map(\.start), [t(0), t(20), t(80)])
        XCTAssertEqual(c.clips("Camera sound").map(\.start), [t(0), t(20), t(80)])
        XCTAssertTrue(c.clips("Camera sound").allSatisfy { $0.mediaID == "med_cam" })
        assertValid(c.project)
    }

    func testAMicThatStopsJustShortOfTheTakesEndLeavesNoSliverAndKeepsItsFade() throws {
        // The mic ran 0.06 s less than the camera, so it stops two frames
        // before the take's last one. The cut there handed the fade to black
        // to a 67 ms sliver, where it played in 67 ms, and 67 ms of camera
        // sound played after the mic.
        let c = try Self.project(micLength: 122.94)
        let camera = try XCTUnwrap(c.project.track(named: "Camera"))
        try c.run("Fade", .addTransition(trackID: camera.id, transition: Transition(
            id: "tr_out", type: .fadeToBlack, duration: t(1), fromClipID: c.clips("Camera")[0].id, toClipID: nil
        )))
        let result = try c.run("Add the mic", .placeSynced(mediaID: "med_mic"))
        let end = Time.frames(3598, at: .fps30)
        XCTAssertEqual(c.clips("Camera").map(\.range), [TimeRange(start: t(0), end: end)])
        let fade = try XCTUnwrap(c.project.track(named: "Camera")?.transitions.first)
        XCTAssertEqual(fade.id, "tr_out")
        XCTAssertEqual(fade.fromClipID, c.clips("Camera")[0].id)
        XCTAssertEqual(fade.window(on: try XCTUnwrap(c.project.track(named: "Camera"))), TimeRange(start: end - t(1), end: end), "a whole second")
        XCTAssertEqual(c.clips("Voice").map(\.mediaID), ["med_mic"])
        XCTAssertEqual(c.clips("Voice")[0].range, TimeRange(start: t(0), end: end))
        XCTAssertEqual(c.clips("Camera sound").map(\.range), [TimeRange(start: t(0), end: end)])
        XCTAssertTrue(result.warnings.contains { $0.contains("last 67 ms") && $0.contains("fadeToBlack") }, "\(result.warnings)")
        assertValid(c.project)
    }

    func testASliverWithoutAFadeKeepsItsPictureAndMutesItsSound() throws {
        let c = try Self.project(micLength: 122.94)
        try c.run("Add the mic", .placeSynced(mediaID: "med_mic"))
        let end = Time.frames(3598, at: .fps30)
        XCTAssertEqual(c.clips("Camera").map(\.range), [TimeRange(start: t(0), end: end), TimeRange(start: end, end: t(120))])
        XCTAssertEqual(c.clips("Voice").map(\.mediaID), ["med_mic"], "no blip of camera sound after the mic")
        XCTAssertEqual(c.clips("Camera sound").map(\.range), [TimeRange(start: t(0), end: end), TimeRange(start: end, end: t(120))])
        XCTAssertEqual(c.clips("Camera sound")[1].linkGroup, c.clips("Camera")[1].linkGroup, "still linked to its picture")
        assertValid(c.project)
    }

    func testMovingAPlacedFilesTakeOffsetSaysItsClipsStayed() throws {
        let c = try Self.project()
        try c.run("Add the mic", .placeSynced(mediaID: "med_mic"))
        let before = c.clips("Voice")[0]
        let result = try c.run("Later", .updateMedia(mediaID: "med_mic", patch: .object(["takeOffset": .number(0.0436)])))
        XCTAssertEqual(c.clips("Voice")[0], before, "nothing moves")
        XCTAssertTrue(result.warnings.contains { $0.contains("+43.6 ms") && $0.contains("slip it by -43.6 ms") }, "\(result.warnings)")
        let quiet = try c.run("Path", .updateMedia(mediaID: "med_mic", patch: .object(["role": .string("other")])))
        XCTAssertTrue(quiet.warnings.isEmpty, "\(quiet.warnings)")
    }

    func testAnAngleAFrameLongerThanTheMicPlacedAfterItLeavesNoSliver() throws {
        let c = try Self.project()
        try c.run("Longer", .updateMedia(mediaID: "med_angle", patch: .object(["duration": .number(60.04)])))
        try c.apply(EditBatch(label: "Add", commands: [.placeSynced(mediaID: "med_mic"), .placeSynced(mediaID: "med_angle")]))
        XCTAssertEqual(c.clips("Camera").map(\.start), [t(0), t(57)])
        XCTAssertEqual(c.clips("Angle 2").map(\.range), [TimeRange(start: t(0), end: t(57))])
        assertValid(c.project)
    }

    func testRippleCutsMovesAndOneUndoKeepEverythingInStep() throws {
        let c = try Self.project()
        let before = c.project
        try c.apply(EditBatch(label: "Add the angle and mic", commands: [.placeSynced(mediaID: "med_angle"), .placeSynced(mediaID: "med_mic")]))
        try c.run("Cut", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(12))))
        // Every file plays the same moment at 10 s: camera 12, close-up and mic 15.
        for (track, expected) in [("Camera", 12.0), ("Voice", 15.0), ("Camera sound", 12.0), ("Angle 2", 15.0)] {
            let clip = try XCTUnwrap(c.project.track(named: track)?.clips.first { $0.start == t(10) }, track)
            XCTAssertEqual(clip.sourceStart, t(expected), track)
        }
        XCTAssertEqual(c.clips("Camera")[0].end, t(10))
        XCTAssertEqual(c.clips("Voice")[1].end, t(55))

        // Moves and trims of the camera take the angle, mic and camera sound with it.
        XCTAssertEqual(c.project.linkedClipIDs(of: c.clips("Camera")[1].id).count, 4, "camera, close-up, mic and camera sound")
        assertValid(c.project)

        _ = c.undo()
        _ = c.undo()
        XCTAssertEqual(c.project, before, "the angle and mic were one undo step")
    }

    func testAFileThatsNotInATakeOrAlreadyPlacedIsRefused() throws {
        let c = try Self.project()
        try c.run("Out of the take", .updateMedia(mediaID: "med_mic", patch: .object(["takeID": .null])))
        XCTAssertThrowsError(try c.run("Mic", .placeSynced(mediaID: "med_mic"))) { error in
            XCTAssertTrue("\(error)".contains("tandem sync"), "\(error)")
        }
        try c.run("Angle", .placeSynced(mediaID: "med_angle"))
        XCTAssertThrowsError(try c.run("Again", .placeSynced(mediaID: "med_angle"))) { error in
            XCTAssertTrue("\(error)".contains("already on the timeline"), "\(error)")
        }
    }
}

final class AngleSwitchTests: XCTestCase {
    private func placed() throws -> ProjectCoordinator {
        let c = try SyncedPlacementTests.project()
        try c.apply(EditBatch(label: "Add", commands: [.placeSynced(mediaID: "med_angle"), .placeSynced(mediaID: "med_mic")]))
        return c
    }

    func testShowingAnAngleOverARangeCutsTheTakeThereAndTurnsItOn() throws {
        let c = try placed()
        let sound = c.clips("Voice").map { ($0.mediaID, $0.sourceStart - $0.start) }
        try c.run("Close-up", .showAngle(range: TimeRange(start: t(20), end: t(30)), trackID: "Angle 2"))
        let angle = c.clips("Angle 2")
        XCTAssertEqual(angle.map(\.range), [TimeRange(start: t(0), end: t(20)), TimeRange(start: t(20), end: t(30)), TimeRange(start: t(30), end: t(57))])
        XCTAssertEqual(angle.map(\.enabled), [false, true, false])
        XCTAssertEqual(c.clips("Camera").map(\.start), [t(0), t(20), t(30), t(57)], "cut with it, so each piece stays linked")
        XCTAssertEqual(Set(c.clips("Voice").map { ($0.mediaID ?? "") + "\(($0.sourceStart - $0.start).flicks)" }),
                       Set(sound.map { ($0.0 ?? "") + "\($0.1.flicks)" }), "the sound plays just as before")
        XCTAssertTrue(c.clips("Camera").allSatisfy(\.enabled))
        for clip in angle {
            XCTAssertEqual(c.project.linkedClipIDs(of: clip.id).count, 4, "one of each, so trims and moves stay in step")
        }

        // Back to the wide shot for part of it.
        try c.run("Wide", .showAngle(range: TimeRange(start: t(25), end: t(27)), trackID: "Camera"))
        XCTAssertEqual(c.clips("Angle 2").map(\.enabled), [false, true, false, true, false])

        // A later ripple cut keeps the close-up where it was in the take.
        try c.run("Cut", .rippleDeleteRange(range: TimeRange(start: t(0), end: t(5))))
        let shown = c.clips("Angle 2").filter(\.enabled).map(\.range)
        XCTAssertEqual(shown, [TimeRange(start: t(15), end: t(20)), TimeRange(start: t(22), end: t(25))])

        // Joining through-edits leaves the switches, which change what shows.
        try c.run("Join", .joinThroughEdits())
        XCTAssertEqual(c.clips("Angle 2").filter(\.enabled).map(\.range), shown)
        assertValid(c.project)
    }

    func testRangesSnapToFramesAndAGapOrAFileOutsideATakeIsRefused() throws {
        let c = try placed()
        try c.run("Close-up", .showAngle(range: TimeRange(start: t(20.01), end: t(30.02)), trackID: "Angle 2"))
        XCTAssertEqual(c.clips("Angle 2").filter(\.enabled).map(\.range), [TimeRange(start: t(20), end: Time.frames(901, at: .fps30))])
        XCTAssertThrowsError(try c.run("Past it", .showAngle(range: TimeRange(start: t(58), end: t(60)), trackID: "Angle 2"))) { error in
            XCTAssertTrue("\(error)".contains("Angle 2"), "\(error)")
        }
        XCTAssertThrowsError(try c.run("B-roll", .showAngle(range: TimeRange(start: t(1), end: t(2)), trackID: "B-roll")))
    }
}
