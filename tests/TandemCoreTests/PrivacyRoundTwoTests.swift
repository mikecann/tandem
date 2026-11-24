import XCTest
@testable import TandemCore

private func roundTwoFixture(hold: Bool = false, freeze: Bool = false) throws -> (ProjectCoordinator, String, String) {
    let item = MediaItem(id: "med_round2", path: "dummy.mov", kind: .video, role: .screen, duration: t(30), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
    let picture = Clip(id: "clip_round2", content: .media(mediaID: item.id), start: .zero, duration: t(3), sourceStart: t(1), freezeFrame: freeze, video: VideoProperties())
    let c = ProjectCoordinator(project: Project(name: "Round two synthetic", settings: ProjectSettings(width: 1280, height: 720, frameRate: .fps30), media: [item], videoTracks: [Track(id: "trk_round2", kind: .video, name: "Screen", clips: [picture], rippleMode: .cut)], audioTracks: []))
    if hold { try c.run("Hold whole clip", .holdFrame(clipID: picture.id, range: picture.range)) }
    try c.run("Hide", .redact(range: picture.range, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: item.id, style: .blur))
    return (c, picture.id, c.project.videoTracks.first { $0.isPrivacy }!.clips[0].id)
}

/// These must pass after fixing the audit helper, without changing the app.
final class PrivacyOracleRegressionTests: XCTestCase {
    func testPictureOnlyHoldAfterRedactionContributesItsDisplayedFrame() throws {
        let (c, picture, mask) = try roundTwoFixture()
        try corruptForOracle(c, .holdFrame(clipID: picture, range: TimeRange(start: .zero, end: t(3))))
        XCTAssertTrue(c.project.clip(mask)!.holds.isEmpty, "the copy still plays normally")
        let held = c.project.clip(picture)!.pictureTime(atTimelineTime: t(1))
        XCTAssertEqual(held.seconds, 29.0/30, accuracy: 1e-8)
        let scopes = PrivacyAuditCoverage.capture(c.project)
        XCTAssertTrue(scopes.contains { $0.source.contains(held) }, "capture must resolve the linked picture, not only the copy")
        XCTAssertTrue(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
        try corruptForOracle(c, .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.8)])])])])))
        XCTAssertFalse(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
    }

    func testIntentCapturedBeforePictureOnlyHoldStillChecksItsNominalProtectedSpan() throws {
        let (c, picture, _) = try roundTwoFixture()
        let scopes = PrivacyAuditCoverage.capture(c.project)
        try corruptForOracle(c, .holdFrame(clipID: picture, range: TimeRange(start: .zero, end: t(3))))
        XCTAssertTrue(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
        try corruptForOracle(c, .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.8)])])])])))
        XCTAssertFalse(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty, "a new hold must not bypass an already captured protected nominal span")
    }

    func testUnrelatedSameMediaHoldsDoNotExpandTheCopiesIntent() throws {
        let (c, _, _) = try roundTwoFixture()
        try c.run("Unrelated view", .addTrack(kind: .video, name: "Another view", id: "trk_unrelated"), .insertClip(trackID: "trk_unrelated", clip: Clip(id: "clip_unrelated", content: .media(mediaID: "med_round2"), start: .zero, duration: t(3), sourceStart: t(10), linkGroup: "lnk_unrelated", video: VideoProperties())))
        try c.run("Hold unrelated view", .holdFrame(clipID: "clip_unrelated", range: TimeRange(start: .zero, end: t(3))))
        let unrelated = c.project.clip("clip_unrelated")!.pictureTime(atTimelineTime: t(1))
        XCTAssertFalse(PrivacyAuditCoverage.capture(c.project).contains { $0.source.contains(unrelated) })
    }

    func testHeldFrameBeforeNominalSourceStartIsCapturedAndChecked() throws {
        let (c, picture, _) = try roundTwoFixture(hold: true)
        let held = c.project.clip(picture)!.pictureTime(atTimelineTime: t(1))
        XCTAssertEqual(held.seconds, 29.0/30, accuracy: 1e-8)
        let scopes = PrivacyAuditCoverage.capture(c.project)
        XCTAssertTrue(scopes.contains { $0.source.contains(held) }, "intent must include the held picture actually displayed")
        XCTAssertTrue(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
        try corruptForOracle(c, .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.8)])])])])))
        XCTAssertFalse(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty, "a held source cannot disappear from coverage checks")
    }

    func testZeroBlurOnThePictureCannotHideATrackTransferFromTheOracle() throws {
        let helper = PrivacyPanelTests()
        let (c, picture, _, scopes) = try helper.screen()
        try c.run("No-op picture blur", .addEffect(clipID: picture, effect: Effect(id: "fx_zero_picture", type: "blur", params: ["radius": .number(0)])))
        XCTAssertTrue(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
        let destination = c.project.track(named: "B-roll")!
        try c.run("Show destination", .updateTrack(trackID: destination.id, patch: .object(["hidden": .bool(false)])))
        try corruptForOracle(c, .moveClips(clipIDs: [picture], delta: .zero, toTrackID: destination.id))
        XCTAssertFalse(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
    }

    func testZeroBlurCannotServeAsAnEffectivePrivacyMask() throws {
        let (c, _, mask) = try roundTwoFixture()
        let scopes = PrivacyAuditCoverage.capture(c.project)
        let effect = c.project.clip(mask)!.video!.effects.last!
        try c.run("No-op mask", .updateEffect(clipID: mask, effectID: effect.id, patch: .object(["params": .object(["radius": .number(0)])])))
        XCTAssertFalse(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
    }

    func testAnyPositiveSourceOpacityStillRequiresCoverage() throws {
        let (c, picture, _, scopes) = try PrivacyPanelTests().screen()
        let destination = c.project.track(named: "B-roll")!
        try c.run("Show destination", .updateTrack(trackID: destination.id, patch: .object(["hidden": .bool(false)])))
        try corruptForOracle(c, .moveClips(clipIDs: [picture], delta: .zero, toTrackID: destination.id), .updateClip(clipID: picture, patch: .object(["video": .object(["opacity": .number(0.01)])])))
        XCTAssertFalse(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty, "geometry checks must not certify a visible source by a brightness threshold")
    }

    func testInvisibleStoredHoldsDoNotInventAdditionalPrivacyIntent() throws {
        let (c, _, mask) = try roundTwoFixture()
        let unused = HeldFrame(source: TimeRange(start: t(10), end: t(11)), frame: t(9))
        try c.run("Out-of-view hold metadata", .updateClip(clipID: mask, patch: .object(["holds": try JSONValue.from([unused])])))
        XCTAssertFalse(PrivacyAuditCoverage.capture(c.project).contains { $0.source.contains(t(9)) })
    }
}

extension PrivacyPanelTests {
    func testRoundTwoContinuousRollThenMoveKeepsProtectedNeighboursCovered() throws {
        for edge in ["head", "tail"] {
            let (c, picture, _, scopes) = try screen()
            let neighbour = c.clips("Screen").first { edge == "head" ? $0.end == t(10) : $0.start == t(15) }!
            try c.run("Continuous roll", .roll(leftClipID: edge == "head" ? neighbour.id : picture, rightClipID: edge == "head" ? picture : neighbour.id, delta: t(edge == "head" ? 0.2 : -0.2)))
            assertSafe(c, scopes, "immediately after roll")
            if try PrivacyAuditCoverage.applyOrRefuse(.moveClips(clipIDs: [picture], delta: t(55)), to: c) {
                assertSafe(c, scopes, "round2 roll \(edge) then move")
                try roundTrip(c, scopes: scopes, label: "round2 roll \(edge) then move")
            }
        }
    }

    func testRoundTwoRollThenSpeedPreservesCoverageDespiteDivergentBounds() throws {
        for (delta, speed) in [(0.2, 2.0), (-0.2, 0.5)] {
            let (c, picture, mask, scopes) = try screen()
            let left = c.clips("Screen").first { $0.end == t(10) }!
            try c.run("Roll", .roll(leftClipID: left.id, rightClipID: picture, delta: t(delta)))
            assertSafe(c, scopes, "before follow-up speed")
            XCTAssertNotEqual(c.project.clip(picture)!.range, c.project.clip(mask)!.range)
            if try PrivacyAuditCoverage.applyOrRefuse(.setSpeed(clipID: picture, speed: speed, ripple: true), to: c) {
                assertSafe(c, scopes, "round2 roll \(delta) then speed \(speed)")
                try roundTrip(c, scopes: scopes, label: "round2 roll then speed")
            }
        }
    }

    func testRoundTwoAdjacentSlideThenSpeedKeepsPrivacyInStep() throws {
        let (c, picture, mask, scopes) = try screen()
        try c.run("Blade preceding clip", .blade(at: t(5)))
        let preceding = c.clips("Screen").first { $0.end == t(10) }!
        try c.run("Adjacent slide", .slide(clipID: preceding.id, delta: t(0.2)))
        assertSafe(c, scopes, "immediately after adjacent slide")
        XCTAssertNotEqual(c.project.clip(picture)!.range, c.project.clip(mask)!.range)
        if try PrivacyAuditCoverage.applyOrRefuse(.setSpeed(clipID: picture, speed: 2, ripple: true), to: c) {
            assertSafe(c, scopes, "round2 adjacent slide then speed")
            try roundTrip(c, scopes: scopes, label: "round2 adjacent slide then speed")
        }
    }

    func testRoundTwoAdjacentRippleTrimsPreserveProtectedSource() throws {
        for edge in ["left tail", "right head"] {
            let (c, _, _, scopes) = try screen()
            let neighbour = c.clips("Screen").first { edge == "left tail" ? $0.end == t(10) : $0.start == t(15) }!
            let command = EditCommand.trim(clipID: neighbour.id, edge: edge == "left tail" ? .end : .start, to: t(edge == "left tail" ? 10.5 : 14.5), ripple: true)
            if try PrivacyAuditCoverage.applyOrRefuse(command, to: c) {
                assertSafe(c, scopes, "round2 trim \(edge)")
                try roundTrip(c, scopes: scopes, label: "round2 trim \(edge)")
            }
        }
    }

    func testRoundTwoAdjacentSlipsPreserveProtectedSource() throws {
        for side in ["left", "right"] {
            let (c, _, _, scopes) = try screen()
            let neighbour = c.clips("Screen").first { side == "left" ? $0.end == t(10) : $0.start == t(15) }!
            if try PrivacyAuditCoverage.applyOrRefuse(.slip(clipID: neighbour.id, delta: t(side == "left" ? 1 : -1)), to: c) {
                assertSafe(c, scopes, "round2 slip \(side)")
                try roundTrip(c, scopes: scopes, label: "round2 slip \(side)")
            }
        }
    }

    func testRoundTwoFrozenDurationExtensionKeepsTheProtectedFrameCovered() throws {
        let (c, picture, _) = try roundTwoFixture(freeze: true)
        let scopes = PrivacyAuditCoverage.capture(c.project)
        if try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: picture, patch: .object(["duration": .number(4)])), to: c) {
            assertSafe(c, scopes, "round2 frozen duration")
            try roundTrip(c, scopes: scopes, label: "round2 frozen duration")
        }
    }

    func testRoundTwoRawSpeedAndSourceStartOnNeighbourProtectOriginalSource() throws {
        for field in ["speed", "sourceStart"] {
            let (c, _, _, scopes) = try screen()
            let left = c.clips("Screen").first { $0.end == t(10) }!
            let patch: JSONValue = .object([field: .number(field == "speed" ? 2 : 10.5)])
            if try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: left.id, patch: patch), to: c) {
                assertSafe(c, scopes, "round2 neighbour raw \(field)")
                try roundTrip(c, scopes: scopes, label: "round2 neighbour raw \(field)")
            }
        }
    }

    func testRoundTwoUnfreezingANeighbourProtectsTheSourceItReveals() throws {
        let (c, _, _, scopes) = try screen()
        let left = c.clips("Screen").first { $0.end == t(10) }!
        try c.run("Freeze neighbour before protected source", .updateClip(clipID: left.id, patch: .object(["freezeFrame": .bool(true), "sourceStart": .number(10)])))
        assertSafe(c, scopes, "before unfreezing")
        if try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: left.id, patch: .object(["freezeFrame": .bool(false)])), to: c) {
            assertSafe(c, scopes, "round2 unfreeze neighbour")
            try roundTrip(c, scopes: scopes, label: "round2 unfreeze neighbour")
        }
    }

    func testRoundTwoHoldOnFollowingClipDoesNotExtendPrivateSourcePastMask() throws {
        let (c, _, _, scopes) = try screen()
        let right = c.clips("Screen").first { $0.start == t(15) }!
        if try PrivacyAuditCoverage.applyOrRefuse(.holdFrame(clipID: right.id, range: TimeRange(start: t(15), end: t(15.5))), to: c) {
            assertSafe(c, scopes, "round2 hold following clip")
            try roundTrip(c, scopes: scopes, label: "round2 hold following clip")
        }
    }
}

/// Oracle controls must still see bad states after the app refuses to create
/// them. Construct the historical corruption directly, not through Editing.apply.
private func corruptForOracle(_ c: ProjectCoordinator, _ commands: EditCommand...) throws {
    var p = c.project
    var context = EditContext()
    for command in commands {
        switch command {
        case .holdFrame(let id, let range):
            try Editing.holdFrame(&p, clipID: id, range: range, &context)
        case .updateClip(let id, let patch):
            let at = p.location(ofClip: id)!
            p[at.track].clips[at.index] = try JSONValue.applyMergePatch(patch, to: p[at.track].clips[at.index])
        case .moveClips(let ids, let delta, let destination, _, _):
            for id in ids {
                let at = p.location(ofClip: id)!
                var clip = p[at.track].clips.remove(at: at.index)
                clip.start += delta ?? .zero
                p[p.location(ofTrack: destination!)!].add(clip)
            }
        default: XCTFail("unsupported oracle corruption")
        }
    }
    c.reload(p)
}
