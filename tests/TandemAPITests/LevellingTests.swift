import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// A clip levelled to a loudness (`audio.normalizeTo`) from a file nobody
/// has measured plays at the file's own level. On the Convex 1.50 video
/// music beds levelled to -45 LUFS played at -12.5, as loud as the voice,
/// with no word from `apply` or `check`.
final class LevellingTests: XCTestCase {
    private let level: EditCommand = .updateClip(
        clipID: "clip_mus1", patch: .object(["audio": .object(["normalizeTo": .number(-45), "gainDB": .number(0)])])
    )

    private func harness() throws -> ServiceHarness {
        let h = try ServiceHarness()
        // check leaves a missing file to validate, so the bed is there.
        try FileManager.default.createDirectory(at: h.folder.file("music"), withIntermediateDirectories: true)
        try Data().write(to: h.folder.file("music/bed.m4a"))
        // The take is measured, as it always is by the time it's edited.
        h.analysis.measured["med_camera"] = Loudness(integratedLUFS: -18, truePeakDBTP: -3, loudnessRange: 6)
        return h
    }

    func testLevellingAClipMeasuresItsFile() async throws {
        let h = try harness()
        defer { h.close() }
        let analysis = h.analysis
        analysis.onRequest = { kind, item in
            if kind == .loudness { analysis.measured[item.id] = Loudness(integratedLUFS: -12.5, truePeakDBTP: -1, loudnessRange: 6) }
        }
        let result = try await ApplyRequest(commands: [level]).run(on: h.service, context: h.context)
        XCTAssertTrue(analysis.requests.contains { $0.kind == .loudness && $0.mediaID == "med_music" && $0.priority == .interactive })
        XCTAssertFalse(result.warnings.contains { $0.contains("isn't measured") }, "\(result.warnings)")
        XCTAssertNotNil(analysis.measured["med_music"])
    }

    func testAFileThatCantBeMeasuredNowIsSaidLoudly() async throws {
        let h = try harness()
        defer { h.close() }
        let dry = try await ApplyRequest(commands: [level], dryRun: true).run(on: h.service, context: h.context)
        XCTAssertTrue(dry.warnings.contains { $0.hasPrefix("music/bed.m4a isn't measured yet, so its clip levelled to -45 LUFS plays at the file's own level") }, "\(dry.warnings)")

        let started = Date()
        let result = try await ApplyRequest(commands: [level]).run(on: h.service, context: h.context)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "nothing is measuring it, so it doesn't wait")
        let warning = try XCTUnwrap(result.warnings.first { $0.contains("isn't measured") }, "\(result.warnings)")
        XCTAssertTrue(warning.contains("`tandem wait jobs --media med_music`"), warning)

        // And check fails on it until it's measured.
        let check = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        let problem = try XCTUnwrap(check.problems.first { $0.kind == .unlevelled }, "\(check.problems)")
        XCTAssertEqual(problem.clipIDs, ["clip_mus1"])
        XCTAssertTrue(problem.message.contains("Levelled to -45 LUFS, but music/bed.m4a isn't measured yet"), problem.message)
        XCTAssertFalse(check.ok)

        // A muted Music track isn't heard, so it's no problem.
        _ = try h.apply(.updateTrack(trackID: "trk_music", patch: .object(["muted": .bool(true)])))
        let muted = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertFalse(muted.problems.contains { $0.kind == .unlevelled }, "\(muted.problems)")
        _ = try h.apply(.updateTrack(trackID: "trk_music", patch: .object(["muted": .bool(false)])))

        h.analysis.measured["med_music"] = Loudness(integratedLUFS: -12.5, truePeakDBTP: -1, loudnessRange: 6)
        let measured = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertFalse(measured.problems.contains { $0.kind == .unlevelled }, "\(measured.problems)")
    }

    func testUnmutingALevelledBedMeasuresIt() async throws {
        // Levelled while its track was muted, so not heard and not measured;
        // unmuting changes no clip, but makes it heard.
        let h = try harness()
        defer { h.close() }
        _ = try h.apply(.updateTrack(trackID: "trk_music", patch: .object(["muted": .bool(true)])))
        let quiet = try await ApplyRequest(commands: [level]).run(on: h.service, context: h.context)
        XCTAssertFalse(quiet.warnings.contains { $0.contains("isn't measured") }, "\(quiet.warnings)")
        let unmute = EditCommand.updateTrack(trackID: "trk_music", patch: .object(["muted": .bool(false)]))
        let heard = try await ApplyRequest(commands: [unmute]).run(on: h.service, context: h.context)
        XCTAssertTrue(heard.warnings.contains { $0.hasPrefix("music/bed.m4a isn't measured yet") }, "\(heard.warnings)")
        XCTAssertTrue(h.analysis.requests.contains { $0.kind == .loudness && $0.mediaID == "med_music" })
    }
}
