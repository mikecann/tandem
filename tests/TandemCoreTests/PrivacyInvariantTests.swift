import XCTest
@testable import TandemCore

final class PrivacyInvariantTests: XCTestCase {
    func testASymlinkAliasKeepsItsIdentityThroughRelinkingAndJournalRecovery() throws {
        try assertFileAliasKeepsItsIdentity(hardLink: false)
    }

    func testAHardLinkAliasKeepsItsIdentityThroughRelinkingAndJournalRecovery() throws {
        try assertFileAliasKeepsItsIdentity(hardLink: true)
    }

    private func assertFileAliasKeepsItsIdentity(hardLink: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.mov")
        try Data("synthetic source identity".utf8).write(to: file)
        try FileManager.default.copyItem(at: file, to: root.appendingPathComponent("replacement.mov"))
        if hardLink { try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("alias.mov")) }
        else { try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.mov"), withDestinationURL: file) }
        let a = MediaItem(id: "med_original", path: "original.mov", kind: .video, role: .screen, duration: t(5), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let picture = Clip(id: "clip_original", content: .media(mediaID: a.id), start: .zero, duration: t(1), sourceStart: t(1))
        let original = Project(name: "Symlink identity", media: [a], videoTracks: [Track(id: "trk_original", kind: .video, name: "Screen", clips: [picture])])
        let journal = ProjectJournal(url: root.appendingPathComponent("journal.jsonl"))
        let c = ProjectCoordinator(project: original, journal: journal, sourceFolder: root)
        try c.run("Hide original", .redact(range: picture.range, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: a.id))
        var alias = a
        alias.id = "med_alias"
        alias.path = "alias.mov"
        try c.run("Add symlink reference", .addMedia(item: alias))
        try c.run("Relink discovered alias", .updateMedia(mediaID: alias.id, patch: .object(["path": .string("replacement.mov")])))
        let recovered = try XCTUnwrap(journal.recover(project: original, revision: 0, sourceFolder: root))
        XCTAssertEqual(recovered.project, c.project)
        let saved = root.appendingPathComponent("Safe.tandem")
        try ProjectFile.save(recovered.project, revision: recovered.revision, to: saved)
        let loaded = try ProjectFile.load(from: saved).project
        XCTAssertEqual(loaded, c.project)
        let next = ProjectCoordinator(project: loaded, sourceFolder: root)
        let fresh = Clip(id: "clip_relinked", content: .media(mediaID: alias.id), start: t(2), duration: t(1), sourceStart: t(1))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: fresh), to: next))
    }

    func testAnIntermediateRepointedFileRetainsItsAliasesAfterAnotherRepoint() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        try c.run("Cut away all copies", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(15))))
        try c.run("First replacement", .updateMedia(mediaID: "med_screen", patch: .object(["path": .string("middle.mov")])))
        var alias = c.project.media("med_screen")!
        alias.id = "med_middle"
        alias.fingerprint = "middle-file-fingerprint"
        try c.run("Alias of replacement", .addMedia(item: alias))
        try c.run("Second replacement", .updateMedia(mediaID: "med_screen", patch: .object(["path": .string("last.mov")])))
        let fresh = Clip(id: "clip_middle", content: .media(mediaID: alias.id), start: t(70), duration: t(1), sourceStart: t(11))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: fresh), to: c))
    }

    func testTemplatesCannotIntroduceManagedPrivacyOwnership() throws {
        let (c, _, mask, _) = try PrivacyPanelTests().screen()
        let forged = c.project.clip(mask)!
        try c.run("Cut away original", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(15))))
        let template = Template(id: "forged", name: "Forged ownership", duration: forged.duration, clips: [TemplateClip(track: "Privacy (Imported)", clip: forged)])
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertTemplate(template: template, at: t(20)), to: c))
    }

    func testStrengtheningAPrivacyEffectAfterZoomRetainsItsSourceCalibration() throws {
        let (c, picture, mask, _) = try PrivacyPanelTests().screen()
        let before = RedactionSafety.protections(in: c.project).map(\.sourcePixelsPerUnit).max()!
        try c.run("Zoom", .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["scale": .number(8)])]) ])))
        let effect = c.project.clip(mask)!.video!.effects.last!
        let parameter = effect.type == "blur" ? "radius" : "scale"
        try c.run("Stronger privacy", .updateEffect(clipID: mask, effectID: effect.id, patch: .object(["params": .object([parameter: .number(40)])])))
        XCTAssertGreaterThanOrEqual(RedactionSafety.protections(in: c.project).map(\.sourcePixelsPerUnit).max()!, before)
    }

    func testCoalescingAliasesMustRetainEachOwnersDurableProtection() throws {
        let a = MediaItem(id: "med_a", path: "same.mov", kind: .video, role: .screen, duration: t(10), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        var b = a
        b.id = "med_b"
        let first = Clip(id: "clip_a", content: .media(mediaID: a.id), start: .zero, duration: t(1))
        let second = Clip(id: "clip_b", content: .media(mediaID: b.id), start: t(3), duration: t(1), sourceStart: t(2))
        let c = ProjectCoordinator(project: Project(name: "Aliases", media: [a, b], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [first, second])]))
        let region = Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)
        try c.run("Hide both", .redact(range: first.range, rect: region, mediaID: a.id), .redact(range: second.range, rect: region, mediaID: b.id))
        try c.run("Remove second occurrence", .rippleDeleteRange(range: second.range))
        try c.run("Repoint second owner", .updateMedia(mediaID: b.id, patch: .object(["path": .string("copy.mov"), "fingerprint": .null])))
        let saved = try ProjectFile.encoder().encode(c.project)
        let reloaded = ProjectCoordinator(project: try ProjectFile.migrate(JSONDecoder().decode(Project.self, from: saved)))
        let fresh = Clip(id: "clip_reused_b", content: .media(mediaID: b.id), start: t(5), duration: t(1), sourceStart: t(2))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: fresh), to: reloaded))
    }

    func testOrdinaryFractionalPlaybackProtectsItsDecodedHeadFrame() throws {
        let item = MediaItem(id: "med_fraction", path: "fraction.mov", kind: .video, role: .screen, duration: t(5), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let picture = Clip(id: "clip_fraction", content: .media(mediaID: item.id), start: .zero, duration: t(1), sourceStart: t(1.01))
        let c = ProjectCoordinator(project: Project(name: "Fractional playback", media: [item], videoTracks: [Track(id: "trk_fraction", kind: .video, name: "Screen", clips: [picture])]))
        try c.run("Hide displayed samples", .redact(range: picture.range, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: item.id))
        for (index, source) in [1.0, 2.02].enumerated() {
            let reused = Clip(id: "clip_decoded_\(index)", content: .media(mediaID: item.id), start: t(2 + Double(index)), duration: t(1), sourceStart: t(source), freezeFrame: true)
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: reused), to: c))
        }
    }

    func testVariableRatePrivacyCannotBeDowngradedToANominalSampleGrid() throws {
        let item = MediaItem(id: "med_vfr", path: "vfr.mov", kind: .video, role: .screen, duration: t(5), frameRate: .fps30, width: 1280, height: 720, hasVideo: true, variableFrameRate: true)
        let picture = Clip(id: "clip_vfr", content: .media(mediaID: item.id), start: .zero, duration: t(1), sourceStart: t(1.08), freezeFrame: true)
        let c = ProjectCoordinator(project: Project(name: "Variable timing", media: [item], videoTracks: [Track(id: "trk_vfr", kind: .video, name: "Screen", clips: [picture])]))
        try c.run("Hide variable-rate picture", .redact(range: picture.range, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: item.id))
        XCTAssertTrue(RedactionSafety.protections(in: c.project).allSatisfy { $0.sourceVariableFrameRate == true })
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateMedia(mediaID: item.id, patch: .object(["variableFrameRate": .bool(false)])), to: c))
    }

    func testLegacyVariableRateProtectionCannotAssumeANominalSampleGrid() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        var legacy = c.project
        legacy.schemaVersion = 2
        legacy.sourceRedactions = nil
        legacy.media[legacy.media.firstIndex { $0.id == "med_screen" }!].variableFrameRate = true
        for ti in legacy.videoTracks.indices where legacy.videoTracks[ti].isPrivacy {
            for ci in legacy.videoTracks[ti].clips.indices { legacy.videoTracks[ti].clips[ci].video?.redactionSources = nil; legacy.videoTracks[ti].clips[ci].video?.redactionOriginID = nil; legacy.videoTracks[ti].clips[ci].video?.redactionVisibility = nil; legacy.videoTracks[ti].clips[ci].video?.redactionEffectID = nil }
        }
        let migrated = try ProjectFile.migrate(legacy)
        let scopes = RedactionSafety.protections(in: migrated)
        XCTAssertTrue(scopes.allSatisfy { $0.sourceVariableFrameRate == true })
        let next = ProjectCoordinator(project: migrated)
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateMedia(mediaID: "med_screen", patch: .object(["variableFrameRate": .bool(false)])), to: next))
    }

    func testRoundedHoldBoundariesMustHaveCoverageForTheWholeOutputFrame() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        let following = c.clips("Screen").first { $0.start == t(15) }!
        let before = c.project
        do {
            try c.run("Hold and mask too short", .holdFrame(clipID: following.id, range: TimeRange(start: t(15), end: t(15.5005))), .redact(range: TimeRange(start: t(15), end: t(15.5)), rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen", style: .blur))
            XCTFail("the rounded hold reaches beyond this mask")
        } catch {
            XCTAssertTrue(String(describing: error).lowercased().contains("privacy") || String(describing: error).lowercased().contains("protected"))
            XCTAssertEqual(c.project, before)
        }
    }

    func testDisablingAShortenedCopyDoesNotRelinquishCutAwaySourceFrames() throws {
        for operation in ["cut", "trim"] {
            let (c, picture, mask, _) = try PrivacyPanelTests().screen()
            if operation == "cut" { try c.run("Cut tail", .rippleDeleteRange(range: TimeRange(start: t(13), end: t(15)))) }
            else { try c.run("Trim tail", .trim(clipID: picture, edge: .end, to: t(13))) }
            try c.run("Disable remaining patch", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
            let fresh = Clip(id: "clip_cut_away", content: .media(mediaID: "med_screen"), start: t(70), duration: t(1), sourceStart: t(14))
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: fresh), to: c))
        }
    }

    func testLockedPrivacyControlsAndLinksRequireUnlocking() throws {
        let (c, _, mask, _) = try PrivacyPanelTests().screen()
        let track = c.project.track(named: "Privacy (Screen)")!
        try c.run("Lock", .updateTrack(trackID: track.id, patch: .object(["locked": .bool(true)])))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateTrack(trackID: track.id, patch: .object(["hidden": .bool(true)])), to: c))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.unlink(clipIDs: [mask]), to: c))
    }

    func testFractionalFreezesCannotShowTheSameProtectedDecodedFrameElsewhere() throws {
        let item = MediaItem(id: "med_fraction", path: "fraction.mov", kind: .video, role: .screen, duration: t(5), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let picture = Clip(id: "clip_fraction", content: .media(mediaID: item.id), start: .zero, duration: t(1), sourceStart: t(1.01), freezeFrame: true)
        let c = ProjectCoordinator(project: Project(name: "Fractional freeze", media: [item], videoTracks: [Track(id: "trk_fraction", kind: .video, name: "Screen", clips: [picture])]))
        try c.run("Hide decoded frame", .redact(range: picture.range, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: item.id))
        for source in [1.0, 0.9998] {
            let occurrence = Clip(id: "clip_same_frame", content: .media(mediaID: item.id), start: t(2), duration: t(1), sourceStart: t(source), freezeFrame: true)
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: occurrence), to: c))
        }
    }

    func testBoundaryMetadataCannotInvalidateProtection() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        let patches: [JSONValue] = [.object(["duration": .number(200)]), .object(["frameRate": .object(["numerator": .number(60), "denominator": .number(1)])]), .object(["width": .number(100_000)])]
        for patch in patches {
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateMedia(mediaID: "med_screen", patch: patch), to: c))
        }
    }

    func testAnOrdinarySourceCannotBePromotedByAPrivacyTrackName() throws {
        let (c, picture, _, scopes) = try PrivacyPanelTests().screen()
        try c.run("Weak source look", .addEffect(clipID: picture, effect: Effect(type: "blur", params: ["radius": .number(0.001)])))
        try c.run("Rename source", .updateTrack(trackID: c.project.track(named: "Screen")!.id, patch: .object(["name": .string("Privacy (Original)")])))
        XCTAssertNil(c.project.clip(picture)!.video?.redaction)
        if try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["scale": .number(1.5)])])])), to: c) {
            XCTAssertTrue(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
        }
    }

    func testRenamingAPictureDoesNotReenableItsIntentionallyDisabledCopy() throws {
        let (c, picture, mask, _) = try PrivacyPanelTests().screen()
        try c.run("Disable patch", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
        try c.run("Lock privacy", .updateTrack(trackID: c.project.track(named: "Privacy (Screen)")!.id, patch: .object(["locked": .bool(true)])))
        try c.run("Rename picture", .updateClip(clipID: picture, patch: .object(["name": .string("Intro")])))
        XCTAssertFalse(c.project.clip(mask)!.enabled)
        XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testARippleCannotForgetIntentWhenItRemovesEveryCurrentProtectedPiece() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        try c.run("Remove protected time", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(15))))
        XCTAssertTrue(c.project.videoTracks.filter(\.isPrivacy).flatMap(\.clips).isEmpty)
        XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateMedia(mediaID: "med_screen", patch: .object(["pictureDelay": .number(1)])), to: c))
        let fresh = Clip(id: "clip_reintroduced", content: .media(mediaID: "med_screen"), start: t(70), duration: t(2), sourceStart: t(11))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: fresh), to: c))
        try c.run("Reinsert safely as one batch", .insertClip(trackID: "Screen", clip: fresh), .redact(range: fresh.range, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen", style: .blur))
        XCTAssertNotNil(c.project.clip(fresh.id))
    }

    func testSwappingAFileDoesNotLoseProtectionForItsOriginalPath() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        var alias = c.project.media("med_screen")!
        alias.id = "med_original_alias"
        try c.run("Another reference", .addMedia(item: alias))
        try c.run("Replace original item", .updateMedia(mediaID: "med_screen", patch: .object(["path": .string("replacement.mov"), "fingerprint": .null])))
        let fresh = Clip(id: "clip_original_alias", content: .media(mediaID: alias.id), start: t(70), duration: t(2), sourceStart: t(11))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: fresh), to: c))
    }

    func testLaterZoomCannotWeakenTheSourcePixelBlur() throws {
        let (c, picture, _, _) = try PrivacyPanelTests().screen()
        let before = RedactionSafety.protections(in: c.project).map(\.sourcePixelsPerUnit).max()!
        try c.run("Zoom", .zoomToRegion(clipID: picture, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)))
        XCTAssertGreaterThanOrEqual(RedactionSafety.protections(in: c.project).map(\.sourcePixelsPerUnit).max()!, before)
    }

    func testAnExplicitPartialUnredactionOnlyRelinquishesThatPiecesSource() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        try c.run("Blade", .blade(at: t(12)))
        let right = c.clips("Privacy (Screen)").first { $0.start == t(12) }!
        try c.run("Disable right patch", .updateClip(clipID: right.id, patch: .object(["enabled": .bool(false)])))
        let scopes = RedactionSafety.protections(in: c.project)
        XCTAssertTrue(scopes.contains { $0.sources.contains { $0.contains(t(11)) } })
        XCTAssertFalse(scopes.contains { $0.sources.contains { $0.contains(t(14)) } })
        try c.run("Unrelated edit", .updateProject(patch: .object(["name": .string("Partial privacy")])))
    }

    func testAnAliasOfAProtectedFileCannotBypassCoverage() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        var alias = c.project.media("med_screen")!
        alias.id = "med_alias"
        try c.run("Alias", .addMedia(item: alias))
        let fresh = Clip(id: "clip_alias", content: .media(mediaID: alias.id), start: t(70), duration: t(2), sourceStart: t(11))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: fresh), to: c))
    }

    func testADirectEditingRefusalIsAtomicIncludingLegacyPrivacyMetadata() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        var p = c.project
        p.sourceRedactions = nil
        for ti in p.videoTracks.indices where p.videoTracks[ti].isPrivacy {
            for ci in p.videoTracks[ti].clips.indices { p.videoTracks[ti].clips[ci].video?.redactionSources = nil; p.videoTracks[ti].clips[ci].video?.redactionOriginID = nil; p.videoTracks[ti].clips[ci].video?.redactionVisibility = nil; p.videoTracks[ti].clips[ci].video?.redactionEffectID = nil }
        }
        let before = p
        var context = EditContext()
        XCTAssertThrowsError(try Editing.apply(.updateClip(clipID: "missing", patch: .object([:])), to: &p, context: &context))
        XCTAssertEqual(p, before)
        XCTAssertTrue(context.createdIDs.isEmpty)
    }

    func testUnusedZeroRadiusKeyframesDoNotEraseProtection() throws {
        let (c, picture, mask, scopes) = try PrivacyPanelTests().screen()
        let effect = c.project.clip(mask)!.video!.effects.last!
        try c.run("Animate blur", .setKeyframes(clipID: mask, parameter: "video.effects.\(effect.id).radius", keyframes: [
            Keyframe(time: t(-1), value: .number(0)), Keyframe(time: .zero, value: .number(24))
        ]))
        try c.run("Move picture", .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["scale": .number(1.4)])])])))
        XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
        XCTAssertTrue(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
    }

    func testAPrivacyTrackRenameRetainsItsIdentityAndFollowing() throws {
        let (c, picture, _, scopes) = try PrivacyPanelTests().screen()
        try c.run("Rename", .updateTrack(trackID: c.project.track(named: "Privacy (Screen)")!.id, patch: .object(["name": .string("Sensitive information")])))
        try c.run("Move picture", .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["scale": .number(1.4)])])])))
        XCTAssertTrue(c.project.track(named: "Sensitive information")!.isPrivacy)
        XCTAssertTrue(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
    }

    func testDisablingACopyStillAllowsUnrelatedEdits() throws {
        let (c, _, mask, _) = try PrivacyPanelTests().screen()
        try c.run("Disable copy", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
        XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
        try c.run("Rename project", .updateProject(patch: .object(["name": .string("Still editable")])))
        XCTAssertEqual(c.project.name, "Still editable")
    }

    func testPictureDelayCannotChangeProtectedFrameIdentity() throws {
        let (c, picture, _, _) = try PrivacyPanelTests().screen()
        let before = c.project
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateMedia(mediaID: "med_screen", patch: .object(["pictureDelay": .number(1)])), to: c))
        XCTAssertEqual(c.project, before)
        try c.run("Unlink still retains source protection", .unlink(clipIDs: [picture]))
        XCTAssertEqual(RedactionSafety.protections(in: c.project), RedactionSafety.protections(in: before))
    }

    func testHoldingBeforeTheFileCannotRevealItsProtectedFirstFrame() throws {
        let item = MediaItem(id: "med_edge", path: "edge.mov", kind: .video, role: .screen, duration: t(5), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let picture = Clip(id: "clip_edge", content: .media(mediaID: item.id), start: .zero, duration: t(1), freezeFrame: true, video: VideoProperties())
        let c = ProjectCoordinator(project: Project(name: "Edge frames", media: [item], videoTracks: [Track(id: "trk_edge", kind: .video, name: "Screen", clips: [picture])]))
        try c.run("Hide first frame", .redact(range: picture.range, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: item.id))
        try c.run("Another occurrence", .insertClip(trackID: "trk_edge", clip: Clip(id: "clip_neighbour", content: .media(mediaID: item.id), start: t(2), duration: t(1), sourceStart: t(3), freezeFrame: true)))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: "clip_neighbour", patch: .object(["sourceStart": .number(-1), "holdEdges": .bool(true)])), to: c))
    }

    func testAnUnlinkedMoveCannotLeaveTheBlurBehind() throws {
        let (c, picture, _, scopes) = try PrivacyPanelTests().screen()
        if try PrivacyAuditCoverage.applyOrRefuse(.moveClips(clipIDs: [picture], delta: t(55), includeLinked: false), to: c) {
            XCTAssertTrue(PrivacyAuditCoverage.failures(c.project, protecting: scopes).isEmpty)
        }
    }

    func testProtectionRemembersSourceFramesAfterASlipAndReload() throws {
        let (c, picture, _, scopes) = try PrivacyPanelTests().screen()
        try c.run("Slip protected piece", .slip(clipID: picture, delta: t(1)))
        let data = try ProjectFile.encoder().encode(c.project)
        let loaded = try ProjectFile.migrate(JSONDecoder().decode(Project.self, from: data))
        XCTAssertTrue(RedactionSafety.protections(in: loaded).contains { $0.sources.contains { $0.contains(t(11)) } })
        let next = ProjectCoordinator(project: loaded)
        let left = next.clips("Screen").first { $0.end == t(10) }!
        if try PrivacyAuditCoverage.applyOrRefuse(.slip(clipID: left.id, delta: t(1)), to: next) {
            XCTAssertTrue(PrivacyAuditCoverage.failures(next.project, protecting: scopes).isEmpty)
        }
        try next.run("Remove current occurrences", .rippleDeleteRange(range: TimeRange(start: .zero, end: next.project.duration)))
        let reused = Clip(id: "clip_original_source_again", content: .media(mediaID: "med_screen"), start: .zero, duration: t(1), sourceStart: t(11))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: reused), to: next))
    }
}
