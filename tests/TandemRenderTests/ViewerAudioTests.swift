import AVFoundation
import CoreAudio
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// The viewer's sound, read ahead of time (`ViewerAudio`): the mix from
/// the playhead, every track from its first sample, exactly what export
/// reads, and started with the picture at the same host time on the same
/// clock. Nothing here makes a sound: the renderer is muted.
@MainActor
final class ViewerAudioTests: XCTestCase {
    static let rate = 48_000

    /// A steady tone on every channel.
    static func tone(_ hz: Double, peakDB: Double = -20) -> (Int) -> Float {
        let peak = pow(10, peakDB / 20)
        return { i in Float(peak * sin(2 * Double.pi * hz * Double(i) / 48_000)) }
    }

    /// A float WAV with `sample(i)` on both channels.
    @discardableResult
    func wav(_ media: TestMedia, _ name: String, seconds: Double, sample: (Int) -> Float) throws -> URL {
        let url = media.folder.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let v = sample(i)
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        try file.write(from: buffer)
        return url
    }

    /// A take (picture and a 500 Hz tone, linked), music at 1 kHz and a
    /// sound effect at 2.5 kHz, all from 0 to `seconds`: three composition
    /// audio tracks, each with its own frequency.
    func threeTracks(_ media: TestMedia, seconds: Double = 10) async throws -> BuiltComposition {
        try await media.movie("camera.mov", seconds: seconds, draw: { TestMedia.fill($1, 0.3, 0.3, 0.3) }, sound: Self.tone(500))
        try wav(media, "music.wav", seconds: seconds, sample: Self.tone(1_000))
        try wav(media, "sfx.wav", seconds: seconds, sample: Self.tone(2_500))
        let camera = media.item("med_cam", "camera.mov", role: .camera, seconds: seconds, audio: true)
        let music = MediaItem(id: "med_music", path: "music.wav", kind: .audio, role: .music, duration: t(seconds), hasAudio: true)
        let sfx = MediaItem(id: "med_sfx", path: "sfx.wav", kind: .audio, role: .sfx, duration: t(seconds), hasAudio: true)
        var picture = Clip(id: "clip_pic", content: .media(mediaID: camera.id), start: .zero, duration: t(seconds))
        var voice = Clip(id: "clip_voice", content: .media(mediaID: camera.id), start: .zero, duration: t(seconds))
        picture.linkGroup = "lnk_take"
        voice.linkGroup = "lnk_take"
        let project = smallProject(
            video: [Track(kind: .video, name: "Camera", clips: [picture])],
            audio: [
                Track(kind: .audio, name: "Voice", clips: [voice]),
                Track(kind: .audio, name: "Music", clips: [Clip(id: "clip_music", content: .media(mediaID: music.id), start: .zero, duration: t(seconds))]),
                Track(kind: .audio, name: "SFX", clips: [Clip(id: "clip_sfx", content: .media(mediaID: sfx.id), start: .zero, duration: t(seconds))])
            ],
            media: [camera, music, sfx]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder, useProxies: true))
        XCTAssertEqual(built.audioMix.inputParameters.count, 3, "three composition audio tracks")
        return built
    }

    /// The left channel of the mix from `start` to `end`, read the way
    /// export reads it.
    func exportMix(_ built: BuiltComposition, from start: Double, to end: Double) async throws -> [Float] {
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let job = Unchecked((built.composition, tracks, built.audioMix))
        let range = CMTimeRange(start: t(start).cmTime, end: t(end).cmTime)
        return try await withCheckedThrowingContinuation { continuation in
            Thread {
                let (asset, tracks, audioMix) = job.value
                do {
                    let reader = try AVAssetReader(asset: asset)
                    reader.timeRange = range
                    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: AudioBuffers.readerSettings)
                    output.audioMix = audioMix
                    output.audioTimePitchAlgorithm = .spectral
                    reader.add(output)
                    reader.startReading()
                    var left: [Float] = []
                    while let buffer = output.copyNextSampleBuffer() {
                        let samples = AudioBuffers.samples(in: buffer)
                        left += stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
                    }
                    continuation.resume(returning: left)
                } catch {
                    continuation.resume(throwing: error)
                }
            }.start()
        }
    }

    /// Everything the renderer is given, in order.
    final class Enqueued: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [(frame: Int, samples: [Float])] = []

        func add(_ buffer: CMSampleBuffer) {
            let frame = ViewerMix.frame(of: buffer)
            let samples = AudioBuffers.samples(in: buffer)
            lock.withLock { buffers.append((frame, samples)) }
        }

        var all: [(frame: Int, samples: [Float])] { lock.withLock { buffers } }

        /// The first frame, and the left channel of everything after it
        /// as one run (checking each buffer follows the last).
        func left(file: StaticString = #filePath, line: UInt = #line) -> (first: Int, samples: [Float]) {
            let all = self.all
            guard let first = all.first?.frame else { return (0, []) }
            var left: [Float] = []
            for buffer in all {
                XCTAssertEqual(buffer.frame, first + left.count, "buffers follow on with no gap or overlap", file: file, line: line)
                left += stride(from: 0, to: buffer.samples.count, by: 2).map { buffer.samples[$0] }
            }
            return (first, left)
        }
    }

    func prime(_ audio: ViewerAudio, at seconds: Double, reverse: Bool = false) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            audio.prime(at: t(seconds), reverse: reverse) { done.resume() }
        }
    }

    /// Amplitude of a sine at `hz` in `samples`, which hold whole cycles.
    func amplitude(_ samples: ArraySlice<Float>, hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, x) in samples.enumerated() {
            let phase = 2 * Double.pi * hz * Double(i) / 48_000
            re += Double(x) * cos(phase)
            im += Double(x) * sin(phase)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(samples.count)
    }

    func hasAudioOutput() -> Bool {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr && device != kAudioObjectUnknown
    }

    // MARK: - What it plays

    /// Primed after a seek, the renderer holds the mix from the playhead,
    /// sample for sample what export reads, and every track is in it from
    /// the first sample: AVPlayer with taps brought tracks after the first
    /// in about 0.1 s late.
    func testThePrimedSoundIsTheMixFromThePlayheadWithEveryTrack() async throws {
        let media = try TestMedia()
        let built = try await threeTracks(media)
        let audio = ViewerAudio(muted: true)
        defer { audio.invalidate() }
        let enqueued = Enqueued()
        audio.observeEnqueues(enqueued.add)
        audio.load(built)
        let started = ProcessInfo.processInfo.systemUptime
        await prime(audio, at: 4.25)
        let primed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(primed, 0.25, "queued a quarter of a second in \(primed) s")
        XCTAssertTrue(audio.isReady(at: t(4.25), reverse: false))
        XCTAssertFalse(audio.isReady(at: t(4.3), reverse: false))
        XCTAssertFalse(audio.isReady(at: t(4.25), reverse: true))

        let (first, left) = enqueued.left()
        XCTAssertEqual(first, 204_000, "from the playhead, to the sample")
        XCTAssertGreaterThanOrEqual(left.count, ViewerAudio.readyFrames)
        // Each track's tone at its level in the first 10 ms (whole cycles
        // of each), and still there a moment later.
        let peak = pow(10, -20.0 / 20)
        for hz in [500.0, 1_000, 2_500] {
            for start in [0, 4_800] {
                let heard = amplitude(left[start..<(start + 480)], hz: hz)
                XCTAssertEqual(20 * log10(heard / peak), 0, accuracy: 0.5, "\(hz) Hz, \(start / 48) ms in")
            }
        }
        // Exactly what export reads from the same place.
        let export = try await exportMix(built, from: 4.25, to: 4.25 + Double(left.count) / 48_000)
        XCTAssertEqual(export.count, left.count)
        XCTAssertLessThanOrEqual(zip(left, export).map { abs($0 - $1) }.max() ?? 1, 1e-6)
    }

    /// Played backwards, the renderer gets the mix reversed: what export
    /// reads up to the playhead, back to front, across the blocks it's
    /// read in.
    func testBackwardsItGetsTheMixReversed() async throws {
        let media = try TestMedia()
        try wav(media, "chirp.wav", seconds: 10) { i in
            // A rising tone, so the order of the samples matters.
            let s = Double(i) / 48_000
            return Float(0.1 * sin(2 * Double.pi * (200 * s + 40 * s * s)))
        }
        let item = MediaItem(id: "med_chirp", path: "chirp.wav", kind: .audio, role: .music, duration: t(10), hasAudio: true)
        var clip = Clip(id: "clip_chirp", content: .media(mediaID: item.id), start: .zero, duration: t(10))
        clip.keyframes["audio.gainDB"] = [Keyframe(time: t(2), value: .number(0), interpolation: .linear), Keyframe(time: t(5), value: .number(-12), interpolation: .linear)]
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Music", clips: [clip])], media: [item])
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))

        // The stream, five seconds back from 6 s: blocks of two seconds.
        let sound = ReverseSound(ViewerMix(built), from: ViewerAudio.frame(of: t(6)))
        var backwards: [Float] = []
        var expectedFrame = 0
        while backwards.count < 5 * 48_000, let chunk = sound.next() {
            XCTAssertEqual(chunk.frame, expectedFrame)
            expectedFrame += chunk.samples.count / 2
            backwards += stride(from: 0, to: chunk.samples.count, by: 2).map { chunk.samples[$0] }
        }
        let forwards = try await exportMix(built, from: 1, to: 6)
        XCTAssertEqual(backwards.count, forwards.count)
        XCTAssertLessThanOrEqual(zip(backwards, forwards.reversed()).map { abs($0 - $1) }.max() ?? 1, 1e-6, "the mix, back to front")
        // It ends at the start of the timeline.
        let rest = ReverseSound(ViewerMix(built), from: ViewerAudio.frame(of: t(0.5)))
        var frames = 0
        while let chunk = rest.next() { frames += chunk.samples.count / 2 }
        XCTAssertEqual(frames, 24_000)

        // And primed backwards, the renderer gets it from the playhead.
        let audio = ViewerAudio(muted: true)
        defer { audio.invalidate() }
        let enqueued = Enqueued()
        audio.observeEnqueues(enqueued.add)
        audio.load(built)
        await prime(audio, at: 6, reverse: true)
        XCTAssertTrue(audio.isReady(at: t(6), reverse: true))
        let (first, left) = enqueued.left()
        XCTAssertEqual(first, 0, "the synchronizer counts from where reverse play starts")
        XCTAssertLessThanOrEqual(zip(left, forwards.reversed()).map { abs($0 - $1) }.max() ?? 1, 1e-6)
    }

    /// The sound runs to the end of the timeline, in silence where there's
    /// none, so the renderer never runs dry before the picture ends; a
    /// timeline with no sound at all plays silence.
    func testTheSoundRunsToTheEndOfTheTimeline() async throws {
        let media = try TestMedia()
        try wav(media, "short.wav", seconds: 1, sample: Self.tone(1_000))
        try await media.movie("picture.mov", seconds: 3, draw: { TestMedia.fill($1, 0, 0, 0) })
        let sound = MediaItem(id: "med_s", path: "short.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        let picture = media.item("med_p", "picture.mov", seconds: 3)
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [Clip(id: "clip_p", content: .media(mediaID: picture.id), start: .zero, duration: t(3))])],
            audio: [Track(kind: .audio, name: "SFX", clips: [Clip(id: "clip_s", content: .media(mediaID: sound.id), start: t(0.5), duration: t(1))])],
            media: [sound, picture]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        let stream = ForwardSound(ViewerMix(built), from: ViewerAudio.frame(of: t(0.25)))
        var left: [Float] = []
        while let chunk = stream.next() { left += stride(from: 0, to: chunk.samples.count, by: 2).map { chunk.samples[$0] } }
        XCTAssertEqual(left.count, Int(2.75 * 48_000), "to the end of the timeline")
        XCTAssertEqual(left[0..<12_000].map { abs($0) }.max(), 0, "silence before the sound")
        XCTAssertGreaterThan(left[24_000..<48_000].map { abs($0) }.max() ?? 0, 0.09, "the sound")
        XCTAssertEqual(left[(12_000 + 48_000 + 480)...].map { abs($0) }.max(), 0, "silence after it")

        let silent = smallProject(video: [Track(kind: .video, name: "V1", clips: [Clip(id: "clip_p", content: .media(mediaID: picture.id), start: .zero, duration: t(3))])], media: [picture])
        let quiet = ForwardSound(ViewerMix(try await CompositionBuilder.build(RenderContext(project: silent, folder: media.projectFolder))), from: 0)
        var frames = 0
        while let chunk = quiet.next() {
            XCTAssertEqual(chunk.samples.map { abs($0) }.max(), 0)
            frames += chunk.samples.count / 2
        }
        XCTAssertEqual(frames, 3 * 48_000)
    }

    // MARK: - With the picture

    /// The viewer's player and its sound, as the viewer sets them up.
    struct Rig {
        let audio: ViewerAudio
        let player: AVPlayer
        let item: AVPlayerItem
        let output: AVPlayerItemVideoOutput
        let enqueued: Enqueued

        var audioClock: CMTimebase { audio.synchronizer.timebase }

        /// The picture's and the sound's times at the same host time.
        func times(atHost host: CMTime) -> (picture: Double, sound: Double) {
            (CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: item.timebase!).seconds,
             CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: audioClock).seconds)
        }

        func invalidate() {
            player.pause()
            player.replaceCurrentItem(with: nil)
            audio.invalidate()
        }
    }

    func rig(_ built: BuiltComposition, at seconds: Double, reverse: Bool = false) async throws -> Rig {
        let audio = ViewerAudio(muted: true)
        let enqueued = Enqueued()
        audio.observeEnqueues(enqueued.add)
        audio.load(built)
        let item = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.sourceClock = audio.clock
        for _ in 0..<500 where item.status != .readyToPlay { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        await player.seek(to: t(seconds).cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        await prime(audio, at: seconds, reverse: reverse)
        return Rig(audio: audio, player: player, item: item, output: output, enqueued: enqueued)
    }

    /// Starts the sound at `seconds` as the viewer does, and the picture
    /// at the host time the sound says it begins, which it returns.
    @discardableResult
    func start(_ rig: Rig, at seconds: Double, rate: Double = 1) async -> CMTime {
        await withCheckedContinuation { (done: CheckedContinuation<CMTime, Never>) in
            rig.audio.start(rate: rate, at: t(seconds)) { host in
                rig.player.setRate(Float(rate), time: t(seconds).cmTime, atHostTime: host)
                done.resume(returning: host)
            }
        }
    }

    /// Seconds from `since` until `moved` is true, polling every 0.5 ms.
    func waitUntil(since: Double, timeout: Double = 2, _ moved: () -> Bool) -> Double {
        while ProcessInfo.processInfo.systemUptime - since < timeout {
            if moved() { return ProcessInfo.processInfo.systemUptime - since }
            usleep(500)
        }
        return .infinity
    }

    /// A flash on frame 45 and a beep starting at 1.5 s, with music under
    /// it: the picture shows the flash when the sound reaches the beep,
    /// both start together about 0.13 s after play, and they stay within a
    /// millisecond of each other as they play.
    func testThePictureAndTheSoundStartTogetherAndStayInStep() async throws {
        try XCTSkipUnless(hasAudioOutput(), "no audio output device")
        try skipTimingSensitiveTestOnCI()
        let media = try TestMedia()
        try await media.movie("flash.mov", seconds: 8, draw: { frame, context in
            TestMedia.fill(context, frame == 45 ? 1 : 0, frame == 45 ? 1 : 0, frame == 45 ? 1 : 0)
        }, sound: { i in
            (72_000..<74_400).contains(i) ? Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i - 72_000) / 48_000)) : 0
        })
        try wav(media, "music.wav", seconds: 8, sample: Self.tone(300, peakDB: -60))
        let take = media.item("med_flash", "flash.mov", role: .camera, seconds: 8, audio: true)
        let music = MediaItem(id: "med_music", path: "music.wav", kind: .audio, role: .music, duration: t(8), hasAudio: true)
        var picture = Clip(id: "clip_pic", content: .media(mediaID: take.id), start: .zero, duration: t(8))
        var sound = Clip(id: "clip_sound", content: .media(mediaID: take.id), start: .zero, duration: t(8))
        picture.linkGroup = "lnk"
        sound.linkGroup = "lnk"
        let project = smallProject(
            video: [Track(kind: .video, name: "Camera", clips: [picture])],
            audio: [Track(kind: .audio, name: "Voice", clips: [sound]), Track(kind: .audio, name: "Music", clips: [Clip(id: "clip_m", content: .media(mediaID: music.id), start: .zero, duration: t(8))])],
            media: [take, music]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder, useProxies: true))
        let rig = try await rig(built, at: 0.5)
        defer { rig.invalidate() }

        // The output has been kept awake since the prime, as the viewer
        // keeps it, so this is a start with it running.
        try await Task.sleep(nanoseconds: 300_000_000)
        let pressed = CMClockGetTime(CMClockGetHostTimeClock())
        let host = await start(rig, at: 0.5)
        XCTAssertLessThan((host - pressed).seconds, 0.16, "it starts as quickly as AVPlayer did before the gain taps")
        let since = ProcessInfo.processInfo.systemUptime
        let pictureMoved = waitUntil(since: since) { CMTimebaseGetTime(rig.item.timebase!).seconds > 0.5005 }
        let soundMoved = waitUntil(since: since) { CMTimebaseGetTime(rig.audioClock).seconds > 0.5005 }
        XCTAssertEqual(pictureMoved, soundMoved, accuracy: 0.003, "together")
        let both = rig.times(atHost: host)
        XCTAssertEqual(both.picture, 0.5, accuracy: 0.0005)
        XCTAssertEqual(both.sound, 0.5, accuracy: 0.0005)

        // When the sound reaches the beep, the picture is on the flash: the
        // frames the player hands out, watched as they come, and where the
        // sound is when the flash is due on screen.
        let beepAt = CMSyncConvertTime(CMTime(value: 72_000, timescale: 48_000), from: rig.audioClock, to: CMClockGetHostTimeClock())
        XCTAssertEqual(rig.times(atHost: beepAt).picture, 1.5, accuracy: 0.001)
        var flashShown: (frame: Double, sound: Double)?
        let watching = ProcessInfo.processInfo.systemUptime
        while flashShown == nil, ProcessInfo.processInfo.systemUptime - watching < 1.6 {
            let host = CMClockGetTime(CMClockGetHostTimeClock())
            let itemTime = rig.output.itemTime(forHostTime: host.seconds)
            var shown = CMTime.invalid
            if rig.output.hasNewPixelBuffer(forItemTime: itemTime), let pixels = rig.output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shown),
               Bitmap(CIImage(cvPixelBuffer: pixels), size: built.renderSize).luma(160, 90) > 200 {
                let due = CMSyncConvertTime(shown, from: rig.item.timebase!, to: CMClockGetHostTimeClock())
                flashShown = (shown.seconds, rig.times(atHost: due).sound)
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let flash = try XCTUnwrap(flashShown, "the player showed the flash")
        XCTAssertEqual(flash.frame, 1.5, accuracy: 0.001, "the flash is frame 45")
        XCTAssertEqual(flash.sound, 1.5, accuracy: 0.001, "the sound is at the beep when the flash is due")
        try await Task.sleep(nanoseconds: 200_000_000)
        // The beep is where it should be in what the renderer was given.
        let (first, left) = rig.enqueued.left()
        XCTAssertEqual(first, 24_000)
        let onset = try XCTUnwrap(left.firstIndex { abs($0) > 0.01 }, "the renderer has the beep") + first
        XCTAssertEqual(onset, 72_001, accuracy: 2, "the beep starts at 1.5 s")

        // In step all the way, sampled through five seconds of play.
        var worst = 0.0
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let now = rig.times(atHost: CMClockGetTime(CMClockGetHostTimeClock()))
            worst = max(worst, abs(now.picture - now.sound))
        }
        XCTAssertLessThan(worst, 0.001, "seconds apart at worst")
        XCTAssertTrue(CMTimebaseGetTime(rig.item.timebase!).seconds > 6, "it played")
    }

    /// Paused, the picture stops and the sound is primed again from where
    /// it stopped, so playing on starts both there together. A change of
    /// speed keeps them together, as does going on again at 1x.
    func testPausingAndChangingSpeedKeepThemTogether() async throws {
        try XCTSkipUnless(hasAudioOutput(), "no audio output device")
        try skipTimingSensitiveTestOnCI()
        let media = try TestMedia()
        let built = try await threeTracks(media, seconds: 20)
        let rig = try await rig(built, at: 2)
        defer { rig.invalidate() }
        await start(rig, at: 2)
        try await Task.sleep(nanoseconds: 600_000_000)

        // Pause: the picture stops at once, and the sound is primed there.
        rig.player.pause()
        let at = Time(cmTime: rig.player.currentTime())
        XCTAssertTrue(rig.audio.isPlaying)
        let pausing = ProcessInfo.processInfo.systemUptime
        await prime(rig.audio, at: at.seconds)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - pausing, 0.25, "primed again")
        XCTAssertFalse(rig.audio.isPlaying)
        XCTAssertTrue(rig.audio.isReady(at: at, reverse: false))
        XCTAssertEqual(rig.audio.time.seconds, at.seconds, accuracy: 0.0005)
        XCTAssertEqual(CMTimebaseGetTime(rig.item.timebase!).seconds, at.seconds, accuracy: 0.003)

        // On again, then twice as fast, then 8x, then 1x.
        let resumed = await start(rig, at: at.seconds)
        try await Task.sleep(nanoseconds: 300_000_000)
        let there = rig.times(atHost: resumed)
        XCTAssertEqual(there.sound, at.seconds, accuracy: 0.0005)
        XCTAssertEqual(there.picture, at.seconds, accuracy: 0.0005)
        for speed in [2.0, 8, 1] {
            let change = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: ViewerAudio.startLead, preferredTimescale: 1_000_000_000)
            let then = Time(cmTime: CMSyncConvertTime(change, from: CMClockGetHostTimeClock(), to: rig.item.timebase!))
            rig.audio.start(rate: speed, at: then, hostTime: change)
            rig.player.setRate(Float(speed), time: then.cmTime, atHostTime: change)
            try await Task.sleep(nanoseconds: 500_000_000)
            let now = rig.times(atHost: CMClockGetTime(CMClockGetHostTimeClock()))
            XCTAssertEqual(now.picture, now.sound, accuracy: 0.001, "at \(speed)x")
            XCTAssertEqual(CMTimebaseGetRate(rig.audioClock), speed, accuracy: 0.001)
        }
        XCTAssertGreaterThan(rig.audio.time.seconds, at.seconds + 4, "it played on")
    }
}
