import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tandem claims`: the claims file it writes beside the project and reads
/// the agent's answers back from, through a cut that moves the lines, the
/// list for Mike, and the bareClaim notes `tandem check` reads from it.
final class ClaimsAPITests: XCTestCase {
    /// Mike on camera full screen (no picture-in-picture), naming things.
    static let transcript = Transcript(language: "en", engine: "fake", words: [
        "So today we compare Clerk and WorkOS.",
        "It's really nice to have it all in one place.",
        "There's no per user billing at all.",
        "Decision models matter."
    ].enumerated().flatMap { line, text in
        text.split(separator: " ").enumerated().map { index, word in
            TranscriptWord(text: String(word), start: t(1 + Double(line) * 6 + Double(index) * 0.4), end: t(1.3 + Double(line) * 6 + Double(index) * 0.4))
        }
    })

    private func harness() throws -> ServiceHarness {
        var project = APIFixture.project()
        for index in project.videoTracks[1].clips.indices { project.videoTracks[1].clips[index].video = nil }
        // Nothing over him but the B-roll and title the fixture has.
        project.videoTracks[4].clips = []
        let h = try ServiceHarness(project: project)
        h.analysis.transcripts["med_camera"] = Self.transcript
        return h
    }

    private func readFile(_ h: ServiceHarness) throws -> [String: JSONValue] {
        let data = try Data(contentsOf: ProjectFile.claimsURL(for: h.url))
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw XCTSkip("not an object") }
        return fields
    }

    /// Fills in answers in the file as an agent would, by editing its JSON.
    private func answer(_ h: ServiceHarness, _ answers: [String: [String: String]]) throws {
        let url = ProjectFile.claimsURL(for: h.url)
        var file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var claims = file["claims"] as! [[String: Any]]
        for index in claims.indices {
            guard let id = claims[index]["id"] as? String, let given = answers[id] else { continue }
            for (key, value) in given { claims[index][key] = value }
        }
        file["claims"] = claims
        try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted]).write(to: url)
    }

    func testTheClaimsFileIsWrittenFilledInAndReadBackThroughACut() async throws {
        let h = try harness()
        defer { h.close() }
        let first = try h.service.claims(ClaimsRequest())
        XCTAssertEqual(first.claims.map(\.said), ["So today we compare Clerk and WorkOS.", "There's no per user billing at all."])
        XCTAssertEqual(first.claims.first?.because, ["Clerk", "WorkOS"])
        XCTAssertEqual(first.claims.first?.onScreen, [], "camera only")
        XCTAssertEqual(first.claims.first?.bare ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(first.file, ProjectFile.claimsURL(for: h.url).path)
        XCTAssertTrue(first.file.hasSuffix("/Decision Models.claims.json"), "beside the project, named for it")
        XCTAssertTrue(first.readableText.hasPrefix("2 lines that name something or make a claim (revision 1): 0 answered, 2 to fill in, 2 bare on camera with no skip."), first.readableText)
        XCTAssertTrue(first.readableText.contains("on screen: camera only"), first.readableText)

        // The file reads the line before the answers to fill in, each empty.
        let text = try String(contentsOf: ProjectFile.claimsURL(for: h.url), encoding: .utf8)
        let said = try XCTUnwrap(text.range(of: "\"said\""))
        let shot = try XCTUnwrap(text.range(of: "\"shot\": \"\""))
        XCTAssertLessThan(said.lowerBound, shot.lowerBound, text)
        XCTAssertTrue(text.contains("\"onScreen\": \"camera only\""), text)
        // The order it's read in, every time: the line, then the answers.
        let order = ["\"id\"", "\"at\"", "\"to\"", "\"said\"", "\"because\"", "\"onScreen\"", "\"shot\"", "\"link\"", "\"skip\""].compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(order, order.sorted(), text)

        let ids = first.claims.map(\.id)
        try answer(h, [
            ids[0]: ["shot": "broll/clerk-vs-workos.png", "link": "https://clerk.com/pricing"],
            ids[1]: ["skip": "the title says it"]
        ])
        // A cut before both lines moves them half a second earlier.
        try h.apply(.cutRanges(ranges: [TimeRange(start: t(0.2), end: t(0.7))]), label: "Trim the start")
        let markdown = h.folder.url.appendingPathComponent("claims.md")
        let again = try h.service.claims(ClaimsRequest(markdown: markdown.path))
        XCTAssertEqual(again.claims.map(\.id), ids, "the IDs come from the words")
        XCTAssertEqual(again.claims.first?.start.seconds ?? 0, (first.claims.first?.start.seconds ?? 0) - 0.5, accuracy: 0.01)
        XCTAssertEqual(again.claims.first?.shot, "broll/clerk-vs-workos.png")
        XCTAssertEqual(again.claims.first?.link, "https://clerk.com/pricing")
        XCTAssertEqual(again.claims.last?.skip, "the title says it")
        XCTAssertEqual(again.markdown, markdown.path)
        XCTAssertEqual(again.warnings, [])

        let list = try String(contentsOf: markdown, encoding: .utf8)
        XCTAssertTrue(list.hasPrefix("# What goes on screen: Decision Models\n"), list)
        XCTAssertTrue(list.contains("- **0:00** \"So today we compare Clerk and WorkOS.\"\n  broll/clerk-vs-workos.png [clerk.com/pricing](https://clerk.com/pricing)"), list)
        XCTAssertTrue(list.contains("  Nothing extra: the title says it"), list)

        // Both are answered, so the file keeps them; check notes the one
        // still bare whose shot isn't placed yet, and not the skip.
        let check = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        let bare = check.notes.filter { $0.kind == .bareClaim }
        XCTAssertEqual(bare.map(\.start), [again.claims[0].start])
        XCTAssertTrue(bare.first?.message.contains("plans \"broll/clerk-vs-workos.png\"") ?? false, bare.first?.message ?? "")
    }

    func testALineCutFromTheTimelineKeepsItsAnswerUnderGone() throws {
        let h = try harness()
        defer { h.close() }
        let first = try h.service.claims(ClaimsRequest())
        try answer(h, [first.claims[1].id: ["shot": "pricing table"]])
        // Cut the billing line out.
        let line = first.claims[1]
        try h.apply(.cutRanges(ranges: [TimeRange(start: line.start - t(0.1), end: line.end + t(0.1))]), label: "Cut the billing line")
        let after = try h.service.claims(ClaimsRequest())
        XCTAssertEqual(after.claims.map(\.id), [first.claims[0].id])
        XCTAssertEqual(after.gone.map(\.shot), ["pricing table"])
        XCTAssertTrue(after.readableText.contains("1 answered line is no longer said on the timeline"), after.readableText)
        guard case .array(let gone)? = try readFile(h)["gone"] else { return XCTFail("no gone list in the file") }
        XCTAssertEqual(gone.count, 1)
        // Undone, the line and its answer come back.
        _ = try h.service.undo(expectedRevision: nil)
        let back = try h.service.claims(ClaimsRequest())
        XCTAssertEqual(back.claims.last?.shot, "pricing table")
        XCTAssertEqual(back.gone, [])
    }

    func testABrokenFileIsntWrittenOverAndCheckSaysSo() async throws {
        let h = try harness()
        defer { h.close() }
        let url = ProjectFile.claimsURL(for: h.url)
        try Data("{\"claims\": [{\"said\": \"x\", \"shot\": \"oops\"".utf8).write(to: url)
        assertServiceError(.badRequest) { _ = try h.service.claims(ClaimsRequest()) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"claims\": [{\"said\": \"x\", \"shot\": \"oops\"", "left for the agent to fix")
        let check = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertTrue(check.warnings.contains { $0.contains("Couldn't read the claims file") }, "\(check.warnings)")
        XCTAssertEqual(check.notes.filter { $0.kind == .bareClaim }.count, 2)
        assertServiceError(.badRequest) { _ = try h.service.claims(ClaimsRequest(markdown: "claims.png")) }
    }

    func testTheClaimsFileAndTheListArentMedia() throws {
        // Tandem watches the folder for media: neither file may become a clip.
        XCTAssertNil(MediaScanner.mediaKind(forPath: "Decision Models.claims.json"))
        XCTAssertNil(MediaScanner.mediaKind(forPath: "claims.md"))
        let h = try harness()
        defer { h.close() }
        _ = try h.service.claims(ClaimsRequest(markdown: "claims.md"))
        let found = MediaScanner.mediaFiles(in: h.session.folder).map(\.lastPathComponent)
        XCTAssertFalse(found.contains("Decision Models.claims.json"), "\(found)")
        XCTAssertFalse(found.contains("claims.md"), "\(found)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.folder.url.appendingPathComponent("claims.md").path), "relative to the project folder")
    }

    func testRenamingTheProjectTakesItsClaimsFileAlong() throws {
        let h = try harness()
        _ = try h.service.claims(ClaimsRequest())
        h.close()
        let renamed = try ProjectRenamer.rename(h.url, to: "Decision Models v2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectFile.claimsURL(for: renamed).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectFile.claimsURL(for: h.url).path))
    }
}
