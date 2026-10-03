import AVFoundation
import TandemCore
import XCTest
@testable import TandemMedia

/// A webcam's picture lags its mic: Tandem's setting for it, and new
/// camera takes getting it as they join a project.
final class PictureDelayTests: TempFolderTestCase {
    var folder: ProjectFolder { ProjectFolder(root: temp) }

    func testNewCameraTakesGetTheSettingAndNothingElseDoes() async throws {
        try await SyntheticMedia.writeMovie(to: file("source/2026-10-02_122619-camera.mov"), .init(width: 320, height: 180, duration: 1))
        try await SyntheticMedia.writeMovie(to: file("broll/clip.mp4"), .init(width: 320, height: 180, duration: 1))
        let settings = TandemSettings(cameraPictureDelay: 0.08)
        let first = try await MediaScanner.scanReport(folder, known: [], settings: settings)
        let camera = try XCTUnwrap(first.items.first { $0.role == .camera })
        XCTAssertEqual(camera.pictureDelay, Time(seconds: 0.08))
        XCTAssertNil(first.items.first { $0.path == "broll/clip.mp4" }?.pictureDelay, "only camera takes")

        // A take Mike set back to as recorded stays that way on a rescan.
        var known = first.items
        let index = try XCTUnwrap(known.firstIndex { $0.id == camera.id })
        known[index].pictureDelay = nil
        let again = try await MediaScanner.scan(folder, known: known, settings: settings)
        XCTAssertNil(again.first { $0.id == camera.id }?.pictureDelay)

        // Without a setting, nothing changes.
        let plain = try await MediaScanner.scanReport(folder, known: [], settings: TandemSettings())
        XCTAssertNil(plain.items.first { $0.role == .camera }?.pictureDelay)

        // One file dropped in gets it too.
        let dropped = try await MediaScanner.probe(file("source/2026-10-02_122619-camera.mov"), folder: folder, settings: settings)
        XCTAssertEqual(dropped.pictureDelay, Time(seconds: 0.08))
    }

    func testTheSettingsFileReadsBackAndToleratesItsAbsence() throws {
        let url = file("settings/settings.json")
        XCTAssertEqual(TandemSettings.load(from: url), TandemSettings(), "no file: the defaults")
        try TandemSettings(cameraPictureDelay: 0.08).save(to: url)
        XCTAssertEqual(TandemSettings.load(from: url).cameraPictureDelay, 0.08)
        try Data(#"{"cameraPictureDelay": 0.1, "fromANewerTandem": true}"#.utf8).write(to: url)
        XCTAssertEqual(TandemSettings.load(from: url).cameraPictureDelay, 0.1)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(TandemSettings.load(from: url), TandemSettings())
        XCTAssertNotEqual(TandemSettings.url.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tandem/settings.json").path, "tests never use Mike's")
    }

    func testTheDelayRoundTripsInTheProject() throws {
        let item = MediaItem(id: "med_cam", path: "cam.mov", kind: .video, role: .camera, hasVideo: true, hasAudio: true, pictureDelay: Time(seconds: 0.075))
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: data).pictureDelay, Time(seconds: 0.075))
    }
}
