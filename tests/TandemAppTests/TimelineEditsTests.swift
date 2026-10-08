import XCTest
@testable import TandemApp
@testable import TandemCore

final class MoveEditTests: XCTestCase {
    func testMoveOverwritesWhatItLandsOn() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let batch = TimelineEdits.move(f.project, clipIDs: [broll.id], delta: t(-5))
        XCTAssertEqual(batch?.commands, [.moveClips(clipIDs: [broll.id], delta: t(-5), toTrackID: nil, includeLinked: false, mode: .overwrite)])
        try f.apply(batch)
        XCTAssertEqual(f.clip("B-roll").range, TimeRange(start: t(15), end: t(20)))
    }

    func testMoveToAnotherTrack() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        try f.apply(TimelineEdits.move(f.project, clipIDs: [broll.id], delta: t(1), toTrackID: f.track("Graphics").id))
        XCTAssertTrue(f.clips("B-roll").isEmpty)
        XCTAssertEqual(f.clip("Graphics").range, TimeRange(start: t(21), end: t(26)))
        XCTAssertEqual(f.clip("Graphics").id, broll.id)
    }

    func testAGroupAcrossTracksOnlyMovesInTime() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let group = f.project.linkedClipIDs(of: f.clip("Camera", 1).id)
        let batch = TimelineEdits.move(f.project, clipIDs: group, delta: t(2), toTrackID: f.track("B-roll").id)
        guard case .moveClips(_, _, let toTrack, _, _)? = batch?.commands.first else { return XCTFail("expected a move") }
        XCTAssertNil(toTrack)
    }

    func testNoMoveNoBatch() throws {
        let f = try AppFixture()
        XCTAssertNil(TimelineEdits.move(f.project, clipIDs: [f.clip("B-roll").id], delta: .zero))
        XCTAssertNil(TimelineEdits.move(f.project, clipIDs: ["clip_missing"], delta: t(1)))
    }

    func testCommandDragInsertsAndLeavesAGap() throws {
        let f = try AppFixture()
        try f.blade(at: [10, 20])
        // Move the middle part of the take (10 to 20) to 40 as an insert.
        let group = f.project.linkedClipIDs(of: f.clip("Camera", 1).id)
        let batch = TimelineEdits.move(f.project, clipIDs: group, delta: t(30), insert: true)
        XCTAssertEqual(batch?.label, "Insert 3 clips")
        try f.apply(batch)
        let camera = f.clips("Camera").map(\.range)
        XCTAssertEqual(camera, [
            TimeRange(start: t(0), end: t(10)),
            TimeRange(start: t(20), end: t(40)),
            TimeRange(start: t(40), end: t(50)),
            TimeRange(start: t(50), end: t(70))
        ])
        XCTAssertEqual(f.clips("Camera")[2].sourceStart, t(10), "the moved clip keeps its media")
        XCTAssertEqual(f.clips("Voice").map(\.range), camera, "the take moved together")
        XCTAssertEqual(f.project.markers[0].time, t(30), "the marker is before the insert point")
        assertValid(f.project)
    }

    func testNudgeMovesByFramesAndStopsAtZero() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let batch = TimelineEdits.nudge(f.project, clipIDs: [broll.id], frames: -5)
        XCTAssertEqual(batch?.commands, [.moveClips(clipIDs: [broll.id], delta: Time.frames(-5, at: .fps30), toTrackID: nil, includeLinked: false, mode: .overwrite)])
        let camera = f.clip("Camera")
        let atZero = TimelineEdits.nudge(f.project, clipIDs: [camera.id], frames: -1)
        XCTAssertNil(atZero, "already at 0")
    }
}

