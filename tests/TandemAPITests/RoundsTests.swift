import XCTest
@testable import TandemAPI
@testable import TandemCLI
@testable import TandemCore

/// `tandem rounds`: how a video's review went, round by round, read from
/// the edit history, the backups and the export snapshots without opening
/// the project.
final class RoundsTests: XCTestCase {
    private var folder: URL!
    private var project: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-rounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        project = folder.appendingPathComponent("Launch.tandem")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func t(_ seconds: Double) -> Time { Time(seconds: seconds) }
    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func row(_ revision: Int, _ label: String, by author: String, at minutes: Double, kind: HistoryRecord.Kind = .edit,
                     place: (Double, Double, [String])? = nil, comments: [HistoryComment]? = nil) -> HistoryRecord {
        var record = HistoryRecord(revision: revision, kind: kind, label: label, author: author, date: at(minutes))
        record.place = place.map { EditPlace(start: t($0.0), end: t($0.1), tracks: $0.2) }
        record.comments = comments
        return record
    }

    private func writeHistory(_ records: [HistoryRecord]) {
        let log = EditHistoryLog(url: ProjectFile.historyURL(for: project))
        for record in records { log.append(record) }
    }

    private func comment(_ id: String, _ seconds: Double, _ text: String) -> Marker {
        Marker(id: id, time: t(seconds), name: text, kind: .comment)
    }

    private func saveProject(revision: Int, comments: [Marker] = [], id: String = "prj_launch") throws {
        try ProjectFile.save(Project(id: id, name: "Launch", markers: comments), revision: revision, to: project)
    }

    private func saveBackup(_ stamp: String, revision: Int, comments: [Marker]) throws {
        let backups = ProjectFile.supportFolder(for: project).appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try ProjectFile.save(Project(id: "prj_launch", name: "Launch", markers: comments), revision: revision, to: backups.appendingPathComponent("Launch 2026-11-12 \(stamp).tandem"))
    }

    /// Exports write revision 0 in their snapshot, so they go by when the export began.
    private func saveExportSnapshot(_ name: String, at minutes: Double, comments: [Marker], id: String = "prj_launch") throws {
        let exports = folder.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let metadata = ["export.output": name, "export.date": ISO8601DateFormatter().string(from: at(minutes))]
        try ProjectFile.save(Project(id: id, name: "Launch", markers: comments, metadata: metadata), revision: 0, to: exports.appendingPathComponent(name + ".tandem"))
    }

