import CoreGraphics
import XCTest
@testable import TandemCore

struct PrivacyAuditIntent {
    var mediaID: String
    var source: TimeRange
    var rect: Rect
}

/// Capture the protected source interval BEFORE an edit. Walk every picture,
/// including extended neighbours and copies moved to another track, rather
/// than walking only the masks that survived the edit. This is conservative
/// about occlusion: fixtures contain no unrelated foreground pictures.
enum PrivacyAuditCoverage {
    static func capture(_ p: Project) -> [PrivacyAuditIntent] {
        p.videoTracks.filter(\.isPrivacy).flatMap(\.clips).flatMap { c -> [PrivacyAuditIntent] in
            guard let media = c.mediaID, let region = c.video?.redaction else { return [] }
            let fileFrame = p.media(media)?.frameRate?.frameDuration ?? p.settings.frameRate.frameDuration
            func point(_ frame: Time) -> PrivacyAuditIntent {
                PrivacyAuditIntent(mediaID: media, source: TimeRange(start: frame, duration: fileFrame), rect: region)
            }
            let nominal = c.freezeFrame ? [] : [PrivacyAuditIntent(mediaID: media, source: TimeRange(start: c.sourceStart, duration: c.sourceDuration), rect: region)]
            // A hold changes only its picture, so the copy's own time map
            // cannot describe every frame it is meant to hide. Resolve both
            // the copy and its linked source over their shared timeline.
            // Unrelated views of the same file add no new privacy intent.
            var heldFrames = Set<Time>()
            func captureDisplayedFrames(_ picture: Clip, within range: TimeRange) {
                if picture.freezeFrame {
                    heldFrames.insert(picture.sourceStart)
                    return
                }
                var time = range.start
                while time < range.end {
                    let shown = picture.pictureTime(atTimelineTime: time)
                    if shown != picture.sourceTime(atTimelineTime: time) { heldFrames.insert(shown) }
                    time += p.settings.frameRate.frameDuration
                }
            }
            captureDisplayedFrames(c, within: c.range)
            if let group = c.linkGroup {
                for picture in p.videoTracks.filter({ !$0.isPrivacy }).flatMap(\.clips)
                    where picture.mediaID == media && picture.linkGroup == group {
                    if let shared = picture.range.intersection(c.range) {
                        captureDisplayedFrames(picture, within: shared)
                    }
                }
            }
            return nominal + heldFrames.sorted().map(point)
        }
    }

    static func hasMaskEffect(_ video: VideoProperties) -> Bool {
        video.effects.contains { effect in
            guard effect.enabled else { return false }
            switch effect.type {
            case "blur": return (effect.params["radius"]?.number ?? RedactStyle.blur.defaultSize) > 0
            case "pixelate": return (effect.params["scale"]?.number ?? RedactStyle.pixelate.defaultSize) > 1
            default: return false
            }
        }
    }

    static func intersection(_ a: Rect, _ crop: Crop) -> CGRect {
        CGRect(x: a.x, y: a.y, width: a.width, height: a.height).intersection(
            CGRect(x: crop.left, y: crop.top, width: max(0, 1-crop.left-crop.right), height: max(0, 1-crop.top-crop.bottom)))
    }

    static func placement(_ transform: Transform, media: MediaItem, project: Project) -> CGAffineTransform {
        let w = Double(media.width!), h = Double(media.height!)
        let cw = Double(project.settings.width), ch = Double(project.settings.height)
        let scale = min(cw/w, ch/h) * transform.scale
        return CGAffineTransform(translationX: -w/2, y: -h/2)
            .concatenating(CGAffineTransform(scaleX: transform.flipped ? -scale : scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: transform.rotation * .pi/180))
            .concatenating(CGAffineTransform(translationX: transform.position.x*cw, y: transform.position.y*ch))
    }

