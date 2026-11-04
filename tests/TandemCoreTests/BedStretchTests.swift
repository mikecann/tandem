import XCTest
@testable import TandemCore

/// Time opened inside a music bed on a `.follow` track stretches the bed by
/// that much, playing on from its file, so it still ends with the section
/// card it was laid under and its swell moves with the timeline. Other
/// follow clips (a B-roll shot) stay whole and play across the new time.
final class BedStretchTests: XCTestCase {
    private func gain(_ pairs: [(Double, Double)]) -> [Keyframe] {
        pairs.map { Keyframe(time: t($0.0), value: .number($0.1), interpolation: .linear) }
    }

    func testABedStretchesAcrossInsertedTimeAndItsSwellMovesWithIt() throws {
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0].id
        try c.run("Swell", .setKeyframes(clipID: music, parameter: "audio.gainDB", keyframes: gain([(0, -30), (50, -30), (52, -18), (55, -30)])))
        try c.run("Room", .insertTime(at: t(10), duration: t(2)))
        let bed = c.clips("Music")[0]
        XCTAssertEqual(bed.range, TimeRange(start: t(0), end: t(62)), "the bed plays on 2 s longer, to the end of the take")
        XCTAssertEqual(bed.sourceStart, .zero)
        XCTAssertEqual(bed.keyframes["audio.gainDB"]?.map(\.time), [t(0), t(52), t(54), t(57)])
        XCTAssertEqual(c.clips("B-roll")[0].range, TimeRange(start: t(22), end: t(27)), "later B-roll just moves")
        assertValid(c.project)
    }

    func testARampAcrossTheInsertHoldsItsLevelThroughTheNewTime() throws {
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0].id
        try c.run("Ramp", .setKeyframes(clipID: music, parameter: "audio.gainDB", keyframes: gain([(0, -30), (20, -10)])))
        try c.run("Room", .insertTime(at: t(10), duration: t(2)))
        let curve = try XCTUnwrap(c.clips("Music")[0].keyframes["audio.gainDB"])
        XCTAssertEqual(curve.value(at: t(5))?.number ?? 0, -25, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: t(11))?.number ?? 0, -20, accuracy: 1e-9, "held through the new time")
        XCTAssertEqual(curve.value(at: t(17))?.number ?? 0, -15, accuracy: 1e-9, "what played at 15 s")
        XCTAssertEqual(curve.last?.time, t(22))
    }

    func testInsertingOnTheFirstKeyframeHoldsItsLevel() throws {
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0].id
        try c.run("Ramp", .setKeyframes(clipID: music, parameter: "audio.gainDB", keyframes: gain([(10, -30), (20, -10)])))
        try c.run("Room", .insertTime(at: t(10), duration: t(2)))
        let curve = try XCTUnwrap(c.clips("Music")[0].keyframes["audio.gainDB"])
        XCTAssertEqual(curve.value(at: t(11))?.number ?? 0, -30, accuracy: 1e-9, "held through the new time")
        XCTAssertEqual(curve.value(at: t(17))?.number ?? 0, -20, accuracy: 1e-9, "what played at 15 s")
    }

    func testABedAtTheEndOfItsFileStretchesAsFarAsItCanAndSays() throws {
        let (f, c) = try Fixture.edited()
        // 179 s into a 180 s file: one second left.
        try c.run("Lift", .removeClips(clipIDs: [f.clips("Music")[0].id], ripple: false))
        try c.run("Bed", .placeMedia(mediaIDs: ["med_music"], at: .zero, sourceStart: t(119), duration: t(60)))
        let result = try c.run("Room", .insertTime(at: t(10), duration: t(2)))
        XCTAssertEqual(c.clips("Music")[0].range, TimeRange(start: t(0), end: t(61)))
        XCTAssertTrue(result.warnings.contains { $0.contains("1 s") && $0.contains("music") }, "\(result.warnings)")
        assertValid(c.project)
    }

    func testInsertingAShotStretchesTheBedUnderIt() throws {
        // The usual insert: a clip put in the take with mode insert.
        let (f, c) = try Fixture.edited()
        let slug = Clip(id: "clip_slug", content: .solid(color: .black), start: t(30), duration: t(3))
        try c.run("Slug", .insertClip(trackID: f.track("Camera").id, clip: slug, mode: .insert))
        XCTAssertEqual(c.clips("Music")[0].range, TimeRange(start: t(0), end: t(63)))
    }

    func testARippleTrimLengtheningTheTakeStretchesTheBed() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.track("Camera").id
        try c.run("Cut", .blade(at: t(20), trackIDs: [camera]))
        try c.run("Trim", .trim(clipID: c.clips("Camera")[0].id, edge: .end, to: t(18), ripple: true))
        XCTAssertEqual(c.clips("Music")[0].range, TimeRange(start: t(0), end: t(58)))
        try c.run("Untrim", .trim(clipID: c.clips("Camera")[0].id, edge: .end, to: t(20), ripple: true))
        XCTAssertEqual(c.clips("Music")[0].range, TimeRange(start: t(0), end: t(60)), "back to where it ended")
    }

    func testBRollSpanningTheInsertStaysWhole() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Room", .insertTime(at: t(22), duration: t(2)))
        XCTAssertEqual(c.clips("B-roll")[0].range, TimeRange(start: t(20), end: t(25)))
    }

    func testOneUndoPutsTheBedBack() throws {
        let (_, c) = try Fixture.edited()
        let before = c.project
        try c.run("Room", .insertTime(at: t(10), duration: t(2)))
        _ = c.undo()
        XCTAssertEqual(c.project, before)
    }
}
