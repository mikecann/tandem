import Accelerate
import Foundation

/// A picture of the empty room behind a fixed camera, made from the take
/// itself, that tightens RVM's matte where the room is light.
///
/// RVM sees the frame at 480x270, and next to something the same colour as
/// the wall behind it (the white logo on Mike's cap against his light grey
/// wall) its matte bulged out over about 20 px of wall, which the cutout
/// then showed as a pale smudge. The camera never moves, and over an hour
/// he uncovers every bit of wall round his head and shoulders at some
/// point, so the median of the frames where the matte says "wall" is a
/// clean plate. Each frame's soft edge then loses the alpha of any pixel
/// that looks like the plate there.
///
/// Only where the plate is light: against the dark sofa and chair his navy
/// jacket matched the plate as closely as the wall did, and the edge went
/// jagged. And never in the solid core of the matte (eroded by about 8 px
/// at 1080p), or where the plate never saw the wall, so a mistake can only
/// shave the outer edge. Measured on the Threadbear launch take
/// (docs/MEDIA.md): the bulge over the logo went, and the edge flickered
/// less (1.2 against 1.5 on 0 to 255 between still frames).
///
/// Everything is in the model's content size (1280x720 for a 16:9 take),
/// colour as BGRA, alpha and masks as 0...255.
struct CleanPlate {
    let width: Int
    let height: Int
    /// The plate, a little blurred, BGRA.
    let blurred: [UInt8]
    /// Where the plate saw the wall (255) and where it never did (0).
    let seen: [UInt8]
    /// How far to trust the plate: light and seen, 0...255.
    let use: [UInt8]

    /// Frames sampled across the take for the plate.
    static let sampleCount = 80
    /// A sample's pixel counts as wall where its matte, grown by this share
    /// of the height, is under `wallAlpha`: the person's soft edge and
    /// motion blur stay out of the plate.
    static let maskGrowth = 0.006
    static let wallAlpha: UInt8 = 5
    /// A camera that moved, or a background that kept changing, gives no
    /// plate: fewer than this share of a pixel's wall samples sat within
    /// `steadyLevel` of its median, on average.
    static let steadyShare = 0.75
    static let steadyLevel = 14
    /// And too little of the frame seen to be worth it.
    static let minimumSeen = 0.3
    /// Colour distance (0...441) from the plate where a pixel goes from
    /// "the wall" to "not the wall".
    static let keyFrom = 10.0, keyTo = 30.0
    /// Plate lightness (0...1) where it starts and finishes counting.
    static let lightFrom = 0.35, lightTo = 0.5
    /// The solid core left alone, as a share of the height (8 px at 1080p).
    static let coreProtect = 8.0 / 1080

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case tooFewSamples
        case notSteady(Double)
        case tooLittleSeen(Double)