    static func failures(_ p: Project, protecting intents: [PrivacyAuditIntent]) -> [String] {
        var failures: [String] = []
        let frame = p.settings.frameRate.frameDuration
        let canvas = CGRect(x: 0, y: 0, width: p.settings.width, height: p.settings.height)
        for (index, track) in p.videoTracks.enumerated() where !track.hidden && !track.isPrivacy {
            // A source effect is not proof of concealment. In particular,
            // blur(radius: 0) is permitted and leaves a picture sharp.
            for picture in track.clips where picture.enabled {
                guard let mediaID = picture.mediaID, let media = p.media(mediaID), media.width != nil, media.height != nil else { continue }
                let scopes = intents.filter { $0.mediaID == mediaID }
                guard !scopes.isEmpty else { continue }
                var time = picture.start
                while time < picture.end {
                    let video = picture.resolvedVideo(at: time-picture.start)
                    let source = picture.pictureTime(atTimelineTime: time)
                    let nominalSource = picture.sourceTime(atTimelineTime: time)
                    // A later hold cannot erase the protected nominal span.
                    // This conservatively checks the region during that span
                    // as well as every occurrence of captured held frames.
                    for scope in scopes where (scope.source.contains(source) || scope.source.contains(nominalSource)) && video.opacity > 0 {
                        let shown = intersection(scope.rect, video.crop)
                        guard !shown.isNull && !shown.isEmpty else { continue }
                        let pixels = CGRect(x: shown.minX*Double(media.width!), y: shown.minY*Double(media.height!), width: shown.width*Double(media.width!), height: shown.height*Double(media.height!))
                        let area = pixels.applying(placement(video.transform, media: media, project: p))
                        guard area.intersects(canvas) else { continue }
                        let covered = p.videoTracks.enumerated().contains { maskIndex, masks in
                            guard maskIndex > index, masks.isPrivacy, !masks.hidden else { return false }
                            return masks.clips.contains { mask in
                                guard mask.enabled, mask.video?.redaction != nil, mask.mediaID == mediaID, mask.range.contains(time) else { return false }
                                let mv = mask.resolvedVideo(at: time-mask.start)
                                guard hasMaskEffect(mv) else { return false }
                                // Exact shared placement is the contract used by
                                // these fixtures. Unusual rotated/oversized masks
                                // require pixel verification rather than this oracle.
                                guard mv.transform == video.transform, mv.opacity >= 0.999 else { return false }
                                let mr = CGRect(x: mv.crop.left, y: mv.crop.top, width: 1-mv.crop.left-mv.crop.right, height: 1-mv.crop.top-mv.crop.bottom)
                                return mr.insetBy(dx: -1e-8, dy: -1e-8).contains(shown)
                            }
                        }
                        if !covered {
                            failures.append("\(picture.id) on \(track.name) timeline=\(time.seconds) source=\(source.seconds)")
                            break
                        }
                    }
                    if failures.last?.hasPrefix("\(picture.id) on ") == true { break }
                    time += frame
                }
            }
        }
        return failures
    }

    @discardableResult
    static func applyOrRefuse(_ command: EditCommand, to c: ProjectCoordinator, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let before = c.project
        do { try c.run("Privacy contract", command); return true }
        catch let error as EditError {
            switch error {
            case .locked, .invalid:
                let reason = String(describing: error).lowercased()
                guard ["privacy", "blur", "redact", "locked"].contains(where: reason.contains) else { throw error }
                XCTAssertEqual(c.project, before, "refusal must be atomic", file: file, line: line)
                return false
            default: throw error
            }
        }
    }
}

