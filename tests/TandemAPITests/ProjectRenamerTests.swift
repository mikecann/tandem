import XCTest
@testable import TandemAPI
@testable import TandemCore

/// Rename on the project list: the file and the name Tandem shows, with
/// everything the project had beside it.
final class ProjectRenamerTests: XCTestCase {
    private var folder: URL!
    private var project: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        project = folder.appendingPathComponent("ESLint.tandem")
        try ProjectFile.save(Project(id: "prj_eslint", name: "ESLint"), revision: 7, to: project)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func testTheFileTheNameAndEverythingBesideItMove() throws {
        let support = folder.appendingPathComponent(".tandem", isDirectory: true)
        try write("review", to: ProjectFile.reviewURL(for: project))
        try write("undo", to: ProjectFile.undoHistoryURL(for: project))
        try write("journal", to: ProjectFile.journalURL(for: project))
        try write("icon", to: support.appendingPathComponent("ESLint.icon.png"))
        try write("old save", to: support.appendingPathComponent("backups/ESLint 2026-09-30 10.00.00.tandem"))
        try write("stale lock", to: support.appendingPathComponent("ESLint.lock"))
        try write("theirs", to: support.appendingPathComponent("backups/ESLint v2 2026-09-30 10.00.00.tandem"))

        let renamed = try ProjectRenamer.rename(project, to: "  Experimental video ")
        XCTAssertEqual(renamed.lastPathComponent, "Experimental video.tandem")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
        let (loaded, revision) = try ProjectFile.load(from: renamed)
        XCTAssertEqual(loaded.name, "Experimental video", "the name Tandem shows")
        XCTAssertEqual(loaded.id, "prj_eslint", "still the same project")
        XCTAssertEqual(revision, 7)

        XCTAssertEqual(read(ProjectFile.reviewURL(for: renamed)), "review", "agent edits still wait for review")
        XCTAssertEqual(read(ProjectFile.undoHistoryURL(for: renamed)), "undo")
        XCTAssertEqual(read(ProjectFile.journalURL(for: renamed)), "journal")
        XCTAssertEqual(read(support.appendingPathComponent("Experimental video.icon.png")), "icon")
        XCTAssertEqual(read(support.appendingPathComponent("backups/Experimental video 2026-09-30 10.00.00.tandem")), "old save")
        XCTAssertEqual(read(support.appendingPathComponent("backups/ESLint v2 2026-09-30 10.00.00.tandem")), "theirs", "another project's backups stay")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("ESLint.lock").path))
    }

    func testWhatAnOlderFileOfTheNewNameLeftBehindIsCleared() throws {
        let leftover = ProjectFile.reviewURL(for: folder.appendingPathComponent("Renamed.tandem"))
        try write("someone else's review", to: leftover)
        let renamed = try ProjectRenamer.rename(project, to: "Renamed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectFile.reviewURL(for: renamed).path), "not attached to this project")
    }

    func testOnlyTheCaseCanChange() throws {
        let renamed = try ProjectRenamer.rename(project, to: "Eslint")
        XCTAssertEqual(renamed.lastPathComponent, "Eslint.tandem")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tandem") && !$0.hasPrefix(".") }
        XCTAssertEqual(names, ["Eslint.tandem"])
        XCTAssertEqual(try ProjectFile.load(from: renamed).project.name, "Eslint")
    }

    func testItWontTakeANameInUseOrOneAFileCantHave() throws {
        try ProjectFile.save(Project(name: "Other"), revision: 1, to: folder.appendingPathComponent("Other.tandem"))
        for (name, reason) in [("Other", "already a project called Other"), ("", "Give it a name"), ("a/b", "can't have / or :"), (".hidden", "can't start with a full stop")] {
            XCTAssertThrowsError(try ProjectRenamer.rename(project, to: name), name) { error in
                XCTAssertTrue((error as? ServiceError)?.message.contains(reason) == true, "\(name): \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path), "nothing moved")
    }

    func testItWontRenameAProjectSomethingHasOpen() throws {
        let lockURL = ProjectSession.lockURL(for: project)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard case .acquired(let lock) = try LockHandle.acquire(lockURL, lock: ProjectSession.Lock(pid: 1, owner: .app, started: Date())) else {
            return XCTFail("couldn't take the lock")
        }
        defer { lock.release() }
        XCTAssertThrowsError(try ProjectRenamer.rename(project, to: "Renamed")) { error in
            XCTAssertEqual((error as? ServiceError)?.code, "locked")
            XCTAssertTrue((error as? ServiceError)?.message.contains("open in the Tandem app") == true, "\(error)")
        }
    }
}
