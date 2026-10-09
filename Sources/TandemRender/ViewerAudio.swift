import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import TandemCore

/// The viewer's sound, read ahead of time instead of in real time.
///
/// An AVPlayer playing the mix with its gain taps (`GainTap`) runs each
/// tapped track's sound through the taps in real time, about 0.4 s ahead
/// of what's heard, and only once playing starts: play took about 0.5 s to
/// start after a seek or an edit, and tracks after the first joined about
/// 0.1 s late, missing that much sound. Here the same mix is read by an
/// `AVAssetReader` with the same taps, export's path, which reads far
/// faster than real time (the first 8192 frames come in about 10 ms), into
/// an `AVSampleBufferAudioRenderer`. While the viewer is paused the sound
/// from the playhead is already waiting in the renderer, so play only has
/// to start a clock, and every track's sound is in it from the first
/// sample.
///
/// The viewer's players show the picture only (`makePlayerItem`), on the
/// same clock as this (`clock`, the output device's). A start lets the
/// synchronizer choose when the sound begins, as soon as the output can
/// play it, and the picture starts at that host time; a change of speed
/// sets both for the same host time. They stay in step to well under a
/// millisecond. Like AVPlayer, it keeps the output device running for a
/// while after it plays or queues sound, so a start doesn't wait for the
/// device to wake.
///
/// Played backwards, the synchronizer still runs forwards (it can't do
/// otherwise): its time counts from where reverse play started, and the
/// sound is read in blocks going back from there, each reversed. AVPlayer
/// played the composition backwards with its sound reversed too.
///
/// The synchronizer holds up whoever changes its rate while it plays, for
/// 30 to 40 ms as the output stops, so it's told what to do on a queue of
/// its own and the methods here return at once. Pausing primes again from
/// where the picture stopped rather than trusting what the renderer kept.
/// Use it from one thread; the viewer uses the main one. The renderer is
/// fed on a queue of each prime's own, so a reader that stalls holds up
/// nothing but itself.
public final class ViewerAudio: @unchecked Sendable {
    /// How far ahead of now a change of speed is set for, in seconds, and
    /// a start when the synchronizer can't say when it will begin (no
    /// output device). Asked to start, it begins about 0.13 s later with
    /// the output running, and about 0.2 s when the output has to wake.
    public static let startLead = 0.1

    /// Sound queued before a prime counts as ready, in frames (a quarter
    /// of a second). The renderer takes about a second while paused, and
    /// the rest follows while the start's lead runs.
    static let readyFrames = 12_000

    /// The default output device's clock, which the synchronizer runs on
    /// while it plays. The viewer's players run on it too, so the picture
    /// can't drift from the sound. Nil if Core Media can't make one.
    public let clock: CMClock?

    /// Where the sound waiting in the renderer starts, with nothing
    /// moving: `start` can begin there at once. Nil while playing, before
    /// a prime has queued enough, and after the mix changes.
    public private(set) var readyAt: (time: Time, reverse: Bool)?
    public private(set) var isPlaying = false
    /// Called on the main queue when the renderer throws away what it was
    /// given (an output device change, say): what's ready has gone, so
    /// prime again, or start again from where the playhead is.
    public var onInterruption: (() -> Void)?

    let synchronizer = AVSampleBufferRenderSynchronizer()
    /// `TANDEM_MUTED=1`, or a test: it plays, silently.
    public let muted: Bool
    /// The device it plays to, nil for the system's default output.
    private let outputDeviceUID: String?
    private let format: CMAudioFormatDescription?
    private var mix: ViewerMix?
    private var reverse = false
    /// Played backwards, the timeline frame the synchronizer's zero is.
    private var origin = 0
    private var primes = 0
    /// Once invalidated it neither primes nor plays.
    private var invalidated = false
    /// The prime under way, and who's waiting for it.
    private var priming: (time: Time, reverse: Bool)?
    private var waiting: [() -> Void] = []
    /// Where the synchronizer is told what to do, in order.
    private let control = DispatchQueue(label: "com.mikerosoft.tandem.viewer-audio.control", qos: .userInteractive)
    /// Only touched on `control`.
    private var observers: [NSObjectProtocol] = []
    private var saidRendererFailed = false

