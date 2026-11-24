import XCTest
@testable import TandemCore

final class PrivacyRound2OwnershipTests: XCTestCase {
    private enum Cut: CaseIterable { case trim, blade }
    private enum Timing: CaseIterable {
        case speed, sourceStart, slip, duration

        func command(_ mask: String) -> EditCommand {
            switch self {
            case .speed: return .updateClip(clipID: mask, patch: .object(["speed": .number(2)]))
            case .sourceStart: return .updateClip(clipID: mask, patch: .object(["sourceStart": .number(5)]))
            case .slip: return .slip(clipID: mask, delta: Time(seconds: 5), includeLinked: false)
            case .duration: return .updateClip(clipID: mask, patch: .object(["duration": .number(10)]))
            }
        }
    }

    private func time(_ seconds: Double) -> Time { Time(seconds: seconds) }

    @discardableResult
    private func commit(_ c: ProjectCoordinator, _ commands: [EditCommand]) throws -> ProjectCoordinator.CommitResult {
        try c.apply(EditBatch(label: "Ownership regression", commands: commands))
    }

    @discardableResult
    private func applyOrRefuse(_ commands: [EditCommand], to c: ProjectCoordinator,
                               file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let before = c.project
        let revision = c.revision
        do { try commit(c, commands); return true }
        catch let error as EditError {
            switch error {
            case .invalid, .locked:
                let message = String(describing: error).lowercased()
                guard ["privacy", "redact", "blur", "locked"].contains(where: message.contains) else { throw error }
                XCTAssertEqual(c.project, before, "a safe refusal must preserve the whole project", file: file, line: line)
                XCTAssertEqual(c.revision, revision, file: file, line: line)
                return false
            default: throw error
            }
        }
    }

