import CryptoKit
import Foundation
import TandemCore
import XCTest
@testable import TandemMedia

/// Bark 3.0 Pro transcripts: tokens into words, pieces and their joins, the
/// model store and when SpeechAnalyzer stands in. None of these need the
/// model or the network; the last test runs the real model when
/// TANDEM_BARK_MODEL points at its coreml folder.
final class BarkTranscriptionTests: TempFolderTestCase {
    typealias Token = BarkTranscription.Token

    func token(_ text: String, _ start: Double, _ end: Double, _ confidence: Float = 0.9) -> Token {
        Token(text: text, start: start, end: end, confidence: confidence)
    }

    // MARK: - Tokens into words

    func testSubWordTokensBecomeWordsFromTheirFirstStartToTheirLastEnd() {
        // FluidAudio turns the SentencePiece marker into a leading space.
        let words = BarkTranscription.words(from: [
            token(" Hel", 0.32, 0.40, 0.95), token("lo", 0.40, 0.56, 0.7), token(",", 0.88, 0.96, 0.99),
            token(" world", 1.04, 1.36), token(".", 1.60, 1.68)
        ])
        XCTAssertEqual(words.map(\.text), ["Hello,", "world."])
        XCTAssertEqual(words[0].start, 0.32)
        XCTAssertEqual(words[0].end, 0.56, "punctuation joins the word without moving its end into the pause")
        XCTAssertEqual(words[0].confidence, 0.7, "a word is as sure as its least sure piece")
        XCTAssertEqual(words[1].start, 1.04)
        XCTAssertEqual(words[1].end, 1.36)
    }

    func testWordBoundariesFollowTheMarkerApostrophesAndCommas() {
        let words = BarkTranscription.words(from: [
            token(" we", 0, 0.1), token("'", 0.1, 0.2), token("ll", 0.2, 0.3),
            token(" '", 0.4, 0.5), token("cause", 0.5, 0.6),
            token(" say", 0.7, 0.8), token(",", 0.8, 0.9), token("Oh", 0.9, 1.0),
            token(" Node", 1.1, 1.2), token(".", 1.2, 1.3), token("js", 1.3, 1.4),
            token("\u{2581}um", 1.5, 1.6)
        ])
        XCTAssertEqual(words.map(\.text), ["we'll", "'cause", "say,", "Oh", "Node.js", "um"])
    }

    func testFillersStayAndStrayPunctuationAndSpecialTokensGo() {
        let words = BarkTranscription.words(from: [
            token(".", 0, 0.08), token("<unk>", 0.1, 0.2), token(" Um", 0.3, 0.5), token(",", 0.5, 0.6), token(" so", 0.7, 0.8)
        ])
        XCTAssertEqual(words.map(\.text), ["Um,", "so"])
        XCTAssertTrue(BarkTranscription.words(from: []).isEmpty)
    }

    // MARK: - Pieces and joins

    /// A tone with silences at the given seconds (each `gap` long).
    func tone(seconds: Double, silences: [Double], gap: Double = 0.3) -> [Float] {
        let rate = Double(BarkTranscription.sampleRate)
        return (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            if silences.contains(where: { time >= $0 && time < $0 + gap }) { return 0 }
            return 0.3 * Float(sin(2 * Double.pi * 220 * time))
        }
    }

    func testAPieceIsCutInTheQuietestPauseOfTheLastTenSeconds() {
        let samples = tone(seconds: 20, silences: [2, 9])
        let cut = samples.withUnsafeBufferPointer { BarkTranscription.cutPoint(in: $0) }
        XCTAssertEqual(Double(cut) / 16_000, 9.15, accuracy: 0.02, "the middle of the pause at 9 s, not the one at 2 s outside the search")
        XCTAssertLessThanOrEqual(cut, BarkTranscription.pieceLimit)
    }

