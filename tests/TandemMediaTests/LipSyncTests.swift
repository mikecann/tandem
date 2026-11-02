import XCTest
@testable import TandemMedia

/// The measuring behind `tandem sync --check`, on made-up mouths and voices.
/// Vision's part needs a real face, so it's checked on real footage by hand.
final class LipSyncTests: XCTestCase {
    /// A syllable rhythm with no fixed period: how wide the mouth is, and how
    /// loud the voice, at a time in seconds.
    static func speech(_ time: Double) -> Double {
        let a = sin(2 * .pi * 3.1 * time), b = sin(2 * .pi * 4.7 * time + 1), c = sin(2 * .pi * 1.3 * time + 2)
        return max(0, a * 0.5 + b * 0.4 + c * 0.3 + 0.3)
    }

    /// 24 fps frames with one face talking and optionally another sat still,
    /// and the loudness of a voice `lead` seconds ahead of the mouth.
    static func stretch(lead: Double, seconds: Double = 20, listener: Bool = true) -> (frames: [LipSync.Frame], loudness: [Float]) {
        let frames = (0..<Int(seconds * 24)).map { i -> LipSync.Frame in
            let time = Double(i) / 24
            var faces = [LipSync.Face(x: 0.3, y: 0.5, height: 0.2, opening: speech(time) * 0.02)]
            if listener { faces.append(LipSync.Face(x: 0.7, y: 0.5, height: 0.2, opening: 0.003 + 0.0002 * sin(time))) }
            return LipSync.Frame(time: time, faces: faces)
        }
        // The voice at t is what the mouth does at t + lead.
        let loudness = (0..<Int(seconds * 1000)).map { Float(speech(Double($0) / 1000 + lead)) }
        return (frames, loudness)
    }

    func testItFindsHowFarTheVoiceIsAheadOfTheLips() {
        for lead in [0.057, 0.013, -0.03] {
            let (frames, loudness) = Self.stretch(lead: lead)
            let readings = LipSync.measure(frames: frames, loudness: loudness, start: 0)
            XCTAssertGreaterThanOrEqual(readings.count, 3, "lead \(lead)")
            for reading in readings {
                XCTAssertEqual(reading.voiceLead, lead, accuracy: 0.004, "lead \(lead)")
                XCTAssertGreaterThan(reading.correlation, 0.9)
            }
        }
    }

    func testTheFaceThatMovesWithTheVoiceIsTheOneTalking() {
        // Two faces, the talker on the right this time, and they swap sides
        // in the list between frames: followed by where they are, not order.
        let (frames, loudness) = Self.stretch(lead: 0.04)
        let swapped = frames.enumerated().map { index, frame -> LipSync.Frame in
            var frame = frame
            if index % 2 == 1 { frame.faces.reverse() }
            return frame
        }
        let readings = LipSync.measure(frames: swapped, loudness: loudness, start: 0)
        XCTAssertFalse(readings.isEmpty)
        for reading in readings { XCTAssertEqual(reading.voiceLead, 0.04, accuracy: 0.004) }
    }

    func testNoFaceOrNoVoiceOrAMouthThatDoesntMoveWithItReadsNothing() {
        let (frames, loudness) = Self.stretch(lead: 0)
        let faceless = frames.map { LipSync.Frame(time: $0.time, faces: []) }
        XCTAssertEqual(LipSync.measure(frames: faceless, loudness: loudness, start: 0), [])
        let silent = [Float](repeating: 0, count: loudness.count)
        XCTAssertEqual(LipSync.measure(frames: frames, loudness: silent, start: 0), [])
        // Someone else talking off camera: this mouth is on a rhythm of its own.
        let unrelated = (0..<loudness.count).map { Float(Self.speech(Double($0) / 1000 * 0.61 + 40)) }
        XCTAssertEqual(LipSync.measure(frames: frames, loudness: unrelated, start: 0), [])
        XCTAssertEqual(LipSync.measure(frames: Array(frames.prefix(24)), loudness: loudness, start: 0), [], "a second is too short")
    }

