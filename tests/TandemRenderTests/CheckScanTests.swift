import CoreGraphics
import XCTest
import TandemCore
@testable import TandemRender

/// Dead air on synthetic media, rendered and measured by the real scanner:
/// an edit with a still pause, an animated one and a short sentence pause,
/// with Mike moving about in his corner the whole time.
final class CheckScanTests: XCTestCase {
    static let size = CGSize(width: 320, height: 180)

    /// A page of dim text on a dark background, like Mike's explainers.
    static func drawPage(_ c: CGContext) {
        TestMedia.fill(c, 0.08, 0.08, 0.09)
        c.setFillColor(CGColor(gray: 0.45, alpha: 1))
        for line in 0..<14 {
            let length = CGFloat(60 + (line * 7 % 9) * 24)
            c.fill(CGRect(x: 16, y: 14 + CGFloat(line) * 11, width: min(length, size.width - 32), height: 5))
        }
    }

    /// Mike in his corner: a blob that never keeps still.
    static func drawCamera(_ frame: Int, _ c: CGContext) {
        TestMedia.fill(c, 0.25, 0.3, 0.35)
        c.setFillColor(CGColor(srgbRed: 0.8, green: 0.6, blue: 0.5, alpha: 1))
        let sway = CGFloat((frame * 7) % 23)
        c.fillEllipse(in: CGRect(x: 110 + sway, y: 40 + sway / 2, width: 90, height: 120))
    }

    private func project(screen: [Clip], media: TestMedia, seconds: Double) -> Project {
        let pip = VideoProperties(transform: Transform(position: Point(x: 0.75, y: 0.75), scale: 0.5))
        return smallProject(
            video: [
                Track(id: "trk_screen", kind: .video, name: "Screen", clips: screen),
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
            Self.drawPage(c)
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
}
