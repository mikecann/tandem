import Foundation
import XCTest
@testable import TandemCore

final class PrivacySourceControlTests: XCTestCase {
    func testStrengtheningAnEffectCannotReanchorProtectedMediaInABatch() throws {
        let patches: [(variableRate: Bool, patch: JSONValue)] = [
            (false, .object(["pictureDelay": .number(1)])),
            (false, .object(["frameRate": try .from(FrameRate.fps60)])),
            (false, .object(["duration": .number(30)])),
            (false, .object(["width": .number(2560), "height": .number(1440)])),
            (true, .object(["variableFrameRate": .bool(false)]))
        ]
        for (variableRate, patch) in patches {
            let (c, _, mask) = try PrivacyFollowupTests().ready(variableRate: variableRate)
            let before = c.project
            let effect = before.clip(mask)!.video!.redactionEffectID!
            let batch = EditBatch(label: "Change mapping and strengthen blur", commands: [
                .updateMedia(mediaID: "med_screen", patch: patch),
                .updateEffect(clipID: mask, effectID: effect, patch: .object(["params": .object(["radius": .number(49)])]))
            ])
            XCTAssertThrowsError(try c.apply(batch)) { error in
                XCTAssertTrue(String(describing: error).lowercased().contains("privacy"), "\(error)")
            }
            XCTAssertEqual(c.project, before)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-batch-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            let journal = ProjectJournal(url: url)
            journal.append(batch: batch, revision: 1, seed: 1)
            let saved = try Data(contentsOf: url)
            XCTAssertThrowsError(try journal.recover(project: before, revision: 0))
            XCTAssertEqual(try Data(contentsOf: url), saved)
        }
    }

    func testStrengtheningARelinkedBlurRetainsOfflineOriginalFileIdentity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.mov")
        let alias = folder.appendingPathComponent("alias.mov")
        let replacement = folder.appendingPathComponent("replacement.mov")
        try Data("original source".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)
        try Data("replacement source".utf8).write(to: replacement)
        let fileID = try XCTUnwrap(RedactionSafety.fileIdentity(at: original))
        let (base, _, _) = try PrivacyFollowupTests().ready()
        var p = base.project
        p.videoTracks.removeAll(where: \.isPrivacy); p.sourceRedactions = nil
        p.media[0].path = original.path; p.media[0].fingerprint = "fp_original"
        let c = ProjectCoordinator(project: p)
        try c.run("Protect original", .redact(range: TimeRange(start: .zero, end: t(5)), rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen", style: .blur, size: 48))
        let mask = c.project.videoTracks.first(where: \.isPrivacy)!.clips[0]
        try c.run("Relink source", .updateMedia(mediaID: "med_screen", patch: .object(["path": .string(replacement.path)])))
        try FileManager.default.removeItem(at: original)
        try c.run("Strengthen blur", .updateEffect(clipID: mask.id, effectID: mask.video!.redactionEffectID!, patch: .object(["params": .object(["radius": .number(60)])])))
        let loaded = try ProjectFile.migrate(JSONDecoder().decode(Project.self, from: ProjectFile.encoder().encode(c.project)))
        XCTAssertTrue(RedactionSafety.protections(in: loaded).contains { $0.identities?.contains { $0.fileIdentity == fileID } == true })
        let next = ProjectCoordinator(project: loaded)
        var item = p.media[0]
        item.id = "med_original_alias"; item.path = alias.path; item.fingerprint = nil
        try next.run("Find original under another name", .addMedia(item: item))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "trk_screen", clip: Clip(id: "clip_original_alias", content: .media(mediaID: item.id), start: t(7), duration: t(1), sourceStart: t(1))), to: next))
    }

    func testAdoptingAFormatCannotRewriteALockedPrivacyCopy() throws {
        for disabled in [false, true] {
            let (c, picture, mask) = try PrivacyFollowupTests().ready()
            try c.run("Portrait layout", .setFormatLayout(clipIDs: [picture], format: "portrait", slot: .top))
            if disabled { try c.run("Copy off", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)]))) }
            else { try c.run("Unlink copy", .unlink(clipIDs: [mask])) }
            try c.run("Lock privacy", .updateTrack(trackID: c.project.videoTracks.first(where: \.isPrivacy)!.id, patch: .object(["locked": .bool(true)])))
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.adoptFormat(format: "portrait"), to: c))
        }
    }

    func testALockedPrivacyTrackCannotBeReordered() throws {
        let (c, _, _) = try PrivacyFollowupTests().ready()
        let track = c.project.videoTracks.first(where: \.isPrivacy)!.id
        try c.run("Another overlay", .addTrack(kind: .video, name: "Overlay", id: "trk_overlay"))
        try c.run("Lock privacy", .updateTrack(trackID: track, patch: .object(["locked": .bool(true)])))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.moveTrack(trackID: track, index: 2), to: c))
    }

    func testPictureFreezeDoesNotRecaptureALockedInactiveCopy() throws {
        for mode in ["copy", "effect", "track"] {
            let (c, picture, mask) = try PrivacyFollowupTests().ready()
            let track = c.project.videoTracks.first(where: \.isPrivacy)!.id
            switch mode {
            case "copy": try c.run("Copy off", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
            case "effect": try c.run("Blur off", .updateEffect(clipID: mask, effectID: c.project.clip(mask)!.video!.redactionEffectID!, patch: .object(["enabled": .bool(false)])))
            default: try c.run("Hide privacy", .updateTrack(trackID: track, patch: .object(["hidden": .bool(true)])))
            }
            try c.run("Lock privacy", .updateTrack(trackID: track, patch: .object(["locked": .bool(true)])))
            let before = c.project.clip(mask)
            try c.run("Freeze picture", .updateClip(clipID: picture, patch: .object(["freezeFrame": .bool(true), "sourceStart": .number(10)])))
            XCTAssertEqual(c.project.clip(mask), before, mode)
            XCTAssertTrue(c.project.clip(picture)!.freezeFrame)
        }
    }
}
