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

    func testGainKeyframesInsideTheCutCollapseToTheCutPoint() throws {
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0].id
        try c.run("Dip", .setKeyframes(clipID: music, parameter: "audio.gainDB", keyframes: gain([(0, -30), (11, -10), (20, -30)])))
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(12))))
        let bed = c.clips("Music")[0]
        XCTAssertEqual(gainTimes(bed), [t(0), t(10), t(18)])
        // 12 s was 1/9 of the way from -10 at 11 s to -30 at 20 s: what plays
        // straight after the cut keeps playing there.
        XCTAssertEqual(gainValues(bed)[1], -10 - 20.0 / 9, accuracy: 1e-6)
        XCTAssertEqual(bed.keyframes["audio.gainDB"]?[1].interpolation, .linear)
        assertValid(c.project)
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
        XCTAssertEqual(gainTimes(music), [t(0), t(25), t(27), t(30)])
        XCTAssertEqual(gainValues(music), [-30, -30, -18, -30])
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
