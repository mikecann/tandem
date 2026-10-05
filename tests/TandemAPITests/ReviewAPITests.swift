import XCTest
@testable import TandemAPI
@testable import TandemCore

/// Agent edits reach the review log wherever they're made, and agents can
/// read what's waiting from `status`.
final class ReviewAPITests: XCTestCase {
    /// With the app closed, each CLI command opens the project, edits it
    /// and closes it again. Its edit waits for Mike when the app opens the
    /// project next.
    func testHeadlessAgentEditsWaitForTheAppToOpenTheProject() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let client = ProjectClient(projectURL: url, author: "claude")
        client.analysis = FakeAnalysis()
        client.renderer = FakeRenderer()
        let applied = try await client.call(ApplyRequest(label: "Add push", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectSession.lockURL(for: url).path), "the command let go of the project")

        let app = try ProjectSession.open(url, owner: .app)
        defer { app.close() }
        let entries = app.review.log.entries
        XCTAssertEqual(entries.map(\.label), ["Add push"])
        XCTAssertEqual(entries.first?.revision, applied.revision)
        XCTAssertEqual(entries.first?.added.count, 1)
        XCTAssertNotNil(entries.first?.added.first.flatMap { app.coordinator.project.clip($0) })
    }

    /// Edits a crash left in the journal (the app died before it saved)
    /// are replayed when the project opens, and an agent's wait for review.
    func testAgentEditsReplayedFromTheJournalWaitForReview() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let journal = ProjectJournal.forProject(at: url)
        journal.append(batch: EditBatch(label: "Add push", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]), revision: 2, seed: 9)
        journal.append(batch: EditBatch(label: "Nudge", commands: [.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false)]), revision: 3, seed: 10)
        let session = try ProjectSession.open(url, owner: .app)
        defer { session.close() }
        XCTAssertTrue(session.recoveredEdits)
        XCTAssertEqual(session.review.log.entries.map(\.label), ["Add push"])
    }

    /// `tandem undo` with the app closed puts the project back from its
    /// undo history, and the edit it undid stops waiting.
    func testAHeadlessUndoTakesTheEditOutOfReview() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let client = ProjectClient(projectURL: url, author: "claude")
        client.analysis = FakeAnalysis()
        client.renderer = FakeRenderer()
        _ = try await client.call(ApplyRequest(label: "Add push", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3))]))
        let waiting = try await client.call(StatusRequest())
        XCTAssertEqual(waiting.reviewPending?.map(\.label), ["Add push"])
        _ = try await client.call(UndoRequest())
        let undone = try await client.call(StatusRequest())
        XCTAssertEqual(undone.reviewPending, [])
        // Redo puts the edit back, waiting again.
        _ = try await client.call(RedoRequest())
        let redone = try await client.call(StatusRequest())
        XCTAssertEqual(redone.reviewPending?.map(\.label), ["Add push"])
    }

    /// Restoring the cut between the take's pieces is a ripple trim: the
    /// first piece runs on, its camera and screen with it, and the rest
    /// moves along. Undoing it leaves nothing waiting.
    func testAHeadlessUndoOfARippleTrimLeavesNothingWaiting() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let client = ProjectClient(projectURL: url, author: "claude")
        client.analysis = FakeAnalysis()
        client.renderer = FakeRenderer()
        let restored = try await client.call(ApplyRequest(label: "Restore the cut", commands: [.trim(clipID: "clip_voc1", edge: .end, to: t(32), ripple: true)]))
        let waiting = try await client.call(StatusRequest())
        XCTAssertEqual(waiting.reviewPending?.map(\.label), ["Restore the cut"])
        XCTAssertEqual(Set(waiting.reviewPending?.first?.clipIDs ?? []), ["clip_voc1", "clip_cam1", "clip_scr1"])
        _ = try await client.call(UndoRequest(expectedRevision: restored.revision))
        let undone = try await client.call(StatusRequest())
        XCTAssertEqual(undone.reviewPending, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectFile.reviewURL(for: url).path), "nothing left to highlight")
    }

    /// With the app closed, an agent restores the cut between the take's
    /// pieces, joins them into one clip that plays the file straight
    /// through, then undoes both. The second piece coming back on the first
    /// undo is that clip put back, not the far half of the one the trim
    /// lengthened, so once the trim is undone too nothing waits.
    func testUndoingATrimAndTheJoinAfterItLeavesNothingWaiting() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let start = try ProjectFile.load(from: url).project
        let client = ProjectClient(projectURL: url, author: "claude")
        client.analysis = FakeAnalysis()
        client.renderer = FakeRenderer()
        _ = try await client.call(ApplyRequest(label: "Restore the cut", commands: [.trim(clipID: "clip_voc1", edge: .end, to: t(32), ripple: true)]))
        let joined = try await client.call(ApplyRequest(label: "Join", commands: [
            .removeClips(clipIDs: ["clip_voc2"]),
            .trim(clipID: "clip_voc1", edge: .end, to: t(62))
        ]))
        let both = try await client.call(StatusRequest())
        XCTAssertEqual(both.reviewPending?.map(\.label), ["Restore the cut", "Join"])

        let first = try await client.call(UndoRequest(expectedRevision: joined.revision))
        let one = try await client.call(StatusRequest())
        XCTAssertEqual(one.reviewPending?.map(\.label), ["Restore the cut"])
        XCTAssertEqual(Set(one.reviewPending?.first?.clipIDs ?? []), ["clip_voc1", "clip_cam1", "clip_scr1"], "only what the trim changed")

        _ = try await client.call(UndoRequest(expectedRevision: first.revision))
        let two = try await client.call(StatusRequest())
        XCTAssertEqual(try ProjectFile.load(from: url).project, start, "back where it started")
        XCTAssertEqual(two.reviewPending, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectFile.reviewURL(for: url).path), "nothing left to highlight")
    }

    /// An archive is a finished video: it starts with nothing to review.
    func testAnArchiveLeavesTheReviewLogBehind() throws {
        let f = try ArchiveFixture()
        let session = try ProjectSession.open(f.projectURL, owner: .cli)
        try session.coordinator.apply(EditBatch(label: "Later", author: "claude", commands: [.moveClips(clipIDs: ["clip_brl"], delta: t(1), includeLinked: false)]))
        session.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectFile.reviewURL(for: f.projectURL).path))
        let shelf = f.root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let result = try f.archive(to: shelf, clone: false)
        let archived = URL(fileURLWithPath: result.projectFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectFile.reviewURL(for: archived).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectFile.reviewURL(for: f.projectURL).path), "the original keeps its own")
    }

    func testMikesEditsNeverWaitForReview() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        _ = try h.service.apply(ApplyRequest(commands: [.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false)]), context: CallContext(author: "user"))
        XCTAssertEqual(h.service.status().reviewPending, [])
    }

    func testStatusListsTheEditsWaitingForReview() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(3)), label: "Add push")
        let status = h.service.status()
        let pending = try XCTUnwrap(status.reviewPending)
        XCTAssertEqual(pending.map(\.label), ["Add push"])
        XCTAssertEqual(pending.first?.author, "claude")
        XCTAssertEqual(pending.first?.clipIDs.count, 1)
        XCTAssertTrue(status.readableText.contains("waiting for Mike's review: 1 agent edit (Add push by claude)"), status.readableText)
        let decoded = try ServiceJSON.decoder().decode(StatusResult.self, from: ServiceJSON.encoder().encode(status))
        XCTAssertEqual(decoded.reviewPending, pending)

        // Mark reviewed in the app empties it.
        h.session.review.markReviewed()
        XCTAssertEqual(h.service.status().reviewPending, [])
        XCTAssertFalse(h.service.status().readableText.contains("waiting for Mike's review"))
    }

    func testAnOldAppsStatusWithoutItStillReads() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: ServiceJSON.encoder().encode(h.service.status())) as? [String: Any])
        fields["reviewPending"] = nil
        let old = try ServiceJSON.decoder().decode(StatusResult.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertNil(old.reviewPending)
    }
}
