import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tandem tighten --lead-only` and `tandem check`'s note for a face waiting
/// to talk: Mike, reviewing the Let's Build It video (13 Nov 2026), wants
/// each clip of the take to start a frame or two before he speaks, with the
/// pause on the end of the clip before.
final class LeadRollTests: XCTestCase {
    /// The fixture's take is cut at timeline 30: the first piece plays file
    /// 0-30, the second file 32-62. "section." ends at file 29.9, "Um,
    /// wait." (file 30.5-31.4) is cut out, and "Now" starts at file 32.5:
    /// the second piece runs 0.5 s before he speaks.
    static let speech: [(Double, Double)] = [(28.0, 29.9), (30.5, 31.4), (32.5, 34.0)]

    private func harness(transition: Bool = false) throws -> ServiceHarness {
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        if !transition { project.videoTracks[1].transitions = [] }
        let h = try ServiceHarness(project: project)
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try CutAPITests.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.speech)
        h.analysis.transcripts["med_camera"] = APIFixture.cameraTranscript
        return h
    }

    private var frame: Double { 1.0 / APIFixture.project().settings.frameRate.framesPerSecond }

    func testLeadOnlyRollsThePauseOntoTheClipBefore() async throws {
        let h = try harness()
        defer { h.close() }
        let before = h.service.coordinator.project
        let plan = try await TightenRequest(leadOnly: true).run(on: h.service, context: h.context)
        let join = try XCTUnwrap(plan.leads?.first { abs($0.at.seconds - 30) < 0.01 }, plan.readableText)
        XCTAssertEqual(join.wait.seconds, 0.5, accuracy: 0.03, plan.readableText)
        XCTAssertTrue(join.words.hasPrefix("Now"), join.words)
        // Down to the 0.05 s lead, on whole frames, rounding down.
        let roll = try XCTUnwrap(join.roll, plan.readableText).seconds
        XCTAssertEqual(roll, ((join.wait.seconds - 0.05) / frame + 1e-6).rounded(.down) * frame, accuracy: 0.001)
        // Camera, screen and voice are linked: one roll moves them all.
        XCTAssertEqual(plan.commands.count, 1, "\(plan.commands)")
        XCTAssertEqual(h.service.coordinator.project, before, "a dry run changes nothing")
        XCTAssertTrue(plan.readableText.contains("Roll 1 of"), plan.readableText)

        _ = try await TightenRequest(leadOnly: true, apply: true).run(on: h.service, context: h.context)
        let after = h.service.coordinator.project
        XCTAssertEqual(after.duration, before.duration, "a roll keeps the timeline's length")
        for id in ["clip_voc2", "clip_cam2", "clip_scr2"] {
            let clip = try XCTUnwrap(after.clip(id))
            XCTAssertEqual(clip.start.seconds, 30 + roll, accuracy: 0.001, id)
        }
        XCTAssertEqual(try XCTUnwrap(after.clip("clip_voc2")).sourceStart.seconds, 32 + roll, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(after.clip("clip_voc1")).end.seconds, 30 + roll, accuracy: 0.001)

        // Now it starts within the lead and a frame of "Now": nothing to do,
        // and check --cuts hears the join clean.
        let again = try await TightenRequest(leadOnly: true).run(on: h.service, context: h.context)
        XCTAssertTrue(again.commands.isEmpty, again.readableText)
        let check = try await CheckRequest(from: t(28), to: t(33), cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(check.problems.isEmpty, "\(check.problems)")
    }

    func testTheClipBeforeOnlyGrowsThroughQuiet() async throws {
        // "Um" now starts 0.2 s after the first piece ends: it can grow
        // 0.17 s at most (30 ms short of the "um"), not the 0.45 s asked.
        let h = try harness()
        defer { h.close() }
        try CutAPITests.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: [(28.0, 29.9), (30.2, 31.4), (32.5, 34.0)])
        let plan = try await TightenRequest(leadOnly: true).run(on: h.service, context: h.context)
        let join = try XCTUnwrap(plan.leads?.first, plan.readableText)
        let roll = try XCTUnwrap(join.roll, plan.readableText).seconds
        XCTAssertLessThanOrEqual(roll, 0.17 + 0.001)
        XCTAssertGreaterThan(roll, 0.05)
    }

    func testAJoinUnderATransitionIsLeftAlone() async throws {
        let h = try harness(transition: true)
        defer { h.close() }
        let plan = try await TightenRequest(leadOnly: true).run(on: h.service, context: h.context)
        XCTAssertEqual(plan.leads?.count, 0, plan.readableText)
        XCTAssertTrue(plan.commands.isEmpty)
    }

    func testEveryClipTheRollMovesBoundsIt() async throws {
        // The linked screen clip after the join is only 0.25 s long, under
        // the 0.3 s a roll leaves: the join stays where it is rather than
        // failing the whole batch in `Editing.roll`.
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        project.videoTracks[1].transitions = []
        project.videoTracks[0].clips[1].duration = t(0.25)
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try CutAPITests.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.speech)
        let plan = try await TightenRequest(leadOnly: true).run(on: h.service, context: h.context)
        XCTAssertNil(plan.leads?.first?.roll, plan.readableText)
        XCTAssertTrue(plan.commands.isEmpty)
    }

    func testAHiddenLinkedClipBoundsTheRollToo() async throws {
        // Hidden, the short screen clip still rolls with its linked
        // partners in `Editing.roll`, so it still bounds the roll.
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        project.videoTracks[1].transitions = []
        project.videoTracks[0].clips[1].duration = t(0.25)
        project.videoTracks[0].hidden = true
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try CutAPITests.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.speech)
        let plan = try await TightenRequest(leadOnly: true).run(on: h.service, context: h.context)
        XCTAssertNil(plan.leads?.first?.roll, plan.readableText)
    }

    func testALinkedClipAHairApartInTheNextFrameIsLeftAlone() async throws {
        // Voice and screen meet exactly at 30.016; the camera's next clip
        // starts at 30.020, which rounds into the next frame.
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        project.videoTracks[1].transitions = []
        for track in [0, 1] { project.videoTracks[track].clips[0].duration = t(30.016) }
        project.audioTracks[0].clips[0].duration = t(30.016)
        project.videoTracks[0].clips[1].start = t(30.016)
        project.audioTracks[0].clips[1].start = t(30.016)
        project.videoTracks[1].clips[1].start = t(30.02)
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try CutAPITests.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.speech)
        let plan = try await TightenRequest(leadOnly: true).run(on: h.service, context: h.context)
        XCTAssertEqual(plan.leads?.count, 0, plan.readableText)
        // Asked about only the voice's side of it, too.
        let narrow = try await TightenRequest(leadOnly: true, from: t(30.016), to: t(30.018)).run(on: h.service, context: h.context)
        XCTAssertEqual(narrow.leads?.count, 0, narrow.readableText)
    }

    func testAJoinWithALinkedClipAHairApartIsLeftAlone() async throws {
        // The linked screen clip starts 10 ms after the others: a roll
        // would move the camera and voice and leave it, or fail.
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        project.videoTracks[1].transitions = []
        project.videoTracks[0].clips[1].start = t(30.01)
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try CutAPITests.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.speech)
        let plan = try await TightenRequest(leadOnly: true).run(on: h.service, context: h.context)
        XCTAssertEqual(plan.leads?.count, 0, plan.readableText)
    }

    func testATransitionAtTheClipsOtherEndDoesntCount() async throws {
        let h = try harness()
        defer { h.close() }
        try h.service.coordinator.apply(EditBatch(label: "Fade in", commands: [
            .addTransition(trackID: "trk_camera", transition: Transition(type: .dissolve, duration: t(0.5), fromClipID: nil, toClipID: "clip_cam1"))
        ]))
        let plan = try await TightenRequest(leadOnly: true).run(on: h.service, context: h.context)
        XCTAssertNotNil(plan.leads?.first?.roll, plan.readableText)
    }

    func testLeadOnlyTakesOnlyLeadFromAndTo() async throws {
        let h = try harness()
        defer { h.close() }
        do {
            _ = try await TightenRequest(filmora: true, leadOnly: true).run(on: h.service, context: h.context)
            XCTFail("filmora with leadOnly should be refused")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("`filmora`"), error.message)
        }
        do {
            _ = try await TightenRequest(lead: 2, leadOnly: true).run(on: h.service, context: h.context)
            XCTFail("a lead over a second should be refused")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("lead"), error.message)
        }
        // A longer lead rolls less.
        let longer = try await TightenRequest(lead: 0.2, leadOnly: true).run(on: h.service, context: h.context)
        let first = try XCTUnwrap(longer.leads?.first)
        let roll = try XCTUnwrap(first.roll).seconds
        XCTAssertEqual(roll, ((first.wait.seconds - 0.2) / frame + 1e-6).rounded(.down) * frame, accuracy: 0.001)
        // Outside from and to, nothing.
        let outside = try await TightenRequest(leadOnly: true, from: t(0), to: t(20)).run(on: h.service, context: h.context)
        XCTAssertEqual(outside.leads?.count, 0)
    }

    func testCheckNotesAFaceWaitingToTalkWithTheRoll() async throws {
        let h = try harness()
        defer { h.close() }
        let check = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        let note = try XCTUnwrap(check.notes.first { $0.kind == .faceWaits }, "\(check.notes.map(\.kind))")
        XCTAssertEqual(note.start.seconds, 30, accuracy: 0.01)
        XCTAssertTrue(note.message.contains("Face waits 0."), note.message)
        XCTAssertTrue(note.message.contains("\"Now"), note.message)
        XCTAssertTrue(note.message.contains("--lead-only"), note.message)
        guard case .roll(let left, let right, let delta) = try XCTUnwrap(note.fix) else { return XCTFail("\(String(describing: note.fix))") }
        XCTAssertEqual(Set([left, right]).count, 2)
        XCTAssertGreaterThan(delta.seconds, 0.4)
        XCTAssertTrue(check.ok, "a note, not a problem")

        // Rolled, the note goes.
        _ = try await TightenRequest(leadOnly: true, apply: true).run(on: h.service, context: h.context)
        let after = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertFalse(after.notes.contains { $0.kind == .faceWaits }, "\(after.notes)")
    }

    func testNoNoteWhereFullFrameBRollHidesHisFace() async throws {
        let h = try harness()
        defer { h.close() }
        // The fixture's B-roll shot, full frame, moved over the join.
        try h.service.coordinator.apply(EditBatch(label: "Cover the join", commands: [.updateClip(clipID: "clip_brl1", patch: .object(["start": .number(28)]))]))
        let check = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertFalse(check.notes.contains { $0.kind == .faceWaits }, "\(check.notes)")
    }
}
