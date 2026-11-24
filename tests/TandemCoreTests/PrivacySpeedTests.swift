import XCTest
@testable import TandemCore

/// Privacy checks run on every edit, so they have to stay quick on a long
/// timeline. On 24 Nov 2026 they asked `isPrivacy` (a scan of the track)
/// once per clip, and joining 3,000 clips went from 0.1 s to over 2 s.
final class PrivacySpeedTests: XCTestCase {
    func testEditsStayQuickOnALongTimelineWithARedaction() throws {
        var fixture = Fixture()
        let pieces = 1000
        let length = t(0.1)
        fixture.project.media[0].duration = t(200)
        fixture.project.media[1].duration = t(201)
        for (name, mediaID, offset) in [("Screen", "med_screen", t(0.5)), ("Camera", "med_camera", Time.zero), ("Voice", "med_camera", Time.zero)] {
            let location = try XCTUnwrap(fixture.project.location(ofTrack: fixture.track(name).id))
            fixture.project[location].clips = (0..<pieces).map { i in
                let start = Time(flicks: length.flicks * Int64(i))
                return Clip(id: "clip_\(name)_\(i)", content: .media(mediaID: mediaID), start: start, duration: length,
                            sourceStart: start + offset, linkGroup: "lnk_\(i)")
            }
        }
        let c = ProjectCoordinator(project: fixture.project)
        try c.apply(EditBatch(label: "Redact", commands: [.redact(range: TimeRange(start: t(10), end: t(12)),
            rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen", style: .blur, size: 48)]))
        let started = Date()
        try c.apply(EditBatch(label: "Trim", commands: [.trim(clipID: "clip_Camera_500", edge: .end, to: t(50.05))]))
        let elapsed = Date().timeIntervalSince(started)
        // About 0.1 s on a Mac and 1 s on a shared CI runner; it took 250 s
        // when the checks scanned each track once per clip.
        XCTAssertLessThan(elapsed, 5, "a trim on a 3,000 clip timeline with a redaction took \(elapsed) s")
    }
}
