import XCTest
@testable import TandemCore

/// What `tandem handback` asks of a round before it hands it back
/// (`HandbackGate`), from the checks in the edit history.
final class HandbackGateTests: XCTestCase {
    /// The take on Camera and Voice, a B-roll shot an agent added at
    /// revision 5, and, with `cut`, a stretch it cut out of the take at
    /// revision 6.
    private func round(cut: Bool = false) -> (Project, ReviewLog) {
        var project = Project.standard(name: "Gate")
        project.videoTracks[1].clips = [
            Clip(id: "clip_cam1", content: .solid(color: .black), start: .zero, duration: t(30)),
            Clip(id: "clip_cam2", content: .solid(color: .black), start: t(30), duration: t(30))
        ]
        project.videoTracks[2].clips = [Clip(id: "clip_shot", content: .solid(color: .black), start: t(20), duration: t(5))]
        var added = ReviewChanges()
        added.added = ["clip_shot"]
        var log = ReviewLog(entries: [ReviewEntry(revision: 5, label: "B-roll over the config", author: "claude", date: Date(), changes: added)])
        if cut {
            var removed = ReviewChanges()
            removed.removals = [ReviewRemoval(trackID: project.videoTracks[1].id, time: t(30), duration: t(2), anchorClipID: "clip_cam2", anchorEdge: .start, from: ["clip_cam1"])]
            log.entries.append(ReviewEntry(revision: 6, label: "Cut the um", author: "claude", date: Date(), changes: removed))
        }
        return (project, log)
    }

    private func edit(_ revision: Int, by author: String = "claude", summary: String? = "1 changed", place: Bool = true) -> HistoryRecord {
        var record = HistoryRecord(revision: revision, kind: .edit, label: "Edit", author: author)
        record.summary = summary
        record.place = place ? EditPlace(start: t(1), end: t(2), tracks: ["V3 B-roll"]) : nil
        return record
    }

    private func check(_ revision: Int, _ mode: CheckRun.Mode = .full, covers: [Int], problems: Int = 0, found: [CheckRun.Note]? = nil, notes: [CheckRun.Note] = []) -> HistoryRecord {
        let run = CheckRun(scope: .changed, mode: mode, ranges: [TimeRange(start: t(19.5), end: t(32.5))], problems: found?.count ?? problems, found: found, notes: notes, covers: covers)
        var record = HistoryRecord(revision: revision, kind: .check, label: run.command, author: "claude")
        record.check = run
        return record
    }

    private func judge(_ records: [HistoryRecord], cut: Bool = false, answers: [HandbackGate.Answer] = []) -> HandbackGate.Verdict {
        let (project, log) = round(cut: cut)
        return HandbackGate.judge(records: records, log: log, project: project, answers: answers)
    }

    func testNothingWaitingNeedsNoCheck() {
        let (project, _) = round()
        let verdict = HandbackGate.judge(records: [], log: ReviewLog(), project: project, answers: [])
        XCTAssertTrue(verdict.passes)
        XCTAssertEqual(verdict.waiting, [])
    }

    func testAProblemTheCheckKeptCanBeAnsweredAsAFalseAlarm() {
        // The Examples Page video (18 Nov 2026): a web page's empty ad slot
        // read as a white block, with no way past but --unchecked.
        let white = CheckRun.Note(kind: "whiteBlock", start: t(21), end: t(21.3), message: "White block: a flat white patch over 8% of the frame comes and goes in 9 frames (a key or matte that failed?).")
        let records = [edit(5), check(5, covers: [5], found: [white])]
        let refused = judge(records)
        XCTAssertFalse(refused.passes)
        XCTAssertEqual(refused.needs, [], "the check ran and covered it")
        XCTAssertEqual(refused.unansweredProblems, [white])
        let answered = judge(records, answers: [.init(kind: "whiteBlock", at: t(21), why: "an empty ad slot on the real Fortune page")])
        XCTAssertTrue(answered.passes)
        XCTAssertEqual(answered.overruled, ["whiteBlock at 00:21.000: an empty ad slot on the real Fortune page"])
        XCTAssertEqual(answered.answered, 0, "notes answered are counted apart")
        // A newer check that read the stretch again clean clears it, though
        // the older one is still what covers another batch.
        let both = TimeRange(start: t(19.5), end: t(32.5)), shot = TimeRange(start: t(19.5), end: t(25.5))
        var older = check(6, covers: [5, 6], found: [white])
        older.check?.ranges = [both]
        var newer = check(7, covers: [5])
        newer.check?.ranges = [shot]
        let (project, log) = round(cut: true)
        let cleared = HandbackGate.judge(records: [edit(5), edit(6), older, newer], log: log, project: project, answers: [], cutsMatter: false)
        XCTAssertEqual(cleared.unansweredProblems, [], "the newer check found nothing there")
        XCTAssertTrue(cleared.passes, "\(cleared)")
        // A check from before problems were kept can't be answered.
        XCTAssertEqual(judge([edit(5), check(5, covers: [5], problems: 1)], answers: [.init(kind: "whiteBlock", at: t(21), why: "ad")]).needs,
                       [.renderProblems(count: 1, revision: 5)])
    }

