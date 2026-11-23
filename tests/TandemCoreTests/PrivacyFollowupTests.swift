import XCTest
@testable import TandemCore

final class PrivacyFollowupTests: XCTestCase {
    func ready(variableRate: Bool = false) throws -> (ProjectCoordinator, String, String) {
        let item = MediaItem(id: "med_screen", path: "screen.mov", kind: .video, role: .screen, duration: t(20), frameRate: .fps30, width: 1280, height: 720, hasVideo: true, variableFrameRate: variableRate)
        let picture = Clip(id: "clip_screen", content: .media(mediaID: item.id), start: .zero, duration: t(5), video: VideoProperties())
        let c = ProjectCoordinator(project: Project(name: "Panel controls", settings: ProjectSettings(width: 1280, height: 720, alternateFormats: [.portrait]), media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [picture])]))
        try c.run("Hide", .redact(range: picture.range, rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: item.id, style: .blur, size: 48))
        return (c, picture.id, c.project.videoTracks.first(where: \.isPrivacy)!.clips[0].id)
    }

    func testShorteningAnAnimatedCopyCannotRelinquishItsProtectedTail() throws {
        let (c, _, mask) = try ready()
        let effect = c.project.clip(mask)!.video!.redactionEffectID!
        try c.run("Animate blur", .setKeyframes(clipID: mask, parameter: "video.effects.\(effect).radius", keyframes: [Keyframe(time: .zero, value: .number(48)), Keyframe(time: t(5), value: .number(24))]))
        let before = c.project
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: mask, patch: .object(["duration": .number(2)])), to: c))
        XCTAssertEqual(c.project, before)
        XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.sources.contains { $0.contains(t(4)) } })
    }

    func testExtendingACopyIntoAZeroStrengthKeyframeCannotRelinquishItsSource() throws {
        let (c, _, mask) = try ready()
        let effect = c.project.clip(mask)!.video!.redactionEffectID!
        try c.run("Animate beyond the tail", .setKeyframes(clipID: mask, parameter: "video.effects.\(effect).radius", keyframes: [Keyframe(time: .zero, value: .number(48)), Keyframe(time: t(6), value: .number(0))]))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: mask, patch: .object(["duration": .number(7)])), to: c))
        XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testCombiningATimingEditAndAnEffectEditCannotReleaseTheOldTail() throws {
        let (c, _, mask) = try ready()
        let id = c.project.clip(mask)!.video!.redactionEffectID!
        let patch: JSONValue = .object(["duration": .number(2), "video": .object(["effects": .array([
            .object(["id": .string(id), "type": .string("blur"), "params": .object(["radius": .number(49)])])
        ])])])
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: mask, patch: patch), to: c))
        XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.sources.contains { $0.contains(t(4)) } })
    }

    func testAnOrdinaryTrackNamedPrivacyStillAcceptsRedactions() throws {
        let (c, _, _, _) = try PrivacyPanelTests().screen()
        let id = c.project.track(named: "Screen")!.id
        try c.run("Rename source", .updateTrack(trackID: id, patch: .object(["name": .string("Privacy (Ordinary)")])))
        XCTAssertFalse(c.project.track(id)!.isPrivacy)
        try c.run("Another region", .redact(range: TimeRange(start: t(10), end: t(15)), rect: Rect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), trackID: id))
    }

    func testOrdinaryFootageOnAnEmptyPrivacyNamedTrackKeepsItsIdentity() throws {
        let (c, _, _) = try ready()
        try c.run("Empty named track", .addTrack(kind: .video, name: "Privacy (Empty)", id: "trk_empty"))
        try c.run("Ordinary footage", .insertClip(trackID: "trk_empty", clip: Clip(id: "clip_later", content: .media(mediaID: "med_screen"), start: t(7), duration: t(1), sourceStart: t(10))))
        XCTAssertFalse(c.project.track("trk_empty")!.isPrivacy)
        try c.run("Hide later footage", .redact(range: TimeRange(start: t(7), end: t(8)), rect: Rect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), trackID: "trk_empty"))
    }

    func testDisabledAndRemovedLegacyEffectsMigrateAndCanBeReenabled() throws {
        for version in [1, 2] {
            for removed in [false, true] {
                let (original, picture, mask) = try ready()
                var p = original.project
                p.schemaVersion = version
                p.sourceRedactions = nil
                let (track, index) = p.location(ofClip: mask)!
                p[track].clips[index].video?.redaction = nil
                p[track].clips[index].video?.redactionSources = nil
                p[track].clips[index].video?.redactionEffectID = nil
                p[track].clips[index].video?.redactionVisibility = nil
                p[track].clips[index].video?.redactionOriginID = nil
                if removed { p[track].clips[index].video?.effects = [] }
                else { p[track].clips[index].video?.effects[0].enabled = false }
                let loaded = try ProjectFile.migrate(p)
                XCTAssertNotNil(loaded.clip(mask)?.video?.redaction)
                XCTAssertFalse(loaded.clip(mask)?.video?.redactionSources?.isEmpty ?? true)
                XCTAssertTrue(loaded[track].isSwitchedOffRedaction(loaded.clip(mask)!))
                let c = ProjectCoordinator(project: loaded)
                if removed {
                    try c.run("New blur", .addEffect(clipID: mask, effect: Effect(id: "fx_restore", type: "blur", params: ["radius": .number(48)])))
                } else {
                    try c.run("Restore blur", .updateEffect(clipID: mask, effectID: loaded.clip(mask)!.video!.effects[0].id, patch: .object(["enabled": .bool(true)])))
                }
                try c.run("Zoom picture", .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["scale": .number(2)])])])))
                XCTAssertEqual(c.project.clip(mask)?.video?.transform.scale, 2)
                XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
            }
        }
    }

    func testAddingAndRemovingAnotherEffectCannotOrphanTheActiveBlur() throws {
        for (enabled, radius) in [(true, 24.0), (false, 24.0), (true, 0.0)] {
            let (c, _, mask) = try ready()
            let first = c.project.clip(mask)!.video!.redactionEffectID!
            try c.run("Second blur", .addEffect(clipID: mask, effect: Effect(id: "fx_second", type: "blur", enabled: enabled, params: ["radius": .number(radius)])))
            XCTAssertEqual(c.project.clip(mask)?.video?.redactionEffectID, first)
            XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
            try c.run("Remove second blur", .removeEffect(clipID: mask, effectID: "fx_second"))
            XCTAssertEqual(c.project.clip(mask)?.video?.redactionEffectID, first)
            XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
            XCTAssertFalse(c.project.videoTracks.first(where: \.isPrivacy)!.isSwitchedOffRedaction(c.project.clip(mask)!))
        }
    }

    func testRemovingTheManagedEffectSelectsAnotherEffectiveRedaction() throws {
        let (c, _, mask) = try ready()
        let first = c.project.clip(mask)!.video!.redactionEffectID!
        try c.run("Second effect", .addEffect(clipID: mask, effect: Effect(id: "fx_second", type: "pixelate", params: ["scale": .number(40)])))
        try c.run("Remove first", .removeEffect(clipID: mask, effectID: first))
        XCTAssertEqual(c.project.clip(mask)?.video?.redactionEffectID, "fx_second")
        XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testAnUnusedEffectCannotEraseStrongerProtectionRetainedThroughACut() throws {
        let (c, _, _) = try ready()
        let region = RedactionSafety.protections(in: c.project)[0].region
        try c.run("Cut away current occurrences", .rippleDeleteRange(range: TimeRange(start: .zero, end: c.project.duration)))
        try c.run("Reuse with another copy", .insertClip(trackID: "trk_screen", clip: Clip(id: "clip_reuse", content: .media(mediaID: "med_screen"), start: .zero, duration: t(5))), .redact(range: TimeRange(start: .zero, end: t(5)), rect: region, mediaID: "med_screen", style: .blur, size: 1))
        let mask = c.project.videoTracks.first(where: \.isPrivacy)!.clips[0].id
        func retainsStrongPolicy() -> Bool {
            RedactionSafety.protections(in: c.project).contains { $0.effect.params["radius"]?.number == 48 && $0.sources.contains { $0.contains(t(1)) } }
        }
        XCTAssertTrue(retainsStrongPolicy())
        try c.run("Unused effect", .addEffect(clipID: mask, effect: Effect(id: "fx_unused", type: "blur", enabled: false, params: ["radius": .number(10)])))
        XCTAssertTrue(retainsStrongPolicy())
        try c.run("Remove unused effect", .removeEffect(clipID: mask, effectID: "fx_unused"))
        XCTAssertTrue(retainsStrongPolicy())
        let active = c.project.clip(mask)!.video!.redactionEffectID!
        try c.run("Strengthen only the current weak copy", .updateEffect(clipID: mask, effectID: active, patch: .object(["params": .object(["radius": .number(2)])])))
        XCTAssertTrue(retainsStrongPolicy())
    }

    func testAnAliasEffectIncreaseCannotReduceSourcePixelConcealment() throws {
        let (c, _, _) = try ready()
        let scopes = RedactionSafety.protections(in: c.project)
        let strongest = scopes.map { $0.sourcePixelsPerUnit * ($0.effect.params["radius"]?.number ?? 0) }.max()!
        let region = scopes[0].region
        try c.run("Cut away current occurrences", .rippleDeleteRange(range: TimeRange(start: .zero, end: c.project.duration)))
        var alias = c.project.media[0]
        alias.id = "med_alias"
        try c.run("Another identity", .addMedia(item: alias))
        let picture = Clip(id: "clip_alias", content: .media(mediaID: alias.id), start: .zero, duration: t(5), video: VideoProperties(transform: Transform(scale: 8)))
        try c.run("Redact the zoomed alias", .insertClip(trackID: "trk_screen", clip: picture), .redact(range: picture.range, rect: region, mediaID: alias.id, style: .blur, size: 48))
        let mask = c.project.videoTracks.first(where: \.isPrivacy)!.clips[0]
        try c.run("Increase blur", .updateEffect(clipID: mask.id, effectID: mask.video!.redactionEffectID!, patch: .object(["params": .object(["radius": .number(49)])])))
        let after = RedactionSafety.protections(in: c.project).map { $0.sourcePixelsPerUnit * ($0.effect.params["radius"]?.number ?? 0) }.max()!
        XCTAssertGreaterThanOrEqual(after, strongest)
    }

    func testCopyTimingCannotAbsorbAnotherPiecesDurableSelection() throws {
        for slip in [false, true] {
            let (c, _, mask, _) = try PrivacyPanelTests().screen()
            let region = c.project.clip(mask)!.video!.redaction!
            try c.run("Another protected piece", .redact(range: TimeRange(start: t(20), end: t(22)), rect: region, mediaID: "med_screen", style: .blur, size: 48))
            let other = c.clips("Screen").first { $0.start == t(20) }!
            try c.run("Incidentally remove the other piece", .removeClips(clipIDs: [other.id]))
            let change = slip ? EditCommand.slip(clipID: mask, delta: t(10), includeLinked: false) : .updateClip(clipID: mask, patch: .object(["speed": .number(4)]))
            _ = try PrivacyAuditCoverage.applyOrRefuse(change, to: c)
            try c.run("Explicitly disable only this copy", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
            XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.sources.contains { $0.contains(t(21)) } })
            let reused = Clip(id: "clip_other_source", content: .media(mediaID: "med_screen"), start: t(70), duration: t(1), sourceStart: t(21))
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "Screen", clip: reused), to: c))
        }
    }

    func testClearingAllVideoPropertiesCannotStripPrivacyOwnership() throws {
        let (c, _, mask) = try ready()
        let before = c.project
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: mask, patch: .object(["video": .null])), to: c))
        XCTAssertEqual(c.project, before)
    }

    func testMovingACopyCannotPromoteOrdinaryFootageToAPrivacyTrack() throws {
        let (c, _, mask) = try ready()
        var camera = c.project.media[0]
        camera.id = "med_camera"; camera.path = "camera.mov"; camera.role = .camera
        try c.run("Camera", .addMedia(item: camera), .addTrack(kind: .video, name: "Camera", id: "trk_camera"), .insertClip(trackID: "trk_camera", clip: Clip(id: "clip_camera", content: .media(mediaID: camera.id), start: t(6), duration: t(1))))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.moveClips(clipIDs: [mask], delta: .zero, toTrackID: "trk_camera", includeLinked: false), to: c))
        XCTAssertFalse(c.project.track("trk_camera")!.isPrivacy)
        try c.run("Hide camera", .redact(range: TimeRange(start: t(6), end: t(7)), rect: Rect(x: 0.1, y: 0.1, width: 0.4, height: 0.4), trackID: "trk_camera"))
    }

    func testEditingASlippedCopyCannotCreateAnEmptySourcePolicy() throws {
        let (c, picture, mask) = try ready(variableRate: true)
        try c.run("Slip away", .slip(clipID: picture, delta: t(10)))
        XCTAssertEqual(c.project.clip(mask)?.video?.redactionSources, [])
        let effect = c.project.clip(mask)!.video!.redactionEffectID!
        try c.run("Strengthen slipped blur", .updateEffect(clipID: mask, effectID: effect, patch: .object(["params": .object(["radius": .number(60)])])))
        XCTAssertTrue((c.project.sourceRedactions ?? []).allSatisfy { !$0.sources.isEmpty })
    }

    func testAnExplicitlyDisabledCopyStaysOffThroughPictureTogglesAndReload() throws {
        let (c, picture, mask) = try ready()
        try c.run("Turn off copy", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
        let loaded = try ProjectFile.migrate(JSONDecoder().decode(Project.self, from: ProjectFile.encoder().encode(c.project)))
        let next = ProjectCoordinator(project: loaded)
        try next.run("Picture off", .updateClip(clipID: picture, patch: .object(["enabled": .bool(false)])))
        try next.run("Picture on", .updateClip(clipID: picture, patch: .object(["enabled": .bool(true)])))
        XCTAssertFalse(next.project.clip(mask)!.enabled)
        XCTAssertTrue(RedactionSafety.protections(in: next.project).isEmpty)
    }

    func testALockedDisabledCopyDoesNotBlockPictureTransforms() throws {
        let (c, picture, mask) = try ready()
        try c.run("Turn off copy", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
        try c.run("Lock copy", .updateTrack(trackID: c.project.videoTracks.first(where: \.isPrivacy)!.id, patch: .object(["locked": .bool(true)])))
        try c.run("Zoom picture", .updateClip(clipID: picture, patch: .object(["video": .object(["transform": .object(["scale": .number(2)])])])))
        XCTAssertFalse(c.project.clip(mask)!.enabled)
        XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
        try c.run("Layout picture", .applyLayout(clipIDs: [picture], preset: .pipLeft))
        try c.run("Portrait layout", .setFormatLayout(clipIDs: [picture], format: "portrait", slot: .top))
        XCTAssertFalse(c.project.clip(mask)!.enabled)
    }

    func testAHiddenLockedPrivacyTrackDoesNotBlockPictureLayouts() throws {
        let (c, picture, _) = try ready()
        let track = c.project.videoTracks.first(where: \.isPrivacy)!.id
        try c.run("Hide privacy", .updateTrack(trackID: track, patch: .object(["hidden": .bool(true)])))
        try c.run("Lock hidden privacy", .updateTrack(trackID: track, patch: .object(["locked": .bool(true)])))
        try c.run("Layout picture", .applyLayout(clipIDs: [picture], preset: .pipLeft))
        try c.run("Portrait layout", .setFormatLayout(clipIDs: [picture], format: "portrait", slot: .top))
        XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testAnAutomaticallyHiddenCopyFollowsItsPictureBackOn() throws {
        let (c, picture, mask) = try ready()
        try c.run("Picture off", .updateClip(clipID: picture, patch: .object(["enabled": .bool(false)])))
        XCTAssertFalse(c.project.clip(mask)!.enabled)
        try c.run("Picture on", .updateClip(clipID: picture, patch: .object(["enabled": .bool(true)])))
        XCTAssertTrue(c.project.clip(mask)!.enabled)
        XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testEditingAnAutomaticallyHiddenEffectRetainsItsSourceProtection() throws {
        for batched in [false, true] {
            let (c, picture, mask) = try ready()
            let effect = c.project.clip(mask)!.video!.redactionEffectID!
            let hide = EditCommand.updateClip(clipID: picture, patch: .object(["enabled": .bool(false)]))
            let strengthen = EditCommand.updateEffect(clipID: mask, effectID: effect, patch: .object(["params": .object(["radius": .number(49)])]))
            if batched { try c.run("Hide then strengthen", hide, strengthen) }
            else { try c.run("Picture off", hide); try c.run("Strengthen", strengthen) }
            XCTAssertEqual(c.project.clip(mask)?.video?.redactionVisibility, .followingPicture)
            XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.sources.contains { $0.contains(t(1)) } })
            let loaded = try ProjectFile.migrate(JSONDecoder().decode(Project.self, from: ProjectFile.encoder().encode(c.project)))
            let next = ProjectCoordinator(project: loaded)
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "trk_screen", clip: Clip(id: "clip_reuse", content: .media(mediaID: "med_screen"), start: t(7), duration: t(1), sourceStart: t(1))), to: next))
        }
    }

    func testAnExplicitDisableWhileAutomaticallyHiddenPersistsItsIntent() throws {
        let (c, picture, mask) = try ready()
        try c.run("Picture off", .updateClip(clipID: picture, patch: .object(["enabled": .bool(false)])))
        try c.run("Copy explicitly off", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
        XCTAssertEqual(c.project.clip(mask)?.video?.redactionVisibility, .disabled)
        XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
        let loaded = try ProjectFile.migrate(JSONDecoder().decode(Project.self, from: ProjectFile.encoder().encode(c.project)))
        let next = ProjectCoordinator(project: loaded)
        try next.run("Picture on", .updateClip(clipID: picture, patch: .object(["enabled": .bool(true)])))
        XCTAssertFalse(next.project.clip(mask)!.enabled)
    }

    func testAnOffEffectOnALockedTrackDoesNotBlockLayouts() throws {
        let (c, picture, mask) = try ready()
        let effectID = c.project.clip(mask)!.video!.redactionEffectID!
        try c.run("Effect off", .updateEffect(clipID: mask, effectID: effectID, patch: .object(["enabled": .bool(false)])))
        try c.run("Lock copy", .updateTrack(trackID: c.project.videoTracks.first(where: \.isPrivacy)!.id, patch: .object(["locked": .bool(true)])))
        try c.run("Layout picture", .applyLayout(clipIDs: [picture], preset: .pipLeft))
        try c.run("Portrait layout", .setFormatLayout(clipIDs: [picture], format: "portrait", slot: .top))
        XCTAssertFalse(c.project.clip(mask)!.video!.effects.first { $0.id == effectID }!.enabled)
        XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testAngleSwitchingDoesNotReenableAnExplicitlyDisabledCopy() throws {
        let (base, picture, mask) = try ready()
        var p = base.project
        p.media[0].takeID = "take_angles"; p.media[0].takeOffset = .zero
        var camera = p.media[0]
        camera.id = "med_camera"; camera.path = "camera.mov"; camera.role = .camera
        p.media.append(camera)
        p.videoTracks.insert(Track(id: "trk_camera", kind: .video, name: "Camera", clips: [Clip(id: "clip_camera", content: .media(mediaID: camera.id), start: .zero, duration: t(5), linkGroup: p.clip(picture)!.linkGroup)]), at: 0)
        let c = ProjectCoordinator(project: p)
        try c.run("Copy off", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
        try c.run("Camera angle", .showAngle(range: TimeRange(start: .zero, end: t(5)), trackID: "Camera"))
        XCTAssertFalse(c.project.clip(picture)!.enabled)
        try c.run("Screen angle", .showAngle(range: TimeRange(start: .zero, end: t(5)), trackID: "Screen"))
        XCTAssertTrue(c.project.clip(picture)!.enabled)
        XCTAssertFalse(c.project.clip(mask)!.enabled)
        XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)

        let off = ProjectCoordinator(project: p)
        let effectID = off.project.clip(mask)!.video!.redactionEffectID!
        try off.run("Effect off", .updateEffect(clipID: mask, effectID: effectID, patch: .object(["enabled": .bool(false)])))
        try off.run("Lock dormant copy", .updateTrack(trackID: off.project.videoTracks.first(where: \.isPrivacy)!.id, patch: .object(["locked": .bool(true)])))
        let inactiveBeforeAngle = off.project.clip(mask)
        try off.run("Camera angle", .showAngle(range: TimeRange(start: .zero, end: t(5)), trackID: "Camera"))
        XCTAssertEqual(off.project.clip(mask), inactiveBeforeAngle, "angle selection cannot mutate a locked inactive copy")
        try off.run("Screen angle", .showAngle(range: TimeRange(start: .zero, end: t(5)), trackID: "Screen"))
        XCTAssertFalse(off.project.clip(mask)!.video!.effects.first { $0.id == effectID }!.enabled)
        XCTAssertTrue(RedactionSafety.protections(in: off.project).isEmpty)
    }

    func testAliasesWithDifferentTimingRefuseBeforeBecomingRemembered() throws {
        for hardLink in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-clock-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("screen.mov")
            try Data("synthetic identity".utf8).write(to: source)
            let aliasURL = root.appendingPathComponent("alias.mov")
            if hardLink { try FileManager.default.linkItem(at: source, to: aliasURL) }
            else { try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: source) }
            let (base, _, _) = try ready()
            let c = ProjectCoordinator(project: base.project, sourceFolder: root)
            var alias = c.project.media[0]
            alias.id = "med_alias"; alias.path = "alias.mov"; alias.pictureDelay = t(1)
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.addMedia(item: alias), to: c))
            try c.run("Still editable", .updateProject(patch: .object(["name": .string("Still editable")])))
            XCTAssertNil(c.project.media(alias.id))
        }
    }

    func testPreexistingAliasesCannotPoisonTheFirstRedaction() throws {
        let (base, _, _) = try ready()
        var p = base.project
        p.videoTracks.removeAll(where: \.isPrivacy)
        p.sourceRedactions = nil
        var alias = p.media[0]
        alias.id = "med_alias"; alias.pictureDelay = t(1)
        p.media.append(alias)
        let c = ProjectCoordinator(project: p)
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.redact(range: TimeRange(start: .zero, end: t(5)), rect: Rect(x: 0.1, y: 0.1, width: 0.4, height: 0.4), mediaID: "med_screen"), to: c))
        try c.run("Still editable", .updateProject(patch: .object(["name": .string("Still editable")])))
        XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testAnInconsistentLegacyAliasCanBeRepairedOrUnredacted() throws {
        let (base, _, mask) = try ready()
        var p = base.project
        var alias = p.media[0]
        alias.id = "med_alias"; alias.pictureDelay = t(1)
        p.media.append(alias)
        let repair = ProjectCoordinator(project: p)
        try repair.run("Repair alias clock", .updateMedia(mediaID: alias.id, patch: .object(["pictureDelay": .number(0)])))
        try repair.run("Still editable", .updateProject(patch: .object(["name": .string("Repaired")])))
        let unredact = ProjectCoordinator(project: p)
        try unredact.run("Explicitly remove privacy", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
        XCTAssertTrue(RedactionSafety.protections(in: unredact.project).isEmpty)
    }

    func testAnInconsistentAliasAndItsClipsCanBeRemovedInOneAtomicBatch() throws {
        let (base, _, _) = try ready()
        var p = base.project
        var alias = p.media[0]
        alias.id = "med_alias"; alias.pictureDelay = t(0.2)
        p.media.append(alias)
        p.videoTracks[0].clips.append(Clip(id: "clip_alias", content: .media(mediaID: alias.id), start: t(7), duration: t(1), sourceStart: t(10)))
        let c = ProjectCoordinator(project: p)
        try c.run("Remove alias and its occurrence", .removeClips(clipIDs: ["clip_alias"], includeLinked: false), .removeMedia(mediaID: alias.id))
        XCTAssertNil(c.project.media(alias.id))
        XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testInactiveCopiesCannotRelinquishAnotherCopiesRetainedPolicy() throws {
        for action in ["remove", "effect", "enable", "unhide"] {
            let (c, picture, mask) = try ready()
            let region = c.project.clip(mask)!.video!.redaction!
            let effect = c.project.clip(mask)!.video!.redactionEffectID!
            let track = c.project.videoTracks.first(where: \.isPrivacy)!.id
            try c.run("Weaker first copy", .updateEffect(clipID: mask, effectID: effect, patch: .object(["params": .object(["radius": .number(12)])])))
            if action == "unhide" { try c.run("Hide privacy track", .updateTrack(trackID: track, patch: .object(["hidden": .bool(true)]))) }
            else { try c.run("Disable copy", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)]))) }
            try c.run("Picture off", .updateClip(clipID: picture, patch: .object(["enabled": .bool(false)])))
            let next = Clip(id: "clip_other", content: .media(mediaID: "med_screen"), start: t(10), duration: t(5))
            try c.run("Protect another occurrence", .insertClip(trackID: "trk_screen", clip: next), .redact(range: next.range, rect: region, mediaID: "med_screen", style: .blur, size: 48))
            try c.run("Incidentally cut it away", .rippleDeleteRange(range: next.range))
            XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.effect.params["radius"]?.number == 48 })
            switch action {
            case "remove": try c.run("Remove inactive copy", .removeClips(clipIDs: [mask], includeLinked: false))
            case "effect": try c.run("Edit inactive copy", .updateEffect(clipID: mask, effectID: effect, patch: .object(["params": .object(["radius": .number(13)])])))
            case "enable": try c.run("Re-enable copy", .updateClip(clipID: mask, patch: .object(["enabled": .bool(true)])))
            default: try c.run("Unhide copy", .updateTrack(trackID: track, patch: .object(["hidden": .bool(false)])))
            }
            XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.effect.params["radius"]?.number == 48 && $0.sources.contains { $0.contains(t(2)) } }, action)
        }
    }

    func testALockedAutomaticallyHiddenCopyCannotBeStrandedByABladeOrRipple() throws {
        for blade in [false, true] {
            let (c, picture, _) = try ready()
            try c.run("Picture off", .updateClip(clipID: picture, patch: .object(["enabled": .bool(false)])))
            try c.run("Lock privacy", .updateTrack(trackID: c.project.videoTracks.first(where: \.isPrivacy)!.id, patch: .object(["locked": .bool(true)])))
            let command = blade ? EditCommand.blade(at: t(2)) : .rippleDeleteRange(range: TimeRange(start: .zero, end: t(1)))
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(command, to: c))
        }
    }

    func testAnUnlinkedDisabledLegacyCopyDoesNotResurrectSourceProtection() throws {
        let (base, _, mask) = try ready()
        var p = base.project
        let (track, index) = p.location(ofClip: mask)!
        p[track].clips[index].enabled = false
        p[track].clips[index].linkGroup = nil
        p[track].clips[index].video?.redactionVisibility = nil
        p[track].clips[index].video?.redactionOriginID = nil
        p.sourceRedactions = nil
        let loaded = try ProjectFile.migrate(p)
        XCTAssertEqual(loaded.clip(mask)?.video?.redactionVisibility, .disabled)
        XCTAssertTrue(RedactionSafety.protections(in: loaded).isEmpty)
        try ProjectCoordinator(project: loaded).run("Still editable", .updateProject(patch: .object(["name": .string("No resurrection")])))
    }

    func testAnAdoptedFormatsAutomaticallyHiddenCopyCanFollowLaterUncropping() throws {
        let (c, picture, mask) = try ready()
        try c.run("Crop the region out of portrait", .updateClip(clipID: picture, patch: .object(["video": .object(["formatOverrides": .object(["portrait": .object(["crop": .object(["left": .number(0.7)])])])])])))
        XCTAssertEqual(c.project.clip(mask)?.video?.formatOverrides["portrait"]?.hidden, true)
        try c.run("Use portrait as the main layout", .adoptFormat(format: "portrait"))
        try c.run("Reveal the region again", .updateClip(clipID: picture, patch: .object(["video": .object(["crop": .object(["left": .number(0)])])])))
        XCTAssertTrue(c.project.clip(mask)!.enabled)
        XCTAssertEqual(c.project.clip(mask)?.video?.crop.left, 0.2)
    }

    func testRedactingWhileAnOldPrivacyTrackIsHiddenCreatesVisibleProtection() throws {
        let (c, _, _) = try ready()
        let region = RedactionSafety.protections(in: c.project)[0].region
        try c.run("Hide previous privacy", .updateTrack(trackID: c.project.videoTracks.first(where: \.isPrivacy)!.id, patch: .object(["hidden": .bool(true)])))
        try c.run("Redact again", .redact(range: TimeRange(start: .zero, end: t(5)), rect: region, mediaID: "med_screen", style: .blur, size: 48))
        XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
        XCTAssertTrue(c.project.videoTracks.contains { $0.isPrivacy && !$0.hidden && !$0.clips.isEmpty })
    }


    func testALockedAutomaticallyHiddenCopyCannotBeMutatedByAngleSelection() throws {
        let (base, picture, _) = try ready()
        var p = base.project
        p.media[0].takeID = "take_locked"; p.media[0].takeOffset = .zero
        var camera = p.media[0]
        camera.id = "med_camera"; camera.path = "camera.mov"; camera.role = .camera
        p.media.append(camera)
        p.videoTracks.insert(Track(id: "trk_camera", kind: .video, name: "Camera", clips: [Clip(id: "clip_camera", content: .media(mediaID: camera.id), start: .zero, duration: t(5), linkGroup: p.clip(picture)!.linkGroup)]), at: 0)
        let c = ProjectCoordinator(project: p)
        let range = TimeRange(start: .zero, end: t(5))
        try c.run("Hide screen by angle", .showAngle(range: range, trackID: "Camera"))
        try c.run("Lock dormant privacy", .updateTrack(trackID: c.project.videoTracks.first(where: \.isPrivacy)!.id, patch: .object(["locked": .bool(true)])))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.showAngle(range: range, trackID: "Screen"), to: c))
    }


    func testDisablingALaterCopyCannotReleaseAnIndependentHistoricalRedaction() throws {
        for size in [12.0, 48.0] {
            let (c, _, _) = try ready()
            let region = RedactionSafety.protections(in: c.project)[0].region
            try c.run("Cut away first request", .rippleDeleteRange(range: TimeRange(start: .zero, end: c.project.duration)))
            let picture = Clip(id: "clip_later", content: .media(mediaID: "med_screen"), start: .zero, duration: t(5))
            try c.run("Another independent redaction", .insertClip(trackID: "trk_screen", clip: picture), .redact(range: picture.range, rect: region, mediaID: "med_screen", style: .blur, size: size))
            let mask = c.project.videoTracks.first(where: \.isPrivacy)!.clips[0].id
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])), to: c))
            XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.effect.params["radius"]?.number == 48 && $0.sources.contains { $0.contains(t(1)) } })
        }
    }

    func testAFreezeCannotAdoptAndUnredactAnotherRequestsHistory() throws {
        let (c, _, _) = try ready()
        let region = RedactionSafety.protections(in: c.project)[0].region
        try c.run("Cut away first request", .rippleDeleteRange(range: TimeRange(start: .zero, end: c.project.duration)))
        let picture = Clip(id: "clip_other_request", content: .media(mediaID: "med_screen"), start: t(5), duration: t(2), sourceStart: t(10))
        try c.run("Protect different source frames", .insertClip(trackID: "trk_screen", clip: picture), .redact(range: picture.range, rect: region, mediaID: "med_screen", style: .blur, size: 48))
        let mask = c.project.videoTracks.first(where: \.isPrivacy)!.clips[0].id
        try c.run("Freeze onto the first request", .updateClip(clipID: picture.id, patch: .object(["freezeFrame": .bool(true), "sourceStart": .number(1)])))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])), to: c))
        XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.sources.contains { $0.contains(t(1)) } })
    }

    func testReturningFromATrimOrSlipRestoresTheSameRequestsControllableSelection() throws {
        for slip in [false, true] {
            let (c, picture, mask) = try ready()
            if slip {
                try c.run("Slip away", .slip(clipID: picture, delta: t(10)))
                try c.run("Slip back", .slip(clipID: picture, delta: t(-10)))
            } else {
                try c.run("Trim in", .trim(clipID: picture, edge: .start, to: t(1)))
                try c.run("Trim back", .trim(clipID: picture, edge: .start, to: .zero))
            }
            XCTAssertTrue(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(t(0.5)) })
            try c.run("Explicitly disable this request", .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])))
            XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
        }
    }


    func testPrivacyRequestIdentityCannotBeInjectedThroughClipCommands() throws {
        let (c, picture, mask) = try ready()
        let origin = c.project.clip(mask)!.video!.redactionOriginID!
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: picture, patch: .object(["video": .object(["redactionOriginID": .string(origin)])])), to: c))
        let forged = Clip(id: "clip_forged_request", content: .media(mediaID: "med_screen"), start: t(7), duration: t(1), sourceStart: t(10), video: VideoProperties(redactionOriginID: origin))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.insertClip(trackID: "trk_screen", clip: forged), to: c))
    }


    func testAutomaticallyHiddenCopiesKeepFollowingTimingAndHolds() throws {
        let patches: [JSONValue] = [.object(["start": .number(2)]), .object(["duration": .number(3)]), .object(["sourceStart": .number(2)])]
        for patch in patches {
            let (c, picture, mask) = try ready()
            try c.run("Picture off", .updateClip(clipID: picture, patch: .object(["enabled": .bool(false)])))
            try c.run("Edit hidden picture", .updateClip(clipID: picture, patch: patch))
            XCTAssertEqual(c.project.clip(mask)?.range, c.project.clip(picture)?.range)
            XCTAssertEqual(c.project.clip(mask)?.sourceStart, c.project.clip(picture)?.sourceStart)
            try c.run("Picture back on", .updateClip(clipID: picture, patch: .object(["enabled": .bool(true)])))
            XCTAssertEqual(c.project.clip(mask)?.range, c.project.clip(picture)?.range)
        }
        let (c, picture, mask) = try ready()
        try c.run("Picture off", .updateClip(clipID: picture, patch: .object(["enabled": .bool(false)])))
        try c.run("Hold hidden picture", .holdFrame(clipID: picture, range: TimeRange(start: t(1), end: t(2))))
        XCTAssertEqual(c.project.clip(mask)?.holds, c.project.clip(picture)?.holds)
    }

    func testAutomaticBrollPlacementDoesNotChooseAPrivacyTrack() throws {
        let (base, picture, _) = try ready()
        var p = base.project
        p.videoTracks.removeAll(where: \.isPrivacy); p.sourceRedactions = nil
        let (track, index) = p.location(ofClip: picture)!
        p[track].clips[index].duration = t(10)
        var broll = p.media[0]
        broll.id = "med_broll"; broll.path = "broll.mov"; broll.role = .broll
        p.media.append(broll)
        let c = ProjectCoordinator(project: p)
        try c.run("Short redaction", .redact(range: TimeRange(start: .zero, end: t(2)), rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen"))
        try c.run("Place B-roll", .placeMedia(mediaIDs: [broll.id], at: t(6), duration: t(2)))
        XCTAssertTrue(c.project.videoTracks.contains { !$0.isPrivacy && $0.clips.contains { $0.mediaID == broll.id } })
    }


    func testAPrivacyCopyCannotBeRepointedWhileItsPictureIsHidden() throws {
        let (c, picture, mask) = try ready()
        var other = c.project.media[0]
        other.id = "med_other"; other.path = "other.mov"
        try c.run("Another file", .addMedia(item: other))
        try c.run("Hide picture", .updateClip(clipID: picture, patch: .object(["enabled": .bool(false)])))
        let before = c.project
        let contents: [ClipContent] = [.media(mediaID: other.id), .solid(color: .white)]
        for content in contents {
            let original = before.clip(mask)!
            let change = try XCTUnwrap(JSONValue.mergePatch(from: .from(original.content), to: .from(content)))
            let patch: JSONValue = .object(["content": change])
            let attempted = try JSONValue.applyMergePatch(patch, to: original)
            XCTAssertEqual(attempted.content, content, "the probe must actually replace the clip content")
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: mask, patch: patch), to: c))
            XCTAssertEqual(c.project, before)
        }
        try c.run("Show picture", .updateClip(clipID: picture, patch: .object(["enabled": .bool(true)])))
        XCTAssertTrue(c.project.clip(mask)!.enabled)
    }

    func testAnAPIAddedStillCanBeRedactedWithoutTheVideoFlag() throws {
        let item = MediaItem(id: "med_still", path: "card.png", kind: .image, role: .graphic, width: 1280, height: 720)
        let c = ProjectCoordinator(project: Project(name: "Still", media: [item], videoTracks: [Track(id: "trk_still", kind: .video, name: "Still")]))
        try c.run("Place still", .placeMedia(mediaIDs: [item.id], at: .zero, duration: t(3)))
        try c.run("Hide text on still", .redact(range: TimeRange(start: .zero, end: t(3)), rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: item.id))
        XCTAssertFalse(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testANoOpPixelateCannotCreateAnUnmanagedRedaction() throws {
        let (base, _, _) = try ready()
        var p = base.project
        p.videoTracks.removeAll(where: \.isPrivacy); p.sourceRedactions = nil
        let c = ProjectCoordinator(project: p)
        let before = c.project
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.redact(range: TimeRange(start: .zero, end: t(5)), rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: "med_screen", style: .pixelate, size: 1), to: c))
        XCTAssertEqual(c.project, before)
    }

    func testMigrationCannotGiveACopyControlOfIndependentHistoricalProtection() throws {
        for amount in [12.0, 48.0] {
            let (base, _, mask) = try ready()
            var p = base.project
            let (track, index) = p.location(ofClip: mask)!
            p[track].clips[index].video?.redactionOriginID = nil
            p[track].clips[index].video?.effects[0].params["radius"] = .number(amount)
            var old = RedactionSafety.protections(in: p)[0]
            old.originID = nil
            var current = old
            current.effect.params["radius"] = .number(amount)
            p.sourceRedactions = [old, current]
            let c = ProjectCoordinator(project: try ProjectFile.migrate(p))
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: mask, patch: .object(["enabled": .bool(false)])), to: c))
            XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.effect.params["radius"]?.number == 48 })
        }
    }

    func testOriginlessMergedPoliciesCannotBeReleasedByAnUnprovenOwner() throws {
        let (base, _, _) = try ready()
        let item = base.project.media[0]
        let region = Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)
        var scope = RedactionSafety.protections(in: base.project)[0]
        scope.originID = nil
        scope.sources = [TimeRange(start: .zero, end: t(2)), TimeRange(start: t(5), end: t(7))]
        var pictures: [Clip] = [], masks: [Clip] = []
        for (n, start) in [0.0, 5.0].enumerated() {
            let link = "lnk_legacy_\(n)"
            pictures.append(Clip(id: "picture_\(n)", content: .media(mediaID: item.id), start: t(start), duration: t(2), sourceStart: t(start), linkGroup: link))
            var fx = scope.effect
            fx.id = "fx_legacy_\(n)"
            let video = VideoProperties(crop: Crop(left: 0.2, top: 0.2, right: 0.4, bottom: 0.6), effects: [fx], redaction: region, redactionSources: [scope.sources[n]], redactionEffectID: fx.id)
            masks.append(Clip(id: "mask_\(n)", content: .media(mediaID: item.id), start: t(start), duration: t(2), sourceStart: t(start), linkGroup: link, video: video))
        }
        scope.effect.id = "fx_legacy_0"
        var p = Project(name: "Merged legacy policy", settings: base.project.settings, media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: pictures), Track(id: "trk_privacy", kind: .video, name: "Privacy (Screen)", clips: masks)])
        p.sourceRedactions = [scope]
        let c = ProjectCoordinator(project: try ProjectFile.migrate(p))
        XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: "mask_1", patch: .object(["enabled": .bool(false)])), to: c))
        XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.sources.contains { $0.contains(t(1)) } })
        XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.sources.contains { $0.contains(t(6)) } })
    }

    func testLegacySharedEffectIDsDoNotCollapseIndependentPrivacyRequests() throws {
        for storedPolicy in [false, true] {
            let (base, _, _) = try ready()
            let item = base.project.media[0]
            let region = Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)
            let effect = Effect(id: "fx_shared", type: "blur", params: ["radius": .number(48)])
            let crop = Crop(left: 0.2, top: 0.2, right: 0.4, bottom: 0.6)
            let pictures = [Clip(id: "clip_a", content: .media(mediaID: item.id), start: .zero, duration: t(2), sourceStart: t(1), linkGroup: "lnk_a"), Clip(id: "clip_b", content: .media(mediaID: item.id), start: t(4), duration: t(2), sourceStart: t(1), linkGroup: "lnk_b")]
            var masks = [
                Clip(id: "mask_a", name: "Privacy", content: .media(mediaID: item.id), start: .zero, duration: t(2), sourceStart: t(1), linkGroup: "lnk_a", video: VideoProperties(crop: crop, effects: [effect])),
                Clip(id: "mask_b", name: "Privacy", content: .media(mediaID: item.id), start: t(4), duration: t(2), sourceStart: t(1), linkGroup: "lnk_b", video: VideoProperties(crop: crop, effects: [effect]))
            ]
            var p = Project(name: "Independent legacy requests", settings: base.project.settings, media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: pictures), Track(id: "trk_privacy", kind: .video, name: "Privacy (Screen)", clips: masks)])
            p.schemaVersion = storedPolicy ? 3 : 2
            if storedPolicy {
                var scope = RedactionSafety.protections(in: base.project)[0]
                scope.effect = effect; scope.sources = [TimeRange(start: t(1), end: t(3))]; scope.originID = nil
                p.sourceRedactions = [scope]
                for i in masks.indices { masks[i].video?.redaction = region; masks[i].video?.redactionSources = scope.sources; masks[i].video?.redactionEffectID = effect.id }
                p.videoTracks[1].clips = masks
            }
            let loaded = try ProjectFile.migrate(p)
            XCTAssertNotEqual(loaded.clip("mask_a")?.video?.redactionOriginID, loaded.clip("mask_b")?.video?.redactionOriginID)
            let c = ProjectCoordinator(project: loaded)
            try c.run("Incidentally remove the first request", .rippleDeleteRange(range: TimeRange(start: .zero, end: t(2))))
            XCTAssertFalse(try PrivacyAuditCoverage.applyOrRefuse(.updateClip(clipID: "mask_b", patch: .object(["enabled": .bool(false)])), to: c))
        }
    }

}
