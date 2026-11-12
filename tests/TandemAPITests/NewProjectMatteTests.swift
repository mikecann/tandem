import XCTest
@testable import TandemAPI
@testable import TandemCLI
@testable import TandemCore

/// `tandem new` says to start the cutout matte straight away: a long 4K
/// take mattes for hours, and on the Convex Auth v2 video (12 Nov 2026) the
/// agent framed Mike's face in a box while it ran instead.
final class NewProjectMatteTests: XCTestCase {
    func testNewSaysToStartTheMatteForALandscapeTake() {
        var project = Project.standard(name: "Convex Auth v2")
        project.settings.width = 3840
        project.settings.height = 2160
        let take = MediaItem(id: "med_cam", path: "source/2026-11-12_111045-camera.mov", kind: .video, role: .camera, duration: Time(seconds: 8 * 60 + 10), width: 3840, height: 2160, hasVideo: true, hasAudio: true)
        let line = CLI.matteLine([take], in: project) ?? ""
        XCTAssertTrue(line.contains("Start the cutout matte now"), line)
        XCTAssertTrue(line.contains("an 8-minute 4K take"), line)
        XCTAssertTrue(line.contains(#""preset": "pipRight""#), line)

        project.settings.width = 1080
        project.settings.height = 1920
        XCTAssertNil(CLI.matteLine([take], in: project), "a Short's face box has the cutout off")
        let voice = MediaItem(id: "med_mic", path: "source/mic.m4a", kind: .audio, role: .camera, duration: Time(seconds: 600), hasAudio: true)
        project.settings.width = 3840
        project.settings.height = 2160
        XCTAssertNil(CLI.matteLine([voice], in: project), "a voice take has nothing to matte")
    }
}