    func testAFaceTheFrameOftenLosesCantBeRead() {
        let (frames, loudness) = Self.stretch(lead: 0, listener: false)
        let patchy = frames.enumerated().map { index, frame in
            index % 2 == 0 ? frame : LipSync.Frame(time: frame.time, faces: [])
        }
        XCTAssertEqual(LipSync.measure(frames: patchy, loudness: loudness, start: 0), [])
    }

    private func readings(_ leads: [Double]) -> [LipSync.Reading] {
        leads.enumerated().map { index, lead in
            // A broad hump with its peak at the lead, as a real window gives.
            let curve = (-250...250).map { ms -> Float in
                let distance = (Double(ms) / 1000 - lead) / 0.06
                return Float(0.6 * exp(-distance * distance))
            }
            return LipSync.Reading(time: Double(index), voiceLead: lead, correlation: 0.6, curve: curve)
        }
    }

    func testJudgedAgainstWhatInSyncFootageReadsInWholeFrames() throws {
        let frame = 1001.0 / 24000
        // James's Gemini wide: a frame out.
        let wide = try XCTUnwrap(LipSync.assess(readings([0.055, 0.057, 0.059, 0.057]), frame: frame))
        XCTAssertEqual(wide.state, .off)
        XCTAssertEqual(wide.frames, 1)
        XCTAssertEqual(wide.offBy, 0.044, accuracy: 0.001)
        // The close-ups: the 5-21 ms in-sync footage reads.
        let close = try XCTUnwrap(LipSync.assess(readings([0.005, 0.012, 0.021, 0.015]), frame: frame))
        XCTAssertEqual(close.state, .inSync)
        XCTAssertEqual(close.frames, 0)
        // The overshoot: lips early by a frame or so needs less delay.
        let over = try XCTUnwrap(LipSync.assess(readings([-0.028, -0.026, -0.025]), frame: frame))
        XCTAssertEqual(over.frames, -1)
        // Close to a frame but within what in-sync footage reads: left alone.
        XCTAssertEqual(LipSync.assess(readings([-0.008, -0.008]), frame: frame)?.state, .inSync)
        XCTAssertEqual(LipSync.assess(readings([0.031, 0.031]), frame: frame)?.state, .inSync)
        // The fix is in frames of the file, however many that takes.
        XCTAssertEqual(LipSync.assess(readings([0.063, 0.063]), frame: 1.0 / 60)?.frames, 3)
        // Together they peak where they agree, whatever one window says.
        let together = try XCTUnwrap(LipSync.assess(readings([0.050, 0.060, 0.050, 0.060]), frame: frame))
        XCTAssertEqual(together.voiceLead, 0.055, accuracy: 0.002)
        // Nothing to go on, or readings all over the place.
        XCTAssertEqual(LipSync.assess(readings([0.057]), frame: frame)?.state, .unclear)
        XCTAssertEqual(LipSync.assess(readings([-0.1, 0.0, 0.1, 0.2]), frame: frame)?.state, .unclear)
        XCTAssertNil(LipSync.assess([], frame: frame))
    }

    func testLoudnessKeepsTheVoiceInPlaceAndDropsHum() {
        // A burst of 1 kHz from 0.5 s to 0.7 s over mains hum.
        let rate = 48_000.0
        let samples = (0..<Int(rate)).map { i -> Float in
            let time = Double(i) / rate
            let hum = 0.3 * sin(2 * .pi * 50 * time)
            let voice = time >= 0.5 && time < 0.7 ? 0.3 * sin(2 * .pi * 1_000 * time) : 0
            return Float(hum + voice)
        }
        let loudness = LipSync.loudness(samples, rate: rate)
        XCTAssertEqual(loudness.count, 1000)
        XCTAssertLessThan(loudness[300], loudness[600] * 0.1, "the hum's filtered out")
        // The window smears both edges the same way, so the burst stays
        // centred on where it was: that's what the lag depends on.
        let half = (loudness.max() ?? 0) / 2
        let rise = try! XCTUnwrap(loudness.firstIndex { $0 > half })
        let fall = try! XCTUnwrap(loudness.lastIndex { $0 > half })
        XCTAssertEqual((rise + fall) / 2, 600, accuracy: 2)
    }
}
