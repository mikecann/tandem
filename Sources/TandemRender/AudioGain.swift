import Accelerate
import AVFoundation
import MediaToolbox
import TandemCore

/// The gain of one composition track along the timeline: the envelopes of
/// the segments placed on it, end to end. Silent between segments.
struct TrackGain: Equatable, Sendable {
    /// Gain moving in a straight line from `from` at `start` to `to` at
    /// `end` (timeline seconds), on a segment playing its source at `speed`
    /// source seconds per timeline second.
    struct Piece: Equatable, Sendable {
        var start: Double
        var end: Double
        var from: Float
        var to: Float
        var speed: Double
    }

    /// In time order, never overlapping. A piece holds its start but not
    /// its end, so at a cut the clip after it has the cut's first sample.
    private(set) var pieces: [Piece] = []

    /// `frameDuration` is how much source a freeze frame stretches.
    init(_ segments: [PlannedSegment], frameDuration: Time) {
        for segment in segments.sorted(by: { $0.timeline.start < $1.timeline.start }) {
            let duration = segment.timeline.duration.seconds
            var speed = segment.freeze ? frameDuration.seconds / max(duration, 1e-9) : segment.speed
            if !(speed > 0) { speed = 1 }
            for (a, b) in zip(segment.envelope, segment.envelope.dropFirst()) where b.time > a.time {
                pieces.append(Piece(start: a.time.seconds, end: b.time.seconds, from: Float(a.gain), to: Float(b.gain), speed: speed))
            }
        }
    }

    /// The gain at a timeline time.
    func gain(at time: Double) -> Float {
        pieces.withUnsafeBufferPointer { pieces in
            let index = Self.firstPiece(endingAfter: time, in: pieces)
            guard index < pieces.count, time >= pieces[index].start else { return 0 }
            let piece = pieces[index]
            return piece.from + (piece.to - piece.from) * Float((time - piece.start) / (piece.end - piece.start))
        }
    }