    func testARenderingCheckSinceTheLastAgentEditIsNeeded() {
        XCTAssertEqual(judge([edit(5)]).needs, [.render(uncovered: [5], stale: nil)])
        XCTAssertTrue(judge([edit(5), check(5, covers: [5])]).passes)
        // A quick check renders nothing, and a privacy check reads text.
        XCTAssertEqual(judge([edit(5), check(5, .quick, covers: [5]), check(5, .privacy, covers: [5])]).needs, [.render(uncovered: [5], stale: nil)])
        // One that missed the change doesn't cover it.
        XCTAssertEqual(judge([edit(5), check(5, covers: [])]).needs, [.render(uncovered: [5], stale: nil)])
    }

    func testOnlyAnAgentsEditAfterTheCheckMakesItStale() {
        // An agent's edit after it, even one review doesn't highlight (a
        // setting), means it checked something else.
        var verdict = judge([edit(5), check(5, covers: [5]), edit(6, summary: "settings", place: false)])
        XCTAssertEqual(verdict.needs, [.render(uncovered: [5], stale: 5)])
        XCTAssertEqual(verdict.lastAgentEdit, 6)
        // Mike's trims, Tandem finding new media, and an agent resolving a
        // comment don't.
        verdict = judge([
            edit(5), check(5, covers: [5]), edit(6, by: EditAuthor.person), edit(7, by: EditAuthor.system, summary: "2 media added", place: false),
            edit(8, summary: "markers", place: false)
        ])
        XCTAssertTrue(verdict.passes, "\(verdict)")
        // The project changed somewhere that kept no history.
        XCTAssertEqual(judge([edit(5), check(5, covers: [5]), HistoryRecord(revision: 9, kind: .opened, label: "Opened", author: EditAuthor.system)]).needs.count, 1)
    }

    func testProblemsHaveToBeFixed() {
        XCTAssertEqual(judge([edit(5), check(5, covers: [5], problems: 2)]).needs, [.renderProblems(count: 2, revision: 5)])
        // Two checks of their own stretches cover the round between them.
        let (project, _) = round()
        var log = round().1
        var more = ReviewChanges()
        more.added = ["clip_cam2"]
        log.entries.append(ReviewEntry(revision: 7, label: "Punch in", author: "claude", date: Date(), changes: more))
        let both = HandbackGate.judge(records: [edit(5), edit(7), check(7, covers: [5]), check(7, covers: [7])], log: log, project: project, answers: [])
        XCTAssertTrue(both.passes)
    }

    /// The newest check over a batch decides it: Mike changes the picture
    /// after a clean check, the next check finds a gap, and the older clean
    /// one doesn't let the hand-back through.
    func testANewerFailingCheckOutvotesAnOlderCleanOne() {
        let verdict = judge([edit(5), check(5, covers: [5]), edit(6, by: EditAuthor.person), check(6, covers: [5], problems: 1)])
        XCTAssertEqual(verdict.needs, [.renderProblems(count: 1, revision: 6)])
        XCTAssertTrue(judge([edit(5), check(5, covers: [5], problems: 1), check(5, covers: [5])]).passes, "fixed and checked again")
    }

    /// One reason answers one note, even where two of the same kind sit side by side.
    func testOneReasonAnswersOneNote() {
        let comments = CheckRun.Note(kind: "outroSting", start: t(400), end: t(401), message: "Comments ask with no Comment below.")
        let subscribe = CheckRun.Note(kind: "outroSting", start: t(401.5), end: t(402.5), message: "Subscribe ask with no Like and subscribe.")
        let records = [edit(5), check(5, covers: [5], notes: [comments, subscribe])]
        var verdict = judge(records, answers: [HandbackGate.Answer(kind: "outroSting", at: t(401), why: "he asks in the description instead")])
        XCTAssertEqual(verdict.unanswered, [subscribe])
        verdict = judge(records, answers: [
            HandbackGate.Answer(kind: "outroSting", at: t(401), why: "asked in the description"),
            HandbackGate.Answer(kind: "outroSting", at: t(402), why: "no subscribe sting on a release video")
        ])
        XCTAssertTrue(verdict.passes, "\(verdict)")
    }

    func testACutInTheTakeAlsoNeedsTheListenCheck() {
        var verdict = judge([edit(5), edit(6), check(6, covers: [5, 6])], cut: true)
        XCTAssertEqual(verdict.needs, [.listen(uncovered: [6], stale: nil)])
        verdict = judge([edit(5), edit(6), check(6, covers: [5, 6]), check(6, .cuts, covers: [6])], cut: true)
        XCTAssertEqual(verdict.needs, [.listen(uncovered: [6], stale: nil)], "the levels alone don't hear the join")
        verdict = judge([edit(5), edit(6), check(6, covers: [5, 6]), check(6, .listen, covers: [6], problems: 1)], cut: true)
        XCTAssertEqual(verdict.needs, [.listenProblems(count: 1, revision: 6)])
        let heard = CheckRun.Note(kind: "heardWhole", start: t(30), end: t(30), message: "Heard whole.")
        verdict = judge([edit(5), edit(6), check(6, covers: [5, 6]), check(6, .listen, covers: [6], notes: [heard])], cut: true)
        XCTAssertTrue(verdict.passes, "a join heard whole needs no answer: \(verdict)")
        // Without speech in the edit there's nothing to hear.
        let (project, log) = round(cut: true)
        XCTAssertTrue(HandbackGate.judge(records: [edit(5), edit(6), check(6, covers: [5, 6])], log: log, project: project, answers: [], cutsMatter: false).passes)
    }

