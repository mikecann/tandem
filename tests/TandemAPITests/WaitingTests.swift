import XCTest
@testable import TandemAPI
@testable import TandemCore

/// `tandem waiting`: what waits in every project in a folder, read in one
/// process without opening any of them, for Threadbear's Tandem panel.
final class WaitingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-waiting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func t(_ seconds: Double) -> Time { Time(seconds: seconds) }

    @discardableResult
    private func project(_ name: String, markers: [Marker] = [], revision: Int = 3) throws -> URL {
        let url = folder.appendingPathComponent("\(name).tandem")
        try ProjectFile.save(Project(id: "prj_\(name.count)", name: name, markers: markers), revision: revision, to: url)
        return url
    }

    private func writeReview(_ json: String, for url: URL) throws {
        let review = ProjectFile.reviewURL(for: url)
        try FileManager.default.createDirectory(at: review.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: review)
    }

    func testReadsEveryProjectInTheFolderWithoutOpeningThem() async throws {
        let long = try project("Interview", markers: [
            Marker(id: "mk_late", time: t(31), name: "Too quick after the cut", kind: .comment),
            Marker(id: "mk_early", time: t(5), name: "B-roll here", kind: .comment),
            Marker(id: "mk_plain", time: t(9), name: "Chapter", kind: .marker),
        ])
        let short = try project("Short 01")
        try writeReview("""
        {"version": 1,
         "entries": [{"revision": 2, "label": "Cut to the exchange", "author": "claude", "date": "2026-11-03T03:28:13Z"}],
         "notes": [{"id": "look_a", "author": "claude", "date": "2026-11-03T03:30:00Z", "revision": 2, "start": 12, "end": 14, "name": "New hook", "question": true}]}
        """, for: short)
        let before = try Data(contentsOf: long)

        let result = await ProjectsWaiting.read(try ProjectLocator.all([], in: folder), author: "test")

        XCTAssertEqual(result.projects.map(\.name), ["Interview", "Short 01"])
        XCTAssertEqual(result.projects[0].comments.map(\.id), ["mk_early", "mk_late"], "comments only, earliest first")
        XCTAssertEqual(result.projects[0].comments.first?.text, "B-roll here")
        XCTAssertEqual(result.projects[0].revision, 3)
        XCTAssertEqual(result.projects[1].reviewPending.map(\.label), ["Cut to the exchange"])
        XCTAssertEqual(result.projects[1].handback.map(\.name), ["New hook"])
        XCTAssertEqual(result.projects[1].handback.first?.question, true)
        // No lock taken, nothing written: the app can open any of them meanwhile.
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectSession.lockURL(for: long).path))
        XCTAssertEqual(try Data(contentsOf: long), before)
    }

    func testAgreesWithStatusAndComments() async throws {
        let url = try project("Interview", markers: [Marker(id: "mk_a", time: t(4), name: "Cut the umm", kind: .comment)])
        try writeReview("""
        {"version": 1, "entries": [], "notes": [{"id": "look_a", "author": "claude", "date": "2026-11-03T03:30:00Z", "revision": 3, "start": 2, "end": 3, "name": "Look here", "note": "the zoom"}]}
        """, for: url)

        let light = await ProjectsWaiting.read([url], author: "test").projects[0]
        let client = ProjectClient(projectURL: url, author: "test")
        let status = try await client.call(StatusRequest())
        let comments = try await client.call(CommentsRequest())

        XCTAssertEqual(light.name, status.name)
        XCTAssertEqual(light.revision, status.revision)
        XCTAssertEqual(light.handback, status.handback ?? [])
        XCTAssertEqual(light.reviewPending, status.reviewPending ?? [])
        XCTAssertEqual(light.comments.map(\.id), comments.comments.map(\.id))
        XCTAssertEqual(light.comments.map(\.text), comments.comments.map(\.text))
    }

    func testCountsACommentACrashLeftInTheJournal() async throws {
        let url = try project("Interview", revision: 3)
        let journal = ProjectJournal.forProject(at: url)
        journal.append(batch: CommentEdits.add("Trim the pause", at: t(8), id: "mk_lost")!, revision: 4, seed: 1)

        let result = await ProjectsWaiting.read([url], author: "test").projects[0]

        XCTAssertEqual(result.comments.map(\.id), ["mk_lost"])
        XCTAssertEqual(result.revision, 4)
    }

    func testABrokenProjectDoesntHideTheOthers() async throws {
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("Broken.tandem"))
        try project("Short 02", markers: [Marker(id: "mk_a", time: t(1), name: "Louder", kind: .comment)])

        let result = await ProjectsWaiting.read(try ProjectLocator.all([folder.path], in: folder), author: "test")

        XCTAssertEqual(result.projects.map(\.name), ["Broken", "Short 02"])
        XCTAssertNotNil(result.projects[0].error)
        XCTAssertEqual(result.projects[1].comments.map(\.id), ["mk_a"])
    }

    func testFindsTheNearestFolderWithProjects() throws {
        try project("Interview")
        try project("Short 01")
        let inside = folder.appendingPathComponent("shorts/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        // An export's record of the project it rendered isn't a project.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("review.mp4.tandem"))

        XCTAssertEqual(try ProjectLocator.all([], in: inside).map(\.lastPathComponent), ["Interview.tandem", "Short 01.tandem"])
    }
}
