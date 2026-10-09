import CoreGraphics
import XCTest
import TandemCore
@testable import TandemRender

/// Dead air and page changes on synthetic media, rendered and measured by
/// the real scanner: a screen-like picture that turns a page, types and
/// scrolls, and an edit with a still pause, an animated one and a short
/// sentence pause, with Mike moving about in his corner the whole time.
final class CheckScanTests: XCTestCase {
    static let size = CGSize(width: 320, height: 180)

    /// A page of dim text on a dark background, like Mike's explainers.
    /// Layout 0 is lines of text; 1 is two panels of rows, which `scroll`
    /// moves up; 2 is a chapter title.
    static func drawPage(_ c: CGContext, layout: Int, scroll: CGFloat = 0) {
        TestMedia.fill(c, 0.08, 0.08, 0.09)
        c.setFillColor(CGColor(gray: 0.45, alpha: 1))
        switch layout {
        case 0:
            for line in 0..<14 {
                let length = CGFloat(60 + (line * 7 % 9) * 24)
                c.fill(CGRect(x: 16, y: 14 + CGFloat(line) * 11, width: min(length, size.width - 32), height: 5))
            }
        case 1:
            for row in 0..<30 {
                let y = 24 + CGFloat(row) * 14 - scroll
                guard y > -8, y < size.height else { continue }
                c.fill(CGRect(x: 30, y: y, width: CGFloat(40 + (row * 5 % 7) * 9), height: 6))
                c.fill(CGRect(x: 180, y: y + 4, width: CGFloat(30 + (row * 3 % 5) * 20), height: 6))
            }
            c.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
            c.stroke(CGRect(x: 20, y: 12 - scroll, width: 130, height: 420), width: 2)
            c.stroke(CGRect(x: 170, y: 16 - scroll, width: 140, height: 420), width: 2)
        default:
            c.setFillColor(CGColor(gray: 0.9, alpha: 1))
            c.fill(CGRect(x: 24, y: 60, width: 200, height: 26))
            c.setFillColor(CGColor(srgbRed: 0.9, green: 0.6, blue: 0.2, alpha: 1))
            c.fill(CGRect(x: 24, y: 98, width: 150, height: 10))
            c.setFillColor(CGColor(gray: 0.35, alpha: 1))
            c.fill(CGRect(x: 24, y: 130, width: 270, height: 3))
        }
    }

    /// Mike in his corner: a blob that never keeps still.
    static func drawCamera(_ frame: Int, _ c: CGContext) {
        TestMedia.fill(c, 0.25, 0.3, 0.35)
        c.setFillColor(CGColor(srgbRed: 0.8, green: 0.6, blue: 0.5, alpha: 1))
        let sway = CGFloat((frame * 7) % 23)
        c.fillEllipse(in: CGRect(x: 110 + sway, y: 40 + sway / 2, width: 90, height: 120))
    }

    private func project(screen: [Clip], transitions: [Transition] = [], media: TestMedia, seconds: Double) -> Project {
        let pip = VideoProperties(transform: Transform(position: Point(x: 0.75, y: 0.75), scale: 0.5))
        return smallProject(
            video: [
                Track(id: "trk_screen", kind: .video, name: "Screen", clips: screen, transitions: transitions),
                Track(id: "trk_camera", kind: .video, name: "Camera", clips: [
                    Clip(id: "clip_camera", content: .media(mediaID: "med_camera"), start: .zero, duration: t(seconds), video: pip)
                ])
            ],
            media: [
                media.item("med_screen", "screen.mov", role: .screen, seconds: seconds),
                media.item("med_camera", "camera.mov", role: .camera, seconds: seconds)
            ]
        )
    }

