import XCTest
@testable import TandemRender
import TandemSpeech

/// The viewer's speech-tuned speed change: voices keep their pitch, and the
/// sound keeps time with a picture running at the same speed however long
/// it plays.
final class SpeechStretcherTests: XCTestCase {
    static let rate = 48_000.0

    /// A voice-like buzz (a few harmonics) whose pitch glides from `from`
    /// to `to` Hz, stereo interleaved.
    static func glide(seconds: Double, from: Double, to: Double) -> [Float] {
        let frames = Int(seconds * rate)
        var out = [Float](repeating: 0, count: frames * 2)
        var phase = 0.0
        for i in 0..<frames {
            let f = from + (to - from) * Double(i) / Double(frames)
            phase += 2 * .pi * f / rate
            let s = Float(0.5 * sin(phase) + 0.25 * sin(2 * phase) + 0.12 * sin(3 * phase)) * 0.8
            out[i * 2] = s
            out[i * 2 + 1] = s
        }
        return out
    }

    static func stretch(_ samples: [Float], rate: Double) -> [Float] {
        var stretcher = SpeechStretcher(rate: rate)
        var out: [Float] = []
        var at = 0
        while at < samples.count {
            let end = min(at + 4_800 * 2, samples.count)
            out += stretcher.process(Array(samples[at..<end]))
            at = end
        }
        return out + stretcher.flush()
    }

    /// The pitch of the left channel around `frame`, in Hz, by AMDF,
    /// looked for within a third of `near` so it can't land an octave out.
    static func pitch(_ samples: [Float], at frame: Int, near: Double) -> Double {
        let window = 2_400
        var best = 0, bestDiff = Float.greatestFiniteMagnitude
        for period in Int(rate / (near * 1.33))...Int(rate / (near / 1.33)) {
            var diff: Float = 0
            for i in 0..<window { diff += abs(samples[(frame + i) * 2] - samples[(frame + i + period) * 2]) }
            if diff < bestDiff { bestDiff = diff; best = period }
        }
        return rate / Double(best)
    }

    func testEverySpeedPlaysForTheRightLengthWithNoDrift() {
        let input = Self.glide(seconds: 10, from: 110, to: 230)
        let held = Double(SpeechStretcher(rate: 2).maxRequired)
        for speed in [0.5, 0.75, 1.25, 1.5, 1.75, 2] {
            let output = Self.stretch(input, rate: speed)
            let expected = Double(input.count / 2) / speed
            // Off only by the last few hundredths of a second, which the
            // flush passes through unstretched at the very end. Poddle's
            // rounding drifted on top of that, by 0.1% at 1.75x: 10 ms here
            // and 0.6 s, out of sync, after ten minutes.
            let tail = held * abs(1 - 1 / speed)
            XCTAssertEqual(Double(output.count / 2), expected, accuracy: tail + 50, "length at \(speed)x")
        }
    }

    func testVoicesKeepTheirPitchAndStayInTimeWithThePicture() {
        let seconds = 6.0, from = 110.0, to = 230.0
        let input = Self.glide(seconds: seconds, from: from, to: to)
        for speed in [0.75, 1.5, 2] {
            let output = Self.stretch(input, rate: speed)
            // Sampled through the output: the pitch there should be the
            // glide's at the same moment of the timeline (output time x
            // speed), which only holds if it neither shifts pitch nor drifts.
            for fraction in [0.2, 0.5, 0.8] {
                let outFrame = Int(Double(output.count / 2) * fraction)
                let inFrame = Double(outFrame) * speed
                let source = from + (to - from) * inFrame / (seconds * Self.rate)
                let heard = Self.pitch(output, at: outFrame, near: source)
                XCTAssertEqual(heard, source, accuracy: source * 0.03, "pitch at \(fraction) of the way through at \(speed)x")
            }
        }
    }

    func testItNeverGetsLouderThanTheSound() {
        let input = Self.glide(seconds: 3, from: 90, to: 300)
        let peak = input.map(abs).max()!
        for speed in [0.5, 1.5, 2] {
            let output = Self.stretch(input, rate: speed)
            XCTAssertLessThanOrEqual(output.map(abs).max()!, peak + 1e-5, "at \(speed)x")
        }
    }
}