    func testPiecesCoverTheAudioOnceInOrderAtPausesInMediaTime() throws {
        let samples = tone(seconds: 40, silences: [9, 21, 33])
        var offset = 0
        // Arrives a second at a time, stamped from 100 s like a time range.
        let feed = BarkFeed { append in
            guard offset < samples.count else { return false }
            let count = min(16_000, samples.count - offset)
            samples.withUnsafeBufferPointer { append(UnsafeBufferPointer(rebasing: $0[offset..<(offset + count)]), 100 + Double(offset) / 16_000) }
            offset += count
            return true
        }
        var pieces: [BarkFeed.Piece] = []
        while let piece = try feed.nextPiece() { pieces.append(piece) }
        XCTAssertEqual(pieces.map(\.samples.count).reduce(0, +), samples.count, "every sample once: nothing lost or doubled at the joins")
        XCTAssertEqual(pieces.flatMap(\.samples), samples)
        XCTAssertEqual(pieces.first?.start, 100)
        for (piece, next) in zip(pieces, pieces.dropFirst()) {
            XCTAssertLessThanOrEqual(piece.samples.count, BarkTranscription.pieceLimit)
            XCTAssertEqual(next.start, piece.start + Double(piece.samples.count) / 16_000, accuracy: 1e-9)
        }
        let joins = pieces.dropFirst().map { $0.start - 100 }
        XCTAssertEqual(joins.count, 3)
        for (join, pause) in zip(joins, [9.0, 21, 33]) {
            XCTAssertEqual(join, pause + 0.15, accuracy: 0.02)
        }
    }

    func testWordsLandInMediaTimeInsideTheirPiece() {
        let piece = 10.0, lead = 0.25
        let words = BarkTranscription.place([
            .init(text: "early", start: 0.1, end: 0.4, confidence: 0.81234),
            .init(text: "middle", start: lead + 2, end: lead + 2.5, confidence: nil),
            .init(text: "late", start: lead + 4.9, end: lead + 5.4, confidence: 1)
        ], pieceStart: piece, pieceSamples: 5 * 16_000)
        XCTAssertEqual(words.map(\.text), ["early", "middle", "late"])
        XCTAssertEqual(words[0].start.seconds, 10, accuracy: 1e-4, "a word in the lead-in starts with the piece")
        XCTAssertEqual(words[0].end.seconds, 10.15, accuracy: 1e-4)
        XCTAssertEqual(words[0].confidence, 0.812)
        XCTAssertEqual(words[1].start.seconds, 12, accuracy: 1e-4)
        XCTAssertNil(words[1].confidence)
        XCTAssertEqual(words[2].end.seconds, 15, accuracy: 1e-4, "never past the piece, so pieces don't overlap")
    }

    // MARK: - Settings and caches

    func testBarkIsTheDefaultForEnglishAndSpeechAnalyzerForOtherLocales() {
        let standard = AnalysisSettings()
        XCTAssertEqual(standard.transcriptEngine, .bark, "Mike approved Bark 3.0 Pro")
        XCTAssertTrue(standard.usesBark)
        XCTAssertTrue(AnalysisSettings(transcriptLocale: "en-AU").usesBark)
        XCTAssertTrue(AnalysisSettings(transcriptLocale: "en_GB").usesBark)
        XCTAssertFalse(AnalysisSettings(transcriptLocale: "fr-FR").usesBark, "Bark is English only")
        XCTAssertFalse(AnalysisSettings(transcriptEngine: .speechAnalyzer).usesBark)
    }

    func testSwitchingEnginesRemakesTranscriptsOnly() {
        let speech = AnalysisSettings(transcriptEngine: .speechAnalyzer)
        XCTAssertEqual(speech.canonical(for: .transcript), "{\"locale\":\"en-US\"}", "SpeechAnalyzer transcripts keep the key they had")
        let bark = AnalysisSettings()
        XCTAssertEqual(bark.canonical(for: .transcript), "{\"engine\":\"bark-3.0-pro\",\"locale\":\"en-US\"}")
        XCTAssertEqual(AnalysisKind.allCases.filter { bark.canonical(for: $0) != speech.canonical(for: $0) }, [.transcript])
        let french = AnalysisSettings(transcriptLocale: "fr-FR")
        XCTAssertEqual(french.canonical(for: .transcript), AnalysisSettings(transcriptLocale: "fr-FR", transcriptEngine: .speechAnalyzer).canonical(for: .transcript),
                       "French is SpeechAnalyzer's either way, so it keeps its transcripts")
    }

