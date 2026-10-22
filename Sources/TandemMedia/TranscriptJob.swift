import Accelerate
import AVFoundation
import Foundation
import Speech
import TandemCore

/// Word-level transcript, word times in media time. Bark 3.0 Pro makes it
/// (`BarkTranscription`) unless the settings say SpeechAnalyzer or the
/// locale isn't English. When Bark's model isn't here yet (in the app it
/// downloads in the background; a `tandem` command waits for it), fails its
/// check or throws, SpeechAnalyzer (macOS 26)
/// makes it instead and the job says so: its status keeps a "Made with
/// SpeechAnalyzer" line, and `TranscriptFallback` gets the transcript made
/// again with Bark once the model changes. Either engine streams the audio
/// from the file, so a long take never sits in memory.
///
/// The cache keeps the engine's own word times. SpeechAnalyzer's run end
/// to end and swallow the pauses; `TranscriptAlignment` pulls them in to the
/// voice when the transcript is read, so transcripts made before it existed
/// get it too.
enum TranscriptJob {
    static let file = "transcript.json"

    static func run(source: URL, settings: AnalysisSettings, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil, barkStore: BarkModelStore = .standard) async throws {
        var fellBack: String?
        if settings.transcriptEngine == .bark {
            if settings.usesBark {
                do {
                    let transcript = try await bark(source: source, context: context, timeRange: timeRange, store: barkStore)
                    try CacheJSON.write(transcript, to: folder.appendingPathComponent(file))
                    return
                } catch let unavailable as BarkTranscription.Unavailable {
                    // Not silently: the job's status keeps this line, and the
                    // fallback file gets the transcript made again with Bark
                    // once the model changes (see MediaAnalysis).
                    fellBack = unavailable.reason
                    context.note("Made with SpeechAnalyzer: \(unavailable.reason)")
                    try TranscriptFallback(reason: unavailable.reason, model: barkStore.stamp()).write(to: folder)
                }
            } else {
                context.note("Made with SpeechAnalyzer: Bark 3.0 Pro is English only, and the transcript locale is \(settings.transcriptLocale)")
            }
        }
        guard #available(macOS 26, *) else {
            throw MediaError.notApplicable("Transcripts need macOS 26 (SpeechAnalyzer)" + (fellBack.map { " when \(BarkTranscription.engine) can't: \($0)" } ?? ""))
        }
        let transcript = try await SpeechTranscription.transcribe(source: source, localeID: settings.transcriptLocale, context: context, timeRange: timeRange)
        try CacheJSON.write(transcript, to: folder.appendingPathComponent(file))
    }

    /// Bark's transcript, or `Unavailable` saying why SpeechAnalyzer should
    /// make it. A model that isn't ready starts getting ready in the
    /// background rather than holding the job up for a 1.23 GB download,
    /// unless the store waits for it (`tandem` commands, which would end the
    /// download when they exit): then the job shows the download's progress
    /// and goes on with Bark once it's ready.
    static func bark(source: URL, context: JobContext, timeRange: CMTimeRange?, store: BarkModelStore) async throws -> Transcript {
        guard let models = try await readyModel(store, context: context) else {
            let state = await BarkModelPreparer.shared.state(of: store)
            if state.running {
                throw BarkTranscription.Unavailable(reason: "\(BarkTranscription.engine) is downloading (\(Int((state.progress * 100).rounded()))%)")
            }
            throw BarkTranscription.Unavailable(reason: "\(BarkTranscription.engine) isn't downloaded" + (state.failure.map { " (\($0))" } ?? ""))
        }
        do {
            return try await BarkTranscription.transcribe(source: source, context: context, timeRange: timeRange, models: models,
                                                          vocabulary: store.folder.appendingPathComponent(BarkModelStore.vocabulary))
        } catch let error where !(error is CancellationError) && !context.isCancelled {
            if case MediaError.fileChanged = error { throw error }
            throw BarkTranscription.Unavailable(reason: "\(BarkTranscription.engine) failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    /// The compiled model, starting its download when it isn't here, and
    /// waiting for that when the store says to. Nil when it isn't ready.
    static func readyModel(_ store: BarkModelStore, context: JobContext) async throws -> URL? {
        if let models = store.readyFolder() { return models }
        guard store.autoPrepare else { return nil }
        await BarkModelPreparer.shared.start(store)
        guard store.waitsForModel else { return nil }
        var state = await BarkModelPreparer.shared.state(of: store)
        while state.running {
            // The job's progress is the download's for now; the line says so.
            context.progress(state.progress, message: "\(state.message) (\(String(format: "%.2f", Double(store.totalBytes) / 1e9)) GB, once only), then transcribing")
            try context.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
            state = await BarkModelPreparer.shared.state(of: store)
        }
        return store.readyFolder()
    }

    static func read(from folder: URL) -> Transcript? {
        CacheJSON.read(Transcript.self, from: folder.appendingPathComponent(file))
    }
}

/// Written next to a transcript SpeechAnalyzer made because Bark couldn't,
/// with the state Bark's model was in. Once that changes (the model arrived,
/// or was made ready again), `MediaAnalysis` makes the transcript again
/// once, like `MatteFallback`.
struct TranscriptFallback: Codable, Equatable {
    static let file = "fallback.json"
    var reason: String
    /// `BarkModelStore.stamp()` when it fell back.
    var model: String

    static func read(from folder: URL) -> TranscriptFallback? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(TranscriptFallback.self, from: data)
    }

    func write(to folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent(Self.file))
    }
}

