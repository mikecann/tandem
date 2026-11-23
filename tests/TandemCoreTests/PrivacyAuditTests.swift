import XCTest
@testable import TandemCore

/// Report-only scratch regressions. These assert the privacy contract, so a
/// failure is evidence; this file is never installed in the application repo.
final class PrivacyAuditAlignmentTests: XCTestCase {
    let region = Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)

    func ready(crop: Double = 0, animated: Bool = false) throws -> (ProjectCoordinator, String, String) {
        let (_, c) = try Fixture.edited()
        let screen = c.clips("Screen")[0]
        if crop > 0 {
            try c.run("Crop", .updateClip(clipID: screen.id, patch: .object(["video": .object(["crop": .object(["left": .number(crop)])])])))
        }
        if animated {
            try c.run("Animate before", .setKeyframes(clipID: screen.id, parameter: "video.transform.scale", keyframes: [
                Keyframe(time: .zero, value: .number(1)), Keyframe(time: t(60), value: .number(2))
            ]))
        }
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: region, mediaID: "med_screen", style: .blur))
        return (c, c.clips("Screen").first { $0.start == t(10) }!.id, c.clips("Privacy (Screen)")[0].id)
    }

    func aligned(_ c: ProjectCoordinator, _ picture: String, _ patch: String, at time: Double = 2, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.project.clip(picture)!.resolvedVideo(at: t(time)).transform,
                       c.project.clip(patch)!.resolvedVideo(at: t(time)).transform,
                       "redaction must follow the picture after the edit", file: file, line: line)
    }

    func testLaterUpdateTransformFollows() throws {
        let (c, picture, patch) = try ready()
        try c.run("Move", .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object([
            "position": .object(["x": .number(0.7), "y": .number(0.6)]), "scale": .number(1.3), "rotation": .number(10), "flipped": .bool(true)
        ])])])))
        aligned(c, picture, patch)
    }

    func testLaterCropWideningCoversNewlyVisiblePart() throws {
        let (c, picture, patch) = try ready(crop: 0.45)
        try c.run("Uncrop", .updateClip(clipID: picture, patch: .object(["video": .object(["crop": .object(["left": .number(0)])])])))
        XCTAssertEqual(c.project.clip(patch)!.video!.crop.left, region.x, accuracy: 1e-9, "0.2 to 0.45 is newly visible and must be covered")
    }

    func testLaterCropAnimationCoversNewlyVisiblePart() throws {
        let (c, picture, patch) = try ready(crop: 0.45)
        try c.run("Animate crop", .setKeyframes(clipID: picture, parameter: "video.crop.left", keyframes: [Keyframe(time: .zero, value: .number(0))]))
        XCTAssertEqual(c.project.clip(patch)!.video!.crop.left, region.x, accuracy: 1e-9)
    }

    func testLaterSetKeyframesFollows() throws {
        let (c, picture, patch) = try ready()
        try c.run("Animate scale", .setKeyframes(clipID: picture, parameter: "video.transform.scale", keyframes: [
            Keyframe(time: .zero, value: .number(1), interpolation: .linear), Keyframe(time: t(5), value: .number(2))
        ]))
        aligned(c, picture, patch)
    }

    func testRemovingExistingKeyframesAlsoFollows() throws {
        let (c, picture, patch) = try ready(animated: true)
        aligned(c, picture, patch)
        try c.run("Stop motion", .setKeyframes(clipID: picture, parameter: "video.transform.scale", keyframes: []))
        aligned(c, picture, patch)
    }

    func testLaterZoomStaticFollows() throws {
        let (c, picture, patch) = try ready()
        try c.run("Zoom", .zoomToRegion(clipID: picture, rect: region))
        aligned(c, picture, patch)
    }

    func testLaterZoomAnimatedFollows() throws {
        let (c, picture, patch) = try ready()
        try c.run("Zoom", .zoomToRegion(clipID: picture, rect: region, at: t(11), duration: t(1)))
        aligned(c, picture, patch, at: 1.5)
    }

    func testLaterAddMotionFollows() throws {
        let (c, picture, patch) = try ready()
        try c.run("Motion", .addMotion(clipIDs: [picture], style: .zoomIn, amount: 1.5))
        aligned(c, picture, patch)
    }

    func testDirectFormatOverrideFollows() throws {
        let (c, picture, patch) = try ready()
        try c.run("Format", .updateSettings(patch: .object(["alternateFormats": try JSONValue.from([OutputFormat.portrait])])))
        try c.run("Short", .setFormatLayout(clipIDs: [picture], format: "portrait", slot: .top))
        try c.run("Tweak short", .updateClip(clipID: picture, patch: .object(["video": .object(["formatOverrides": .object([
            "portrait": .object(["transform": .object(["scale": .number(1.6)])])
        ])])])))
        XCTAssertEqual(c.project.clip(picture)!.video!.formatOverrides["portrait"]!.transform,
                       c.project.clip(patch)!.video!.formatOverrides["portrait"]!.transform)
    }
}

