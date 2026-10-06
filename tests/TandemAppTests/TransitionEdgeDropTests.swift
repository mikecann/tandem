import XCTest
@testable import TandemApp
import TandemCore

/// A transition dropped at a clip's start or end with nothing next to it
/// goes on that clip alone, as Filmora does: an overlay pushes in, or out
/// over the tracks below.
final class TransitionEdgeDropTests: XCTestCase {
    func testAtAnOverlaysEndItExitsAndAtItsStartItEnters() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let track = f.track("B-roll").id
        let out = try XCTUnwrap(LibraryDrops.transition(.push, at: broll.end - t(0.2), trackID: track, in: f.project, id: "tr_out"))
        XCTAssertTrue(out.label.contains("end"), out.label)
        try f.apply(out)
        let exit = try XCTUnwrap(f.project.track(track)?.transitions.first { $0.id == "tr_out" })
        XCTAssertEqual(exit.fromClipID, broll.id)
        XCTAssertNil(exit.toClipID, "nothing after it: it goes over what's below")

        let into = try XCTUnwrap(LibraryDrops.transition(.slide, at: broll.start + t(0.3), trackID: track, in: f.project, id: "tr_in"))
        try f.apply(into)
        let enter = try XCTUnwrap(f.project.track(track)?.transitions.first { $0.id == "tr_in" })
        XCTAssertNil(enter.fromClipID)
        XCTAssertEqual(enter.toClipID, broll.id)

        // The same again changes nothing; another type changes it.
        XCTAssertNil(LibraryDrops.transition(.push, at: broll.end, trackID: track, in: f.project))
        let changed = try XCTUnwrap(LibraryDrops.transition(.wipe, at: broll.end, trackID: track, in: f.project))
        try f.apply(changed)
        XCTAssertEqual(f.project.track(track)?.transitions.first { $0.fromClipID == broll.id }?.type, .wipe)
    }

    func testACutStillTakesItBetweenItsClips() throws {
        let f = try AppFixture()
        let camera = f.clip("Camera").id
        try f.apply(EditBatch(label: "Cut", commands: [.blade(at: t(40), clipIDs: [camera])]))
        let batch = try XCTUnwrap(LibraryDrops.transition(.push, at: t(40.2), trackID: f.track("Camera").id, in: f.project, id: "tr_cut"))
        try f.apply(batch)
        let added = try XCTUnwrap(f.project.track(named: "Camera")?.transitions.first)
        XCTAssertNotNil(added.fromClipID)
        XCTAssertNotNil(added.toClipID)
    }

    func testFarFromAnyEdgeNothingHappens() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        XCTAssertNil(LibraryDrops.transition(.push, at: broll.start + t(2.5), trackID: f.track("B-roll").id, in: f.project))
    }
}
