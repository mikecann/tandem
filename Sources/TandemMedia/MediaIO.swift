import AVFoundation
import CoreMedia
import Foundation
import TandemCore

/// Runs blocking work (reader loops, Vision, encoders) on a GCD queue so it
/// never ties up Swift's cooperative threads.
enum Blocking {
    static func run<T>(qos: DispatchQoS.QoSClass = .utility, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

extension Time {
    /// Snapped to the 48 kHz grid like every stored Time, so values survive
    /// a JSON round trip unchanged.
    init(_ time: CMTime) {
        self.init(seconds: time.seconds)
    }
}

extension CMTime {
    init(_ time: Time) {
        self = CMTime(value: time.flicks, timescale: CMTimeScale(Time.flicksPerSecond))
    }
}

/// JSON for cache files: sorted keys, and loudness of silence (-infinity)
/// kept as a string instead of failing to encode.
enum CacheJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

/// A size that fits inside a box, keeping the aspect ratio, never larger
/// than the source, with even sides for the video encoders. Portrait sources
/// use the box turned on its side.
func fittedSize(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0 else { return (2, 2) }
    let (boxWidth, boxHeight) = height > width ? (maxHeight, maxWidth) : (maxWidth, maxHeight)
    let scale = min(1, Double(boxWidth) / Double(width), Double(boxHeight) / Double(height))
    func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
    return (even(Double(width) * scale), even(Double(height) * scale))
}

/// Reads an asset's first audio track as interleaved 32-bit float PCM, in
/// chunks, with each chunk's position in media time.
///
/// AVAssetReader decodes at the file's own rate and Tandem resamples
/// (`Resampler`), because AVAssetReader's own rate conversion slips on
/// movies: asked for 8 kHz from a camera's 48 kHz sound interleaved with its
/// picture, it now and then gives a packet's worth of samples twice and
/// stamps the chunks by its own count, so the sound runs about 100 ppm late.
/// On the Databased S2E7 Restream recording (November 2026) that was 0.33 s
/// by the end of the hour, and sync by sound placed a guest's mic 151 ms out.
/// Audio-only files and reads at the file's own rate don't slip.
final class AudioReader: @unchecked Sendable {
    let sampleRate: Double
    let channels: Int
    /// Seconds of media to read: the asset's, or the time range's.
    let duration: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    /// Reading and cancelling can come from different threads, and
    /// AVAssetReader crashes if it's cancelled mid-copy, so they take turns.
    private let access = NSRecursiveLock()
    private var cancelled = false
    /// Turns the file's rate into `sampleRate`, when they differ.
    private let resampler: Resampler?

    /// - Parameters:
    ///   - sampleRate: resample to this rate; nil keeps the file's.
    ///   - channels: mix to this many channels; nil keeps the file's.
    ///   - timeRange: read only part of the file.
    init(url: URL, sampleRate: Double? = nil, channels: Int? = nil, timeRange: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (tracks, duration) = try await asset.load(.tracks, .duration)
        guard let track = tracks.first(where: { $0.mediaType == .audio }) else {
            throw MediaError.notApplicable("\(url.lastPathComponent) has no audio")
        }
        let formats = try await track.load(.formatDescriptions)
        let native = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = sampleRate ?? native.map { Double($0.mSampleRate) } ?? 48_000
        let count = channels ?? Int(native?.mChannelsPerFrame ?? 2)
        self.sampleRate = rate
        self.channels = max(1, count)
        self.duration = timeRange.map { $0.duration.seconds } ?? duration.seconds
        let nativeRate = native.map { Double($0.mSampleRate) } ?? rate
        if nativeRate != rate, nativeRate > 0 {
            // No falling back to AVAssetReader's own conversion, which slips.
            guard let resampler = Resampler(from: nativeRate, to: rate, channels: self.channels) else {
                throw MediaError.failed("Can't resample the audio of \(url.lastPathComponent) from \(Int(nativeRate)) Hz to \(Int(rate)) Hz with \(self.channels) channels")
            }
            self.resampler = resampler
        } else {
            resampler = nil
        }

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            // The file's own rate when Tandem resamples (see above).
            AVSampleRateKey: resampler == nil ? rate : nativeRate,
            AVNumberOfChannelsKey: self.channels
        ]
        // Changing the channel count needs a layout to mix to.
        if let layout = Self.layout(for: self.channels), channels != nil {
            settings[AVChannelLayoutKey] = layout
        }
        reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.failed("Can't read the audio of \(url.lastPathComponent)") }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.unreadable(url.lastPathComponent, reader.error?.localizedDescription ?? "the audio can't be decoded")
        }
    }

    private static func layout(for channels: Int) -> Data? {
        let tag: AudioChannelLayoutTag
        switch channels {
        case 1: tag = kAudioChannelLayoutTag_Mono
        case 2: tag = kAudioChannelLayoutTag_Stereo
        default: return nil
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// Calls `body` with the next chunk of samples (`frames * channels`
    /// values) and its start in media time, or returns false at the end.
    func next(_ body: (UnsafeBufferPointer<Float>, _ frames: Int, _ start: CMTime) throws -> Void) throws -> Bool {
        access.lock()
        defer { access.unlock() }
        guard !cancelled else { return false }
        guard let resampler else { return try nextDecoded(body) }
        if let chunk = resampler.pending.popFirst() {
            try chunk.samples.withUnsafeBufferPointer { try body($0, chunk.samples.count / channels, chunk.start) }
            return true
        }
        let more = try nextDecoded { samples, frames, start in try resampler.add(samples, frames: frames, at: start) }
        if !more { try resampler.finish() }
        guard !resampler.pending.isEmpty else { return more }
        if let chunk = resampler.pending.popFirst() {
            try chunk.samples.withUnsafeBufferPointer { try body($0, chunk.samples.count / channels, chunk.start) }
        }
        return true
    }

    /// The next chunk as AVAssetReader decodes it.
    private func nextDecoded(_ body: (UnsafeBufferPointer<Float>, _ frames: Int, _ start: CMTime) throws -> Void) throws -> Bool {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw MediaError.failed("Audio decoding failed: \(reader.error?.localizedDescription ?? "unknown error")")
            }
            return false
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return true }
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        var contiguous = block
        if !CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) {
            var copy: CMBlockBuffer?
            CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: block, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &copy)
            guard let copy else { return true }
            contiguous = copy
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return true }
        let values = min(frames * channels, length / MemoryLayout<Float>.size)
        try pointer.withMemoryRebound(to: Float.self, capacity: values) { floats in
            try body(UnsafeBufferPointer(start: floats, count: values), values / channels, start)
        }
        return true
    }

    func cancel() {
        access.lock()
        defer { access.unlock() }
        guard !cancelled else { return }
        cancelled = true
        reader.cancelReading()
    }
}