final class PrivacyPanelTests: XCTestCase {
    let region = Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)

    func testAtomicPrivacyRefusalIsAnAcceptedContractOutcome() throws {
        let (c, picture, _, _) = try screen()
        let track = c.project.track(named: "Privacy (Screen)")!
        try c.run("Lock", .updateTrack(trackID: track.id, patch: .object(["locked": .bool(true)])))
        let before = c.project
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.applyLayout(clipIDs: [picture], preset: .pipLeft), to: c))
        XCTAssertEqual(c.project, before)
        XCTAssertThrowsError(try PrivacyAuditCoverage.applyOrRefuse(.applyLayout(clipIDs: ["clip_missing"], preset: .pipLeft), to: c))
    }

    func screen() throws -> (ProjectCoordinator, String, String, [PrivacyAuditIntent]) {
        let (c, picture, patch) = try PrivacyAuditAlignmentTests().ready()
        // Other pictures must not hide a failure from the model probe.
        for track in c.project.videoTracks where !track.isPrivacy && track.name != "Screen" {
            try c.run("Hide unrelated track", .updateTrack(trackID: track.id, patch: .object(["hidden": .bool(true)])))
        }
        let broll = c.project.track(named: "B-roll")!
        try c.run("Empty destination", .removeClips(clipIDs: broll.clips.map(\.id), includeLinked: false))
        return (c, picture, patch, PrivacyAuditCoverage.capture(c.project))
    }

    func assertSafe(_ c: ProjectCoordinator, _ scopes: [PrivacyAuditIntent], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(scopes.isEmpty, "capture privacy intent before editing", file: file, line: line)
        let failures = PrivacyAuditCoverage.failures(c.project, protecting: scopes)
        XCTAssertTrue(failures.isEmpty, "\(name): \(failures)", file: file, line: line)
    }

    func roundTrip(_ c: ProjectCoordinator, scopes: [PrivacyAuditIntent], label: String) throws {
        let gaps = PrivacyAuditCoverage.failures(c.project, protecting: scopes)
        let after = c.project
        XCTAssertNotNil(c.undo()); XCTAssertNotNil(c.redo())
        XCTAssertEqual(c.project, after)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(UUID().uuidString).tandem")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectFile.save(c.project, revision: c.revision, to: url)
        let loaded = try ProjectFile.load(from: url).project
        XCTAssertEqual(PrivacyAuditCoverage.failures(loaded, protecting: scopes), gaps)
        print("PANEL \(label): protected-source gaps \(gaps); undo/redo/reload checked")
    }

    func testSlidesInBothDirectionsCoverProtectedSourceOnNeighbours() throws {
        for delta in [0.2, -0.2] {
            let (c, picture, _, scopes) = try screen()
            assertSafe(c, scopes, "before")
            if try PrivacyAuditCoverage.applyOrRefuse(.slide(clipID: picture, delta: t(delta)), to: c) {
                assertSafe(c, scopes, "slide \(delta)")
                try roundTrip(c, scopes: scopes, label: "slide \(delta)")
            }
        }
    }

    func testAdjacentSlideHasImmediateCoverageButDivergentMaskBounds() throws {
        let (c, picture, mask, scopes) = try screen()
        try c.run("Separate preceding piece", .blade(at: t(5)))
        let preceding = c.clips("Screen").first { $0.end == t(10) }!
        if try PrivacyAuditCoverage.applyOrRefuse(.slide(clipID: preceding.id, delta: t(0.2)), to: c) {
            assertSafe(c, scopes, "adjacent slide")
            XCTAssertEqual(c.project.clip(picture)!.start, t(10.2))
            XCTAssertNotEqual(c.project.clip(picture)!.range, c.project.clip(mask)!.range)
            try roundTrip(c, scopes: scopes, label: "adjacent slide")
        }
    }

    func testContinuousRollsHaveImmediateCoverageOnly() throws {
        for edge in ["head", "tail"] {
            for delta in [0.2, -0.2] {
                let (c, picture, mask, scopes) = try screen()
                let left = edge == "head" ? c.clips("Screen").first { $0.end == t(10) }!.id : picture
                let right = edge == "head" ? picture : c.clips("Screen").first { $0.start == t(15) }!.id
                try c.run("Roll", .roll(leftClipID: left, rightClipID: right, delta: t(delta)))
                assertSafe(c, scopes, "continuous roll \(edge) \(delta)")
                XCTAssertNotEqual(c.project.clip(picture)!.range, c.project.clip(mask)!.range)
                try roundTrip(c, scopes: scopes, label: "continuous roll \(edge) \(delta)")
            }
        }
    }

    func testRollsIntoDifferentlyFramedNeighboursCoverProtectedSource() throws {
        for edge in ["head", "tail"] {
            let (c, picture, _, scopes) = try screen()
            let neighbour = c.clips("Screen").first { edge == "head" ? $0.end == t(10) : $0.start == t(15) }!
            try c.run("Frame neighbour differently", .updateClip(clipID: neighbour.id, patch: .object(["video": .object(["transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.8)])])])])))
            assertSafe(c, scopes, "before roll")
            let command = EditCommand.roll(leftClipID: edge == "head" ? neighbour.id : picture, rightClipID: edge == "head" ? picture : neighbour.id, delta: t(edge == "head" ? 0.2 : -0.2))
            if try PrivacyAuditCoverage.applyOrRefuse(command, to: c) {
                assertSafe(c, scopes, "differently framed roll \(edge)")
                try roundTrip(c, scopes: scopes, label: "differently framed roll \(edge)")
            }
        }
    }

    func follow(_ mode: RippleMode) throws -> (ProjectCoordinator, String, [PrivacyAuditIntent]) {
        var p = Project.standard(name: "Panel follow")
        p.media = [MediaItem(id: "med_panel", path: "dummy.mov", kind: .video, role: .broll, duration: t(20), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)]
        let c = ProjectCoordinator(project: p)
        let track = c.project.track(named: "B-roll")!
        try c.run("Mode", .updateTrack(trackID: track.id, patch: .object(["rippleMode": .string(mode.rawValue)])))
        try c.run("Picture", .insertClip(trackID: track.id, clip: Clip(id: "clip_panel", content: .media(mediaID: "med_panel"), start: t(10), duration: t(5), video: VideoProperties())))
        try c.run("Animate before redacting", .setKeyframes(clipID: "clip_panel", parameter: "video.transform.position", keyframes: [
            Keyframe(time: .zero, value: .point(Point(x: 0.5, y: 0.5)), interpolation: .linear), Keyframe(time: t(5), value: .point(Point(x: 0.5, y: 0.8)))
        ]))
        try c.run("Hide", .redact(range: TimeRange(start: t(10), end: t(15)), rect: region, mediaID: "med_panel", style: .blur))
        return (c, track.id, PrivacyAuditCoverage.capture(c.project))
    }

    func testGlobalInsertOnFollowAndOffTracksPreservesPrivacy() throws {
        for mode: RippleMode in [.follow, .off] {
            let (c, _, scopes) = try follow(mode)
            assertSafe(c, scopes, "before insertion")
            let screen = c.project.track(named: "Screen")!
            if try PrivacyAuditCoverage.applyOrRefuse(.insertTime(at: t(12), duration: t(2), trackIDs: [screen.id]), to: c) {
                assertSafe(c, scopes, "global insert \(mode)")
                try roundTrip(c, scopes: scopes, label: "global insert \(mode)")
            }
        }
    }

    func testGlobalCutOnFollowTrackKeepsContentAnimationAligned() throws {
        let (c, _, scopes) = try follow(.follow)
        if try PrivacyAuditCoverage.applyOrRefuse(.cutRanges(ranges: [TimeRange(start: t(11), end: t(12))], trackIDs: [c.project.track(named: "Screen")!.id]), to: c) {
            assertSafe(c, scopes, "global follow cut")
            try roundTrip(c, scopes: scopes, label: "global follow cut")
        }
    }

    func testTargetedRippleOnFollowTrackMovesItsPrivacyCopy() throws {
        let (c, track, scopes) = try follow(.follow)
        if try PrivacyAuditCoverage.applyOrRefuse(.rippleDeleteRange(range: TimeRange(start: t(9), end: t(10)), trackIDs: [track]), to: c) {
            assertSafe(c, scopes, "targeted follow ripple")
            try roundTrip(c, scopes: scopes, label: "targeted follow ripple")
        }
    }

    func testMovingPictureToAHigherTrackKeepsPrivacyAboveIt() throws {
        let (c, picture, _, scopes) = try screen()
        let destination = c.project.track(named: "B-roll")!
        try c.run("Show destination", .updateTrack(trackID: destination.id, patch: .object(["hidden": .bool(false)])))
        if try PrivacyAuditCoverage.applyOrRefuse(.moveClips(clipIDs: [picture], delta: .zero, toTrackID: destination.id), to: c) {
            assertSafe(c, scopes, "track transfer")
            try roundTrip(c, scopes: scopes, label: "track transfer")
        }
    }

    func testMovingTheSourceTrackAboveItsPrivacyTrackKeepsCoverage() throws {
        let (c, _, _, scopes) = try screen()
        if try PrivacyAuditCoverage.applyOrRefuse(.moveTrack(trackID: c.project.track(named: "Screen")!.id, index: c.project.videoTracks.count-1), to: c) {
            assertSafe(c, scopes, "track reorder")
            try roundTrip(c, scopes: scopes, label: "track reorder")
        }
    }

    func testLockedAngleRedactionCannotBeStrandedDisabled() throws {
        let c = try SyncedPlacementTests.project()
        try c.run("Angle", .placeSynced(mediaID: "med_angle"))
        try c.run("Hide", .redact(range: TimeRange(start: t(20), end: t(30)), rect: region, mediaID: "med_angle"))
        let scopes = PrivacyAuditCoverage.capture(c.project)
        try c.run("Base camera", .showAngle(range: TimeRange(start: t(20), end: t(30)), trackID: "Camera"))
        let privacy = c.project.track(named: "Privacy (Angle 2)")!
        XCTAssertFalse(privacy.clips[0].enabled)
        try c.run("Lock privacy", .updateTrack(trackID: privacy.id, patch: .object(["locked": .bool(true)])))
        if try PrivacyAuditCoverage.applyOrRefuse(.showAngle(range: TimeRange(start: t(24), end: t(26)), trackID: "Angle 2"), to: c) {
            assertSafe(c, scopes, "locked angle")
            try roundTrip(c, scopes: scopes, label: "locked angle")
        }
    }

    func testBladeUnderALockedCopyCannotUnlinkItsLaterPiece() throws {
        let (c, _, _, scopes) = try screen()
        let privacy = c.project.track(named: "Privacy (Screen)")!
        try c.run("Lock", .updateTrack(trackID: privacy.id, patch: .object(["locked": .bool(true)])))
        if try PrivacyAuditCoverage.applyOrRefuse(.blade(at: t(12)), to: c) {
            try c.run("Unlock", .updateTrack(trackID: privacy.id, patch: .object(["locked": .bool(false)])))
            let right = c.clips("Screen").first { $0.start == t(12) }!
            try c.run("Move later piece", .moveClips(clipIDs: [right.id], delta: t(55)))
            assertSafe(c, scopes, "blade then move")
            try roundTrip(c, scopes: scopes, label: "blade then move")
        }
    }

    func testDirectTemporalPatchesPreservePreviouslyProtectedFrames() throws {
        for patch in [JSONValue.object(["start": .number(12)]), .object(["sourceStart": .number(9.5)])] {
            let (c, picture, _, scopes) = try screen()
            let other = c.clips("Screen").filter { $0.id != picture }.map(\.id)
            try c.run("Make legal space", .removeClips(clipIDs: other, includeLinked: false))
            if try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: picture, patch: patch), to: c) {
                assertSafe(c, scopes, "direct time patch \(patch)")
                try roundTrip(c, scopes: scopes, label: "direct time patch")
            }
        }
    }

    func testDirectEnableMustNotLeaveThePrivacyCopyDisabled() throws {
        let (c, picture, mask, scopes) = try screen()
        try c.run("Both off", .updateClip(clipID: picture, patch: .object(["enabled": .bool(false)])), .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
        if try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: picture, patch: .object(["enabled": .bool(true)])), to: c) {
            assertSafe(c, scopes, "direct enable")
            try roundTrip(c, scopes: scopes, label: "direct enable")
        }
    }

    func testIsolatedUnfrozenRawPatchControlsAndOverlapGuards() throws {
        let patches: [(String, JSONValue)] = [
            ("start", .object(["start": .number(12)])),
            ("duration", .object(["duration": .number(10)])),
            ("sourceStart", .object(["sourceStart": .number(9.5)])),
            ("speed", .object(["speed": .number(2)])),
            ("freezeFrame", .object(["freezeFrame": .bool(true), "sourceStart": .number(12)]))
        ]
        for (field, patch) in patches {
            let (c, picture, mask, scopes) = try screen()
            if field == "start" || field == "duration" {
                let before = c.project
                XCTAssertThrowsError(try c.run("Overlaps next picture", .updateClip(clipID: picture, patch: patch)))
                XCTAssertEqual(c.project, before)
            }
            try c.run("Remove neighbours for a legal isolated patch", .removeClips(clipIDs: c.clips("Screen").filter { $0.id != picture }.map(\.id), includeLinked: false))
            let oldMask = c.project.clip(mask)!
            try c.run("Raw \(field)", .updateClip(clipID: picture, patch: patch))
            XCTAssertEqual(c.project.clip(mask)!, oldMask, "observed independent raw-patch behavior")
            print("PANEL raw field \(field): mask unchanged; originally protected source gaps \(PrivacyAuditCoverage.failures(c.project, protecting: scopes))")
        }
    }
}
