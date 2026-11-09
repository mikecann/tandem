import Foundation

/// Pitch-synchronous time-domain speed change, tuned for speech: the viewer
/// plays through this at the transport's playback speeds (0.5× to 2×)
/// instead of Apple's spectral time-pitch, which made voices sound robotic.
/// Ported from Poddle's PoddlePlayback `SpeechStretcher` (the approach of
/// Bill Cox's Sonic, which Android's ExoPlayer uses for podcast speed-up):
/// it finds the local pitch period with AMDF, then drops (or repeats) whole
/// pitch periods, overlap-adding across each join. Because it only removes
/// or adds whole glottal cycles, voices keep their pitch and formants and
/// don't go phasey the way a phase vocoder does. Mike picked it over Apple's
/// spectral and time-domain modes by ear (9 Nov 2026).
///
/// Unlike Poddle's, it carries the fractions it rounds off from one period
/// to the next, so over a long play its output stays exactly `1 / rate` of
/// its input. The viewer depends on that: the picture runs at `rate` on the
/// same clock, and any drift would build up into a lip-sync error.
///
/// Interleaved samples in and out, `channels` to a frame. It's a module of
/// its own so it can be built optimised even in a debug build (Package.swift):
/// restart.sh installs one, and unoptimised it ran about 100 times slower,
/// most of a core at 2×.
public struct SpeechStretcher {
    public let rate: Double
    public let channels: Int

    private let minPeriod: Int
    private let maxPeriod: Int
    /// Frames it needs on hand to look for a period and join across it.
    public let maxRequired: Int
    private let skip: Int
    private var input: [Float] = []
    /// The next frame of `input` to use.
    private var position = 0
    private var remainingInputToCopy = 0
    private var previousPeriod = 0
    private var previousMinDiff = 0.0
    /// What rounding the last lengths down left over, in frames.
    private var carry = 0.0
    /// Frames taken in and given out, so `flush` can end on exactly
    /// `1 / rate` of the input.
    private var inputTotal = 0
    private var outputTotal = 0
    private var mono: [Float] = []
    private var downsampled: [Float] = []

    public init(rate: Double, sampleRate: Double = 48_000, channels: Int = 2) {
        precondition(rate > 0 && rate != 1, "a speech stretcher for 1x would only copy")
        self.rate = rate
        self.channels = channels
        minPeriod = Int(sampleRate / 400)
        maxPeriod = Int(sampleRate / 65)
        maxRequired = 2 * maxPeriod
        skip = max(1, Int(sampleRate / 4000))
    }

    private var inputFrames: Int { input.count / channels }

