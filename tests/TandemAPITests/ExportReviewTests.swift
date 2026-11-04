import XCTest
@testable import TandemAPI
@testable import TandemCore

/// A final export waits for Mike to review agent edits. On the Threadbear
/// launch video an agent exported four times while its privacy blurs still
/// waited for him: "I didn't actually verify the blur looks good. I need to
/// verify all that before you export it."
final class ExportReviewTests: XCTestCase {
    func testAFinalExportStopsWhileAgentEditsWaitForReview() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)), label: "Blur the email column")

        // (short too, on a project with a 9:16 frame; this one has none, so
        // it says that first.)
        for preset in ["youtube4k", "youtube1080", nil] {
            do {
                _ = try h.service.prepareExport(ExportRequest(preset: preset))
                XCTFail("\(preset ?? "the default") shouldn't export with edits waiting")
            } catch let error as ServiceError {
                XCTAssertEqual(error.code, "invalid")
                XCTAssertTrue(error.message.contains("Blur the email column"), error.message)
                XCTAssertTrue(error.message.contains("--unreviewed"), error.message)
            }
        }

        // A review copy goes ahead, and says what it shows that Mike hasn't seen.
        let review = try await ExportRequest(preset: "review").run(on: h.service, context: h.context)
        XCTAssertTrue(review.warnings.contains { $0.contains("Blur the email column") }, "\(review.warnings)")

        // A deliberate check export, which says it's not one to publish.
        let check = try await ExportRequest(preset: "youtube1080", from: t(0), to: t(5), unreviewed: true).run(on: h.service, context: h.context)
        XCTAssertTrue(check.warnings.contains { $0.contains("hasn't reviewed") }, "\(check.warnings)")
    }

    func testOnceMikeHasReviewedItExportsAsUsual() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)), label: "Add push")
        h.session.review.markReviewed()
        let outcome = try await ExportRequest(preset: "youtube1080", from: t(0), to: t(5)).run(on: h.service, context: h.context)
        XCTAssertFalse(outcome.warnings.contains { $0.contains("review") }, "\(outcome.warnings)")
    }
}
