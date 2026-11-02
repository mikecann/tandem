import AVFoundation
import Foundation
import ImageIO
import Vision

/// Measures how far a voice is from the lips on screen: per-frame mouth
/// opening (Apple Vision's face landmarks) against the voice's loudness,
/// cross-correlated over ±250 ms.
///
/// Lining recordings up by sound can't see this. A far camera mic and a
/// camera's own audio-to-picture offset both leave a lag between its picture
/// and the sound, however well the sounds match: on the James interview
/// (November 2026) the RED Gemini wide read 55-59 ms with its sound matched to
/// the lav at confidence 54-59, and Mike was the one who noticed.
public enum LipSync {
    /// What footage known to be in sync reads, in seconds: the voice's
    /// loudness peaks a little before the mouth is widest. James's close-ups
    /// read 5-21 ms a stretch, so a file is judged by how far it is from the
    /// middle.
    public static let naturalLead = 0.013
    /// How far a file has to be from `naturalLead` before it's worth moving.
    /// A sample of in-sync footage lands anywhere from -8 to 30 ms, as the
    /// talker and the words change: the James interview's close-ups and its
    /// corrected wide did, and a render of the same stretches read the same,
    /// so that's the speech and not the measuring. The uncorrected wide was
    /// 44 ms out.
    public static let tolerance = 0.030
    /// How far either side of zero the search looks.
    static let reach = 0.25
    /// Readings are this long, this far apart. Long enough to hold several
    /// syllables, short enough to catch one person talking.
    static let windowLength = 8.0
    static let windowStep = 4.0
    static let shortestWindow = 4.0
    /// A reading needs the voice going for this much of it, the face seen
    /// for this much of it, a peak this strong, and to beat the next face
    /// by this much (someone listening, nodding along).
    public static let minimumVoiced = 0.35
    static let minimumCoverage = 0.7
    static let minimumCorrelation = 0.3
    static let minimumMargin = 0.05
    /// Two halves of the readings further apart than this, or a frame if
    /// that's longer, say nothing about one frame.
    static let widestSpread = 0.03
    /// The frames faces are looked for in, per second at most: mouths don't
    /// need 60, and Vision is the slow part.
    static let framesPerSecond = 31.0

    public struct Face: Equatable, Sendable {
        /// Centre and height of the face, as fractions of the frame.
        public var x: Double
        public var y: Double
        public var height: Double
        /// How far the inner lips are apart, as a fraction of the frame's
        /// height. Nil when Vision found the face but not its lips.
        public var opening: Double?

        public init(x: Double, y: Double, height: Double, opening: Double?) {
            self.x = x
            self.y = y
            self.height = height
            self.opening = opening
        }
    }

    public struct Frame: Equatable, Sendable {
        public var time: Double
        public var faces: [Face]

        public init(time: Double, faces: [Face]) {
            self.time = time
            self.faces = faces
        }
    }

    public struct Reading: Equatable, Sendable {
        /// Where the window starts.
        public var time: Double
        /// How far the voice is ahead of the lips, in seconds. Negative: behind.
        public var voiceLead: Double
        public var correlation: Double
        /// The correlation at every lead from -`reach` to +`reach`, a
        /// millisecond apart. One window's peak is broad and wanders; readings
        /// are combined by adding these up and taking the peak of that.
        public var curve: [Float]

        public init(time: Double, voiceLead: Double, correlation: Double, curve: [Float]) {
            self.time = time
            self.voiceLead = voiceLead
            self.correlation = correlation
            self.curve = curve
        }
    }