    // MARK: - The model store

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A store of small files, no packages to compile, whose downloads hand
    /// over `served` (by default the right bytes) and are counted.
    func store(_ contents: [String: Data], serving served: [String: Data] = [:], downloads: Counter = Counter(), autoPrepare: Bool = false) -> BarkModelStore {
        let temp = self.temp!
        let files = contents.keys.sorted().map { path in
            BarkModelStore.File(path: path, size: Int64(contents[path]!.count),
                                sha256: SHA256.hash(data: contents[path]!).map { String(format: "%02x", $0) }.joined())
        }
        let folder = temp.appendingPathComponent("Models/bark", isDirectory: true)
        return BarkModelStore(folder: folder, compiledFolder: folder.appendingPathComponent("compiled", isDirectory: true), files: files,
                              remote: URL(string: "https://example.invalid/coreml/")!, fetch: { url, _, progress in
                                  downloads.increment()
                                  let path = url.path.replacingOccurrences(of: "/coreml/", with: "")
                                  let data = served[path] ?? contents[path]!
                                  progress(Int64(data.count))
                                  let file = temp.appendingPathComponent("download-\(UUID().uuidString)")
                                  try data.write(to: file)
                                  return file
                              }, autoPrepare: autoPrepare)
    }

    func testTheStandardStoreIsTheModelAtAPinnedCommit() {
        let store = BarkModelStore.standard
        XCTAssertTrue(store.folder.path.hasSuffix("Library/Application Support/Tandem/Models/bark-3.0-pro"), store.folder.path)
        XCTAssertEqual(BarkModelStore.revision.count, 40, "a commit, not main")
        XCTAssertTrue(store.remote.absoluteString.hasPrefix("https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Pro/resolve/\(BarkModelStore.revision)/coreml/"))
        XCTAssertEqual(store.packages, ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"])
        XCTAssertTrue(store.files.contains { $0.path == "NOTICE" } && store.files.contains { $0.path == "LICENSE" }, "CC-BY: the credit comes down with it")
        XCTAssertTrue(store.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
        XCTAssertEqual(Double(store.totalBytes) / 1e9, 1.23, accuracy: 0.01)
        XCTAssertFalse(store.autoPrepare, "tests never download it")
    }

    func testMissingFilesAreDownloadedOnceCheckedAndMadeReady() async throws {
        let downloads = Counter()
        let store = store(["vocab.json": Data("{}".utf8), "NOTICE": Data("credit".utf8)], downloads: downloads)
        XCTAssertNil(store.readyFolder())
        XCTAssertEqual(store.stamp(), "absent")
        try await store.prepare()
        XCTAssertEqual(store.readyFolder(), store.compiledFolder)
        XCTAssertEqual(try Data(contentsOf: store.folder.appendingPathComponent("NOTICE")), Data("credit".utf8))
        XCTAssertNotEqual(store.stamp(), "absent")
        try await store.prepare()
        XCTAssertEqual(downloads.value, 2, "each file once")
    }

    func testFilesAlreadyInPlaceAreCheckedNotDownloaded() async throws {
        let downloads = Counter()
        let store = store(["vocab.json": Data("{}".utf8)], downloads: downloads)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.folder.appendingPathComponent("vocab.json"))
        try await store.prepare()
        XCTAssertNotNil(store.readyFolder())
        XCTAssertEqual(downloads.value, 0)
    }

    func testADownloadThatDoesNotMatchItsChecksumIsRefused() async throws {
        let store = store(["vocab.json": Data("{}".utf8)], serving: ["vocab.json": Data("{\"x\":1}".utf8)])
        do {
            try await store.prepare()
            XCTFail("a download with the wrong checksum must not be used")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
        }
        XCTAssertNil(store.readyFolder())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("vocab.json").path))
    }

    func testAFileChangedSinceItWasCheckedMakesTheModelUnreadyUntilCheckedAgain() async throws {
        let downloads = Counter()
        let store = store(["vocab.json": Data("{}".utf8)], downloads: downloads)
        try await store.prepare()
        let ready = store.stamp()
        try Data("{ }".utf8).write(to: store.folder.appendingPathComponent("vocab.json"))
        XCTAssertNil(store.readyFolder(), "a quick stat says it changed")
        try await store.prepare()
        XCTAssertNotNil(store.readyFolder())
        XCTAssertEqual(downloads.value, 2, "the damaged file came down again")
        XCTAssertNotEqual(store.stamp(), ready, "so transcripts that fell back meanwhile are made again")
    }

    func testADownloadCutOffLastTimeIsFinishedNotStartedAgain() async throws {
        let contents = Data("0123456789abcdef".utf8)
        let store = store(["weights.bin": contents])
        let partial = store.partialFile(store.files[0])
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.prefix(6).write(to: partial)
        RangeServer.serve(contents)
        let downloaded = try await ModelDownload.fetch(URL(string: "https://example.invalid/coreml/weights.bin")!, into: partial,
                                                       configuration: RangeServer.configuration()) { _ in }
        XCTAssertEqual(try Data(contentsOf: downloaded), contents)
        XCTAssertEqual(RangeServer.ranges, ["bytes=6-"], "it asked for the rest")

        // A server that ignores the range sends it all, which starts it again.
        try contents.prefix(6).write(to: partial)
        RangeServer.serve(contents, honoursRange: false)
        _ = try await ModelDownload.fetch(URL(string: "https://example.invalid/coreml/weights.bin")!, into: partial,
                                          configuration: RangeServer.configuration()) { _ in }
        XCTAssertEqual(try Data(contentsOf: partial), contents)
    }

    func testAPartialThatIsAllThereIsUsedWithoutDownloading() async throws {
        let downloads = Counter()
        let store = store(["vocab.json": Data("{}".utf8)], downloads: downloads)
        let partial = store.partialFile(store.files[0])
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: partial)
        try await store.prepare()
        XCTAssertNotNil(store.readyFolder())
        XCTAssertEqual(downloads.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "placed, so the partial goes")
    }

    func testThePreparerMakesTheModelReadyInTheBackgroundAndSaysSo() async throws {
        let store = store(["vocab.json": Data("{}".utf8)])
        let announced = expectation(forNotification: BarkModelStore.readyNotification, object: nil)
        await BarkModelPreparer.shared.start(store)
        await BarkModelPreparer.shared.wait(for: store)
        await fulfillment(of: [announced], timeout: 10)
        XCTAssertNotNil(store.readyFolder())
        let state = await BarkModelPreparer.shared.state(of: store)
        XCTAssertFalse(state.running)
        XCTAssertNil(state.failure)
    }

    /// A `tandem` command would end the download when it exits, so its
    /// transcripts wait for the model; the app's fall back meanwhile.
    func testACommandWaitsForTheModelWhereTheAppFallsBack() async throws {
        let context = JobContext(id: "t", kind: .transcript, scheduler: nil)
        var app = store(["vocab.json": Data("{}".utf8)], autoPrepare: true)
        app.folder = temp.appendingPathComponent("Models/app-bark", isDirectory: true)
        app.compiledFolder = app.folder.appendingPathComponent("compiled", isDirectory: true)
        let none = try await TranscriptJob.readyModel(app, context: context)
        XCTAssertNil(none, "the app doesn't wait: SpeechAnalyzer stands in")
        await BarkModelPreparer.shared.wait(for: app)
        XCTAssertNotNil(app.readyFolder(), "while the download carries on in the background")

        var command = store(["vocab.json": Data("{}".utf8)], autoPrepare: true)
        command.waitsForModel = true
        let models = try await TranscriptJob.readyModel(command, context: context)
        XCTAssertEqual(models, command.compiledFolder, "the command waited for it, so Bark makes its transcript")
    }

    // MARK: - Falling back

    func testWithoutTheModelBarkSaysWhySpeechAnalyzerShouldMakeIt() async throws {
        let store = store(["vocab.json": Data("{}".utf8)])
        let context = JobContext(id: "t", kind: .transcript, scheduler: nil)
        do {
            _ = try await TranscriptJob.bark(source: file("take.wav"), context: context, timeRange: nil, store: store)
            XCTFail("no model, no Bark transcript")
        } catch let unavailable as BarkTranscription.Unavailable {
            XCTAssertEqual(unavailable.reason, "Bark 3.0 Pro isn't downloaded")
        }
    }

    func testABrokenModelFallsBackToo() async throws {
        try SyntheticMedia.writeAudioFile(to: file("take.wav"), segments: [(1, 0.3)])
        let store = store(["vocab.json": Data("{}".utf8)])
        try await store.prepare()
        let context = JobContext(id: "t", kind: .transcript, scheduler: nil)
        do {
            _ = try await TranscriptJob.bark(source: file("take.wav"), context: context, timeRange: nil, store: store)
            XCTFail("a model that won't load makes no transcript")
        } catch let unavailable as BarkTranscription.Unavailable {
            XCTAssertTrue(unavailable.reason.hasPrefix("Bark 3.0 Pro failed: "), unavailable.reason)
        }
    }

    func testATranscriptSpeechAnalyzerMadeIsMadeAgainOnceWhenBarksModelIsReady() async throws {
        try SyntheticMedia.writeAudioFile(to: file("source/take-camera.wav"), segments: [(1, 0.3)])
        let folder = ProjectFolder(root: temp)
        let take = try await MediaScanner.probe(file("source/take-camera.wav"), folder: folder)
        let analysis = MediaAnalysis(folder: folder, encoderLock: EncoderLock())
        let store = store(["vocab.json": Data("{}".utf8)])
        analysis.barkStore = store
        // The fallback as `TranscriptJob` leaves it: SpeechAnalyzer's words
        // and the state Bark's model was in.
        let key = try XCTUnwrap(analysis.cacheKey(.transcript, for: take))
        let pending = try analysis.cache.begin(kind: .transcript, key: key)
        try CacheJSON.write(Transcript(language: "en-US", engine: "SpeechAnalyzer", words: [TranscriptWord(text: "hi", start: .zero, end: Time(seconds: 0.5))]),
                            to: pending.folder.appendingPathComponent(TranscriptJob.file))
        try TranscriptFallback(reason: "Bark 3.0 Pro isn't downloaded", model: store.stamp()).write(to: pending.folder)
        try analysis.cache.commit(pending, fingerprint: try XCTUnwrap(take.fingerprint), algorithmVersion: AnalysisKind.transcript.algorithmVersion,
                                  settings: analysis.settings.canonical(for: .transcript, item: take), source: take.path)
        XCTAssertTrue(analysis.isCached(.transcript, for: take), "the stand-in serves while the model isn't here")
        XCTAssertEqual(analysis.rawTranscript(for: take)?.engine, "SpeechAnalyzer")

        try await store.prepare()
        XCTAssertFalse(analysis.isCached(.transcript, for: take), "the model arrived: due for Bark")
        XCTAssertNotNil(analysis.rawTranscript(for: take), "and the stand-in keeps serving until that's made")

        // With SpeechAnalyzer chosen, a stand-in is just a transcript.
        analysis.settings.transcriptEngine = .speechAnalyzer
        XCTAssertFalse(analysis.needsRebuild(.transcript, key: key, settings: analysis.settings))
    }

    /// The stand-in was read (and remembered) before Bark's transcript
    /// replaced it under the same key; the same `MediaAnalysis` reads Bark's.
    func testATranscriptRemadeWithBarkIsReadInPlaceOfTheRememberedStandIn() async throws {
        try SyntheticMedia.writeAudioFile(to: file("source/take-camera.wav"), segments: [(1, 0.3)])
        let folder = ProjectFolder(root: temp)
        let take = try await MediaScanner.probe(file("source/take-camera.wav"), folder: folder)
        let analysis = MediaAnalysis(folder: folder, encoderLock: EncoderLock())
        analysis.barkStore = store(["vocab.json": Data("{}".utf8)])
        let key = try XCTUnwrap(analysis.cacheKey(.transcript, for: take))
        func commit(_ engine: String, fallback: Bool) throws {
            let pending = try analysis.cache.begin(kind: .transcript, key: key)
            try CacheJSON.write(Transcript(language: "en-US", engine: engine, words: [TranscriptWord(text: engine, start: .zero, end: Time(seconds: 0.5))]),
                                to: pending.folder.appendingPathComponent(TranscriptJob.file))
            if fallback { try TranscriptFallback(reason: "Bark 3.0 Pro isn't downloaded", model: "absent").write(to: pending.folder) }
            // As `MediaAnalysis.make` commits a rebuild.
            if analysis.cache.contains(kind: .transcript, key: key) { analysis.cache.remove(kind: .transcript, key: key) }
            try analysis.cache.commit(pending, fingerprint: try XCTUnwrap(take.fingerprint), algorithmVersion: AnalysisKind.transcript.algorithmVersion,
                                      settings: analysis.settings.canonical(for: .transcript, item: take), source: take.path)
        }
        try commit("SpeechAnalyzer", fallback: true)
        XCTAssertEqual(analysis.rawTranscript(for: take)?.engine, "SpeechAnalyzer")
        XCTAssertEqual(analysis.transcript(for: take)?.engine, "SpeechAnalyzer")

        try commit("Bark 3.0 Pro", fallback: false)
        XCTAssertEqual(analysis.rawTranscript(for: take)?.engine, "Bark 3.0 Pro")
        XCTAssertEqual(analysis.transcript(for: take)?.words.first?.text, "Bark 3.0 Pro")
    }

    /// The whole job with the model missing: SpeechAnalyzer makes the
    /// transcript and the status says so. Needs the Mac's speech services.
    func testTheJobFallsBackToSpeechAnalyzerSayingSo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_SPEECH_TESTS"] == "1",
                          "set TANDEM_SPEECH_TESTS=1 to test speech services and allow model installation")
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let url = file("said-camera.wav")
        let spoken = try await SyntheticMedia.writeSpeech("Convex keeps every word of the take in sync with the timeline.", to: url, leadIn: 1)
        try XCTSkipUnless(spoken, "no system voice to make test speech with")
        let out = file("out/x").deletingLastPathComponent()
        let store = store(["vocab.json": Data("{}".utf8)])
        let context = JobContext(id: "t", kind: .transcript, scheduler: nil)
        try await TranscriptJob.run(source: url, settings: AnalysisSettings(), into: out, context: context, barkStore: store)
        XCTAssertEqual(TranscriptJob.read(from: out)?.engine, "SpeechAnalyzer")
        XCTAssertEqual(context.lastNote, "Made with SpeechAnalyzer: Bark 3.0 Pro isn't downloaded")
        XCTAssertEqual(TranscriptFallback.read(from: out)?.model, "absent")
    }

    // MARK: - The real model

    /// Bark on a spoken sentence. Opt in with TANDEM_BARK_MODEL=<the model
    /// repository's coreml folder> (compiled into a temporary folder), and
    /// TANDEM_BARK_UNITS=cpu where there's no Neural Engine.
    func testBarkTranscribesSpeechWithMediaTimes() async throws {
        guard let path = ProcessInfo.processInfo.environment["TANDEM_BARK_MODEL"] else {
            throw XCTSkip("set TANDEM_BARK_MODEL to the Bark 3.0 Pro coreml folder")
        }
        let models = URL(fileURLWithPath: path, isDirectory: true)
        let url = file("source/said-camera.wav")
        let spoken = try await SyntheticMedia.writeSpeech("Convex keeps every word of the take in sync with the timeline.", to: url, leadIn: 1.5)
        try XCTSkipUnless(spoken, "no system voice to make test speech with")
        let store = BarkModelStore(folder: models, compiledFolder: temp.appendingPathComponent("compiled", isDirectory: true))
        try await store.prepare()
        let out = file("out/x").deletingLastPathComponent()
        let context = JobContext(id: "t", kind: .transcript, scheduler: nil)
        try await TranscriptJob.run(source: url, settings: AnalysisSettings(), into: out, context: context, barkStore: store)
        let transcript = try XCTUnwrap(TranscriptJob.read(from: out))
        XCTAssertEqual(transcript.engine, "Bark 3.0 Pro")
        XCTAssertNil(context.lastNote, "no fallback")
        XCTAssertNil(TranscriptFallback.read(from: out))
        let words = transcript.words.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        XCTAssertTrue(words.contains("every") && words.contains("timeline"), words.description)
        // After a silence the model starts the first word 0.25-0.3 s before
        // the voice (Bark's MLX runtime too: 1.27 s here), and FluidAudio
        // moves it a frame earlier, so 1.19 s for speech at 1.5 s.
        // TranscriptAlignment pulls it in to the voice when it's read.
        XCTAssertGreaterThanOrEqual(transcript.words.first?.start.seconds ?? 0, 1.05, "after the lead-in of silence, in media time")
        XCTAssertTrue(transcript.words.allSatisfy { $0.confidence != nil })
    }
}

/// Serves one file for `ModelDownload`, honouring a Range header (206 and
/// the rest) unless told not to, and remembers the ranges it was asked for.
final class RangeServer: URLProtocol {
    nonisolated(unsafe) private static var contents = Data()
    nonisolated(unsafe) private static var honoursRange = true
    nonisolated(unsafe) static var ranges: [String] = []

    static func serve(_ data: Data, honoursRange: Bool = true) {
        contents = data
        self.honoursRange = honoursRange
        ranges = []
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServer.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Self.contents
        var status = 200
        if let range = request.value(forHTTPHeaderField: "Range") {
            Self.ranges.append(range)
            if Self.honoursRange, let from = Int(range.dropFirst("bytes=".count).dropLast()) {
                body = Self.contents.subdata(in: from..<Self.contents.count)
                status = 206
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
