import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import XCTest
@testable import TandemCore
import TandemMedia
@testable import TandemRender

/// Real compositor and OCR evidence, rather than an injected opaque-input list.
/// Synthetic encodes and renders run on Tinker Desk through heavy.
final class PrivacyRound2RenderTests: XCTestCase {
    let email = "jane@example.com"

    func screen(_ media: TestMedia, size: CGSize, font: CGFloat, seconds: Double = 0.4) async throws -> MediaItem {
        let url = try await media.movie("screen.mov", seconds: seconds, size: size) { _, context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.translateBy(x: size.width * 0.1, y: size.height * 0.35)
            context.scaleBy(x: 1, y: -1)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, font, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: self.email, attributes: attributes)), context)
        }
        var item = try await MediaScanner.probe(url, folder: media.projectFolder, id: "med_screen")
        item.role = .screen
        return item
    }

    func project(_ screen: MediaItem, transform: Transform = Transform()) -> Project {
        Project(name: "Round 2 attribution", settings: ProjectSettings(width: screen.width!, height: screen.height!), media: [screen], videoTracks: [
            Track(kind: .video, name: "Screen", clips: [Clip(id: "clip_screen", content: .media(mediaID: screen.id), start: .zero, duration: t(0.4), video: VideoProperties(transform: transform))])
        ])
    }

    func assertScreenFix(_ project: Project, media: TestMedia, width: Int, format: String? = nil, probeFolder: Bool = true, file: StaticString = #filePath, line: UInt = #line) async throws {
        var context = RenderContext(project: project, folder: media.projectFolder)
        context.format = format
        let reader = FrameTextReader(context: context, width: width)
        let frames = try await reader.read([t(0.2)], sequential: true)
        XCTAssertEqual(frames.count, 1, file: file, line: line)
        XCTAssertTrue(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "positive control: the real output must contain readable private text", file: file, line: line)
        let found = try await PrivacyCheck.run(project: project, ranges: [TimeRange(start: t(0.2), duration: FrameRate.fps30.frameDuration)], folder: probeFolder ? media.projectFolder : nil, format: format) { times, _ in
            XCTAssertEqual(times, frames.map(\.time))
            return frames
        }
        XCTAssertEqual(found.problems.count, 1, file: file, line: line)
        let problem = try XCTUnwrap(found.problems.first, file: file, line: line)
        guard case .redact(_, let rect, let mediaID, _, _, _, _)? = problem.fix else {
            return XCTFail("readable screen text needs an automatic source redaction: \(problem)", file: file, line: line)
        }
        XCTAssertEqual(mediaID, "med_screen", file: file, line: line)
        XCTAssertEqual(problem.clipIDs, ["clip_screen"], file: file, line: line)
        XCTAssertTrue(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).contains(CGPoint(x: 0.2, y: 0.33)), "the fix must map back into the screen's own source pixels", file: file, line: line)
    }

    func testDefault4KScanRetainsAnActionableSource() async throws {
        let media = try TestMedia()
        let item = try await screen(media, size: CGSize(width: 3840, height: 2160), font: 110)
        try await assertScreenFix(project(item), media: media, width: 1920)
    }

    func testShortsDownsampleRetainsAnActionableSource() async throws {
        let media = try TestMedia()
        let item = try await screen(media, size: CGSize(width: 1920, height: 1080), font: 72)
        var p = project(item)
        p.settings.alternateFormats = [.portrait]
        try await assertScreenFix(p, media: media, width: 1080, format: "portrait")
    }

    func testDownscaledPictureInPictureRetainsAnActionableSource() async throws {
        let media = try TestMedia()
        let item = try await screen(media, size: CGSize(width: 1280, height: 720), font: 64)
        try await assertScreenFix(project(item, transform: Transform(scale: 0.5)), media: media, width: 1280)
    }

    func testFractionalPlacementRetainsAnActionableSource() async throws {
        let media = try TestMedia()
        let item = try await screen(media, size: CGSize(width: 1280, height: 720), font: 40)
        try await assertScreenFix(project(item, transform: Transform(position: Point(x: 0.50035, y: 0.50055))), media: media, width: 1280)
    }

    func testSamplingOutsideAnOverlaysGeometricBoundsStillRequiresReview() async throws {
        let media = try TestMedia()
        let item = try await screen(media, size: CGSize(width: 1280, height: 720), font: 40)
        let url = try await media.movie("edge.mov", seconds: 0.4, size: CGSize(width: 1280, height: 720)) { _, context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        }
        let overlay = try await MediaScanner.probe(url, folder: media.projectFolder, id: "med_overlay")
        var p = project(item)
        p.media.append(overlay)
        let transform = Transform(position: Point(x: 0.5, y: 500.4), scale: 1000)
        p.videoTracks.append(Track(kind: .video, name: "Edge", clips: [Clip(id: "clip_edge", content: .media(mediaID: overlay.id), start: .zero, duration: t(0.4), video: VideoProperties(transform: transform))]))
        let reader = FrameTextReader(context: RenderContext(project: p, folder: media.projectFolder), width: 1280)
        let frames = try await reader.read([t(0.2)], sequential: true)
        let frame = try XCTUnwrap(frames.first)
        let line = try XCTUnwrap(frame.lines.first { $0.text.contains(email) }, "the real sampling edge must leave the email readable")
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720).applying(LayerMath.placement(source: CGSize(width: 1280, height: 720), canvas: CGSize(width: 1280, height: 720), transform: transform))
        XCTAssertLessThan(line.box.maxY * 720, bounds.minY, "this entire OCR rectangle is outside the geometric overlay")
        XCTAssertEqual(frame.inputCoverage.first { $0.box == line.box }?.clips["clip_edge"]?.opacity, .mixed, "the actual sampler still contributes there")
        let found = try await PrivacyCheck.run(project: p, ranges: [TimeRange(start: t(0.2), duration: FrameRate.fps30.frameDuration)], folder: media.projectFolder) { _, _ in frames }
        XCTAssertFalse(found.problems.isEmpty)
        XCTAssertTrue(found.problems.allSatisfy { $0.fix == nil }, "actual overlapping pixels cannot be ignored because geometry alone says the layer is elsewhere")
    }

    func testAnOffGridHoldCannotReadAnEndedOverlaysTextOnTheNextFrame() async throws {
        let media = try TestMedia()
        var overlay = try await screen(media, size: CGSize(width: 1280, height: 720), font: 40, seconds: 1.2)
        overlay.id = "med_overlay"
        let url = try await media.movie("blank.mov", seconds: 1, size: CGSize(width: 1280, height: 720)) { _, context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        }
        let blank = try await MediaScanner.probe(url, folder: media.projectFolder, id: "med_blank")
        let p = Project(name: "Off-grid recovery start", settings: ProjectSettings(width: 1280, height: 720), media: [blank, overlay], videoTracks: [
            Track(kind: .video, name: "Blank", clips: [Clip(id: "clip_blank", content: .media(mediaID: blank.id), start: .zero, duration: t(2), sourceStart: t(0.01))]),
            Track(kind: .video, name: "Private overlay", clips: [Clip(id: "clip_overlay", content: .media(mediaID: overlay.id), start: .zero, duration: t(1))])
        ])
        let reader = FrameTextReader(context: RenderContext(project: p, folder: media.projectFolder), width: 1280)
        let built = try await CompositionAssembler.build(reader.context)
        let recovery = ExportPipeline.readStart(t(1), composition: built.composition, instructions: built.videoComposition.instructions)
        XCTAssertEqual(recovery.seconds, 0.99, accuracy: 0.0001, "the held file edge supplies a genuinely off-grid reader start")
        let beforeCut = try await reader.read([Time.frames(29, at: .fps30)], sequential: true)
        XCTAssertTrue(beforeCut.flatMap(\.lines).contains { $0.text.contains(email) }, "the outgoing overlay really contains private text")
        let frames = try await reader.read([t(1)], sequential: true)
        XCTAssertFalse(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "the frame at the cut must be rendered at 1.000, not the nearby 0.990 frame")
        let found = try await PrivacyCheck.run(project: p, ranges: [TimeRange(start: t(1), duration: FrameRate.fps30.frameDuration)], folder: media.projectFolder) { _, _ in frames }
        XCTAssertTrue(found.problems.isEmpty, "the ended overlay's email must never generate a source fix for the clean lower file")
    }

    func logo(_ media: TestMedia) throws -> MediaItem {
        let url = media.folder.appendingPathComponent("logo.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return MediaItem(id: "med_logo", path: url.lastPathComponent, kind: .image, role: .graphic, width: 256, height: 128, hasVideo: true)
    }

    func testAnUnrelatedDownsampledStillDoesNotEraseScreenEvidence() async throws {
        let media = try TestMedia()
        let item = try await screen(media, size: CGSize(width: 1280, height: 720), font: 40)
        let logo = try logo(media)
        var p = project(item)
        p.media.append(logo)
        p.videoTracks.append(Track(kind: .video, name: "Logo", clips: [Clip(id: "clip_logo", content: .media(mediaID: logo.id), start: .zero, duration: t(0.4), video: VideoProperties(transform: Transform(position: Point(x: 0.85, y: 0.85), scale: 0.1)))]))
        try await assertScreenFix(p, media: media, width: 1280)
    }

    func testAnUnrelatedRedactedStillDoesNotEraseScreenEvidence() async throws {
        let media = try TestMedia()
        let item = try await screen(media, size: CGSize(width: 1280, height: 720), font: 40)
        let logo = try logo(media)
        var p = project(item)
        p.media.append(logo)
        p.videoTracks.append(Track(kind: .video, name: "Logo", clips: [Clip(id: "clip_logo", content: .media(mediaID: logo.id), start: .zero, duration: t(0.4), video: VideoProperties(transform: Transform(position: Point(x: 0.85, y: 0.85), scale: 0.1)))]))
        let coordinator = ProjectCoordinator(project: p)
        _ = try coordinator.apply(EditBatch(label: "Redact logo", commands: [.redact(range: TimeRange(start: .zero, end: t(0.4)), rect: Rect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), mediaID: logo.id, style: .blur, size: 40)]))
        try await assertScreenFix(coordinator.project, media: media, width: 1280)
    }

    func testAnActuallyRenderedStillNeedsNoSeparateFileAlphaProbe() async throws {
        let media = try TestMedia()
        let movie = try await screen(media, size: CGSize(width: 1280, height: 720), font: 40)
        let image = try await FrameRenderer(context: RenderContext(project: project(movie), folder: media.projectFolder)).image(at: t(0.2))
        let url = media.folder.appendingPathComponent("screen.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let still = MediaItem(id: "med_screen", path: url.lastPathComponent, kind: .image, role: .screen, width: 1280, height: 720, hasVideo: true)
        try await assertScreenFix(project(still), media: media, width: 1280, probeFolder: false)
    }
}
