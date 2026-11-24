import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import TandemCore
import TandemMedia
@testable import TandemRender

extension PrivacyAuditRenderTests {
    func testDurableStillBlurCannotReuseTheFilesUnfilteredAlphaProof() async throws {
        let media = try TestMedia()
        let screenURL = try await media.movie("strip-screen.mov", seconds: 2, size: canvas) { _, context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: self.canvas))
            self.text(self.email, x: 400, y: 326, size: 28, in: context)
        }
        let imageURL = media.folder.appendingPathComponent("opaque-strip.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.clear(CGRect(origin: .zero, size: canvas))
        bitmap.translateBy(x: 0, y: 720)
        bitmap.scaleBy(x: 1, y: -1)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 296, width: 1280, height: 36))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var screen = try await MediaScanner.probe(screenURL, folder: media.projectFolder, id: "med_screen")
        screen.role = .screen
        let still = MediaItem(id: "med_still", path: imageURL.lastPathComponent, kind: .image, role: .graphic, width: 1280, height: 720, hasVideo: true, hasAlpha: true)
        let p = Project(name: "Filtered still alpha", settings: ProjectSettings(width: 1280, height: 720), media: [screen, still], videoTracks: [
            Track(kind: .video, name: "Screen", clips: [Clip(id: "clip_screen", content: .media(mediaID: screen.id), start: .zero, duration: t(2))]),
            Track(kind: .video, name: "Still", clips: [Clip(id: "clip_still", content: .media(mediaID: still.id), start: .zero, duration: t(2))])
        ])
        let coordinator = ProjectCoordinator(project: p)
        let patch = Rect(x: 0, y: 0.4, width: 1, height: 0.1)
        XCTAssertFalse(try apply(coordinator, .redact(range: TimeRange(start: .zero, end: t(1)), rect: patch, mediaID: still.id, style: .blur, size: 90)), "the editor already refuses an uncovered occurrence of the same still")
        XCTAssertTrue(try apply(coordinator, .redact(range: TimeRange(start: .zero, end: t(2)), rect: patch, mediaID: still.id, style: .blur, size: 90)))
        // The public renderer also accepts imported project values. Model
        // a saved partial copy directly; the edit entry point refuses it.
        var imported = coordinator.project
        for track in imported.videoTracks.indices {
            for index in imported.videoTracks[track].clips.indices where imported.videoTracks[track].clips[index].isRedaction {
                imported.videoTracks[track].clips[index].duration = t(1)
            }
        }
        let projectURL = media.folder.appendingPathComponent("Imported.tandem")
        try ProjectFile.save(imported, revision: 0, to: projectURL)
        let loaded = try ProjectFile.load(from: projectURL).project
        XCTAssertEqual(loaded.videoTracks.flatMap(\.clips).filter(\.isRedaction).map(\.duration), [t(1)])
        let reader = FrameTextReader(context: RenderContext(project: loaded, folder: media.projectFolder), width: 1280)
        let frames = try await reader.read([t(1.2)], sequential: true)
        XCTAssertTrue(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "durable source blur mixes the strip's alpha after its visible copy ends")
        let found = try await PrivacyCheck.run(project: loaded, ranges: [TimeRange(start: t(1.2), duration: FrameRate.fps30.frameDuration)], folder: media.projectFolder) { times, sequential in try await reader.read(times, sequential: sequential) }
        XCTAssertFalse(found.problems.isEmpty)
        XCTAssertTrue(found.problems.allSatisfy { $0.fix == nil }, "the raw PNG cannot prove the opacity of filtered source pixels")
    }

    func testLanczosEdgeTransparencyCannotStealAttributionAtExtremeZoom() async throws {
        let media = try TestMedia()
        let screenURL = try await media.movie("edge-screen.mov", seconds: 1, size: canvas) { _, context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: self.canvas))
            self.text(self.email, x: 400, y: 180, size: 28, in: context)
        }
        let overlayURL = try await media.movie("edge-overlay.mov", seconds: 1, size: canvas) { _, context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: self.canvas))
        }
        var screen = try await MediaScanner.probe(screenURL, folder: media.projectFolder, id: "med_screen")
        screen.role = .screen
        var overlay = try await MediaScanner.probe(overlayURL, folder: media.projectFolder, id: "med_overlay")
        overlay.role = .graphic
        let p = Project(name: "Resampled alpha edge", settings: ProjectSettings(width: 1280, height: 720), media: [screen, overlay], videoTracks: [
            Track(kind: .video, name: "Screen", clips: [Clip(id: "clip_screen", content: .media(mediaID: screen.id), start: .zero, duration: t(1))]),
            Track(kind: .video, name: "Overlay", clips: [Clip(id: "clip_overlay", content: .media(mediaID: overlay.id), start: .zero, duration: t(1))])
        ])
        let coordinator = ProjectCoordinator(project: p)
        XCTAssertTrue(try apply(coordinator, .updateClip(clipID: "clip_overlay", patch: .object(["video": .object(["transform": .object([
            "position": .object(["x": .number(0.5), "y": .number(500.2)]), "scale": .number(1000)
        ])])]))))
        let reader = FrameTextReader(context: RenderContext(project: coordinator.project, folder: media.projectFolder), width: 1280)
        let frames = try await reader.read([t(0.2)], sequential: true)
        XCTAssertTrue(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "the real Lanczos edge reveals the screen through an opaque source")
        let found = try await PrivacyCheck.run(project: coordinator.project, ranges: [TimeRange(start: t(0.2), duration: FrameRate.fps30.frameDuration)], folder: media.projectFolder) { times, sequential in try await reader.read(times, sequential: sequential) }
        XCTAssertFalse(found.problems.isEmpty)
        XCTAssertTrue(found.problems.allSatisfy { $0.fix == nil }, "an OCR box inside geometric bounds can still overlap the sampling edge")

        var interior = p
        interior.videoTracks.removeLast()
        interior.videoTracks[0].clips[0].video = VideoProperties(transform: Transform(position: Point(x: 0.5, y: 0.75), scale: 2))
        let interiorReader = FrameTextReader(context: RenderContext(project: interior, folder: media.projectFolder), width: 1280)
        let safe = try await PrivacyCheck.run(project: interior, ranges: [TimeRange(start: t(0.2), duration: FrameRate.fps30.frameDuration)], folder: media.projectFolder) { times, sequential in try await interiorReader.read(times, sequential: sequential) }
        let targets = safe.problems.compactMap { problem -> String? in
            guard case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix else { return nil }
            return mediaID
        }
        XCTAssertEqual(targets, [screen.id], "ordinary zoomed interior text remains actionable")
    }

    func testCustomEffectDefinitionsCannotWeakenDurableSourceProtection() async throws {
        for style in [RedactStyle.blur, .pixelate] {
            let (media, coordinator) = try await fixture(video: true)
            let control = try await image(coordinator, media, at: 0.2)
            XCTAssertTrue(recognise(control).contains { $0.contains(email) })
            XCTAssertTrue(try apply(coordinator, .redact(range: TimeRange(start: .zero, end: t(3)), rect: region, mediaID: "med_dummy", style: style, size: 90)))
            var registry = EffectRegistry.standard
            var replacement = try XCTUnwrap(registry.definition(style.rawValue))
            replacement.coreImage = nil
            registry.register(replacement)
            let reader = FrameTextReader(context: RenderContext(project: coordinator.project, folder: media.projectFolder, effects: registry), width: 1280)
            let frames = try await reader.read([t(0.2)], sequential: true)
            XCTAssertEqual(frames.count, 1)
            XCTAssertTrue(frames.flatMap(\.lines).contains { $0.text.contains("PUBLIC") }, "OCR still reads the unprotected header")
            XCTAssertFalse(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "source concealment must retain its built-in meaning when a caller replaces the effect definition")
        }
    }

    func testAReplacedManagedBlurCannotAttestTheWrongVideo() async throws {
        let (media, original) = try await fixture(video: true)
        let url = try await media.movie("black-overlay.mov", seconds: 1, size: canvas) { _, context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: self.canvas))
        }
        var overlay = try await MediaScanner.probe(url, folder: media.projectFolder, id: "med_overlay")
        overlay.role = .graphic
        var p = original.project
        p.media.append(overlay)
        p.videoTracks.append(Track(kind: .video, name: "Overlay", clips: [Clip(id: "clip_overlay", content: .media(mediaID: overlay.id), start: .zero, duration: t(1))]))
        let coordinator = ProjectCoordinator(project: p)
        XCTAssertTrue(try apply(coordinator, .redact(range: TimeRange(start: .zero, end: t(1)), rect: region, mediaID: overlay.id, style: .blur, size: 90)))
        var registry = EffectRegistry.standard
        var replacement = try XCTUnwrap(registry.definition("blur"))
        replacement.coreImage = CoreImageBinding(filter: "CIMaskToAlpha", inputs: [:])
        registry.register(replacement)
        let reader = FrameTextReader(context: RenderContext(project: coordinator.project, folder: media.projectFolder, effects: registry), width: 1280)
        let frames = try await reader.read([t(0.2)], sequential: true)
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "a replacement effect cannot turn durable concealment into a transparent hole")
        XCTAssertTrue(frames.allSatisfy { $0.visibleClipIDs.contains("clip_overlay") && $0.visibleClipIDs.contains("clip_dummy") }, "the canonical privacy filter stays attestable when display effects are replaced")
        let found = try await PrivacyCheck.run(project: coordinator.project, ranges: [TimeRange(start: .zero, end: t(1))], folder: media.projectFolder) { times, sequential in try await reader.read(times, sequential: sequential) }
        XCTAssertTrue(found.problems.isEmpty, "the standard privacy effect keeps the lower screen concealed")
    }

    func testRawCropValuesCannotExpandAnOverlaysAutomaticAttribution() async throws {
        let media = try TestMedia()
        let screenURL = try await media.movie("upper-email.mov", seconds: 1, size: canvas) { _, context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: self.canvas))
            self.text(self.email, x: 400, y: 185, size: 20, in: context)
        }
        let overlayURL = try await media.movie("lower-overlay.mov", seconds: 1, size: canvas) { _, context in
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(origin: .zero, size: self.canvas))
        }
        var screen = try await MediaScanner.probe(screenURL, folder: media.projectFolder, id: "med_screen")
        screen.role = .screen
        var overlay = try await MediaScanner.probe(overlayURL, folder: media.projectFolder, id: "med_overlay")
        overlay.role = .graphic
        let p = Project(name: "Clamped crop attribution", settings: ProjectSettings(width: 1280, height: 720), media: [screen, overlay], videoTracks: [
            Track(kind: .video, name: "Screen", clips: [Clip(id: "clip_screen", content: .media(mediaID: screen.id), start: .zero, duration: t(1))]),
            Track(kind: .video, name: "Overlay", clips: [Clip(id: "clip_overlay", content: .media(mediaID: overlay.id), start: .zero, duration: t(1))])
        ])
        let coordinator = ProjectCoordinator(project: p)
        XCTAssertTrue(try apply(coordinator, .updateClip(clipID: "clip_overlay", patch: .object(["video": .object([
            "transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.77)]), "scale": .number(0.5), "rotation": .number(45)]),
            "crop": .object(["left": .number(-1), "top": .number(-1)])
        ])]))))
        let reader = FrameTextReader(context: RenderContext(project: coordinator.project, folder: media.projectFolder), width: 1280)
        let frames = try await reader.read([t(0.2)], sequential: true)
        XCTAssertTrue(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "the clamped overlay leaves the screen text visible above it")
        let frame = try XCTUnwrap(frames.first)
        let look = Look(opaqueVideoClipIDs: frame.opaqueVideoClipIDs, visibleClipIDs: frame.visibleClipIDs)
        let knownBox = CGRect(x: 400.0 / 1280, y: 160.0 / 720, width: 200.0 / 1280, height: 30.0 / 720)
        XCTAssertNotEqual(PrivacyCheck.source(of: knownBox, text: email, at: t(0.2), in: coordinator.project, look: look)?.mediaID, overlay.id)
        let found = try await PrivacyCheck.run(project: coordinator.project, ranges: [TimeRange(start: .zero, end: t(1))], folder: media.projectFolder) { times, sequential in try await reader.read(times, sequential: sequential) }
        XCTAssertFalse(found.problems.isEmpty)
        for problem in found.problems {
            if case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix {
                XCTAssertEqual(mediaID, screen.id, "raw crop values cannot enlarge the overlay's rendered bounds")
            }
        }
    }

    func testADecodedButDiscardedOverlayCannotStealAttribution() async throws {
        let (media, original) = try await fixture(video: true)
        let url = try await media.movie("discarded.mov", seconds: 1, size: canvas) { _, context in
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(origin: .zero, size: self.canvas))
        }
        var overlay = try await MediaScanner.probe(url, folder: media.projectFolder, id: "med_overlay")
        overlay.role = .graphic
        var p = original.project
        p.media.append(overlay)
        p.videoTracks.append(Track(kind: .video, name: "Discarded overlay", clips: [Clip(id: "clip_overlay", content: .media(mediaID: overlay.id), start: .zero, duration: t(1))]))
        let coordinator = ProjectCoordinator(project: p)
        XCTAssertTrue(try apply(coordinator, .updateClip(clipID: "clip_overlay", patch: .object(["video": .object(["transform": .object(["scale": .number(-1)])])]))))
        let reader = FrameTextReader(context: RenderContext(project: coordinator.project, folder: media.projectFolder), width: 1280)
        let frames = try await reader.read([t(0.2)], sequential: true)
        XCTAssertTrue(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "the renderer discards the negative-scale overlay")
        let found = try await PrivacyCheck.run(project: coordinator.project, ranges: [TimeRange(start: .zero, end: t(1))], folder: media.projectFolder) { times, sequential in try await reader.read(times, sequential: sequential) }
        let targets = found.problems.compactMap { problem -> String? in
            guard case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix else { return nil }
            return mediaID
        }
        XCTAssertEqual(targets, ["med_dummy"], "decoded input is not proof that a layer contributed to the output")
    }

    func testAPathReplacementWithStaleDimensionsCannotStealAttribution() async throws {
        let media = try TestMedia()
        let screenURL = try await media.movie("left-email.mov", seconds: 1, size: canvas) { _, context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: self.canvas))
            self.text(self.email, x: 30, y: 320, size: 24, in: context)
        }
        let square = CGSize(width: 720, height: 720)
        let squareVideo = try await media.movie("square.mov", seconds: 1, size: square) { _, context in
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(origin: .zero, size: square))
        }
        let squareImage = media.folder.appendingPathComponent("square.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 720, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 0.5, alpha: 1))
        bitmap.fill(CGRect(origin: .zero, size: square))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(squareImage as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var screen = try await MediaScanner.probe(screenURL, folder: media.projectFolder, id: "med_screen")
        screen.role = .screen
        for (kind, replacement) in [(MediaKind.video, squareVideo), (.image, squareImage)] {
            let overlay = MediaItem(id: "med_overlay", path: "wide-original", kind: kind, role: .graphic,
                duration: t(1), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
            let p = Project(name: "Stale overlay geometry", settings: ProjectSettings(width: 1280, height: 720), media: [screen, overlay], videoTracks: [
                Track(kind: .video, name: "Screen", clips: [Clip(id: "clip_screen", content: .media(mediaID: screen.id), start: .zero, duration: t(1))]),
                Track(kind: .video, name: "Overlay", clips: [Clip(id: "clip_overlay", content: .media(mediaID: overlay.id), start: .zero, duration: t(1))])
            ])
            let coordinator = ProjectCoordinator(project: p)
            XCTAssertTrue(try apply(coordinator, .updateMedia(mediaID: overlay.id, patch: .object(["path": .string(replacement.lastPathComponent)]))))
            XCTAssertEqual(coordinator.project.media.last?.width, 1280, "the supported path-only edit retains old geometry")
            let reader = FrameTextReader(context: RenderContext(project: coordinator.project, folder: media.projectFolder), width: 1280)
            let frames = try await reader.read([t(0.2)], sequential: true)
            XCTAssertTrue(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "the square overlay leaves the screen's left margin readable")
            let found = try await PrivacyCheck.run(project: coordinator.project, ranges: [TimeRange(start: .zero, end: t(1))], folder: media.projectFolder) { times, sequential in try await reader.read(times, sequential: sequential) }
            XCTAssertFalse(found.problems.isEmpty)
            for problem in found.problems {
                guard case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix else {
                    XCTFail("actual transparent margins must preserve the lower screen's actionable finding")
                    continue
                }
                XCTAssertEqual(mediaID, screen.id)
                XCTAssertEqual(problem.clipIDs, ["clip_screen"])
            }
        }
    }

    func testALoadedVideoThatSuppliesNoFrameCannotStealAttribution() async throws {
        let (media, c) = try await fixture(video: true)
        let control = try await image(c, media)
        var p = c.project
        var overlay = p.media[0]
        overlay.id = "med_overlay"
        p.media.append(overlay)
        p.videoTracks.append(Track(kind: .video, name: "Missing decoded frame", clips: [Clip(id: "clip_overlay", content: .media(mediaID: overlay.id), start: .zero, duration: t(3))]))
        let source = try await SourceCache.shared.source(for: media.folder.appendingPathComponent("dummy.mov"))
        let picture = SourceTrack(url: source.asset.url, asset: source.asset, track: try XCTUnwrap(source.video), timeRange: source.videoRange, leading: nil, opaque: source.opaque)
        XCTAssertTrue(picture.opaque)
        var clips = RenderEngine.sceneClips(p, folder: media.projectFolder)
        clips["clip_dummy"]?.picture = picture
        clips["clip_overlay"]?.picture = picture
        let evidence = FramePrivacyEvidence()
        let scene = RenderScene(canvas: canvas, frameDuration: FrameRate.fps30.frameDuration, format: nil, clips: clips, registry: .standard, folder: media.projectFolder)
        struct LowerOnly: FrameSources {
            let image: CIImage
            func frame(track: Int) -> CIImage? { track == 0 ? image : nil }
        }
        let stack: [StackNode] = [
            .layer(LayerRef(clipID: "clip_dummy", trackIndex: 0, pictureTrack: 0, matteTrack: nil)),
            .layer(LayerRef(clipID: "clip_overlay", trackIndex: 1, pictureTrack: 1, matteTrack: nil))
        ]
        let composed = FrameComposer(scene: scene, privacyEvidence: evidence).compose(stack, at: .zero, sources: LowerOnly(image: CIImage(cgImage: control)))
        let rendered = try XCTUnwrap(FrameTextReader.ciContext.createCGImage(composed, from: CGRect(origin: .zero, size: canvas)))
        let inputs = try XCTUnwrap(evidence.complete())
        var frame = FrameTextReader.recognise(rendered, at: .zero)
        XCTAssertTrue(frame.lines.contains { $0.text.contains(email) })
        frame.opaqueVideoClipIDs = inputs.opaqueVideos
        frame.unavailableClipIDs = inputs.unavailable
        frame.visibleClipIDs = inputs.visible
        let captured = frame
        let found = try await PrivacyCheck.run(project: p, ranges: [TimeRange(start: .zero, duration: FrameRate.fps30.frameDuration)], folder: media.projectFolder) { times, _ in
            times.map { time in var value = captured; value.time = time; return value }
        }
        let targets = found.problems.compactMap { problem -> String? in
            guard case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix else { return nil }
            return mediaID
        }
        XCTAssertEqual(targets, ["med_dummy"])
    }

    func testAnAlphaVideoWithoutMetadataCannotStealTheScreensRedaction() async throws {
        for codec in ["prores", "hevc"] { try await checkAlphaVideoWithoutMetadata(codec: codec) }
    }

    func checkAlphaVideoWithoutMetadata(codec: String) async throws {
        let media = try TestMedia()
        let screenURL = try await media.movie("right-email.mov", seconds: 1, size: canvas) { _, context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: self.canvas))
            self.text(self.email, x: 880, y: 320, size: 28, in: context)
        }
        let overlayURL = try await media.alphaOverlay("alpha-overlay.mov", codec: codec, width: 1280, height: 720, seconds: 1)
        var screen = try await MediaScanner.probe(screenURL, folder: media.projectFolder, id: "med_screen")
        screen.role = .screen
        var overlay = try await MediaScanner.probe(overlayURL, folder: media.projectFolder, id: "med_overlay")
        overlay.role = .graphic
        XCTAssertTrue(overlay.hasAlpha, "the file really contains alpha")
        overlay.hasAlpha = false
        let p = Project(name: "Missing alpha metadata", settings: ProjectSettings(width: 1280, height: 720), media: [screen, overlay], videoTracks: [
            Track(kind: .video, name: "Screen", clips: [Clip(id: "clip_screen", content: .media(mediaID: screen.id), start: .zero, duration: t(1))]),
            Track(kind: .video, name: "Overlay", clips: [Clip(id: "clip_overlay", content: .media(mediaID: overlay.id), start: .zero, duration: t(1))])
        ])
        let reader = FrameTextReader(context: RenderContext(project: p, folder: media.projectFolder), width: 1280)
        let frames = try await reader.read([t(0.2)], sequential: true)
        XCTAssertTrue(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "the real rendered frame shows the screen through the overlay")
        let found = try await PrivacyCheck.run(project: p, ranges: [TimeRange(start: .zero, end: t(1))], folder: media.projectFolder) { times, sequential in try await reader.read(times, sequential: sequential) }
        XCTAssertFalse(found.problems.isEmpty)
        for problem in found.problems {
            guard case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix else {
                XCTFail("the actual transparent video region must preserve the lower screen's actionable finding")
                continue
            }
            XCTAssertEqual(mediaID, screen.id)
            XCTAssertEqual(problem.clipIDs, ["clip_screen"])
        }
    }

    func testAnOmittedVideoCannotStealPrivacyAttributionFromTheScreen() async throws {
        for undecodable in [false, true] {
            let (media, c) = try await fixture()
            let missing = MediaItem(id: "med_missing_video", path: "missing.mov", kind: .video, role: .graphic, duration: t(3), frameRate: .fps30, width: 1280, height: 720, hasVideo: true, undecodableCodec: undecodable ? "rle " : nil)
            XCTAssertTrue(try apply(c, .addMedia(item: missing)))
            XCTAssertTrue(try apply(c, .addTrack(kind: .video, name: "Omitted video", id: "trk_missing_video")))
            XCTAssertTrue(try apply(c, .insertClip(trackID: "trk_missing_video", clip: Clip(id: "clip_missing_video", content: .media(mediaID: missing.id), start: .zero, duration: t(3), video: VideoProperties()))))
            let reader = FrameTextReader(context: RenderContext(project: c.project, folder: media.projectFolder), width: 1280)
            let frames = try await reader.read([.zero], sequential: true)
            XCTAssertTrue(frames.flatMap(\.lines).contains { $0.text.contains(email) }, "the omitted upper video displays the private source below")
            let found = try await PrivacyCheck.run(project: c.project, ranges: [TimeRange(start: .zero, end: t(1))], folder: media.projectFolder) { times, sequential in try await reader.read(times, sequential: sequential) }
            let targets = found.problems.compactMap { problem -> String? in
                guard case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix else { return nil }
                return mediaID
            }
            XCTAssertEqual(targets, ["med_dummy"])
        }
    }

    func testAMissingImageCannotStealPrivacyAttributionFromTheScreen() async throws {
        let (media, c) = try await fixture()
        let missing = MediaItem(id: "med_missing", path: "missing.png", kind: .image, role: .graphic, width: 1280, height: 720, hasVideo: true)
        XCTAssertTrue(try apply(c, .addMedia(item: missing)))
        XCTAssertTrue(try apply(c, .addTrack(kind: .video, name: "Missing image", id: "trk_missing")))
        XCTAssertTrue(try apply(c, .insertClip(trackID: "trk_missing", clip: Clip(id: "clip_missing", content: .media(mediaID: missing.id), start: .zero, duration: t(3), video: VideoProperties()))))
        let rendered = try await image(c, media)
        XCTAssertTrue(recognise(rendered).contains { $0.contains(email) }, "the compositor skips the unavailable image and displays the private source below")
        let reader = FrameTextReader(context: RenderContext(project: c.project, folder: media.projectFolder), width: 1280)
        let found = try await PrivacyCheck.run(project: c.project, ranges: [TimeRange(start: .zero, end: t(1))], folder: media.projectFolder) { times, sequential in try await reader.read(times, sequential: sequential) }
        let targets = found.problems.compactMap { problem -> String? in
            guard case .redact(_, _, let mediaID, _, _, _, _)? = problem.fix else { return nil }
            return mediaID
        }
        XCTAssertEqual(targets, ["med_dummy"])
    }

    func testAnEarlyRecoveryFallbackCannotExposeAnySampleItMayHold() async throws {
        let media = try TestMedia()
        let url = try await media.movie("opening.mov", seconds: 1, size: canvas, draw: { n, context in self.draw(context, privateText: n == 3) })
        let times = await FrameTimes.read(url)
        XCTAssertFalse(SourcePrivacyTiming(times).protectsEveryFrame)
        let item = MediaItem(id: "med_opening", path: "opening.mov", kind: .video, role: .screen, duration: t(1), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let selected = Clip(id: "clip_selected", content: .media(mediaID: item.id), start: t(4), duration: t(1), sourceStart: t(0.1), speed: 1.0 / 30, video: VideoProperties())
        let original = ProjectCoordinator(project: Project(name: "Opening fallback", settings: ProjectSettings(width: 1280, height: 720), media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [selected])]))
        let held = try await image(original, media, at: 4)
        XCTAssertTrue(recognise(held).contains { $0.contains(email) })
        XCTAssertTrue(try apply(original, .redact(range: selected.range, rect: region, mediaID: item.id, style: .blur, size: 90)))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let source = SourceTrack(url: url, asset: asset, track: video, timeRange: try await video.load(.timeRange), leading: nil)
        let picture = Clip(id: "clip_opening", content: .media(mediaID: item.id), start: .zero, duration: t(1), video: VideoProperties())
        var clip = SceneClip(clip: picture, trackIndex: 0)
        clip.media = item; clip.picture = source
        clip.privacyTiming = SourcePrivacyTiming(times)
        clip.redactions = RedactionSafety.protections(in: original.project)
        let scene = RenderScene(canvas: canvas, frameDuration: FrameRate.fps30.frameDuration, format: nil,
                                clips: [picture.id: clip], registry: EffectRegistry.standard, folder: media.projectFolder, recovery: FrameRecovery())
        // Fault-inject an image the opening recovery fallback is allowed to
        // hold after undecodable leading samples. Its PTS is later than
        // both nominal time and the ordinary 1ms look-ahead.
        struct OpeningFrame: FrameSources {
            let image: CIImage
            func frame(track: Int) -> CIImage? { image }
        }
        let layer = LayerRef(clipID: picture.id, trackIndex: 0, pictureTrack: 0, matteTrack: nil)
        let frame = FrameComposer(scene: scene).compose([.layer(layer)], at: .zero, sources: OpeningFrame(image: CIImage(cgImage: held)))
        let hidden = try XCTUnwrap(FrameTextReader.ciContext.createCGImage(frame, from: CGRect(origin: .zero, size: canvas)))
        XCTAssertFalse(recognise(hidden).contains { $0.contains(email) })
    }

    func testRecoveryClampsBeforeLookingAheadAtAFastTransitionHead() async throws {
        let media = try TestMedia()
        let url = try await media.movie("fast-recovery.mov", seconds: 0.004, size: canvas, fps: 2000, draw: { n, context in self.draw(context, privateText: n == 2) })
        let times = await FrameTimes.read(url)
        XCTAssertFalse(SourcePrivacyTiming(times).protectsEveryFrame)
        let item = MediaItem(id: "med_fast", path: "fast-recovery.mov", kind: .video, role: .screen, duration: t(0.004), frameRate: FrameRate(2000), width: 1280, height: 720, hasVideo: true)
        let selected = Clip(id: "clip_selected", content: .media(mediaID: item.id), start: t(4), duration: t(1), sourceStart: t(0.001), speed: 1.0 / 2000, video: VideoProperties())
        let original = ProjectCoordinator(project: Project(name: "Fast recovery", settings: ProjectSettings(width: 1280, height: 720), media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [selected])]))
        XCTAssertTrue(try apply(original, .redact(range: selected.range, rect: region, mediaID: item.id, style: .blur, size: 90)))
        let scopes = RedactionSafety.protections(in: original.project)
        XCTAssertTrue(scopes.contains { $0.sources.contains { $0.contains(t(0.001)) } })
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let range = try await video.load(.timeRange)
        let source = SourceTrack(url: url, asset: asset, track: video, timeRange: range, leading: nil)
        let picture = Clip(id: "clip_fast_head", content: .media(mediaID: item.id), start: t(1), duration: t(1), sourceStart: t(0.02), holdEdges: true, video: VideoProperties())
        let recovery = FrameRecovery()
        struct MissingFrames: FrameSources { func frame(track: Int) -> CIImage? { nil } }
        func recovered(protecting policies: [SourceRedaction]) throws -> CGImage {
            var clip = SceneClip(clip: picture, trackIndex: 0)
            clip.media = item; clip.picture = source
            clip.privacyTiming = SourcePrivacyTiming(times); clip.redactions = policies
            let scene = RenderScene(canvas: canvas, frameDuration: FrameRate.fps30.frameDuration, format: nil,
                                    clips: [picture.id: clip], registry: EffectRegistry.standard, folder: media.projectFolder, recovery: recovery)
            let layer = LayerRef(clipID: picture.id, trackIndex: 0, pictureTrack: 0, matteTrack: nil)
            let frame = FrameComposer(scene: scene).compose([.layer(layer)], at: t(0.9), sources: MissingFrames())
            return try XCTUnwrap(FrameTextReader.ciContext.createCGImage(frame, from: CGRect(origin: .zero, size: canvas)))
        }
        let control = try recovered(protecting: [])
        XCTAssertTrue(recognise(control).contains { $0.contains(email) }, "clamped recovery must decode the protected look-ahead sample")
        let hidden = try recovered(protecting: scopes)
        try png(control, "panel-fast-recovery-before")
        try png(hidden, "panel-fast-recovery-after")
        XCTAssertFalse(recognise(hidden).contains { $0.contains(email) })
        XCTAssertGreaterThanOrEqual(recovery.requests, 2)
    }

    func testNonFrozenRecoveryProtectsTheActualOffsetSampleItReadsAhead() async throws {
        let media = try TestMedia()
        let offset = t(0.0005)
        let url = try await media.movie("offset.mov", seconds: 4, size: canvas, offset: offset, draw: { n, context in self.draw(context, privateText: n == 30) })
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let providesCursors = try await video.load(.canProvideSampleCursors)
        XCTAssertTrue(providesCursors)
        let times = await FrameTimes.read(video)
        let range = try await video.load(.timeRange)
        XCTAssertTrue(times?.contains(t(1) + offset) == true, "the file clock must include its leading edit")
        let item = MediaItem(id: "med_offset", path: "offset.mov", kind: .video, role: .screen, duration: t(4) + offset, frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let picture = Clip(id: "clip_offset", content: .media(mediaID: item.id), start: .zero, duration: t(3), video: VideoProperties())
        let p = Project(name: "Offset recovery", settings: ProjectSettings(width: 1280, height: 720), media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [picture])])
        let original = ProjectCoordinator(project: p)
        XCTAssertTrue(try apply(original, .redact(range: picture.range, rect: region, mediaID: item.id, style: .blur, size: 90)))
        var protected = original.project
        let exact = TimeRange(start: t(1) + offset, duration: FrameRate.fps30.frameDuration)
        // A durable policy without an overlay or nominal frame-grid padding
        // isolates the recovery decoder's look-ahead from edit alignment.
        protected.sourceRedactions = protected.sourceRedactions!.map { scope in var value = scope; value.sources = [exact]; return value }
        protected.videoTracks = p.videoTracks
        let saved = try store(ProjectCoordinator(project: protected), media, as: "panel-offset-policy")
        let loaded = try ProjectFile.load(from: saved.appendingPathComponent("Synthetic.tandem")).project
        let source = SourceTrack(url: url, asset: asset, track: video, timeRange: range, leading: nil)
        let recovery = FrameRecovery()
        struct MissingFrames: FrameSources { func frame(track: Int) -> CIImage? { nil } }
        func recovered(protecting scopes: [SourceRedaction]) throws -> CGImage {
            var clip = SceneClip(clip: picture, trackIndex: 0)
            clip.media = item; clip.picture = source
            clip.privacyTiming = SourcePrivacyTiming(times)
            clip.redactions = scopes
            let scene = RenderScene(canvas: canvas, frameDuration: FrameRate.fps30.frameDuration, format: nil,
                                    clips: [picture.id: clip], registry: EffectRegistry.standard, folder: media.projectFolder, recovery: recovery)
            let layer = LayerRef(clipID: picture.id, trackIndex: 0, pictureTrack: 0, matteTrack: nil)
            let frame = FrameComposer(scene: scene).compose([.layer(layer)], at: t(0.9998), sources: MissingFrames())
            return try XCTUnwrap(FrameTextReader.ciContext.createCGImage(frame, from: CGRect(origin: .zero, size: canvas)))
        }
        let control = try recovered(protecting: [])
        XCTAssertTrue(recognise(control).contains { $0.contains(email) }, "the missing-frame path must actually decode the protected look-ahead sample")
        let hidden = try recovered(protecting: loaded.sourceRedactions ?? [])
        try png(control, "panel-offset-recovery-before")
        try png(hidden, "panel-offset-recovery-after")
        XCTAssertFalse(recognise(hidden).contains { $0.contains(email) })
        XCTAssertGreaterThanOrEqual(recovery.requests, 2)
    }

    func testTransitionBoundaryHoldsDoNotPlayNeighbouringFasterSourceFrames() async throws {
        for (head, fps) in [(true, Int32(60)), (false, Int32(120)), (true, Int32(2000))] {
            let media = try TestMedia()
            let index = head ? 1 : Int(fps) - 2
            let seconds = fps > 1000 ? 0.004 : 1.0
            try await media.movie("fast.mov", seconds: seconds, size: canvas, fps: fps, draw: { n, context in self.draw(context, privateText: n == index) })
            let item = MediaItem(id: "med_fast", path: "fast.mov", kind: .video, role: .screen, duration: t(seconds), frameRate: FrameRate(Int64(fps)), width: 1280, height: 720, hasVideo: true)
            let selected = Time.frames(Int64(index), at: item.frameRate!)
            let actual = await FrameTimes.read(media.folder.appendingPathComponent("fast.mov"))
            XCTAssertTrue(actual?.contains(selected) == true, "the file must contain the protected source sample")
            let frozen = Clip(id: "clip_protected", content: .media(mediaID: item.id), start: t(4), duration: t(1), sourceStart: selected, speed: fps > 1000 ? 1.0 / Double(fps) : 1, freezeFrame: fps <= 1000, video: VideoProperties())
            let original = ProjectCoordinator(project: Project(name: "Faster edge", settings: ProjectSettings(width: 1280, height: 720, frameRate: .fps30), media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [frozen])]))
            let control = try await image(original, media, at: 4.5)
            XCTAssertTrue(recognise(control).contains { $0.contains(email) })
            XCTAssertTrue(try apply(original, .redact(range: frozen.range, rect: region, mediaID: item.id, style: .blur, size: 90)))
            let scopes = RedactionSafety.protections(in: original.project)
            XCTAssertTrue(scopes.contains { $0.sources.contains { $0.contains(selected) } })
            // Bypass Editing to isolate rendering of a protected source in
            // a transition handle, without a mask over that handle.
            var p = original.project
            let movie = Clip(id: "clip_fast", content: .media(mediaID: item.id), start: t(1), duration: t(1), holdEdges: true, video: VideoProperties())
            let left = Clip(id: "clip_left", content: .solid(color: .white), start: .zero, duration: t(1))
            let right = Clip(id: "clip_right", content: .solid(color: .white), start: t(2), duration: t(1))
            p.videoTracks[0].clips = [left, movie, right, frozen]
            p.videoTracks[0].transitions = [Transition(type: .dissolve, duration: t(1), fromClipID: head ? left.id : movie.id, toClipID: head ? movie.id : right.id)]
            let c = ProjectCoordinator(project: p)
            let times = head ? [18.0 / 30, 23.0 / 30, 27.0 / 30] : [69.0 / 30]
            for time in times {
                let rendered = Bitmap(try await image(c, media, at: time))
                let darkest = (210..<260).map { y in (120..<600).map { rendered.luma($0, y) }.min()! }.min()!
                XCTAssertGreaterThan(darkest, 245, "a boundary hold must show its boundary frame, not a neighbouring private frame (\(fps) fps at \(time))")
            }
            try await panelCovered(c, media, at: times.last!, name: "panel-fast-\(head ? "head" : "tail")-\(fps)", encode: true)
        }
    }

    func testEmptyPoliciesCannotConcealAnImageOrAnUnknownFrameTable() async throws {
        for video in [false, true] {
            let (media, original) = try await fixture(video: video)
            XCTAssertTrue(try apply(original, .redact(range: TimeRange(start: .zero, end: t(3)), rect: region, mediaID: "med_dummy", style: .blur, size: 90)))
            var p = original.project
            p.videoTracks.removeAll(where: \.isPrivacy)
            for index in p.sourceRedactions!.indices { p.sourceRedactions![index].sources = [] }
            if video { p.media[0].variableFrameRate = true }
            let c = ProjectCoordinator(project: p)
            let frame = try await image(c, media)
            XCTAssertTrue(recognise(frame).contains { $0.contains(email) }, "an empty source selection must not produce a file-wide blur")
        }
    }
}