final class RemoveEditTests: XCTestCase {
    func testDeleteLiftsAndShiftDeleteRipples() throws {
        let f = try AppFixture()
        try f.blade(at: [10, 20])
        let middle = Set(f.project.linkedClipIDs(of: f.clip("Camera", 1).id))
        let lift = TimelineEdits.remove(f.project, clipIDs: middle, ripple: false)
        XCTAssertEqual(lift?.label, "Delete 3 clips")
        let ripple = try XCTUnwrap(TimelineEdits.remove(f.project, clipIDs: middle, ripple: true))
        try f.apply(ripple)
        XCTAssertEqual(f.clips("Camera").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(50))])
        XCTAssertEqual(f.clip("B-roll").start, t(10), "follow tracks moved with the take")
    }

    func testOptionSelectedSideRemovesOnlyThatSide() throws {
        let f = try AppFixture()
        let voice = f.clip("Voice")
        try f.apply(TimelineEdits.remove(f.project, clipIDs: [voice.id], ripple: false))
        XCTAssertTrue(f.clips("Voice").isEmpty)
        XCTAssertEqual(f.clips("Camera").count, 1)
    }

    func testLiftRangeLeavesAGapOnEveryUnlockedTrack() throws {
        let f = try AppFixture()
        let batch = try XCTUnwrap(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(10), end: t(22))))
        XCTAssertEqual(batch.label, "Lift in to out")
        try f.apply(batch)
        for name in ["Camera", "Screen", "Voice", "Music"] {
            XCTAssertEqual(f.clips(name).map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(22), end: t(60))], name)
        }
        XCTAssertEqual(f.clip("Camera", 1).sourceStart, t(22), "the right part still shows the same media")
        XCTAssertEqual(f.clip("B-roll").range, TimeRange(start: t(22), end: t(25)))
        XCTAssertEqual(f.clip("B-roll").sourceStart, t(3))
        XCTAssertEqual(f.project.markers[0].time, t(30), "markers stay put")
        assertValid(f.project)
    }

    func testLiftRangeKeepsMarkersInsideTheRange() throws {
        let f = try AppFixture()
        try f.coordinator.apply(EditBatch(label: "Marker", commands: [.addMarker(marker: Marker(id: "mk_in", time: t(15), name: "Inside"))]))
        try f.apply(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(10), end: t(20))))
        XCTAssertEqual(f.project.markers.first { $0.id == "mk_in" }?.time, t(15))
    }

    func testLiftRangeSkipsLockedTracks() throws {
        let f = try AppFixture()
        try f.coordinator.apply(EditBatch(label: "Lock", commands: [.updateTrack(trackID: f.track("Music").id, patch: .object(["locked": .bool(true)]))]))
        try f.apply(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(10), end: t(20))))
        XCTAssertEqual(f.clips("Music").map(\.range), [TimeRange(start: t(0), end: t(60))])
        XCTAssertEqual(f.clips("Camera").count, 2)
    }

    func testExtractRangeClosesTheGap() throws {
        let f = try AppFixture()
        try f.apply(TimelineEdits.extractRange(f.project, range: TimeRange(start: t(10), end: t(12))))
        XCTAssertEqual(f.clips("Camera").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(58))])
        XCTAssertEqual(f.clips("Music").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(58))], "named tracks are cut, not followed")
        XCTAssertEqual(f.project.duration, t(58))
    }

    func testEmptyRangesDoNothing() throws {
        let f = try AppFixture()
        XCTAssertNil(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(5), end: t(5))))
        XCTAssertNil(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(100), end: t(110))))
        XCTAssertNil(TimelineEdits.extractRange(f.project, range: TimeRange(start: t(5), end: t(4))))
    }
}

final class CutEditTests: XCTestCase {
    func testBladeAtPlayheadCutsTargetedTracks() throws {
        let f = try AppFixture()
        let batch = TimelineEdits.bladeAtPlayhead(f.project, playhead: t(22), selection: [])
        XCTAssertEqual(batch?.commands, [.blade(at: t(22))])
        XCTAssertNil(TimelineEdits.bladeAtPlayhead(f.project, playhead: t(99), selection: []))
    }