    /// From this version on, each handback is a row in the history and each
    /// comment's words are kept with it.
    func testHandbacksMarkTheRoundsAndTheHistoryHasTheWords() throws {
        try saveProject(revision: 12)
        let take = ["V2 Camera", "V1 Screen", "A1 Voice"]
        writeHistory([
            row(0, "Opened", by: "system", at: 0, kind: .opened),
            row(1, "Cut the take", by: "claude", at: 1, place: (0, 60, take)),
            row(2, "Place the B-roll", by: "claude", at: 2, place: (5, 9, ["V3 B-roll"])),
            // The check before the handback changed nothing: not an agent edit.
            row(2, "Check", by: "claude", at: 2.5, kind: .check),
            .handback(revision: 2, author: "claude", count: 3, date: at(3)),
            row(3, "Add comment", by: "user", at: 11, comments: [HistoryComment(id: "mk_a", time: t(12), text: "Awkward pause mid-sentence here")]),
            row(4, "Ripple trim", by: "user", at: 12, place: (10, 10.5, take)),
            // A delete and its close gap are one fix, though the close
            // gap's place runs on to the end.
            row(5, "Delete 3 clips", by: "user", at: 12.2, place: (10.5, 11, take)),
            row(6, "Close gap", by: "user", at: 12.25, place: (10.5, 58, take + ["V3 B-roll", "A2 Music"])),
            row(7, "Ripple trim", by: "user", at: 13, place: (40, 41, take)),
            row(8, "Turn off blur", by: "user", at: 14, place: (20, 25, ["V4 Privacy (Screen)"])),
            row(9, "Ripple trim", by: "user", at: 14.5, place: (30, 31, ["V3 B-roll"])),
            row(10, "Show the docs (your comment)", by: "claude", at: 30, place: (12, 15, ["V3 B-roll"])),
            .handback(revision: 10, author: "claude", count: 1, date: at(31)),
            row(11, "Add comment", by: "user", at: 40, comments: [HistoryComment(id: "mk_b", time: t(14), text: "Show the docs page here insted")]),
            row(12, "Edit comment", by: "user", at: 40.5, comments: [HistoryComment(id: "mk_b", time: t(14), text: "Show the docs page here instead")]),
            row(13, "Add comment", by: "user", at: 41, comments: [HistoryComment(id: "mk_c", time: t(50), text: "Oops")]),
            row(14, "Add comment", by: "user", at: 41.1, kind: .undo),
            row(15, "Music down", by: "claude", at: 50, place: (0, 60, ["A2 Music"])),
        ])

        let result = try ReviewRounds.read(project)

        XCTAssertEqual(result.rounds.count, 2)
        let first = result.rounds[0]
        XCTAssertFalse(first.inferred)
        XCTAssertEqual(first.revision, 2)
        XCTAssertEqual(first.handedBackThings, 3)
        XCTAssertEqual(first.agentEdits, 2)
        XCTAssertEqual(first.comments.map(\.text), ["Awkward pause mid-sentence here"])
        XCTAssertEqual(first.comments.first?.source, .history)
        XCTAssertEqual(first.comments.first?.theme, .pauses)
        XCTAssertEqual(first.firstCommentAfter, 480)
        XCTAssertEqual(first.trims, 2, "the trim, delete and close gap at 10 s are one fix; 40 s is another")
        XCTAssertEqual(first.trimEdits, 4)
        XCTAssertEqual(first.otherEdits, 2, "the blur, and a trim of the B-roll alone")

        let second = result.rounds[1]
        XCTAssertEqual(second.agentEdits, 1)
        XCTAssertEqual(second.comments.map(\.text), ["Show the docs page here instead"], "reworded, and the undone one isn't his")
        XCTAssertEqual(second.commentsReworded, 1)
        XCTAssertEqual(second.comments.first?.theme, .broll)
        XCTAssertEqual(second.undos, 0)

        XCTAssertEqual(result.agentEditsSinceHandback, 1, "the music edit hasn't been handed back")
        XCTAssertEqual(result.total.comments, 2)
        XCTAssertEqual(result.total.trims, 2)
        XCTAssertEqual(result.themes.map(\.theme), [.pauses, .broll], "a tie goes in the usual order")
        let text = result.readableText
        XCTAssertTrue(text.hasPrefix("Launch: 2 review rounds"), text)
        XCTAssertTrue(text.contains("Round 1: handed back"), text)
        XCTAssertTrue(text.contains("at r2 with 3 things to look at, 2 agent edits by claude"), text)
        XCTAssertTrue(text.contains("Mike: 1 comment, the first 8 min after; 2 trims of the take (4 edits), 2 other edits"), text)
        XCTAssertTrue(text.contains("[pauses] Awkward pause mid-sentence here"), text)
        XCTAssertTrue(text.contains("1 agent edit since the last handback, not handed back yet."), text)
    }

    /// Older history has no handbacks and no words: the authors say where
    /// the rounds were, and the saved files say what he wrote.
    func testOlderHistoryInfersRoundsAndFindsTheWordsInSavedFiles() throws {
        try saveProject(revision: 12)
        writeHistory([
            row(0, "Opened", by: "system", at: 0, kind: .opened),
            row(1, "Place the take", by: "claude", at: 1),
            row(2, "Found new media", by: "system", at: 1.5),
            row(3, "Cut the take", by: "claude", at: 2),
            row(4, "Add comment", by: "user", at: 20),
            row(5, "Add comment", by: "user", at: 21),
            row(6, "Your comments", by: "claude", at: 60),
            row(7, "Add comment", by: "user", at: 70),
            row(9, "Add comment", by: "user", at: 80),
            // A quick fix while he watched is part of the round.
            row(10, "Swap the shot", by: "claude", at: 80.5),
            row(11, "Add comment", by: "user", at: 81.5),
            row(12, "Last pass", by: "claude", at: 120),
        ])
        try saveBackup("11.00.00", revision: 3, comments: [])
        try saveBackup("11.30.00", revision: 5, comments: [comment("mk_late", 20, "Cut the umm here"), comment("mk_early", 5, "You can add the B-roll here?")])
        try saveBackup("11.40.00", revision: 6, comments: [comment("mk_late", 20, "Cut the umm here please")])
        try saveExportSnapshot("v1.mp4", at: 75, comments: [comment("mk_music", 30, "Are we using the same music as the intro video?")])
        // Another project's export in the same folder isn't this one's.
        try saveExportSnapshot("Short.mp4", at: 90, comments: [comment("mk_short", 3, "Not this project's")], id: "prj_short")

        let result = try ReviewRounds.read(project)

        XCTAssertEqual(result.rounds.count, 3)
        XCTAssertTrue(result.rounds.allSatisfy(\.inferred))
        XCTAssertEqual(result.rounds.map(\.revision), [3, 6, 12])
        XCTAssertEqual(result.rounds[0].agentEdits, 2)
        XCTAssertEqual(result.rounds[0].comments.map(\.text), ["You can add the B-roll here?", "Cut the umm here please"], "earliest on the timeline first, newest words")
        XCTAssertEqual(result.rounds[0].comments.map(\.source), [.snapshot, .snapshot])
        XCTAssertEqual(result.rounds[0].comments.map(\.theme), [.broll, .clipped])
        XCTAssertEqual(result.rounds[1].comments.map(\.text), ["Are we using the same music as the intro video?", nil, nil])
        XCTAssertEqual(result.rounds[1].missingText, 2)
        XCTAssertEqual(result.rounds[1].agentEditsDuringReview, 1)
        XCTAssertEqual(result.rounds[2].comments.count, 0, "handed back, not watched yet")
        XCTAssertEqual(result.total.comments, 5)
        XCTAssertEqual(result.total.commentsWithText, 3)
        XCTAssertNil(result.agentEditsSinceHandback)
        let text = result.readableText
        XCTAssertTrue(text.contains("(2 comments without words: not in the history, a backup or an export's snapshot)"), text)
        XCTAssertTrue(text.contains("Total: 5 comments in 2 of 3 rounds (words for 3; 2 not kept anywhere)"), text)
        XCTAssertTrue(text.contains("Mike: nothing on the timeline yet"), text)
    }

