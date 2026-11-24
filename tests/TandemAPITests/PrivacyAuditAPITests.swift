import XCTest
@testable import TandemAPI
@testable import TandemCore

final class PrivacyAuditAPITests: XCTestCase {
    func testShortCopyKeepsRegionalRedactionAndOriginalProject() throws {
        let c = ProjectCoordinator(project: APIFixture.project())
        _ = try c.apply(EditBatch(label: "Hide", commands: [.redact(range: TimeRange(start: t(10), end: t(15)),
            rect: Rect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), mediaID: "med_screen", style: .blur)]))
        let h = try ServiceHarness(project: c.project)
        defer { h.close() }
        let before = h.service.coordinator.project
        let result = try h.service.short(ShortRequest(apply: true, copy: true), context: h.context)
        let copy = try ProjectFile.load(from: URL(fileURLWithPath: XCTUnwrap(result.copy))).project
        XCTAssertEqual(h.service.coordinator.project, before)
        XCTAssertEqual(try ProjectFile.load(from: h.url).project, before)
        XCTAssertEqual(copy.settings.width, 1080)
        XCTAssertEqual(copy.settings.height, 1920)
        XCTAssertTrue(copy.settings.alternateFormats.isEmpty)
        let patch = try XCTUnwrap(copy.videoTracks.first { $0.isPrivacy }?.clips.first)
        let picture = try XCTUnwrap(copy.track(named: "Screen")?.clips.first { $0.range == patch.range })
        XCTAssertEqual(patch.video?.transform, picture.video?.transform)
        XCTAssertEqual(patch.video!.crop.left, 0.1, accuracy: 1e-9)
        XCTAssertEqual(patch.video!.crop.right, 0.6, accuracy: 1e-9)
        XCTAssertEqual(patch.video?.redaction, Rect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        XCTAssertEqual(patch.sourceStart, picture.sourceStart)
        XCTAssertEqual(patch.linkGroup, picture.linkGroup)
    }

    func testExportGateChecksPendingAgentReviewButDoesNotRequirePrivacyScan() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        XCTAssertNoThrow(try h.service.prepareExport(ExportRequest(preset: "youtube1080")), "no privacy scan has run")
        _ = try h.apply(.updateClip(clipID: "clip_scr1", patch: .object(["video": .object(["transform": .object(["scale": .number(1.5)])]) ])))
        XCTAssertThrowsError(try h.service.prepareExport(ExportRequest(preset: "youtube1080")))
        XCTAssertNoThrow(try h.service.prepareExport(ExportRequest(preset: "review")))
        XCTAssertNoThrow(try h.service.prepareExport(ExportRequest(preset: "youtube1080", unreviewed: true)))
    }
}