    func testBladeAtPlayheadPrefersTheSelection() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let batch = TimelineEdits.bladeAtPlayhead(f.project, playhead: t(22), selection: [broll.id, f.clip("Camera").id])
        XCTAssertEqual(batch?.commands, [.blade(at: t(22), clipIDs: [f.clip("Camera").id, broll.id])], "timeline order: V2 before V3")
    }

    func testBladeToolClick() throws {
        let f = try AppFixture()
        let camera = f.clip("Camera")
        XCTAssertEqual(TimelineEdits.blade(f.project, clipID: camera.id, at: t(5), allTracks: false)?.commands, [.blade(at: t(5), clipIDs: [camera.id])])
        XCTAssertEqual(TimelineEdits.blade(f.project, clipID: camera.id, at: t(5), allTracks: true)?.commands, [.blade(at: t(5))])
        XCTAssertNil(TimelineEdits.blade(f.project, clipID: camera.id, at: .zero, allTracks: false), "on the edge there's nothing to cut")
    }

    func testQRippleTrimsTheStartAndMovesThePlayheadToTheEdit() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let result = try XCTUnwrap(TimelineEdits.rippleTrimToPlayhead(f.project, playhead: t(14), edge: .start, selection: []))
        XCTAssertEqual(result.playhead, t(10))
        try f.apply(result.batch)
        XCTAssertEqual(f.clip("Camera", 1).range, TimeRange(start: t(10), end: t(56)))
        XCTAssertEqual(f.clip("Camera", 1).sourceStart, t(14))
        XCTAssertEqual(f.clip("Voice", 1).sourceStart, t(14), "the linked sound went with it")
        XCTAssertEqual(f.clip("B-roll").start, t(16), "later clips closed up")
        assertValid(f.project)
    }

    func testWRippleTrimsTheEnd() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let result = try XCTUnwrap(TimelineEdits.rippleTrimToPlayhead(f.project, playhead: t(4), edge: .end, selection: []))
        XCTAssertEqual(result.playhead, t(4))
        try f.apply(result.batch)
        XCTAssertEqual(f.clip("Camera", 0).range, TimeRange(start: t(0), end: t(4)))
        XCTAssertEqual(f.clip("Camera", 1).range, TimeRange(start: t(4), end: t(54)))
    }

    func testQOnTheEditPointDoesNothing() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        XCTAssertNil(TimelineEdits.rippleTrimToPlayhead(f.project, playhead: t(10), edge: .start, selection: []))
    }

    func testSlipConvertsTimelineDistanceToMedia() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll") // source starts at 1 s
        let batch = TimelineEdits.slip(f.project, clipID: broll.id, timelineDelta: t(0.5), includeLinked: true)
        XCTAssertEqual(batch?.commands, [.slip(clipID: broll.id, delta: t(-0.5), includeLinked: true)])
        try f.apply(batch)
        XCTAssertEqual(f.clip("B-roll").sourceStart, t(0.5))
        XCTAssertEqual(f.clip("B-roll").start, t(20), "slipping never moves the clip")
    }
}

final class FreezeFrameEditTests: XCTestCase {
    /// Filmora's freeze frame, for the whole picture: the camera over the
    /// screen, each cut at the playhead and holding its own frame there for
    /// five seconds. Everything after moves five seconds later on every
    /// track, so the take's sound waits with them.
    func testAFreezeFrameHoldsTheWholePictureForFiveSecondsAndPushesTheRestLater() throws {
        let f = try AppFixture()
        let before = f.project
        let camera = f.clip("Camera")
        let screen = f.clip("Screen")
        let batch = try XCTUnwrap(TimelineEdits.freezeFrame(f.project, playhead: t(10), selection: [], freezeID: "clip_frz"))
        XCTAssertEqual(batch.label, "Freeze frame")
        try f.apply(batch)

        let held = [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(15)), TimeRange(start: t(15), end: t(65))]
        XCTAssertEqual(f.clips("Camera").map(\.range), held)
        XCTAssertEqual(f.clips("Screen").map(\.range), held, "the screen under the camera holds too, rather than going black")
        let cameraFreeze = f.clip("Camera", 1)
        let screenFreeze = f.clip("Screen", 1)
        XCTAssertEqual(cameraFreeze.id, "clip_frz", "the clip Mike froze")
        XCTAssertTrue(cameraFreeze.freezeFrame && screenFreeze.freezeFrame)
        XCTAssertEqual(cameraFreeze.sourceStart, t(10), "the camera's frame at the playhead")
        XCTAssertEqual(screenFreeze.mediaID, "med_screen")
        XCTAssertEqual(screenFreeze.sourceStart, t(10.5), "the screen's own frame there: it started half a second earlier")
        XCTAssertEqual(f.clip("Camera", 0).id, camera.id)
        XCTAssertEqual(f.clip("Screen", 0).id, screen.id)
        XCTAssertEqual(f.clip("Camera", 2).sourceStart, t(10), "the rest plays on from the frame that held")