    /// Index of the first piece that ends after `time`.
    static func firstPiece(endingAfter time: Double, in pieces: UnsafeBufferPointer<Piece>) -> Int {
        var low = 0, high = pieces.count
        while low < high {
            let middle = (low + high) / 2
            if pieces[middle].end <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Multiplies `frames` frames of float samples by the gain each plays
    /// at. The first frame is at `start` on the timeline, and each frame
    /// after it a frame of source later: 1 / (rate x speed) seconds.
    /// `channels` holds one pointer per channel, each `step` floats apart
    /// frame to frame (1 for separate channel buffers, the channel count
    /// for interleaved ones). Each run of frames inside one piece is a
    /// straight line of gain, applied with vDSP; between segments it's
    /// silence.
    static func apply(
        _ pieces: UnsafeBufferPointer<Piece>,
        to channels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
        step: Int,
        frames: Int,
        start: Double,
        sampleRate: Double
    ) {
        var frame = 0
        var time = start
        var index = firstPiece(endingAfter: time, in: pieces)
        while frame < frames {
            while index < pieces.count && time >= pieces[index].end { index += 1 }
            let inside = index < pieces.count && time >= pieces[index].start
            let seconds = 1 / (sampleRate * (inside ? pieces[index].speed : 1))
            // Frames before the piece ends (or, in a gap, the next starts).
            var count = frames - frame
            if index < pieces.count {
                let boundary = inside ? pieces[index].end : pieces[index].start
                count = min(count, max(1, Int(((boundary - time) / seconds - 1e-9).rounded(.up))))
            }
            let stride = vDSP_Stride(step)
            if inside {
                let piece = pieces[index]
                let slope = Double(piece.to - piece.from) / (piece.end - piece.start)
                let first = Float(Double(piece.from) + slope * (time - piece.start))
                let increment = Float(slope * seconds)
                if increment != 0 || first != 1 {
                    for channel in channels {
                        var gain = first
                        var change = increment
                        let samples = channel + frame * step
                        vDSP_vrampmul(samples, stride, &gain, &change, samples, stride, vDSP_Length(count))
                    }
                }
            } else {
                for channel in channels {
                    vDSP_vclr(channel + frame * step, stride, vDSP_Length(count))
                }
            }
            frame += count
            time += Double(count) * seconds
        }
    }
}

/// Applies a composition track's gain to its samples as AVFoundation reads
/// them, in an MTAudioProcessingTap on the track's audio mix input. Export,
/// review clips, the loudness passes and the viewer's sound (`ViewerAudio`)
/// all use it.
///
/// AVAudioMix's own volume ramps can't do this. However a ramp is set,
/// AVFoundation moves a track's volume by at most 1.0 (linear) every
/// 25 ms: measured on a constant source, 1 to 4 takes 75 ms and 1 to 30
/// takes 724 ms, whatever the ramp's length and wherever reading starts.
/// So a clip normalised up 8 dB and keyframed to +16.3 dB (16.4 times)
/// took 0.35 s to come down to the next clip's 2.5 after a cut, playing
/// the next clip's first word up to 16 dB too loud, and a clip starting
/// on a track that was silent faded in over as long. A keyframed ramp
/// inside a clip landed late the same way, and the 3 ms fades at hard
/// cuts never happened at all. Reading from a seek made it worse: each
/// track started at about the volume it had 0.3 s earlier.
///
/// The tap sits before AVFoundation's effects, so it sees each source's
/// own samples (before a speed change is time-stretched or the player's
/// rate is applied), each call stamped with the timeline time of its
/// first sample. The stamp was exact to the sample in export's readers
/// from any start, and in AVPlayer at rates 0.5, 1 and 2 after seeks and
/// across edits. A post-effects tap's stamps run 4096 samples behind in
/// the player and drift at other rates. Within a call, a frame of a
/// segment at speed s moves the timeline on by 1 / (48000 s).
///
/// In AVPlayer taps cost something at the start of playback: after a seek
/// or a rebuild, play took about 0.5 s to get going instead of 0.15 s, and
/// audio tracks after the first joined about 0.1 s late, missing that
/// much, because a tapped track's sound runs through the taps in real time
/// once playing starts. Prerolling or scheduling the start didn't help
/// (RENDER.md, Gotchas). So the viewer doesn't play the mix in AVPlayer:
/// `ViewerAudio` reads it ahead of time through these taps, the way export
/// does.
///
/// A tapped track must not change audio format part way (see
/// `RenderPlanner.assignTracks`).
enum GainTap {
    /// What the tap's callbacks need. Built once per tap and never changed
    /// while audio plays, apart from the format, which `prepare` sets
    /// before the first `process`.
    final class Context {
        let pieces: UnsafeMutableBufferPointer<TrackGain.Piece>
        var sampleRate = Double(AudioBuffers.sampleRate)
        var channelCount = 2
        var interleaved = false
        var isFloat32 = true

        init(_ gain: TrackGain) {
            pieces = .allocate(capacity: gain.pieces.count)
            _ = pieces.initialize(from: gain.pieces)
        }

        deinit {
            pieces.deinitialize()
            pieces.deallocate()
        }

        func prepare(_ format: AudioStreamBasicDescription) {
            sampleRate = format.mSampleRate > 0 ? format.mSampleRate : Double(AudioBuffers.sampleRate)
            channelCount = max(Int(format.mChannelsPerFrame), 1)
            interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            isFloat32 = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        }

        /// Runs on the audio thread: no allocation, no locks.
        func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, start: CMTime) {
            guard frames > 0 else { return }
            guard isFloat32, start.isNumeric else {
                // No time to look the gain up at. The player's first call,
                // before it has a position, is all silence anyway. Any
                // other format would be a new AVFoundation, and silence is
                // a safer guess than sound at the wrong level.
                for buffer in buffers {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return
            }
            let pieces = UnsafeBufferPointer(self.pieces)
            let seconds = CMTimeGetSeconds(start)
            // A pointer to each channel's first sample, on the stack.
            if interleaved {
                guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
                withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: channelCount) { pointers in
                    for c in 0..<channelCount { pointers[c] = data + c }
                    TrackGain.apply(pieces, to: UnsafeBufferPointer(pointers), step: channelCount, frames: frames, start: seconds, sampleRate: sampleRate)
                }
            } else {
                withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: buffers.count) { pointers in
                    var used = 0
                    for buffer in buffers {
                        guard let data = buffer.mData else { continue }
                        pointers[used] = data.assumingMemoryBound(to: Float.self)
                        used += 1
                    }
                    TrackGain.apply(pieces, to: UnsafeBufferPointer(rebasing: pointers[0..<used]), step: 1, frames: frames, start: seconds, sampleRate: sampleRate)
                }
            }
        }
    }

    static func make(_ gain: TrackGain) throws -> MTAudioProcessingTap {
        let context = Unmanaged.passRetained(Context(gain))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context.toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frameCount, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                var frames: CMItemCount = 0
                guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, &range, &frames) == noErr else {
                    framesOut.pointee = 0
                    return
                }
                framesOut.pointee = frames
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(UnsafeMutableAudioBufferListPointer(bufferList), frames: frames, start: range.start)
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        // A failed create may or may not have finalized the context, so it
        // isn't released here: a leak is better than a double release.
        guard status == noErr, let tap else { throw RenderError.compositor("couldn't make the audio gain tap (\(status))") }
        return tap
    }
}
