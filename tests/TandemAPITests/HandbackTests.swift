import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// Handing a round back with the places Mike should look at first:
/// `tandem handback` (and the MCP tool), what status says, and what the
/// next round sees.
final class HandbackTests: XCTestCase {
    func testHandingBackRecordsThemInTimelineOrderAndStatusSaysSo() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let given = [
            HandbackNote(at: t(40), to: t(44), name: "The new shot"),
            HandbackNote(at: t(2), to: t(6), name: "Angles: ten zooms became two here", note: "The busiest stretch.\nIf this reads OK the rest will."),
            HandbackNote(at: t(50), name: "Keep this line?", question: true)
        ]
        let result = try h.service.handback(HandbackRequest(notes: given), context: h.context)
        XCTAssertEqual(result.recorded, 3)
        XCTAssertEqual(result.notes.map(\.name), ["Angles: ten zooms became two here", "The new shot", "Keep this line?"], "timeline order")
        XCTAssertEqual(result.notes.map(\.author), ["claude", "claude", "claude"])
        XCTAssertEqual(result.notes[2].end, t(55), "a stretch of 5 s unless told otherwise")
        XCTAssertEqual(result.notes[2].question, true)
        XCTAssertEqual(result.notes[0].note, "The busiest stretch.\nIf this reads OK the rest will.")
        XCTAssertTrue(result.readableText.hasPrefix("Handed back 3 things to look at (revision 1)."), result.readableText)
        XCTAssertTrue(result.readableText.contains("00:02.000-00:06.000  look from claude: Angles: ten zooms became two here"), result.readableText)
        XCTAssertTrue(result.readableText.contains("  note: The busiest stretch. / If this reads OK the rest will."), result.readableText)
        XCTAssertTrue(result.readableText.contains("00:50.000-00:55.000  question from claude: Keep this line?"), result.readableText)

        let status = h.service.status()
        XCTAssertEqual(status.handback?.map(\.name), result.notes.map(\.name))
        XCTAssertTrue(status.readableText.contains("things to look at, handed back and not yet watched: 3 (00:02.000 Angles: ten zooms became two here; 00:40.000 The new shot; 00:50.000 Keep this line?)"), status.readableText)
        XCTAssertFalse(status.readableText.contains("waiting for Mike's review"), "nothing was edited, so nothing blocks the next round")
    }

    /// Next round: what's left, with Mike's comment beside a question as
    /// his answer, and a fresh handback taking the old one's place.
    func testListingShowsWhatsLeftAndHisAnswers() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        _ = try h.service.handback(HandbackRequest(notes: [
            HandbackNote(at: t(10), to: t(14), name: "The new shot"),
            HandbackNote(at: t(50), to: t(52), name: "Keep this line?", question: true)
        ]), context: h.context)
        // Mike watched the first and answered the second.
        h.session.review.markWatched([TimeRange(start: t(9), end: t(15))], in: h.session.coordinator.project)
        try h.apply(.addMarker(marker: Marker(id: "mk_ans", time: t(53), name: "Yes keep it, I like it", kind: .comment)), label: "Add comment")

        let listed = try h.service.handback(HandbackRequest(), context: h.context)
        XCTAssertNil(listed.recorded)
        XCTAssertEqual(listed.notes.map(\.name), ["Keep this line?"])
        XCTAssertEqual(listed.notes.first?.comments.map(\.text), ["Yes keep it, I like it"], "within 2 s of the stretch")
        XCTAssertTrue(listed.readableText.hasPrefix("1 thing still waiting for Mike to look at (revision 2)"), listed.readableText)
        XCTAssertTrue(listed.readableText.contains("  Mike's comment at 00:53.000: \"Yes keep it, I like it\""), listed.readableText)

        let again = try h.service.handback(HandbackRequest(notes: [HandbackNote(at: t(20), name: "Round two")]), context: h.context)
        XCTAssertEqual(again.notes.map(\.name), ["Round two"], "the old round's notes go")
        let withdrawn = try h.service.handback(HandbackRequest(notes: []), context: h.context)
        XCTAssertEqual(withdrawn.notes, [])
        XCTAssertEqual(withdrawn.recorded, 0)
        let nothing = try h.service.handback(HandbackRequest(), context: h.context)
        XCTAssertTrue(nothing.readableText.hasPrefix("Nothing handed back is waiting (revision 2)"), nothing.readableText)
    }

    func testBadNotesAreRefusedWithTheReason() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        func refused(_ note: HandbackNote, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try h.service.handback(HandbackRequest(notes: [note]), context: h.context), file: file, line: line) { error in
                let message = (error as? ServiceError)?.message ?? "\(error)"
                XCTAssertTrue(message.contains(expected), message, file: file, line: line)
            }
        }
        refused(HandbackNote(at: t(10), name: "  "), "needs a name")
        refused(HandbackNote(at: t(61), name: "Past the end"), "past the end of the timeline (01:00.000)")
        refused(HandbackNote(at: t(10), to: t(8), name: "Backwards"), "ends (00:08.000) before it starts (00:10.000)")
        // The card has to read at a glance: a long name or note is refused, not clipped.
        refused(HandbackNote(at: t(10), name: "Cold open with the trailer bed, its final hit on the cut into your first line"), "is 77 characters. Mike reads the name off a small card at a glance, so keep it to 40")
        refused(HandbackNote(at: t(10), name: "Cold open music", note: "Placed at revision 169 from the option 2 preview you picked, about 8 LU under the voices, fading over 0.5 s after the cut."), "is 122 characters. It's one short line under the name")
        XCTAssertTrue(h.session.review.log.notes.isEmpty, "none of them was recorded")
        // 40 and 80 are the limits themselves, not past them.
        let fits = HandbackNote(at: t(10), name: String(repeating: "n", count: 40), note: String(repeating: "o", count: 80))
        XCTAssertEqual(try h.service.handback(HandbackRequest(notes: [fits]), context: h.context).recorded, 1)
        _ = try h.service.handback(HandbackRequest(notes: []), context: h.context)
        // A stretch running past the end is cut to it.
        let clipped = try h.service.handback(HandbackRequest(notes: [HandbackNote(at: t(58), to: t(70), name: "The outro")]), context: h.context)
        XCTAssertEqual(clipped.notes.first?.end, t(60))
    }

    func testTheMCPToolExists() throws {
        let tool = try XCTUnwrap(MCPTools.named("handback"))
        XCTAssertEqual(tool.operation, .handback)
        XCTAssertFalse(tool.readOnly)
        XCTAssertTrue(MCPServer.instructions.contains("`handback`"))
    }
}