        XCTAssertEqual(f.clips("Voice").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(15), end: t(65))], "the camera's sound waits five seconds")
        XCTAssertEqual(Set(f.project.linkedClipIDs(of: "clip_frz")), [cameraFreeze.id, screenFreeze.id], "the freezes are linked, in a group of their own")
        let rest = Set(["Camera", "Screen", "Voice"].map { f.clips($0).last!.id })
        XCTAssertEqual(Set(f.project.linkedClipIDs(of: f.clip("Camera", 2).id)), rest, "the rest of the take stays linked")
        XCTAssertEqual(f.clip("B-roll").start, t(25), "later clips move five seconds")
        XCTAssertEqual(f.clip("Music").range, TimeRange(start: t(0), end: t(60)), "the music bed plays on under it")
        XCTAssertEqual(f.project.markers.first?.time, t(35))
        assertValid(f.project)

        f.coordinator.undo()
        XCTAssertEqual(f.project, before, "one undo puts it all back")
    }

    /// The freezes are linked, so a ripple trim of one moves the others'
    /// edges with it and the tracks stay in sync.
    func testARippleTrimOfOneFreezeTrimsThemAll() throws {
        let f = try AppFixture()
        try f.apply(TimelineEdits.freezeFrame(f.project, playhead: t(10), selection: [], freezeID: "clip_frz"))
        try f.coordinator.apply(EditBatch(label: "Shorter", commands: [.trim(clipID: "clip_frz", edge: .end, to: t(12), ripple: true)]))
        let shorter = [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(12)), TimeRange(start: t(12), end: t(62))]
        XCTAssertEqual(f.clips("Camera").map(\.range), shorter)
        XCTAssertEqual(f.clips("Screen").map(\.range), shorter, "the screen's freeze moved with the camera's")
        XCTAssertEqual(f.clips("Voice").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(12), end: t(62))])
        assertValid(f.project)
    }

    /// Every picture under the playhead holds, whichever clip Mike picked:
    /// a B-roll shot over the take is cut there too, rather than playing
    /// on over the freeze and coming out of step with the take. A track
    /// with nothing there isn't touched, and a title over it plays on.
    func testEveryPictureUnderThePlayheadHolds() throws {
        let f = try AppFixture()
        let title = Clip(id: "clip_title", content: .text(TextContent(text: "Hi")), start: t(21), duration: t(3))
        try f.coordinator.apply(EditBatch(label: "Title", commands: [.insertClip(trackID: f.track("Text").id, clip: title)]))
        // At 22 the B-roll (20 to 25, from 1 s into its file) covers the
        // camera, and Mike picked the camera.
        let camera = f.clip("Camera").id
        try f.apply(TimelineEdits.freezeFrame(f.project, playhead: t(22), selection: [camera], freezeID: "clip_frz"))
        XCTAssertEqual(f.clip("Camera", 1).id, "clip_frz")
        XCTAssertEqual(f.clips("B-roll").map(\.range), [
            TimeRange(start: t(20), end: t(22)),
            TimeRange(start: t(22), end: t(27)),
            TimeRange(start: t(27), end: t(30))
        ])
        XCTAssertTrue(f.clip("B-roll", 1).freezeFrame)
        XCTAssertEqual(f.clip("B-roll", 1).sourceStart, t(3), "the B-roll's own frame")
        XCTAssertEqual(Set(f.project.linkedClipIDs(of: "clip_frz")), Set(["Screen", "Camera", "B-roll"].map { f.clip($0, 1).id }))
        XCTAssertTrue(f.clips("Graphics").isEmpty, "nothing there, nothing to hold")
        XCTAssertEqual(f.clip("Text").range, title.range, "the title plays on over it")
        XCTAssertEqual(f.clip("Music").range, TimeRange(start: t(0), end: t(60)))
        assertValid(f.project)
    }

    /// A selected video clip under the playhead (the top one), otherwise
    /// the top video clip that shows there, decides whether there's
    /// anything to freeze.
    func testItFreezesTheSelectedVideoClipThereOrTheTopOne() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll").id
        let camera = f.clip("Camera").id
        let screen = f.clip("Screen").id
        // At 22 the B-roll covers the camera, which covers the screen.
        XCTAssertEqual(TimelineEdits.freezeTarget(f.project, playhead: t(22), selection: [])?.id, broll, "the top one")
        XCTAssertEqual(TimelineEdits.freezeTarget(f.project, playhead: t(22), selection: Set(f.project.linkedClipIDs(of: camera)))?.id, camera, "the top selected one: the camera over its screen")
        XCTAssertEqual(TimelineEdits.freezeTarget(f.project, playhead: t(22), selection: [screen])?.id, screen)
        XCTAssertEqual(TimelineEdits.freezeTarget(f.project, playhead: t(10), selection: [broll])?.id, camera, "a selected clip somewhere else doesn't count")
        XCTAssertNil(TimelineEdits.freezeTarget(f.project, playhead: t(60), selection: []), "nothing there")
        XCTAssertNil(TimelineEdits.freezeFrame(f.project, playhead: t(60), selection: []))
    }

    /// Only a moving picture starts a freeze: a title, a still and sound
    /// are passed over for the video under them. Once it starts, a still
    /// under the playhead holds as well, and so does a frame that was
    /// already held, so nothing under the freeze goes black.
    func testOnlyMovingPicturesStartAFreezeButStillsAndHeldFramesHoldToo() throws {
        let f = try AppFixture()
        let still = MediaItem(id: "med_logo", path: "images/logo.png", kind: .image, role: .image, width: 800, height: 600)
        let title = Clip(id: "clip_title", content: .text(TextContent(text: "Hi")), start: t(8), duration: t(4))
        try f.coordinator.apply(EditBatch(label: "Over the camera", commands: [
            .addMedia(item: still),
            .placeMedia(mediaIDs: ["med_logo"], at: t(8), duration: t(4), videoTrackID: f.track("Graphics").id),
            .insertClip(trackID: f.track("Text").id, clip: title),
            // The screen held on one frame, as an agent might have left it.
            .updateClip(clipID: f.clip("Screen").id, patch: .object(["freezeFrame": .bool(true)]))
        ]))
        let logo = f.clip("Graphics").id
        let camera = f.clip("Camera").id
        XCTAssertEqual(TimelineEdits.freezeTarget(f.project, playhead: t(10), selection: [])?.id, camera, "under the title and the still")
        XCTAssertEqual(TimelineEdits.freezeTarget(f.project, playhead: t(10), selection: ["clip_title", logo, f.clip("Screen").id])?.id, camera)
        XCTAssertNil(TimelineEdits.freezeFrame(f.project, clipID: "clip_title", at: t(10)))
        XCTAssertNil(TimelineEdits.freezeFrame(f.project, clipID: logo, at: t(10)))
        XCTAssertNil(TimelineEdits.freezeFrame(f.project, clipID: f.clip("Screen").id, at: t(10)), "it's already still")
        XCTAssertNil(TimelineEdits.freezeFrame(f.project, clipID: f.clip("Voice").id, at: t(10)), "sound has no picture")

        try f.apply(TimelineEdits.freezeFrame(f.project, clipID: camera, at: t(10), freezeID: "clip_frz"))
        XCTAssertEqual(f.clips("Graphics").map(\.range), [
            TimeRange(start: t(8), end: t(10)),
            TimeRange(start: t(10), end: t(15)),
            TimeRange(start: t(15), end: t(17))
        ], "the still holds through the freeze")
        XCTAssertEqual(f.clip("Graphics", 1).mediaID, "med_logo")
        XCTAssertEqual(f.clips("Screen").map(\.start), [t(0), t(10), t(15)])
        XCTAssertEqual(f.clips("Screen").map(\.sourceStart), [t(0.5), t(0.5), t(0.5)], "the held screen holds on")
        XCTAssertEqual(f.clip("Text").range, title.range, "a title plays on over it")
        XCTAssertEqual(f.project.linkedClipIDs(of: "clip_frz").count, 3, "the screen, the camera and the still")
        assertValid(f.project)
    }

    /// What shows is what decides: a hidden track or a clip that's off
    /// only counts when it's selected, and a locked track can't change,
    /// so it plays on, out of step, with a warning.
    func testHiddenOffAndLockedClipsArePassedOver() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll").id
        try f.coordinator.apply(EditBatch(label: "Hide", commands: [.updateTrack(trackID: f.track("B-roll").id, patch: .object(["hidden": .bool(true)]))]))
        XCTAssertEqual(TimelineEdits.freezeTarget(f.project, playhead: t(22), selection: [])?.id, f.clip("Camera").id, "the hidden B-roll doesn't show")
        XCTAssertEqual(TimelineEdits.freezeTarget(f.project, playhead: t(22), selection: [broll])?.id, broll, "unless it's picked")
        try f.coordinator.apply(EditBatch(label: "Off", commands: [.updateClip(clipID: f.clip("Camera").id, patch: .object(["enabled": .bool(false)]))]))
        XCTAssertEqual(TimelineEdits.freezeTarget(f.project, playhead: t(22), selection: [])?.id, f.clip("Screen").id, "the camera is off")
        try f.coordinator.apply(EditBatch(label: "Lock", commands: [.updateTrack(trackID: f.track("Screen").id, patch: .object(["locked": .bool(true)]))]))
        XCTAssertNil(TimelineEdits.freezeTarget(f.project, playhead: t(22), selection: []))
        XCTAssertNil(TimelineEdits.freezeFrame(f.project, clipID: f.clip("Screen").id, at: t(22)), "a locked track can't change")

        let g = try AppFixture()
        try g.coordinator.apply(EditBatch(label: "Lock", commands: [.updateTrack(trackID: g.track("Screen").id, patch: .object(["locked": .bool(true)]))]))
        let result = try g.apply(TimelineEdits.freezeFrame(g.project, playhead: t(10), selection: [], freezeID: "clip_frz"))
        XCTAssertEqual(g.clips("Camera").count, 3)
        XCTAssertEqual(g.clips("Screen").count, 1, "the locked screen plays on")
        XCTAssertTrue(result.warnings.contains { $0.contains("Locked track \"Screen\"") }, "\(result.warnings)")
    }

    /// Freeze frame on a clip's menu freezes at the playhead, so the
    /// playhead has to be on the clip. Picking a B-roll shot holds the
    /// take under it too, and the take's sound waits.
    func testTheMenusFreezeFrameFreezesThatClipAtThePlayhead() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll") // 20 to 25, from 1 s into its file
        XCTAssertNil(TimelineEdits.freezeFrame(f.project, clipID: broll.id, at: t(10)), "the playhead isn't on it")
        XCTAssertNil(TimelineEdits.freezeFrame(f.project, clipID: broll.id, at: t(25)), "its end is after its last frame")
        try f.apply(TimelineEdits.freezeFrame(f.project, clipID: broll.id, at: t(22), freezeID: "clip_frz"))
        XCTAssertEqual(f.clips("B-roll").map(\.range), [
            TimeRange(start: t(20), end: t(22)),
            TimeRange(start: t(22), end: t(27)),
            TimeRange(start: t(27), end: t(30))
        ])
        XCTAssertEqual(f.project.clip("clip_frz")?.sourceStart, t(3))
        let take = [TimeRange(start: t(0), end: t(22)), TimeRange(start: t(22), end: t(27)), TimeRange(start: t(27), end: t(65))]
        XCTAssertEqual(f.clips("Camera").map(\.range), take)
        XCTAssertEqual(f.clips("Screen").map(\.range), take)
        XCTAssertEqual(f.clips("Voice").map(\.range), [TimeRange(start: t(0), end: t(22)), TimeRange(start: t(27), end: t(65))])
        assertValid(f.project)

        // On its first frame there's nothing to cut: its hold goes in
        // before it.
        try f.apply(TimelineEdits.freezeFrame(f.project, clipID: broll.id, at: t(20), freezeID: "clip_first"))
        XCTAssertEqual(f.clips("B-roll").map(\.start), [t(20), t(25), t(27), t(32)])
        XCTAssertEqual(f.project.clip("clip_first")?.sourceStart, t(1))
        assertValid(f.project)
    }

    /// The frame that holds is the one that showed: an animation is read
    /// where the playhead was and kept there, a faster clip's frame is
    /// the one it had reached, and a clip holding its last frame past the
    /// end of its file freezes that frame.
    func testTheFreezeShowsWhatTheClipShowedThere() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll").id
        try f.coordinator.apply(EditBatch(label: "Zoom", commands: [
            .setKeyframes(clipID: broll, parameter: "video.transform.scale", keyframes: [
                Keyframe(time: .zero, value: .number(1), interpolation: .linear),
                Keyframe(time: t(4), value: .number(2), interpolation: .linear)
            ])
        ]))
        try f.apply(TimelineEdits.freezeFrame(f.project, clipID: broll, at: t(22), freezeID: "clip_zoom"))
        let zoomed = try XCTUnwrap(f.project.clip("clip_zoom"))
        XCTAssertEqual(zoomed.video?.transform.scale ?? 0, 1.5, accuracy: 1e-9, "halfway through the zoom")
        XCTAssertTrue(zoomed.keyframes.isEmpty, "and held there")

        let fast = try AppFixture()
        let shot = fast.clip("B-roll").id
        try fast.coordinator.apply(EditBatch(label: "Fast", commands: [.setSpeed(clipID: shot, speed: 2, ripple: true)]))
        try fast.apply(TimelineEdits.freezeFrame(fast.project, clipID: shot, at: t(21), freezeID: "clip_fast"))
        XCTAssertEqual(fast.project.clip("clip_fast")?.sourceStart, t(3), "a second in at double speed is two seconds into the file")
        XCTAssertEqual(fast.project.clip("clip_fast")?.speed, 1)
        assertValid(fast.project)

        let held = try AppFixture()
        let long = held.clip("B-roll").id
        // The file runs out at 29; the shot holds its last frame to 32.
        try held.coordinator.apply(EditBatch(label: "Hold", commands: [
            .updateClip(clipID: long, patch: .object(["holdEdges": .bool(true)])),
            .trim(clipID: long, edge: .end, to: t(32))
        ]))
        try held.apply(TimelineEdits.freezeFrame(held.project, clipID: long, at: t(31), freezeID: "clip_held"))
        XCTAssertEqual(held.project.clip("clip_held")?.sourceStart, t(10), "the end of the file, where its last frame is")
        assertValid(held.project)
    }
}

