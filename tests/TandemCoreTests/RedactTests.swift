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

    func testLayingOutAShortKeepsEachRedactionOverItsOwnRegion() throws {
        // The Coordinators Short: `tandem short` put the screen's blurred
        // sidebar lines in the top half like ordinary screen clips, with the
        // full frame showing, so the whole top window came out blurred.
        let (_, c) = try Fixture.edited()
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: email, mediaID: "med_screen", style: .blur))
        try c.run("Format", .updateSettings(patch: .object(["alternateFormats": .array([try JSONValue.from(OutputFormat.portrait)])])))
        let screen = try XCTUnwrap(c.clips("Screen").first { $0.range.start == t(10) })
        let copy = try XCTUnwrap(c.clips("Privacy (Screen)").first)
        func clip(_ id: String) throws -> Clip { try XCTUnwrap(c.project.clip(id)) }

        func assertOverItsRegion(_ copy: Clip, _ screen: Clip, file: StaticString = #filePath, line: UInt = #line) throws {
            let shown = try XCTUnwrap(copy.video?.formatOverrides["portrait"], file: file, line: line)
            XCTAssertEqual(shown.transform, screen.video?.formatOverrides["portrait"]?.transform, "the same place as the picture it hides", file: file, line: line)
            let crop = try XCTUnwrap(shown.crop, file: file, line: line)
            XCTAssertEqual(crop.left, 0.1, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(crop.top, 0.2, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(crop.right, 0.6, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(crop.bottom, 0.7, accuracy: 1e-9, file: file, line: line)
            XCTAssertNotEqual(shown.hidden, true, file: file, line: line)
            XCTAssertNotEqual(shown.cutout, true, file: file, line: line)
        }

        // Both in one go, as `tandem short` does.
        try c.run("Short", .setFormatLayout(clipIDs: [screen.id, copy.id], format: "portrait", slot: .top))
        try assertOverItsRegion(clip(copy.id), clip(screen.id))

        // Only the screen moved: its redactions go with it.
        try c.run("Lower", .setFormatLayout(clipIDs: [screen.id], format: "portrait", slot: .bottom))
        try assertOverItsRegion(clip(copy.id), clip(screen.id))

        // Made the canvas (`tandem short --copy`): still just the email column.
        try c.run("Adopt", .adoptFormat(format: "portrait"))
        let adopted = try XCTUnwrap(clip(copy.id).video)
        XCTAssertEqual(adopted.transform, try clip(screen.id).video?.transform)
        XCTAssertEqual(adopted.crop.left, 0.1, accuracy: 1e-9)
        XCTAssertEqual(adopted.crop.right, 0.6, accuracy: 1e-9)
        assertCovered(c)
        assertValid(c.project)
    }

    /// A screen with a redaction, and a portrait format to lay it out in.
    func shortReady(rect: Rect? = nil, mainCrop: Double = 0) throws -> (ProjectCoordinator, screen: Clip, copy: Clip) {
        let (_, c) = try Fixture.edited()
        if mainCrop > 0 {
            let first = c.clips("Screen")[0]
            try c.run("Crop", .updateClip(clipID: first.id, patch: .object(["video": .object(["crop": .object(["left": .number(mainCrop)])])])))
        }
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: rect ?? email, mediaID: "med_screen", style: .blur))
        try c.run("Format", .updateSettings(patch: .object(["alternateFormats": .array([try JSONValue.from(OutputFormat.portrait)])])))
        let screen = try XCTUnwrap(c.clips("Screen").first { $0.range.start == t(10) })
        return (c, screen, try XCTUnwrap(c.clips("Privacy (Screen)").first))
    }

    func testARegionTheLandscapeCropNarrowedIsHiddenWholeOnceTheShortShowsMore() throws {
        // The landscape crop hid the left half, so the copy only had to
        // cover 0.5 to 0.7. The short shows the whole frame, 0.3 to 0.5 too.
        let (c, screen, copy) = try shortReady(rect: Rect(x: 0.3, y: 0.2, width: 0.4, height: 0.1), mainCrop: 0.5)
        XCTAssertEqual(copy.video?.crop.left ?? 0, 0.5, accuracy: 1e-9)
        try c.run("Short", .setFormatLayout(clipIDs: [screen.id], format: "portrait", slot: .top))
        let crop = try XCTUnwrap(c.project.clip(copy.id)?.video?.formatOverrides["portrait"]?.crop)
        XCTAssertEqual(crop.left, 0.3, accuracy: 1e-9)
        XCTAssertEqual(crop.right, 0.3, accuracy: 1e-9)
    }

    func testACopyAskedIntoAnotherSlotStillGoesWhereItsPictureIs() throws {
        // A camera at full scale with its cutout on goes in the bottom half;
        // its copy has no cutout, so `tandem short` asked for the full frame.
        let (c, screen, copy) = try shortReady()
        try c.run("Bottom", .setFormatLayout(clipIDs: [screen.id], format: "portrait", slot: .bottom))
        try c.run("Full", .setFormatLayout(clipIDs: [copy.id], format: "portrait", slot: .full))
        let picture = try XCTUnwrap(c.project.clip(screen.id)?.video?.formatOverrides["portrait"]?.transform)
        XCTAssertEqual(c.project.clip(copy.id)?.video?.formatOverrides["portrait"]?.transform, picture)
    }

    func testALockedPrivacyTrackStopsALayoutThatWouldLeaveItsBlurBehind() throws {
        let (c, screen, _) = try shortReady()
        let privacy = try XCTUnwrap(c.project.track(named: "Privacy (Screen)"))
        try c.run("Lock", .updateTrack(trackID: privacy.id, patch: .object(["locked": .bool(true)])))
        XCTAssertThrowsError(try c.run("Short", .setFormatLayout(clipIDs: [screen.id], format: "portrait", slot: .top))) { error in
            XCTAssertTrue("\(error)".contains("locked"), "\(error)")
        }
        XCTAssertNil(c.project.clip(screen.id)?.video?.formatOverrides["portrait"], "nothing moved")
    }

    func testABlurAnOlderShortLeftWholeFrameIsCutBackToItsRegion() throws {
        // Copies made before the region was kept, laid out by the old short:
        // a whole-frame crop in the portrait format.
        let (c, screen, copy) = try shortReady()
        var legacy = c.project
        let at = legacy.location(ofClip: copy.id)!
        legacy[at.track].clips[at.index] = try JSONValue.applyMergePatch(.object(["video": .object([
            "redaction": .null,
            "formatOverrides": .object(["portrait": .object(["crop": .object(["left": .number(0)]), "transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.25)]), "scale": .number(1)])])])
        ])]), to: copy)
        legacy[at.track].clips[at.index].video?.redactionSources = nil
        legacy.sourceRedactions = nil
        legacy.schemaVersion = 2
        c.reload(legacy)
        XCTAssertNil(c.project.clip(copy.id)?.video?.redaction, "construct the historical saved state directly")
        try c.run("Short", .setFormatLayout(clipIDs: [screen.id], format: "portrait", slot: .top))
        try c.run("Adopt", .adoptFormat(format: "portrait"))
        let adopted = try XCTUnwrap(c.project.clip(copy.id)?.video)
        XCTAssertEqual(adopted.crop.left, 0.1, accuracy: 1e-9)
        XCTAssertEqual(adopted.crop.bottom, 0.7, accuracy: 1e-9)
        XCTAssertEqual(adopted.transform, c.project.clip(screen.id)?.video?.transform)
    }

    func testLayoutPresetsMoveTheBlurWithThePictureAndNeverFillTheFrameWithIt() throws {
        let (c, screen, copy) = try shortReady()
        try c.run("PiP", .applyLayout(clipIDs: [screen.id], preset: .pipRight))
        var moved = try XCTUnwrap(c.project.clip(copy.id)?.video)
        XCTAssertEqual(moved.transform, c.project.clip(screen.id)?.video?.transform)
        XCTAssertEqual(moved.crop.left, 0.1, accuracy: 1e-9)
        try c.run("Full", .applyLayout(clipIDs: [screen.id, copy.id], preset: .full))
        moved = try XCTUnwrap(c.project.clip(copy.id)?.video)
        XCTAssertEqual(moved.transform, c.project.clip(screen.id)?.video?.transform)
        XCTAssertEqual(moved.crop.left, 0.1, accuracy: 1e-9)
        XCTAssertEqual(moved.crop.right, 0.6, accuracy: 1e-9)
    }

    func testTheRegionIsKeptThroughSavingAndPatches() throws {
        let (c, screen, copy) = try shortReady(rect: Rect(x: 0.3, y: 0.2, width: 0.4, height: 0.1), mainCrop: 0.5)
        try c.run("Rename", .updateClip(clipID: copy.id, patch: .object(["name": .string("Privacy: sidebar")])))
        let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(c.project))
        XCTAssertEqual(saved.clip(copy.id)?.video?.redaction, Rect(x: 0.3, y: 0.2, width: 0.4, height: 0.1))
        let reopened = ProjectCoordinator(project: saved)
        try reopened.run("Short", .setFormatLayout(clipIDs: [screen.id], format: "portrait", slot: .top))
        XCTAssertEqual(reopened.project.clip(copy.id)?.video?.formatOverrides["portrait"]?.crop?.left ?? 0, 0.3, accuracy: 1e-9)
    }

    func testABlurFollowsThePictureItWasMadeOverNotAnotherOfTheSameFile() throws {
        // The same recording twice: full frame on "Screen", and as a PiP
        // on a track above. Both occurrences of the private source are protected.
        let (_, c) = try Fixture.edited()
        try c.run("Track", .addTrack(kind: .video, name: "Screen PiP", index: c.project.videoTracks.count, id: "trk_pip"))
        try c.run("PiP", .placeMedia(mediaIDs: ["med_screen"], at: .zero, sourceStart: c.clips("Screen")[0].sourceStart, duration: t(60), videoTrackID: "trk_pip", includeAudio: false))
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: email, mediaID: "med_screen"))
        let pip = try XCTUnwrap(c.clips("Screen PiP").first { $0.range.start == t(10) })
        let copy = try XCTUnwrap(c.clips("Privacy (Screen PiP)").first)
        try c.run("Corner", .applyLayout(clipIDs: [pip.id], preset: .pipLeft))
        XCTAssertEqual(c.project.clip(copy.id)?.video?.transform, c.project.clip(pip.id)?.video?.transform)
        try c.run("Back", .applyLayout(clipIDs: [copy.id], preset: .full))
        XCTAssertEqual(c.project.clip(copy.id)?.video?.transform, c.project.clip(pip.id)?.video?.transform, "still the PiP's place, not the full frame")

        // The full-frame one redacted too, its privacy track then dragged
        // above the PiP's: it still follows its own picture, by its link.
        let full = try XCTUnwrap(c.clips("Screen").first { $0.range.start == t(10) })
        let fullCopy = try XCTUnwrap(c.clips("Privacy (Screen)").first)
        try c.run("Drag", .moveTrack(trackID: c.project.track(named: "Privacy (Screen)")!.id, index: c.project.videoTracks.count - 1))
        try c.run("Split", .applyLayout(clipIDs: [full.id], preset: .split))
        XCTAssertEqual(c.project.clip(fullCopy.id)?.video?.transform, c.project.clip(full.id)?.video?.transform)
        XCTAssertEqual(c.project.clip(copy.id)?.video?.transform, c.project.clip(pip.id)?.video?.transform, "the PiP's blur stays on the PiP")
    }

    func testALandscapeLayoutRecutsTheBlurInFormatsThatShowTheLandscapeCrop() throws {
        // The short only moves the picture, so it shows the landscape crop;
        // a full-frame preset then uncrops it there too.
        let (_, c) = try Fixture.edited()
        try c.run("Crop and move", .updateClip(clipID: c.clips("Screen")[0].id, patch: .object(["video": .object([
            "crop": .object(["left": .number(0.5)]),
            "formatOverrides": .object([
                "portrait": .object(["transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.25)]), "scale": .number(1)])])
            ])
        ])])))
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: Rect(x: 0.3, y: 0.2, width: 0.4, height: 0.1), mediaID: "med_screen"))
        let screen = try XCTUnwrap(c.clips("Screen").first { $0.range.start == t(10) })
        let copy = try XCTUnwrap(c.clips("Privacy (Screen)").first)
        XCTAssertEqual(copy.video?.formatOverrides["portrait"]?.crop?.left ?? 0, 0.5, accuracy: 1e-9)
        try c.run("Full", .applyLayout(clipIDs: [screen.id], preset: .full))
        let video = try XCTUnwrap(c.project.clip(copy.id)?.video)
        XCTAssertEqual(video.crop.left, 0.3, accuracy: 1e-9)
        XCTAssertEqual(video.formatOverrides["portrait"]?.crop?.left ?? 1, 0.3, accuracy: 1e-9)
    }

    func testABlurOverTwoPicturesLaidOutApartStopsTheLayout() throws {
        // Its track locked, the picture was bladed under it without it.
        let (c, _, copy) = try shortReady()
        let privacy = try XCTUnwrap(c.project.track(named: "Privacy (Screen)"))
        try c.run("Lock", .updateTrack(trackID: privacy.id, patch: .object(["locked": .bool(true)])))
        let before = c.project
        XCTAssertThrowsError(try c.run("Blade", .blade(at: t(12), trackIDs: [c.project.track(named: "Screen")!.id])))
        XCTAssertEqual(c.project, before, "the locked blade refuses atomically")
        XCTAssertEqual(c.project.clip(copy.id)?.range, TimeRange(start: t(10), end: t(15)))
    }

    func testABlurShowsItsRegionWhereThePicturesAnimatedCropDoes() throws {
        let (_, c) = try Fixture.edited()
        let first = c.clips("Screen")[0]
        try c.run("Hold", .setKeyframes(clipID: first.id, parameter: "video.crop.left", keyframes: [Keyframe(time: .zero, value: .number(0), interpolation: .hold)]))
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: Rect(x: 0.2, y: 0.2, width: 0.2, height: 0.1), mediaID: "med_screen"))
        let copy = try XCTUnwrap(c.clips("Privacy (Screen)").first)
        XCTAssertNil(copy.keyframes["video.crop.left"], "a still crop, covering all the animation shows")
        XCTAssertEqual(copy.video?.crop.left ?? 0, 0.2, accuracy: 1e-9)
        let screen = try XCTUnwrap(c.clips("Screen").first { $0.range.start == t(10) })
        try c.run("Split", .applyLayout(clipIDs: [screen.id], preset: .split))
        let moved = try XCTUnwrap(c.project.clip(copy.id))
        XCTAssertEqual(moved.video?.crop.left ?? 0, 0.2, accuracy: 1e-9, "the picture still shows from 0.2 by its keyframe")
        XCTAssertEqual(moved.video?.crop.right ?? 0, 0.6, accuracy: 1e-9)

        // Animated from nothing to 0.4 over the clip: covered from 0.2 all along.
        try c.run("Animate", .setKeyframes(clipID: screen.id, parameter: "video.crop.left", keyframes: [
            Keyframe(time: .zero, value: .number(0), interpolation: .linear), Keyframe(time: t(5), value: .number(0.4))
        ]))
        try c.run("Full", .applyLayout(clipIDs: [screen.id], preset: .full))
        XCTAssertEqual(c.project.clip(copy.id)?.video?.crop.left ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertNil(c.project.clip(copy.id)?.keyframes["video.crop.left"])
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

    /// Sammy Cam: one 30 fps night shot placed as two clips side by side on
    /// B-roll, both a few ms off the frame grid. Its first clip redacted
    /// fine, but a redact ending partway through the second was refused as
    /// exposing a protected region, and so was a second region stacked on
    /// the second's tail. Cut at the project's frame, 553.3, the take split
    /// partway through the file's frame 88.3...88.333, which the copy then
    /// claimed, leaving it unhidden on the piece after (or the one before).
    func offGridBroll() throws -> ProjectCoordinator {
        var fixture = Fixture()
        fixture.project.media.append(MediaItem(
            id: "med_night", path: "broll/night.mp4", kind: .video, role: .broll,
            duration: t(510.534), frameRate: .fps30, width: 1920, height: 1080, hasVideo: true, hasAudio: true
        ))
        let c = ProjectCoordinator(project: fixture.project)
        try c.run("Place", .placeMedia(mediaIDs: ["med_night"], at: t(537.557), sourceStart: t(67.5), duration: t(12.934), includeAudio: false),
                  .placeMedia(mediaIDs: ["med_night"], at: t(550.491), sourceStart: t(85.5), duration: t(4.866), includeAudio: false))
        XCTAssertEqual(c.clips("B-roll").map(\.range), [TimeRange(start: t(537.557), end: t(550.491)), TimeRange(start: t(550.491), end: t(555.357))])
        return c
    }

    func testARangeEndingPartwayThroughAClipNextToAProtectedOneIsHidden() throws {
        let c = try offGridBroll()
        let kids = Rect(x: 0.44, y: 0.13, width: 0.13, height: 0.2)
        try c.run("First", .redact(range: TimeRange(start: t(537.557), end: t(550.491)), rect: kids, mediaID: "med_night"))
        try c.run("Second", .redact(range: TimeRange(start: t(550.491), end: t(553.291)), rect: Rect(x: 0.46, y: 0.18, width: 0.1, height: 0.16), mediaID: "med_night"))

        let pieces = c.clips("B-roll")
        XCTAssertEqual(pieces.map(\.range), [
            TimeRange(start: t(537.557), end: t(550.491)), TimeRange(start: t(550.491), end: t(553.291)), TimeRange(start: t(553.291), end: t(555.357))
        ], "cut where the file's frame 88.3 starts, not partway through it")
        XCTAssertEqual(pieces[2].sourceStart, t(88.3))
        XCTAssertEqual(c.clips("Privacy (B-roll)").map(\.range), Array(pieces.map(\.range).prefix(2)))
        assertCovered(c, "Privacy (B-roll)")
        // The tail stays sharp: no protected frame shows on it.
        XCTAssertFalse(RedactionSafety.protections(in: c.project).flatMap(\.sources).contains { $0.end > t(88.3) + Time.overlapTolerance })
        assertValid(c.project)
    }

    func testASecondRegionStackedOnAProtectedClipsTailIsHidden() throws {
        let c = try offGridBroll()
        let first = Rect(x: 0.46, y: 0.18, width: 0.1, height: 0.16)
        try c.run("Whole", .redact(range: TimeRange(start: t(550.491), end: t(555.357)), rect: first, mediaID: "med_night"))
        try c.run("Tail", .redact(range: TimeRange(start: t(553.291), end: t(555.357)), rect: Rect(x: 0.46, y: 0.3, width: 0.1, height: 0.1), mediaID: "med_night"))

        let pieces = Array(c.clips("B-roll").map(\.range).dropFirst())
        XCTAssertEqual(pieces, [TimeRange(start: t(550.491), end: t(553.291)), TimeRange(start: t(553.291), end: t(555.357))])
        XCTAssertEqual(c.clips("Privacy (B-roll)").map(\.range), pieces, "the first copy cut with the take")
        XCTAssertEqual(c.clips("Privacy (B-roll) 2").map(\.range), [TimeRange(start: t(553.291), end: t(555.357))])
        assertCovered(c, "Privacy (B-roll)")
        assertCovered(c, "Privacy (B-roll) 2")
        assertValid(c.project)
    }

    func testAMidClipEdgeOffTheFilesFrameGoesOutToItAndExposureIsStillRefused() throws {
        let c = try offGridBroll()
        let region = Rect(x: 0.46, y: 0.18, width: 0.1, height: 0.16)
        // 553.3 is on the project's frame grid but 9 ms into the file's
        // frame 88.3...88.333, so that frame's hidden too.
        try c.run("Hide", .redact(range: TimeRange(start: t(550.491), end: t(553.3)), rect: region, mediaID: "med_night"))
        XCTAssertEqual(c.clips("B-roll").map(\.range).last, TimeRange(start: t(550.491 + 2.8 + 1.0 / 30), end: t(555.357)))
        assertCovered(c, "Privacy (B-roll)")
        // Moving the sharp tail back over a protected frame is still refused.
        let tail = try XCTUnwrap(c.clips("B-roll").last)
        let before = c.project
        XCTAssertThrowsError(try c.run("Slip", .slip(clipID: tail.id, delta: t(-0.1)))) { error in
            XCTAssertTrue("\(error)".contains("expose a protected source region"), "\(error)")
        }
        XCTAssertEqual(c.project, before)
    }

    /// One file, 3 s of it from its start on B-roll.
    func oneClip(_ rate: FrameRate, speed: Double? = nil, sourceStart: Time = .zero, duration: Time = t(3)) throws -> ProjectCoordinator {
        var fixture = Fixture()
        fixture.project.media.append(MediaItem(
            id: "med_clip", path: "broll/clip.mp4", kind: .video, role: .broll,
            duration: t(60), frameRate: rate, width: 1920, height: 1080, hasVideo: true, hasAudio: false
        ))
        let c = ProjectCoordinator(project: fixture.project)
        try c.run("Place", .placeMedia(mediaIDs: ["med_clip"], at: .zero, sourceStart: sourceStart, duration: duration, includeAudio: false, speed: speed))
        return c
    }

    func testAMidClipEdgeOnA2997FileIsCutOnTheSharpSideOfItsFramesStart() throws {
        // A 29.97 fps frame rarely starts on a 48 kHz sample, where times
        // are kept, so the nearest sample can be inside the next frame.
        let c = try oneClip(FrameRate(30000, 1001))
        try c.run("Hide", .redact(range: TimeRange(start: .zero, end: t(1.0333333)), rect: email, mediaID: "med_clip"))
        try c.run("Hide", .redact(range: TimeRange(start: t(2.0), end: t(3)), rect: email, mediaID: "med_clip"))
        XCTAssertEqual(c.clips("Privacy (B-roll)").count, 2)
        assertCovered(c, "Privacy (B-roll)")
        assertValid(c.project)
    }

    func testAMidClipRangeOnASlowedClipIsCutOnTheFilesFrames() throws {
        let c = try oneClip(.fps30, speed: 0.9)
        try c.run("Hide", .redact(range: TimeRange(start: t(0.2666667), end: t(0.4)), rect: email, mediaID: "med_clip"))
        XCTAssertEqual(c.clips("Privacy (B-roll)").count, 1)
        assertCovered(c, "Privacy (B-roll)")
    }

    func testEveryFrameShownInTheRangeIsHiddenOnSlowMotion() throws {
        // A 25 fps file at quarter speed: a file frame lasts 0.16 s, five
        // of the project's frames, so an edge rounded to the nearest one
        // left the frame shown at 0.967 sharp.
        let c = try oneClip(.fps25, speed: 0.25)
        try c.run("Hide", .redact(range: TimeRange(start: t(0.2), end: t(1.0)), rect: email, mediaID: "med_clip"))
        let copy = try XCTUnwrap(c.clips("Privacy (B-roll)").first)
        XCTAssertLessThanOrEqual(copy.start, t(0.2))
        XCTAssertGreaterThanOrEqual(copy.end, t(1.0))
        assertCovered(c, "Privacy (B-roll)")
    }

    func testAFrameShownInTheRangeIsHiddenOnVerySlowMotionToo() throws {
        // A millisecond's leeway at the edge, taken in the file's time, is
        // a tenth of a second on the timeline at 1%: the frame at 1.0 was left sharp.
        let c = try oneClip(.fps30, speed: 0.01, sourceStart: t(0.0235))
        try c.run("Hide", .redact(range: TimeRange(start: t(0.2), end: t(1.0333333)), rect: email, mediaID: "med_clip"))
        let copy = try XCTUnwrap(c.clips("Privacy (B-roll)").first)
        XCTAssertLessThanOrEqual(copy.start, t(0.2))
        XCTAssertGreaterThan(copy.end, t(1.0))
        assertCovered(c, "Privacy (B-roll)")
    }

    func testAnEndNoSampleLandsNearOnAFrameStartSaysSo() throws {
        // 29.97 fps at 0.9x: none of the next eight frame starts falls on a sample.
        let c = try oneClip(FrameRate(30000, 1001), speed: 0.9)
        XCTAssertThrowsError(try c.run("Hide", .redact(range: TimeRange(start: t(0.4), end: t(0.7666667)), rect: email, mediaID: "med_clip"))) { error in
            XCTAssertTrue("\(error)".contains("Couldn't end the redaction"), "\(error)")
        }
    }

    func testLinkedClipsOfOneFileInStepButOfDifferentLengthsAreBothHidden() throws {
        let c = try oneClip(.fps30, duration: t(4))
        let screen = try XCTUnwrap(c.project.track(named: "Screen"))
        try c.run("Again", .placeMedia(mediaIDs: ["med_clip"], at: .zero, sourceStart: .zero, duration: t(3), videoTrackID: screen.id, includeAudio: false))
        try c.run("Link", .link(clipIDs: [c.clips("B-roll")[0].id, c.clips("Screen")[0].id]))
        try c.run("Hide", .redact(range: TimeRange(start: t(1), end: t(3.5)), rect: email, mediaID: "med_clip"))
        XCTAssertEqual(c.clips("Privacy (Screen)").map(\.range), [TimeRange(start: t(1), end: t(3))])
        XCTAssertEqual(c.clips("Privacy (B-roll)").map(\.range), [TimeRange(start: t(1), end: t(3.5))])
        assertCovered(c, "Privacy (Screen)")
        assertCovered(c, "Privacy (B-roll)")
    }

    func testLinkedClipsOfOneFileAtDifferentPointsInItsFramesSayToUnlinkThem() throws {
        let c = try oneClip(.fps30)
        let screen = try XCTUnwrap(c.project.track(named: "Screen"))
        try c.run("Again", .placeMedia(mediaIDs: ["med_clip"], at: .zero, sourceStart: t(0.009), duration: t(3), videoTrackID: screen.id, includeAudio: false))
        try c.run("Link", .link(clipIDs: [c.clips("B-roll")[0].id, c.clips("Screen")[0].id]))
        XCTAssertThrowsError(try c.run("Hide", .redact(range: TimeRange(start: t(1), end: t(2)), rect: email, mediaID: "med_clip"))) { error in
            XCTAssertTrue("\(error)".contains("Unlink them first"), "\(error)")
        }
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