    func testEveryNoteIsAnsweredOrGone() {
        let deadAir = CheckRun.Note(kind: "deadAir", start: t(236), end: t(237), message: "Dead air: 0.80 s with nothing said.")
        let broll = CheckRun.Note(kind: "littleBRoll", start: t(60), end: t(300), message: "Little B-roll.")
        let records = [edit(5), check(5, covers: [5], notes: [deadAir, broll])]
        var verdict = judge(records)
        XCTAssertFalse(verdict.passes)
        XCTAssertEqual(verdict.unanswered, [broll, deadAir], "in timeline order")
        // Matched by kind, however it's spelt, and a time within about a
        // second of the stretch; an answer with no reason doesn't count.
        verdict = judge(records, answers: [
            HandbackGate.Answer(kind: "dead air", at: t(235.2), why: "the build animation plays here"),
            HandbackGate.Answer(kind: "littleBRoll", at: t(120), why: "  "),
            HandbackGate.Answer(kind: "softZoom", at: t(10), why: "?")
        ])
        XCTAssertEqual(verdict.unanswered, [broll])
        XCTAssertEqual(verdict.answered, 1)
        XCTAssertEqual(verdict.unmatched.map(\.kind), ["littleBRoll", "softZoom"])
        verdict = judge(records, answers: [
            HandbackGate.Answer(kind: "deadAir", at: t(236), why: "the build animation plays here"),
            HandbackGate.Answer(kind: "littleBRoll", at: t(61), why: "a screen demo, the screen is the B-roll")
        ])
        XCTAssertTrue(verdict.passes)
        XCTAssertEqual(verdict.answered, 2)
        // A later check that no longer finds one is what counts.
        XCTAssertTrue(judge(records + [edit(6, by: EditAuthor.person), check(6, covers: [5], notes: [])]).passes)
    }
}

/// Checks and hand-backs in the edit history sit between its edits
/// without breaking the walk back through them.
final class CheckHistoryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-check-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testChecksDontBreakTheChainOrStartItAgain() throws {
        let (f, c) = try Fixture.edited()
        let url = folder.appendingPathComponent("Fixture.history.jsonl")
        var recorder = HistoryRecorder(coordinator: c, url: url)
        let start = c.revision
        try c.run("Gain", .updateClip(clipID: f.clips("Music")[0].id, patch: .object(["audio": .object(["gainDB": .number(-6)])])))
        let checked = c.revision
        try c.run("Trim", .trim(clipID: f.clips("B-roll")[0].id, edge: .start, to: t(21)))
        // A check that read the revision before the trim finishes after it.
        var late = HistoryRecord(revision: checked, kind: .check, label: "check --changed", author: "claude")
        late.check = CheckRun(scope: .changed, mode: .full, ranges: [TimeRange(start: t(19.5), end: t(25.5))], problems: 0, notes: [], covers: [])
        recorder.note(late)
        var unchecked = HistoryRecord(revision: c.revision, kind: .handback, label: "Handed back unchecked", author: "claude")
        unchecked.unchecked = "no renderer here"
        recorder.note(unchecked)
        recorder.close()

        XCTAssertEqual(EditHistoryLog(url: url).lastRevision(), c.revision, "a check carries the revision it read, not the last")
        recorder = HistoryRecorder(coordinator: c, url: url)
        let records = recorder.records()
        XCTAssertEqual(records.filter { $0.kind == .opened }.count, 1, "the next session carries on from the trim")
        XCTAssertEqual(records.first { $0.kind == .check }?.check?.command, "check --changed")
        XCTAssertEqual(records.last?.unchecked, "no renderer here")
        let walk = try HistoryChain.walk(records, current: TimelineClips(c.project), currentRevision: c.revision, back: start)
        XCTAssertEqual(walk.records.map(\.label), ["Gain", "Trim"])
        XCTAssertEqual(HistoryChain.earliest(records, currentRevision: c.revision), start)
        recorder.close()
    }

    func testANoteIsShortenedToItsFirstSentence() {
        XCTAssertEqual(CheckRun.Note.short("Dead air: 0.80 s with nothing said, no sound effect or music swell (after \"is called the committer.\"). Cut it, or keep it."), "Dead air: 0.80 s with nothing said, no sound effect or music swell (after \"is called the committer.\").")
        XCTAssertEqual(CheckRun.Note.short(String(repeating: "a", count: 200)).count, 140)
    }
}
