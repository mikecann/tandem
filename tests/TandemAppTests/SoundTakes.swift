import AVFoundation
import CoreGraphics
import XCTest
@testable import TandemCore

/// Real media with sound, for the viewer's playback scenarios: a camera
/// take (a grey picture with a 500 Hz tone), music at 1 kHz and a sound
/// effect at 2.5 kHz, each at -20 dBFS and as long as asked. They become
/// three composition audio tracks, and each one's frequency shows which
/// track a sound came from.
struct SoundTakes {
    static let toneHz: [String: Double] = ["med_take": 500, "med_tune": 1_000, "med_ding": 2_500]
    let folder: URL
    let media: [MediaItem]

    static func write(in folder: URL, seconds: Double = 30) async throws -> SoundTakes {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await movie(folder.appendingPathComponent("take.mov"), seconds: seconds, hz: 500)
        try wav(folder.appendingPathComponent("tune.wav"), seconds: seconds, hz: 1_000)
        try wav(folder.appendingPathComponent("ding.wav"), seconds: seconds, hz: 2_500)
        let length = Time(seconds: seconds)
        return SoundTakes(folder: folder, media: [
            MediaItem(id: "med_take", path: "take.mov", kind: .video, role: .camera, duration: length, frameRate: .fps30,
                      width: 320, height: 180, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_tune", path: "tune.wav", kind: .audio, role: .music, duration: length, hasAudio: true),
            MediaItem(id: "med_ding", path: "ding.wav", kind: .audio, role: .sfx, duration: length, hasAudio: true)
        ])
    }

    /// Places all three from 0 for `seconds`.
    func build(seconds: Double = 30) -> [EditCommand] {
        media.map { .addMedia(item: $0) } + [
            .placeMedia(mediaIDs: ["med_take"], at: .zero, duration: Time(seconds: seconds)),
            .placeMedia(mediaIDs: ["med_tune"], at: .zero, duration: Time(seconds: seconds)),
            .placeMedia(mediaIDs: ["med_ding"], at: .zero, duration: Time(seconds: seconds))
        ]
    }

    static func tone(_ hz: Double) -> (Int) -> Float {
        let peak = pow(10, -20.0 / 20)
        return { i in Float(peak * sin(2 * Double.pi * hz * Double(i) / 48_000)) }
    }

    static func wav(_ url: URL, seconds: Double, hz: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let sample = tone(hz)
        for i in 0..<Int(frames) {
            let v = sample(i)
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        try file.write(from: buffer)
    }

    /// A 320x180 grey movie at 30 fps with a tone in AAC.
    static func movie(_ url: URL, seconds: Double, hz: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoMaxKeyFrameIntervalKey: 15]
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        XCTAssertTrue(writer.startWriting(), "\(writer.error as Any)")
        writer.startSession(atSourceTime: .zero)
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        let frame = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 0x60, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        var format: CMAudioFormatDescription?
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                      mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let frames = Int(seconds * 30), samples = Int(seconds * 48_000)
        final class Progress: @unchecked Sendable { var frame = 0, sample = 0 }
        let progress = Progress()
        let sound = tone(hz)
        let io = SendableBox((writer, video, adaptor, audio, frame, try XCTUnwrap(format)))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            group.enter()
            io.value.1.requestMediaDataWhenReady(on: DispatchQueue(label: "sound-takes.video")) {
                let (_, video, adaptor, _, frame, _) = io.value
                while video.isReadyForMoreMediaData {
                    if progress.frame >= frames { video.markAsFinished(); group.leave(); return }
                    adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(progress.frame), timescale: 30))
                    progress.frame += 1
                }
            }
            io.value.3.requestMediaDataWhenReady(on: DispatchQueue(label: "sound-takes.audio")) {
                let (_, _, _, audio, _, format) = io.value
                while audio.isReadyForMoreMediaData {
                    if progress.sample >= samples { audio.markAsFinished(); group.leave(); return }
                    let count = min(4_800, samples - progress.sample)
                    var interleaved = [Float](repeating: 0, count: count * 2)
                    for j in 0..<count { interleaved[2 * j] = sound(progress.sample + j); interleaved[2 * j + 1] = interleaved[2 * j] }
                    if let buffer = Self.buffer(interleaved, at: progress.sample, format: format) { audio.append(buffer) }
                    progress.sample += count
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(writer.error as Any)")
    }

    static func buffer(_ samples: [Float], at frame: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count / 2,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer
    }

    /// Amplitude of a sine at `hz` in samples holding whole cycles of it.
    static func amplitude(_ samples: ArraySlice<Float>, hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, x) in samples.enumerated() {
            let phase = 2 * Double.pi * hz * Double(i) / 48_000
            re += Double(x) * cos(phase)
            im += Double(x) * sin(phase)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(samples.count)
    }
}

/// Hands AVFoundation writers to their callback queues.
struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