/// Resamples an AudioReader's chunks as they come, with AVAudioConverter,
/// which keeps exact count over a continuous stream. Chunks are stamped from
/// where the stream started plus the samples given out since, and a jump in
/// the file's own stamps (a gap in the sound) starts the count again there.
private final class Resampler {
    let inputRate: Double
    let outputRate: Double
    let channels: Int
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter
    /// Where the current run of continuous sound started, and how many
    /// samples it has given out since.
    private var anchor: CMTime?
    private var given: Int64 = 0
    /// Where the next decoded chunk should start if the sound is continuous.
    private var expected: CMTime?
    private var finished = false
    var pending: ArraySlice<(samples: [Float], start: CMTime)> = []

    init?(from inputRate: Double, to outputRate: Double, channels: Int) {
        // Over two channels a format needs a layout; discrete channels in
        // order keep them as they are.
        guard channels > 0, let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)) else { return nil }
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, interleaved: true, channelLayout: layout)
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, interleaved: true, channelLayout: layout)
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        // The default prime method treats what came before the first sample
        // as silence, so the output lines up with the input sample for sample.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.channels = channels
        self.input = input
        self.output = output
        self.converter = converter
    }

    func add(_ samples: UnsafeBufferPointer<Float>, frames: Int, at start: CMTime) throws {
        guard frames > 0 else { return }
        // Over 5 ms out is a gap in the sound (an AAC packet is 21 ms), not
        // a stamp rounded to its track's timescale.
        if let expected, abs((start - expected).seconds) > 0.005 {
            try endRun()
            converter.reset()
            anchor = nil
        }
        if anchor == nil {
            anchor = start
            given = 0
        }
        expected = start + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(inputRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)) else {
            throw MediaError.failed("Out of memory resampling the audio")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData![0].update(from: samples.baseAddress!, count: frames * channels)
        try convert(buffer)
    }

    /// The last of the sound the converter held back for its filter.
    func finish() throws {
        guard !finished else { return }
        finished = true
        try endRun()
    }

    private func endRun() throws {
        if anchor != nil { try convert(nil) }
    }

    /// Gives `buffer` to the converter (nil: the end of this run) and
    /// queues what comes out.
    private func convert(_ buffer: AVAudioPCMBuffer?) throws {
        let frames = Double(buffer?.frameLength ?? 0)
        let capacity = AVAudioFrameCount((frames * outputRate / inputRate).rounded(.up)) + 1024
        nonisolated(unsafe) var handed = false
        while true {
            guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity), let anchor else { return }
            var error: NSError?
            let status = converter.convert(to: target, error: &error) { _, state in
                if let buffer, !handed {
                    handed = true
                    state.pointee = .haveData
                    return buffer
                }
                state.pointee = buffer == nil ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error { throw MediaError.failed("Couldn't resample the audio: \(error?.localizedDescription ?? "unknown error")") }
            let made = Int(target.frameLength)
            if made > 0 {
                let start = anchor + CMTime(value: CMTimeValue(given), timescale: CMTimeScale(outputRate))
                pending.append((Array(UnsafeBufferPointer(start: target.floatChannelData![0], count: made * channels)), start))
                given += Int64(made)
            }
            // A full buffer may have left more inside; anything else means
            // it wants more input or has finished.
            guard status == .haveData else { return }
        }
    }
}
