import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// Mike's comments as agents see them: `tandem comments` (and the MCP
/// tool), and clearing the ones they've done.
final class CommentsTests: XCTestCase {
    private func projectWithComments() -> Project {
        var project = APIFixture.project()
        project.markers += [
            Marker(id: "mk_late", time: t(31), name: "Too quick after the cut", kind: .comment),
            Marker(id: "mk_early", time: t(5.2), name: "B-roll here\nthe servers one", kind: .comment)
        ]
        return project
    }

    func testEachCommentComesWithWhatsSaidAndPlayingThere() throws {
        let h = try ServiceHarness(project: projectWithComments())
        defer { h.close() }
        let result = h.service.comments()
        XCTAssertEqual(result.comments.map(\.id), ["mk_early", "mk_late"], "earliest first, and not the section marker")

        let early = result.comments[0]
        XCTAssertEqual(early.text, "B-roll here\nthe servers one")
        XCTAssertEqual(early.said, "today we talk about decision models. They | help you choose fast. Decision models matter.")
        XCTAssertEqual(early.clips.map(\.clipID), ["clip_cam1", "clip_scr1", "clip_voc1", "clip_mus1"], "top track first")
        XCTAssertEqual(early.clips.first?.track, "V2 Camera")

        let late = result.comments[1]
        XCTAssertEqual(late.said, "Second section. Now let's | look at decision models again.", "across the cut, in timeline time")
        XCTAssertEqual(late.clips.map(\.clipID), ["clip_cam2", "clip_scr2", "clip_voc2", "clip_mus1"])

        let text = result.readableText
        XCTAssertTrue(text.hasPrefix("2 comments from Mike, earliest first (revision 1):"), text)
        XCTAssertTrue(text.contains("mk_early  00:05.200  \"B-roll here / the servers one\""), text)
        XCTAssertTrue(text.contains("  said: today we talk"), text)
        XCTAssertTrue(text.contains("V2 Camera  clip_cam1  00:00.000-00:30.000  take1-camera.mov [00:00.000-00:30.000]"), text)
        XCTAssertTrue(text.contains(#"{"removeMarker": {"markerID": "<id>"}}"#), "how to clear one: \(text)")
    }

    func testNoCommentsSaysWhereTheyComeFrom() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = h.service.comments()
        XCTAssertTrue(result.comments.isEmpty)
        XCTAssertTrue(result.readableText.hasPrefix("No comments (revision 1)."), result.readableText)
    }

    func testTheMCPToolListsThem() throws {
        let tool = try XCTUnwrap(MCPTools.named("comments"))
        XCTAssertEqual(tool.operation, .comments)
        XCTAssertTrue(MCPServer.instructions.contains("`comments`"))
    }
}

/// `tandem comments` and `tandem comments resolve`, run as agents run them.
final class CommentsCLITests: XCTestCase {
    private let cli = CLITests()

    func testAnAgentListsThemAndClearsTheOnesItDid() throws {
        let folder = TempFolder()
        var project = APIFixture.project()
        project.markers += [
            Marker(id: "mk_one", time: t(12), name: "Cut the umm", kind: .comment),
            Marker(id: "mk_two", time: t(40), name: "Louder music here", kind: .comment)
        ]
        let url = try APIFixture.write(to: folder.url, project: project)

        let listed = try cli.tandem("comments", in: folder.url)
        XCTAssertEqual(listed.status, 0, listed.stderr)
        XCTAssertTrue(listed.stdout.contains("mk_one  00:12.000  \"Cut the umm\""), listed.stdout)

        let resolved = try cli.tandem("comments", "resolve", "mk_one", "--author", "claude", in: folder.url)
        XCTAssertEqual(resolved.status, 0, resolved.stderr)
        XCTAssertTrue(resolved.stdout.contains("Applied \"Resolve comment\" by claude"), resolved.stdout)
        XCTAssertEqual(try ProjectFile.load(from: url).project.comments.map(\.id), ["mk_two"])

        let notAComment = try cli.tandem("comments", "resolve", "mk_s2", in: folder.url)
        XCTAssertEqual(notAComment.status, 2)
        XCTAssertTrue(notAComment.stderr.contains("mk_s2 isn't one of Mike's comments"), notAComment.stderr)

        let nothing = try cli.tandem("comments", "resolve", in: folder.url)
        XCTAssertEqual(nothing.status, 2)
        XCTAssertTrue(nothing.stderr.contains("needs the IDs"), nothing.stderr)

        let all = try cli.tandem("comments", "resolve", "--all", in: folder.url)
        XCTAssertEqual(all.status, 0, all.stderr)
        let after = try ProjectFile.load(from: url).project
        XCTAssertTrue(after.comments.isEmpty)
        XCTAssertEqual(after.markers.map(\.id), ["mk_s2"], "the section marker stays")
    }
}