/// `tandem handback`, run as agents run it, with the app closed: the notes
/// wait in the review log for the app to open the project.
final class HandbackCLITests: XCTestCase {
    private let cli = CLITests()

    func testAnAgentHandsBackAndTheAppFindsIt() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let list = #"[{"at": "0:40", "to": "0:44", "name": "The new shot"}, {"at": 2, "name": "Angles", "note": "The busiest stretch", "question": false}]"#
        let handed = try cli.tandem("handback", list, "--author", "claude", in: folder.url)
        XCTAssertEqual(handed.status, 0, handed.stderr)
        XCTAssertTrue(handed.stdout.hasPrefix("Handed back 2 things to look at"), handed.stdout)

        let listed = try cli.tandem("handback", in: folder.url)
        XCTAssertEqual(listed.status, 0, listed.stderr)
        XCTAssertTrue(listed.stdout.hasPrefix("2 things still waiting"), listed.stdout)
        XCTAssertTrue(listed.stdout.contains("00:02.000-00:07.000  look from claude: Angles"), listed.stdout)

        let status = try cli.tandem("status", in: folder.url)
        XCTAssertTrue(status.stdout.contains("things to look at, handed back and not yet watched: 2"), status.stdout)

        // One from flags, as Codex: it sits beside Claude's.
        let one = try cli.tandem("handback", "--at", "50", "--name", "Keep this line?", "--note", "Pro is $25", "--question", "--author", "codex", in: folder.url)
        XCTAssertEqual(one.status, 0, one.stderr)
        XCTAssertTrue(one.stdout.contains("question from codex: Keep this line?"), one.stdout)

        let app = try ProjectSession.open(url, owner: .app)
        defer { app.close() }
        XCTAssertEqual(app.review.log.notes.map(\.name), ["Angles", "The new shot", "Keep this line?"])
        XCTAssertEqual(app.review.log.notes.map(\.author), ["claude", "claude", "codex"])
    }

    func testUsageMistakesAreExplained() throws {
        let folder = TempFolder()
        _ = try APIFixture.write(to: folder.url)
        let both = try cli.tandem("handback", "[]", "--at", "2", in: folder.url)
        XCTAssertEqual(both.status, 2)
        XCTAssertTrue(both.stderr.contains("Give the JSON list or --at, not both."), both.stderr)
        let noName = try cli.tandem("handback", "--at", "2", in: folder.url)
        XCTAssertEqual(noName.status, 2)
        XCTAssertTrue(noName.stderr.contains("--at needs --name"), noName.stderr)
        let noAt = try cli.tandem("handback", "--name", "Angles", in: folder.url)
        XCTAssertEqual(noAt.status, 2)
        XCTAssertTrue(noAt.stderr.contains("--name goes with --at"), noAt.stderr)
        let broken = try cli.tandem("handback", #"[{"to": "0:44", "name": "No start"}]"#, in: folder.url)
        XCTAssertEqual(broken.status, 2)
        XCTAssertTrue(broken.stderr.contains("Couldn't read the things to look at"), broken.stderr)
        XCTAssertTrue(broken.stderr.contains("only at and name are needed"), broken.stderr)
    }
}
