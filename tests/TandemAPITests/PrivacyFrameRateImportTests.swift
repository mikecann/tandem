import XCTest
@testable import TandemCore
import TandemMedia
@testable import TandemAPI

/// Round-2 review r6 (Gemini): a new project takes its first camera take's
/// frame rate, but redactions freeze the project's rate. Taking it then
/// refused the whole scan, and every later scan tried again, so no new
/// file came in until the project was reopened.
final class PrivacyFrameRateImportTests: XCTestCase {
    func testACameraTakeAfterARedactionStillImportsAndKeepsTheRate() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let folder = TempFolder()
        func movie(_ path: String, rate: String) throws {
            try FileManager.default.createDirectory(at: folder.file(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x806040:s=320x240:d=2:r=\(rate)",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", folder.file(path).path])
        }
        let session = try ProjectSession.create(at: folder.file("Video.tandem"), owner: .cli)
        defer { session.close() }
        try movie("source/talk-screen.mov", rate: "30")
        try await session.refreshMedia()
        let screen = try XCTUnwrap(session.coordinator.project.media.first { $0.path == "source/talk-screen.mov" })
        try session.coordinator.apply(EditBatch(label: "Place", commands: [.placeMedia(mediaIDs: [screen.id], at: .zero)]))
        try session.coordinator.apply(EditBatch(label: "Redact", commands: [.redact(range: TimeRange(start: .zero, end: Time(seconds: 1)),
            rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: screen.id, style: .blur, size: 48)]))

        try movie("source/talk-camera.mov", rate: "24000/1001")
        let report = try await session.refreshMediaReport()
        XCTAssertTrue(session.coordinator.project.media.contains { $0.path == "source/talk-camera.mov" }, "the camera take comes in")
        XCTAssertEqual(report.added.count, 1)
        XCTAssertNil(report.frameRate)
        XCTAssertEqual(session.coordinator.project.settings.frameRate, FrameRate(30), "the redacted project keeps its rate")
    }
}