    /// Keeps the output device awake between plays.
    private let output = OutputHold()

    private let lock = NSLock()
    /// The renderer, replaced if it fails. Guarded by `lock`.
    private var renderer: AVSampleBufferAudioRenderer
    /// The feed whose sound the renderer is playing. Guarded by `lock`.
    private var feed: Feed?
    /// Tests see every buffer as it's enqueued, on the feed's queue.
    private var enqueueObserver: ((CMSampleBuffer) -> Void)?

    public convenience init(muted: Bool = false) {
        self.init(muted: muted, outputDeviceUID: nil)
    }

    /// Tests play to a device that isn't there, as on a Mac with none.
    init(muted: Bool, outputDeviceUID: String?) {
        self.muted = muted
        self.outputDeviceUID = outputDeviceUID
        var made: CMClock?
        CMAudioDeviceClockCreate(allocator: kCFAllocatorDefault, deviceUID: nil, clockOut: &made)
        clock = made
        format = try? AudioBuffers.formatDescription()
        renderer = Self.makeRenderer(muted: muted, outputDeviceUID: outputDeviceUID)
        synchronizer.addRenderer(renderer)
        control.sync { observe(renderer) }
    }

    deinit {
        // Not `invalidate`: the last reference can go on the control queue,
        // and waiting for that queue there would never end.
        synchronizer.rate = 0
        retireFeed()
        output.release()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private static func makeRenderer(muted: Bool, outputDeviceUID: String?) -> AVSampleBufferAudioRenderer {
        let renderer = AVSampleBufferAudioRenderer()
        // Speed changes keep their pitch, as they did in AVPlayer.
        renderer.audioTimePitchAlgorithm = .spectral
        renderer.isMuted = muted
        if let outputDeviceUID { renderer.audioOutputDeviceUniqueID = outputDeviceUID }
        return renderer
    }

    /// Stops and lets go of the renderer's sound, waiting for the
    /// synchronizer to stop. It can't play after this.
    public func invalidate() {
        invalidated = true
        forgetPrime()
        readyAt = nil
        isPlaying = false
        control.sync {
            synchronizer.rate = 0
            retireFeed()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }
        output.release()
    }

    // MARK: - What to play

    /// The mix to read from the next prime on. Nil plays silence.
    public func load(_ built: BuiltComposition?) {
        mix = built.map(ViewerMix.init)
        readyAt = nil
        forgetPrime()
    }

    /// Stops, throws away what's queued and queues the sound from `time`,
    /// forwards or backwards, ready for `start`. `ready` runs on the main
    /// queue once a quarter of a second is queued (or all there is), unless
    /// another prime, a load or a stop comes first. Asked again for the
    /// same place while a prime is under way, it waits for that one.
    public func prime(at time: Time, reverse: Bool, ready: @escaping () -> Void = {}) {
        guard !invalidated else { return }
        if let priming, priming.reverse == reverse, Self.frame(of: priming.time) == Self.frame(of: time) {
            waiting.append(ready)
            return
        }
        primes += 1
        let prime = primes
        priming = (time, reverse)
        waiting = [ready]
        readyAt = nil
        isPlaying = false
        self.reverse = reverse
        origin = Self.frame(of: time)
        let position = position(of: time)
        let start = origin
        let mix = self.mix ?? ViewerMix.silence(until: start)
        let feed = Feed(readyFrames: Self.readyFrames) {
            reverse ? ReverseSound(mix, from: start) as ViewerSound : ForwardSound(mix, from: start)
        }
        feed.onReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.primes == prime else { return }
                self.readyAt = (time, reverse)
                let waiting = self.waiting
                self.forgetPrime()
                for ready in waiting { ready() }
            }
        }
        control.async { [weak self] in
            guard let self else { return }
            synchronizer.setRate(0, time: position)
            replaceRendererIfFailed()
            install(feed)
        }
        output.hold()
        watchForFailure(of: feed, prime: prime)
    }

    /// A renderer with no output to play to takes one buffer, fails and
    /// never asks for more, so the prime would never be ready and play
    /// would never start. Until the prime is ready, this looks every
    /// quarter of a second, and if the renderer has failed, play starts,
    /// silently.
    private func watchForFailure(of feed: Feed, prime: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, primes == prime, readyAt == nil else { return }
            if rendererFailed {
                feed.queue.async { feed.finished() }
            } else {
                watchForFailure(of: feed, prime: prime)
            }
        }
    }

    private var rendererFailed: Bool {
        lock.withLock { renderer.status == .failed }
    }

    /// Whether `start` can begin at `time` without priming first.
    public func isReady(at time: Time, reverse: Bool) -> Bool {
        guard let readyAt, readyAt.reverse == reverse else { return false }
        return abs(Self.frame(of: readyAt.time) - Self.frame(of: time)) <= 1
    }

    // MARK: - Transport

    /// Plays at `rate` (negative backwards, which must match the prime)
    /// from `time`, as soon as the output can, and calls `started` on the
    /// main queue with the host time it reaches `time` at, so the picture
    /// starts then too: about 0.13 s from now with the output running.
    /// The synchronizer chooses that time itself, leaving the output long
    /// enough to start that the first sample is heard (a fixed 0.1 s
    /// wasn't, measured: woken from idle the output took 0.1 s more).
    /// Nothing is called if it's stopped or primed again first.
    public func start(rate: Double, at time: Time, started: @escaping (CMTime) -> Void) {
        guard rate != 0 else { return stop() }
        guard !invalidated else { return }
        forgetPrime()
        let start = primes
        readyAt = nil
        isPlaying = true
        let position = position(of: time)
        let speed = Float(abs(rate))
        control.async { [weak self] in
            guard let self else { return }
            let host = startSoon(speed, at: position)
            DispatchQueue.main.async { [weak self] in
                guard let self, primes == start, isPlaying else { return }
                started(host)
            }
        }
        output.hold()
    }

    /// Plays at `rate` from `time`, which it reaches at `hostTime` on the
    /// host clock: how a change of speed is made while it plays, at a
    /// `time` and `hostTime` the picture changes at too.
    public func start(rate: Double, at time: Time, hostTime: CMTime) {
        guard rate != 0 else { return stop() }
        guard !invalidated else { return }
        forgetPrime()
        readyAt = nil
        isPlaying = true
        let position = position(of: time)
        let speed = Float(abs(rate))
        control.async { [synchronizer] in
            synchronizer.setRate(speed, time: position, atHostTime: hostTime)
        }
    }

    /// On `control`: starts the synchronizer when it's ready and returns
    /// the host time it reaches `position` at. Its timebase gets a rate
    /// once it has chosen, 20 to 30 ms after it's asked with the output
    /// running (0.1 s when the output has to wake), with the start about
    /// 0.1 s after that. With no output it never chooses, so the start is
    /// set for a moment from now instead, straight away when the renderer
    /// has failed and after half a second otherwise.
    private func startSoon(_ speed: Float, at position: CMTime) -> CMTime {
        if !rendererFailed {
            synchronizer.setRate(speed, time: position)
            let asked = ProcessInfo.processInfo.systemUptime
            while CMTimebaseGetRate(synchronizer.timebase) == 0, ProcessInfo.processInfo.systemUptime - asked < 0.5 {
                usleep(500)
            }
            if CMTimebaseGetRate(synchronizer.timebase) != 0 {
                return CMSyncConvertTime(position, from: synchronizer.timebase, to: CMClockGetHostTimeClock())
            }
        }
        let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: Self.startLead, preferredTimescale: 1_000_000_000)
        synchronizer.setRate(speed, time: position, atHostTime: host)
        return host
    }

    /// Stops and throws away everything queued.
    public func stop() {
        forgetPrime()
        isPlaying = false
        readyAt = nil
        control.async { [weak self] in
            guard let self else { return }
            synchronizer.rate = 0
            retireFeed()
        }
    }

    /// Any prime under way won't count, and nobody waits for it.
    private func forgetPrime() {
        primes += 1
        priming = nil
        waiting = []
    }

    /// Where the synchronizer is, on the timeline.
    public var time: Time {
        timeline(synchronizer.currentTime())
    }

    /// Where the synchronizer is (or was, or will be) at a host time, on
    /// the timeline.
    public func time(atHost host: CMTime) -> Time {
        timeline(CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: synchronizer.timebase))
    }

    private func timeline(_ position: CMTime) -> Time {
        let frames = Int(CMTimeConvertScale(position, timescale: 48_000, method: .roundHalfAwayFromZero).value)
        return Time(flicks: Int64(reverse ? origin - frames : frames) * Time.flicksPerSample48k)
    }

    /// The synchronizer's own time for a timeline time: the timeline time
    /// going forwards, and the time since reverse play began going back.
    func position(of time: Time) -> CMTime {
        let frame = Self.frame(of: time)
        return CMTime(value: Int64(reverse ? max(origin - frame, 0) : frame), timescale: 48_000)
    }

    /// The 48 kHz frame a timeline time falls on.
    static func frame(of time: Time) -> Int {
        Int((Double(time.flicks) / Double(Time.flicksPerSample48k)).rounded())
    }

    /// Tests: sees each sample buffer as the renderer gets it.
    func observeEnqueues(_ observer: ((CMSampleBuffer) -> Void)?) {
        lock.withLock { enqueueObserver = observer }
    }

    // MARK: - Feeding (on `control`, except `pump`)

    private func install(_ new: Feed) {
        let (old, renderer): (Feed?, AVSampleBufferAudioRenderer) = lock.withLock {
            self.renderer.stopRequestingMediaData()
            self.renderer.flush()
            let old = feed
            feed = new
            return (old, self.renderer)
        }
        old?.retire()
        renderer.requestMediaDataWhenReady(on: new.queue) { [weak self] in
            self?.pump(new, into: renderer)
        }
    }

    private func retireFeed() {
        let old: Feed? = lock.withLock {
            renderer.stopRequestingMediaData()
            renderer.flush()
            let old = feed
            feed = nil
            return old
        }
        old?.retire()
    }

    /// On the feed's queue: hands the renderer sound while it wants more.
    private func pump(_ feed: Feed, into renderer: AVSampleBufferAudioRenderer) {
        guard let format else { return }
        while renderer.isReadyForMoreMediaData {
            guard lock.withLock({ self.feed === feed }) else { return }
            guard let chunk = feed.next() else {
                lock.withLock {
                    if self.feed === feed { renderer.stopRequestingMediaData() }
                }
                feed.finished()
                return
            }
            guard let buffer = try? AudioBuffers.sampleBuffer(chunk.samples, at: CMTime(value: Int64(chunk.frame), timescale: 48_000), format: format) else { continue }
            let current: Bool = lock.withLock {
                guard self.feed === feed else { return false }
                enqueueObserver?(buffer)
                renderer.enqueue(buffer)
                return true
            }
            guard current else { return }
            feed.enqueued(chunk.samples.count / AudioBuffers.channels)
        }
    }

    // MARK: - The renderer (on `control`)

    /// A renderer that failed (its device went away) stays failed, so a
    /// prime brings a new one.
    private func replaceRendererIfFailed() {
        let failed = lock.withLock { renderer.status == .failed ? renderer : nil }
        guard let failed else { return }
        if !saidRendererFailed {
            saidRendererFailed = true
            NSLog("TandemRender: the viewer's audio renderer failed (\(String(describing: failed.error))); making another for each prime")
        }
        retireFeed()
        synchronizer.removeRenderer(failed, at: .invalid, completionHandler: nil)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let fresh = Self.makeRenderer(muted: muted, outputDeviceUID: outputDeviceUID)
        lock.withLock { renderer = fresh }
        synchronizer.addRenderer(fresh)
        observe(fresh)
    }

    private func observe(_ renderer: AVSampleBufferAudioRenderer) {
        // The renderer drops what's queued when the output changes, and
        // may when the rate does; either way it needs the sound again.
        // Heard where it's posted, perhaps inside a rate change on
        // `control`, and passed to the main queue without waiting: an
        // observer on the main queue would hold that change up until the
        // main queue ran it, and `invalidate` waits for `control` there.
        for name in [Notification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically, .AVSampleBufferAudioRendererOutputConfigurationDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: renderer, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.invalidated else { return }
                    self.readyAt = nil
                    self.onInterruption?()
                }
            })
        }
    }
}