@available(macOS 26, *)
enum SpeechTranscription {
    static let engine = "SpeechAnalyzer"

    static func transcribe(source: URL, localeID: String, context: JobContext, timeRange: CMTimeRange?) async throws -> Transcript {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw MediaError.notApplicable("SpeechAnalyzer doesn't support \(localeID)")
        }
        let status = await AssetInventory.status(forModules: [makeTranscriber(locale)])
        guard status != .unsupported else { throw MediaError.notApplicable("SpeechAnalyzer can't transcribe \(localeID) on this Mac") }
        do {
            return try await attempt(source: source, locale: locale, context: context, timeRange: timeRange)
        } catch let error where status < .installed && !context.isCancelled && !(error is CancellationError) {
            // The model usually works even when the inventory only says
            // "supported"; if it didn't, install it and try once more.
            let transcriber = makeTranscriber(locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                context.progress(0, message: "Installing the \(locale.identifier) speech model")
                try await request.downloadAndInstall()
            }
            return try await attempt(source: source, locale: locale, context: context, timeRange: timeRange)
        }
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    static func attempt(source: URL, locale: Locale, context: JobContext, timeRange: CMTimeRange?) async throws -> Transcript {
        let transcriber = makeTranscriber(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MediaError.failed("SpeechAnalyzer has no audio format for \(locale.identifier)")
        }
        let reader = try await AudioReader(url: source, sampleRate: format.sampleRate, channels: Int(format.channelCount), timeRange: timeRange)
        let start = timeRange?.start.seconds ?? 0
        let feed = try AnalyzerFeed(reader: reader, format: format, context: context, origin: start)
        let duration = reader.duration

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .lingering))
        let collector = Task { () -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in transcriber.results where result.isFinal {
                words += Self.words(in: result.text)
                let end = result.range.end.seconds
                if end.isFinite, duration > 0 { context.progress((end - start) / duration) }
            }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(AnalyzerInputs(feed: feed)) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            reader.cancel()
            throw error
        }
        let words = try await collector.value
        try context.checkCancellation()
        return Transcript(language: locale.identifier(.bcp47), engine: engine, words: words)
    }

    /// One word per run with a time range; runs carry their leading space.
    static func words(in text: AttributedString) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, range.start.isNumeric, range.end.isNumeric else { continue }
            words.append(TranscriptWord(
                text: word,
                start: Time(range.start),
                end: Time(range.end),
                confidence: run.transcriptionConfidence
            ))
        }
        return words
    }
}

/// Pulls audio from the reader a second at a time, converted to the
/// analyzer's format, each buffer stamped with its media time.
@available(macOS 26, *)
final class AnalyzerFeed: @unchecked Sendable {
    let reader: AudioReader
    let format: AVAudioFormat
    let context: JobContext
    private let chunkFrames: Int
    private var pending: [Float] = []
    private var pendingStart: CMTime?
    private var finished = false
    /// Media time the audio should start at (0, or a range's start).
    private let origin: Double

