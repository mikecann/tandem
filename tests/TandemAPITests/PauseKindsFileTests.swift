import XCTest
@testable import TandemCLI

/// The kinds file `tandem tighten --filmora --kinds <file>` writes and reads.
final class PauseKindsFileTests: XCTestCase {
    func testAHandWrittenFileSaysWhatsMissingAndHowToGetOne() throws {
        // The Examples Page video (18 Nov 2026): kinds and pauses, but no
        // revision or settings, read as "The data couldn't be read because
        // it is missing".
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pause.json")
        try Data(#"{"kinds": "mid", "pauses": [{"start": 1, "end": 2, "heard": 1, "before": "a", "after": "b", "guess": "mid", "kind": "mid"}]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try PauseKindsFile.read(url, as: "/tmp/pause.json")) { error in
            let message = (error as? UsageError)?.message ?? "\(error)"
            XCTAssertTrue(message.hasPrefix("/tmp/pause.json isn't a kinds file tighten wrote: missing \"revision\"."), message)
            XCTAssertTrue(message.contains("run the same command without --apply"), message)
        }
    }
}
