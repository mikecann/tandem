import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import TandemCore

/// Transcripts with Underdog Bark 3.0 Pro, a fine-tune of NVIDIA's Parakeet
/// TDT 0.6B v3, run through FluidAudio's Parakeet decoder (Underdog's own
/// tested recipe: `AsrModels(..., version: .ultra)`, the encoder's `short8`
/// function for a take of up to 8 s and `full15` for anything longer, the
/// encoder on the Neural Engine and the rest on the CPU, 0.25 s of silence
/// before each piece).
///
/// The encoder takes at most 15 s, so the audio streams in from the file
/// and is cut into pieces of at most 14.75 s, each at the quietest 200 ms of
/// the last 10 s before that limit. That's a pause between words, so no word
/// straddles a join, and the pieces don't overlap, so none is written twice.
/// Only one piece is held at a time, however long the take. On the four
/// spike clips (tests/bark-check/) this got 36 words wrong where Bark's MLX
/// runtime, on 60 s pieces, got 21, and 15 of the 36 were "um"s the
/// provisional reference left out (8 of them where Bark 3.0 and Plus wrote
/// one too) and acronyms spelled out ("O. c. c." for "OCC"). Searching only
/// the last 5 s cut inside a word of Ian's fast speech, and the model then
/// missed the six words after it (42 wrong). Giving each piece a second of
/// the audio either side as context was worse still (48 to 71): a window that
/// opens mid-word can leave the decoder blank for seconds (FluidAudio issue
/// #909). FluidAudio's own long-audio path (15 s windows with 2 s of overlap,
/// merged by matching tokens) got 36 too, but needs the whole file in
/// memory, or converted to a temporary file, and takes no time range.
///
/// Words come from the tokens: a token with a leading space (SentencePiece's
/// word marker) starts a word, others join it, and punctuation joins the
/// word before without moving its end. A word runs from its first token's
/// start to its last token's end, as FluidAudio times them: on the encoder's
/// 80 ms grid, a frame before the decoder emitted them (TDT emits about a
/// frame late), the end the token's frame plus its TDT duration. Its
/// confidence is the lowest of its tokens'.
enum BarkTranscription {
    static let engine = "Bark 3.0 Pro"
    /// In the transcript cache key (`AnalysisSettings`).
    static let cacheName = "bark-3.0-pro"
    static let sampleRate = 16_000
    /// Underdog evaluated the model with 0.25 s of silence before the audio.
    static let leadIn = 4_000
    /// FluidAudio's single-window limit (15 s), less the lead-in.
    static let pieceLimit = ASRConstants.maxModelSamples - leadIn
    /// Pieces are cut in the last 10 s before the limit.
    static let cutSearch = 10 * sampleRate
    static let cutWindow = sampleRate / 5
    /// A take of up to 8 s with the lead-in goes through the encoder's
    /// `short8`. A longer take's short last piece stays on `full15`, as in
    /// Underdog's runner (FluidAudio masks the padding), so a take never
    /// loads the encoder twice.
    static let shortLimit = 8 * sampleRate

    /// The model wasn't there, or it failed: the transcript is SpeechAnalyzer's.
    struct Unavailable: Error, LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// The whole file (or range) as one transcript in media time.
    static func transcribe(source: URL, context: JobContext, timeRange: CMTimeRange?, models: URL, vocabulary: URL, runtime: BarkRuntime = .shared) async throws -> Transcript {
        let reader = try await AudioReader(url: source, sampleRate: Double(sampleRate), channels: 1, timeRange: timeRange)
        defer { reader.cancel() }
        let origin = timeRange?.start.seconds ?? 0
        return try await transcribe(BarkFeed(reader: reader, origin: origin), origin: origin, duration: reader.duration, context: context,
                                    models: models, vocabulary: vocabulary, runtime: runtime)
    }

    static func transcribe(_ feed: BarkFeed, origin: Double, duration: Double, context: JobContext, models: URL, vocabulary: URL, runtime: BarkRuntime = .shared) async throws -> Transcript {
        let duration = max(duration, 0.001)
        var words: [TranscriptWord] = []
        let lease = try await runtime.lease(models: models, vocabulary: vocabulary)
        defer { Task { await runtime.release() } }
        context.progress(0, message: "Transcribing with \(engine)")
        while let piece = try await Blocking.run(qos: context.qos, { try feed.nextPiece() }) {
            try await context.checkpoint()
            let short = duration * Double(sampleRate) + Double(leadIn) <= Double(shortLimit)
            let tokens = try await lease.tokens(for: piece.samples, short: short)
            words += place(Self.words(from: tokens), pieceStart: piece.start, pieceSamples: piece.samples.count)
            context.progress(min(1, (piece.start + Double(piece.samples.count) / Double(sampleRate) - origin) / duration))
        }
        try context.checkCancellation()
        return Transcript(language: "en", engine: engine, words: words)
    }

