import AVFoundation
import XCTest
@testable import TandemMedia

/// The clean plate on a real take, with and without (opt-in, read only):
///
///     TANDEM_CLEAN_PLATE_FILE=<camera file> swift test --filter CleanPlateRealTests
///
/// Writes `with/matte.mov` and `without/matte.mov` beside each other under
/// /private/tmp/tandem-clean-plate/ (or TANDEM_CLEAN_PLATE_OUT), with the
/// job's notes (whether it made a plate) in report.txt.
final class CleanPlateRealTests: XCTestCase {
    func testWithAndWithoutTheCleanPlate() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TANDEM_CLEAN_PLATE_FILE"] else { throw XCTSkip("set TANDEM_CLEAN_PLATE_FILE to a camera take") }
        let source = URL(fileURLWithPath: path)
        try XCTSkipUnless((try? RVMModelStore.checksum(of: RVMModelStore.standard.folder.appendingPathComponent(RVMMatte.modelFile))) == RVMMatte.modelSHA256,
                          "the RVM model isn't installed, and tests never download it")
        let out = URL(fileURLWithPath: environment["TANDEM_CLEAN_PLATE_OUT"] ?? "/private/tmp/tandem-clean-plate")
        var report: [String] = []
        for (name, plate) in [("with", true), ("without", false)] {
            let folder = out.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let context = JobContext(id: "clean-plate-\(name)", kind: .matte, qos: .utility, scheduler: nil)
            let start = Date()
            try await MatteJob.run(source: source, settings: AnalysisSettings(matteCleanPlate: plate), into: folder, context: context)
            report.append(String(format: "%@: %.1f s, notes: %@", name, Date().timeIntervalSince(start), context.lastNote ?? "none (plate made, or off)"))
            // RVM ran (no Vision fallback note), and with the plate on, it
            // made one (no "No clean plate" note).
            XCTAssertNil(context.lastNote, "\(name): \(context.lastNote ?? "")")
        }
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
    }
}
