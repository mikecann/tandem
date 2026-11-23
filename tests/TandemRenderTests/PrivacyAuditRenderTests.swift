import AppKit
import AVFoundation
import CoreText
import ImageIO
import XCTest
@testable import TandemCore
import TandemMedia
@testable import TandemRender

/// Synthetic, offline rendering only. Run on tinker-desk through heavy.
final class PrivacyAuditRenderTests: XCTestCase {
    let canvas = CGSize(width: 1280, height: 720)
    let region = Rect(x: 0.075, y: 0.25, width: 0.55, height: 0.18)
    let email = "jane@example.com"
    var evidence: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["TANDEM_AUDIT_EVIDENCE"]!)
    }

    func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, in c: CGContext) {
        c.saveGState()
        c.translateBy(x: x, y: y)
        c.scaleBy(x: 1, y: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        c.textPosition = .zero
        CTLineDraw(line, c)
        c.restoreGState()
    }

    func draw(_ c: CGContext, privateText: Bool = true) {
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fill(CGRect(origin: .zero, size: canvas))
        text("PUBLIC SYNTHETIC FIXTURE", x: 55, y: 70, size: 25, in: c)
        if privateText { text(email, x: 120, y: 260, size: 45, in: c) }
    }

    func png(_ image: CGImage, _ name: String) throws {
        let target = evidence.appendingPathComponent(name + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func recognise(_ image: CGImage) -> [String] {
        FrameTextReader.recognise(image, at: .zero).lines.map(\.text)
    }

    func exportedImage(_ url: URL, at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: t(time).cmTime)
        XCTAssertEqual(result.actualTime.seconds, time, accuracy: 1.0 / 60)
        return result.image
    }

    func store(_ c: ProjectCoordinator, _ media: TestMedia, as name: String) throws -> URL {
        let directory = evidence.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in c.project.media {
            try FileManager.default.copyItem(at: media.folder.appendingPathComponent(item.path), to: directory.appendingPathComponent(item.path))
        }
        try ProjectFile.save(c.project, revision: c.revision, to: directory.appendingPathComponent("Synthetic.tandem"))
        return directory
    }

    func fixture(video: Bool = false, hlg: Bool = false, timed: Bool = false) async throws -> (TestMedia, ProjectCoordinator) {
        let media = try TestMedia()
        let file = video ? "dummy.mov" : "dummy.png"
        if video {
            try await media.movie(file, seconds: 4, size: canvas, hlg: hlg, draw: { index, c in self.draw(c, privateText: !timed || (index >= 30 && index < 90)) })
        } else {
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.translateBy(x: 0, y: 720)
            bitmap.scaleBy(x: 1, y: -1)
            draw(bitmap)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(media.folder.appendingPathComponent(file) as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let item = MediaItem(id: "med_dummy", path: file, kind: video ? .video : .image, role: .screen,
            duration: t(4), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let picture = Clip(id: "clip_dummy", content: .media(mediaID: item.id), start: .zero, duration: t(3), video: VideoProperties())
        let project = Project(name: "Privacy audit synthetic", settings: ProjectSettings(width: 1280, height: 720, frameRate: .fps30),
            media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [picture], rippleMode: .cut)], audioTracks: [])
        return (media, ProjectCoordinator(project: project))
    }

    @discardableResult
    func apply(_ c: ProjectCoordinator, _ command: EditCommand) throws -> Bool {
        let before = c.project
        do {
            _ = try c.apply(EditBatch(label: "Audit", commands: [command]))
            return true
        } catch let error as EditError {
            switch error {
            case .locked, .invalid:
                guard ["privacy", "blur", "redact", "locked"].contains(where: { String(describing: error).lowercased().contains($0) }) else { throw error }
                XCTAssertEqual(c.project, before, "a privacy refusal must leave the entire project unchanged")
                print("PRIVACY REFUSAL: \(error)")
                return false
            default: throw error
            }
        }
    }

    func hide(_ c: ProjectCoordinator, range: TimeRange? = nil) throws {
        try apply(c, .redact(range: range ?? TimeRange(start: .zero, end: t(3)), rect: region, mediaID: "med_dummy", style: .blur, size: 90))
    }

    func image(_ c: ProjectCoordinator, _ media: TestMedia, at time: Double = 1.5, format: String? = nil) async throws -> CGImage {
        var context = RenderContext(project: c.project, folder: media.projectFolder)
        context.format = format
        return try await FrameRenderer(context: context).image(at: t(time))
    }

    func scan(_ c: ProjectCoordinator, _ media: TestMedia, format: String? = nil, from: Double = 0, to: Double = 3) async throws -> [CheckProblem] {
        var context = RenderContext(project: c.project, folder: media.projectFolder)
        context.format = format
        let reader = FrameTextReader(context: context, width: format == nil ? 1280 : 1080)
        return try await PrivacyCheck.run(project: c.project, ranges: [TimeRange(start: t(from), end: t(to))], folder: media.projectFolder, format: format) { times, sequential in
            let frames = try await reader.read(times, sequential: sequential)
            if sequential {
                XCTAssertEqual(frames.count, times.count, "a clean result needs all requested samples rendered")
                print("AUDIT scan read \(frames.count)/\(times.count) samples")
            }
            return frames
        }.problems
    }

    func testRenderedProtectionAfterSpatialEditsAndDiskReload() async throws {
        for operation in ["updateTransform", "zoomStatic", "zoomAnimated", "setKeyframes", "addMotion", "uncrop", "animateCrop", "formatOverride"] {
            let (media, c) = try await fixture()
            if operation == "uncrop" || operation == "animateCrop" {
                try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["crop": .object(["left": .number(0.6)])])])))
            }
            if operation == "formatOverride" {
                try apply(c, .updateSettings(patch: .object(["alternateFormats": try JSONValue.from([OutputFormat.portrait])])))
                try apply(c, .setFormatLayout(clipIDs: ["clip_dummy"], format: "portrait", slot: .top))
                try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["formatOverrides": .object(["portrait": .object(["transform": .object(["scale": .number(1)])])])])])))
            }
            try hide(c)
            let before = try await image(c, media, format: operation == "formatOverride" ? "portrait" : nil)
            try png(before, operation + "-before")
            XCTAssertFalse(recognise(before).contains { $0.contains(email) }, "control blur must hide the dummy email")
            switch operation {
            case "updateTransform":
                try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["transform": .object(["position": .object(["y": .number(0.8)])])])])))
            case "zoomStatic": try apply(c, .zoomToRegion(clipID: "clip_dummy", rect: region))
            case "zoomAnimated": try apply(c, .zoomToRegion(clipID: "clip_dummy", rect: region, at: t(0.2), duration: t(0.8)))
            case "setKeyframes": try apply(c, .setKeyframes(clipID: "clip_dummy", parameter: "video.transform.position", keyframes: [Keyframe(time: .zero, value: .point(Point(x: 0.5, y: 0.8)))]))
            case "addMotion": try apply(c, .addMotion(clipIDs: ["clip_dummy"], style: .panDown, amount: 1.2))
            case "uncrop": try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["crop": .object(["left": .number(0)])])])))
            case "animateCrop": try apply(c, .setKeyframes(clipID: "clip_dummy", parameter: "video.crop.left", keyframes: [Keyframe(time: .zero, value: .number(0))]))
            default:
                try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["formatOverrides": .object(["portrait": .object(["transform": .object(["position": .object(["y": .number(0.65)])])])])])])))
            }
            let savedURL = media.folder.appendingPathComponent("\(operation).tandem")
            try ProjectFile.save(c.project, revision: c.revision, to: savedURL)
            let reopened = ProjectCoordinator(project: try ProjectFile.load(from: savedURL).project)
            let after = try await image(reopened, media, at: operation == "addMotion" ? 0 : 1.5, format: operation == "formatOverride" ? "portrait" : nil)
            try png(after, operation + "-after-reload")
            let lines = recognise(after)
            print("AUDIT render \(operation): OCR \(lines)")
            // These probes establish observed behavior; the model tests assert
            // the desired contract and fail on this same commit.
            XCTAssertFalse(lines.contains { $0.contains("@example.com") }, "redaction must still hide readable pixels after the edit")
            let problems = try await scan(reopened, media, format: operation == "formatOverride" ? "portrait" : nil)
            print("AUDIT scan \(operation): \(problems.map(\.kind))")
            XCTAssertTrue(problems.isEmpty, "a fresh scan must confirm concealment")
            try FileManager.default.copyItem(at: savedURL, to: evidence.appendingPathComponent(operation + ".tandem"))
            if operation == "updateTransform" {
                try FileManager.default.copyItem(at: media.folder.appendingPathComponent("dummy.png"), to: evidence.appendingPathComponent("dummy.png"))
            }
        }
    }

    func testShortLayoutAndAdoptionKeepRegionCovered() async throws {
        let (media, c) = try await fixture()
        let control = try await image(c, media)
        XCTAssertTrue(recognise(control).contains { $0.contains(email) })
        try hide(c)
        try apply(c, .updateSettings(patch: .object(["alternateFormats": try JSONValue.from([OutputFormat.portrait])])))
        try apply(c, .setFormatLayout(clipIDs: ["clip_dummy"], format: "portrait", slot: .top))
        let short = try await image(c, media, format: "portrait")
        try png(short, "short-layout-covered")
        XCTAssertFalse(recognise(short).contains { $0.contains(email) })
        let shortScan = try await scan(c, media, format: "portrait")
        XCTAssertTrue(shortScan.isEmpty)
        try apply(c, .adoptFormat(format: "portrait"))
        let adopted = try await image(c, media)
        try png(adopted, "short-adopted-covered")
        XCTAssertFalse(recognise(adopted).contains { $0.contains(email) })
        let adoptedScan = try await scan(c, media)
        XCTAssertTrue(adoptedScan.isEmpty)
    }

    func testBriefAnimatedExposureBetweenOldSamplesIsDetected() async throws {
        let (media, c) = try await fixture(video: true)
        let points: [(Double, Double)] = [(0, 0), (0.1, 1), (0.3, 0), (0.5, 0), (3, 0)]
        try apply(c, .setKeyframes(clipID: "clip_dummy", parameter: "video.opacity", keyframes: points.map {
            Keyframe(time: t($0.0), value: .number($0.1), interpolation: .hold)
        }))
        let exposed = try await image(c, media, at: 0.2)
        try png(exposed, "brief-exposure-at-0.2")
        XCTAssertTrue(recognise(exposed).contains { $0.contains(email) })
        let found = try await scan(c, media)
        print("AUDIT brief exposure: readable at 0.2s, full privacy scan \(found.count) problems")
        XCTAssertTrue(found.contains { $0.kind == .privateText }, "every-frame scanning must find the 0.1–0.3 s exposure")
        let directory = try store(c, media, as: "brief-exposure")
        let out = directory.appendingPathComponent("export.mp4")
        let preset = ExportPreset(name: "Audit", codec: .h264, videoBitrate: 8_000_000, audioBitrate: 192_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: RenderContext(project: c.project, folder: media.projectFolder), preset: preset, output: out).run()
        let exported = try await exportedImage(out, at: 0.2)
        try png(exported, "brief-exposure-export-at-0.2")
        XCTAssertTrue(recognise(exported).contains { $0.contains(email) })
    }

    func testTransitionHandlesKeepTheSourceRedacted() async throws {
        let (media, c) = try await fixture(video: true)
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["duration": .number(2)])))
        try await media.movie("plain.mov", seconds: 4, size: canvas, draw: { _, c in self.draw(c, privateText: false) })
        try apply(c, .addMedia(item: MediaItem(id: "med_plain", path: "plain.mov", kind: .video, role: .screen, duration: t(4), width: 1280, height: 720, hasVideo: true)))
        try apply(c, .insertClip(trackID: "trk_screen", clip: Clip(id: "clip_plain", content: .media(mediaID: "med_plain"), start: t(2), duration: t(1), sourceStart: t(1)), mode: .place))
        try hide(c, range: TimeRange(start: .zero, end: t(2)))
        try apply(c, .addTransition(trackID: "trk_screen", transition: Transition(type: .dissolve, duration: t(1), fromClipID: "clip_dummy", toClipID: "clip_plain")))
        let after = try await image(c, media, at: 2.1)
        try png(after, "transition-after-copy-ended")
        let lines = recognise(after)
        print("AUDIT transition at 2.1: \(lines)")
        XCTAssertFalse(lines.contains { $0.contains(email) })
        let found = try await scan(c, media)
        print("AUDIT transition scan: \(found.map(\.message))")
        let directory = try store(c, media, as: "transition")
        let out = directory.appendingPathComponent("export.mp4")
        let preset = ExportPreset(name: "Audit", codec: .h264, videoBitrate: 8_000_000, audioBitrate: 192_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: RenderContext(project: c.project, folder: media.projectFolder), preset: preset, output: out).run()
        let exported = try await exportedImage(out, at: 2.1)
        try png(exported, "transition-export-at-2.1")
        XCTAssertFalse(recognise(exported).contains { $0.contains(email) })
    }

    func testHLGHoldAndPictureFreezeKeepOpaqueRegionCovered() async throws {
        let (media, c) = try await fixture(video: true, hlg: true)
        let control = try await image(c, media)
        XCTAssertTrue(recognise(control).contains { $0.contains(email) }, "HLG control must contain readable text before redacting")
        try apply(c, .holdFrame(clipID: "clip_dummy", range: TimeRange(start: t(1), end: t(1.4))))
        try hide(c)
        try apply(c, .holdFrame(clipID: "clip_dummy", range: TimeRange(start: t(2), end: t(2.3))))
        let held = try await image(c, media, at: 1.2)
        try png(held, "hlg-held-redacted")
        XCTAssertFalse(recognise(held).contains { $0.contains(email) })
        let problems = try await scan(c, media)
        XCTAssertTrue(problems.isEmpty)
        let directory = try store(c, media, as: "hlg-held")
        let out = directory.appendingPathComponent("export.mp4")
        let preset = ExportPreset(name: "Audit", codec: .h264, videoBitrate: 8_000_000, audioBitrate: 192_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: RenderContext(project: c.project, folder: media.projectFolder), preset: preset, output: out).run()
        let exported = try await exportedImage(out, at: 1.2)
        try png(exported, "hlg-held-redacted-export")
        XCTAssertFalse(recognise(exported).contains { $0.contains(email) })
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["freezeFrame": .bool(true), "sourceStart": .number(1)])))
        let frozen = try await image(c, media, at: 1.2)
        try png(frozen, "hlg-frozen-redacted")
        XCTAssertFalse(recognise(frozen).contains { $0.contains(email) })
        let frozenScan = try await scan(c, media)
        XCTAssertTrue(frozenScan.isEmpty)
    }

    func testLockedPrivacyTrackRefusesRippleExposureAtomically() async throws {
        let (media, c) = try await fixture(video: true, timed: true)
        try hide(c, range: TimeRange(start: t(1), end: t(3)))
        let beforeScan = try await scan(c, media)
        XCTAssertTrue(beforeScan.isEmpty, "before editing, every frame with private text is covered")
        let track = c.project.videoTracks.first { $0.isPrivacy }!
        try apply(c, .updateTrack(trackID: track.id, patch: .object(["locked": .bool(true)])))
        try apply(c, .cutRanges(ranges: [TimeRange(start: .zero, end: t(0.5))]))
        let saved = evidence.appendingPathComponent("locked-ripple.tandem")
        try ProjectFile.save(c.project, revision: c.revision, to: saved)
        let reopened = ProjectCoordinator(project: try ProjectFile.load(from: saved).project)
        let exposed = try await image(reopened, media, at: 0.7)
        try png(exposed, "locked-ripple-at-0.7")
        XCTAssertFalse(recognise(exposed).contains { $0.contains(email) })
        let found = try await scan(reopened, media)
        XCTAssertTrue(found.isEmpty)
        let directory = try store(reopened, media, as: "locked-ripple")
        let out = directory.appendingPathComponent("export.mp4")
        let preset = ExportPreset(name: "Audit", codec: .h264, videoBitrate: 8_000_000, audioBitrate: 192_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: RenderContext(project: reopened.project, folder: media.projectFolder), preset: preset, output: out).run()
        let exported = try await exportedImage(out, at: 0.7)
        try png(exported, "locked-ripple-export-at-0.7")
        XCTAssertFalse(recognise(exported).contains { $0.contains(email) })
    }
}