/// One prime's sound on its way to the renderer: its stream, made on its
/// own queue, and how much it has handed over.
private final class Feed: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.mikerosoft.tandem.viewer-audio", qos: .userInitiated)
    var onReady: (() -> Void)?
    private let readyFrames: Int
    private let make: () -> ViewerSound
    // The rest is only touched on `queue`.
    private var sound: ViewerSound?
    private var queued = 0
    private var signalled = false

    init(readyFrames: Int, make: @escaping () -> ViewerSound) {
        self.readyFrames = readyFrames
        self.make = make
    }

    func next() -> (frame: Int, samples: [Float])? {
        if sound == nil { sound = make() }
        return sound?.next()
    }

    func enqueued(_ frames: Int) {
        queued += frames
        if queued >= readyFrames { signal() }
    }

    /// All the sound there is has gone to the renderer.
    func finished() {
        signal()
    }

    private func signal() {
        guard !signalled else { return }
        signalled = true
        onReady?()
    }

    /// Lets go of the reader once nothing on its queue is reading it:
    /// cancelling a reader while another thread is in it crashes.
    func retire() {
        queue.async { [self] in
            sound?.cancel()
            sound = nil
            onReady = nil
        }
    }
}

// MARK: - Reading the mix

/// What the viewer's sound is read from: a built composition's audio
/// tracks and each one's gain, so every reader gets gain taps of its own.
struct ViewerMix: @unchecked Sendable {
    let composition: AVComposition?
    let tracks: [(id: CMPersistentTrackID, gain: TrackGain)]
    /// The end of the timeline in 48 kHz frames: the sound is padded with
    /// silence to here, so the renderer never runs dry before the picture
    /// does.
    let end: Int