    private func ready(_ cut: Cut, frameRate: FrameRate? = .fps30) throws -> (ProjectCoordinator, String, String) {
        let item = MediaItem(id: "med_screen", path: "screen.mov", kind: .video, role: .screen,
                             duration: time(20), frameRate: frameRate, width: 1280, height: 720, hasVideo: true)
        let picture = Clip(id: "clip_screen", content: .media(mediaID: item.id), start: .zero, duration: time(20))
        let c = ProjectCoordinator(project: Project(name: "Same request ownership", media: [item],
            videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [picture])]))
        try commit(c, [.redact(range: TimeRange(start: .zero, end: time(10)),
            rect: Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), mediaID: item.id, style: .blur, size: 48)])
        let mask = try XCTUnwrap(c.project.videoTracks.first(where: \.isPrivacy)?.clips.first?.id)
        let protected = try XCTUnwrap(c.project.track("trk_screen")?.clips.first(where: { $0.start == .zero })?.id)
        let origin = try XCTUnwrap(c.project.clip(mask)?.video?.redactionOriginID)
        switch cut {
        case .trim:
            try commit(c, [.trim(clipID: protected, edge: .end, to: time(5))])
        case .blade:
            try commit(c, [.blade(at: time(5))])
            let right = try XCTUnwrap(c.project.track("trk_screen")?.clips.first(where: { $0.start == time(5) }))
            let rightCopy = try XCTUnwrap(c.project.videoTracks.first(where: \.isPrivacy)?.clips.first(where: { $0.start == time(5) }))
            XCTAssertEqual(rightCopy.video?.redactionOriginID, origin, "both pieces must belong to the same redact request")
            try commit(c, [.removeClips(clipIDs: [right.id])])
        }
        XCTAssertEqual(c.project.clip(protected)?.range, TimeRange(start: .zero, end: time(5)))
        XCTAssertEqual(c.project.clip(mask)?.range, TimeRange(start: .zero, end: time(5)))
        XCTAssertFalse(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(time(6)) })
        XCTAssertTrue(RedactionSafety.protections(in: c.project).contains { $0.originID == origin && $0.sources.contains { $0.contains(time(6)) } })
        return (c, protected, mask)
    }

    private func assertTail(_ c: ProjectCoordinator, file: StaticString = #filePath, line: UInt = #line) {
        let tail = RedactionSafety.protections(in: c.project).filter { $0.sources.contains { $0.contains(time(6)) } }
        XCTAssertFalse(tail.isEmpty, "source 6 remains durable after its picture was cut away", file: file, line: line)
        XCTAssertTrue(tail.allSatisfy { $0.effect.type == "blur" && $0.effect.params["radius"]?.number == 48 },
                      "the cut tail keeps its original blur strength", file: file, line: line)
    }

    private func disable(_ mask: String) -> EditCommand {
        .updateClip(clipID: mask, patch: .object(["enabled": .bool(false)]))
    }

    private func weaken(_ mask: String, in c: ProjectCoordinator) throws -> EditCommand {
        let effect = try XCTUnwrap(c.project.clip(mask)?.video?.redactionEffectID)
        return .updateEffect(clipID: mask, effectID: effect, patch: .object(["params": .object(["radius": .number(12)])]))
    }

    private func reinsert() -> EditCommand {
        .insertClip(trackID: "trk_screen", clip: Clip(id: "clip_reused_tail", content: .media(mediaID: "med_screen"),
                    start: time(30), duration: time(1), sourceStart: time(6)))
    }

    func testCopyTimingCannotAdoptATrimmedOrBladedTailFromTheSameRequest() throws {
        for cut in Cut.allCases {
            for timing in Timing.allCases {
                let (c, _, mask) = try ready(cut)
                _ = try applyOrRefuse([timing.command(mask)], to: c)
                XCTAssertFalse(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(time(6)) }, "\(cut), \(timing)")
                assertTail(c)
            }
        }
    }

    func testDisablingAfterCopyTimingKeepsTheSameRequestsCutTail() throws {
        for cut in Cut.allCases {
            for timing in Timing.allCases {
                let (c, _, mask) = try ready(cut)
                _ = try applyOrRefuse([timing.command(mask)], to: c)
                try commit(c, [disable(mask)])
                assertTail(c)
                XCTAssertFalse(try applyOrRefuse([reinsert()], to: c), "\(cut), \(timing): private source 6 must not reinsert sharp")
            }
        }
    }

    func testWeakeningAfterCopyTimingKeepsTheCutTailsOriginalStrength() throws {
        for cut in Cut.allCases {
            for timing in Timing.allCases {
                let (c, _, mask) = try ready(cut)
                _ = try applyOrRefuse([timing.command(mask)], to: c)
                try commit(c, [weaken(mask, in: c)])
                assertTail(c)
            }
        }
    }

    func testADeferredBatchCannotLaunderTimingIntoControlOfTheCutTail() throws {
        for cut in Cut.allCases {
            for timing in Timing.allCases {
                for disabled in [false, true] {
                    let (c, _, mask) = try ready(cut)
                    let control = disabled ? disable(mask) : try weaken(mask, in: c)
                    _ = try applyOrRefuse([timing.command(mask), control], to: c)
                    assertTail(c)
                }
            }
        }
    }

    func testADeferredBatchCannotUnredactAndReinsertTheCutTail() throws {
        for cut in Cut.allCases {
            for timing in Timing.allCases {
                let (c, _, mask) = try ready(cut)
                XCTAssertFalse(try applyOrRefuse([timing.command(mask), disable(mask), reinsert()], to: c))
                assertTail(c)
            }
        }
    }

    func testReloadCannotGiveAnEditedCopyControlOfTheCutTail() throws {
        for cut in Cut.allCases {
            for timing in Timing.allCases {
                let (c, _, mask) = try ready(cut)
                _ = try applyOrRefuse([timing.command(mask)], to: c)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-ownership-\(UUID().uuidString).tandem")
                defer { try? FileManager.default.removeItem(at: url) }
                try ProjectFile.save(c.project, revision: c.revision, to: url)
                let loaded = ProjectCoordinator(project: try ProjectFile.load(from: url).project)
                try commit(loaded, [disable(mask)])
                assertTail(loaded)
                XCTAssertFalse(try applyOrRefuse([reinsert()], to: loaded))
            }
        }
    }

    func testUnlinkingCannotLetACopyClaimItsRequestsHistoricalTail() throws {
        for cut in Cut.allCases {
            for timing in Timing.allCases {
                let (c, _, mask) = try ready(cut)
                try commit(c, [.unlink(clipIDs: [mask])])
                _ = try applyOrRefuse([timing.command(mask), disable(mask)], to: c)
                assertTail(c)
                XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
            }
        }
    }

    func testReturningTheActualPictureRestoresItsOwnRequestsControllableSelection() throws {
        for cut in Cut.allCases {
            let (c, picture, mask) = try ready(cut)
            try commit(c, [.trim(clipID: picture, edge: .end, to: time(10))])
            XCTAssertTrue(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(time(6)) })
            try commit(c, [disable(mask)])
            XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
        }
    }

    func testPictureOnlyTimingStillRestoresTheFramesThatPictureShows() throws {
        for speed in [false, true] {
            let (c, picture, mask) = try ready(.trim)
            let edit = speed ? EditCommand.updateClip(clipID: picture, patch: .object(["speed": .number(2)]))
                : .slip(clipID: picture, delta: time(5), includeLinked: false)
            try commit(c, [edit])
            XCTAssertTrue(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(time(6)) })
            assertTail(c)
        }
    }

    private func legacy(version: Int, disjoint: Bool, regionRecorded: Bool) -> Project {
        let item = MediaItem(id: "med_screen", path: "screen.mov", kind: .video, role: .screen,
                             duration: time(20), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let picture = Clip(id: "clip_screen", content: .media(mediaID: item.id), start: .zero,
                           duration: time(5), sourceStart: time(disjoint ? 12 : 0), linkGroup: "lnk_legacy")
        let region = Rect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)
        let video = VideoProperties(crop: Crop(left: 0.2, top: 0.2, right: 0.4, bottom: 0.6),
            effects: [Effect(id: "fx_legacy", type: "blur", params: ["radius": .number(48)])],
            redaction: regionRecorded ? region : nil)
        let copy = Clip(id: "clip_privacy", name: "Privacy", content: .media(mediaID: item.id),
                        start: .zero, duration: time(10), linkGroup: "lnk_legacy", video: video)
        var p = Project(name: "Legacy source intent", media: [item], videoTracks: [
            Track(id: "trk_screen", kind: .video, name: "Screen", clips: [picture]),
            Track(id: "trk_privacy", kind: .video, name: "Privacy (Screen)", clips: [copy])
        ])
        p.schemaVersion = version
        return p
    }

    private func reload(_ p: Project) throws -> Project {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-legacy-\(UUID().uuidString).tandem")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectFile.save(p, revision: 0, to: url)
        return try ProjectFile.load(from: url).project
    }

    func testMigrationKeepsAnUninitializedCopiesFullIntentBeforeBoundingItsControls() throws {
        for version in [1, 2] {
            for disjoint in [false, true] {
                for regionRecorded in [false, true] {
                    let migrated = try ProjectFile.migrate(legacy(version: version, disjoint: disjoint, regionRecorded: regionRecorded))
                    let c = ProjectCoordinator(project: try reload(migrated))
                    assertTail(c)
                    let owned = try XCTUnwrap(c.project.clip("clip_privacy")?.video?.redactionSources)
                    XCTAssertFalse(owned.contains { $0.contains(time(6)) }, "migration must retain history without handing it to the visible copy")
                    XCTAssertFalse(try applyOrRefuse([reinsert()], to: c), "schema \(version), disjoint \(disjoint), region \(regionRecorded)")
                }
            }
        }
    }

    func testReadOnlyProtectionCaptureAlsoKeepsTheFullLegacySelection() throws {
        for version in [1, 2] {
            for disjoint in [false, true] {
                let p = legacy(version: version, disjoint: disjoint, regionRecorded: true)
                let policies = RedactionSafety.protections(in: p)
                XCTAssertTrue(policies.contains { $0.sources.contains { $0.contains(time(6)) } })
                XCTAssertNil(p.sourceRedactions, "a read-only capture must leave the caller's project unchanged")
            }
        }
    }

    func testMigratedCopyControlsCannotReleaseOrWeakenItsCutAwayLegacyIntent() throws {
        for version in [1, 2] {
            for disjoint in [false, true] {
                for disabled in [false, true] {
                    let migrated = try ProjectFile.migrate(legacy(version: version, disjoint: disjoint, regionRecorded: true))
                    let c = ProjectCoordinator(project: try reload(migrated))
                    try commit(c, [disabled ? disable("clip_privacy") : try weaken("clip_privacy", in: c)])
                    assertTail(c)
                    let loaded = ProjectCoordinator(project: try reload(c.project))
                    assertTail(loaded)
                    XCTAssertFalse(try applyOrRefuse([reinsert()], to: loaded))
                }
            }
        }
    }

    func testMigratedCopiesCannotRepeatInitialCaptureThroughTimingEdits() throws {
        for version in [1, 2] {
            for timing in Timing.allCases {
                let migrated = try ProjectFile.migrate(legacy(version: version, disjoint: false, regionRecorded: true))
                let c = ProjectCoordinator(project: try reload(migrated))
                _ = try applyOrRefuse([timing.command("clip_privacy"), disable("clip_privacy")], to: c)
                assertTail(c)
                XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
            }
        }
    }

    func testLinksCannotGiveAnUnseenDummyControlOfTheCutTail() throws {
        for hidden in [false, true] {
            for control in 0..<3 {
                let (c, _, mask) = try ready(.trim)
                let track = hidden ? "trk_hidden_dummy" : "trk_screen"
                if hidden {
                    try commit(c, [.addTrack(kind: .video, name: "Hidden dummy", id: track),
                        .updateTrack(trackID: track, patch: .object(["hidden": .bool(true)]))])
                }
                let dummy = Clip(id: "clip_dummy", content: .media(mediaID: "med_screen"), start: time(5),
                                 duration: time(5), sourceStart: time(5), enabled: hidden)
                try commit(c, [.insertClip(trackID: track, clip: dummy)])
                guard try applyOrRefuse([.link(clipIDs: [mask, dummy.id])], to: c),
                      try applyOrRefuse([.updateClip(clipID: mask, patch: .object(["duration": .number(10)]))], to: c) else {
                    assertTail(c)
                    XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
                    continue
                }
                try commit(c, [.blade(at: time(5), clipIDs: [mask])])
                let right = try XCTUnwrap(c.project.videoTracks.first(where: \.isPrivacy)?.clips.first(where: { $0.start == time(5) }))
                let command: EditCommand
                switch control {
                case 0: command = disable(right.id)
                case 1: command = .removeClips(clipIDs: [right.id], includeLinked: false)
                default: command = try weaken(right.id, in: c)
                }
                _ = try applyOrRefuse([command], to: c)
                assertTail(c)
                XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
            }
        }
    }

    func testRegroupingTheActualPartnerStillAllowsItsHistoricalSelectionToReturn() throws {
        let (c, picture, mask) = try ready(.trim)
        try commit(c, [.link(clipIDs: [picture, mask])])
        try commit(c, [.trim(clipID: picture, edge: .end, to: time(10))])
        XCTAssertTrue(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(time(6)) })
        try commit(c, [disable(mask)])
        XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
    }

    func testAClipPatchCannotReplaceAnExistingPrivacyPicturesPartner() throws {
        let (c, _, mask) = try ready(.trim)
        let dummy = Clip(id: "clip_dummy", content: .media(mediaID: "med_screen"), start: time(5),
                         duration: time(5), sourceStart: time(5), enabled: false)
        try commit(c, [.insertClip(trackID: "trk_screen", clip: dummy)])
        let other = try XCTUnwrap(c.project.track("trk_screen")?.clips.first(where: { $0.start == time(10) }))
        try commit(c, [.link(clipIDs: [dummy.id, other.id])])
        let group = try XCTUnwrap(c.project.clip(dummy.id)?.linkGroup)
        XCTAssertFalse(try applyOrRefuse([.updateClip(clipID: mask, patch: .object(["linkGroup": .string(group)]))], to: c))
        assertTail(c)
    }

    func testADeferredBatchCannotReassignPrivacyOwnershipToADummy() throws {
        let (c, _, mask) = try ready(.trim)
        let dummy = Clip(id: "clip_dummy", content: .media(mediaID: "med_screen"), start: time(5),
                         duration: time(5), sourceStart: time(5), enabled: false)
        try commit(c, [.insertClip(trackID: "trk_screen", clip: dummy)])
        XCTAssertFalse(try applyOrRefuse([.link(clipIDs: [mask, dummy.id]),
            .updateClip(clipID: mask, patch: .object(["duration": .number(10)])), disable(mask), reinsert()], to: c))
        assertTail(c)
    }

    func testAnOlderMultiPartnerGroupCannotGrantHistoricalOwnershipOnReload() throws {
        let (base, _, mask) = try ready(.trim)
        var p = base.project
        let dummy = Clip(id: "clip_dummy", content: .media(mediaID: "med_screen"), start: time(5),
                         duration: time(5), sourceStart: time(5), enabled: false, linkGroup: p.clip(mask)?.linkGroup)
        p.videoTracks[0].clips.append(dummy)
        let c = ProjectCoordinator(project: try reload(p))
        _ = try applyOrRefuse([.updateClip(clipID: mask, patch: .object(["duration": .number(10)]))], to: c)
        XCTAssertFalse(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(time(6)) })
        try commit(c, [disable(mask)])
        assertTail(c)
        XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
    }

    func testAnAmbiguousLegacyPartnerCannotAdoptTheTailThroughAFreeze() throws {
        let (base, _, mask) = try ready(.trim)
        var p = base.project
        let dummy = Clip(id: "clip_dummy", content: .media(mediaID: "med_screen"), start: time(5),
                         duration: time(5), sourceStart: time(5), enabled: false, linkGroup: p.clip(mask)?.linkGroup)
        p.videoTracks[0].clips.append(dummy)
        let c = ProjectCoordinator(project: try reload(p))
        _ = try applyOrRefuse([.updateClip(clipID: mask, patch: .object(["duration": .number(10)]))], to: c)
        _ = try applyOrRefuse([.updateClip(clipID: dummy.id, patch: .object(["sourceStart": .number(6), "freezeFrame": .bool(true)]))], to: c)
        try commit(c, [disable(mask)])
        assertTail(c)
    }

    func testAnAlreadyFrozenLegacyDummyCannotGrantHistoricalOwnership() throws {
        let (base, _, mask) = try ready(.trim)
        var p = base.project
        let dummy = Clip(id: "clip_dummy", content: .media(mediaID: "med_screen"), start: time(5),
                         duration: time(5), sourceStart: time(6), freezeFrame: true,
                         enabled: false, linkGroup: p.clip(mask)?.linkGroup)
        p.videoTracks[0].clips.append(dummy)
        let c = ProjectCoordinator(project: try reload(p))
        _ = try applyOrRefuse([.updateClip(clipID: mask, patch: .object(["duration": .number(10)]))], to: c)
        XCTAssertFalse(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(time(6)) })
        try commit(c, [disable(mask)])
        assertTail(c)
    }

    func testAutomaticallyHiddenActualOwnersStillControlTheirCurrentSelection() throws {
        let (c, picture, mask) = try ready(.trim)
        try commit(c, [.updateClip(clipID: picture, patch: .object(["enabled": .bool(false)]))])
        try commit(c, [.trim(clipID: picture, edge: .end, to: time(10))])
        XCTAssertFalse(c.project.clip(mask)!.enabled)
        XCTAssertEqual(c.project.clip(mask)?.video?.redactionVisibility, .followingPicture)
        XCTAssertTrue(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(time(6)) })
        try commit(c, [weaken(mask, in: c)])
        let tail = RedactionSafety.protections(in: c.project).filter { $0.sources.contains { $0.contains(time(6)) } }
        XCTAssertFalse(tail.isEmpty)
        XCTAssertTrue(tail.allSatisfy { $0.effect.params["radius"]?.number == 12 })
    }

    func testExplicitControlsUseTheActualPicturesSelectionAtThatCommandInABatch() throws {
        for disabled in [false, true] {
            for batched in [false, true] {
                let (c, picture, mask) = try ready(.trim)
                let visit = EditCommand.updateClip(clipID: picture, patch: .object(["sourceStart": .number(5)]))
                let control = disabled ? disable(mask) : try weaken(mask, in: c)
                let restore = EditCommand.updateClip(clipID: picture, patch: .object(["sourceStart": .number(0)]))
                let enable = EditCommand.updateClip(clipID: mask, patch: .object(["enabled": .bool(true), "sourceStart": .number(0)]))
                let effect = try XCTUnwrap(c.project.clip(mask)?.video?.redactionEffectID)
                let strengthen = EditCommand.updateEffect(clipID: mask, effectID: effect,
                    patch: .object(["params": .object(["radius": .number(48)])]))
                if batched {
                    try commit(c, [visit, control, restore, enable, strengthen])
                } else {
                    try commit(c, [visit])
                    try commit(c, [control])
                    try commit(c, [restore, enable, strengthen])
                }
                let policies = RedactionSafety.protections(in: c.project)
                XCTAssertTrue(policies.contains { $0.effect.params["radius"]?.number == 48 && $0.sources.contains { $0.contains(time(1)) } })
                let tail = policies.filter { $0.sources.contains { $0.contains(time(6)) } }
                if disabled {
                    XCTAssertTrue(tail.isEmpty, "explicitly disabling while the actual picture shows source 6 releases that selection")
                    XCTAssertTrue(try applyOrRefuse([reinsert()], to: c))
                } else {
                    XCTAssertFalse(tail.isEmpty)
                    XCTAssertTrue(tail.allSatisfy { $0.effect.params["radius"]?.number == 12 },
                                  "the later reset acts on source 0–5; the explicitly weakened tail remains at 12")
                }
            }
        }
    }

    private func ambiguous(hiddenDummy: Bool, emptyOwnership: Bool = false, duplicateOwnership: Bool = false) throws -> (ProjectCoordinator, String, String, String) {
        let (base, picture, mask) = try ready(.trim)
        var p = base.project
        let dummy = Clip(id: "clip_dummy", content: .media(mediaID: "med_screen"),
                         start: time(duplicateOwnership ? 0 : 5), duration: time(5),
                         sourceStart: time(duplicateOwnership ? 0 : 5), enabled: hiddenDummy,
                         linkGroup: p.clip(mask)?.linkGroup)
        p.videoTracks.append(Track(id: "trk_dummy", kind: .video, name: "Dummy", clips: [dummy], hidden: hiddenDummy))
        if emptyOwnership {
            let (track, index) = try XCTUnwrap(p.location(ofClip: mask))
            p[track].clips[index].video?.redactionSources = []
        }
        return (ProjectCoordinator(project: try reload(p)), picture, mask, dummy.id)
    }

    func testNarrowingALegacyGroupCannotPromoteAnUnownedDummy() throws {
        for hiddenDummy in [false, true] {
            for remove in [false, true] {
                for frozen in [false, true] {
                    for disabled in [false, true] {
                        let (base, picture, mask, dummy) = try ambiguous(hiddenDummy: hiddenDummy)
                        // Load the already-extended state so this still tests
                        // narrowing after copy timing edits are refused.
                        var p = base.project
                        let (track, index) = try XCTUnwrap(p.location(ofClip: mask))
                        p[track].clips[index].duration = time(10)
                        let c = ProjectCoordinator(project: try reload(p))
                        try commit(c, [.updateClip(clipID: picture, patch: .object(["enabled": .bool(false)]))])
                        let narrow = remove ? EditCommand.removeClips(clipIDs: [picture], includeLinked: false) : .unlink(clipIDs: [picture])
                        guard try applyOrRefuse([narrow], to: c) else {
                            assertTail(c)
                            XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
                            continue
                        }
                        let change = EditCommand.updateClip(clipID: dummy,
                            patch: .object(["sourceStart": .number(6), "freezeFrame": .bool(frozen)]))
                        _ = try applyOrRefuse([change], to: c)
                        _ = try applyOrRefuse([disabled ? disable(mask) : try weaken(mask, in: c)], to: c)
                        assertTail(c)
                        XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
                    }
                }
            }
        }
    }

    func testDroppingADummyKeepsTheUniquelyIdentifiedActualOwner() throws {
        for hiddenDummy in [false, true] {
            for hiddenPicture in [false, true] {
                let (c, picture, mask, dummy) = try ambiguous(hiddenDummy: hiddenDummy)
                if hiddenPicture {
                    try commit(c, [.updateClip(clipID: picture, patch: .object(["enabled": .bool(false)]))])
                }
                try commit(c, [.unlink(clipIDs: [dummy])])
                try commit(c, [.trim(clipID: picture, edge: .end, to: time(10))])
                XCTAssertTrue(c.project.clip(mask)!.video!.redactionSources!.contains { $0.contains(time(6)) })
                try commit(c, [disable(mask)])
                XCTAssertTrue(RedactionSafety.protections(in: c.project).isEmpty)
            }
        }
    }

    func testEmptyOrAmbiguousOwnershipNeedsAllPartnersUnlinked() throws {
        for empty in [false, true] {
            let (c, picture, mask, dummy) = try ambiguous(hiddenDummy: true,
                emptyOwnership: empty, duplicateOwnership: !empty)
            XCTAssertFalse(try applyOrRefuse([.unlink(clipIDs: [dummy])], to: c))
            try commit(c, [.unlink(clipIDs: [picture, dummy])])
            XCTAssertNil(c.project.clip(mask)?.linkGroup)
            assertTail(c)
            _ = try applyOrRefuse([.updateClip(clipID: mask, patch: .object(["speed": .number(2)])), disable(mask)], to: c)
            assertTail(c)
            XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
        }
    }

    func testAnAmbiguousOwnerCannotBeDiscardedWhileOtherPartnersRemain() throws {
        let (base, picture, mask, _) = try ambiguous(hiddenDummy: false)
        var p = base.project
        let (source, index) = try XCTUnwrap(p.location(ofClip: picture))
        p[source].clips[index].enabled = false
        let echo = Clip(id: "clip_echo", content: .media(mediaID: "med_screen"), start: .zero,
                        duration: time(5), enabled: false, linkGroup: p.clip(mask)?.linkGroup)
        p.videoTracks[p.videoTracks.count - 1].clips.append(echo)
        let c = ProjectCoordinator(project: try reload(p))
        XCTAssertFalse(try applyOrRefuse([.removeClips(clipIDs: [picture], includeLinked: false)], to: c))
        assertTail(c)
    }

    private func offsetDummy(hidden: Bool) throws -> (ProjectCoordinator, String, String, String) {
        let (base, picture, mask, dummy) = try ambiguous(hiddenDummy: hidden)
        var p = base.project
        let (track, index) = try XCTUnwrap(p.location(ofClip: dummy))
        p[track].clips[index].sourceStart = .zero
        let c = ProjectCoordinator(project: try reload(p))
        try commit(c, [.updateClip(clipID: picture, patch: .object(["enabled": .bool(false)]))])
        return (c, picture, mask, dummy)
    }

    func testAnAmbiguousCopyCannotMoveItsOwnershipProofOntoADummy() throws {
        for hidden in [false, true] {
            for move in [false, true] {
                for disabled in [false, true] {
                    let (c, picture, mask, dummy) = try offsetDummy(hidden: hidden)
                    let shift = move ? EditCommand.moveClips(clipIDs: [mask], delta: time(5), includeLinked: false)
                        : .updateClip(clipID: mask, patch: .object(["start": .number(5)]))
                    guard try applyOrRefuse([shift], to: c) else {
                        assertTail(c)
                        XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
                        continue
                    }
                    try commit(c, [.unlink(clipIDs: [picture])])
                    try commit(c, [.updateClip(clipID: dummy, patch: .object(["sourceStart": .number(5)]))])
                    try commit(c, [disabled ? disable(mask) : try weaken(mask, in: c)])
                    assertTail(c)
                    XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
                }
            }
        }
    }

    func testCopyTimingEditsAreRefusedWhileItsPictureOwnershipIsAmbiguous() throws {
        let edits: [(String) -> EditCommand] = [
            { .updateClip(clipID: $0, patch: .object(["start": .number(5)])) },
            { .moveClips(clipIDs: [$0], delta: self.time(5), includeLinked: false) },
            { .slip(clipID: $0, delta: self.time(5), includeLinked: false) },
            { .updateClip(clipID: $0, patch: .object(["sourceStart": .number(5)])) },
            { .updateClip(clipID: $0, patch: .object(["duration": .number(10)])) },
            { .updateClip(clipID: $0, patch: .object(["speed": .number(2)])) },
            { .setSpeed(clipID: $0, speed: 2, includeLinked: false) },
            { .updateClip(clipID: $0, patch: .object(["freezeFrame": .bool(true)])) },
            { .updateClip(clipID: $0, patch: .object(["holdEdges": .bool(true)])) },
            { .holdFrame(clipID: $0, range: TimeRange(start: self.time(1), end: self.time(2))) }
        ]
        for edit in edits {
            let (c, _, mask, _) = try offsetDummy(hidden: false)
            XCTAssertFalse(try applyOrRefuse([edit(mask)], to: c))
            assertTail(c)
        }
    }

    func testAPrivacyCopyCannotDetourThroughAnAudioTrack() throws {
        // Round-2 review r4: with media that has sound, moving only the mask
        // to an audio track and back skipped the ownership guard.
        for shift in [false, true] {
            let (base, picture, mask, dummy) = try offsetDummy(hidden: false)
            var p = base.project
            let mi = try XCTUnwrap(p.media.firstIndex { $0.id == "med_screen" })
            p.media[mi].hasAudio = true
            p.audioTracks.append(Track(id: "trk_detour", kind: .audio, name: "Detour", clips: []))
            let c = ProjectCoordinator(project: try reload(p))
            let home = try XCTUnwrap(c.project.location(ofClip: mask)).track
            let away = EditCommand.moveClips(clipIDs: [mask], delta: shift ? time(5) : nil, toTrackID: "trk_detour", includeLinked: false)
            XCTAssertFalse(try applyOrRefuse([away], to: c))
            XCTAssertFalse(try applyOrRefuse([away, .moveClips(clipIDs: [mask], toTrackID: c.project[home].id, includeLinked: false)], to: c))
            XCTAssertTrue(c.project.audioTracks.flatMap(\.clips).isEmpty)
            _ = try applyOrRefuse([.unlink(clipIDs: [picture])], to: c)
            _ = try applyOrRefuse([.updateClip(clipID: dummy, patch: .object(["sourceStart": .number(5)]))], to: c)
            _ = try applyOrRefuse([disable(mask)], to: c)
            assertTail(c)
            XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
        }
    }

    func testALoadedPrivacyCopyOnAnAudioTrackCannotReturnToVideo() throws {
        let (base, _, mask, _) = try offsetDummy(hidden: false)
        var p = base.project
        let mi = try XCTUnwrap(p.media.firstIndex { $0.id == "med_screen" })
        p.media[mi].hasAudio = true
        let (home, index) = try XCTUnwrap(p.location(ofClip: mask))
        var copy = p[home].clips.remove(at: index)
        copy.start = time(5)
        p.audioTracks.append(Track(id: "trk_detour", kind: .audio, name: "Detour", clips: [copy]))
        let c = ProjectCoordinator(project: p)
        XCTAssertFalse(try applyOrRefuse([.moveClips(clipIDs: [mask], delta: time(-5), toTrackID: p[home].id, includeLinked: false)], to: c))
    }

    func testAnOverwriteThatSplitsACopyIsJudgedByTheCopyItCameFrom() throws {
        // Round-2 review r4 (Gemini): one overwrite cleared the mask in two
        // places, leaving only a new right-hand piece linked to a dummy.
        let (base, picture, mask, _) = try ambiguous(hiddenDummy: false)
        var p = base.project
        let (track, index) = try XCTUnwrap(p.location(ofClip: mask))
        p[track].clips[index].duration = time(10)
        let privacy = p[track].name
        let c = ProjectCoordinator(project: try reload(p))
        try commit(c, [.updateClip(clipID: picture, patch: .object(["enabled": .bool(false)]))])
        func solid(_ name: String, _ at: Double, _ length: Double) -> TemplateClip {
            TemplateClip(track: name, offset: time(at), clip: Clip(id: "clip_solid", content: .solid(color: .black), start: .zero, duration: time(length)))
        }
        let template = Template(id: "tpl_split", name: "Split", duration: time(7),
                                clips: [solid(privacy, 6, 1), solid(privacy, 0, 6), solid("Dummy", 6, 1)])
        if try applyOrRefuse([.insertTemplate(template: template, at: .zero, mode: .overwrite)], to: c) {
            let right = try XCTUnwrap(c.project[track].clips.first { $0.isRedaction && $0.start == time(7) })
            let dummyRight = try XCTUnwrap(c.project.videoTracks.first { $0.name == "Dummy" }?.clips.first { $0.start == time(7) })
            _ = try applyOrRefuse([.updateClip(clipID: dummyRight.id, patch: .object(["sourceStart": .number(5), "duration": .number(5)]))], to: c)
            _ = try applyOrRefuse([disable(right.id)], to: c)
        }
        assertTail(c)
        XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
    }

    func testABatchCannotChangeAFrameRateWhileItRemembersWiderSources() throws {
        // Round-2 review r4 (Gemini): frame timing was only checked at batch
        // end, so a frozen picture could remember a 20 s "frame" mid-batch.
        let (c, protected, mask) = try ready(.trim)
        try commit(c, [.updateClip(clipID: protected, patch: .object(["freezeFrame": .bool(true)]))])
        let slow = EditCommand.updateMedia(mediaID: "med_screen", patch: .object(["frameRate": .object(["numerator": .number(1), "denominator": .number(20)])]))
        let back = EditCommand.updateMedia(mediaID: "med_screen", patch: .object(["frameRate": .object(["numerator": .number(30), "denominator": .number(1)])]))
        XCTAssertFalse(try applyOrRefuse([slow, disable(mask), back, .updateClip(clipID: mask, patch: .object(["enabled": .bool(true)]))], to: c))
        assertTail(c)
        XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
    }

    func testABrokenAliasCannotSwitchOffTheFrameRateCheckMidBatch() throws {
        // Round-2 review r5 (Codex): an alias with a mismatched mapping made
        // the batch's earlier state invalid, which skipped the per-command check.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("screen".utf8).write(to: folder.appendingPathComponent("screen.mov"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("alias.mov").path, withDestinationPath: "screen.mov")
        let (start, protected, mask) = try ready(.trim)
        let c = ProjectCoordinator(project: start.project, sourceFolder: folder)
        try commit(c, [.updateClip(clipID: protected, patch: .object(["freezeFrame": .bool(true)]))])
        let alias = MediaItem(id: "med_alias", path: "alias.mov", kind: .video, role: .screen,
                              duration: time(20), frameRate: FrameRate(60), width: 1280, height: 720, hasVideo: true)
        let slow = EditCommand.updateMedia(mediaID: "med_screen", patch: .object(["frameRate": .object(["numerator": .number(1), "denominator": .number(20)])]))
        let back = EditCommand.updateMedia(mediaID: "med_screen", patch: .object(["frameRate": .object(["numerator": .number(30), "denominator": .number(1)])]))
        let batch: [EditCommand] = [.addMedia(item: alias), slow, disable(mask), back, .removeMedia(mediaID: alias.id),
                                    .updateClip(clipID: mask, patch: .object(["enabled": .bool(true)]))]
        XCTAssertFalse(try applyOrRefuse(batch, to: c))
        assertTail(c)
        XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
    }

    func testAProjectFrameRateCannotRetimeAProtectedFileWithoutItsOwnRate() throws {
        // Round-2 review r5 (Codex): a file with no frame rate is read on the
        // project's clock, which the mapping check didn't record.
        let (c, protected, mask) = try ready(.trim, frameRate: nil)
        try commit(c, [.updateClip(clipID: protected, patch: .object(["freezeFrame": .bool(true)]))])
        let slow = EditCommand.updateSettings(patch: .object(["frameRate": .object(["numerator": .number(1), "denominator": .number(20)])]))
        let back = EditCommand.updateSettings(patch: .object(["frameRate": .object(["numerator": .number(30), "denominator": .number(1)])]))
        XCTAssertFalse(try applyOrRefuse([slow, disable(mask), back, .updateClip(clipID: mask, patch: .object(["enabled": .bool(true)]))], to: c))
        assertTail(c)
        XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
    }

    func testAProjectFrameRateCannotMoveAHeldFrameOntoTheCutTail() throws {
        // Round-2 review r5 (Gemini): held frames snap to the project grid
        // even for a file with its own rate.
        let (c, protected, mask) = try ready(.trim)
        try commit(c, [.holdFrame(clipID: protected, range: TimeRange(start: time(4), end: time(4.5)))])
        let slow = EditCommand.updateSettings(patch: .object(["frameRate": .object(["numerator": .number(1), "denominator": .number(10)])]))
        let back = EditCommand.updateSettings(patch: .object(["frameRate": .object(["numerator": .number(30), "denominator": .number(1)])]))
        XCTAssertFalse(try applyOrRefuse([slow], to: c))
        XCTAssertFalse(try applyOrRefuse([slow, disable(mask), back, .updateClip(clipID: mask, patch: .object(["enabled": .bool(true)]))], to: c))
        assertTail(c)
        XCTAssertFalse(try applyOrRefuse([reinsert()], to: c))
    }
}
