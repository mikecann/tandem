import AVFoundation
import CoreGraphics
import VideoToolbox
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// Synthetic media for end-to-end tests, written with AVAssetWriter into a
/// scratch folder that is removed afterwards.
final class TestMedia {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    var projectFolder: ProjectFolder { ProjectFolder(root: folder) }

    /// A movie at 30 fps, H.264 unless `codec` says otherwise. `draw` paints
    /// each frame (y down); `sound` gives the sample (both channels) at each
    /// sample index, or nil for no audio.
    @discardableResult
    func movie(
        _ name: String,
        seconds: Double,
        size: CGSize = CGSize(width: 320, height: 180),
        fps: Int32 = 30,
        codec: AVVideoCodecType = .h264,
        hlg: Bool = false,
        tenBit: Bool = true,
        attempt: Int = 1,
        draw: @escaping (Int, CGContext) -> Void,
        sound: ((Int) -> Float)? = nil
    ) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // With `hlg`, 10-bit HEVC in BT.2100 HLG, as an iPhone records HDR,
        // the drawn values taken as the HLG signal.
        var compression: [String: Any] = [AVVideoAverageBitRateKey: 20_000_000, AVVideoMaxKeyFrameIntervalKey: 10]
        if hlg { compression[AVVideoProfileLevelKey] = tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hlg ? .hevc : codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: hlg ? [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ] : [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(video)
        var audio: AVAssetWriterInput?
        if sound != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
        }
        XCTAssertTrue(writer.startWriting(), "\(writer.error as Any)")
        writer.startSession(atSourceTime: .zero)

        let frames = Int((seconds * Double(fps)).rounded())
        let totalSamples = Int(seconds * 48_000)
        let format = try AudioBuffers.formatDescription()
        final class Progress: @unchecked Sendable {
            var frame = 0
            var sample = 0
        }
        let progress = Progress()
        let io = Unchecked((writer: writer, video: video, adaptor: adaptor, audio: audio))
        // Each input pulls on its own queue: the writer interleaves, and
        // pushing one input far ahead of the other stalls it.
        let written = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let group = DispatchGroup()
            group.enter()
            io.value.video.requestMediaDataWhenReady(on: DispatchQueue(label: "test.video")) {
                let (writer, video, adaptor, _) = io.value
                while video.isReadyForMoreMediaData {
                    if progress.frame >= frames || writer.status == .failed {
                        video.markAsFinished()
                        group.leave()
                        return
                    }
                    // Our own buffer, not the adaptor's pool: a writer that
                    // fails under load tears its pool down while this block
                    // can still be using it (a crash in CVPixelBufferPool).
                    // Failing here ends the video, and the assertion below
                    // reports the writer's error.
                    var buffer: CVPixelBuffer?
                    CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
                    guard let buffer else {
                        video.markAsFinished()
                        group.leave()
                        return
                    }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let context = CGContext(
                        data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                    )!
                    // Flip so drawing code can think y down.
                    context.translateBy(x: 0, y: size.height)
                    context.scaleBy(x: 1, y: -1)
                    draw(progress.frame, context)
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    // Tag the frame as BT.709 so the encoder converts it
                    // straight to YCbCr instead of colour matching it.
                    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, hlg ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, hlg ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(progress.frame), timescale: fps))
                    progress.frame += 1
                }
            }
            if let sound, let input = io.value.audio {
                group.enter()
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "test.audio")) {
                    let (writer, _, _, audio) = io.value
                    guard let audio else { return }
                    while audio.isReadyForMoreMediaData {
                        if progress.sample >= totalSamples || writer.status == .failed {
                            audio.markAsFinished()
                            group.leave()
                            return
                        }
                        let count = min(4_800, totalSamples - progress.sample)
                        var samples = [Float](repeating: 0, count: count * 2)
                        for j in 0..<count {
                            let v = sound(progress.sample + j)
                            samples[2 * j] = v
                            samples[2 * j + 1] = v
                        }
                        if let buffer = try? AudioBuffers.sampleBuffer(samples, at: CMTime(value: CMTimeValue(progress.sample), timescale: 48_000), format: format) {
                            audio.append(buffer)
                        }
                        progress.sample += count
                    }
                }
            }
            DispatchQueue.global().async { done.resume(returning: group.wait(timeout: .now() + 60) == .success) }
        }
        guard written else { throw MediaError.failed("writing \(name) stalled") }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        try await writer.finishWriting(within: 60)
        // The 10-bit HEVC encoder fails now and then (-12902) on a busy
        // machine; another go writes it.
        if hlg, writer.status != .completed, attempt < 3 {
            try? FileManager.default.removeItem(at: url)
            return try await movie(name, seconds: seconds, size: size, fps: fps, codec: codec, hlg: hlg, tenBit: tenBit, attempt: attempt + 1, draw: draw, sound: sound)
        }
        XCTAssertEqual(writer.status, .completed, "\(writer.error as Any)")
        return url
    }

    /// Eight stripes across the frame spell the frame index in binary,
    /// so a grab shows exactly which source frame it came from.
    static func drawIndex(_ index: Int, _ context: CGContext, size: CGSize = CGSize(width: 320, height: 180)) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let stripe = size.width / 8
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for bit in 0..<8 where index & (1 << bit) != 0 {
            context.fill(CGRect(x: CGFloat(bit) * stripe, y: 0, width: stripe, height: size.height))
        }
    }

    /// Reads the index drawn by `drawIndex` from a region of a frame.
    static func readIndex(_ bitmap: Bitmap, in rect: CGRect) -> Int {
        var index = 0
        let stripe = rect.width / 8
        for bit in 0..<8 {
            let x = Int(rect.minX + stripe * (CGFloat(bit) + 0.5))
            if bitmap.luma(x, Int(rect.midY)) > 128 { index |= 1 << bit }
        }
        return index
    }

    static func fill(_ context: CGContext, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: CGSize = CGSize(width: 320, height: 180)) {
        context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
    }

    func item(_ id: String, _ name: String, role: MediaRole = .other, seconds: Double, audio: Bool = false) -> MediaItem {
        MediaItem(
            id: id, path: name, kind: .video, role: role, duration: Time(seconds: seconds),
            frameRate: .fps30, width: 320, height: 180, hasVideo: true, hasAudio: audio
        )
    }
}

/// Decoded audio of a file, as interleaved stereo float at 48 kHz.
func decodeAudio(_ url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: AudioBuffers.readerSettings)
    reader.add(output)
    reader.startReading()
    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        samples += AudioBuffers.samples(in: buffer)
    }
    return samples
}

extension AVAssetWriter {
    /// Waits for `input` to take more, throwing rather than polling
    /// forever if the writer fails or stalls.
    func ready(_ input: AVAssetWriterInput, timeout: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !input.isReadyForMoreMediaData {
            if status == .failed { throw error ?? MediaError.failed("the writer failed") }
            guard Date() < deadline else { throw MediaError.failed("the writer wasn't ready for more within \(Int(timeout)) s") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// `finishWriting()`, throwing rather than waiting forever if the
    /// writer never says it's done.
    func finishWriting(within timeout: Double) async throws {
        let finished = DispatchSemaphore(value: 0)
        finishWriting { finished.signal() }
        let done = await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { resume.resume(returning: finished.wait(timeout: .now() + timeout) == .success) }
        }
        guard done else { throw MediaError.failed("the writer didn't finish within \(Int(timeout)) s") }
    }
}
