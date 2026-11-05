import AppKit
import ImageIO
import XCTest
@testable import TandemCore
import TandemMedia
@testable import TandemRender

/// `tandem check --privacy` (`PrivacyCheck`): what a sweep by eye kept
/// missing in the Threadbear launch video, found from what's read on each
/// frame. The frames here are made up, so the grouping, edges and mapping
/// are tested without rendering; `testVisionReadsAnEmailAndAQRCode` reads
/// a real picture.
final class PrivacyScanTests: XCTestCase {
    let screen = MediaItem(
        id: "med_screen", path: "source/screen.mov", kind: .video, role: .screen,
        duration: t(120), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true
    )

    /// The screen recording full frame for 60 s, 4K at 30 fps, with a title
    /// over 40 to 45 and anything else given.
    func project(screenVideo: VideoProperties? = nil, text: [Clip] = []) -> Project {
        var project = Project.standard(name: "Privacy")
        project.settings.width = 3840
        project.settings.height = 2160
        project.settings.frameRate = .fps30
        project.media = [screen]
        project.videoTracks = [
            Track(id: "trk_screen", kind: .video, name: "Screen", clips: [
                Clip(id: "clip_screen", content: .media(mediaID: "med_screen"), start: .zero, duration: t(60), sourceStart: .zero, video: screenVideo)
            ], rippleMode: .cut),
            Track(id: "trk_text", kind: .video, name: "Text", clips: text, rippleMode: .follow)
        ]
        project.audioTracks = []
        return project
    }

    /// A reader that "reads" `lines` on every frame from `from` up to (not
    /// including) `to`, and nothing else, and counts what it's asked for.
    final class FakeReader: @unchecked Sendable {
        var shows: [(from: Time, to: Time, line: ReadLine)] = []
        var codes: [(from: Time, to: Time, box: CGRect)] = []
        private(set) var asked = 0

        func read(_ times: [Time]) -> [ReadFrame] {
            asked += times.count
            return times.map { time in
                ReadFrame(
                    time: time,
                    lines: shows.filter { $0.from <= time && time < $0.to }.map(\.line),
                    codes: codes.filter { $0.from <= time && time < $0.to }.map(\.box)
                )
            }
        }
    }

    func run(_ project: Project, _ reader: FakeReader, from: Double = 0, to: Double = 60) async throws -> (problems: [CheckProblem], notes: [CheckProblem]) {
        try await PrivacyCheck.run(project: project, ranges: [TimeRange(start: t(from), end: t(to))], folder: nil) { times, _ in reader.read(times) }
    }

    func frame(_ n: Int) -> Time { Time(seconds: Double(n) / 30) }

    func testFindsAnEmailToTheFrameWithTheRedactThatHidesIt() async throws {
        let reader = FakeReader()
        // Shows from frame 301 (10.033 s) up to frame 453 (15.1 s): between
        // the half-second samples at both ends.
        let email = ReadLine(text: "Owner  jane@example.com  Admin", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02))
        reader.shows = [(frame(301), frame(453), email)]
        let found = try await run(project(), reader)

