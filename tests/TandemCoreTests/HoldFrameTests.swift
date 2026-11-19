import XCTest
@testable import TandemCore

/// `holdFrame`: a one-frame flash in a screen recording (the preview
/// jumping as Mike clicked) used to take blade, blade, unlink, slip and
/// relink. Now it's one command, kept on the clip by media time
/// (`Clip.holds`) rather than cut into pieces.
final class HoldFrameTests: XCTestCase {
    private func inStep(_ c: ProjectCoordinator, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(QualityCheck.pictureOffVoice(in: c.project, ranges: [TimeRange(start: .zero, end: c.project.duration)]), [], file: file, line: line)
    }

    func testHoldsTheFrameBeforeOverTheRangePictureOnly() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        let screen = f.clips("Screen")[0]
        let flash = TimeRange(start: t(10), duration: frame)
        let result = try c.run("Hold", .holdFrame(clipID: screen.id, range: flash))

        XCTAssertEqual(c.clips("Screen").count, 1, "the clip isn't cut")
        let held = c.clips("Screen")[0]
        XCTAssertEqual(held.id, screen.id)
        XCTAssertEqual(held.holds, [HeldFrame(
            source: TimeRange(start: screen.sourceTime(atTimelineTime: flash.start), end: screen.sourceTime(atTimelineTime: flash.end)),
            frame: screen.sourceTime(atTimelineTime: flash.start - frame)
        )])
        XCTAssertEqual(held.pictureTime(atTimelineTime: flash.start), screen.sourceTime(atTimelineTime: flash.start - frame), "the frame shown just before the flash")
        XCTAssertEqual(held.pictureTime(atTimelineTime: flash.end), screen.sourceTime(atTimelineTime: flash.end), "it plays on as it did after")
        XCTAssertEqual(held.sourceTime(atTimelineTime: flash.start), screen.sourceTime(atTimelineTime: flash.start), "the clip's own timing is untouched")
        XCTAssertTrue(result.createdIDs.isEmpty)