final class LayoutAndLinkEditTests: XCTestCase {
    func testLayoutKeysPreferSelectedVideoClips() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let targets = TimelineEdits.layoutTargets(f.project, playhead: t(22), selection: [broll.id, f.clip("Voice").id])
        XCTAssertEqual(targets, [broll.id])
    }

    func testLayoutKeysFallBackToTheCameraUnderThePlayhead() throws {
        let f = try AppFixture()
        XCTAssertEqual(TimelineEdits.layoutTargets(f.project, playhead: t(22), selection: []), [f.clip("Camera").id])
        let batch = try XCTUnwrap(TimelineEdits.applyLayout(f.project, preset: .pipRight, playhead: t(22), selection: []))
        XCTAssertEqual(batch.label, "Layout: PiP right")
        try f.apply(batch)
        XCTAssertEqual(f.clip("Camera").video?.transform.scale, 0.5)
        XCTAssertEqual(f.clip("Camera").video?.cutout?.enabled, true)
        XCTAssertNil(TimelineEdits.applyLayout(f.project, preset: .full, playhead: t(99), selection: []))
    }

    func testLinkToggles() throws {
        let f = try AppFixture()
        let group = Set(f.project.linkedClipIDs(of: f.clip("Camera").id))
        let unlink = try XCTUnwrap(TimelineEdits.toggleLink(f.project, selection: group))
        XCTAssertEqual(unlink.label, "Unlink 3 clips")
        try f.apply(unlink)
        XCTAssertNil(f.clip("Camera").linkGroup)
        let link = try XCTUnwrap(TimelineEdits.toggleLink(f.project, selection: [f.clip("Camera").id, f.clip("B-roll").id]))
        try f.apply(link)
        XCTAssertNotNil(f.clip("Camera").linkGroup)
        XCTAssertEqual(f.clip("Camera").linkGroup, f.clip("B-roll").linkGroup)
        XCTAssertNil(TimelineEdits.toggleLink(f.project, selection: [f.clip("Music").id]), "one unlinked clip has nothing to link to")
    }

    func testMarkersAndDefaultTransition() throws {
        let f = try AppFixture()
        try f.apply(TimelineEdits.addMarker(f.project, at: t(12), id: "mk_new"))
        XCTAssertEqual(f.project.markers.map(\.id), ["mk_new", "mk_s2"])
        XCTAssertNil(TimelineEdits.addDefaultTransition(f.project, playhead: t(12), selection: []), "no cut in reach")
        try f.blade(at: [12])
        let batch = try XCTUnwrap(TimelineEdits.addDefaultTransition(f.project, playhead: t(12.5), selection: [], id: "tr_d"))
        try f.apply(batch)
        let transition = try XCTUnwrap(f.track("Camera").transitions.first)
        XCTAssertEqual(transition.id, "tr_d")
        XCTAssertEqual(transition.type, .dissolve)
        XCTAssertEqual(transition.fromClipID, f.clip("Camera", 0).id)
    }

    func testDroppingMediaOnATrack() throws {
        let f = try AppFixture()
        let batch = try XCTUnwrap(TimelineEdits.placeMedia(f.project, mediaIDs: ["med_broll"], at: t(40), trackID: f.track("Graphics").id, insert: false))
        XCTAssertEqual(batch.label, "Place servers")
        try f.apply(batch)
        XCTAssertEqual(f.clip("Graphics").range, TimeRange(start: t(40), end: t(50)))
        let insert = try XCTUnwrap(TimelineEdits.placeMedia(f.project, mediaIDs: ["med_camera", "med_screen"], at: t(10), trackID: nil, insert: true))
        try f.apply(insert)
        XCTAssertEqual(f.clips("Camera").count, 3, "the insert split the take and the new take sits in the middle")
        assertValid(f.project)
    }
}