        XCTAssertEqual(found.problems.count, 1)
        let problem = try XCTUnwrap(found.problems.first)
        XCTAssertEqual(problem.kind, .privateText)
        XCTAssertFalse(problem.kind.isNote, "it fails the check")
        XCTAssertEqual(problem.start, frame(301), "the first frame it shows on")
        XCTAssertEqual(problem.end, frame(453), "the frame after the last it shows on")
        XCTAssertTrue(problem.message.contains("email"), problem.message)
        XCTAssertTrue(problem.message.contains("jane@example.com"), problem.message)
        XCTAssertTrue(problem.message.contains("screen.mov"), problem.message)
        XCTAssertEqual(problem.clipIDs, ["clip_screen"])
        guard case .redact(let range, let rect, let mediaID, _, let style, _, _)? = problem.fix else { return XCTFail("a redact: \(String(describing: problem.fix))") }
        XCTAssertEqual(range, TimeRange(start: frame(301), end: frame(453)))
        XCTAssertEqual(mediaID, "med_screen")
        XCTAssertEqual(style, .blur)
        // Full frame, so the file's frame is the video's, with a little room.
        XCTAssertEqual(rect.x, 0.19, accuracy: 0.001)
        XCTAssertEqual(rect.y, 0.29, accuracy: 0.001)
        XCTAssertEqual(rect.width, 0.32, accuracy: 0.001)
        XCTAssertEqual(rect.height, 0.04, accuracy: 0.001)
        // 120 samples, and a few more to find each edge to the frame.
        XCTAssertLessThan(reader.asked, 140)
    }

    func testMapsTextOnAPictureInPictureBackToTheFilesFrame() async throws {
        // The screen at half size in the right half of the frame.
        var video = VideoProperties()
        video.transform = Transform(position: Point(x: 0.75, y: 0.5), scale: 0.5)
        let reader = FakeReader()
        // The middle of the file is the middle of the right half.
        reader.shows = [(t(5), t(6), ReadLine(text: "Booking reference: X7KQ2P", box: CGRect(x: 0.7, y: 0.45, width: 0.1, height: 0.1)))]
        let found = try await run(project(screenVideo: video), reader)
        guard case .redact(_, let rect, _, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("a redact") }
        XCTAssertEqual(rect.x, 0.4 - 0.01, accuracy: 0.001)
        XCTAssertEqual(rect.y, 0.4 - 0.01, accuracy: 0.001)
        XCTAssertEqual(rect.width, 0.2 + 0.02, accuracy: 0.001)
        XCTAssertEqual(rect.height, 0.2 + 0.02, accuracy: 0.001)

        // Text read off the empty left half is over nothing of the screen.
        let left = FakeReader()
        left.shows = [(t(5), t(6), ReadLine(text: "jane@example.com", box: CGRect(x: 0.1, y: 0.45, width: 0.1, height: 0.1)))]
        let none = try await run(project(screenVideo: video), left)
        XCTAssertEqual(none.problems, [])
    }

    func testTextInsideAPhoneFrameIsThePhonesRecording() async throws {
        // The launch video's Pocket card was on the phone recording, inside
        // a phone frame PNG with a see-through screen on the track above.
        // Blamed on the frame, its redact would have blurred the frame.
        let frameArt = MediaItem(id: "med_frame", path: "broll/phone-frame.png", kind: .image, role: .broll, width: 1000, height: 2000, hasVideo: true, hasAlpha: true)
        var p = project()
        p.media.append(frameArt)
        p.videoTracks.insert(Track(id: "trk_frame", kind: .video, name: "Phone frame", clips: [
            Clip(id: "clip_frame", content: .media(mediaID: "med_frame"), start: .zero, duration: t(60))
        ], rippleMode: .follow), at: 1)
        let reader = FakeReader()
        reader.shows = [(t(5), t(6), ReadLine(text: "Frequent Flyer 1234567890", box: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.02)))]
        let found = try await run(p, reader)
        guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("a redact") }
        XCTAssertEqual(mediaID, "med_screen")
    }

    func testAnOpaqueCardWithAlphaKeepsItsOwnText() async throws {
        // A still with alpha round an opaque card over the screen: text on
        // the card is the card's, so its redact goes on the card, not under it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-alpha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // 100 by 100, see-through, with an opaque white square in its middle.
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
        let image = try XCTUnwrap(context.makeImage())
        let url = folder.appendingPathComponent("card.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let card = MediaItem(id: "med_card", path: "card.png", kind: .image, role: .broll, width: 3840, height: 2160, hasVideo: true, hasAlpha: true)
        var p = project()
        p.media.append(card)
        p.videoTracks.insert(Track(id: "trk_card", kind: .video, name: "Card", clips: [
            Clip(id: "clip_card", content: .media(mediaID: "med_card"), start: .zero, duration: t(60))
        ], rippleMode: .follow), at: 1)
        let reader = FakeReader()
        reader.shows = [
            (t(5), t(6), ReadLine(text: "jane@example.com", box: CGRect(x: 0.45, y: 0.49, width: 0.1, height: 0.02))),
            (t(20), t(21), ReadLine(text: "jane@example.com", box: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.02)))
        ]
        let found = try await PrivacyCheck.run(project: p, ranges: [TimeRange(start: .zero, end: t(60))], folder: ProjectFolder(root: folder)) { times, _ in reader.read(times) }
        let targets = found.problems.compactMap { problem -> String? in
            guard case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix else { return nil }
            return mediaID
        }
        XCTAssertEqual(targets, ["med_card", "med_screen"], "on the card in the middle, through it at the corner")
    }

    func testTextBesideACutOutCameraIsTheScreens() async throws {
        // The launch video's account emails were read beside Mike, cut out
        // full frame over the screen, and put on the camera as well.
        let camera = MediaItem(id: "med_camera", path: "source/camera.mov", kind: .video, role: .camera, width: 3840, height: 2160, hasVideo: true)
        var p = project()
        p.media.append(camera)
        var video = VideoProperties()
        video.cutout = Cutout(enabled: true)
        p.videoTracks.insert(Track(id: "trk_camera", kind: .video, name: "Camera", clips: [
            Clip(id: "clip_camera", content: .media(mediaID: "med_camera"), start: .zero, duration: t(60), sourceStart: .zero, video: video)
        ], rippleMode: .cut), at: 1)
        let reader = FakeReader()
        reader.shows = [(t(5), t(6), ReadLine(text: "jane.doe@gmail.c...", box: CGRect(x: 0.6, y: 0.3, width: 0.1, height: 0.02)))]
        let found = try await run(p, reader)
        XCTAssertEqual(found.problems.count, 1)
        guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("a redact") }
        XCTAssertEqual(mediaID, "med_screen")
    }

    func testAnAddressWrappedOntoTwoLinesIsFound() async throws {
        // A task card in a highlights panel in the launch video, with the
        // street number on one line and the street on the next.
        let reader = FakeReader()
        reader.shows = [
            (t(5), t(6), ReadLine(text: "Collect the keys at 12", box: CGRect(x: 0.7, y: 0.30, width: 0.15, height: 0.02))),
            (t(5), t(6), ReadLine(text: "Harbour Rise", box: CGRect(x: 0.7, y: 0.325, width: 0.08, height: 0.02)))
        ]
        let found = try await run(project(), reader)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertTrue(found.problems.first?.message.contains("12 Harbour Rise") == true, "\(found.problems.map(\.message))")

        // A word one line has alone ("Bank", money) doesn't hide the address.
        let bank = FakeReader()
        bank.shows = [
            (t(5), t(6), ReadLine(text: "Drop it at 12 Bank", box: CGRect(x: 0.7, y: 0.30, width: 0.15, height: 0.02))),
            (t(5), t(6), ReadLine(text: "Road", box: CGRect(x: 0.7, y: 0.325, width: 0.05, height: 0.02)))
        ]
        let banked = try await run(project(), bank)
        XCTAssertTrue(banked.problems.first?.message.contains("12 Bank Road") == true, "\(banked.problems.map(\.message))")
    }

    func testAShortsOwnLayoutIsReadInItsOwnFrame() async throws {
        // A Short (the portrait format) puts the screen in its top window,
        // where the main layout has it full frame: text there is placed by
        // the format's own transform, and a clip hidden in the format isn't
        // what's read.
        var p = project()
        p.settings.alternateFormats = [OutputFormat(id: "portrait", name: "Short 9:16", width: 1080, height: 1920)]
        let screenID = p.videoTracks[0].clips[0].id
        p.videoTracks[0].clips[0].video = VideoProperties()
        p.videoTracks[0].clips[0].video?.formatOverrides["portrait"] = FormatOverride(transform: Transform(position: Point(x: 0.5, y: 0.25), scale: 1))
        // A full-frame still over everything in the main layout, hidden in the Short.
        let card = MediaItem(id: "med_card", path: "card.png", kind: .image, role: .broll, width: 3840, height: 2160, hasVideo: true)
        p.media.append(card)
        var cardVideo = VideoProperties()
        cardVideo.formatOverrides["portrait"] = FormatOverride(hidden: true)
        p.videoTracks.append(Track(id: "trk_card", kind: .video, name: "Card", clips: [
            Clip(id: "clip_card", content: .media(mediaID: "med_card"), start: .zero, duration: t(60), video: cardVideo)
        ], rippleMode: .follow))

        let reader = FakeReader()
        // The middle of the Short's top window is the middle of the screen recording.
        reader.shows = [(t(5), t(6), ReadLine(text: "jane@example.com", box: CGRect(x: 0.45, y: 0.24, width: 0.1, height: 0.02)))]
        let found = try await PrivacyCheck.run(project: p, ranges: [TimeRange(start: .zero, end: t(60))], folder: nil, format: "portrait") { times, _ in reader.read(times) }
        guard case .redact(_, let rect, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("a redact: \(found.problems)") }
        XCTAssertEqual(mediaID, "med_screen", "not the card, which the Short hides")
        XCTAssertEqual(found.problems.first?.clipIDs, [screenID])
        // 108 px of a 1080 wide Short over a screen shown 1080 wide: a tenth of the file.
        XCTAssertEqual(rect.x, 0.45 - 0.01, accuracy: 0.002)
        XCTAssertEqual(rect.width, 0.1 + 0.02, accuracy: 0.002)
        XCTAssertEqual(rect.y + rect.height / 2, 0.5, accuracy: 0.002, "the middle of the file, up and down")
    }

    func testTitlesAndCaptionsAreMikesOwnWords() async throws {
        let title = Clip(id: "clip_title", content: .text(TextContent(text: "Email me at jane@example.com")), start: t(40), duration: t(5))
        let reader = FakeReader()
        reader.shows = [(t(40), t(45), ReadLine(text: "Email me at jane@example.com", box: CGRect(x: 0.3, y: 0.8, width: 0.4, height: 0.05)))]
        let found = try await run(project(text: [title]), reader)
        XCTAssertEqual(found.problems, [])
    }

    func testAQRCodeAndAListOfNamesAreFlagged() async throws {
        let reader = FakeReader()
        reader.codes = [(t(20), t(22), CGRect(x: 0.8, y: 0.7, width: 0.1, height: 0.15))]
        reader.shows = [
            (t(30), t(32), ReadLine(text: "Sarah Johnson", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.02))),
            (t(30), t(32), ReadLine(text: "David Williams", box: CGRect(x: 0.1, y: 0.13, width: 0.2, height: 0.02))),
            (t(30), t(32), ReadLine(text: "Emily Thompson", box: CGRect(x: 0.1, y: 0.16, width: 0.2, height: 0.02)))
        ]
        let found = try await run(project(), reader)
        guard found.problems.count == 2 else { return XCTFail("\(found.problems.map(\.message))") }
        XCTAssertTrue(found.problems[0].message.contains("QR code"), found.problems[0].message)
        XCTAssertEqual(found.problems[0].start, t(20))
        XCTAssertTrue(found.problems[1].message.contains("names"), found.problems[1].message)
    }

    func testAStretchOfReadableTextIsANoteToLookThrough() async throws {
        // A thread's answer about a plan: nothing the rules know is
        // private, but 50 words of it a frame for 8 s.
        let words = Array(repeating: "the plan we agreed for the next release is", count: 5).joined(separator: " ")
        let reader = FakeReader()
        reader.shows = [(t(4), t(12), ReadLine(text: words, box: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.05)))]
        let found = try await run(project(), reader)
        XCTAssertEqual(found.problems, [])
        XCTAssertEqual(found.notes.map(\.kind), [.readableText])
        XCTAssertTrue(found.notes[0].kind.isNote)
        XCTAssertEqual(found.notes[0].start, t(4))
        XCTAssertEqual(found.notes[0].end, t(12))
    }

    func testTextScrollingPastAFixedBlurIsStillFound() async throws {
        // The launch video, 8:51.7 to 8:59: a blur box held still over a
        // thread's answer while it scrolled, and lines passed through the
        // strip above it. The scan reads the frames as export renders them,
        // so what scrolls into view is read wherever it is.
        let reader = FakeReader()
        for (index, second) in stride(from: 51.7, to: 58.9, by: 1.0).enumerated() {
            reader.shows.append((t(second), t(second + 0.6), ReadLine(text: "Sell the BTC before the \(index + 1)th", box: CGRect(x: 0.3, y: 0.12, width: 0.3, height: 0.02))))
        }
        let found = try await run(project(), reader)
        XCTAssertEqual(found.problems.count, 8, "each line as it passes: \(found.problems.map { "\($0.start)-\($0.end)" })")
        XCTAssertTrue(found.problems.allSatisfy { $0.message.contains("crypto") })
    }

    // MARK: - Vision

    func testVisionReadsAnEmailAndAQRCode() throws {
        let size = CGSize(width: 1280, height: 720)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            let font = NSFont.systemFont(ofSize: 28)
            ("Owner  jane@example.com  Admin" as NSString).draw(at: CGPoint(x: 100, y: 100), withAttributes: [.font: font, .foregroundColor: NSColor.black])
            if let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("https://example.com/pair".utf8)]),
               let qr = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) {
                let rep = NSCIImageRep(ciImage: qr)
                let picture = NSImage(size: rep.size)
                picture.addRepresentation(rep)
                picture.draw(in: NSRect(x: 900, y: 300, width: rep.size.width, height: rep.size.height))
            }
            return true
        }
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let frame = FrameTextReader.recognise(cg, at: .zero)
        XCTAssertTrue(frame.lines.contains { $0.text.contains("jane@example.com") }, "\(frame.lines.map(\.text))")
        let line = try XCTUnwrap(frame.lines.first { $0.text.contains("jane@") })
        XCTAssertEqual(line.box.midY, 115.0 / 720, accuracy: 0.03, "from the top")
        XCTAssertEqual(frame.codes.count, 1)
    }
}
