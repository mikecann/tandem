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
        var opaqueVideoClipIDs: Set<String> = ["clip_screen"]
        var visibleClipIDs: Set<String> = ["clip_screen", "clip_card", "clip_early_card"]
        private(set) var asked = 0

        func read(_ times: [Time]) -> [ReadFrame] {
            asked += times.count
            return times.map { time in
                var frame = ReadFrame(
                    time: time,
                    lines: shows.filter { $0.from <= time && time < $0.to }.map(\.line),
                    codes: codes.filter { $0.from <= time && time < $0.to }.map(\.box)
                )
                frame.opaqueVideoClipIDs = opaqueVideoClipIDs
                frame.visibleClipIDs = visibleClipIDs
                return frame
            }
        }
    }

    func run(_ project: Project, _ reader: FakeReader, from: Double = 0, to: Double = 60) async throws -> (problems: [CheckProblem], notes: [CheckProblem]) {
        // These model-only frames represent opaque RGB video, apart from
        // the explicit alpha/cutout/translucency cases in each fixture.
        reader.opaqueVideoClipIDs = Set(project.videoTracks.flatMap(\.clips).filter { clip in
            guard let id = clip.mediaID, let item = project.media(id) else { return false }
            return item.kind == .video && !item.hasAlpha
        }.map(\.id))
        reader.visibleClipIDs = Set(project.videoTracks.flatMap(\.clips).map(\.id))
        return try await PrivacyCheck.run(project: project, ranges: [TimeRange(start: t(from), end: t(to))], folder: nil) { times, _ in reader.read(times) }
    }

    func frame(_ n: Int) -> Time { Time(seconds: Double(n) / 30) }

    func testAnExposureEntirelyBetweenHalfSecondSamplesIsFound() async throws {
        let reader = FakeReader()
        reader.shows = [(t(0.1), t(0.3), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
        let found = try await run(project(), reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertEqual(found.problems.first?.start, t(0.1))
        XCTAssertEqual(found.problems.first?.end, t(0.3))
    }

    func testAMissingFrameOrRecognitionFailureCannotPassClean() async throws {
        for missing in [true, false] {
            do {
                _ = try await PrivacyCheck.run(project: project(), ranges: [TimeRange(start: .zero, end: t(1))], folder: nil) { times, _ in
                    if missing { return times.dropFirst().map { ReadFrame(time: $0, lines: []) } }
                    return times.map { ReadFrame(time: $0, lines: [], recognitionError: "synthetic Vision failure") }
                }
                XCTFail("an incomplete scan must throw")
            } catch { XCTAssertTrue(String(describing: error).contains("privacy") || String(describing: error).contains("output frame")) }
        }
    }

    func testAReaderWithoutVideoOpacityEvidenceCannotGuessAnAutomaticFix() async throws {
        let p = project()
        let found = try await PrivacyCheck.run(project: p, ranges: [TimeRange(start: .zero, end: t(1))], folder: nil) { times, _ in
            times.map { ReadFrame(time: $0, lines: [ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02))]) }
        }
        XCTAssertFalse(found.problems.isEmpty)
        XCTAssertTrue(found.problems.allSatisfy { $0.fix == nil })
    }

    func testTextInAnOutOfBoundsPictureShadowCannotBlameTheLowerFile() async throws {
        var p = project()
        p.settings.width = 1920; p.settings.height = 1080
        p.media[0].width = 1920; p.media[0].height = 1080
        let card = MediaItem(id: "med_shadow_card", path: "card.png", kind: .image, role: .graphic, width: 100, height: 50, hasVideo: true, hasAlpha: true)
        p.media.append(card)
        let video = VideoProperties(transform: Transform(scale: 5.0 / 96), effects: [Effect(type: "dropShadow", params: ["distance": .number(100), "angle": .number(180), "blur": .number(0), "opacity": .number(100)])])
        p.videoTracks.append(Track(kind: .video, name: "Card", clips: [Clip(id: "clip_shadow_card", content: .media(mediaID: card.id), start: .zero, duration: t(1), video: video)]))
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 1020.0 / 1920, y: 530.0 / 1080, width: 80.0 / 1920, height: 20.0 / 1080)))]
        let found = try await run(p, reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertNil(found.problems.first?.fix, "the upper picture's shadow can supply glyphs outside its ordinary bounds")
    }

    func testAttributionUsesTheClipActuallyRenderedAtASnappedBoundary() async throws {
        let media = try TestMedia()
        let context = try XCTUnwrap(CGContext(data: nil, width: 384, height: 216, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 384, height: 216))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(media.folder.appendingPathComponent("early.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var p = project()
        let card = MediaItem(id: "med_early_card", path: "early.png", kind: .image, role: .graphic, width: 3840, height: 2160, hasVideo: true)
        p.media.append(card)
        let clip = Clip(id: "clip_early_card", content: .media(mediaID: card.id), start: t(0.0005), duration: t(0.02), video: VideoProperties())
        p.videoTracks.append(Track(kind: .video, name: "Early card", clips: [clip]))
        let plan = RenderPlanner.plan(p, format: nil, assets: nil)
        XCTAssertTrue(plan.instructions.first { $0.range.contains(.zero) }!.stack.flatMap(\.layers).contains { $0.clipID == clip.id })
        let reader = FakeReader()
        reader.shows = [(t(0), FrameRate.fps30.frameDuration, ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
        let found = try await PrivacyCheck.run(project: p, ranges: [TimeRange(start: .zero, end: t(1))], folder: media.projectFolder) { times, _ in reader.read(times) }
        XCTAssertEqual(found.problems.count, 1)
        guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("the rendered card must be actionable") }
        XCTAssertEqual(mediaID, card.id)
        XCTAssertEqual(found.problems.first?.clipIDs, [clip.id])
    }

    func testANonoverlappingShadowedTitleLeavesTheUnderlyingSourceActionable() async throws {
        let title = Clip(id: "clip_corner_title", content: .text(TextContent(text: "Hello", style: TextStyle(size: 20))), start: .zero, duration: t(1), video: VideoProperties(transform: Transform(position: Point(x: 0.5, y: 0.9)), effects: [Effect(type: "dropShadow")]))
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.02)))]
        let found = try await run(project(text: [title]), reader, to: 1)
        guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("a distant shadow cannot supply this line") }
        XCTAssertEqual(mediaID, screen.id)
    }

    func testRecognisedTextIsNotDiscardedBecauseItsSourceHasABlur() async throws {
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
        let video = VideoProperties(effects: [Effect(type: "blur", params: ["radius": .number(0)])])
        let found = try await run(project(screenVideo: video), reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("a no-op blur must leave the source actionable") }
        XCTAssertEqual(mediaID, screen.id)
    }

    func testOpaqueColourGradesKeepTheirSourceActionable() async throws {
        for type in ["colorAdjust", "hsl", "colorWheels", "vignette", "sharpen", "lut"] {
            var p = project()
            p.media[0].look = [Effect(type: type)]
            let reader = FakeReader()
            reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
            let found = try await run(p, reader, to: 1)
            XCTAssertEqual(found.problems.count, 1)
            guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("a colour grade must retain actionable source attribution: \(type)") }
            XCTAssertEqual(mediaID, screen.id)
        }
    }

    func testACroppedOutTitleWithAnEffectCannotHideTheSourceAttribution() async throws {
        let title = Clip(id: "clip_cropped_effect", content: .text(TextContent(text: "jane@example.com")), start: .zero, duration: t(1), video: VideoProperties(crop: Crop(left: 0.5, right: 0.5), effects: [Effect(type: "dropShadow")]))
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.02)))]
        let found = try await run(project(text: [title]), reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("a fully cropped title cannot supply the text") }
        XCTAssertEqual(mediaID, screen.id)
    }

    func testTransitionFindingsIncludeTheOutgoingHandleAndDoNotSuggestTheWrongFile() async throws {
        var p = project()
        p.videoTracks[0].clips[0].duration = t(2)
        p.media.append(MediaItem(id: "med_blank", path: "blank.mov", kind: .video, role: .screen, duration: t(5), width: 3840, height: 2160, hasVideo: true))
        p.videoTracks[0].clips.append(Clip(id: "clip_blank", content: .media(mediaID: "med_blank"), start: t(2), duration: t(2), sourceStart: t(1)))
        p.videoTracks[0].transitions = [Transition(type: .dissolve, duration: t(1), fromClipID: "clip_screen", toClipID: "clip_blank")]
        let reader = FakeReader()
        reader.shows = [(t(2.1), t(2.3), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
        let found = try await run(p, reader, to: 4)
        XCTAssertTrue(found.problems.contains { $0.message.contains("screen.mov") })
        XCTAssertTrue(found.problems.allSatisfy { $0.fix == nil && $0.message.contains("contributing") })
    }

    func testOrdinaryFootageOnAPrivacyNamedTrackStillScans() async throws {
        var p = project()
        p.videoTracks[0].name = "Privacy (Screen)"
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
        let found = try await run(p, reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertEqual(found.problems.first?.clipIDs, ["clip_screen"])
    }

    func testACroppedOutTitleCannotSuppressPrivateTextBeneathIt() async throws {
        let title = Clip(id: "clip_invisible", content: .text(TextContent(text: "jane@example.com")), start: .zero, duration: t(1), video: VideoProperties(transform: Transform(position: Point(x: 0.5, y: 0.31)), crop: Crop(left: 0.5, right: 0.5)))
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.02)))]
        let p = project(text: [title])
        let found = try await run(p, reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        let line = reader.shows[0].line
        let attribution = PrivacyCheck.attribution(of: line.box, text: line.text, at: .zero, in: p, look: Look(opaqueVideoClipIDs: ["clip_screen"], visibleClipIDs: ["clip_screen"]))
        XCTAssertFalse(attribution.authored)
        XCTAssertEqual(attribution.source?.mediaID, screen.id)
        guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("the source below the invisible title must be actionable") }
        XCTAssertEqual(mediaID, screen.id)
    }

    func testNearTransparentTitleColorCannotSuppressPrivateFootage() async throws {
        let title = Clip(id: "clip_faint", content: .text(TextContent(text: "jane@example.com", style: TextStyle(color: RGBA(r: 1, g: 1, b: 1, a: 0.001)))), start: .zero, duration: t(1), video: VideoProperties())
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.48, y: 0.495, width: 0.04, height: 0.01)))]
        let p = project(text: [title])
        let found = try await run(p, reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        let line = reader.shows[0].line
        let attribution = PrivacyCheck.attribution(of: line.box, text: line.text, at: .zero, in: p, look: Look(opaqueVideoClipIDs: ["clip_screen"], visibleClipIDs: ["clip_screen"]))
        XCTAssertFalse(attribution.authored)
        XCTAssertNil(attribution.source, "overlapping title pixels leave the source uncertain")
        XCTAssertNil(found.problems.first?.fix)
    }

    func testAnOutlinedTitleWithTransparentFillCannotBlameTheFootageBelow() async throws {
        let style = TextStyle(color: RGBA(r: 0, g: 0, b: 0, a: 0), strokeColor: .black, strokeWidth: 3)
        let title = Clip(id: "clip_outline", content: .text(TextContent(text: "jane@example.com", style: style)), start: .zero, duration: t(1), video: VideoProperties())
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.48, y: 0.495, width: 0.04, height: 0.01)))]
        let p = project(text: [title])
        let found = try await run(p, reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        let line = reader.shows[0].line
        let attribution = PrivacyCheck.attribution(of: line.box, text: line.text, at: .zero, in: p, look: Look(opaqueVideoClipIDs: ["clip_screen"], visibleClipIDs: ["clip_screen"]))
        XCTAssertFalse(attribution.authored)
        XCTAssertNil(attribution.source)
        XCTAssertNil(found.problems.first?.fix)
    }

    func testTitleBelowUnprobedFootageCannotWhitelistThatFootagesText() async throws {
        let title = Clip(id: "clip_below", content: .text(TextContent(text: "jane@example.com")), start: .zero, duration: t(1), video: VideoProperties())
        var p = project(text: [title])
        p.media[0].width = nil
        p.media[0].height = nil
        p.videoTracks.swapAt(0, 1)
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.48, y: 0.495, width: 0.04, height: 0.01)))]
        let found = try await run(p, reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertNil(found.problems.first?.fix)
    }

    func testAnUnprobedImageWithoutTheVideoFlagStillBlocksALowerTitleExemption() async throws {
        let title = Clip(id: "clip_below", content: .text(TextContent(text: "jane@example.com")), start: .zero, duration: t(1), video: VideoProperties())
        var p = project(text: [title])
        p.media[0].kind = .image
        p.media[0].hasVideo = false
        p.media[0].width = nil
        p.media[0].height = nil
        p.videoTracks.swapAt(0, 1)
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.48, y: 0.495, width: 0.04, height: 0.01)))]
        let found = try await run(p, reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertNil(found.problems.first?.fix)
    }

    func testARotatedTitlesEmptyBoundingBoxCornersDoNotExemptFootage() async throws {
        let title = Clip(id: "clip_rotated", content: .text(TextContent(text: "jane@example.com", style: TextStyle(size: 100))), start: .zero, duration: t(1), video: VideoProperties(transform: Transform(rotation: 45)))
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.55, y: 0.25, width: 0.1, height: 0.02)))]
        let p = project(text: [title])
        let found = try await run(p, reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        let line = reader.shows[0].line
        let attribution = PrivacyCheck.attribution(of: line.box, text: line.text, at: .zero, in: p, look: Look(opaqueVideoClipIDs: ["clip_screen"], visibleClipIDs: ["clip_screen"]))
        XCTAssertFalse(attribution.authored)
        XCTAssertNil(attribution.source, "overlapping title pixels leave the source uncertain")
        XCTAssertNil(found.problems.first?.fix)
    }

    func testASpatialAdjustmentCannotSuggestARedactionAtUnchangedCoordinates() async throws {
        for type in ["customScale", "dropShadow", "pixelate"] {
            var p = project()
            let adjustment = Clip(id: "clip_adjustment", content: .adjustment, start: .zero, duration: t(1), video: VideoProperties(effects: [Effect(type: type)]))
            p.videoTracks.append(Track(kind: .video, name: "Spatial effect", clips: [adjustment]))
            let reader = FakeReader()
            reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.7, width: 0.15, height: 0.02)))]
            let found = try await run(p, reader, to: 1)
            XCTAssertEqual(found.problems.count, 1)
            XCTAssertNil(found.problems.first?.fix, "\(type) may move glyphs away from their original source coordinates")
        }
        var graded = project()
        graded.videoTracks.append(Track(kind: .video, name: "Grade", clips: [Clip(content: .adjustment, start: .zero, duration: t(1), video: VideoProperties(effects: [Effect(type: "colorAdjust")]))]))
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
        let found = try await run(graded, reader, to: 1)
        guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { return XCTFail("a coordinate-preserving grade keeps its source actionable") }
        XCTAssertEqual(mediaID, screen.id)
    }

    func testAdjustmentAndCornerLayersDoNotMisattributeTextToACutoutCamera() async throws {
        let layers: [(ClipContent, VideoProperties)] = [
            (.adjustment, VideoProperties()),
            (.graphic(GraphicContent(template: SectionCard.template)), VideoProperties(transform: Transform(position: Point(x: 0.9, y: 0.9), scale: 0.1))),
            (.solid(color: .white), VideoProperties(transform: Transform(position: Point(x: 0.9, y: 0.9), scale: 0.1))),
            (.solid(color: RGBA(r: 1, g: 1, b: 1, a: 0)), VideoProperties())
        ]
        for (content, video) in layers {
            for cameraOnTop in [false, true] {
                var p = project()
                p.videoTracks.append(Track(id: "trk_middle", kind: .video, name: "Overlay", clips: [Clip(id: "clip_middle", content: content, start: .zero, duration: t(1), video: video)]))
                if cameraOnTop {
                    var camera = screen
                    camera.id = "med_camera"; camera.path = "camera.mov"; camera.role = .camera
                    p.media.append(camera)
                    p.videoTracks.append(Track(id: "trk_camera", kind: .video, name: "Camera", clips: [Clip(id: "clip_camera", content: .media(mediaID: camera.id), start: .zero, duration: t(1), video: VideoProperties(cutout: Cutout()))]))
                }
                let reader = FakeReader()
                reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
                let found = try await run(p, reader, to: 1)
                XCTAssertEqual(found.problems.count, 1)
                if cameraOnTop {
                    XCTAssertNil(found.problems.first?.fix, "a cutout's unknown pixels cannot be assigned to either file automatically")
                } else {
                    guard case .redact(_, _, let mediaID, _, _, _, _)? = found.problems.first?.fix else { XCTFail("unobscured screen text must remain actionable"); continue }
                    XCTAssertEqual(mediaID, screen.id)
                    XCTAssertEqual(found.problems.first?.clipIDs, ["clip_screen"])
                }
            }
        }
    }

    func testATranslucentTitleCannotBlameTheFootageBelow() async throws {
        let title = Clip(id: "clip_title", content: .text(TextContent(text: "jane@example.com")), start: .zero, duration: t(1), video: VideoProperties(opacity: 0.6))
        let reader = FakeReader()
        reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.48, y: 0.495, width: 0.04, height: 0.01)))]
        let found = try await run(project(text: [title]), reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertNil(found.problems.first?.fix)
    }

    func testUnknownAlphaAndTranslucencyCannotBlameTheOpaqueFileBelow() async throws {
        for mode in ["opacity", "cutout", "alpha"] {
            var p = project()
            var camera = screen
            camera.id = "med_camera"; camera.path = "camera.mov"; camera.role = .camera
            camera.hasAlpha = mode == "alpha"
            p.media.append(camera)
            var video = VideoProperties()
            if mode == "opacity" { video.opacity = 0.6 }
            if mode == "cutout" { video.cutout = Cutout() }
            p.videoTracks.append(Track(id: "trk_camera", kind: .video, name: "Camera", clips: [Clip(id: "clip_camera", content: .media(mediaID: camera.id), start: .zero, duration: t(1), video: video)]))
            let reader = FakeReader()
            reader.shows = [(t(0), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
            let found = try await run(p, reader, to: 1)
            XCTAssertEqual(found.problems.count, 1)
            XCTAssertNil(found.problems.first?.fix, "the upper file could own these glyphs")
        }
    }

    func testAnUncertainGraphicCannotTurnACutoutCameraIntoACertainSource() async throws {
        var p = project()
        var camera = screen
        camera.id = "med_camera"; camera.path = "camera.mov"; camera.role = .camera
        p.media.append(camera)
        p.videoTracks.append(Track(id: "trk_middle", kind: .video, name: "Overlay", clips: [Clip(id: "clip_middle", content: .graphic(GraphicContent(template: SectionCard.template)), start: .zero, duration: t(1), video: VideoProperties())]))
        p.videoTracks.append(Track(id: "trk_camera", kind: .video, name: "Camera", clips: [Clip(id: "clip_camera", content: .media(mediaID: camera.id), start: .zero, duration: t(1), video: VideoProperties(cutout: Cutout()))]))
        let reader = FakeReader()
        reader.shows = [(t(0.5), t(1), ReadLine(text: "jane@example.com", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.02)))]
        let found = try await run(p, reader, to: 1)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertNil(found.problems.first?.fix)
    }

    func testUnattributedLinesStillRunAddressAndNameListRules() async throws {
        var p = project()
        p.media[0].width = nil
        p.media[0].height = nil
        let reader = FakeReader()
        reader.shows = [
            (t(0), t(1), ReadLine(text: "Collect the keys at 12", box: CGRect(x: 0.7, y: 0.30, width: 0.15, height: 0.02))),
            (t(0), t(1), ReadLine(text: "Harbour Rise", box: CGRect(x: 0.7, y: 0.325, width: 0.08, height: 0.02))),
            (t(1), t(2), ReadLine(text: "Sarah Johnson", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.02))),
            (t(1), t(2), ReadLine(text: "David Williams", box: CGRect(x: 0.1, y: 0.13, width: 0.2, height: 0.02))),
            (t(1), t(2), ReadLine(text: "Emily Thompson", box: CGRect(x: 0.1, y: 0.16, width: 0.2, height: 0.02)))
        ]
        let found = try await run(p, reader, to: 2)
        XCTAssertTrue(found.problems.contains { $0.message.contains("12 Harbour Rise") })
        XCTAssertTrue(found.problems.contains { $0.message.contains("names") })
        XCTAssertTrue(found.problems.allSatisfy { $0.fix == nil })
    }

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
        // Every output frame, including exposures between the old samples.
        XCTAssertEqual(reader.asked, 1800)
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
        XCTAssertEqual(none.problems.count, 1, "recognised private text must not be discarded when placement attribution fails")
        XCTAssertNil(none.problems.first?.fix, "an unknown source cannot have a source-specific redaction")
    }

    func testAnUnprobedPhoneFrameCannotChooseAnAutomaticSource() async throws {
        // Without this PNG's pixels, a scan cannot establish whether the
        // recording or the frame supplied a line. Keep it for review.
        let frameArt = MediaItem(id: "med_frame", path: "broll/phone-frame.png", kind: .image, role: .broll, width: 1000, height: 2000, hasVideo: true, hasAlpha: true)
        var p = project()
        p.media.append(frameArt)
        p.videoTracks.insert(Track(id: "trk_frame", kind: .video, name: "Phone frame", clips: [
            Clip(id: "clip_frame", content: .media(mediaID: "med_frame"), start: .zero, duration: t(60))
        ], rippleMode: .follow), at: 1)
        let reader = FakeReader()
        reader.shows = [(t(5), t(6), ReadLine(text: "Frequent Flyer 1234567890", box: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.02)))]
        let found = try await run(p, reader)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertNil(found.problems.first?.fix, "the unprobed overlay may own the glyphs; inspect rather than redact the wrong file")
    }

    func testAnOpaqueCardWithAlphaKeepsItsOwnText() async throws {
        for hasAlpha in [true, false] { try await checkCardAttribution(hasAlpha: hasAlpha) }
    }

    func checkCardAttribution(hasAlpha: Bool) async throws {
        // A still with alpha round an opaque card over the screen: text on
        // the card is the card's, so its redact goes on the card, not under it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-alpha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // 384 by 216, see-through, with an opaque white square in its middle.
        let context = try XCTUnwrap(CGContext(data: nil, width: 384, height: 216, bitsPerComponent: 8, bytesPerRow: 1536,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 96, y: 54, width: 192, height: 108))
        let image = try XCTUnwrap(context.makeImage())
        let url = folder.appendingPathComponent("card.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let card = MediaItem(id: "med_card", path: "card.png", kind: .image, role: .broll, width: 384, height: 216, hasVideo: true, hasAlpha: hasAlpha)
        var p = project()
        p.media.append(card)
        p.videoTracks.insert(Track(id: "trk_card", kind: .video, name: "Card", clips: [
            Clip(id: "clip_card", content: .media(mediaID: "med_card"), start: .zero, duration: t(60))
        ], rippleMode: .follow), at: 1)
        let reader = FakeReader()
        reader.shows = [
            (t(5), t(6), ReadLine(text: "jane@example.com", box: CGRect(x: 0.45, y: 0.49, width: 0.1, height: 0.02))),
            (t(20), t(21), ReadLine(text: "jane@example.com", box: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.02))),
            (t(25), t(26), ReadLine(text: "jane@example.com", box: CGRect(x: 0.21, y: 0.49, width: 0.1, height: 0.02))),
            (t(30), t(31), ReadLine(text: "jane@example.com", box: CGRect(x: 0.18, y: 0.49, width: 0.1, height: 0.02)))
        ]
        let found = try await PrivacyCheck.run(project: p, ranges: [TimeRange(start: .zero, end: t(60))], folder: ProjectFolder(root: folder)) { times, _ in reader.read(times) }
        let targets = found.problems.compactMap { problem -> String? in
            guard case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix else { return nil }
            return mediaID
        }
        XCTAssertEqual(targets, ["med_card", "med_screen"], "on the card in the middle, through it at the corner")
        XCTAssertEqual(found.problems.count, 4)
        XCTAssertTrue(found.problems.suffix(2).allSatisfy { $0.fix == nil }, "a partly covered line has an uncertain source")
    }

    func testAnUnprobedCutoutCannotChooseAnAutomaticSource() async throws {
        // Without the per-frame matte, these glyphs could come from either
        // picture. A source-specific fix would be a guess.
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
        XCTAssertNil(found.problems.first?.fix, "the unprobed overlay may own the glyphs; inspect rather than redact the wrong file")
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

    func testAuthoredPrivateLookingTextStillRequiresReview() async throws {
        let title = Clip(id: "clip_title", content: .text(TextContent(text: "Email me at jane@example.com")), start: t(40), duration: t(5), video: VideoProperties(transform: Transform(position: Point(x: 0.5, y: 0.825))))
        let reader = FakeReader()
        reader.shows = [(t(40), t(45), ReadLine(text: "Email me at jane@example.com", box: CGRect(x: 0.3, y: 0.8, width: 0.4, height: 0.05)))]
        let found = try await run(project(text: [title]), reader)
        XCTAssertEqual(found.problems.count, 1)
        XCTAssertNil(found.problems.first?.fix, "OCR cannot prove whether the matching glyphs came from the title or footage")
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