    init(_ built: BuiltComposition) {
        composition = built.composition
        tracks = zip(built.audioMix.inputParameters.map(\.trackID), built.audioGains).map { (id: $0, gain: $1) }
        end = ViewerAudio.frame(of: built.duration)
    }

    private init(end: Int) {
        composition = nil
        tracks = []
        self.end = end
    }

    /// No sound at all, to `end`.
    static func silence(until end: Int) -> ViewerMix {
        ViewerMix(end: end)
    }

    /// A reader of frames `from` to `to` through new gain taps, read the
    /// way export reads the mix, or nil when there's no sound to read.
    func reader(from: Int, to: Int) -> (AVAssetReader, AVAssetReaderAudioMixOutput)? {
        guard let composition, !tracks.isEmpty, to > from else { return nil }
        let byID = Dictionary(composition.tracks(withMediaType: .audio).map { ($0.trackID, $0) }, uniquingKeysWith: { a, _ in a })
        let used = tracks.compactMap { byID[$0.id] }
        guard !used.isEmpty else { return nil }
        do {
            let reader = try AVAssetReader(asset: composition)
            reader.timeRange = CMTimeRange(start: CMTime(value: Int64(from), timescale: 48_000), end: CMTime(value: Int64(to), timescale: 48_000))
            let output = AVAssetReaderAudioMixOutput(audioTracks: used, audioSettings: AudioBuffers.readerSettings)
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = try tracks.filter { byID[$0.id] != nil }.map { track in
                let parameters = AVMutableAudioMixInputParameters()
                parameters.trackID = track.id
                parameters.audioTimePitchAlgorithm = .spectral
                parameters.audioTapProcessor = try GainTap.make(track.gain)
                return parameters
            }
            output.audioMix = audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                NSLog("TandemRender: the viewer couldn't read its sound: \(String(describing: reader.error))")
                return nil
            }
            return (reader, output)
        } catch {
            NSLog("TandemRender: the viewer couldn't read its sound: \(error)")
            return nil
        }
    }

    /// Frames `from` to `to` of the mix, interleaved, silence wherever the
    /// composition has no sound.
    func read(from: Int, to: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: max(to - from, 0) * AudioBuffers.channels)
        guard let opened = reader(from: from, to: to) else { return samples }
        let (reader, output) = opened
        while let buffer = output.copyNextSampleBuffer() {
            let frame = ViewerMix.frame(of: buffer) - from
            let read = AudioBuffers.samples(in: buffer)
            let skip = max(0, -frame)
            let count = min(read.count / AudioBuffers.channels - skip, to - from - max(frame, 0))
            guard count > 0 else { continue }
            let at = max(frame, 0) * AudioBuffers.channels
            samples.replaceSubrange(at..<(at + count * AudioBuffers.channels), with: read[(skip * AudioBuffers.channels)..<((skip + count) * AudioBuffers.channels)])
        }
        if reader.status == .failed {
            NSLog("TandemRender: reading the viewer's sound failed: \(String(describing: reader.error))")
        }
        return samples
    }

    /// The 48 kHz frame a buffer from the reader starts on.
    static func frame(of buffer: CMSampleBuffer) -> Int {
        Int(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(buffer), timescale: 48_000, method: .roundHalfAwayFromZero).value)
    }
}

