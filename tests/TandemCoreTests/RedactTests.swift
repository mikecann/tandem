import XCTest
@testable import TandemCore

/// `redact`: hiding a QR code, an email column or a phone's cards over a
/// stretch of time. In the Threadbear launch video that took 40 lines of
/// Python each time: a copy of each clip on its own track, lined up by hand,
/// cropped, pixelated and linked, which `check` then called the same shot twice.
final class RedactTests: XCTestCase {
    let email = Rect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)

    /// Every copy sits on a clip of the same file with the same range and
    /// source time, linked to it: what keeps the region hidden.
    func assertCovered(_ c: ProjectCoordinator, _ track: String = "Privacy (Screen)", file: StaticString = #filePath, line: UInt = #line) {
        let below = c.project.videoTracks.flatMap(\.clips).filter { !$0.isObscured }
        for copy in c.clips(track) {
            let match = below.first { $0.mediaID == copy.mediaID && $0.range == copy.range }
            XCTAssertNotNil(match, "nothing under \(copy.range)", file: file, line: line)
            XCTAssertEqual(match?.sourceStart, copy.sourceStart, file: file, line: line)
            XCTAssertEqual(match?.linkGroup, copy.linkGroup, file: file, line: line)
            XCTAssertNotNil(copy.linkGroup, file: file, line: line)
        }
    }

    func testHidesARegionOfTheScreenOnItsOwnTrackLinkedToThePieceItHides() throws {
        let (_, c) = try Fixture.edited()
        let result = try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: email, mediaID: "med_screen", name: "email column"))

        let names = c.project.videoTracks.map(\.name)
        XCTAssertEqual(names.firstIndex(of: "Privacy (Screen)"), names.firstIndex(of: "Screen")! + 1, "right above the screen, under the camera's PiP")
        XCTAssertEqual(c.project.track(named: "Privacy (Screen)")?.rippleMode, .cut)
        let copies = c.clips("Privacy (Screen)")
        XCTAssertEqual(copies.count, 1)
        let copy = copies[0]
        XCTAssertEqual(copy.range, TimeRange(start: t(10), end: t(15)))
        XCTAssertEqual(copy.name, "Privacy: email column")
        XCTAssertTrue(result.createdIDs.contains(copy.id))
        let crop = try XCTUnwrap(copy.video?.crop)
        XCTAssertEqual(crop.left, 0.1, accuracy: 1e-9)
        XCTAssertEqual(crop.top, 0.2, accuracy: 1e-9)
        XCTAssertEqual(crop.right, 0.6, accuracy: 1e-9)
        XCTAssertEqual(crop.bottom, 0.7, accuracy: 1e-9)
        XCTAssertEqual(copy.video?.effects.last?.type, "pixelate")
        XCTAssertEqual(copy.video?.effects.last?.params["scale"], .number(24), "the effect's own default")
        XCTAssertTrue(copy.isObscured)

        // The take's cut at the edges, so the copy is linked one clip a track.
        XCTAssertEqual(c.clips("Screen").map(\.range), [TimeRange(start: t(0), end: t(10)), copy.range, TimeRange(start: t(15), end: t(60))])
        XCTAssertEqual(c.clips("Camera").map(\.range), c.clips("Screen").map(\.range))
        XCTAssertEqual(c.clips("Voice").map(\.range), c.clips("Screen").map(\.range))
        XCTAssertEqual(c.project.linkedClipIDs(of: copy.id).count, 4, "screen, camera, voice and the copy")
        assertCovered(c)
        XCTAssertTrue(QualityCheck.sameShotTwice(in: c.project, ranges: [TimeRange(start: .zero, end: t(60))]).isEmpty, "a redaction isn't a second shot")
        assertValid(c.project)
    }

    func testACopyWithItsBlurOffOrRemovedIsntTheSameShotTwice() throws {
        // 189 "Same shot twice" notes on the launch video, one for each
        // copy whose blur Mike had switched off while he reviewed them.
        let (_, c) = try Fixture.edited()
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: email, mediaID: "med_screen", style: .blur))
        try c.run("Hide", .redact(range: TimeRange(start: t(30), end: t(35)), rect: email, mediaID: "med_screen", style: .blur))
        let copies = c.clips("Privacy (Screen)")
        let first = try XCTUnwrap(copies.first), second = try XCTUnwrap(copies.last)
        let blur = try XCTUnwrap(first.video?.effects.last)
        try c.run("Turn off blur", .updateEffect(clipID: first.id, effectID: blur.id, patch: .object(["enabled": .bool(false)])))
        try c.run("Remove blur", .removeEffect(clipID: second.id, effectID: try XCTUnwrap(second.video?.effects.last?.id)))
        XCTAssertEqual(QualityCheck.sameShotTwice(in: c.project, ranges: [TimeRange(start: .zero, end: t(60))]), [])
    }

    func testFollowsTheClipsPlacementSoAPiPIsHiddenWhereItsShown() throws {
        let (_, c) = try Fixture.edited()
        let screen = c.clips("Screen")[0]
        try c.run("PiP", .updateClip(clipID: screen.id, patch: .object(["video": .object([
            "transform": .object(["position": .object(["x": .number(0.3), "y": .number(0.6)]), "scale": .number(0.4)]),
            "crop": .object(["left": .number(0.2)])
        ])])))
        try c.run("Frame", .addEffect(clipID: screen.id, effect: Effect(type: "border", params: ["width": .number(4)])))
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: email, trackID: "Screen", style: .blur, size: 30))

        let copy = try XCTUnwrap(c.clips("Privacy (Screen)").first)
        XCTAssertEqual(copy.video?.transform, c.clips("Screen")[1].video?.transform)
        XCTAssertEqual(copy.video?.crop.left ?? 0, 0.2, accuracy: 1e-9, "the clip's own crop still holds")
        XCTAssertEqual(copy.video?.effects.map(\.type), ["blur"], "a border would frame the patch")
        XCTAssertEqual(copy.video?.effects.first?.params["radius"], .number(30))
        assertCovered(c)
    }

    func testRippleCutsAndMovesKeepItOnThePictureItHides() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: email, mediaID: "med_screen"))
        try c.run("Cut before", .cutRanges(ranges: [TimeRange(start: t(4), end: t(6))]))
        XCTAssertEqual(c.clips("Privacy (Screen)").map(\.range), [TimeRange(start: t(8), end: t(13))])
        try c.run("Cut inside", .rippleDeleteRange(range: TimeRange(start: t(9), end: t(10))))
        XCTAssertEqual(c.clips("Privacy (Screen)").map(\.range), [TimeRange(start: t(8), end: t(9)), TimeRange(start: t(9), end: t(12))])
        assertCovered(c)

        let piece = try XCTUnwrap(c.clips("Screen").first { $0.start == t(9) })
        try c.run("Slip", .slip(clipID: piece.id, delta: t(0.5)))
        assertCovered(c)
        try c.run("Trim", .trim(clipID: piece.id, edge: .end, to: t(11), ripple: true))
        assertCovered(c)
        assertValid(c.project)
    }

    func testNeverRunsPastTheTimeAskedFor() throws {
        // The Threadbear launch video: a blur on a thread that ended at
        // 7:07.467 snapped out to the clip's end at 7:07.817 and blurred
        // the next window for 0.35 s as it opened. Hiding a frame too long
        // is fine; a third of a second over the wrong picture isn't.
        let (_, c) = try Fixture.edited()
        try c.run("Hide", .redact(range: TimeRange(start: t(0.2), end: t(59.8)), rect: email, mediaID: "med_screen"))
        XCTAssertEqual(c.clips("Privacy (Screen)").map(\.range), [TimeRange(start: t(0.2), end: t(59.8))])
        XCTAssertEqual(c.clips("Screen").map(\.range), [
            TimeRange(start: t(0), end: t(0.2)), TimeRange(start: t(0.2), end: t(59.8)), TimeRange(start: t(59.8), end: t(60))
        ], "cut where asked, through-edits that play straight on")
        assertCovered(c)
        assertValid(c.project)
    }

    func testAnEdgeWithinAFrameOfAClipsEdgeGoesToItRatherThanLeaveASliver() throws {
        // A take tightened off the frame grid: the screen is cut at 10.01.
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10.01)))
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: email, mediaID: "med_screen"))
        XCTAssertEqual(c.clips("Privacy (Screen)").map(\.range), [TimeRange(start: t(10.01), end: t(15))],
                       "no 0.01 s copy over the clip before, and no 0.01 s of take cut off it")
        XCTAssertEqual(c.clips("Screen").map(\.range), [
            TimeRange(start: t(0), end: t(10.01)), TimeRange(start: t(10.01), end: t(15)), TimeRange(start: t(15), end: t(60))
        ])
        XCTAssertTrue(QualityCheck.slivers(in: c.project, ranges: [TimeRange(start: .zero, end: t(60))]).isEmpty)
        assertCovered(c)
    }

    func testARedactionsEdgeIsntACutForTheDoubleJumpCheck() throws {
        // The launch video: a blur starting 5 frames after a B-roll shot
        // ended, and check asked to run the shot on to it, as if the take
        // cut there. The take carries straight on; only the patch starts.
        let (_, c) = try Fixture.edited()
        // The camera in the corner, so the screen recording is what's seen.
        let camera = c.clips("Camera")[0]
        try c.run("PiP", .updateClip(clipID: camera.id, patch: .object(["video": .object(["transform": .object(["scale": .number(0.3)])])])))
        let everything = [TimeRange(start: .zero, end: t(60))]
        let before = QualityCheck.doubleJumps(in: c.project, ranges: everything)
        try c.run("Hide", .redact(range: TimeRange(start: t(25 + 5.0 / 30), end: t(28)), rect: email, mediaID: "med_screen"))
        try c.run("Hide", .redact(range: TimeRange(start: t(16), end: t(20 - 4.0 / 30)), rect: email, mediaID: "med_screen"))
        XCTAssertEqual(QualityCheck.doubleJumps(in: c.project, ranges: everything).map(\.message), before.map(\.message))

        // A take clip with a blur of its own is still the take: a cut into
        // it is a cut, and B-roll a few frames off it is a double jump.
        try c.run("Cut", .blade(at: t(40)))
        let after = try XCTUnwrap(c.clips("Screen").first { $0.start == t(40) })
        try c.run("Blur", .addEffect(clipID: after.id, effect: Effect(type: "blur", params: ["radius": .number(10)])))
        try c.run("Slip", .slip(clipID: after.id, delta: t(-2)))
        try c.run("Shot", .placeMedia(mediaIDs: ["med_broll"], at: t(40.1), sourceStart: t(1), duration: t(3)))
        XCTAssertTrue(QualityCheck.doubleJumps(in: c.project, ranges: everything).contains { $0.start == t(40) }, "the cut at 40 still counts")
    }

    func testOverlappingRedactionsStackOnTheirOwnTracks() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Email", .redact(range: TimeRange(start: t(10), end: t(20)), rect: email, mediaID: "med_screen"))
        try c.run("QR", .redact(range: TimeRange(start: t(12), end: t(18)), rect: Rect(x: 0.7, y: 0.7, width: 0.2, height: 0.2), mediaID: "med_screen"))
        let names = c.project.videoTracks.map(\.name)
        let screen = names.firstIndex(of: "Screen")!
        XCTAssertEqual(Array(names[screen...(screen + 2)]), ["Screen", "Privacy (Screen)", "Privacy (Screen) 2"])
        // The first copy's cut at 12 and 18 with the take, and both still cover.
        XCTAssertEqual(c.clips("Privacy (Screen)").map(\.range), [
            TimeRange(start: t(10), end: t(12)), TimeRange(start: t(12), end: t(18)), TimeRange(start: t(18), end: t(20))
        ])
        assertCovered(c)
        assertCovered(c, "Privacy (Screen) 2")

        // A third, after the second's done, fits on the first privacy track.
        try c.run("Later", .redact(range: TimeRange(start: t(30), end: t(35)), rect: email, mediaID: "med_screen"))
        XCTAssertEqual(c.clips("Privacy (Screen)").count, 4)
        XCTAssertEqual(c.project.videoTracks.filter { $0.name.hasPrefix("Privacy") }.count, 2)
    }

    func testARedactionOnAnAngleFollowsTheAngleOnAndOff() throws {
        let c = try SyncedPlacementTests.project()
        try c.run("Add the close-up", .placeSynced(mediaID: "med_angle"))
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(20)), rect: email, mediaID: "med_angle"))
        let names = c.project.videoTracks.map(\.name)
        XCTAssertEqual(names.firstIndex(of: "Privacy (Angle 2)"), names.firstIndex(of: "Angle 2")! + 1)
        XCTAssertEqual(c.clips("Privacy (Angle 2)").map(\.enabled), [false], "the angle's off, so the patch is too")

        try c.run("Show", .showAngle(range: TimeRange(start: t(5), end: t(25)), trackID: "Angle 2"))
        XCTAssertTrue(c.clips("Angle 2").filter { $0.range.overlaps(TimeRange(start: t(10), end: t(20))) }.allSatisfy(\.enabled),
                      "the privacy track isn't another angle that switches it off")
        XCTAssertEqual(c.clips("Privacy (Angle 2)").map(\.enabled), [true])
        try c.run("Back", .showAngle(range: TimeRange(start: t(5), end: t(25)), trackID: "Camera"))
        XCTAssertEqual(c.clips("Privacy (Angle 2)").map(\.enabled), [false])
        assertCovered(c, "Privacy (Angle 2)")
    }

    func testThePatchIsSolidEvenOverASeeThroughPicture() throws {
        // A see-through patch over a see-through picture lets the sharp one
        // show through it: at 50% each, a quarter of the private text.
        let (_, c) = try Fixture.edited()
        let screen = c.clips("Screen")[0]
        try c.run("Half", .updateClip(clipID: screen.id, patch: .object(["video": .object(["opacity": .number(0.5)])])))
        let result = try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: email, mediaID: "med_screen"))
        XCTAssertEqual(c.clips("Privacy (Screen)").first?.video?.opacity, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("solid") }, "\(result.warnings)")
    }

    func testFormatLayoutsAreHiddenWhereTheyShowTheRegionAndLeftAloneWhereTheyDont() throws {
        let (_, c) = try Fixture.edited()
        let screen = c.clips("Screen")[0]
        // The main layout crops the email column out; the short shows it,
        // and a square format crops it out too.
        try c.run("Crops", .updateClip(clipID: screen.id, patch: .object(["video": .object([
            "crop": .object(["left": .number(0.5)]),
            "formatOverrides": .object([
                "portrait": .object(["crop": .object(["left": .number(0)])]),
                "square": .object(["crop": .object(["left": .number(0.6)])])
            ])
        ])])))
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: email, mediaID: "med_screen"))
        let copy = try XCTUnwrap(c.clips("Privacy (Screen)").first, "the short still shows it, so it isn't skipped")
        let main = try XCTUnwrap(copy.video?.crop)
        XCTAssertGreaterThanOrEqual(main.left + main.right, 1, "nothing drawn where the main crop already hides it")
        XCTAssertEqual(copy.video?.formatOverrides["portrait"]?.crop?.left ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(copy.video?.formatOverrides["portrait"]?.hidden, false)
        XCTAssertEqual(copy.video?.formatOverrides["square"]?.hidden, true, "not the whole square shot pixelated")
    }

    func testASwitchBackToTheCameraTurnsOffOnlyTheRedactionsInIt() throws {
        let c = try SyncedPlacementTests.project()
        try c.run("Add the close-up", .placeSynced(mediaID: "med_angle"))
        try c.run("Show", .showAngle(range: TimeRange(start: t(20), end: t(30)), trackID: "Angle 2"))
        try c.run("Hide", .redact(range: TimeRange(start: t(20), end: t(30)), rect: email, mediaID: "med_angle"))
        try c.run("Back", .showAngle(range: TimeRange(start: t(25), end: t(27)), trackID: "Camera"))
        let copies = c.clips("Privacy (Angle 2)")
        XCTAssertEqual(copies.map(\.range), [
            TimeRange(start: t(20), end: t(25)), TimeRange(start: t(25), end: t(27)), TimeRange(start: t(27), end: t(30))
        ])
        XCTAssertEqual(copies.map(\.enabled), [true, false, true])
        assertCovered(c, "Privacy (Angle 2)")
    }

    func testSaysWhatsWrong() throws {
        let (_, c) = try Fixture.edited()
        let range = TimeRange(start: t(10), end: t(15))
        XCTAssertThrowsError(try c.run("None", .redact(range: range, rect: email)))
        XCTAssertThrowsError(try c.run("Outside", .redact(range: range, rect: Rect(x: 0.8, y: 0, width: 0.5, height: 0.5), mediaID: "med_screen")))
        XCTAssertThrowsError(try c.run("Sound", .redact(range: range, rect: email, trackID: "Voice")))
        XCTAssertThrowsError(try c.run("Nothing there", .redact(range: TimeRange(start: t(70), end: t(75)), rect: email, mediaID: "med_screen")))
        XCTAssertThrowsError(try c.run("Size", .redact(range: range, rect: email, mediaID: "med_screen", size: 0)))
        XCTAssertNil(c.project.track(named: "Privacy (Screen)"), "nothing changed")
    }
}
