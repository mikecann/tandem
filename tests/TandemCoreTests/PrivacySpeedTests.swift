import XCTest
@testable import TandemCore

/// Privacy checks run on every edit, so they have to stay quick on a long
/// timeline. On 24 Nov 2026 they asked `isPrivacy` (a scan of the track)
/// once per clip, and joining 3,000 clips went from 0.1 s to over 2 s.
final class PrivacySpeedTests: XCTestCase {
    func testEditsStayQuickOnALongTimelineWithARedaction() throws {
        var fixture = Fixture()
        let pieces = 1000
        let length = t(0.1)
        fixture.project.media[0].duration = t(200)
        fixture.project.media[1].duration = t(201)
        for (name, mediaID, offset) in [("Screen", "med_screen", t(0.5)), ("Camera", "med_camera", Time.zero), ("Voice", "med_camera", Time.zero)] {
            let location = try XCTUnwrap(fixture.project.location(ofTrack: fixture.track(name).id))
            fixture.project[location].clips = (0..<pieces).map { i in
                let start = Time(flicks: length.flicks * Int64(i))
                return Clip(id: "clip_\(name)_\(i)", content: .media(mediaID: mediaID), start: start, duration: length,
                            sourceStart: start + offset, linkGroup: "lnk_\(i)")
            }
        }
        let c = ProjectCoordinator(project: fixture.project)
        try c.apply(EditBatch(label: "Redact", commands: [.redact(range: TimeRange(start: t(10), end: t(12)),
            rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen", style: .blur, size: 48)]))
        let started = Date()
        try c.apply(EditBatch(label: "Trim", commands: [.trim(clipID: "clip_Camera_500", edge: .end, to: t(50.05))]))
        let elapsed = Date().timeIntervalSince(started)
        // About 0.1 s on a Mac and 1 s on a shared CI runner; it took 250 s
        // when the checks scanned each track once per clip.
        XCTAssertLessThan(elapsed, 5, "a trim on a 3,000 clip timeline with a redaction took \(elapsed) s")
    }

    /// A project with lots of files: on 26 Nov 2026 each check asked every
    /// file whether it was a protected file's alias by looking through every
    /// file again, and resolved and statted each file once per policy. A
    /// 578-file project spent two seconds on each edit, and a drag previews
    /// an edit on every pointer move, so moving a sound effect lagged.
    func testEditsStayQuickWithManyFilesAndARedaction() throws {
        let (c, _, _) = try PrivacyFollowupTests().ready()
        var p = c.project
        // Screenshot names carry a narrow no-break space, which makes their
        // paths slow to hash and compare.
        let files = (0..<1500).map { i in
            MediaItem(id: "med_sfx_\(i)", path: "sound/Screenshot 2026-11-20 at 10.15.\(i)\u{202F}AM whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        }
        p.media += files
        p.audioTracks = [Track(id: "trk_sfx", kind: .audio, name: "SFX", clips: files.prefix(200).enumerated().map { i, item in
            Clip(id: "clip_sfx_\(i)", content: .media(mediaID: item.id), start: t(Double(i) * 2), duration: t(1))
        })]
        let big = ProjectCoordinator(project: p)
        let started = Date()
        try big.apply(EditBatch(label: "Move clip", commands: [.moveClips(clipIDs: ["clip_sfx_100"], delta: t(0.5))]))
        let elapsed = Date().timeIntervalSince(started)
        // About 0.1 s on a Mac with the checks looking each file up once,
        // and about 4 s before.
        XCTAssertLessThan(elapsed, 2, "a move on a 1,500-file project with a redaction took \(elapsed) s")
    }

    /// The lookups a batch or a drag shares remember answers only for the
    /// media list they saw: a file added since is still checked.
    func testSharedLookupsNoticeANewAliasOfAProtectedFile() throws {
        let (c, _, _) = try PrivacyFollowupTests().ready()
        let files = RedactionSafety.FileLookups()
        let scope = try XCTUnwrap(RedactionSafety.protections(in: c.project).first)
        var p = c.project
        XCTAssertEqual(files.matching(scope, in: p), [true])
        p.media.append(MediaItem(id: "med_alias", path: "./screen.mov", kind: .video, role: .screen, duration: t(20), frameRate: .fps30, width: 1280, height: 720, hasVideo: true))
        XCTAssertEqual(files.matching(scope, in: p), [true, true], "the alias of the protected file")
        RedactionSafety.rememberPolicies(&p, files: files)
        XCTAssertTrue(RedactionSafety.protections(in: p).contains { $0.identities?.contains { $0.mediaID == "med_alias" } == true })
    }

    /// A caller that hands one context to several edits still has each
    /// look at the disk again: a file that became a hard link of the
    /// protected one in between is its alias. That holds after a batch, a
    /// lone command, or a command that failed.
    func testEachEditLooksAtTheFilesAgain() throws {
        enum First: CaseIterable { case batch, command, failedCommand }
        for first in First.allCases {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-lookups-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let original = folder.appendingPathComponent("original.mov")
            let other = folder.appendingPathComponent("other.mov")
            try Data("original source".utf8).write(to: original)
            try Data("other source".utf8).write(to: other)
            let (base, _, _) = try PrivacyFollowupTests().ready()
            var p = base.project
            p.videoTracks.removeAll(where: \.isPrivacy); p.sourceRedactions = nil
            p.media[0].path = original.path
            var otherItem = p.media[0]
            otherItem.id = "med_other"; otherItem.path = other.path
            p.media.append(otherItem)
            let c = ProjectCoordinator(project: p)
            try c.run("Protect original", .redact(range: TimeRange(start: .zero, end: t(5)), rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen", style: .blur, size: 48))
            var project = c.project
            var context = EditContext(seed: 1)
            let marker = EditCommand.addMarker(marker: Marker(id: "mk_1", time: t(1), name: "One"))
            switch first {
            case .batch: try Editing.apply(EditBatch(label: "Add a marker", commands: [marker]), to: &project, context: &context)
            case .command: try Editing.apply(marker, to: &project, context: &context)
            case .failedCommand: XCTAssertThrowsError(try Editing.apply(.removeClips(clipIDs: ["clip_missing"]), to: &project, context: &context))
            }
            try FileManager.default.removeItem(at: other)
            try FileManager.default.linkItem(at: original, to: other)
            let place = EditCommand.placeMedia(mediaIDs: ["med_other"], at: t(10), duration: t(5))
            var viaBatch = project
            XCTAssertThrowsError(try Editing.apply(EditBatch(label: "Show the alias", commands: [place]), to: &viaBatch, context: &context), "after a \(first)")
            var viaCommand = project
            XCTAssertThrowsError(try Editing.apply(place, to: &viaCommand, context: &context), "after a \(first)")
        }
    }
}