final class PrivacyAuditLifecycleTests: XCTestCase {
    func testLockedPrivacyTrackDoesNotPermitARippleThatLeavesPrivateFramesExposed() throws {
        let (c, picture, patch) = try PrivacyAuditAlignmentTests().ready()
        let track = c.project.videoTracks.first { $0.isPrivacy }!
        try c.run("Lock privacy", .updateTrack(trackID: track.id, patch: .object(["locked": .bool(true)])))
        let scopes = PrivacyAuditCoverage.capture(c.project)
        if try PrivacyAuditCoverage.applyOrRefuse(.cutRanges(ranges: [TimeRange(start: t(4), end: t(6))]), to: c) {
            XCTAssertEqual(c.project.clip(picture)!.range, c.project.clip(patch)!.range, "if the locked blur cannot move, refuse the edit")
            XCTAssertTrue(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
        }
    }

    func pairs(_ c: ProjectCoordinator, protecting scopes: [PrivacyAuditIntent], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(scopes.isEmpty, "capture privacy intent before editing", file: file, line: line)
        let failures = PrivacyAuditCoverage.failures(c.project, protecting: scopes)
        XCTAssertTrue(failures.isEmpty, "uncovered protected source: \(failures)", file: file, line: line)
        assertValid(c.project, file: file, line: line)
    }

    func testNineDirectEditsHaveImmediateCoverageInThisFixture() throws {
        let names = ["blade", "cut before", "cut inside", "trim", "slip", "same-track move", "speed", "cut-track insert", "join"]
        for name in names {
            let (c, picture, _) = try PrivacyAuditAlignmentTests().ready(animated: true)
            let scopes = PrivacyAuditCoverage.capture(c.project)
            switch name {
            case "blade": try c.run(name, .blade(at: t(12)))
            case "cut before": try c.run(name, .cutRanges(ranges: [TimeRange(start: t(4), end: t(6))]))
            case "cut inside": try c.run(name, .rippleDeleteRange(range: TimeRange(start: t(11), end: t(12))))
            case "trim": try c.run(name, .trim(clipID: picture, edge: .end, to: t(14), ripple: true))
            case "slip": try c.run(name, .slip(clipID: picture, delta: t(0.5)))
            case "same-track move": try c.run(name, .moveClips(clipIDs: [picture], delta: t(55)))
            case "speed": try c.run(name, .setSpeed(clipID: picture, speed: 1.5, ripple: true))
            case "cut-track insert": try c.run(name, .insertTime(at: t(12), duration: t(1)))
            case "join":
                try c.run("Blade", .blade(at: t(12)))
                try c.run(name, .join(clipID: picture))
            default: XCTFail("unknown audit operation")
            }
            pairs(c, protecting: scopes)
            let after = c.project
            _ = try c.undo()
            _ = try c.redo()
            XCTAssertEqual(c.project, after, name)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).tandem")
            defer { try? FileManager.default.removeItem(at: url) }
            try ProjectFile.save(c.project, revision: c.revision, to: url)
            let loaded = try ProjectFile.load(from: url)
            XCTAssertEqual(loaded.project, c.project, name)
            pairs(ProjectCoordinator(project: loaded.project), protecting: scopes)
            print("AUDIT lifecycle \(name): checked timing, animation, undo/redo, disk reload")
        }
    }

    func testUndoRedoAndReloadPreserveAlignedRedactions() throws {
        let (c, picture, patch) = try PrivacyAuditAlignmentTests().ready()
        let before = c.project
        try c.run("Move", .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["scale": .number(2)])]) ])))
        let after = c.project
        XCTAssertEqual(after.clip(picture)!.video!.transform, after.clip(patch)!.video!.transform)
        _ = try c.undo()
        XCTAssertEqual(c.project, before)
        _ = try c.redo()
        XCTAssertEqual(c.project, after)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).tandem")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectFile.save(c.project, revision: c.revision, to: url)
        let loaded = try ProjectFile.load(from: url)
        XCTAssertEqual(loaded.project, after)
        XCTAssertEqual(loaded.project.clip(picture)!.video!.transform, loaded.project.clip(patch)!.video!.transform)
    }

    func testHoldInsideRedactedPieceRetainsCoverage() throws {
        let (_, c) = try Fixture.edited()
        let screen = c.clips("Screen")[0]
        try c.run("Hold before", .holdFrame(clipID: screen.id, range: TimeRange(start: t(12), end: t(12.1))))
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen"))
        let picture = c.clips("Screen").first { $0.start == t(10) }!
        let patch = c.clips("Privacy (Screen)")[0]
        let scopes = PrivacyAuditCoverage.capture(c.project)
        XCTAssertEqual(picture.holds, patch.holds)
        try c.run("Hold after", .holdFrame(clipID: picture.id, range: TimeRange(start: t(13), end: t(13.1))))
        XCTAssertEqual(c.project.clip(picture.id)!.holds, c.project.clip(patch.id)!.holds)
        pairs(c, protecting: scopes)
        print("AUDIT hold: picture and redaction hold the same frame")
    }
}
