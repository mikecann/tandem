import XCTest
@testable import TandemCore

/// What the review layer takes from an agent's batch: the clips it added
/// and changed, by ID, and the places it took something out, but not the
/// clips that only rode along with a ripple.
final class ReviewDiffTests: XCTestCase {
    /// Runs a batch as Claude and returns what it did.
    private func agent(_ coordinator: ProjectCoordinator, _ commands: [EditCommand]) throws -> ReviewChanges {
        let before = coordinator.project
        try coordinator.apply(EditBatch(label: "Agent edit", author: "claude", commands: commands))
        return ReviewDiff.between(before, coordinator.project)
    }

    func testPlacedBRollIsAddedAndNothingElse() throws {
        let (_, c) = try Fixture.edited()
        let changes = try agent(c, [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        let shot = try XCTUnwrap(c.clips("B-roll").first { $0.start == t(40) })
        XCTAssertEqual(changes.added, [shot.id])
        XCTAssertEqual(changes.changed, [])
        XCTAssertEqual(changes.removals, [])
    }

    func testAChangedClipIsFound() throws {
        let (f, c) = try Fixture.edited()
        let music = f.clips("Music")[0]
        let changes = try agent(c, [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-35)])]))])
        XCTAssertEqual(changes.changed, [music.id])
        XCTAssertEqual(changes.added, [])
        XCTAssertNotNil(changes.before[music.id], "what it was, to spot an undo")
    }

    /// Tightening a pause cuts the take and moves everything after it up.
    /// Only the join is news: not the halves of the cut clips, the B-roll
    /// that moved with its words, or the music bed that lost a second from
    /// its end.
    func testARippleDeleteMarksTheJoinAndNothingThatMoved() throws {
        let (f, c) = try Fixture.edited()
        let changes = try agent(c, [.rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))])
        XCTAssertEqual(changes.added, [])
        XCTAssertEqual(changes.changed, [])
        XCTAssertEqual(Set(changes.removals.map(\.trackID)), Set(["Screen", "Camera", "Voice"].map { f.track($0).id }))
        for removal in changes.removals {
            XCTAssertEqual(removal.time, t(10))
            XCTAssertEqual(removal.duration, t(1))
            // Pinned to the clip after the join: the cut clip's right half.
            let anchor = try XCTUnwrap(c.project.clip(try XCTUnwrap(removal.anchorClipID)))
            XCTAssertEqual(anchor.start, t(10))
            XCTAssertEqual(removal.anchorEdge, .start)
            XCTAssertEqual(removal.offset, .zero)
        }
    }

    /// `tandem tighten` cuts several pauses in one batch, latest first:
    /// a mark at each join, where it is after all of them, and still
    /// nothing that only moved, not even the B-roll one of the pauses ran
    /// through.
    func testTighteningSeveralPausesMarksEachJoin() throws {
        let (f, c) = try Fixture.edited()
        let changes = try agent(c, [
            .rippleDeleteRange(range: TimeRange(start: t(40), end: t(41))),
            .rippleDeleteRange(range: TimeRange(start: t(20), end: t(20.5))),
            .rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))
        ])
        XCTAssertEqual(changes.added, [])
        XCTAssertEqual(changes.changed, [])
        let screen = changes.removals.filter { $0.trackID == f.track("Screen").id }
        XCTAssertEqual(screen.map(\.time), [t(10), t(19), t(38.5)])
        XCTAssertEqual(screen.map(\.duration), [t(1), t(0.5), t(1)])
        XCTAssertEqual(changes.removals.count, 9, "the three take tracks")
        for removal in changes.removals {
            XCTAssertEqual(removal.time(in: c.project), removal.time, "pinned at its join")
        }
    }

    /// A slip shows other media in the same place: a change, even on the
    /// take, and no join, since nothing got shorter.
    func testASlippedTakeClipIsChangedWithNoMark() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(30)))
        let second = c.clips("Screen")[1]
        let changes = try agent(c, [.slip(clipID: second.id, delta: t(-2))])
        XCTAssertEqual(Set(changes.changed), Set(c.project.linkedClipIDs(of: second.id)))
        XCTAssertEqual(changes.changed.count, 3, "the screen, the camera and its sound")
        XCTAssertEqual(changes.removals, [])
    }

    /// A pause cut where one take clip ends and the next begins takes from
    /// both, and still makes one mark a track.
    func testARippleDeleteAcrossACutMakesOneMarkATrack() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10.5)))
        let changes = try agent(c, [.rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))])
        XCTAssertEqual(changes.added, [])
        XCTAssertEqual(changes.changed, [])
        let screen = changes.removals.filter { $0.trackID == f.track("Screen").id }
        XCTAssertEqual(screen.count, 1)
        XCTAssertEqual(screen.first?.time, t(10))
        XCTAssertEqual(screen.first?.duration, t(1))
        XCTAssertEqual(screen.first?.from.count, 2)
    }

    func testOpeningTimeMovesThingsWithoutChangingThem() throws {
        let (_, c) = try Fixture.edited()
        let changes = try agent(c, [.insertTime(at: t(15), duration: t(2))])
        XCTAssertTrue(changes.isEmpty, "\(changes)")
    }

    func testBladingTheTakeIsNotAChange() throws {
        let (_, c) = try Fixture.edited()
        XCTAssertTrue(try agent(c, [.blade(at: t(12))]).isEmpty)
    }

    func testAMovedClipIsChanged() throws {
        let (f, c) = try Fixture.edited()
        let shot = f.clips("B-roll")[0]
        let changes = try agent(c, [.moveClips(clipIDs: [shot.id], delta: t(5), includeLinked: false)])
        XCTAssertEqual(changes.changed, [shot.id])
        XCTAssertEqual(changes.added, [])
        XCTAssertEqual(changes.removals, [])
    }

    func testTrimmingAClipIsAChange() throws {
        let (f, c) = try Fixture.edited()
        let shot = f.clips("B-roll")[0]
        let changes = try agent(c, [.trim(clipID: shot.id, edge: .end, to: t(24), ripple: false, includeLinked: false)])
        XCTAssertEqual(changes.changed, [shot.id])
        XCTAssertEqual(changes.removals, [])
    }

    /// Closing up the B-roll track only moves B-roll: a shot after the gap
    /// now plays over different words, so it has changed.
    func testRippleDeletingOnlyTheBRollMovesTheShotsAfterIt() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Second shot", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)))
        let shots = c.clips("B-roll")
        let changes = try agent(c, [.removeClips(clipIDs: [shots[0].id], ripple: true)])
        XCTAssertEqual(changes.changed, [shots[1].id])
        XCTAssertEqual(changes.removals.map(\.trackID), [f.track("B-roll").id])
        XCTAssertEqual(changes.removals.first?.time, t(20))
    }

    func testLiftingAClipLeavesAMarkWhereItWasPinnedToTheNextClip() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Second shot", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)))
        let shots = c.clips("B-roll")
        let changes = try agent(c, [.removeClips(clipIDs: [shots[0].id], ripple: false)])
        XCTAssertEqual(changes.removals.count, 1)
        let removal = changes.removals[0]
        XCTAssertEqual(removal.trackID, f.track("B-roll").id)
        XCTAssertEqual(removal.time, t(20))
        XCTAssertEqual(removal.duration, t(5))
        XCTAssertEqual(removal.anchorClipID, shots[1].id)
        XCTAssertEqual(removal.anchorEdge, .start)
        XCTAssertEqual(removal.offset, t(-20))
        XCTAssertEqual(removal.time(in: c.project), t(20))
        XCTAssertEqual(removal.from, [shots[0].id])
    }

    /// With nothing after it on the track, the mark stays with the clip
    /// before it.
    func testTheLastClipsMarkIsPinnedToTheOneBefore() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Second shot", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)))
        let shots = c.clips("B-roll")
        let removal = try XCTUnwrap(try agent(c, [.removeClips(clipIDs: [shots[1].id])]).removals.first)
        XCTAssertEqual(removal.anchorClipID, shots[0].id)
        XCTAssertEqual(removal.anchorEdge, .end)
        XCTAssertEqual(removal.offset, t(15))
    }

    /// Section cards that make room push the whole take along at the
    /// marker; the card is the only news.
    func testSectionCardsThatMakeRoomAreTheOnlyNews() throws {
        let (_, c) = try Fixture.edited()
        let changes = try agent(c, [.addSectionCards(mode: .insert)])
        let card = try XCTUnwrap(c.clips("Graphics").first)
        XCTAssertEqual(changes.added, [card.id])
        XCTAssertEqual(changes.changed, [])
        XCTAssertEqual(changes.removals, [])
    }

    /// A shot placed over another replaces it: the new shot shows that,
    /// with no mark for the one it replaced.
    func testAShotThatReplacesAnotherLeavesNoMark() throws {
        let (f, c) = try Fixture.edited()
        let old = f.clips("B-roll")[0]
        let changes = try agent(c, [.placeMedia(mediaIDs: ["med_broll"], at: t(20), sourceStart: t(4), duration: t(5), mode: .overwrite)])
        let shot = c.clips("B-roll")[0]
        XCTAssertNotEqual(shot.id, old.id)
        XCTAssertEqual(changes.added, [shot.id])
        XCTAssertEqual(changes.removals, [])
    }

    func testANewTransitionIsFound() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10)))
        let camera = c.clips("Camera")
        let changes = try agent(c, [.addTransition(trackID: f.track("Camera").id, transition: Transition(id: "tr_new", type: .dissolve, duration: t(0.5), fromClipID: camera[0].id, toClipID: camera[1].id))])
        XCTAssertEqual(changes.transitions, ["tr_new"])
        XCTAssertEqual(changes.changed, [])
    }

    func testANewLookChangesEveryClipOfTheFile() throws {
        let (f, c) = try Fixture.edited()
        let changes = try agent(c, [.updateMedia(mediaID: "med_camera", patch: .object(["look": .array([.object(["type": .string("vignette")])])]))])
        let cameraClips = Set(c.project.allTracks.flatMap(\.clips).filter { $0.mediaID == "med_camera" }.map(\.id))
        XCTAssertEqual(Set(changes.changed), cameraClips)
        XCTAssertEqual(cameraClips.count, 2, "the picture and its sound")
        XCTAssertFalse(changes.changed.contains(f.clips("Screen")[0].id))
    }

    // MARK: Joins

    /// Joining a through-edit plays exactly what the two clips did, so
    /// there's nothing to review: not the joined clip, and not the clip it
    /// took in.
    func testJoiningAThroughEditIsNotAChange() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        let changes = try agent(c, [.join(clipID: camera)])
        XCTAssertEqual(c.clips("Voice").count, 1, "the camera, screen and voice joined")
        XCTAssertTrue(changes.isEmpty, "\(changes)")
    }

    /// Every through-edit at once: the take, the music bed under it and a
    /// B-roll shot cut twice, so three pieces become one.
    func testJoiningEveryThroughEditIsNotAChange() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10)), .blade(at: t(22)), .blade(at: t(23)), .blade(at: t(45)))
        XCTAssertEqual(c.clips("B-roll").count, 3)
        let changes = try agent(c, [.joinThroughEdits()])
        for name in ["Screen", "Camera", "Voice", "Music", "B-roll"] {
            XCTAssertEqual(c.clips(name).count, 1, name)
        }
        XCTAssertTrue(changes.isEmpty, "\(changes)")
    }

    /// The same by hand: the clip after the cut lifted, and the one before
    /// it trimmed over where it was.
    func testJoiningByHandIsNotAChange() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        let next = c.clips("Camera")[1]
        let changes = try agent(c, [.removeClips(clipIDs: [next.id]), .trim(clipID: camera, edge: .end, to: next.end)])
        XCTAssertEqual(c.clips("Screen").count, 1)
        XCTAssertTrue(changes.isEmpty, "\(changes)")
    }

    /// A join by hand that loses something hasn't played the same: the
    /// voice's fade out at the end of the take went with the clip lifted.
    func testAJoinByHandThatLosesAFadeIsAChange() throws {
        let (f, c) = try Fixture.edited()
        let voice = f.clips("Voice")[0].id
        try c.run("Fade out", .updateClip(clipID: voice, patch: .object(["audio": .object(["fadeOut": .number(1)])])))
        try c.run("Cut", .blade(at: t(10), clipIDs: [voice]))
        let next = c.clips("Voice")[1]
        let changes = try agent(c, [.removeClips(clipIDs: [next.id]), .trim(clipID: voice, edge: .end, to: next.end)])
        XCTAssertEqual(changes.changed, [voice])
        XCTAssertEqual(changes.removals, [])
    }

    /// The case that prompted this: an agent joins the hundreds of
    /// through-edits ripple trims left in a take, in one command. Still
    /// nothing to review, and quickly worked out.
    func testJoiningHundredsOfThroughEditsIsNothingToReview() throws {
        var fixture = Fixture()
        let pieces = 1000
        let length = t(0.1)
        fixture.project.media[0].duration = t(200)
        fixture.project.media[1].duration = t(201)
        for (name, mediaID, offset) in [("Screen", "med_screen", t(0.5)), ("Camera", "med_camera", Time.zero), ("Voice", "med_camera", Time.zero)] {
            guard let location = fixture.project.location(ofTrack: fixture.track(name).id) else { return XCTFail(name) }
            fixture.project[location].clips = (0..<pieces).map { i in
                let start = Time(flicks: length.flicks * Int64(i))
                return Clip(id: "clip_\(name)_\(i)", content: .media(mediaID: mediaID), start: start, duration: length, sourceStart: start + offset, linkGroup: "lnk_\(i)")
            }
        }
        let c = ProjectCoordinator(project: fixture.project)
        let before = c.project
        try c.apply(EditBatch(label: "Join", author: "claude", commands: [.joinThroughEdits()]))
        XCTAssertEqual(c.clips("Voice").count, 1)
        let started = Date()
        let changes = ReviewDiff.between(before, c.project)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(changes.isEmpty, "\(changes.changed.count) changed, \(changes.removals.count) removals")
        XCTAssertLessThan(elapsed, 1, "\(pieces * 3) clips compared in \(elapsed) s")
    }

    /// A join in a batch that does more: only the rest is news.
    func testAJoinAlongsideOtherEditsRecordsOnlyThem() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        let music = f.clips("Music")[0]
        let changes = try agent(c, [
            .join(clipID: camera),
            .updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-35)])])),
            .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))
        ])
        XCTAssertEqual(changes.changed, [music.id])
        XCTAssertEqual(changes.added, [try XCTUnwrap(c.clips("B-roll").last).id])
        XCTAssertEqual(changes.removals, [])
    }

    /// Tightening a pause and joining the cut before it in one batch, in
    /// either order: the joined clip and the piece after the pause are the
    /// take as it was, so only the pause's join is news.
    func testTighteningAndJoiningInOneBatchMarksOnlyThePause() throws {
        for joinFirst in [false, true] {
            let (f, c) = try Fixture.edited()
            let camera = f.clips("Camera")[0].id
            try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
            let tighten = EditCommand.rippleDeleteRange(range: TimeRange(start: t(20), end: t(21)))
            let changes = try agent(c, joinFirst ? [.join(clipID: camera), tighten] : [tighten, .join(clipID: camera)])
            XCTAssertEqual(c.clips("Camera").map(\.start), [t(0), t(20)])
            XCTAssertEqual(changes.added, [], "join first: \(joinFirst)")
            XCTAssertEqual(changes.changed, [], "join first: \(joinFirst)")
            XCTAssertEqual(Set(changes.removals.map(\.trackID)), Set(["Screen", "Camera", "Voice"].map { f.track($0).id }), "join first: \(joinFirst)")
            for removal in changes.removals {
                XCTAssertEqual(removal.time, t(20), "join first: \(joinFirst)")
                XCTAssertEqual(removal.duration, t(1), "join first: \(joinFirst)")
            }
        }
    }
}