final class SelectionRuleTests: XCTestCase {
    func testClickSelectsTheLinkGroupUnlessOptionIsDown() throws {
        let f = try AppFixture()
        let camera = f.clip("Camera").id
        let group = Set(f.project.linkedClipIDs(of: camera))
        XCTAssertEqual(SelectionRules.click(camera, in: f.project, current: [], modifiers: .init(), linkedSelection: true), group)
        XCTAssertEqual(SelectionRules.click(camera, in: f.project, current: [], modifiers: .init(option: true), linkedSelection: true), [camera])
        XCTAssertEqual(SelectionRules.click(camera, in: f.project, current: [], modifiers: .init(), linkedSelection: false), [camera])
    }

    func testShiftTogglesAndPressingASelectedClipKeepsTheSelection() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll").id
        let music = f.clip("Music").id
        var selection = SelectionRules.click(broll, in: f.project, current: [], modifiers: .init(), linkedSelection: true)
        selection = SelectionRules.click(music, in: f.project, current: selection, modifiers: .init(shift: true), linkedSelection: true)
        XCTAssertEqual(selection, [broll, music])
        XCTAssertEqual(SelectionRules.click(broll, in: f.project, current: selection, modifiers: .init(), linkedSelection: true), selection)
        selection = SelectionRules.click(broll, in: f.project, current: selection, modifiers: .init(command: true), linkedSelection: true)
        XCTAssertEqual(selection, [music])
    }

    func testMarqueeAndSelectForward() throws {
        let f = try AppFixture()
        let picked = SelectionRules.marquee([f.clip("B-roll").id], in: f.project, current: [f.clip("Music").id], modifiers: .init(shift: true), linkedSelection: true)
        XCTAssertEqual(picked, [f.clip("B-roll").id, f.clip("Music").id])
        try f.blade(at: [30])
        let forward = SelectionRules.forward(from: t(20), in: f.project)
        XCTAssertEqual(forward, Set([f.clip("B-roll").id] + f.project.linkedClipIDs(of: f.clip("Camera", 1).id)))
    }

    func testEditPoints() throws {
        let f = try AppFixture()
        XCTAssertEqual(EditPoints.next(after: t(0), in: f.project), t(20))
        XCTAssertEqual(EditPoints.next(after: t(20), in: f.project), t(25))
        XCTAssertEqual(EditPoints.previous(before: t(20), in: f.project), t(0))
        XCTAssertNil(EditPoints.next(after: t(60), in: f.project))
        XCTAssertEqual(EditPoints.nextMarker(after: t(0), in: f.project), t(30))
    }
}
