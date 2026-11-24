import Foundation
import XCTest
@testable import TandemAPI
@testable import TandemCore

final class PrivacyPreflightTests: XCTestCase {
    func protected() throws -> ServiceHarness {
        let item = MediaItem(id: "med_screen", path: "original.mov", kind: .video, role: .screen, duration: t(20), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let picture = Clip(id: "clip_screen", content: .media(mediaID: item.id), start: .zero, duration: t(3))
        let p = Project(name: "Privacy preflight", settings: ProjectSettings(width: 1280, height: 720), media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [picture])])
        let h = try ServiceHarness(project: p)
        try h.apply(.redact(range: picture.range, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: item.id))
        return h
    }

    func testPreflightAllowsAProtectedReuseAndItsRedactionInOneBatch() throws {
        let h = try protected()
        defer { h.close() }
        let before = h.service.coordinator.project
        let revision = h.service.coordinator.revision
        let commands: [EditCommand] = [
            .insertClip(trackID: "trk_screen", clip: Clip(id: "clip_reuse", content: .media(mediaID: "med_screen"), start: t(10), duration: t(3))),
            .redact(range: TimeRange(start: t(10), end: t(13)), rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen")
        ]
        let dry = try h.service.apply(ApplyRequest(commands: commands, dryRun: true), context: h.context)
        XCTAssertTrue(dry.dryRun)
        XCTAssertEqual(h.service.coordinator.project, before)
        XCTAssertEqual(h.service.coordinator.revision, revision)
        let actual = try h.service.apply(ApplyRequest(commands: commands), context: h.context)
        XCTAssertEqual(dry.duration, actual.duration)
        XCTAssertEqual(dry.added.count, actual.added.count)
    }

    func testPreflightRejectsRelativeAliasesLikeTheCommittedEdit() throws {
        for symlink in [false, true] {
            let h = try protected()
            defer { h.close() }
            let source = h.folder.url.appendingPathComponent("original.mov")
            let alias = h.folder.url.appendingPathComponent("alias.mov")
            try Data("identity-only fixture".utf8).write(to: source)
            try h.apply(.updateProject(patch: .object(["name": .string("Remember original inode")])))
            if symlink { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source) }
            else { try FileManager.default.linkItem(at: source, to: alias) }
            XCTAssertNotEqual(FileManager.default.currentDirectoryPath, h.folder.url.path)
            var item = h.service.coordinator.project.media[0]
            item.id = "med_alias"; item.path = "alias.mov"; item.fingerprint = nil
            let before = h.service.coordinator.project
            let commands: [EditCommand] = [.addMedia(item: item), .insertClip(trackID: "trk_screen", clip: Clip(id: "clip_alias", content: .media(mediaID: item.id), start: t(10), duration: t(1), sourceStart: t(1)))]
            for dryRun in [true, false] {
                assertServiceError(.invalid) {
                    _ = try h.service.apply(ApplyRequest(commands: commands, dryRun: dryRun), context: h.context)
                }
                XCTAssertEqual(h.service.coordinator.project, before)
            }
        }
    }
}