/// The log: only agents' batches, followed by clip ID through later edits.
final class ReviewLogTests: XCTestCase {
    /// Runs a batch and updates `log` the way the recorder does.
    @discardableResult
    private func run(_ c: ProjectCoordinator, _ log: inout ReviewLog, by author: String, _ commands: [EditCommand], label: String = "Edit") throws -> Int {
        let before = c.project
        let result = try c.apply(EditBatch(label: label, author: author, commands: commands))
        log.follow(from: before, to: c.project)
        log.record(label: label, author: author, revision: result.revision, before: before, after: c.project)
        log.prune(in: c.project, reverts: false)
        return result.revision
    }

    func testOnlyAgentsEditsAreRecorded() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "user", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        try run(c, &log, by: "", [.placeMedia(mediaIDs: ["med_broll"], at: t(44), duration: t(1))])
        try run(c, &log, by: "system", [.placeMedia(mediaIDs: ["med_broll"], at: t(46), duration: t(1))])
        XCTAssertTrue(log.isEmpty)
        let revision = try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(2))], label: "Add push")
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].label, "Add push")
        XCTAssertEqual(log.entries[0].author, "claude")
        XCTAssertEqual(log.entries[0].revision, revision)
        XCTAssertEqual(log.entries[0].added, [c.clips("B-roll").last!.id])
    }

    /// The highlight is on the clip's ID, so it stays with the clip when
    /// Mike tightens the take before it and then moves it.
    func testTheHighlightFollowsItsClipThroughARippleAndAMove() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        let shot = c.clips("B-roll").last!
        try run(c, &log, by: "user", [.rippleDeleteRange(range: TimeRange(start: t(5), end: t(7)))])
        XCTAssertEqual(c.project.clip(shot.id)?.start, t(38))
        try run(c, &log, by: "user", [.moveClips(clipIDs: [shot.id], delta: t(4), includeLinked: false)])
        XCTAssertEqual(c.project.clip(shot.id)?.start, t(42))
        XCTAssertEqual(log.entries.map(\.added), [[shot.id]])
    }

    func testCuttingAHighlightedClipHighlightsBothHalves() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(4))])
        let shot = c.clips("B-roll").last!
        try run(c, &log, by: "user", [.blade(at: t(42), clipIDs: [shot.id])])
        let halves = c.clips("B-roll").filter { $0.start >= t(40) }.map(\.id)
        XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(Set(log.entries[0].added), Set(halves))
    }

    /// Mike may only have nudged it: the agent's change still wants a look.
    func testMikeChangingAnAgentsClipKeepsTheHighlight() throws {
        let (f, c) = try Fixture.edited()
        var log = ReviewLog()
        let music = f.clips("Music")[0]
        try run(c, &log, by: "claude", [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-35)])]))])
        try run(c, &log, by: "user", [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-31)])]))])
        XCTAssertEqual(log.entries.map(\.changed), [[music.id]], "even back where it was, by hand")
    }

    func testDeletingAnAgentsClipDropsItsHighlight() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        try run(c, &log, by: "user", [.removeClips(clipIDs: [c.clips("B-roll").last!.id])])
        XCTAssertTrue(log.isEmpty)
    }

    /// A shot an agent added straight after another, carrying on its file,
    /// is in the clip it's joined onto, so that's highlighted now. The
    /// join itself adds nothing to review.
    func testJoiningAHighlightedClipOnHighlightsTheJoinedClip() throws {
        let (f, c) = try Fixture.edited()
        var log = ReviewLog()
        let shot = f.clips("B-roll")[0]
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(25), sourceStart: t(6), duration: t(3))], label: "Longer shot")
        let more = try XCTUnwrap(c.clips("B-roll").last)
        XCTAssertEqual(log.entries.map(\.clipIDs), [[more.id]])
        try run(c, &log, by: "claude", [.join(clipID: shot.id)], label: "Join")
        XCTAssertEqual(c.clips("B-roll").map(\.id), [shot.id], "joined")
        XCTAssertEqual(log.entries.map(\.label), ["Longer shot"])
        XCTAssertEqual(log.entries.map(\.clipIDs), [[shot.id]])
    }

    /// The other way round: the agent's clip that Mike's carries on from
    /// keeps its highlight when they're joined.
    func testJoiningOntoAHighlightedClipKeepsItHighlighted() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))], label: "Add push")
        let push = try XCTUnwrap(c.clips("B-roll").last)
        try run(c, &log, by: "user", [.placeMedia(mediaIDs: ["med_broll"], at: t(43), sourceStart: push.sourceEnd, duration: t(2))])
        XCTAssertEqual(c.clips("B-roll").count, 3)
        try run(c, &log, by: "claude", [.join(clipID: push.id)], label: "Join")
        XCTAssertEqual(c.clips("B-roll").map(\.id).last, push.id)
        XCTAssertEqual(c.project.clip(push.id)?.end, t(45), "joined")
        XCTAssertEqual(log.entries.map(\.label), ["Add push"])
        XCTAssertEqual(log.entries.map(\.clipIDs), [[push.id]])
    }

    /// A lift's mark stays with the clip after it when Mike tightens the
    /// take before both.
    func testARemovalMarkMovesWithTheClipAfterIt() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Second shot", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)))
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.removeClips(clipIDs: [c.clips("B-roll")[0].id])])
        try run(c, &log, by: "user", [.rippleDeleteRange(range: TimeRange(start: t(5), end: t(8)))])
        let removal = try XCTUnwrap(log.entries.first?.removals.first)
        XCTAssertEqual(removal.time(in: c.project), t(17))
    }

    /// When the clip a mark was pinned to goes, the mark is pinned again
    /// where its join is now.
    func testAMarkWhoseClipWentIsPinnedAgain() throws {
        let (_, c) = try Fixture.edited()
        try c.run("More shots", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)), .placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(3)))
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.removeClips(clipIDs: [c.clips("B-roll")[0].id])])
        try run(c, &log, by: "user", [.removeClips(clipIDs: [c.clips("B-roll")[0].id])])
        let removal = try XCTUnwrap(log.entries.first?.removals.first)
        XCTAssertEqual(removal.anchorClipID, c.clips("B-roll")[0].id)
        XCTAssertEqual(removal.time(in: c.project), t(20))
    }

    func testTheLogReadsBackAsItWasWritten() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        try run(c, &log, by: "claude", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)), .placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(3))], label: "Add push")
        try run(c, &log, by: "codex", [.rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))], label: "Tighten")
        // One shot deleted again stays listed, out of sight.
        try run(c, &log, by: "user", [.removeClips(clipIDs: [c.clips("B-roll").last!.id])])
        XCTAssertEqual(log.entries.first?.away.count, 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)/.tandem/Test.review.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try log.save(to: url)
        XCTAssertEqual(ReviewLog.load(from: url), log)
        try ReviewLog().save(to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an empty log leaves no file")
        XCTAssertEqual(ReviewLog.load(from: url), ReviewLog())
    }

    func testABrokenLogReadsAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(ReviewLog.load(from: url), ReviewLog())
    }
}

