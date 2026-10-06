import AVFoundation
import CoreImage
import XCTest
import TandemCore
@testable import TandemMedia
@testable import TandemRender

/// Stickers and overlays with alpha (HEVC with alpha, ProRes 4444) keep
/// their transparency through the compositor, and through the scrub
/// proxies the viewer plays.
final class AlphaVideoTests: XCTestCase {
    func testHEVCWithAlphaOverlaysTheTrackBelow() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 1, draw: { TestMedia.fill($1, 1, 0, 0) })
        // HEVC with alpha: left half opaque blue, right half transparent.
        let url = media.folder.appendingPathComponent("sticker.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pb!)
            for y in 0..<180 { for x in 0..<320 { let o = y * row + x * 4
                if x < 160 { base[o] = 255; base[o+1] = 0; base[o+2] = 0; base[o+3] = 255 } else { base[o] = 0; base[o+1] = 0; base[o+2] = 0; base[o+3] = 0 } } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30)); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(writer.error as Any)")
        var sticker = media.item("med_k", "sticker.mov", role: .sticker, seconds: 1)
        sticker.hasAlpha = true
        let project = smallProject(video: [
            Track(kind: .video, name: "V1", clips: [Clip(id: "clip_r", content: .media(mediaID: "med_r"), start: .zero, duration: t(1))]),
            Track(kind: .video, name: "V2", clips: [Clip(id: "clip_k", content: .media(mediaID: "med_k"), start: .zero, duration: t(1))])
        ], media: [media.item("med_r", "red.mov", seconds: 1), sticker])
        let frame = Bitmap(try await FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder)).image(at: t(0.5)))
        assertColor(frame[80, 90], [0, 0, 255], tolerance: 16)
        assertColor(frame[240, 90], [255, 0, 0], tolerance: 8)
    }

    /// An overlay bigger than 1080p on the timeline gets a scrub proxy, and
    /// the viewer plays from it: the track below has to show through the
    /// proxy as it does through the original (exports, paused frames).
    /// ProRes 4444 and a QuickTime Animation sticker (by way of its
    /// converted copy) have straight alpha, HEVC with alpha from
    /// AVAssetWriter premultiplied.
    func testTheTrackBelowShowsThroughTheProxyOfABigOverlay() async throws {
        for codec in ["prores", "hevc", "qtrle"] {
            let media = try TestMedia()
            try await media.movie("blue.mov", seconds: 0.5, draw: { TestMedia.fill($1, 0, 0, 1) })
            let url = try await media.alphaOverlay("overlay.mov", codec: codec, width: 2400, height: 1350, seconds: 0.5)
            let overlay = try await MediaScanner.probe(url, folder: media.projectFolder, id: "med_over")
            XCTAssertTrue(overlay.hasAlpha, codec)
            let project = smallProject(video: [
                Track(kind: .video, name: "V1", clips: [Clip(id: "clip_bg", content: .media(mediaID: "med_bg"), start: .zero, duration: t(0.5))]),
                Track(kind: .video, name: "V2", clips: [Clip(id: "clip_over", content: .media(mediaID: "med_over"), start: .zero, duration: t(0.5))])
            ], media: [media.item("med_bg", "blue.mov", seconds: 0.5), overlay])
            XCTAssertTrue(AnalysisNeeds.needs(for: project).contains { $0.mediaID == "med_over" && $0.kind == .proxy }, "bigger than 1080p, \(codec)")
            let analysis = MediaAnalysis(folder: media.projectFolder, encoderLock: EncoderLock())
            let state = await analysis.waitFor(.proxy, for: overlay)
            XCTAssertEqual(state, .ready, codec)
            XCTAssertNotNil(analysis.proxyURL(for: overlay), codec)

            for useProxies in [false, true] {
                let what = "\(codec) \(useProxies ? "proxy" : "original")"
                let context = RenderContext(project: project, folder: media.projectFolder, analysis: analysis, useProxies: useProxies)
                let frame = Bitmap(try await FrameRenderer(context: context).image(at: t(0.25)))
                assertColor(frame[53, 90], [255, 255, 255], tolerance: 12, what)
                assertColor(frame[160, 90], [128, 128, 255], tolerance: 16, "half alpha over blue, \(what)")
                assertColor(frame[266, 90], [0, 0, 255], tolerance: 12, "the track below shows through, \(what)")
            }
            // The viewer's player, whose compositor writes 4:2:0.
            let playing = try await playerFrame(RenderContext(project: project, folder: media.projectFolder, analysis: analysis, useProxies: true), at: t(0.25))
            assertColor(playing[53, 90], [255, 255, 255], tolerance: 12, "\(codec) playing")
            assertColor(playing[160, 90], [128, 128, 255], tolerance: 16, "half alpha over blue, \(codec) playing")
            assertColor(playing[266, 90], [0, 0, 255], tolerance: 12, "the track below shows through, \(codec) playing")
        }
    }

    /// Every proxy is 1080p HEVC, so an overlay's proxy (HEVC with alpha)
    /// can follow a camera's (plain HEVC) on one composition track.
    /// AVFoundation keeps a track's decoder while the codec and size stay
    /// the same, and the plain decoder drops the alpha: the overlay played
    /// black over the track below, and `tandem check` found its clear
    /// frames black (issue #10).
    func testAnOverlaysProxyAfterAPlainProxyStillShowsTheTrackBelow() async throws {
        let media = try TestMedia()
        try await media.movie("blue.mov", seconds: 1, draw: { TestMedia.fill($1, 0, 0, 1) })
        let big = CGSize(width: 2400, height: 1350)
        let cameraURL = try await media.movie("camera.mov", seconds: 0.5, size: big, draw: { TestMedia.fill($1, 1, 0, 0, size: big) })
        // Clear for its first six frames, as a motion graphic often starts.
        let overlayURL = try await media.alphaOverlay("overlay.mov", codec: "hevc", width: 2400, height: 1350, seconds: 0.5, clearFrames: 6)
        let camera = try await MediaScanner.probe(cameraURL, folder: media.projectFolder, id: "med_cam")
        let overlay = try await MediaScanner.probe(overlayURL, folder: media.projectFolder, id: "med_over")
        let project = smallProject(video: [
            Track(kind: .video, name: "V1", clips: [Clip(id: "clip_bg", content: .media(mediaID: "med_bg"), start: .zero, duration: t(1))]),
            Track(kind: .video, name: "V2", clips: [
                Clip(id: "clip_cam", content: .media(mediaID: "med_cam"), start: .zero, duration: t(0.5)),
                Clip(id: "clip_over", content: .media(mediaID: "med_over"), start: t(0.5), duration: t(0.5))
            ])
        ], media: [media.item("med_bg", "blue.mov", seconds: 1), camera, overlay])
        let analysis = MediaAnalysis(folder: media.projectFolder, encoderLock: EncoderLock())
        for item in [camera, overlay] {
            let state = await analysis.waitFor(.proxy, for: item)
            XCTAssertEqual(state, .ready, item.path)
        }
        let context = RenderContext(project: project, folder: media.projectFolder, analysis: analysis, useProxies: true)

        // The check reads the proxies.
        let frames = try await FrameScanner.scan(context, ranges: [TimeRange(start: t(0.5), end: t(1))], width: 192)
        XCTAssertEqual(frames.count, 15)
        let black = frames.filter(\.isBlack).map { String(format: "%.3f", $0.time.seconds) }
        XCTAssertEqual(black, [], "frames the check finds black")

        // So does the viewer while it plays.
        let clear = try await playerFrame(context, at: t(0.6))
        assertColor(clear[160, 90], [0, 0, 255], tolerance: 12, "the track below through a clear frame, playing")
        let drawn = try await playerFrame(context, at: t(0.9))
        assertColor(drawn[53, 90], [255, 255, 255], tolerance: 12, "the overlay, playing")
        assertColor(drawn[266, 90], [0, 0, 255], tolerance: 12, "the track below beside it, playing")
    }

    /// The same from the originals, read as an export reads them: HEVC with
    /// alpha after plain HEVC of the same size on one composition track
    /// came out black where it's clear. (A frame grab decoded it right.)
    func testAnHEVCOverlayAfterPlainHEVCOfTheSameSizeShowsTheTrackBelow() async throws {
        let media = try TestMedia()
        try await media.movie("blue.mov", seconds: 1, draw: { TestMedia.fill($1, 0, 0, 1) })
        try await media.movie("camera.mov", seconds: 0.5, codec: .hevc, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.alphaOverlay("overlay.mov", codec: "hevc", width: 320, height: 180, seconds: 0.5, clearFrames: 6)
        var overlay = media.item("med_over", "overlay.mov", role: .graphic, seconds: 0.5)
        overlay.hasAlpha = true
        let project = smallProject(video: [
            Track(kind: .video, name: "V1", clips: [Clip(id: "clip_bg", content: .media(mediaID: "med_bg"), start: .zero, duration: t(1))]),
            Track(kind: .video, name: "V2", clips: [
                Clip(id: "clip_cam", content: .media(mediaID: "med_cam"), start: .zero, duration: t(0.5)),
                Clip(id: "clip_over", content: .media(mediaID: "med_over"), start: t(0.5), duration: t(0.5))
            ])
        ], media: [media.item("med_bg", "blue.mov", seconds: 1), media.item("med_cam", "camera.mov", seconds: 0.5), overlay])
        let context = RenderContext(project: project, folder: media.projectFolder)

        let frames = try await FrameScanner.scan(context, ranges: [TimeRange(start: t(0.5), end: t(1))], width: 192)
        XCTAssertEqual(frames.count, 15)
        XCTAssertEqual(frames.filter(\.isBlack).map { String(format: "%.3f", $0.time.seconds) }, [], "frames read as an export reads them")
    }

    /// The frame a paused player shows at `time`, built as the viewer
    /// builds it.
    func playerFrame(_ context: RenderContext, at time: Time) async throws -> Bitmap {
        let built = try await CompositionBuilder.build(context)
        let item = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil) }
        await player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if output.hasNewPixelBuffer(forItemTime: time.cmTime), let pixels = output.copyPixelBuffer(forItemTime: time.cmTime, itemTimeForDisplay: nil) {
                return Bitmap(CIImage(cvPixelBuffer: pixels), size: built.renderSize)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return try XCTUnwrap(nil, "the player showed nothing at \(time.seconds) s")
    }
}