        XCTAssertEqual(c.clips("Voice").count, 1, "the sound isn't cut")
        XCTAssertEqual(c.clips("Camera").count, 1, "nor the camera")
        XCTAssertEqual(c.project.duration, f.project.duration, "nothing moves")
        assertValid(c.project)
    }

    /// The workbench short (19 Nov 2026): a hold over a flicker on the
    /// camera, then a ripple trim on the end of the voice clip just before
    /// a cut. With the hold cut into pieces in the voice's link group, the
    /// trim moved every piece's edge: the held frame grew to 0.233 s and the
    /// camera fell 0.2 to 0.4 s behind the voice from there to the end.
    func testARippleTrimAfterAHoldKeepsPictureAndVoiceInStep() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(11.8), end: t(12.5))], trackIDs: nil))
        let camera = c.clips("Camera")[0]
        try c.run("Hold", .holdFrame(clipID: camera.id, range: TimeRange(start: t(10), duration: frame)))
        let voice = c.clips("Voice")[0]
        try c.run("Let it finish", .trim(clipID: voice.id, edge: .end, to: voice.end + t(0.2), ripple: true, includeLinked: nil))

        XCTAssertEqual(c.clips("Camera").map(\.range), c.clips("Voice").map(\.range), "the picture's cuts are the voice's")
        XCTAssertEqual(c.clips("Camera")[0].holds.map { $0.source.duration }, [frame], "the hold is still one frame")
        inStep(c)

        let after = c.clips("Voice")[1]
        try c.run("Earlier", .trim(clipID: after.id, edge: .start, to: after.start + t(0.1), ripple: true, includeLinked: nil))
        inStep(c)
        assertValid(c.project)
    }

    /// Held by media time, a hold stays on its frames through cuts before
    /// it, on its edge and around it, in one batch with it or later.
    func testAHoldStaysOnItsFramesThroughCuts() throws {
        for cut in ["before", "on its edge", "same batch", "several ranges"] {
            let (f, c) = try Fixture.edited()
            let frame = f.project.settings.frameRate.frameDuration
            let camera = c.clips("Camera")[0]
            let hold = EditCommand.holdFrame(clipID: camera.id, range: TimeRange(start: t(30), duration: frame))
            let shown = camera.sourceTime(atTimelineTime: t(30) - frame)
            switch cut {
            case "before":
                try c.run("Hold", hold)
                try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(5), end: t(10))], trackIDs: nil))
            case "on its edge":
                try c.run("Hold", hold)
                try c.run("Blade", .blade(at: t(30), trackIDs: nil, clipIDs: nil))
            case "same batch":
                try c.apply(EditBatch(label: "Both", commands: [hold, .blade(at: t(30), trackIDs: nil, clipIDs: nil)]))
            default:
                try c.run("Hold", hold)
                try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(5), end: t(10)), TimeRange(start: t(20), end: t(30))], trackIDs: nil))
            }
            // Wherever it is now, the picture shows the held frame over the
            // flash's frames, and is in step with the voice everywhere.
            let pieces = c.clips("Camera")
            let flashTimes = pieces.compactMap { piece -> Time? in
                let at = piece.start + (t(30) - piece.sourceStart)
                return piece.range.contains(at) ? at : nil
            }
            XCTAssertEqual(flashTimes.count, 1, cut)
            if let at = flashTimes.first, let piece = pieces.first(where: { $0.range.contains(at) }) {
                XCTAssertEqual(piece.pictureTime(atTimelineTime: at), shown, cut)
            }
            XCTAssertEqual(pieces.map(\.range), c.clips("Voice").map(\.range), cut)
            inStep(c)

            // And a linked slip of each voice clip takes its picture along.
            for voice in c.clips("Voice") where voice.sourceStart > t(1) {
                try c.run("Slip", .slip(clipID: voice.id, delta: t(-0.2), includeLinked: nil))
            }
            inStep(c)
        }
    }

    func testAClipWithAHeldFrameSlidesAndChangesSpeedAsOne() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(20), end: t(21)), TimeRange(start: t(40), end: t(41))], trackIDs: nil))
        let middle = c.clips("Camera")[1]
        try c.run("Hold", .holdFrame(clipID: middle.id, range: TimeRange(start: t(30), duration: frame)))
        try c.run("Slide", .slide(clipID: middle.id, delta: frame))
        XCTAssertEqual(c.clips("Camera").count, 3)
        XCTAssertEqual(c.clips("Camera")[1].start, middle.start + frame)
        inStep(c)

        try c.run("Faster", .setSpeed(clipID: c.clips("Voice")[1].id, speed: 1.5, ripple: true, includeLinked: nil))
        XCTAssertEqual(c.clips("Camera")[1].holds.count, 1, "the hold rides the speed change")
        inStep(c)
        assertValid(c.project)
    }

    func testJoiningAThroughEditKeepsTheHoldsOfBothSides() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        try c.run("Blade", .blade(at: t(20), trackIDs: nil, clipIDs: nil))
        let right = c.clips("Camera")[1]
        try c.run("Hold", .holdFrame(clipID: right.id, range: TimeRange(start: t(30), duration: frame)))
        try c.run("Join", .join(clipID: c.clips("Camera")[0].id))
        XCTAssertEqual(c.clips("Camera").count, 1)
        XCTAssertEqual(c.clips("Camera")[0].holds.count, 1, "the right piece's hold is kept")
    }

    func testAJoinDoesntBringBackAHoldTrimmedOutOfSight() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        let screen = f.clips("Screen")[0]
        try c.run("Hold", .holdFrame(clipID: screen.id, range: TimeRange(start: t(45), duration: frame)))
        try c.run("Blade", .blade(at: t(30), trackIDs: nil, clipIDs: nil))
        // The left piece kept a copy of the hold at 45, out of its sight;
        // joined back, only the right piece's (which shows it) is kept.
        let pieces = c.clips("Screen")
        XCTAssertEqual(pieces.map(\.holds.count), [1, 1])
        try c.run("Join", .join(clipID: pieces[0].id))
        XCTAssertEqual(c.clips("Screen")[0].holds.count, 1)
        XCTAssertEqual(c.clips("Screen")[0].pictureTime(atTimelineTime: t(45)), screen.sourceTime(atTimelineTime: t(45)) - frame)
    }

    func testHoldsThatMeetBecomeOne() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        let screen = f.clips("Screen")[0]
        try c.run("Hold", .holdFrame(clipID: screen.id, range: TimeRange(start: t(10), duration: frame)))
        try c.run("Hold", .holdFrame(clipID: screen.id, range: TimeRange(start: t(10) + frame, duration: frame)))
        let holds = c.clips("Screen")[0].holds
        XCTAssertEqual(holds.count, 1)
        XCTAssertEqual(holds.first?.source.duration, frame.scaled(by: 2))
        XCTAssertEqual(holds.first?.frame, screen.sourceTime(atTimelineTime: t(10) - frame), "the first hold's frame, held on")
    }

    func testAtTheClipsStartItHoldsTheFileFrameBefore() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(20), end: t(21))], trackIDs: nil))
        let second = c.clips("Screen")[1]
        try c.run("Hold", .holdFrame(clipID: second.id, range: TimeRange(start: second.start, duration: frame)))
        let held = try XCTUnwrap(c.clips("Screen")[1].holds.first?.frame)
        XCTAssertEqual(held.seconds, (second.sourceStart - frame).seconds, accuracy: 0.0001, "the file's frame before the clip starts")
    }

    func testTheFrameBeforeIsAFrameOfTheFile() throws {
        // At half speed a timeline frame back is half a file frame: still
        // the flash. The frame held is a whole file frame before it.
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        try c.run("Cut", .cutRanges(ranges: [TimeRange(start: t(20), end: t(21))], trackIDs: nil))
        let screen = c.clips("Screen")[0]
        try c.run("Slow", .setSpeed(clipID: screen.id, speed: 0.5, ripple: true, includeLinked: false))
        let slow = c.clips("Screen")[0]
        try c.run("Hold", .holdFrame(clipID: slow.id, range: TimeRange(start: t(10), duration: frame.scaled(by: 2))))
        let hold = try XCTUnwrap(c.clips("Screen")[0].holds.first)
        XCTAssertEqual(hold.frame, slow.sourceTime(atTimelineTime: t(10)) - frame, "a 30 fps file's frame before")
    }

    func testTheFilesFirstFrameHasNoFrameBefore() throws {
        let (f, c) = try Fixture.edited()
        let frame = f.project.settings.frameRate.frameDuration
        let screen = f.clips("Screen")[0]
        try c.run("From the file's start", .updateClip(clipID: screen.id, patch: .object(["sourceStart": .number(0)])))
        XCTAssertThrowsError(try c.run("Hold", .holdFrame(clipID: screen.id, range: TimeRange(start: .zero, duration: frame)))) { error in
            XCTAssertTrue("\(error)".contains("first frame of its file"), "\(error)")
        }
        try c.run("Second", .holdFrame(clipID: screen.id, range: TimeRange(start: frame, duration: frame)))
        XCTAssertEqual(c.clips("Screen")[0].holds.first?.frame, .zero)
    }

    func testRefusesWhatItCantHold() throws {
        let (f, c) = try Fixture.edited()
        let screen = f.clips("Screen")[0]
        let voice = f.clips("Voice")[0]
        let frame = f.project.settings.frameRate.frameDuration
        XCTAssertThrowsError(try c.run("Sound", .holdFrame(clipID: voice.id, range: TimeRange(start: t(10), duration: frame))))
        XCTAssertThrowsError(try c.run("Past", .holdFrame(clipID: screen.id, range: TimeRange(start: t(59.99), duration: frame))))
        XCTAssertThrowsError(try c.run("Empty", .holdFrame(clipID: screen.id, range: TimeRange(start: t(10), duration: .zero))))
        try c.run("Lock", .updateTrack(trackID: f.track("Screen").id, patch: .object(["locked": .bool(true)])))
        XCTAssertThrowsError(try c.run("Locked", .holdFrame(clipID: screen.id, range: TimeRange(start: t(10), duration: frame))))
        XCTAssertEqual(c.clips("Screen")[0].holds, [], "nothing changed")
    }

    func testHoldsSurviveSavingAndOlderFilesHaveNone() throws {
        var clip = Clip(id: "clip_h", content: .media(mediaID: "med_camera"), start: .zero, duration: t(10))
        let plain = try JSONEncoder().encode(clip)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("holds"), "files only mention holds where there are some")
        clip.holds = [HeldFrame(source: TimeRange(start: t(5), duration: t(0.033)), frame: t(4.967))]
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(decoded.holds, clip.holds)
    }
}