    /// A word as the tokens give it, in seconds from the start of the
    /// piece's input (lead-in included).
    struct Word: Equatable {
        var text: String
        var start: Double
        var end: Double
        var confidence: Float?
    }

    struct Token: Equatable {
        var text: String
        var start: Double
        var end: Double
        var confidence: Float
    }

    /// Sub-word tokens into words (see the type's comment).
    static func words(from tokens: [Token]) -> [Word] {
        var words: [Word] = []
        var current: Word?
        var afterBreak = false
        for (index, token) in tokens.enumerated() {
            let core = token.text.replacingOccurrences(of: "\u{2581}", with: " ")
            let trimmed = core.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !(trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) else { continue }
            let punctuation = isPunctuation(trimmed)
            // A letter straight after a comma or a full stop's kin starts a
            // word even without the marker ("say," "Oh"); after "." it
            // doesn't ("Node.js").
            let marked = core.hasPrefix(" ") || (afterBreak && !punctuation)
            afterBreak = punctuation && trimmed.unicodeScalars.allSatisfy { ",;:!?".unicodeScalars.contains($0) }
            // A marked apostrophe or hyphen right before a continuation
            // piece starts the word ("'cause").
            let next = tokens.dropFirst(index + 1).first.map { $0.text.replacingOccurrences(of: "\u{2581}", with: " ") }
            let startsWithMark = punctuation && marked && (trimmed == "'" || trimmed == "-" || trimmed == "\u{2019}")
                && next.map { !$0.hasPrefix(" ") && !isPunctuation($0.trimmingCharacters(in: .whitespaces)) } == true
            if var word = current, !startsWithMark, !marked || punctuation {
                word.text += trimmed
                if !punctuation {
                    word.end = max(word.end, token.end)
                    word.confidence = min(word.confidence ?? 1, token.confidence)
                }
                current = word
                continue
            }
            if let word = current { words.append(word) }
            current = Word(text: trimmed, start: token.start, end: token.end, confidence: punctuation ? nil : token.confidence)
        }
        if let current { words.append(current) }
        // A piece can open on punctuation with no word for it to join.
        return words.filter { !isPunctuation($0.text) }
    }

    static func isPunctuation(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
    }

    /// A piece's words in media time: the lead-in taken off, and kept inside
    /// the piece so pieces never overlap.
    static func place(_ words: [Word], pieceStart: Double, pieceSamples: Int) -> [TranscriptWord] {
        let lead = Double(leadIn) / Double(sampleRate)
        let end = pieceStart + Double(pieceSamples) / Double(sampleRate)
        return words.map { word in
            let start = min(end, max(pieceStart, pieceStart + word.start - lead))
            let finish = min(end, max(start, pieceStart + word.end - lead))
            return TranscriptWord(text: word.text, start: Time(seconds: start), end: Time(seconds: finish),
                                  confidence: word.confidence.map { (Double($0) * 1000).rounded() / 1000 })
        }
    }

    /// Where to cut a buffer longer than `limit`: the middle of its quietest
    /// `window` in the `search` before the limit.
    static func cutPoint(in samples: UnsafeBufferPointer<Float>, limit: Int = pieceLimit, search: Int = cutSearch, window: Int = cutWindow) -> Int {
        let high = min(limit, samples.count)
        let low = max(0, high - search)
        guard high - low > window else { return high }
        // Running energy over the window, a 10 ms step at a time. Equally
        // quiet windows in a row (digital silence) cut in their middle.
        let step = max(1, window / 20)
        var bestFirst = high - window / 2, bestLast = bestFirst
        var bestEnergy = Float.infinity
        var energy: Float = 0
        for index in low..<(low + window) { energy += samples[index] * samples[index] }
        var start = low
        while start + window <= high {
            if energy < bestEnergy {
                bestEnergy = energy
                bestFirst = start
                bestLast = start
            } else if energy == bestEnergy, bestLast == start - step {
                bestLast = start
            }
            let nextStart = start + step
            guard nextStart + window <= high else { break }
            for index in start..<nextStart { energy -= samples[index] * samples[index] }
            for index in (start + window)..<(nextStart + window) { energy += samples[index] * samples[index] }
            start = nextStart
        }
        return (bestFirst + bestLast) / 2 + window / 2
    }
}

/// Reads 16 kHz mono from the file and hands it over a piece at a time.
final class BarkFeed: @unchecked Sendable {
    struct Piece: Equatable {
        /// Media time of the first sample.
        var start: Double
        var samples: [Float]
    }