extension TestMedia {
    /// Half a second or so of overlay with alpha at 30 fps: the left third
    /// opaque white, the middle third white at half alpha, the right third
    /// clear. White, so it looks the same whichever YCbCr matrix a decoder
    /// guesses for these untagged files. `prores` (ProRes 4444) and `qtrle`
    /// (QuickTime Animation, which macOS can't decode) come from ffmpeg
    /// with straight alpha; `hevc` (HEVC with alpha) from AVAssetWriter,
    /// premultiplied. The first `clearFrames` frames are clear all over.
    /// Skips the test when ffmpeg isn't installed.
    func alphaOverlay(_ name: String, codec: String, width: Int, height: Int, seconds: Double, clearFrames: Int = 0) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        guard codec != "hevc" else {
            try await writeHEVCWithAlpha(to: url, width: width, height: height, frames: Int(seconds * 30), clearFrames: clearFrames)
            return url
        }
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let encoder = codec == "qtrle"
            ? ["-c:v", "qtrle", "-pix_fmt", "argb"]
            : ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-alpha_bits", "16"]
        try ffmpeg.run([
            "-y", "-v", "error", "-f", "lavfi",
            "-i", "color=c=white:s=\(width)x\(height):d=\(seconds):r=30,format=rgba,geq=r='255':g='255':b='255':a='if(lt(N,\(clearFrames)),0,if(lt(X,W/3),255,if(lt(X,2*W/3),128,0)))'"
        ] + encoder + [url.path])
        return url
    }

    private func writeHEVCWithAlpha(to url: URL, width: Int, height: Int, frames: Int, clearFrames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(writer.error as Any)")
        writer.startSession(atSourceTime: .zero)
        // One premultiplied BGRA row, copied down every frame.
        let clearRow = [UInt8](repeating: 0, count: width * 4)
        var drawnRow = clearRow
        for x in 0..<(2 * width / 3) {
            let value: UInt8 = x < width / 3 ? 255 : 128
            for c in 0..<4 { drawnRow[x * 4 + c] = value }
        }
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &created)
            let buffer = try XCTUnwrap(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            (i < clearFrames ? clearRow : drawnRow).withUnsafeBytes { bytes in
                for y in 0..<height { (base + y * stride).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(writer.error as Any)")
    }
}
