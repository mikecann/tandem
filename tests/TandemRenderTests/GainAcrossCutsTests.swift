import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// A clip's gain lands where the timeline has it, to the sample. AVAudioMix
/// moves a track's volume by at most 1.0 (linear) every 25 ms, so a clip
/// held at +16 dB up to a cut used to carry into the next clip for a third
/// of a second, a keyframed ramp inside a clip landed late, and the 3 ms
/// fades at hard cuts never happened. A tap on each track now applies the
/// gain to the samples, for the viewer and export alike. These read the mix
/// the way export does and the way the viewer does (`ViewerAudio`'s
/// stream, from a seek to where reading starts), and both must land.
final class GainAcrossCutsTests: XCTestCase {
    /// How a mix is read: export's reader, or what the viewer queues for
    /// its renderer after a seek.
    enum Reading: String, CaseIterable {
        case export, viewer
    }
    static let rate = 48_000

    /// A steady 1 kHz tone: 48 samples a cycle, so any whole millisecond
    /// holds whole cycles.
    static func tone(peakDB: Double) -> (Int) -> Float {
        let peak = pow(10, peakDB / 20)
        return { i in Float(peak * sin(2 * Double.pi * 1000 * Double(i) / 48_000)) }
    }

    /// A PCM file with `sample(i)` on every channel, in float or 16-bit.
    @discardableResult
    func wav(_ media: TestMedia, _ name: String, seconds: Double, channels: Int = 2, bits16: Bool = false, sample: (Int) -> Float) throws -> URL {
        let url = media.folder.appendingPathComponent(name)
        let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.rate), channels: AVAudioChannelCount(channels), interleaved: false)!
        var settings = processing.settings
        if bits16 {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * Double(Self.rate))
        let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let v = sample(i)
            for c in 0..<channels { buffer.floatChannelData![c][i] = v }
        }
        try file.write(from: buffer)
        return url
    }

    /// An AAC .m4a with `sample(i)` on every channel.
    @discardableResult
    func aac(_ media: TestMedia, _ name: String, seconds: Double, channels: Int, sample: @escaping (Int) -> Float) async throws -> URL {
        let url = media.folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 192_000
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(writer.error as Any)")
        writer.startSession(atSourceTime: .zero)
        let format = try AudioBuffers.formatDescription()
        let total = Int(seconds * Double(Self.rate))
        var i = 0
        while i < total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let count = min(4_800, total - i)
            var samples = [Float](repeating: 0, count: count * 2)
            for j in 0..<count {
                samples[2 * j] = sample(i + j)
                samples[2 * j + 1] = sample(i + j)
            }
            input.append(try AudioBuffers.sampleBuffer(samples, at: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(Self.rate)), format: format))
            i += count
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(writer.error as Any)")
        return url
    }

    /// The left channel of the mix from `start` to `end`, read the way
    /// export reads it. On a thread of its own with a time limit: a reader
    /// AVFoundation stalls fails the test instead of hanging it.
    func mix(_ built: BuiltComposition, from start: Double, to end: Double, file: StaticString = #filePath, line: UInt = #line) async throws -> [Float] {
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        final class Result: @unchecked Sendable {
            var left: [Float] = []
            var status = AVAssetReader.Status.unknown
            var error: Error?
        }
        let result = Result()
        let finished = DispatchSemaphore(value: 0)
        let job = Unchecked((built.composition, tracks, built.audioMix))
        let range = CMTimeRange(start: t(start).cmTime, end: t(end).cmTime)
        Thread {
            defer { finished.signal() }
            let (asset, tracks, audioMix) = job.value
            do {
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = range
                let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: AudioBuffers.readerSettings)
                output.audioMix = audioMix
                output.audioTimePitchAlgorithm = .spectral
                reader.add(output)
                reader.startReading()
                while let buffer = output.copyNextSampleBuffer() {
                    let samples = AudioBuffers.samples(in: buffer)
                    result.left += stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
                }
                result.status = reader.status
                result.error = reader.error
            } catch {
                result.error = error
            }
        }.start()
        let done = await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { resume.resume(returning: finished.wait(timeout: .now() + 20) == .success) }
        }
        guard done else {
            XCTFail("reading the mix from \(start) to \(end) s stalled", file: file, line: line)
            return []
        }
        XCTAssertEqual(result.status, .completed, "\(result.error as Any)", file: file, line: line)
        return result.left
    }

    /// The left channel from `start` to `end`, read one way or the other.
    func heard(_ built: BuiltComposition, from start: Double, to end: Double, by reading: Reading, file: StaticString = #filePath, line: UInt = #line) async throws -> [Float] {
        switch reading {
        case .export: return try await mix(built, from: start, to: end, file: file, line: line)
        case .viewer: return try await viewerMix(built, from: start, to: end, file: file, line: line)
        }
    }

    /// The left channel of what the viewer queues for its renderer after a
    /// seek to `start`, up to `end`. On a thread of its own with a time
    /// limit, like `mix`.
    func viewerMix(_ built: BuiltComposition, from start: Double, to end: Double, file: StaticString = #filePath, line: UInt = #line) async throws -> [Float] {
        final class Result: @unchecked Sendable { var left: [Float] = [] }
        let result = Result()
        let finished = DispatchSemaphore(value: 0)
        let mix = ViewerMix(built)
        let wanted = Int(((end - start) * Double(Self.rate)).rounded())
        Thread {
            defer { finished.signal() }
            let sound = ForwardSound(mix, from: ViewerAudio.frame(of: t(start)))
            while result.left.count < wanted, let chunk = sound.next() {
                result.left += stride(from: 0, to: chunk.samples.count, by: 2).map { chunk.samples[$0] }
            }
            sound.cancel()
        }.start()
        let done = await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { resume.resume(returning: finished.wait(timeout: .now() + 20) == .success) }
        }
        guard done else {
            XCTFail("reading the viewer's sound from \(start) to \(end) s stalled", file: file, line: line)
            return []
        }
        XCTAssertGreaterThanOrEqual(result.left.count, wanted, "the viewer's sound runs to the end of the timeline", file: file, line: line)
        return Array(result.left.prefix(wanted))
    }

    /// RMS level in dB of `seconds` of `samples` from `time` (seconds after
    /// the first sample).
    func level(_ samples: [Float], at time: Double, seconds: Double) -> Double {
        let i = Int((time * Double(Self.rate)).rounded())
        let n = Int((seconds * Double(Self.rate)).rounded())
        guard i >= 0, i + n <= samples.count, n > 0 else { return .nan }
        let power = samples[i..<(i + n)].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(n)
        return 10 * log10(max(power, 1e-30))
    }

    /// Asserts the clip after the cut plays at its steady level through its
    /// first 50 ms, in 5 ms windows from the end of its 3 ms fade in.
    func assertSteadyAfterCut(
        _ samples: [Float], readFrom: Double, cut: Double, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let steady = level(samples, at: cut + 0.5 - readFrom, seconds: 0.2)
        var heard: [String] = []
        var worst = 0.0
        for k in 0..<10 {
            let start = cut + 0.003 + Double(k) * 0.005
            let difference = level(samples, at: start - readFrom, seconds: 0.005) - steady
            heard.append(String(format: "%+.1f", difference))
            worst = max(worst, abs(difference))
        }
        XCTAssertLessThanOrEqual(worst, 0.5, "\(message) dB against the steady level in 5 ms windows after the cut: \(heard.joined(separator: " "))", file: file, line: line)
    }

    func gainKeyframes(_ pairs: [(Double, Double)]) -> [Keyframe] {
        pairs.map { Keyframe(time: t($0.0), value: .number($0.1), interpolation: .linear) }
    }

    /// The camera's loudness as the analysis would measure it.
    func measured(_ url: URL, _ item: MediaItem) async throws -> FakeAssets {
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        meter.process(interleaved: try await decodeAudio(url))
        let assets = FakeAssets()
        assets.loudnesses[item.id] = Loudness(integratedLUFS: meter.integrated, truePeakDBTP: meter.truePeak, loudnessRange: 0)
        return assets
    }

    // MARK: - Cuts

    func testTheClipAfterACutPlaysAtItsOwnLevel() async throws {
        let media = try TestMedia()
        try wav(media, "tone.wav", seconds: 12, sample: Self.tone(peakDB: -20))
        let item = MediaItem(id: "med_tone", path: "tone.wav", kind: .audio, role: .other, duration: t(12), hasAudio: true)
        // A rises to +12 dB and holds it right up to the cut; B is at 0 dB.
        var a = Clip(id: "clip_a", content: .media(mediaID: item.id), start: .zero, duration: t(2))
        a.keyframes["audio.gainDB"] = gainKeyframes([(1.0, 0), (1.2, 12), (1.6, 12)])
        let b = Clip(id: "clip_b", content: .media(mediaID: item.id), start: t(2), duration: t(3), sourceStart: t(5))
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [a, b])], media: [item])
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))

        // Read from part way in, as a review clip does and as the viewer
        // does after a seek.
        for reading in Reading.allCases {
            let samples = try await heard(built, from: 1.5, to: 3.0, by: reading)
            assertSteadyAfterCut(samples, readFrom: 1.5, cut: 2, reading.rawValue)
            // A is at +12 dB right up to its own fade out.
            let a12 = level(samples, at: 1.99 - 1.5, seconds: 0.005) - level(samples, at: 2.5 - 1.5, seconds: 0.2)
            XCTAssertEqual(a12, 12, accuracy: 0.2, reading.rawValue)
        }
    }

    /// The 3 ms fades either side of a hard cut, which keep it from
    /// clicking, land on the cut.
    func testAHardCutFadesOutAndInOverThreeMilliseconds() async throws {
        let media = try TestMedia()
        try wav(media, "dc.wav", seconds: 12) { _ in 0.25 }
        let item = MediaItem(id: "med_dc", path: "dc.wav", kind: .audio, role: .other, duration: t(12), hasAudio: true)
        let a = Clip(id: "clip_a", content: .media(mediaID: item.id), start: .zero, duration: t(2))
        let b = Clip(id: "clip_b", content: .media(mediaID: item.id), start: t(2), duration: t(2), sourceStart: t(6))
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [a, b])], media: [item])
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        for reading in Reading.allCases {
            let samples = try await heard(built, from: 1.9, to: 2.1, by: reading)
            // A constant source, so every sample shows the gain it got.
            func gain(_ time: Double) -> Double { Double(samples[Int(((time - 1.9) * Double(Self.rate)).rounded())]) / 0.25 }
            XCTAssertEqual(gain(1.996), 1, accuracy: 0.001, reading.rawValue)
            XCTAssertEqual(gain(1.9985), 0.5, accuracy: 0.01, reading.rawValue)
            XCTAssertEqual(gain(2.0), 0, accuracy: 0.01, reading.rawValue)
            XCTAssertEqual(gain(2.0015), 0.5, accuracy: 0.01, reading.rawValue)
            XCTAssertEqual(gain(2.004), 1, accuracy: 0.001, reading.rawValue)
        }
    }

    /// A camera take normalised from -28 to -20 LUFS (+8 dB), keyframed to
    /// +16.3 dB right up to a cut, with music and sound effects on other
    /// tracks: Mike's case, where the next clip was too loud for 0.35 s.
    /// Two arrangements of the pool: before the fix the first put the next
    /// clip on the clip's own composition track (too loud) and the second
    /// on one a sound effect had left silent (too quiet, fading in).
    func testTheClipAfterACutPlaysAtItsOwnLevelInABusyPool() async throws {
        let media = try TestMedia()
        let cameraURL = try await media.movie("camera.mov", seconds: 12, draw: { TestMedia.fill($1, 0, 0, 0) }, sound: Self.tone(peakDB: -28))
        let camera = media.item("med_cam", "camera.mov", role: .camera, seconds: 12, audio: true)
        try wav(media, "bed.wav", seconds: 12) { i in Float(0.1 * sin(2 * Double.pi * 330 * Double(i) / 48_000)) }
        let bed = MediaItem(id: "med_bed", path: "bed.wav", kind: .audio, role: .music, duration: t(12), hasAudio: true)
        try wav(media, "whoosh.wav", seconds: 6) { i in Float(0.1 * sin(2 * Double.pi * 2_000 * Double(i) / 48_000)) }
        let whoosh = MediaItem(id: "med_sfx", path: "whoosh.wav", kind: .audio, role: .sfx, duration: t(6), hasAudio: true)
        let assets = try await measured(cameraURL, camera)

        func voice(_ id: String, start: Double, end: Double, source: Double, keys: [(Double, Double)] = []) -> Clip {
            var clip = Clip(id: id, content: .media(mediaID: camera.id), start: t(start), duration: t(end - start), sourceStart: t(source))
            clip.audio = AudioProperties(normalizeTo: -20)
            if !keys.isEmpty { clip.keyframes["audio.gainDB"] = gainKeyframes(keys) }
            return clip
        }
        func sound(_ id: String, _ item: MediaItem, start: Double, end: Double, gainDB: Double) -> Clip {
            var clip = Clip(id: id, content: .media(mediaID: item.id), start: t(start), duration: t(end - start))
            clip.audio = AudioProperties(gainDB: gainDB)
            return clip
        }
        let cut = 4.04
        // The clip before the cut rises to +16.3 dB and holds it to the cut.
        let before = voice("clip_hh", start: 1.0, end: cut, source: 5.96, keys: [(2.218, 0), (2.368, 16.3), (2.838, 16.3)])
        let after = voice("clip_ma", start: cut, end: 7.5, source: 1.083, keys: [(3.2, 0)])
        let arrangements: [(name: String, voice: [Clip], music: [Clip], sfx: [Clip])] = [
            ("voice first",
             [voice("clip_0", start: 0, end: 1.0, source: 0), before, after],
             [sound("clip_bed", bed, start: 0, end: 9, gainDB: -31)],
             [sound("clip_sfx1", whoosh, start: 0.5, end: 1.5, gainDB: -60), sound("clip_sfx2", whoosh, start: 3.8, end: 4.8, gainDB: -60)]),
            ("a sound effect ending at the cut",
             [voice("clip_0", start: 0.2, end: 1.0, source: 0), before, after],
             [sound("clip_bed", bed, start: 0.3, end: 9, gainDB: -31)],
             [sound("clip_sfx1", whoosh, start: 0, end: cut, gainDB: -60), sound("clip_sfx2", whoosh, start: 5, end: 6, gainDB: -60)])
        ]
        for arrangement in arrangements {
            let project = smallProject(video: [], audio: [
                Track(kind: .audio, name: "Voice", clips: arrangement.voice),
                Track(kind: .audio, name: "Music", clips: arrangement.music),
                Track(kind: .audio, name: "SFX", clips: arrangement.sfx)
            ], media: [camera, bed, whoosh])
            let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder, assets: assets))
            XCTAssertGreaterThanOrEqual(built.audioMix.inputParameters.count, 3, arrangement.name)
            for reading in Reading.allCases {
                let samples = try await heard(built, from: 3.5, to: 5.0, by: reading)
                assertSteadyAfterCut(samples, readFrom: 3.5, cut: cut, "\(arrangement.name), \(reading)")
            }
        }
    }

    // MARK: - Inside a clip

    /// Keyframed gain inside a clip follows its curve smoothly: a fast rise
    /// to +16 dB and a slow dip, checked every millisecond.
    func testKeyframedGainFollowsItsCurve() async throws {
        let media = try TestMedia()
        try wav(media, "dc.wav", seconds: 12) { _ in 0.05 }
        let item = MediaItem(id: "med_dc", path: "dc.wav", kind: .audio, role: .other, duration: t(12), hasAudio: true)
        var clip = Clip(id: "clip_k", content: .media(mediaID: item.id), start: .zero, duration: t(6))
        clip.keyframes["audio.gainDB"] = gainKeyframes([(1.0, 0), (1.15, 16), (2.0, 16), (4.0, -20), (5.0, -20)])
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [clip])], media: [item])
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        let envelope = RenderPlanner.plan(project, format: nil, assets: nil).audioSegments[0].envelope
        for reading in Reading.allCases {
            let samples = try await heard(built, from: 0.5, to: 5.5, by: reading)
            var worst = 0.0
            var previous: Double?
            var biggestStep = 0.0
            var time = 0.6
            while time < 5.4 {
                let heard = Double(samples[Int(((time - 0.5) * Double(Self.rate)).rounded())]) / 0.05
                let planned = gainAt(envelope, t(time))
                worst = max(worst, abs(20 * log10(heard / planned)))
                if let previous { biggestStep = max(biggestStep, abs(20 * log10(heard / previous))) }
                previous = heard
                time += 0.001
            }
            XCTAssertLessThan(worst, 0.05, "dB from the planned curve, \(reading)")
            // The fast rise is 16 dB in 150 ms: about 0.11 dB a millisecond.
            XCTAssertLessThan(biggestStep, 0.2, "dB in one millisecond, \(reading)")
        }
    }

    /// Mike's other case: a long voice clip, normalised up 8 dB, keyframed
    /// down from +24 dB to 0 dB just before he speaks, in a project with
    /// video and several audio tracks. The ramp used to land about 0.4 s
    /// late (1.0 per 25 ms from 40 times down to 2.5 takes almost a
    /// second), so his first syllables played 10 dB hot.
    func testAKeyframedRampInsideALongClipLandsOnTime() async throws {
        let media = try TestMedia()
        let cameraURL = try await media.movie("camera.mov", seconds: 14, draw: { TestMedia.fill($1, 0.2, 0.2, 0.2) }, sound: Self.tone(peakDB: -28))
        let camera = media.item("med_cam", "camera.mov", role: .camera, seconds: 14, audio: true)
        try await media.movie("screen.mov", seconds: 14, draw: { TestMedia.fill($1, 0, 0, 0.6) })
        let screen = media.item("med_scr", "screen.mov", role: .screen, seconds: 14)
        try wav(media, "bed.wav", seconds: 14) { i in Float(0.1 * sin(2 * Double.pi * 330 * Double(i) / 48_000)) }
        let bed = MediaItem(id: "med_bed", path: "bed.wav", kind: .audio, role: .music, duration: t(14), hasAudio: true)
        try wav(media, "whoosh.wav", seconds: 4) { i in Float(0.1 * sin(2 * Double.pi * 2_000 * Double(i) / 48_000)) }
        let whoosh = MediaItem(id: "med_sfx", path: "whoosh.wav", kind: .audio, role: .sfx, duration: t(4), hasAudio: true)
        let assets = try await measured(cameraURL, camera)

        var talk = Clip(id: "clip_talk", content: .media(mediaID: camera.id), start: t(0.5), duration: t(12), sourceStart: t(1))
        talk.audio = AudioProperties(normalizeTo: -20)
        // Clip times: +24 dB, down to 0 dB by 6.8 s (7.3 on the timeline).
        talk.keyframes["audio.gainDB"] = gainKeyframes([(2.0, 24), (6.4, 24), (6.8, 0), (10, 0)])
        var picture = Clip(id: "clip_pic", content: .media(mediaID: camera.id), start: t(0.5), duration: t(12), sourceStart: t(1))
        picture.linkGroup = "lnk_talk"
        talk.linkGroup = "lnk_talk"
        let project = smallProject(
            video: [
                Track(kind: .video, name: "Screen", clips: [Clip(id: "clip_scr", content: .media(mediaID: screen.id), start: .zero, duration: t(13))]),
                Track(kind: .video, name: "Camera", clips: [picture])
            ],
            audio: [
                Track(kind: .audio, name: "Voice", clips: [talk]),
                Track(kind: .audio, name: "Music", clips: [{
                    var clip = Clip(id: "clip_bed", content: .media(mediaID: bed.id), start: .zero, duration: t(13))
                    clip.audio = AudioProperties(gainDB: -40)
                    return clip
                }()]),
                Track(kind: .audio, name: "SFX", clips: [
                    Clip(id: "clip_sfx1", content: .media(mediaID: whoosh.id), start: t(1), duration: t(2), audio: AudioProperties(gainDB: -60)),
                    Clip(id: "clip_sfx2", content: .media(mediaID: whoosh.id), start: t(6.9), duration: t(1), audio: AudioProperties(gainDB: -60))
                ])
            ],
            media: [camera, screen, bed, whoosh]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder, assets: assets))
        XCTAssertGreaterThanOrEqual(built.audioMix.inputParameters.count, 3)
        XCTAssertGreaterThanOrEqual(built.composition.tracks(withMediaType: .video).count, 3)

        // Read from part way through the clip, as `tandem clip` does and as
        // the viewer does after a seek there.
        let from = 5.0
        let plan = RenderPlanner.plan(project, format: nil, assets: assets)
        let envelope = try XCTUnwrap(plan.audioSegments.first { $0.clipID == "clip_talk" }).envelope
        for reading in Reading.allCases {
            let samples = try await heard(built, from: from, to: 9.0, by: reading)
            let base = level(samples, at: 8.5 - from, seconds: 0.2) - 20 * log10(gainAt(envelope, t(8.5)))
            // Every millisecond against the keyframes.
            var worst = 0.0, worstAt = 0.0
            var time = 6.5
            while time < 8.0 {
                let heard = level(samples, at: time - from, seconds: 0.001)
                let planned = base + 20 * log10(gainAt(envelope, t(time + 0.0005)))
                if abs(heard - planned) > worst { worst = abs(heard - planned); worstAt = time }
                time += 0.001
            }
            XCTAssertLessThan(worst, 0.3, String(format: "dB from the keyframes, worst at %.3f s, %@", worstAt, reading.rawValue))
            // It's back to 0 dB (plus the normalising) at the keyframe, not later.
            let settled = level(samples, at: 7.3 - from, seconds: 0.01) - base
            XCTAssertEqual(settled, 20 * log10(gainAt(envelope, t(7.31))), accuracy: 0.3, reading.rawValue)
        }
    }

    // MARK: - Formats

    /// Clips from files in different audio formats on one timeline track:
    /// a camera's float PCM, a mono 16-bit WAV, mono AAC and stereo AAC,
    /// cut together, then music and a sound effect. A tapped composition
    /// track that changed format part way stalled the reader for good, so
    /// each format gets tracks of its own, and every cut lands right.
    func testSoundInDifferentFormatsCutTogetherReadsAndLevels() async throws {
        let media = try TestMedia()
        try await media.movie("camera.mov", seconds: 8, draw: { TestMedia.fill($1, 0, 0, 0) }, sound: Self.tone(peakDB: -20))
        let camera = media.item("med_cam", "camera.mov", role: .camera, seconds: 8, audio: true)
        try wav(media, "mono16.wav", seconds: 8, channels: 1, bits16: true, sample: Self.tone(peakDB: -20))
        try await aac(media, "mono.m4a", seconds: 8, channels: 1, sample: Self.tone(peakDB: -20))
        try await aac(media, "stereo.m4a", seconds: 8, channels: 2, sample: Self.tone(peakDB: -20))
        func audio(_ id: String, _ path: String) -> MediaItem {
            MediaItem(id: id, path: path, kind: .audio, role: .other, duration: t(8), hasAudio: true)
        }
        let mono16 = audio("med_m16", "mono16.wav"), mono = audio("med_mono", "mono.m4a"), stereo = audio("med_st", "stereo.m4a")
        // Each clip a different gain, so a level that carried over shows.
        let order: [(MediaItem, Double)] = [(camera, 6), (mono16, -6), (mono, 9), (stereo, 0), (camera, -3), (mono, 3), (mono16, 12), (stereo, -9)]
        var clips: [Clip] = []
        for (index, (item, gain)) in order.enumerated() {
            var clip = Clip(id: "clip_\(index)", content: .media(mediaID: item.id), start: t(Double(index)), duration: t(1), sourceStart: t(Double(index % 3) + 0.5))
            clip.audio = AudioProperties(gainDB: gain)
            clips.append(clip)
        }
        var bed = Clip(id: "clip_bed", content: .media(mediaID: stereo.id), start: .zero, duration: t(8))
        bed.audio = AudioProperties(gainDB: -60)
        var sfx = Clip(id: "clip_sfx", content: .media(mediaID: mono16.id), start: t(2.5), duration: t(3))
        sfx.audio = AudioProperties(gainDB: -60)
        let project = smallProject(video: [], audio: [
            Track(kind: .audio, name: "Voice", clips: clips),
            Track(kind: .audio, name: "Music", clips: [bed]),
            Track(kind: .audio, name: "SFX", clips: [sfx])
        ], media: [camera, mono16, mono, stereo])
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))

        // The whole timeline, and from part way into each clip, as review
        // clips start and as the viewer starts after a seek.
        let whole = try await mix(built, from: 0, to: 8)
        XCTAssertEqual(whole.count, 8 * Self.rate)
        for start in [0.5, 2.25, 3.6, 6.1] {
            let part = try await mix(built, from: start, to: start + 1.5)
            XCTAssertEqual(part.count, Int(1.5 * Double(Self.rate)), "from \(start) s")
            let viewer = try await viewerMix(built, from: start, to: start + 1.5)
            XCTAssertEqual(viewer.count, part.count, "the viewer from \(start) s")
            XCTAssertLessThanOrEqual(zip(viewer, part).map { abs($0 - $1) }.max() ?? 1, 1e-6, "the viewer plays what export reads, from \(start) s")
        }
        // Every clip at its own gain right after its cut: its file's level
        // plus the clip's gain. (Writing mono AAC from stereo takes 3 dB
        // off, so each file's level is read from the file.)
        var levels: [String: Double] = [:]
        for item in [camera, mono16, mono, stereo] {
            let decoded = try await decodeAudio(media.folder.appendingPathComponent(item.path))
            let left = stride(from: 0, to: decoded.count, by: 2).map { decoded[$0] }
            levels[item.id] = level(left, at: 1, seconds: 1)
        }
        for (index, (item, gain)) in order.enumerated() where index > 0 {
            let cut = Double(index)
            let expected = try XCTUnwrap(levels[item.id]) + gain
            for k in 0..<10 {
                let heard = level(whole, at: cut + 0.003 + Double(k) * 0.005, seconds: 0.005)
                XCTAssertEqual(heard, expected, accuracy: 0.5, "clip \(index), \(3 + 5 * k) ms after its cut")
            }
        }
    }

    // MARK: - Export and playback

    /// The same through a whole export (AAC and all), the way a review
    /// clip renders it.
    func testAnExportKeepsTheGainInsideTheClip() async throws {
        let media = try TestMedia()
        try wav(media, "tone.wav", seconds: 12, sample: Self.tone(peakDB: -20))
        let item = MediaItem(id: "med_tone", path: "tone.wav", kind: .audio, role: .other, duration: t(12), hasAudio: true)
        var a = Clip(id: "clip_a", content: .media(mediaID: item.id), start: .zero, duration: t(2))
        a.keyframes["audio.gainDB"] = gainKeyframes([(1.0, 0), (1.2, 12), (1.6, 12)])
        let b = Clip(id: "clip_b", content: .media(mediaID: item.id), start: t(2), duration: t(3), sourceStart: t(5))
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [a, b])], media: [item])
        let out = media.folder.appendingPathComponent("review.mp4")
        // No master, so the file plays the mix as it is.
        let preset = ExportPreset(name: "Test", codec: .h264, videoBitrate: 2_000_000, audioBitrate: 320_000, loudnessTarget: nil, truePeakCeiling: nil, range: TimeRange(start: t(1.5), end: t(3)))
        _ = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset, output: out).run()
        let decoded = try await decodeAudio(out)
        let samples = stride(from: 0, to: decoded.count, by: 2).map { decoded[$0] }
        assertSteadyAfterCut(samples, readFrom: 1.5, cut: 2)
    }

    /// The viewer's player shows the picture only. Its sound comes from
    /// `ViewerAudio`, which reads the mix through taps of its own with each
    /// track's gain, and no input has volume ramps for AVFoundation to lag.
    @MainActor
    func testTheViewerReadsItsSoundThroughTheGainTaps() async throws {
        let media = try TestMedia()
        try wav(media, "tone.wav", seconds: 12, sample: Self.tone(peakDB: -20))
        let item = MediaItem(id: "med_tone", path: "tone.wav", kind: .audio, role: .other, duration: t(12), hasAudio: true)
        var a = Clip(id: "clip_a", content: .media(mediaID: item.id), start: .zero, duration: t(2))
        a.audio = AudioProperties(gainDB: 12)
        let b = Clip(id: "clip_b", content: .media(mediaID: item.id), start: t(2), duration: t(3), sourceStart: t(5))
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [a, b])], media: [item])
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder, useProxies: true))
        let player = built.makePlayerItem()
        XCTAssertNil(player.audioMix)
        XCTAssertEqual((player.asset as? AVComposition)?.tracks(withMediaType: .audio).count, 0, "the player plays no sound of its own")
        XCTAssertFalse(built.composition.tracks(withMediaType: .audio).isEmpty)

        let mix = ViewerMix(built)
        XCTAssertEqual(mix.tracks.map(\.id), built.audioMix.inputParameters.map(\.trackID))
        XCTAssertEqual(mix.tracks.map(\.gain), built.audioGains)
        let (reader, output) = try XCTUnwrap(mix.reader(from: 0, to: 48_000))
        defer { reader.cancelReading() }
        let inputs = try XCTUnwrap(output.audioMix).inputParameters
        XCTAssertFalse(inputs.isEmpty)
        XCTAssertEqual(inputs.filter { $0.audioTapProcessor == nil }.count, 0, "inputs without a gain tap")
        let ramped = inputs.filter { input in
            stride(from: 0.0, through: 5, by: 0.25).contains { time in
                var start: Float = 0, end: Float = 0
                var range = CMTimeRange()
                return input.getVolumeRamp(for: t(time).cmTime, startVolume: &start, endVolume: &end, timeRange: &range)
            }
        }
        XCTAssertEqual(ramped.count, 0, "inputs with volume ramps")
        // The taps have A's +12 dB up to its fade out and B's 0 dB after the cut.
        XCTAssertEqual(mix.tracks.map { $0.gain.gain(at: 1.99) }.max() ?? 0, Float(pow(10, 12.0 / 20)), accuracy: 0.001)
        XCTAssertEqual(mix.tracks.map { $0.gain.gain(at: 2.01) }.max() ?? 0, 1, accuracy: 0.001)
    }
}
