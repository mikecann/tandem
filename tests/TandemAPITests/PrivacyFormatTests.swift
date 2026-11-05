import XCTest
@testable import TandemAPI
@testable import TandemCore

/// `check --privacy --format`: a Short's own layout read in its own frame.
final class PrivacyFormatTests: XCTestCase {
    func testAFormatIsOneTheProjectHasAndOnlyGoesWithPrivacy() throws {
        var project = APIFixture.project()
        project.settings.alternateFormats = [OutputFormat(id: "portrait", name: "Short 9:16", width: 1080, height: 1920)]
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        assertServiceError(.notFound) { _ = try h.service.prepareCheck(CheckRequest(privacy: true, format: "square")) }
        assertServiceError(.badRequest) { _ = try h.service.prepareCheck(CheckRequest(quick: true, format: "portrait")) }
        XCTAssertNoThrow(try h.service.prepareCheck(CheckRequest(privacy: true, format: "portrait")))

        // A format narrower than a privacy read's 640 still scans by default.
        var narrow = APIFixture.project()
        narrow.settings.alternateFormats = [OutputFormat(id: "tiny", name: "Tiny", width: 480, height: 480)]
        let g = try ServiceHarness(project: narrow)
        defer { g.close() }
        XCTAssertNoThrow(try g.service.prepareCheck(CheckRequest(privacy: true, format: "tiny")))
    }

    func testWithoutAFormatItSaysWhichLayoutsItDidntRead() async throws {
        var project = APIFixture.project()
        project.settings.alternateFormats = [OutputFormat(id: "portrait", name: "Short 9:16", width: 1080, height: 1920)]
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        // An empty stretch, so nothing renders: the warning still comes back.
        let result = try await CheckRequest(changed: true, privacy: true).run(on: h.service, context: h.context)
        XCTAssertEqual(result.privacy, true)
        XCTAssertTrue(result.warnings.contains { $0.contains("--format portrait") }, "nothing read, and still the warning: \(result.warnings)")
        let none = try await CheckRequest(from: t(0), to: t(0.5), privacy: true).run(on: h.service, context: h.context)
        XCTAssertTrue(none.warnings.contains { $0.contains("--format portrait") }, "\(none.warnings)")
    }
}