/// The viewer's sound a chunk at a time: interleaved stereo at 48 kHz,
/// each chunk at `frame` on the synchronizer's timeline.
protocol ViewerSound: AnyObject {
    func next() -> (frame: Int, samples: [Float])?
    func cancel()
}

/// The mix from a frame to the end of the timeline, through one reader,
/// with silence where the composition has none and after its sound ends.
final class ForwardSound: ViewerSound {
    static let silenceChunk = 4_800
    private let end: Int
    private var reader: AVAssetReader?
    private var output: AVAssetReaderAudioMixOutput?
    /// The next frame to hand out.
    private var position: Int
    /// A buffer read past a gap, waiting for the silence before it.
    private var waiting: (frame: Int, samples: [Float])?

    init(_ mix: ViewerMix, from start: Int) {
        end = mix.end
        position = start
        if let opened = mix.reader(from: start, to: mix.end) {
            reader = opened.0
            output = opened.1
        }
    }

    func next() -> (frame: Int, samples: [Float])? {
        while position < end {
            if waiting == nil, let output {
                if let buffer = output.copyNextSampleBuffer() {
                    waiting = (ViewerMix.frame(of: buffer), AudioBuffers.samples(in: buffer))
                } else {
                    if let reader, reader.status == .failed {
                        NSLog("TandemRender: reading the viewer's sound failed: \(String(describing: reader.error))")
                    }
                    self.output = nil
                    reader = nil
                }
            }
            guard let pending = waiting else {
                // Silence to the end of the timeline.
                let count = min(Self.silenceChunk, end - position)
                defer { position += count }
                return (position, [Float](repeating: 0, count: count * AudioBuffers.channels))
            }
            var frame = pending.frame
            var samples = pending.samples
            if frame > position {
                let count = min(frame - position, Self.silenceChunk, end - position)
                defer { position += count }
                return (position, [Float](repeating: 0, count: count * AudioBuffers.channels))
            }
            waiting = nil
            if frame < position {
                // Sound from before where this stream starts.
                let skip = min(position - frame, samples.count / AudioBuffers.channels)
                samples.removeFirst(skip * AudioBuffers.channels)
                frame += skip
            }
            let count = min(samples.count / AudioBuffers.channels, end - position)
            guard count > 0 else { continue }
            if count * AudioBuffers.channels < samples.count { samples.removeLast(samples.count - count * AudioBuffers.channels) }
            position = frame + count
            return (frame, samples)
        }
        return nil
    }