    /// Tuned on his real comments: the theme whose words come first wins.
    func testCommentsAreSortedIntoThemes() {
        let cases: [(String, CommentTheme)] = [
            ("Again, awkward pause mid-sentence, get rid of it.", .pauses),
            ("Can you get rid of the silence or shorten the silence here after I say I love Expo?", .pauses),
            ("Get rid of my throat clearing here, please.", .clipped),
            ("There's a bad take here that you haven't removed.", .clipped),
            ("I think you can cut out this bit where it actually shows it because I kind of show it like 10 seconds later", .clipped),
            ("Flash these logos on the screen as I say them please.", .broll),
            ("Can you justify that by showing a thread in Threadbear working on a state machine component maybe? Hiding anything private about talking with David", .broll),
            ("Are we using the same music as the intro video?", .music),
            ("The voice is way too quiet here", .levels),
            ("Can we have a swipe here? A section swipe?", .transitions),
            ("Again, the text doesn't show what I actually say as a question here.", .text),
            ("Wow, what's going on with the picture in picture here?", .layout),
            ("Show my face on the screen when I say Who reads the code anymore?", .layout),
            ("It's okay, you don't need to blur out the rest of the thread", .privacy),
            ("Love this bit", .other),
        ]
        for (text, theme) in cases {
            XCTAssertEqual(CommentTheme.classify(text), theme, text)
        }
    }

    /// The channel's log has a line per video; running it again at sign-off
    /// replaces that video's line and leaves the rest.
    func testTheLogKeepsOneLinePerVideo() async throws {
        try saveProject(revision: 3)
        writeHistory([
            row(1, "Cut", by: "claude", at: 1),
            .handback(revision: 1, author: "claude", count: 2, date: at(2)),
            row(2, "Add comment", by: "user", at: 5, comments: [HistoryComment(id: "mk_a", time: t(1), text: "Awkward pause here")]),
            row(3, "Ripple trim", by: "user", at: 6, place: (1, 2, ["V2 Camera"])),
        ])
        let log = folder.appendingPathComponent("review-log.jsonl")
        try Data(#"{"project":"Other video","path":"/videos/other/Other.tandem","comments":4}"#.utf8 + [0x0A]).write(to: log)

        let code = await CLI(arguments: ["rounds", project.path, "--log", log.path], directory: folder, environment: [:]).run()
        XCTAssertEqual(code, 0)
        _ = await CLI(arguments: ["rounds", "--log", log.path], directory: folder, environment: [:]).run()

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "the other video's line stays, and this one's is replaced")
        XCTAssertTrue(lines[0].contains("Other video"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let line = try decoder.decode(RoundsLogLine.self, from: Data(lines[1].utf8))
        XCTAssertEqual(line.project, "Launch")
        XCTAssertEqual(line.path, project.standardizedFileURL.path)
        XCTAssertEqual(line.rounds, 1)
        XCTAssertEqual(line.comments, 1)
        XCTAssertEqual(line.commentsPerRound, [1])
        XCTAssertEqual(line.byTheme, ["pauses": 1])
        XCTAssertEqual(line.trims, 1)
        XCTAssertEqual(line.first, at(1))
        XCTAssertEqual(line.last, at(6))
        // It read the project without taking it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectSession.lockURL(for: project).path))
    }
}