    func testDeadAirOnlyWhereThePictureHoldsStill() async throws {
        let media = try TestMedia()
        // The page holds still, except for a badge sliding across it from
        // 3.0 to 4.4 s.
        try await media.movie("screen.mov", seconds: 7, draw: { frame, c in
            Self.drawPage(c, layout: 0)
            let time = Double(frame) / 30
            if time >= 3, time < 4.4 {
                c.setFillColor(CGColor(srgbRed: 0.9, green: 0.7, blue: 0.2, alpha: 1))
                c.fill(CGRect(x: 20 + CGFloat(frame - 90) * 4, y: 60, width: 14, height: 9))
            }
        })
        try await media.movie("camera.mov", seconds: 7, draw: { frame, c in Self.drawCamera(frame, c) })
        let screen = Clip(id: "clip_screen", content: .media(mediaID: "med_screen"), start: .zero, duration: t(7))
        let edit = project(screen: [screen], media: media, seconds: 7)
        // Speech, then 1.3 s still and silent, speech, 1.4 s silent while
        // the badge slides, speech, a 0.4 s sentence pause, speech.
        let said: [(String, Double, Double)] = [("Here's", 0.2, 0.6), ("the page.", 0.6, 1.0), ("Watch", 2.3, 3.0), ("this.", 4.4, 5.2), ("And", 5.6, 6.0), ("done.", 6.0, 6.6)]
        let speech = QualityCheck.Speech(words: said.map { .init(text: $0.0, start: t($0.1), end: t($0.2)) }, clipIDs: [])
        let range = TimeRange(start: t(0.2), end: t(6.6))

        let frames = try await FrameScanner.scan(RenderContext(project: edit, folder: media.projectFolder), ranges: [range], width: 320)
        XCTAssertEqual(frames.first?.columns, 32)
        let found = QualityCheck.deadAir(in: edit, ranges: [range], frames: frames, speech: speech)
        XCTAssertEqual(found.map(\.kind), [.deadAir], "\(found.map(\.message))")
        let note = try XCTUnwrap(found.first)
        XCTAssertEqual(note.start.seconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(note.end.seconds, 2.3, accuracy: 0.001)
        XCTAssertTrue(note.message.contains("(after \"Here's the page.\")"), note.message)
    }

    func testPageChangesFromTheScreenRecordingAlone() async throws {
        let media = try TestMedia()
        // Page 0, a new page at 1.5 s, typing from 2.5 s, a smooth scroll
        // from 4.5 s, a jump down the page at 6 s, and a new page at 7 s
        // that the edit pushes to.
        try await media.movie("screen.mov", seconds: 8, draw: { frame, c in
            let time = Double(frame) / 30
            if time < 1.5 {
                Self.drawPage(c, layout: 0)
                return
            }
            if time >= 7 {
                Self.drawPage(c, layout: 2)
                return
            }
            let scroll: CGFloat = time < 4.5 ? 0 : time < 5.5 ? CGFloat(frame - 135) * 3 : time < 6 ? 90 : 135
            Self.drawPage(c, layout: 1, scroll: scroll)
            let typed = time < 2.5 ? 0 : min(40, (frame - 75) / 2)
            c.setFillColor(CGColor(gray: 0.85, alpha: 1))
            for character in 0..<typed {
                c.fill(CGRect(x: 14 + CGFloat(character % 36) * 8, y: 150 + CGFloat(character / 36) * 10 - scroll, width: 5, height: 7))
            }
        })
        try await media.movie("camera.mov", seconds: 8, draw: { frame, c in Self.drawCamera(frame, c) })
        let first = Clip(id: "clip_s1", content: .media(mediaID: "med_screen"), start: .zero, duration: t(7))
        let second = Clip(id: "clip_s2", content: .media(mediaID: "med_screen"), start: t(7), duration: t(1), sourceStart: t(7))
        let push = Transition(type: .push, direction: .left, duration: t(0.7), fromClipID: "clip_s1", toClipID: "clip_s2")
        let edit = project(screen: [first, second], transitions: [push], media: media, seconds: 8)
        let range = TimeRange(start: .zero, end: t(8))

        let screens = try XCTUnwrap(QualityCheck.screenOnly(edit))
        let frames = try await FrameScanner.scan(RenderContext(project: screens, folder: media.projectFolder), ranges: [range], width: 320, scanlines: true)
        XCTAssertEqual(frames.first?.scanlines.count, QualityCheck.scanlineBands * 180)
        let found = QualityCheck.pageChanges(in: edit, ranges: [range], screenFrames: frames)
        XCTAssertEqual(found.map(\.kind), [.pageChange], "only the new page at 1.5 s: \(found.map { "\($0.start) \($0.message)" })")
        let note = try XCTUnwrap(found.first)
        XCTAssertEqual(note.start.seconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(note.clipIDs, ["clip_s1"])
        XCTAssertTrue(note.message.hasPrefix("Page change inside a clip"), note.message)

        // Without the push, the new page at 7 s is bare too.
        var bare = edit
        bare.videoTracks[0].transitions = []
        XCTAssertEqual(QualityCheck.pageChanges(in: bare, ranges: [range], screenFrames: frames).map(\.start.seconds), [1.5, 7])
    }
}