    func cancel() {
        reader?.cancelReading()
        reader = nil
        output = nil
    }
}

/// The mix played backwards from a frame to the start of the timeline:
/// read forwards a block at a time, each through a reader with taps of its
/// own, and reversed. Frame 0 here is the last frame before `from`.
final class ReverseSound: ViewerSound {
    /// Two seconds: at 8x backwards that's four readers a second, about 5%
    /// of a core.
    static let blockFrames = 96_000
    static let chunk = 4_800
    private let mix: ViewerMix
    private let top: Int
    private var produced = 0
    private var block: [Float] = []
    private var used = 0

    init(_ mix: ViewerMix, from start: Int) {
        self.mix = mix
        top = start
    }

    func next() -> (frame: Int, samples: [Float])? {
        let channels = AudioBuffers.channels
        if used * channels >= block.count {
            let high = top - produced
            guard high > 0 else { return nil }
            let low = max(0, high - Self.blockFrames)
            block = Self.reversed(mix.read(from: low, to: high))
            used = 0
        }
        let count = min(Self.chunk, block.count / channels - used)
        let samples = Array(block[(used * channels)..<((used + count) * channels)])
        defer {
            used += count
            produced += count
        }
        return (produced, samples)
    }

    func cancel() {}

    /// Interleaved frames in reverse order.
    static func reversed(_ samples: [Float]) -> [Float] {
        let channels = AudioBuffers.channels
        let frames = samples.count / channels
        var out = [Float](repeating: 0, count: samples.count)
        for frame in 0..<frames {
            let from = (frames - 1 - frame) * channels
            for channel in 0..<channels { out[frame * channels + channel] = samples[from + channel] }
        }
        return out
    }
}