    public struct Assessment: Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            case inSync, off, unclear
        }
        public var state: State
        /// Where all the readings together peak, and where each half of them
        /// on its own does, the lower first: how far to trust it.
        public var voiceLead: Double
        public var low: Double
        public var high: Double
        /// How far that is from what in-sync footage reads.
        public var offBy: Double
        /// The whole frames to add to the picture delay to close it.
        public var frames: Int
    }

    // MARK: - Reading faces

    /// Every face in each frame of `url` from `from` to `to`, in file time.
    public static func readFaces(_ url: URL, from: Double, to: Double) async throws -> [Frame] {
        let range = CMTimeRange(
            start: CMTime(seconds: max(0, from), preferredTimescale: 48_000),
            end: CMTime(seconds: to, preferredTimescale: 48_000)
        )
        let reader = try await VideoFrameReader(url: url, timeRange: range)
        let orientation = uprightOrientation(reader.transform)
        return try await Blocking.run(qos: .utility) {
            defer { reader.cancel() }
            var frames: [Frame] = []
            var last = -Double.infinity
            while let (buffer, time) = try reader.next() {
                let seconds = time.seconds
                guard seconds < to, seconds >= from, seconds - last >= 1 / framesPerSecond else { continue }
                last = seconds
                autoreleasepool {
                    let request = VNDetectFaceLandmarksRequest()
                    try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:]).perform([request])
                    frames.append(Frame(time: seconds, faces: (request.results ?? []).map(face)))
                }
            }
            return frames
        }
    }

    static func face(_ observation: VNFaceObservation) -> Face {
        let box = observation.boundingBox
        var opening: Double?
        if let lips = observation.landmarks?.innerLips, lips.pointCount > 2 {
            let heights = lips.normalizedPoints.map { Double($0.y) }
            opening = ((heights.max() ?? 0) - (heights.min() ?? 0)) * Double(box.height)
        }
        return Face(x: Double(box.midX), y: Double(box.midY), height: Double(box.height), opening: opening)
    }

    /// Vision only finds faces the right way up, and a phone's file stores
    /// its frames on their side.
    static func uprightOrientation(_ transform: CGAffineTransform) -> CGImagePropertyOrientation {
        if transform.a == 0, transform.b > 0 { return .right }
        if transform.a == 0, transform.b < 0 { return .left }
        if transform.a < 0, transform.d < 0 { return .down }
        return .up
    }

    // MARK: - The voice

    /// The voice's loudness once a millisecond, each over the 25 ms around it,
    /// from 200 Hz to 3 kHz so hum and hiss don't count.
    public static func loudness(_ samples: [Float], rate: Double) -> [Float] {
        var filtered = samples
        lowPass(&filtered, cutoff: 3_000, rate: rate)
        highPass(&filtered, cutoff: 200, rate: rate)
        var total = [Double](repeating: 0, count: filtered.count + 1)
        for i in filtered.indices { total[i + 1] = total[i] + Double(filtered[i]) * Double(filtered[i]) }
        let half = Int(0.0125 * rate)
        let count = Int(Double(filtered.count) / rate * 1000)
        guard half > 0, count > 0 else { return [] }
        return (0..<count).map { ms in
            let middle = Int(Double(ms) / 1000 * rate)
            let first = max(0, middle - half), last = min(filtered.count, middle + half)
            return last > first ? Float(((total[last] - total[first]) / Double(last - first)).squareRoot()) : 0
        }
    }

    private static func highPass(_ x: inout [Float], cutoff: Double, rate: Double) {
        let w = 2 * Double.pi * cutoff / rate
        let alpha = sin(w) / (2 * 2.0.squareRoot() / 2)
        let cw = cos(w)
        biquad(&x, b: [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2], a: [1 + alpha, -2 * cw, 1 - alpha])
    }

    private static func lowPass(_ x: inout [Float], cutoff: Double, rate: Double) {
        let w = 2 * Double.pi * cutoff / rate
        let alpha = sin(w) / (2 * 2.0.squareRoot() / 2)
        let cw = cos(w)
        biquad(&x, b: [(1 - cw) / 2, 1 - cw, (1 - cw) / 2], a: [1 + alpha, -2 * cw, 1 - alpha])
    }

    /// One second-order Butterworth section. Its delay across the voice's
    /// band is well under a millisecond, so it doesn't move the answer.
    private static func biquad(_ x: inout [Float], b: [Double], a: [Double]) {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let input = Double(x[i])
            let output = (b[0] * input + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2) / a[0]
            x2 = x1
            x1 = input
            y2 = y1
            y1 = output
            x[i] = Float(output)
        }
    }

    /// How much of `loudness` has the voice going.
    public static func voicedShare(_ loudness: [Float]) -> Double {
        guard !loudness.isEmpty else { return 0 }
        let sorted = loudness.sorted()
        let loud = sorted[Int(Double(sorted.count - 1) * 0.95)]
        guard loud > 1e-5 else { return 0 }
        return Double(loudness.filter { $0 > loud * 0.1 }.count) / Double(loudness.count)
    }

    // MARK: - Measuring

    /// The faces followed from frame to frame by where they are: per face,
    /// its opening in each frame, nil where it wasn't seen.
    static func follow(_ frames: [Frame]) -> [[Double?]] {
        var last: [(x: Double, y: Double, height: Double)] = []
        var tracks: [[Double?]] = []
        for (index, frame) in frames.enumerated() {
            var taken = Set<Int>()
            for face in frame.faces {
                var best: Int?
                var nearest = Double.infinity
                for (track, seen) in last.enumerated() where !taken.contains(track) {
                    let distance = hypot(face.x - seen.x, face.y - seen.y)
                    // A head moves less than its own height between frames
                    // it was seen in; further than that is someone else.
                    if distance < seen.height, distance < nearest {
                        best = track
                        nearest = distance
                    }
                }
                let track = best ?? tracks.count
                if best == nil {
                    tracks.append([Double?](repeating: nil, count: frames.count))
                    last.append((face.x, face.y, face.height))
                }
                tracks[track][index] = face.opening
                last[track] = (face.x, face.y, face.height)
                taken.insert(track)
            }
        }
        return tracks
    }

    /// The readings in a stretch. `frames` are in the same seconds as
    /// `start`, the time of `loudness`'s first value. In each window the
    /// face that moves with the voice is the one talking.
    public static func measure(frames: [Frame], loudness: [Float], start: Double) -> [Reading] {
        guard let first = frames.first, let final = frames.last else { return [] }
        let tracks = follow(frames)
        let times = frames.map(\.time)
        var readings: [Reading] = []
        let stretch = final.time - first.time
        guard stretch >= shortestWindow else { return [] }
        let length = min(windowLength, stretch)
        var from = first.time
        while from + length <= final.time + 0.001 {
            defer { from += windowStep }
            let to = from + length
            let wanted = Int(max(0, (from - start) * 1000))..<Int(max(0, (to - start) * 1000))
            guard wanted.upperBound <= loudness.count, wanted.count > 1000 else { continue }
            let voice = Array(loudness[wanted])
            guard voicedShare(voice) >= minimumVoiced else { continue }
            var peaks: [(lead: Double, correlation: Double, curve: [Float])] = []
            for track in tracks {
                guard let mouth = resample(track, times: times, from: from, count: voice.count),
                      let peak = peak(mouth: mouth, voice: voice) else { continue }
                peaks.append(peak)
            }
            peaks.sort { $0.correlation > $1.correlation }
            guard let best = peaks.first, best.correlation >= minimumCorrelation else { continue }
            if peaks.count > 1, best.correlation - peaks[1].correlation < minimumMargin { continue }
            readings.append(Reading(time: from, voiceLead: best.lead, correlation: best.correlation, curve: best.curve))
        }
        return readings
    }

    /// One face's opening once a millisecond from `from`, drawn straight
    /// between frames. Nil when it's missing from too much of the window.
    static func resample(_ track: [Double?], times: [Double], from: Double, count: Int) -> [Float]? {
        let to = from + Double(count) / 1000
        var known: [(time: Double, value: Double)] = []
        var total = 0
        for (time, value) in zip(times, track) where time >= from - 0.1 && time <= to + 0.1 {
            total += 1
            if let value { known.append((time, value)) }
        }
        guard total > 0, Double(known.count) / Double(total) >= minimumCoverage else { return nil }
        var out = [Float](repeating: 0, count: count)
        var next = 0
        for i in 0..<count {
            let time = from + Double(i) / 1000
            while next < known.count, known[next].time < time { next += 1 }
            if next == 0 {
                out[i] = Float(known[0].value)
            } else if next == known.count {
                out[i] = Float(known[known.count - 1].value)
            } else {
                let a = known[next - 1], b = known[next]
                out[i] = Float(a.value + (b.value - a.value) * (time - a.time) / (b.time - a.time))
            }
        }
        return out
    }

    /// The lag where mouth and voice agree best, as seconds the voice is
    /// ahead. Nil when either stays flat, or the best is at the very edge of
    /// the search (a rhythm, not a match).
    static func peak(mouth: [Float], voice: [Float]) -> (lead: Double, correlation: Double, curve: [Float])? {
        let count = min(mouth.count, voice.count)
        let reachMs = Int(reach * 1000)
        guard count > 2 * reachMs, let m = normalised(Array(mouth.prefix(count))), let v = normalised(Array(voice.prefix(count))) else { return nil }
        var best = 0.0
        var bestLag = 0
        // Indexed by how far the voice is ahead, so the negative of the lag.
        var curve = [Float](repeating: 0, count: 2 * reachMs + 1)
        for lag in -reachMs...reachMs {
            // Positive lag: the voice matches the mouth later on, so it's late.
            var sum = 0.0
            let n = count - abs(lag)
            m.withUnsafeBufferPointer { m in
                v.withUnsafeBufferPointer { v in
                    for i in 0..<n {
                        sum += Double(lag >= 0 ? m[i] * v[i + lag] : m[i - lag] * v[i])
                    }
                }
            }
            let correlation = sum / Double(n)
            curve[reachMs - lag] = Float(correlation)
            if correlation > best {
                best = correlation
                bestLag = lag
            }
        }
        guard best > 0, abs(bestLag) < reachMs else { return nil }
        return (Double(-bestLag) / 1000, best, curve)
    }

    private static func normalised(_ values: [Float]) -> [Float]? {
        let mean = values.reduce(0, +) / Float(values.count)
        let spread = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)).squareRoot()
        guard spread > 1e-7 else { return nil }
        return values.map { ($0 - mean) / spread }
    }

    // MARK: - Judging

    /// What a file's readings say, given how long one of its frames is:
    /// the picture only moves in whole frames, so that's the size of the fix.
    public static func assess(_ readings: [Reading], frame: Double) -> Assessment? {
        guard let middle = peak(of: readings) else { return nil }
        let odd = peak(of: readings.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)) ?? middle
        let even = peak(of: readings.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)) ?? middle
        let off = middle - naturalLead
        let frames = abs(off) < tolerance ? 0 : Int((off / frame).rounded())
        var state: Assessment.State = frames == 0 ? .inSync : .off
        if readings.count < 2 || abs(odd - even) > max(widestSpread, frame) { state = .unclear }
        return Assessment(state: state, voiceLead: middle, low: min(odd, even), high: max(odd, even), offBy: off, frames: state == .off ? frames : 0)
    }

    /// Where the readings' curves added together peak, as a lead in seconds.
    private static func peak(of readings: [Reading]) -> Double? {
        guard let length = readings.first?.curve.count, length > 0 else { return nil }
        var total = [Float](repeating: 0, count: length)
        for reading in readings {
            for i in 0..<min(length, reading.curve.count) { total[i] += reading.curve[i] }
        }
        guard let best = total.indices.max(by: { total[$0] < total[$1] }) else { return nil }
        return Double(best - length / 2) / 1000
    }
}
