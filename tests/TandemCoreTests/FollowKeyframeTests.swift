import XCTest
@testable import TandemCore

/// A ripple cut shortens a clip on a `.follow` track at its tail, keeping its
/// content from the head. Its sound keyframes are mixing, set against the
/// timeline (a music swell under a section card), so they move with the
/// timeline. Its picture keyframes belong to its content (a push across a
/// still), so they stay where the content is.
final class FollowKeyframeTests: XCTestCase {
    private func gain(_ pairs: [(Double, Double)]) -> [Keyframe] {
        pairs.map { Keyframe(time: t($0.0), value: .number($0.1), interpolation: .linear) }
    }

    private func gainTimes(_ clip: Clip) -> [Time] { (clip.keyframes["audio.gainDB"] ?? []).map(\.time) }

    private func gainValues(_ clip: Clip) -> [Double] { (clip.keyframes["audio.gainDB"] ?? []).compactMap(\.value.number) }

    func testAGainSwellAfterTheCutMovesWithTheTimeline() throws {
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0].id
        // A swell under a card at 52 s.
        try c.run("Swell", .setKeyframes(clipID: music, parameter: "audio.gainDB", keyframes: gain([(0, -30), (50, -30), (52, -18), (55, -30)])))
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(12))))
        let bed = c.clips("Music")[0]
        XCTAssertEqual(bed.range, TimeRange(start: t(0), end: t(58)))
        XCTAssertEqual(gainTimes(bed), [t(0), t(48), t(50), t(53)], "the swell is still under the card, now 2 s earlier")
        XCTAssertEqual(gainValues(bed), [-30, -30, -18, -30])
        assertValid(c.project)
    }

    func testClosingAGapMovesTheSwellToo() throws {
        // Mike's way: delete a piece of the take, then close the gap.
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0].id
        try c.run("Swell", .setKeyframes(clipID: music, parameter: "audio.gainDB", keyframes: gain([(0, -30), (50, -30), (52, -18), (55, -30)])))
        let camera = f.track("Camera").id
        try c.run("Cut", .blade(at: t(20), trackIDs: [camera]), .blade(at: t(10), trackIDs: [camera]))
        try c.run("Lift", .removeClips(clipIDs: [c.clips("Camera")[1].id], ripple: false, includeLinked: true))
        try c.run("Close gap", .closeGap(trackID: f.track("Voice").id, at: t(15)))
        XCTAssertEqual(gainTimes(c.clips("Music")[0]), [t(0), t(40), t(42), t(45)])
    }

    func testGainKeyframesInsideTheCutGoAndTheCurveEitherSideStays() throws {
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0].id
        let dip = [
            Keyframe(time: t(0), value: .number(-30), interpolation: .linear),
            Keyframe(time: t(11), value: .number(-10), interpolation: .easeIn),
            Keyframe(time: t(20), value: .number(-30), interpolation: .linear)
        ]
        let before = dip.value(at: t(10))?.number
        let after = dip.value(at: t(12))?.number
        try c.run("Dip", .setKeyframes(clipID: music, parameter: "audio.gainDB", keyframes: dip))
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(12))))
        let bed = c.clips("Music")[0]
        // What played at 10 s holds up to the cut, then what played at 12 s
        // carries on from it, easing as it was.
        XCTAssertEqual(gainTimes(bed), [t(0), t(10), t(10), t(18)])
        let curve = try XCTUnwrap(bed.keyframes["audio.gainDB"])
        XCTAssertEqual(curve[1].value.number, before)
        XCTAssertEqual(curve[2].value.number, after)
        XCTAssertEqual(curve[2].interpolation, .easeIn)
        XCTAssertEqual(curve.value(at: t(5))?.number ?? 0, dip.value(at: t(5))?.number ?? 1, accuracy: 1e-9, "before the cut it's unchanged")
        XCTAssertEqual(curve.value(at: t(18))?.number, -30)
        assertValid(c.project)
    }

    func testARampTheCutCrossesKeepsItsLevelsEitherSide() throws {
        // No keyframe inside the cut: a ramp from -30 at 0 s to -10 at 20 s.
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0].id
        try c.run("Ramp", .setKeyframes(clipID: music, parameter: "audio.gainDB", keyframes: gain([(0, -30), (20, -10)])))
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(12))))
        let curve = try XCTUnwrap(c.clips("Music")[0].keyframes["audio.gainDB"])
        XCTAssertEqual(curve.map(\.time), [t(0), t(10), t(10), t(18)])
        XCTAssertEqual(curve.value(at: t(5))?.number ?? 0, -25, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: t(10))?.number ?? 0, -18, accuracy: 1e-9, "what played at 12 s")
        XCTAssertEqual(curve.value(at: t(14))?.number ?? 0, -14, accuracy: 1e-9, "what played at 16 s")
    }

    func testABedEndingInsideTheCutGetsNothingFromAfterIt() throws {
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0].id
        try c.run("Trim", .updateClip(clipID: music, patch: .object(["duration": .number(30)])))
        try c.run("Fade", .setKeyframes(clipID: music, parameter: "audio.gainDB", keyframes: gain([(0, -30), (20, -30), (40, 0)])))
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(25), end: t(35))))
        let bed = c.clips("Music")[0]
        XCTAssertEqual(bed.range, TimeRange(start: t(0), end: t(25)))
        XCTAssertEqual(bed.keyframes["audio.gainDB"]?.value(at: t(25))?.number ?? 0, -22.5, accuracy: 1e-9, "the ramp up to where it was cut, no further")
    }

    func testACutOverABedsHeadKeepsItsSwellOnTheSameMoment() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Lift", .removeClips(clipIDs: [f.clips("Music")[0].id], ripple: false))
        let bed = try c.run("Bed", .placeMedia(mediaIDs: ["med_music"], at: t(20), duration: t(40))).createdIDs[0]
        try c.run("Swell", .setKeyframes(clipID: bed, parameter: "audio.gainDB", keyframes: gain([(0, -30), (30, -30), (32, -18), (35, -30)])))
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(15), end: t(25))))
        let music = try XCTUnwrap(c.clips("Music").first)
        XCTAssertEqual(music.range, TimeRange(start: t(15), end: t(50)), "the bed starts where the cut was and keeps its head")
        XCTAssertEqual(music.sourceStart, .zero)
        // On the timeline the swell was at 50-55 and is now at 40-45: 25-30 s into the clip.
        XCTAssertEqual(gainTimes(music), [t(25), t(27), t(30)], "the bed's steady -30 before it holds from the first one")
        XCTAssertEqual(gainValues(music), [-30, -18, -30])
        assertValid(c.project)
    }

    func testPictureKeyframesStayWithTheContent() throws {
        let (f, c) = try Fixture.edited()
        let broll = f.clips("B-roll")[0].id
        let push = [Keyframe(time: t(0), value: .number(1)), Keyframe(time: t(5), value: .number(1.2))]
        try c.run("Push", .setKeyframes(clipID: broll, parameter: "video.transform.scale", keyframes: push))
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(22), end: t(23))))
        let clip = c.clips("B-roll")[0]
        XCTAssertEqual(clip.range, TimeRange(start: t(20), end: t(24)))
        XCTAssertEqual(clip.keyframes["video.transform.scale"]?.map(\.time), [t(0), t(5)], "the push stays on the shot")
    }
}