/// Keeps the default output device running for a while after the viewer
/// plays or queues sound, as AVPlayer did after a pause (for about 35 s):
/// from idle (about 2.5 s after the last sound) the device takes 0.1 s to
/// wake, which every start then waits for. Started with no IOProc it runs
/// at about 0.1% of a core. A running output keeps the Mac from idling to
/// sleep (coreaudiod says so), which is why it lets go after a while. It
/// follows the default device when that changes.
final class OutputHold: @unchecked Sendable {
    /// How long it holds the output after the last `hold`.
    static let duration: TimeInterval = 30
    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.viewer-audio.output")
    /// Only touched on `queue`.
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var holding = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var letGo: DispatchWorkItem?
    private var defaultDevice = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )

    /// Holds the output from now until `duration` after the last call.
    func hold() {
        queue.async { [self] in
            letGo?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.stopHolding() }
            letGo = work
            queue.asyncAfter(deadline: .now() + Self.duration, execute: work)
            guard !holding else { return }
            holding = true
            start()
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, holding else { return }
                stop()
                start()
            }
            self.listener = listener
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, queue, listener)
        }
    }

    /// Lets go now.
    func release() {
        queue.sync { stopHolding() }
    }

    /// On `queue`.
    private func stopHolding() {
        letGo?.cancel()
        letGo = nil
        guard holding else { return }
        holding = false
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, queue, listener)
        }
        listener = nil
        stop()
    }

    private func start() {
        var found = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, 0, nil, &size, &found) == noErr,
              found != kAudioObjectUnknown else { return }
        // No IOProc: this runs the hardware and nothing else, until the
        // matching stop.
        if AudioDeviceStart(found, nil) == noErr { device = found }
    }

    private func stop() {
        guard device != kAudioObjectUnknown else { return }
        AudioDeviceStop(device, nil)
        device = AudioObjectID(kAudioObjectUnknown)
    }
}
