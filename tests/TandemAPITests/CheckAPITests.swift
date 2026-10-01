import XCTest
@testable import TandemAPI
@testable import TandemCore

/// `tandem check` through the service: what it checks, what it reports.
final class CheckAPITests: XCTestCase {
    /// Grey frames at 30 fps from `start`, with a flat white flash at `flash`.
    private func frames(from start: Double, to end: Double, flash: Double? = nil) -> [FrameStats] {
        stride(from: start, to: end - 0.0001, by: 1.0 / 30).map { seconds in
            let lit = flash.map { abs($0 - seconds) < 0.001 } ?? false
            return FrameStats(
                time: Time(seconds: seconds), luma: lit ? 1 : 0.4, brightestTile: lit ? 1 : 0.4,
                flatGreen: 0, flatWhite: lit ? 1 : 0, thumbnail: [UInt8](repeating: lit ? 255 : 100, count: 16)
            )
        }
    }

    func testAFlashInTheFramesIsAProblem() async throws {
        var renderer = FakeRenderer()
        renderer.scanned = frames(from: 0, to: 2, flash: 1)
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await CheckRequest(from: t(0), to: t(2)).run(on: h.service, context: h.context)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.frames, 60)
        XCTAssertEqual(result.problems.map(\.kind), [.whiteBlock])
        XCTAssertEqual(result.problems.first?.start, t(1))
        let text = result.readableText
        XCTAssertTrue(text.hasPrefix("Checked 00:00.000-00:02.000 (60 frames) in "), text)
        XCTAssertTrue(text.contains("1 problem:"), text)
        XCTAssertTrue(text.contains("White block"), text)
        XCTAssertTrue(text.contains("On: clip_cam1 take1-camera"), "names the clips on screen, top first: \(text)")
    }

    func testAQuickCheckRendersNothing() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertEqual(result.frames, 0)
        XCTAssertEqual(result.ranges, [TimeRange(start: .zero, end: t(60))])
        XCTAssertTrue(result.ok, "\(result.problems)")
        XCTAssertTrue(result.readableText.contains("(quick: no frames rendered)"), result.readableText)
    }

    func testChangedChecksWhatsWaitingForReview() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let nothing = try await CheckRequest(changed: true).run(on: h.service, context: h.context)
        XCTAssertTrue(nothing.ranges.isEmpty)
        XCTAssertEqual(nothing.readableText, "Nothing is waiting for Mike's review, so there was nothing to check.")

        // An agent moves the B-roll to 21 to 26.
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false))
        let changed = try await CheckRequest(changed: true).run(on: h.service, context: h.context)
        XCTAssertEqual(changed.ranges, [TimeRange(start: t(20.5), end: t(26.5))], "the change and half a second either side")
        XCTAssertEqual(changed.frames, 180)
    }

    func testABlownUpPictureIsANoteNotAProblem() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.updateMedia(mediaID: "med_broll", patch: .object(["width": .number(1280), "height": .number(720)])))
        try h.apply(.updateClip(clipID: "clip_brl1", patch: .object(["video": .object(["transform": .object(["scale": .number(1.5)])])])))
        let result = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "notes don't fail a check")
        XCTAssertEqual(result.notes.map(\.kind), [.soft])
        XCTAssertTrue(result.readableText.contains("Notes (not problems):"), result.readableText)
    }

    func testRequestsThatDontMakeSenseAreRefused() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        for request in [CheckRequest(from: t(10), to: t(5)), CheckRequest(from: t(1), changed: true), CheckRequest(width: 10)] {
            do {
                _ = try await request.run(on: h.service, context: h.context)
                XCTFail("\(request) should be refused")
            } catch let error as ServiceError {
                XCTAssertEqual(error.code, "badRequest")
            }
        }
    }

    func testTheRequestReadsFriendlyTimes() throws {
        let request = try ServiceJSON.decodeRequest(CheckRequest.self, from: Data(#"{"from": "5:40", "to": 371, "quick": true}"#.utf8))
        XCTAssertEqual(request.from, t(340))
        XCTAssertEqual(request.to, t(371))
        XCTAssertEqual(request.quick, true)
    }
}