        var description: String {
            switch self {
            case .tooFewSamples: return "too few frames to sample"
            case .notSteady(let share): return String(format: "the background moves (%.0f%% steady)", share * 100)
            case .tooLittleSeen(let share): return String(format: "only %.0f%% of the room is ever seen", share * 100)
            }
        }
    }

    /// The plate (BGRA) and where it saw the wall (0 or 255) from `samples`
    /// (BGRA, width x height) and their mattes (0...255), at that size.
    /// Sampled at half the model's size: 80 frames at 640x360 are 74 MB.
    static func make(samples: [[UInt8]], mattes: [[UInt8]], width: Int, height: Int) -> Result<(plate: [UInt8], seen: [UInt8]), Refusal> {
        let count = width * height
        guard samples.count >= 8, samples.count == mattes.count else { return .failure(.tooFewSamples) }
        // Wall pixels in each sample: the matte grown, then under wallAlpha.
        let grow = 2 * max(1, Int((maskGrowth * Double(height)).rounded())) + 1
        let walls: [[Bool]] = mattes.map { matte in
            MatteBlender.morphology(matte, width, height, kernel: grow, grow: true).map { $0 < wallAlpha }
        }
        var plate = [UInt8](repeating: 0, count: count * 4)
        var seen = [UInt8](repeating: 0, count: count)
        var values = [UInt8](repeating: 0, count: samples.count)
        var which = [Int](repeating: 0, count: samples.count)
        var seenCount = 0
        for pixel in 0..<count {
            var n = 0
            for s in 0..<samples.count where walls[s][pixel] { which[n] = s; n += 1 }
            // Three sightings at least: one could be a passing shadow.
            guard n >= 3 else { continue }
            seen[pixel] = 255
            seenCount += 1
            for channel in 0..<3 {
                for k in 0..<n { values[k] = samples[which[k]][pixel * 4 + channel] }
                plate[pixel * 4 + channel] = median(&values, n)
            }
            plate[pixel * 4 + 3] = 255
        }
        let seenShare = Double(seenCount) / Double(max(1, count))
        guard seenShare >= minimumSeen else { return .failure(.tooLittleSeen(seenShare)) }

        // Is it steady? Each sample's exposure drifts over a long take (the
        // light through a window), so its mean difference from the plate
        // comes off first; then a wall pixel should sit near the plate.
        var steady = 0, sightings = 0
        for s in 0..<samples.count {
            var offset = [Double](repeating: 0, count: 3), n = 0
            for pixel in 0..<count where walls[s][pixel] && seen[pixel] != 0 {
                for c in 0..<3 { offset[c] += Double(samples[s][pixel * 4 + c]) - Double(plate[pixel * 4 + c]) }
                n += 1
            }
            guard n > 0 else { continue }
            let shift = offset.map { Int(($0 / Double(n)).rounded()) }
            for pixel in 0..<count where walls[s][pixel] && seen[pixel] != 0 {
                var far = 0
                for c in 0..<3 { far = max(far, abs(Int(samples[s][pixel * 4 + c]) - shift[c] - Int(plate[pixel * 4 + c]))) }
                if far <= steadyLevel { steady += 1 }
                sightings += 1
            }
        }
        let steadyShare = Double(steady) / Double(max(1, sightings))
        guard steadyShare >= self.steadyShare else { return .failure(.notSteady(steadyShare)) }
        return .success((plate, seen))
    }

    /// The plate scaled to the model's content size.
    init(plate: [UInt8], seen: [UInt8], sampleWidth: Int, sampleHeight: Int, width: Int, height: Int) {
        if sampleWidth == width, sampleHeight == height {
            self.init(plate: plate, seen: seen, width: width, height: height)
            return
        }
        var source = plate, out = [UInt8](repeating: 0, count: width * height * 4)
        source.withUnsafeMutableBytes { input in
            out.withUnsafeMutableBytes { output in
                var a = vImage_Buffer(data: input.baseAddress, height: vImagePixelCount(sampleHeight), width: vImagePixelCount(sampleWidth), rowBytes: sampleWidth * 4)
                var b = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                _ = vImageScale_ARGB8888(&a, &b, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        var seenSource = seen, seenOut = [UInt8](repeating: 0, count: width * height)
        MatteBlender.withImage(&seenSource, sampleWidth, sampleHeight) { input in
            MatteBlender.withImage(&seenOut, width, height) { output in
                _ = vImageScale_Planar8(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        // Seen or not, no in between: a half-seen pixel isn't one to trust.
        self.init(plate: out, seen: seenOut.map { $0 >= 250 ? 255 : 0 }, width: width, height: height)
    }

    init(plate: [UInt8], seen: [UInt8], width: Int, height: Int) {
        self.width = width
        self.height = height
        self.seen = seen
        blurred = Self.tent(plate, width, height, size: 3)
        // Lightness of the plate, blurred more, through lightFrom...lightTo.
        let wide = Self.tent(plate, width, height, size: 2 * max(1, Int((3.0 * Double(height) / 1080).rounded())) + 1)
        var use = [UInt8](repeating: 0, count: width * height)
        for i in 0..<use.count where seen[i] != 0 {
            let b = Double(wide[i * 4]), g = Double(wide[i * 4 + 1]), r = Double(wide[i * 4 + 2])
            let lightness = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            use[i] = UInt8((Self.smoothstep(Self.lightFrom, Self.lightTo, lightness) * 255).rounded())
        }
        self.use = use
    }

    /// Tightens `alpha` (width x height) against the plate for `frame`
    /// (BGRA, width x height): only takes alpha away, and only on the soft
    /// edge over light, seen wall.
    func refine(_ alpha: inout [UInt8], frame: [UInt8]) {
        let count = width * height
        guard alpha.count == count, frame.count == count * 4 else { return }
        // The frame's exposure against the plate's, from the wall it shows.
        var sumFrame = [Double](repeating: 0, count: 3), sumPlate = [Double](repeating: 0, count: 3)
        for i in 0..<count where alpha[i] < Self.wallAlpha && seen[i] != 0 {
            for c in 0..<3 {
                sumFrame[c] += Double(frame[i * 4 + c])
                sumPlate[c] += Double(blurred[i * 4 + c])
            }
        }
        let gain = (0..<3).map { c in sumPlate[c] > 0 ? min(1.6, max(0.6, sumFrame[c] / sumPlate[c])) : 1 }
        let picture = Self.tent(frame, width, height, size: 3)

        // 255 where the pixel isn't the wall, 0 where it is.
        var key = [UInt8](repeating: 255, count: count)
        let span = Self.keyTo - Self.keyFrom
        for i in 0..<count where use[i] != 0 && alpha[i] != 0 {
            var d2 = 0.0
            for c in 0..<3 {
                let d = Double(picture[i * 4 + c]) - gain[c] * Double(blurred[i * 4 + c])
                d2 += d * d
            }
            let t = min(1, max(0, (d2.squareRoot() - Self.keyFrom) / span))
            key[i] = UInt8((t * t * (3 - 2 * t) * 255).rounded())
        }
        // Lone specks either way are noise in the camera, not the edge.
        key = MatteBlender.morphology(key, width, height, kernel: 3, grow: false)
        key = MatteBlender.morphology(key, width, height, kernel: 3, grow: true)
        key = MatteBlender.morphology(key, width, height, kernel: 3, grow: true)
        key = MatteBlender.morphology(key, width, height, kernel: 3, grow: false)

        // The solid core, eroded and softened, keeps RVM's alpha.
        let protect = 2 * max(1, Int((Self.coreProtect * Double(height)).rounded())) + 1
        var core = MatteBlender.morphology(alpha.map { $0 > 250 ? 255 : 0 }, width, height, kernel: protect, grow: false)
        core = Self.tentPlanar(Self.tentPlanar(core, width, height, size: 3), width, height, size: 3)

        for i in 0..<count {
            let keep = max(key[i], core[i], 255 - use[i])
            if alpha[i] > keep { alpha[i] = keep }
        }
    }

    // MARK: - Helpers

    static func smoothstep(_ from: Double, _ to: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }

    /// The median of the first `n` values (reorders them).
    static func median(_ values: inout [UInt8], _ n: Int) -> UInt8 {
        values.withUnsafeMutableBufferPointer { buffer in
            var slice = UnsafeMutableBufferPointer(rebasing: buffer[0..<n])
            slice.sort()
            return n % 2 == 1 ? slice[n / 2] : UInt8((Int(slice[n / 2 - 1]) + Int(slice[n / 2]) + 1) / 2)
        }
    }

    /// A size x size tent blur of a BGRA picture.
    static func tent(_ pixels: [UInt8], _ width: Int, _ height: Int, size: Int) -> [UInt8] {
        var source = pixels
        var out = [UInt8](repeating: 0, count: pixels.count)
        source.withUnsafeMutableBytes { input in
            out.withUnsafeMutableBytes { output in
                var a = vImage_Buffer(data: input.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var b = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                _ = vImageTentConvolve_ARGB8888(&a, &b, nil, 0, 0, UInt32(size), UInt32(size), nil, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    /// A size x size tent blur of a one-channel plane.
    static func tentPlanar(_ pixels: [UInt8], _ width: Int, _ height: Int, size: Int) -> [UInt8] {
        var source = pixels
        var out = [UInt8](repeating: 0, count: pixels.count)
        MatteBlender.withImage(&source, width, height) { input in
            MatteBlender.withImage(&out, width, height) { output in
                _ = vImageTentConvolve_Planar8(&input, &output, nil, 0, 0, UInt32(size), UInt32(size), 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    /// The `rect` of a BGRA pixel buffer, row by row, as packed BGRA.
    static func packed(_ base: UnsafeRawPointer, rowBytes: Int, rect: CGRect) -> [UInt8] {
        let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { raw in
            for row in 0..<h {
                memcpy(raw.baseAddress! + row * w * 4, base + (y + row) * rowBytes + x * 4, w * 4)
            }
        }
        return out
    }
}