/// The recorder keeps the log as a coordinator commits, and saves it.
final class ReviewRecorderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".tandem"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var url: URL { ProjectFile.reviewURL(for: folder.appendingPathComponent("Test.tandem")) }

    func testRecordsAgentEditsAndSavesThemForTheNextOpen() throws {
        let (_, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        try c.apply(EditBatch(label: "Mike's", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]))
        XCTAssertTrue(recorder.log.isEmpty)
        try c.apply(EditBatch(label: "Add push", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(3))]))
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Add push"])
        recorder.close()
        let reopened = ReviewRecorder(coordinator: c, url: url)
        XCTAssertEqual(reopened.log, recorder.log)
        reopened.close()
    }

    func testUndoDropsTheAgentsEditAndRedoBringsItBack() throws {
        let (f, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        let music = f.clips("Music")[0]
        try c.apply(EditBatch(label: "Add push", author: "claude", commands: [
            .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)),
            .updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-35)])])),
            .rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))
        ]))
        XCTAssertEqual(recorder.log.entries.count, 1)
        c.undo()
        XCTAssertTrue(recorder.log.isEmpty, "\(recorder.log)")
        c.redo()
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Add push"])
    }

    /// After Mike tightened a pause, an agent puts it back with a ripple
    /// trim, joins the take's pieces so they play the file straight
    /// through (which is nothing to review), then undoes both. The clips
    /// the join took out come back on the first undo; they aren't the far
    /// halves of the clips the trim lengthened, so the trim's entry keeps
    /// only its own clips and goes with the second undo. The agent's
    /// earlier edit still waits.
    func testUndoingATrimAndTheJoinAfterItKeepsOnlyTheEditsLeft() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(10.5))))
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        try c.apply(EditBatch(label: "Add push", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]))
        let push = try XCTUnwrap(c.clips("B-roll").last)
        let piece = c.clips("Voice")[0]
        try c.apply(EditBatch(label: "Restore the pause", author: "claude", commands: [.trim(clipID: piece.id, edge: .end, to: t(10.5), ripple: true)]))
        let lengthened = Set(c.project.linkedClipIDs(of: piece.id))
        XCTAssertEqual(lengthened.count, 3, "the voice, the camera and the screen")
        XCTAssertEqual(recorder.log.entries.last.map { Set($0.changed) }, lengthened)
        let next = c.clips("Voice")[1]
        XCTAssertEqual(next.sourceStart, c.project.clip(piece.id)?.sourceEnd, "the pieces play the file straight through")
        try c.apply(EditBatch(label: "Join", author: "claude", commands: [
            .removeClips(clipIDs: [next.id]),
            .trim(clipID: piece.id, edge: .end, to: next.end)
        ]))
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Add push", "Restore the pause"])
        XCTAssertEqual(recorder.log.entries.last.map { Set($0.changed) }, lengthened)

        c.undo()
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Add push", "Restore the pause"])
        XCTAssertEqual(recorder.log.entries.last.map { Set($0.changed) }, lengthened, "only what the trim changed")
        c.undo()
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Add push"])
        XCTAssertEqual(recorder.log.changes(in: c.project).map(\.subject), [.clip(push.id)])
    }

    /// The same with Mike's own join, which isn't recorded: the next clip
    /// coming back when he undoes it still isn't the agent's.
    func testUndoingMikesJoinLeavesTheAgentsTrimAsItWas() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(10.5))))
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        let piece = c.clips("Voice")[0]
        try c.apply(EditBatch(label: "Restore the pause", author: "claude", commands: [.trim(clipID: piece.id, edge: .end, to: t(10.5), ripple: true)]))
        let lengthened = Set(c.project.linkedClipIDs(of: piece.id))
        let next = c.clips("Voice")[1]
        try c.run("Join", .removeClips(clipIDs: [next.id]), .trim(clipID: piece.id, edge: .end, to: next.end))
        c.undo()
        XCTAssertEqual(recorder.log.entries.map { Set($0.clipIDs) }, [lengthened])
        c.undo()
        XCTAssertTrue(recorder.log.isEmpty, "\(recorder.log)")
    }

    /// Both halves of an agent's clip that Mike cut are highlighted again
    /// when an agent joins them and undoes the join, and go with the rest.
    func testUndoingAJoinOfAHighlightedClipsHalvesHighlightsBoth() throws {
        let (f, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        let shot = f.clips("B-roll")[0]
        try c.apply(EditBatch(label: "Quieter", author: "claude", commands: [.updateClip(clipID: shot.id, patch: .object(["audio": .object(["gainDB": .number(-6)])]))]))
        try c.run("Cut", .blade(at: t(22), clipIDs: [shot.id]))
        let halves = c.clips("B-roll").map(\.id)
        XCTAssertEqual(recorder.log.entries.map(\.clipIDs), [halves])
        try c.apply(EditBatch(label: "Join", author: "claude", commands: [.removeClips(clipIDs: [halves[1]]), .trim(clipID: halves[0], edge: .end, to: t(25))]))
        c.undo()
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Quieter"])
        XCTAssertEqual(recorder.log.changes(in: c.project).map(\.subject), halves.map { .clip($0) })
        c.undo()
        c.undo()
        XCTAssertTrue(recorder.log.isEmpty, "\(recorder.log)")
    }

    /// A clip an agent changed, then rebuilt with a new ID, is highlighted
    /// again when the rebuild is undone, and goes when the change is.
    func testUndoingARebuildThenTheChangeBeforeItLeavesNothing() throws {
        let (f, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        let shot = f.clips("B-roll")[0]
        try c.apply(EditBatch(label: "Quieter", author: "claude", commands: [.updateClip(clipID: shot.id, patch: .object(["audio": .object(["gainDB": .number(-6)])]))]))
        var copy = try XCTUnwrap(c.project.clip(shot.id))
        copy.id = "clip_rebuilt"
        try c.apply(EditBatch(label: "Rebuild", author: "claude", commands: [.removeClips(clipIDs: [shot.id]), .insertClip(trackID: f.track("B-roll").id, clip: copy)]))
        XCTAssertEqual(recorder.log.entries.map(\.clipIDs), [["clip_rebuilt"]], "the rebuild itself changed nothing")
        c.undo()
        XCTAssertEqual(recorder.log.entries.map(\.clipIDs), [[shot.id]])
        c.undo()
        XCTAssertTrue(recorder.log.isEmpty, "\(recorder.log)")
    }

    /// After Mike tightened a pause, an agent puts it back by trimming the
    /// start of the clips after it, which leaves a through-edit, and joins
    /// it. The joined clips play what the trim put back, so they're
    /// highlighted in its place, and the join adds nothing to review. Undo
    /// puts the highlights back on the trimmed clips, redo moves them on
    /// again, and undoing the trim as well leaves nothing.
    func testAJoinTakesOnTheHighlightsOfWhatItJoinedAndUndoGivesThemBack() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(10.5))))
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        let left = c.clips("Voice")[0]
        let right = c.clips("Voice")[1]
        // A ripple trim leaves the clip where it starts and plays it from
        // half a second earlier in the file.
        try c.apply(EditBatch(label: "Restore the pause", author: "claude", commands: [.trim(clipID: right.id, edge: .start, to: t(9.5), ripple: true)]))
        let restored = Set(c.project.linkedClipIDs(of: right.id))
        XCTAssertEqual(restored.count, 3, "the voice, the camera and the screen")
        XCTAssertEqual(recorder.log.entries.map { Set($0.clipIDs) }, [restored])
        try c.apply(EditBatch(label: "Join", author: "claude", commands: [.join(clipID: left.id)]))
        XCTAssertEqual(c.clips("Voice").map(\.id), [left.id], "joined")
        let joined = Set(c.project.linkedClipIDs(of: left.id))
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Restore the pause"], "the join is nothing to review")
        XCTAssertEqual(recorder.log.entries.map { Set($0.clipIDs) }, [joined])

        c.undo()
        XCTAssertEqual(recorder.log.entries.map { Set($0.clipIDs) }, [restored])
        c.redo()
        XCTAssertEqual(recorder.log.entries.map { Set($0.clipIDs) }, [joined])
        c.undo()
        c.undo()
        XCTAssertTrue(recorder.log.isEmpty, "\(recorder.log)")
    }

    /// Mike joins a shot an agent added onto his own: his clip is
    /// highlighted while it holds the agent's, and undoing the join puts
    /// the highlight back on the agent's shot alone.
    func testUndoingAJoinOntoMikesClipLeavesItAsItWas() throws {
        let (f, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        let shot = f.clips("B-roll")[0]
        try c.apply(EditBatch(label: "Longer shot", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(25), sourceStart: t(6), duration: t(3))]))
        let more = try XCTUnwrap(c.clips("B-roll").last)
        try c.run("Join", .join(clipID: shot.id))
        XCTAssertEqual(recorder.log.changes(in: c.project).map(\.subject), [.clip(shot.id)])
        c.undo()
        XCTAssertEqual(recorder.log.changes(in: c.project).map(\.subject), [.clip(more.id)])
        c.undo()
        XCTAssertTrue(recorder.log.isEmpty, "\(recorder.log)")
    }

    /// Undoing Mike's own edit after an agent's leaves the agent's edit.
    func testUndoingMikesEditKeepsTheAgents() throws {
        let (f, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        let music = f.clips("Music")[0]
        try c.apply(EditBatch(label: "Quieter", author: "claude", commands: [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-35)])]))]))
        try c.apply(EditBatch(label: "Nudge", commands: [.updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-34)])]))]))
        c.undo()
        XCTAssertEqual(recorder.log.entries.map(\.changed), [[music.id]])
    }

    func testMarkReviewedClearsTheLogAndItsFile() throws {
        let (_, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        defer { recorder.close() }
        var heard: [ReviewLog] = []
        recorder.observe { heard.append($0) }
        try c.apply(EditBatch(label: "Add push", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]))
        // Reading the log waits for the recorder to catch up.
        XCTAssertEqual(recorder.log.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        recorder.markReviewed()
        XCTAssertTrue(recorder.log.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(heard.map(\.entries.count), [1, 0])
    }

    /// Edits a crash kept in the journal reach the log when the project
    /// opens, once.
    func testCatchesUpOnEditsTheJournalReplayed() throws {
        let (f, c) = try Fixture.edited()
        let journal = ProjectJournal(url: folder.appendingPathComponent(".tandem/Test.journal.jsonl"))
        let batch = EditBatch(label: "Add push", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))])
        journal.append(batch: batch, revision: c.revision + 1, seed: 7)
        var replayed: [(entry: ProjectJournal.Entry, before: Project, after: Project)] = []
        let recovered = try XCTUnwrap(journal.recover(project: f.project, revision: c.revision) { replayed.append(($0, $1, $2)) })
        XCTAssertEqual(replayed.count, 1)
        let reopened = ProjectCoordinator(project: recovered.project, revision: recovered.revision)
        let recorder = ReviewRecorder(coordinator: reopened, url: url)
        defer { recorder.close() }
        recorder.catchUp(replayed)
        recorder.catchUp(replayed)
        XCTAssertEqual(recorder.log.entries.map(\.label), ["Add push"])
        XCTAssertEqual(recorder.log.entries.first?.added, [reopened.clips("B-roll").last!.id])
    }
}

final class JournalReplayTests: XCTestCase {
    /// Recovery says what each entry did, with the project either side.
    func testRecoverReportsEachEntryWithTheProjectEitherSide() throws {
        let (f, c) = try Fixture.edited()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = ProjectJournal(url: url)
        journal.append(batch: EditBatch(label: "A", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]), revision: c.revision + 1, seed: 1)
        journal.appendSnapshot(project: f.project, revision: c.revision + 2, reason: "undo A")
        var seen: [(String, Int, Int)] = []
        _ = journal.recover(project: f.project, revision: c.revision) { entry, before, after in
            seen.append((entry.batch?.label ?? entry.reason ?? "", before.track(named: "B-roll")!.clips.count, after.track(named: "B-roll")!.clips.count))
        }
        XCTAssertEqual(seen.map(\.0), ["A", "undo A"])
        XCTAssertEqual(seen.map(\.1), [1, 2])
        XCTAssertEqual(seen.map(\.2), [2, 1])
    }
}