    /// Takes `samples` and returns what's ready, holding back the last
    /// `maxRequired` frames or so for the next call.
    public mutating func process(_ samples: [Float]) -> [Float] {
        input.append(contentsOf: samples)
        inputTotal += samples.count / channels
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) / rate) + 64 * channels)
        while inputFrames - position >= maxRequired {
            if remainingInputToCopy > 0 {
                let n = min(remainingInputToCopy, maxRequired)
                copy(from: position, count: n, into: &output)
                position += n
                remainingInputToCopy -= n
            } else {
                let period = findPitchPeriod(at: position)
                if rate > 1 {
                    position += period + skipPitchPeriod(at: position, period: period, into: &output)
                } else {
                    position += insertPitchPeriod(at: position, period: period, into: &output)
                }
            }
        }
        if position > 0 {
            input.removeFirst(position * channels)
            position = 0
        }
        outputTotal += output.count / channels
        return output
    }

    /// The end of the sound: what's held back, stretched like the rest and
    /// cut so the whole output is `1 / rate` of the input to the frame.
    /// Passed through unchanged, as Poddle does, a stream shorter than
    /// `maxRequired` (a play started near the end of the timeline) came out
    /// unstretched, ending 30 ms before the picture at 0.5x.
    public mutating func flush() -> [Float] {
        let target = Int((Double(inputTotal) / rate).rounded())
        let before = outputTotal
        // Silence after it, so the held-back frames go through the same
        // way as the rest.
        var out = process([Float](repeating: 0, count: (2 * maxRequired + remainingInputToCopy) * channels))
        let wanted = max(target - before, 0) * channels
        if out.count > wanted {
            out.removeLast(out.count - wanted)
        } else if out.count < wanted {
            out.append(contentsOf: repeatElement(0, count: wanted - out.count))
        }
        input = []
        position = 0
        remainingInputToCopy = 0
        inputTotal = 0
        outputTotal = 0
        return out
    }

    // MARK: Speed up / slow down

    /// A whole number of frames for `exact`, keeping what's rounded off.
    private mutating func whole(_ exact: Double) -> Int {
        let wanted = exact + carry
        let frames = Int(wanted)
        carry = wanted - Double(frames)
        return frames
    }

    private mutating func skipPitchPeriod(at pos: Int, period: Int, into output: inout [Float]) -> Int {
        let newSamples: Int
        if rate >= 2 {
            newSamples = whole(Double(period) / (rate - 1))
        } else {
            newSamples = period
            remainingInputToCopy = whole(Double(period) * (2 - rate) / (rate - 1))
        }
        overlapAdd(count: newSamples, rampDown: pos, rampUp: pos + period, into: &output)
        return newSamples
    }

    private mutating func insertPitchPeriod(at pos: Int, period: Int, into output: inout [Float]) -> Int {
        let newSamples: Int
        if rate < 0.5 {
            newSamples = whole(Double(period) * rate / (1 - rate))
        } else {
            newSamples = period
            remainingInputToCopy = whole(Double(period) * (2 * rate - 1) / (1 - rate))
        }
        copy(from: pos, count: period, into: &output)
        overlapAdd(count: newSamples, rampDown: pos + period, rampUp: pos, into: &output)
        return newSamples
    }

    private func copy(from frame: Int, count: Int, into output: inout [Float]) {
        output.append(contentsOf: input[(frame * channels)..<((frame + count) * channels)])
    }

    /// Linear crossfade from `rampDown` to `rampUp`. A convex blend, so it
    /// can't exceed the input's peaks.
    private func overlapAdd(count: Int, rampDown: Int, rampUp: Int, into output: inout [Float]) {
        guard count > 0 else { return }
        let n = Float(count)
        let channels = channels
        let at = output.count
        // Made room for first and written through pointers: appending a
        // sample at a time was most of the stretcher's time in a debug build,
        // which is what restart.sh installs.
        output.append(contentsOf: repeatElement(0, count: count * channels))
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { out in
                for t in 0..<count {
                    let w = Float(t) / n
                    let down = (rampDown + t) * channels
                    let up = (rampUp + t) * channels
                    let to = at + t * channels
                    for c in 0..<channels {
                        out[to + c] = src[down + c] * (1 - w) + src[up + c] * w
                    }
                }
            }
        }
    }

    // MARK: Pitch detection

    private mutating func findPitchPeriod(at pos: Int) -> Int {
        if mono.count != maxRequired { mono = Array(repeating: 0, count: maxRequired) }
        let scale = 1 / Float(channels)
        let channels = channels
        let maxRequired = maxRequired
        input.withUnsafeBufferPointer { src in
            // The pitch is looked for in the channels' mix, unless they
            // cancel there (opposite polarity, or one side out of phase),
            // when the loudest channel on its own is used instead: in a mix
            // that cancelled to silence, any period matched, and voices came
            // out an octave up.
            var level = [Float](repeating: 0, count: channels)
            var mixLevel: Float = 0
            for i in 0..<maxRequired {
                let base = (pos + i) * channels
                var s: Float = 0
                for c in 0..<channels {
                    level[c] += abs(src[base + c])
                    s += src[base + c]
                }
                mixLevel += abs(s * scale)
            }
            let loudest = level.indices.max { level[$0] < level[$1] } ?? 0
            let useMix = mixLevel >= 0.5 * level[loudest]
            mono.withUnsafeMutableBufferPointer { out in
                for i in 0..<maxRequired {
                    let base = (pos + i) * channels
                    if useMix {
                        var s: Float = 0
                        for c in 0..<channels { s += src[base + c] }
                        out[i] = s * scale
                    } else {
                        out[i] = src[base + loudest]
                    }
                }
            }
        }
        var period: Int
        var minDiff: Double
        var maxDiff: Double
        if skip == 1 {
            (period, minDiff, maxDiff) = Self.amdf(mono, minPeriod, maxPeriod)
        } else {
            let count = maxRequired / skip
            if downsampled.count != count { downsampled = Array(repeating: 0, count: count) }
            let skip = skip
            mono.withUnsafeBufferPointer { m in
                downsampled.withUnsafeMutableBufferPointer { d in
                    for i in 0..<count {
                        var s: Float = 0
                        for j in 0..<skip { s += m[i * skip + j] }
                        d[i] = s
                    }
                }
            }
            let coarse = Self.amdf(downsampled, max(1, minPeriod / skip), maxPeriod / skip).period * skip
            (period, minDiff, maxDiff) = Self.amdf(
                mono, max(minPeriod, coarse - 4 * skip), min(maxPeriod, coarse + 4 * skip))
        }
        // Sonic's continuity rule: keep the previous period when this one
        // is a poor, unvoiced match.
        var chosen = period
        if minDiff > 0, previousPeriod > 0, maxDiff <= minDiff * 3, minDiff * 2 > previousMinDiff * 3 {
            chosen = previousPeriod
        }
        previousMinDiff = minDiff
        previousPeriod = period
        return chosen
    }

    /// Average magnitude difference. Returns the best period plus the
    /// normalised min and max diffs.
    private static func amdf(_ s: [Float], _ minP: Int, _ maxP: Int) -> (period: Int, minDiff: Double, maxDiff: Double) {
        var best = minP, minDiff = Double.greatestFiniteMagnitude, maxDiff = 0.0
        s.withUnsafeBufferPointer { p in
            for period in minP...max(minP, maxP) where period * 2 <= p.count {
                var diff: Float = 0
                for i in 0..<period { diff += abs(p[i] - p[i + period]) }
                let normalised = Double(diff) / Double(period)
                if normalised < minDiff { minDiff = normalised; best = period }
                if normalised > maxDiff { maxDiff = normalised }
            }
        }
        return (best, minDiff, maxDiff)
    }
}

