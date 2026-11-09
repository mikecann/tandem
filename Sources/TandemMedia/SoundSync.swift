import Accelerate
import AVFoundation
import Foundation

/// Lines two recordings of the same moment up by their sound: another camera
/// angle or an external mic against the camera take.
///
/// It cross-correlates the two with GCC-PHAT (every frequency weighted the
/// same, so the mics' colours and the room's boom don't smear the peak).
/// First the whole of both at 2 kHz, band-limited to the voice's
/// fundamentals and first formants, which finds the offset to a millisecond
/// wherever the file sits in the reference (it may cover only part of it).
/// Then the overlap in up to sixteen stretches of a minute or more at
/// 8 kHz, each to a fraction of a sample, with a line through them for the
/// offset at the middle and how far the two clocks drift apart over it.
///
/// Short windows don't work in a real room. On Ian's whiteboard interview
/// (October 2026: a RED close-up and its mic 2.855 s ahead of the wide
/// camera, drifting a few milliseconds in 18 min) a 4 s window picks the
/// voice or its bounce off the whiteboard 3 ms later about equally, and a
/// 30 s one still wanders by a couple of milliseconds. Even minute-long
/// stretches move by a millisecond or two as he walks between the cameras
/// (a metre is 3 ms of sound), so the line is a median one (Theil-Sen)
/// that a few odd stretches can't tip, and drift is good to a couple of
/// milliseconds, well under a frame.
public enum SoundSync {
    public struct Match: Codable, Equatable, Sendable {
        /// How much further into the file a moment is than into the
        /// reference, in seconds of each file's own time: the file's time
        /// is the reference's plus this. Positive when the file started
        /// first. Measured at the middle of the overlap.
        public var offset: Double
        /// How much the offset changes from the start of the overlap to its
        /// end, in seconds: the two recorders' clocks running at slightly
        /// different speeds. Nil when the overlap is too short to tell.
        public var drift: Double?
        /// Where the two overlap, in the reference's time.
        public var overlapStart: Double
        public var overlapEnd: Double
        /// How far the match stands out: the correlation's peak over its
        /// standard deviation across every other alignment. Unrelated sound
        /// comes out under 10; Ian's mic against the wide camera, about 60.
        public var confidence: Double
        /// How many of the overlap's stretches found the same offset to
        /// within `fineSearch`, out of how many were measured. When few do,
        /// the whole-file match is suspect: it's what the offset falls back
        /// to, and nothing checked it to the millisecond.
        public var agreed: Int
        public var stretches: Int

        public init(offset: Double, drift: Double?, overlapStart: Double, overlapEnd: Double, confidence: Double, agreed: Int = 0, stretches: Int = 0) {
            self.offset = offset
            self.drift = drift
            self.overlapStart = overlapStart
            self.overlapEnd = overlapEnd
            self.confidence = confidence
            self.agreed = agreed
            self.stretches = stretches
        }

        /// Fewer than half the stretches agreed with the whole-file match.
        public var doubtful: Bool { agreed * 2 < stretches }
    }

    /// Nothing stood out: the two didn't record the same moment, or one of
    /// them has no usable sound.
    public struct NoMatch: Error, LocalizedError, Sendable {
        public var file: String
        public var reference: String
        public var confidence: Double

        public var errorDescription: String? {
            String(format: "%@ doesn't line up with %@ by sound: the best match scores %.0f, and a real one scores over %.0f. Check they recorded the same moment and both have sound.", file, reference, confidence, SoundSync.minimumConfidence)
        }
    }

    /// A match scoring under this is refused.
    public static let minimumConfidence = 15.0
    static let readRate = 8_000.0
    static let coarseRate = 2_000.0
    static let coarseBand = 150.0...900.0
    static let fineBand = 100.0...3_500.0
    /// Four to sixteen stretches, each at least `stretch` seconds where the
    /// overlap is long enough.
    static let stretches = 16
    static let stretch = 60.0
    /// How far either side of the coarse offset the stretches look, how
    /// far either side they measure the background, and how well a stretch
    /// has to stand out against it to count.
    static let fineSearch = 0.02
    static let fineBackground = 0.5
    static let fineConfidence = 8.0
    /// The least overlap that counts as a match.
    static let minimumOverlap = 5.0

