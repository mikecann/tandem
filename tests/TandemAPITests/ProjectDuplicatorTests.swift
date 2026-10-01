import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// Duplicate on the project list: a project of its own in another folder,
/// playing the same files from where they are.
final class ProjectDuplicatorTests: XCTestCase {
    private var root: URL!
    private var original: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-duplicate-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("eslint", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var project = Project(id: "prj_original", name: "ESLint")
        project.media = [
            MediaItem(id: "med_take", path: "source/take.mov", kind: .video, role: .camera, duration: t(60), hasVideo: true, hasAudio: true),
            MediaItem(id: "med_shared", path: "/Users/shared/Tandem Library/Stickers/Comment below.mov", kind: .video, role: .sticker, duration: t(5), hasVideo: true),
            MediaItem(id: "med_photo", path: "photos/IMG_1.HEIC", kind: .image, role: .image, hasVideo: true, livePhotoVideo: "photos/IMG_1.MOV")
        ]
        let graded = Clip(id: "clip_take", content: .media(mediaID: "med_take"), start: .zero, duration: t(60), video: VideoProperties(effects: [
            Effect(id: "fx_lut", type: "lut", params: ["path": .string("assets/lut/film.cube")])
        ]))
        project.videoTracks = [Track(id: "trk_cam", kind: .video, name: "Camera", clips: [graded])]
        original = folder.appendingPathComponent("ESLint.tandem")
        try ProjectFile.save(project, revision: 42, to: original)
        // Its font, its analysis cache, and an agent edit waiting for review.
        try write("font bytes", to: folder.appendingPathComponent("assets/font/Tilt Warp.ttf"))
        try write("proxy bytes", to: folder.appendingPathComponent(".tandem/cache/proxy/abc123/proxy.mov"))
        var changes = ReviewChanges()
        changes.added = ["clip_take"]
        try ReviewLog(entries: [ReviewEntry(revision: 42, label: "Grade", author: "claude", date: Date(), changes: changes)]).save(to: ProjectFile.reviewURL(for: original))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTheCopyPlaysTheSameFilesFromAnotherFolder() throws {
        let elsewhere = root.appendingPathComponent("new video", isDirectory: true)
        let copy = try ProjectDuplicator.duplicate(original, into: elsewhere)
        XCTAssertEqual(copy.lastPathComponent, "ESLint.tandem")
        XCTAssertEqual(copy.deletingLastPathComponent().standardizedFileURL, elsewhere.standardizedFileURL)

        let (project, revision) = try ProjectFile.load(from: copy)
        let folder = original.deletingLastPathComponent().standardizedFileURL.path
        XCTAssertEqual(project.media(of: "med_take"), "\(folder)/source/take.mov", "back at the original's file")
        XCTAssertEqual(project.media(of: "med_shared"), "/Users/shared/Tandem Library/Stickers/Comment below.mov", "already absolute")
        XCTAssertEqual(project.media.first { $0.id == "med_photo" }?.livePhotoVideo, "\(folder)/photos/IMG_1.MOV")
        XCTAssertEqual(project.clip("clip_take")?.video?.effects.first?.params["path"], .string("\(folder)/assets/lut/film.cube"))
        XCTAssertEqual(project.name, "ESLint")
        XCTAssertNotEqual(project.id, "prj_original", "a project of its own")
        XCTAssertEqual(revision, 42)

        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent("assets/font/Tilt Warp.ttf"), encoding: .utf8), "font bytes", "its titles' font comes too")
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent(".tandem/cache/proxy/abc123/proxy.mov"), encoding: .utf8), "proxy bytes", "no proxies to make again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectFile.reviewURL(for: copy).path), "nothing waiting for review")

        let (unchanged, _) = try ProjectFile.load(from: original)
        XCTAssertEqual(unchanged.media(of: "med_take"), "source/take.mov", "the original is untouched")
        XCTAssertEqual(unchanged.id, "prj_original")
    }

    func testACopyBesideTheOriginalIsNamedCopy() throws {
        let folder = original.deletingLastPathComponent()
        let first = try ProjectDuplicator.duplicate(original, into: folder)
        let second = try ProjectDuplicator.duplicate(original, into: folder)
        XCTAssertEqual(first.lastPathComponent, "ESLint copy.tandem")
        XCTAssertEqual(second.lastPathComponent, "ESLint copy 2.tandem")
        XCTAssertEqual(try ProjectFile.load(from: first).project.media(of: "med_take"), "source/take.mov", "still relative in the same folder")
    }

    func testItNeverReplacesAProjectAlreadyThere() throws {
        let elsewhere = root.appendingPathComponent("busy", isDirectory: true)
        try write("someone else's", to: elsewhere.appendingPathComponent("ESLint.tandem"))
        try write("theirs", to: elsewhere.appendingPathComponent(".tandem/cache/proxy/abc123/proxy.mov"))
        let copy = try ProjectDuplicator.duplicate(original, into: elsewhere)
        XCTAssertEqual(copy.lastPathComponent, "ESLint copy.tandem")
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent("ESLint.tandem"), encoding: .utf8), "someone else's")
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent(".tandem/cache/proxy/abc123/proxy.mov"), encoding: .utf8), "theirs", "a cache file already there is kept")
    }
}

private extension Project {
    func media(of id: String) -> String? {
        media.first { $0.id == id }?.path
    }
}