    /// Appends the next run of 16 kHz mono samples through the callback
    /// (with the media time of its first sample); false at the end.
    typealias Source = (_ append: (UnsafeBufferPointer<Float>, _ start: Double) -> Void) throws -> Bool

    let source: Source
    private var pending: [Float] = []
    private var pendingStart: Double?
    private var finished = false

    init(source: @escaping Source) {
        self.source = source
    }

    convenience init(reader: AudioReader, origin: Double) {
        self.init { append in
            try reader.next { samples, frames, start in
                // Samples stamped before the start (encoder priming) are
                // dropped so word times stay in media time.
                let early = Int(((origin - start.seconds) * reader.sampleRate).rounded())
                let dropped = min(frames, max(0, early))
                guard dropped < frames else { return }
                append(UnsafeBufferPointer(rebasing: samples[dropped...]), dropped > 0 ? origin : start.seconds)
            }
        }
    }

    /// The next piece, nil at the end. Blocks while it decodes.
    func nextPiece() throws -> Piece? {
        let limit = BarkTranscription.pieceLimit
        while !finished, pending.count <= limit {
            let more = try source { samples, start in
                if pendingStart == nil { pendingStart = start }
                pending.append(contentsOf: samples)
            }
            if !more { finished = true }
        }
        guard !pending.isEmpty, let start = pendingStart else { return nil }
        let cut = pending.count > limit ? pending.withUnsafeBufferPointer { BarkTranscription.cutPoint(in: $0) } : pending.count
        let piece = Piece(start: start, samples: Array(pending[..<cut]))
        pending.removeFirst(cut)
        pendingStart = start + Double(cut) / Double(BarkTranscription.sampleRate)
        return piece
    }
}

/// The loaded model, shared by every transcript in the process and run one
/// piece at a time. It stays loaded for a minute after the last transcript,
/// so a project's takes don't each load 1.2 GB, then goes.
actor BarkRuntime {
    static let shared = BarkRuntime()

    /// Where the encoder runs. The Neural Engine; `TANDEM_BARK_UNITS=cpu`
    /// (or `gpu`) for machines or sandboxes without it.
    static var encoderUnits: MLComputeUnits {
        switch ProcessInfo.processInfo.environment["TANDEM_BARK_UNITS"] {
        case "cpu": return .cpuOnly
        case "gpu": return .cpuAndGPU
        default: return .cpuAndNeuralEngine
        }
    }

    private var loaded: (folder: URL, stamp: String, lease: Lease)?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var unload: Task<Void, Never>?

    /// Waits for the model to be free, loading it if needed. Call
    /// `release()` when done.
    func lease(models folder: URL, vocabulary: URL) async throws -> Lease {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        unload?.cancel()
        unload = nil
        let stamp = BarkModelStore.stat(folder.appendingPathComponent("ready.json")) ?? ""
        if let loaded, loaded.folder == folder, loaded.stamp == stamp { return loaded.lease }
        loaded = nil
        do {
            let lease = try Lease(folder: folder, vocabulary: vocabulary, units: Self.encoderUnits)
            loaded = (folder, stamp, lease)
            return lease
        } catch {
            release()
            throw error
        }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
            return
        }
        busy = false
        unload?.cancel()
        unload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        if !busy { loaded = nil }
    }

    /// The model, with the encoder function the last take needed: `full15`,
    /// or `short8` for a take of up to 8 s.
    final class Lease: @unchecked Sendable {
        let folder: URL
        let units: MLComputeUnits
        let vocabulary: [Int: String]
        private let preprocessor: MLModel
        private let decoder: MLModel
        private let joint: MLModel
        private var managers: [String: AsrManager] = [:]

        init(folder: URL, vocabulary url: URL, units: MLComputeUnits) throws {
            self.folder = folder
            self.units = units
            let raw = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
            vocabulary = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
            preprocessor = try Self.load(folder, "Preprocessor", .cpuOnly)
            decoder = try Self.load(folder, "Decoder", .cpuOnly)
            joint = try Self.load(folder, "JointDecisionv3", .cpuOnly)
        }

        static func load(_ folder: URL, _ name: String, _ units: MLComputeUnits, function: String? = nil) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            configuration.functionName = function
            return try MLModel(contentsOf: folder.appendingPathComponent("\(name).mlmodelc"), configuration: configuration)
        }

        /// One function loaded at a time: on the CPU each holds its own copy
        /// of the 1.2 GB of weights (2.6 GB at the peak with both, 1.4 with
        /// one), and only a short take switches.
        func manager(for function: String) throws -> AsrManager {
            if let manager = managers[function] { return manager }
            managers.removeAll()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let models = AsrModels(encoder: try Self.load(folder, "Encoder", units, function: function), preprocessor: preprocessor,
                                   decoder: decoder, joint: joint, configuration: configuration, vocabulary: vocabulary, version: .ultra)
            let manager = AsrManager(models: models)
            managers[function] = manager
            return manager
        }

        /// One piece (at most `pieceLimit` samples) through the model, with
        /// the lead-in added. Times are seconds into that input.
        func tokens(for piece: [Float], short: Bool) async throws -> [BarkTranscription.Token] {
            var input = [Float](repeating: 0, count: BarkTranscription.leadIn)
            input.reserveCapacity(BarkTranscription.leadIn + piece.count)
            input += piece
            let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: BarkTranscription.sampleRate)
            if input.count < minimum { input += [Float](repeating: 0, count: minimum - input.count) }
            let manager = try manager(for: short && input.count <= BarkTranscription.shortLimit ? "short8" : "full15")
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(input, decoderState: &state)
            return (result.tokenTimings ?? []).map {
                BarkTranscription.Token(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
            }
        }
    }
}

