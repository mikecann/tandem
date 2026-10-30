import XCTest
@testable import TandemCore

/// Pointing media at another file (a processed copy of a voice, swapped in
/// with updateMedia's path) must not keep the old file's fingerprint, since
/// every analysis is cached under it: the James interview's swapped voice
/// kept its old loudness and transcript (30 Oct 2026).
final class ReplaceMediaFileTests: XCTestCase {
    func testANewPathDropsTheOldFingerprint() throws {
        var fixture = Fixture()
        fixture.project.media[0].fingerprint = "100-200-abc"
        let c = ProjectCoordinator(project: fixture.project)
        try c.run("Swap", .updateMedia(mediaID: "med_camera", patch: .object(["path": .string("audio/take1-clean.wav")])))
        let item = try XCTUnwrap(c.project.media("med_camera"))
        XCTAssertEqual(item.path, "audio/take1-clean.wav")
        XCTAssertNil(item.fingerprint, "analysis fingerprints the new file instead")
        XCTAssertEqual(item.role, .camera, "everything else stays")
    }

    func testAFingerprintGivenWithThePathIsKept() throws {
        var fixture = Fixture()
        fixture.project.media[0].fingerprint = "100-200-abc"
        let c = ProjectCoordinator(project: fixture.project)
        try c.run("Relink", .updateMedia(mediaID: "med_camera", patch: .object(["path": .string("elsewhere/take1-camera.mov"), "fingerprint": .string("100-300-abc")])))
        XCTAssertEqual(c.project.media("med_camera")?.fingerprint, "100-300-abc")
    }

    func testOtherChangesKeepTheFingerprint() throws {
        var fixture = Fixture()
        fixture.project.media[0].fingerprint = "100-200-abc"
        let c = ProjectCoordinator(project: fixture.project)
        try c.run("Role", .updateMedia(mediaID: "med_camera", patch: .object(["role": .string("screen")])))
        XCTAssertEqual(c.project.media("med_camera")?.fingerprint, "100-200-abc")
        try c.run("Same path", .updateMedia(mediaID: "med_camera", patch: .object(["path": .string("source/take1-camera.mov")])))
        XCTAssertEqual(c.project.media("med_camera")?.fingerprint, "100-200-abc", "the same path is the same file")
    }

    func testTheScansCopyOfTheNewFileGoes() throws {
        var (fixture, c) = try Fixture.edited()
        // The folder watcher saw the processed file land and took it for a
        // camera take before the swap.
        let scanned = MediaItem(id: "med_scanned", path: "audio/take1-clean.wav", kind: .audio, role: .camera, duration: t(60), hasAudio: true, fingerprint: "1-2-new")
        try c.run("Scan", .addMedia(item: scanned))
        let result = try c.run("Swap", .updateMedia(mediaID: "med_camera", patch: .object(["path": .string("audio/take1-clean.wav")])))
        XCTAssertNil(c.project.media("med_scanned"))
        XCTAssertEqual(c.project.media.filter { $0.path == "audio/take1-clean.wav" }.map(\.id), ["med_camera"])
        XCTAssertTrue(result.warnings.contains { $0.contains("med_scanned") }, "\(result.warnings)")
        fixture.project = c.project
        assertValid(fixture.project)
        c.undo()
        XCTAssertNotNil(c.project.media("med_scanned"), "one undo step puts both back")
    }

    func testACopyAClipPlaysStays() throws {
        let (_, c) = try Fixture.edited()
        let other = MediaItem(id: "med_other", path: "audio/take1-clean.wav", kind: .audio, role: .other, duration: t(60), hasAudio: true)
        try c.run("Add", .addMedia(item: other))
        try c.run("Place", .placeMedia(mediaIDs: ["med_other"], at: t(70), duration: t(5)))
        try c.run("Swap", .updateMedia(mediaID: "med_camera", patch: .object(["path": .string("audio/take1-clean.wav")])))
        XCTAssertNotNil(c.project.media("med_other"))
    }
}

extension ReplaceMediaFileTests {
    func testASwapRemembersTheOldFileAndAMoveDoesnt() throws {
        let fixture = Fixture()
        let c = ProjectCoordinator(project: fixture.project)
        try c.run("Swap", .updateMedia(mediaID: "med_camera", patch: .object(["path": .string("audio/clean.wav")])))
        XCTAssertEqual(c.project.media("med_camera")?.replaces, ["source/take1-camera.mov"], "scans leave the old file out")
        try c.run("Swap back", .updateMedia(mediaID: "med_camera", patch: .object(["path": .string("source/take1-camera.mov")])))
        XCTAssertEqual(c.project.media("med_camera")?.replaces, ["audio/clean.wav"])
        try c.run("Move", .updateMedia(mediaID: "med_music", patch: .object(["path": .string("elsewhere/bed.m4a"), "fingerprint": .string("1-2-x")])))
        XCTAssertNil(c.project.media("med_music")?.replaces, "a file moved with its fingerprint is the same file")
    }
}

extension ReplaceMediaFileTests {
    /// An archive moves two items that share a file one after the other;
    /// the second mustn't take the first for a scan's copy.
    func testAMoveLeavesOtherItemsForTheFileAlone() throws {
        var fixture = Fixture()
        fixture.project.media.append(MediaItem(id: "med_music2", path: "music/bed.m4a", kind: .audio, role: .music, duration: t(180), hasAudio: true))
        let c = ProjectCoordinator(project: fixture.project)
        try c.run("Archive",
                  .updateMedia(mediaID: "med_music", patch: .object(["path": .string("media/bed.m4a"), "fingerprint": .null])),
                  .updateMedia(mediaID: "med_music2", patch: .object(["path": .string("media/bed.m4a"), "fingerprint": .null])))
        XCTAssertEqual(c.project.media.filter { $0.path == "media/bed.m4a" }.map(\.id), ["med_music", "med_music2"])
        XCTAssertNil(c.project.media("med_music")?.replaces)
    }
}