    /// A file's sound, read once to match several files against.
    public struct Recording: Sendable {
        public let name: String
        let sound: Sound
    }

    public static func load(_ url: URL) async throws -> Recording {
        Recording(name: url.lastPathComponent, sound: try await read(url))
    }

    public static func match(reference: URL, file: URL) async throws -> Match {
        try await match(try await load(reference), try await load(file))
    }

    public static func match(_ reference: Recording, _ file: Recording) async throws -> Match {
        try await Blocking.run(qos: .userInitiated) {
            try match(reference.sound, file.sound, reference: reference.name, file: file.name)
        }
    }

    static func match(_ a: Sound, _ b: Sound, reference: String, file: String) throws -> Match {
        let factor = Int(readRate / coarseRate)
        let coarseA = decimate(a.samples, by: factor)
        let coarseB = decimate(b.samples, by: factor)
        let minimum = Int(min(minimumOverlap, Double(min(coarseA.count, coarseB.count)) / coarseRate / 2) * coarseRate)
        // b[n] lines up with a[n + k], from b starting near the end of a to
        // b ending near the start of a.
        let lags = (minimum - coarseB.count)...(coarseA.count - minimum)
        let found = correlate(coarseA, coarseB, rate: coarseRate, band: coarseBand, lags: lags)
        guard let coarse = found, coarse.confidence >= minimumConfidence else {
            throw NoMatch(file: file, reference: reference, confidence: found?.confidence ?? 0)
        }
        let coarseOffset = b.start - a.start - coarse.lag / coarseRate
        let overlapStart = max(a.start, b.start - coarseOffset)
        let overlapEnd = min(a.start + a.duration, b.start + b.duration - coarseOffset)
        let length = overlapEnd - overlapStart

        // Each stretch: where it is in the reference, and its offset.
        let count = min(stretches, max(4, Int(length / stretch)))
        let step = length / Double(count)
        var measured: [(time: Double, offset: Double)] = []
        for i in 0..<count {
            let start = overlapStart + Double(i) * step
            if let found = refine(a, b, from: start, length: step, near: coarseOffset), found.confidence >= fineConfidence {
                measured.append((start + step / 2, found.offset))
            }
        }
        var offset = coarseOffset
        var drift: Double?
        if let line = fit(measured) {
            offset = line.offset + line.slope * (overlapStart + overlapEnd) / 2
            // Only when the stretches that agreed span enough of it to tell.
            if line.span >= length / 2 { drift = line.slope * length }
        }
        return Match(offset: offset, drift: drift, overlapStart: overlapStart, overlapEnd: overlapEnd, confidence: coarse.confidence, agreed: measured.count, stretches: count)
    }

    /// The offset over `length` seconds of the reference from `start`,
    /// within `fineSearch` of `near`, and how far it stands out against
    /// every alignment within half a second. Nil past the ends.
    static func refine(_ a: Sound, _ b: Sound, from start: Double, length: Double, near: Double) -> (offset: Double, confidence: Double)? {
        func slice(_ sound: Sound, from: Double, to: Double) -> (samples: [Float], start: Double) {
            let first = max(0, Int(((from - sound.start) * readRate).rounded()))
            let last = min(sound.samples.count, Int(((to - sound.start) * readRate).rounded()))
            guard first < last else { return ([], from) }
            return (Array(sound.samples[first..<last]), sound.start + Double(first) / readRate)
        }
        let x = slice(a, from: start, to: start + length)
        let y = slice(b, from: start + near - fineBackground, to: start + near + length + fineBackground)
        guard x.samples.count > Int(readRate), y.samples.count > Int(readRate) else { return nil }
        // offset = y.start - x.start - lag / rate, so `near` is at:
        let expected = Int(((y.start - x.start - near) * readRate).rounded())
        let reach = Int(fineSearch * readRate)
        let background = Int(fineBackground * readRate)
        guard let peak = correlate(
            x.samples, y.samples, rate: readRate, band: fineBand,
            lags: (expected - reach)...(expected + reach), background: (expected - background)...(expected + background)
        ) else { return nil }
        return (y.start - x.start - peak.lag / readRate, peak.confidence)
    }