/// Bark on its own, outside a project: for checking it against other
/// engines (`tandem-bark-check`). The app goes through `TranscriptJob`.
public struct BarkTranscriber: Sendable {
    public var store: BarkModelStore

    public init(store: BarkModelStore) {
        self.store = store
    }

    /// Checks the model files (downloading any that are missing, for a
    /// store that can) and compiles them if that isn't done yet.
    public func prepare(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws {
        try await store.prepare(progress: progress)
    }

    /// The file's transcript as `TranscriptJob` makes it, in media time.
    /// `wholeFile` hands all of it to FluidAudio at once instead, so its own
    /// long-audio path (15 s windows with 2 s of overlap, merged by matching
    /// tokens) cuts it, for comparing the two.
    public func transcribe(_ file: URL, timeRange: CMTimeRange? = nil, wholeFile: Bool = false) async throws -> Transcript {
        guard let models = store.readyFolder() else { throw MediaError.failed("The Bark model isn't ready; prepare it first") }
        let vocabulary = store.folder.appendingPathComponent(BarkModelStore.vocabulary)
        let context = JobContext(id: "bark-check", kind: .transcript, scheduler: nil)
        let origin = timeRange?.start.seconds ?? 0
        let feed: BarkFeed
        let duration: Double
        do {
            let reader = try await AudioReader(url: file, sampleRate: Double(BarkTranscription.sampleRate), channels: 1, timeRange: timeRange)
            feed = BarkFeed(reader: reader, origin: origin)
            duration = reader.duration
        } catch {
            // AVAssetReader isn't there in some sandboxes; a 16 kHz mono WAV
            // reads the same through AVAudioFile.
            guard timeRange == nil, let wav = try? AVAudioFile(forReading: file), wav.processingFormat.sampleRate == Double(BarkTranscription.sampleRate),
                  wav.processingFormat.channelCount == 1 else { throw error }
            feed = BarkFeed { append in
                guard wav.framePosition < wav.length,
                      let buffer = AVAudioPCMBuffer(pcmFormat: wav.processingFormat, frameCapacity: 16_000) else { return false }
                let start = Double(wav.framePosition) / wav.processingFormat.sampleRate
                try wav.read(into: buffer)
                guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { return false }
                append(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)), start)
                return true
            }
            duration = Double(wav.length) / wav.processingFormat.sampleRate
        }
        guard wholeFile else {
            return try await BarkTranscription.transcribe(feed, origin: origin, duration: duration, context: context, models: models, vocabulary: vocabulary)
        }
        var samples = [Float](repeating: 0, count: BarkTranscription.leadIn)
        while try feed.source({ chunk, _ in samples.append(contentsOf: chunk) }) {}
        let lease = try await BarkRuntime.shared.lease(models: models, vocabulary: vocabulary)
        defer { Task { await BarkRuntime.shared.release() } }
        let tokens = try await lease.tokens(forWhole: samples)
        let start = timeRange?.start.seconds ?? 0
        let words = BarkTranscription.place(BarkTranscription.words(from: tokens), pieceStart: start, pieceSamples: samples.count - BarkTranscription.leadIn)
        return Transcript(language: "en", engine: BarkTranscription.engine, words: words)
    }
}

extension BarkRuntime.Lease {
    /// Lead-in included, any length, through FluidAudio's own chunking.
    func tokens(forWhole input: [Float]) async throws -> [BarkTranscription.Token] {
        let manager = try manager(for: input.count <= BarkTranscription.shortLimit ? "short8" : "full15")
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(input, decoderState: &state)
        return (result.tokenTimings ?? []).map {
            BarkTranscription.Token(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
        }
    }
}