    init(reader: AudioReader, format: AVAudioFormat, context: JobContext, origin: Double) throws {
        guard format.channelCount == AVAudioChannelCount(reader.channels) else {
            throw MediaError.failed("Speech audio format mismatch")
        }
        self.reader = reader
        self.format = format
        self.context = context
        chunkFrames = Int(format.sampleRate)
        self.origin = origin
    }

    func next() throws -> AnalyzerInput? {
        if context.isCancelled {
            reader.cancel()
            return nil
        }
        while !finished, pending.count < chunkFrames * reader.channels {
            let more = try reader.next { samples, frames, start in
                // Samples stamped before the start (encoder priming) are
                // dropped so word times stay in media time.
                let early = Int(((origin - start.seconds) * reader.sampleRate).rounded())
                let dropped = min(frames, max(0, early))
                guard dropped < frames else { return }
                let kept = UnsafeBufferPointer(rebasing: samples[(dropped * reader.channels)...])
                let keptStart = dropped > 0 ? CMTime(seconds: origin, preferredTimescale: CMTimeScale(reader.sampleRate)) : start
                if pendingStart == nil || pending.isEmpty { pendingStart = keptStart }
                pending.append(contentsOf: kept)
            }
            if !more { finished = true }
        }
        guard !pending.isEmpty, let start = pendingStart else { return nil }
        let take = min(pending.count, chunkFrames * reader.channels)
        let frames = take / reader.channels
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw MediaError.failed("Out of memory for speech audio")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try pending.withUnsafeBufferPointer { samples in
            try PCMFill.fill(buffer, from: samples.baseAddress!, frames: frames)
        }
        pending.removeFirst(take)
        pendingStart = pending.isEmpty ? nil : start + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(format.sampleRate))
        return AnalyzerInput(buffer: buffer, bufferStartTime: start)
    }

}

/// Fills a PCM buffer (Int16 or Float32, interleaved or not) from
/// interleaved float samples.
enum PCMFill {
    static func fill(_ buffer: AVAudioPCMBuffer, from samples: UnsafePointer<Float>, frames: Int) throws {
        let channels = Int(buffer.format.channelCount)
        let count = frames * channels
        guard frames <= Int(buffer.frameCapacity) else { throw MediaError.failed("Speech buffer too small") }
        // One channel or interleaved: a single run of samples. Otherwise each
        // channel gets every `channels`-th sample.
        let planar = !buffer.format.isInterleaved && channels > 1
        switch buffer.format.commonFormat {
        case .pcmFormatInt16:
            guard let destination = buffer.int16ChannelData else { throw MediaError.failed("Speech buffer has no data") }
            var scaled = [Float](repeating: 0, count: count)
            var low: Float = -1
            var high: Float = 32767 / 32768
            vDSP_vclip(samples, 1, &low, &high, &scaled, 1, vDSP_Length(count))
            var scale: Float = 32768
            vDSP_vsmul(scaled, 1, &scale, &scaled, 1, vDSP_Length(count))
            scaled.withUnsafeBufferPointer { source in
                if planar {
                    for channel in 0..<channels {
                        vDSP_vfixr16(source.baseAddress! + channel, vDSP_Stride(channels), destination[channel], 1, vDSP_Length(frames))
                    }
                } else {
                    vDSP_vfixr16(source.baseAddress!, 1, destination[0], 1, vDSP_Length(count))
                }
            }
        case .pcmFormatFloat32:
            guard let destination = buffer.floatChannelData else { throw MediaError.failed("Speech buffer has no data") }
            if planar {
                var one: Float = 1
                for channel in 0..<channels {
                    vDSP_vsmul(samples + channel, vDSP_Stride(channels), &one, destination[channel], 1, vDSP_Length(frames))
                }
            } else {
                destination[0].update(from: samples, count: count)
            }
        default:
            throw MediaError.failed("Unsupported speech audio format \(buffer.format)")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
    }
}

@available(macOS 26, *)
struct AnalyzerInputs: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let feed: AnalyzerFeed

    func makeAsyncIterator() -> Iterator { Iterator(feed: feed) }

    struct Iterator: AsyncIteratorProtocol {
        let feed: AnalyzerFeed

        mutating func next() async throws -> AnalyzerInput? {
            let feed = self.feed
            // Decoding blocks, so it runs off the cooperative threads.
            return try await Blocking.run(qos: feed.context.qos) { try feed.next() }
        }
    }
}

