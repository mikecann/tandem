import XCTest
@testable import TandemApp
import TandemCore

/// Which empty stretches can be closed, and on which tracks.
final class TimelineGapTests: XCTestCase {
    /// The take cut at 10 and 20 s and its middle piece lifted: a 10 s
    /// gap on camera, screen and voice.
    private func liftedMiddle() throws -> AppFixture {
        let f = try AppFixture()
        let camera = f.clip("Camera").id
        try f.apply(EditBatch(label: "Cuts", commands: [.blade(at: t(20), clipIDs: [camera]), .blade(at: t(10), clipIDs: [camera])]))
        let middle = try XCTUnwrap(f.clips("Camera").first { $0.start == t(10) })
        try f.apply(EditBatch(label: "Lift", commands: [.removeClips(clipIDs: [middle.id], ripple: false, includeLinked: true)]))
        return f
    }

    func testAGapInTheTakeSpansItsTracks() throws {
        let f = try liftedMiddle()
        let gap = try XCTUnwrap(TimelineGap.at(t(15), onTrack: f.track("Screen").id, in: f.project))
        XCTAssertEqual(gap.range, TimeRange(start: t(10), end: t(20)))
        XCTAssertEqual(Set(gap.trackIDs), Set(f.project.allTracks.filter { $0.rippleMode == .cut }.map(\.id)), "camera, screen and voice close together")
        try f.apply(gap.batch)
        XCTAssertEqual(f.clips("Camera").map(\.start), [t(0), t(10)], "everything after moved up")
        XCTAssertEqual(f.clips("Voice").map(\.start), [t(0), t(10)])
    }

    func testNoGapWhereTheTakeStillPlays() throws {
        let f = try AppFixture()
        let camera = f.clip("Camera").id
        try f.apply(EditBatch(label: "Cuts", commands: [.blade(at: t(20), clipIDs: [camera]), .blade(at: t(10), clipIDs: [camera])]))
        // Only the camera's middle goes; the voice still plays there.
        let middle = try XCTUnwrap(f.clips("Camera").first { $0.start == t(10) })
        try f.apply(EditBatch(label: "Lift camera", commands: [.removeClips(clipIDs: [middle.id], ripple: false, includeLinked: false)]))
        XCTAssertNil(TimelineGap.at(t(15), onTrack: f.track("Camera").id, in: f.project), "closing it would put the take out of step")
    }

    func testAGapBetweenBRollShotsIsJustThatTrack() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        try f.apply(EditBatch(label: "Another", commands: [.placeMedia(mediaIDs: [broll.mediaID!], at: broll.end + t(5), duration: t(2))]))
        let gap = try XCTUnwrap(TimelineGap.at(broll.end + t(1), onTrack: f.track("B-roll").id, in: f.project))
        XCTAssertEqual(gap.trackIDs, [f.track("B-roll").id])
        XCTAssertEqual(gap.range, TimeRange(start: broll.end, end: broll.end + t(5)))
    }

    func testNoGapOnAClipOrAfterTheLast() throws {
        let f = try liftedMiddle()
        XCTAssertNil(TimelineGap.at(t(5), onTrack: f.track("Camera").id, in: f.project), "on a clip")
        XCTAssertNil(TimelineGap.at(t(200), onTrack: f.track("Camera").id, in: f.project), "nothing after it to close up to")
    }
}