    /// A line through the stretches' offsets that a few odd ones can't
    /// pull about (Theil-Sen: the median of the slopes between every pair,
    /// then the median intercept), and how far apart in time they are.
    /// Nil without any.
    static func fit(_ points: [(time: Double, offset: Double)]) -> (offset: Double, slope: Double, span: Double)? {
        guard let first = points.first else { return nil }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }
        var slopes: [Double] = []
        for i in points.indices {
            for j in points.indices where j > i && points[j].time != points[i].time {
                slopes.append((points[j].offset - points[i].offset) / (points[j].time - points[i].time))
            }
        }
        guard !slopes.isEmpty else { return (first.offset, 0, 0) }
        let slope = median(slopes)
        let times = points.map(\.time)
        return (median(points.map { $0.offset - slope * $0.time }), slope, (times.max() ?? 0) - (times.min() ?? 0))
    }

    // MARK: - Reading

    struct Sound: Sendable {
        /// Mono at `readRate`.
        var samples: [Float]
        /// Media time of the first sample.
        var start: Double
        /// Seconds of media.
        var duration: Double
    }

    /// The whole file's sound mixed to mono at `readRate`, from
    /// AVFoundation, or from ffmpeg when AVFoundation can't decode it.
    static func read(_ url: URL) async throws -> Sound {
        do {
            return try await readWithAVFoundation(url)
        } catch let error as MediaError {
            if case .notApplicable = error { throw error }
            guard let ffmpeg = FFmpeg.locate() else { throw error }
            return try await Blocking.run(qos: .userInitiated) { try readWithFFmpeg(ffmpeg, url) }
        }
    }

    /// Placed by the samples' time stamps, so a file whose sound starts late
    /// still lines up with media time.
    static func readWithAVFoundation(_ url: URL) async throws -> Sound {
        let reader = try await AudioReader(url: url, sampleRate: readRate, channels: 1)
        let duration = reader.duration
        let samples = try await Blocking.run(qos: .userInitiated) {
            var samples = [Float](repeating: 0, count: max(0, Int((duration * readRate).rounded())))
            var reached = 0
            while try reader.next({ chunk, frames, stamp in
                var position = Int((stamp.seconds * readRate).rounded())
                var offset = 0
                if position < 0 {
                    offset = min(frames, -position)
                    position += offset
                }
                let count = min(frames - offset, samples.count - position)
                guard count > 0 else { return }
                for i in 0..<count { samples[position + i] = chunk[offset + i] }
                reached = max(reached, position + count)
            }) {}
            return Array(samples.prefix(reached))
        }
        return Sound(samples: samples, start: 0, duration: duration)
    }

    /// Times count from the first sound in the file, which is media time for
    /// the files Tandem syncs (cameras and recorders start their sound at 0).
    static func readWithFFmpeg(_ ffmpeg: FFmpeg, _ url: URL) throws -> Sound {
        let data = try ffmpeg.output(["-v", "error", "-nostdin", "-i", url.path, "-vn", "-map", "0:a:0", "-ac", "1", "-ar", String(Int(readRate)), "-f", "f32le", "-"])
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return Sound(samples: samples, start: 0, duration: Double(samples.count) / readRate)
    }

    /// Every `factor`th sample after a windowed-sinc low-pass under the new
    /// Nyquist. The filter looks ahead rather than behind, which moves both
    /// recordings the same, so their offset is untouched.
    static func decimate(_ samples: [Float], by factor: Int) -> [Float] {
        let taps = 8 * factor + 1
        let cutoff = 0.45 / Double(factor)
        let centre = Double(taps - 1) / 2
        var filter = (0..<taps).map { i -> Float in
            let x = Double(i) - centre
            let sinc = x == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * x) / (Double.pi * x)
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(taps - 1))
            return Float(sinc * window)
        }
        let gain = filter.reduce(0, +)
        filter = filter.map { $0 / gain }
        let count = samples.count / factor
        guard count > 0 else { return [] }
        let padded = samples + [Float](repeating: 0, count: taps)
        var output = [Float](repeating: 0, count: count)
        vDSP_desamp(padded, vDSP_Stride(factor), filter, &output, vDSP_Length(count), vDSP_Length(taps))
        return output
    }

    // MARK: - Correlation

    struct Peak {
        /// In samples, to a fraction: `b[n]` lines up with `a[n + lag]`.
        var lag: Double
        /// The peak over the correlation's standard deviation across the
        /// background lags (the searched ones unless told otherwise).
        var confidence: Double
    }

    /// GCC-PHAT of `a` and `b` over `band`, searched over `lags`: where
    /// `b[n]` best lines up with `a[n + lag]`, and how far that stands out
    /// over `background`.
    static func correlate(_ a: [Float], _ b: [Float], rate: Double, band: ClosedRange<Double>, lags: ClosedRange<Int>, background: ClosedRange<Int>? = nil) -> Peak? {
        guard !a.isEmpty, !b.isEmpty, lags.lowerBound <= lags.upperBound else { return nil }
        var log2n = 1
        while (1 << log2n) < a.count + b.count { log2n += 1 }
        let n = 1 << log2n
        let half = n / 2
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        func spectrum(_ signal: [Float]) -> (real: [Float], imag: [Float]) {
            var padded = signal
            padded.append(contentsOf: repeatElement(0, count: n - signal.count))
            var real = [Float](repeating: 0, count: half)
            var imag = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    padded.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                }
            }
            return (real, imag)
        }

        var (zr, zi) = spectrum(a)
        let (br, bi) = spectrum(b)
        let low = max(1, Int(band.lowerBound / rate * Double(n)))
        let high = min(half - 1, Int(band.upperBound / rate * Double(n)))
        // The cross-spectrum A·conj(B) with every bin brought to the same
        // weight (the phase transform), and nothing outside the band. Bin 0
        // holds DC and Nyquist, both outside it.
        for k in 0..<half {
            var re: Float = 0
            var im: Float = 0
            if k >= low, k <= high {
                re = zr[k] * br[k] + zi[k] * bi[k]
                im = zi[k] * br[k] - zr[k] * bi[k]
                let magnitude = (re * re + im * im).squareRoot()
                if magnitude > 1e-20 {
                    re /= magnitude
                    im /= magnitude
                } else {
                    re = 0
                    im = 0
                }
            }
            zr[k] = re
            zi[k] = im
        }
        var correlation = [Float](repeating: 0, count: n)
        zr.withUnsafeMutableBufferPointer { r in
            zi.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                correlation.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }

        func value(_ lag: Int) -> Double { Double(correlation[((lag % n) + n) % n]) }
        let lower = max(lags.lowerBound, -(n - 1) / 2)
        let upper = min(lags.upperBound, (n - 1) / 2)
        guard lower <= upper else { return nil }
        var best = lower
        for lag in lower...upper where abs(value(lag)) > abs(value(best)) { best = lag }
        let peak = value(best)
        guard peak != 0 else { return nil }
        let wide = background.map { max($0.lowerBound, -(n - 1) / 2)...min($0.upperBound, (n - 1) / 2) } ?? lower...upper
        var sum = 0.0
        var squares = 0.0
        for lag in wide {
            let v = value(lag)
            sum += v
            squares += v * v
        }
        let count = Double(wide.count)
        let spread = max(0, squares / count - (sum / count) * (sum / count)).squareRoot()

        // A parabola through the peak and its neighbours, for the fraction.
        var fraction = 0.0
        if best > lower, best < upper {
            let left = value(best - 1), right = value(best + 1)
            let curve = left - 2 * peak + right
            if curve != 0 { fraction = max(-0.5, min(0.5, 0.5 * (left - right) / curve)) }
        }
        return Peak(lag: Double(best) + fraction, confidence: spread > 0 ? min(10_000, abs(peak) / spread) : 10_000)
    }
}
