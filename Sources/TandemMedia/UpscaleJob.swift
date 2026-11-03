import Accelerate
import AVFoundation
import CoreML
import CoreVideo
import Foundation
import TandemCore
import VideoToolbox

/// A stretch of a file's media time in whole seconds, rounded outwards, so
/// trimming a clip by a few frames finds the copy it already has.
public struct UpscaleSpan: Hashable, Codable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = max(0, start)
        self.end = max(self.start + 1, end)
    }

    public init(covering range: TimeRange) {
        self.init(start: Int(range.start.seconds.rounded(.down)), end: Int(range.end.seconds.rounded(.up)))
    }

    public var timeRange: TimeRange { TimeRange(start: Time(seconds: Double(start)), end: Time(seconds: Double(end))) }

    public func contains(_ range: TimeRange) -> Bool {
        timeRange.start <= range.start && range.end <= timeRange.end
    }

    /// The settings part of the copy's cache key.
    var canonical: String { "{\"end\":\(end),\"start\":\(start)}" }
}

/// Twice-the-size copies of screen recordings, for zooms that would
/// otherwise stretch the pixels.
///
/// A 3200 x 1800 Retina recording on a 4K timeline is already scaled up
/// 1.2x, and zoomed 1.8x into a popover it's 2.16x: small UI text goes soft
/// however well it's resampled. Screen Studio 4.0 trains its own model on
/// generated macOS screenshots for this; Tandem uses Real-ESRGAN's
/// realesr-animevideov3 (BSD-3-Clause), a small network for flat, hard-edged
/// pictures like anime that does well on UI text too, converted to Core ML
/// (Resources/Upscaler/convert.py). On the M5's GPU it takes about 0.3 s per
/// 1778 x 1000 region.
///
/// The copy covers one stretch of the file (`UpscaleSpan`) at the file's own
/// frame times, with a black frame held before it, so the composition reads
/// it at the same media times as the original. The frame is worked in
/// 512 px tiles, and a tile goes through the model again only when it has
/// changed since it last did: on a screen recording most of the picture
/// holds still from frame to frame (a few tiles of 28 change, mostly where
/// the pointer is), so after the first frame it's a fraction of the work.
enum UpscaleJob {
    static let file = "upscaled.mov"
    /// Bump when copies change; it's in their cache key.
    static let version = 1

    static func doubled(_ transform: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 2 * transform.tx, ty: 2 * transform.ty)
    }

    static func run(source: URL, span: UpscaleSpan, into folder: URL, context: JobContext) async throws {
        context.progress(0, message: "Loading the upscaler")
        let model = try await UpscaleModel.shared.load()
        let range = CMTimeRange(start: CMTime(seconds: Double(span.start), preferredTimescale: 600), end: CMTime(seconds: Double(span.end), preferredTimescale: 600))
        let reader = try await VideoFrameReader(url: source, timeRange: range)
        let width = Int(reader.size.width), height = Int(reader.size.height)
        guard width >= UpscaleTiles.tile, height >= UpscaleTiles.tile else {
            throw MediaError.notApplicable("\(source.lastPathComponent) is smaller than the upscaler's \(UpscaleTiles.tile) px tiles")
        }
        let tiles = try UpscaleTiles(model: model, width: width, height: height)
        let writer = try EncodedMovieWriter(url: folder.appendingPathComponent(file), settings: .init(
            width: width * 2, height: height * 2,
            // Like the proxy: P-frames leave still areas still, and a
            // keyframe every second keeps seeking into the copy cheap.
            keyFrameInterval: 30, quality: 0.8, prioritizeSpeed: true,
            colorPrimaries: reader.colors.primaries, transferFunction: reader.colors.transfer, yCbCrMatrix: reader.colors.matrix,
            // A rotation's translation is in pixels, so it doubles too.
            timescale: reader.timescale, transform: Self.doubled(reader.transform),
            expectedFrameRate: reader.nominalFrameRate > 0 ? reader.nominalFrameRate : nil
        ))
        let converter = try FrameConverter(width: width, height: height)
        let counter = FrameCounter()
        let redone = FrameCounter()
        await context.acquireEncoder()
        do {
            while true {
                let more = try await Blocking.run(qos: context.qos) { () -> Bool in
                    for _ in 0..<10 {
                        guard let frame = try reader.next() else { return false }
                        // The copy's times are the file's: before the span
                        // it holds a black frame nothing shows.
                        if counter.count == 0, frame.time > .zero {
                            try writer.append(try tiles.blank(), at: .zero)
                        }
                        let bgra = try converter.bgra(frame.buffer)
                        redone.count += try tiles.upscale(bgra)
                        let out = try tiles.output()
                        CVBufferPropagateAttachments(frame.buffer, out)
                        try writer.append(out, at: frame.time)
                        counter.count += 1
                    }
                    return true
                }
                let average = Double(redone.count) / Double(max(1, counter.count))
                context.progress(Double(counter.count) / Double(max(1, reader.frameCount)),
                                 message: "Frame \(counter.count) of \(reader.frameCount), \(String(format: "%.1f", average)) of \(tiles.count) tiles a frame through the model")
                if !more { break }
                try await context.checkpoint()
            }
            try await writer.finish(endTime: reader.endTime)
        } catch {
            reader.cancel()
            writer.cancel()
            throw error
        }
    }
}

/// The bundled model, compiled for this Mac once per process.
actor UpscaleModel {
    static let shared = UpscaleModel()
    private var loaded: MLModel?

    static var packageURL: URL? {
        Bundle.module.url(forResource: "Upscaler2x", withExtension: "mlpackage", subdirectory: "Upscaler")
    }

    func load() throws -> MLModel {
        if let loaded { return loaded }
        guard let package = Self.packageURL else { throw MediaError.failed("The upscaler model isn't in Tandem's resources") }
        let compiled = try MLModel.compileModel(at: package)
        let configuration = MLModelConfiguration()
        // The GPU was quickest on the M5 (0.32 s a region, against 0.54 s on
        // the Neural Engine); `.all` lets Core ML choose it.
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        loaded = model
        return model
    }
}

/// Turns decoded 4:2:0 frames into BGRA for the model.
final class FrameConverter: @unchecked Sendable {
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int) throws {
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr, let created else {
            throw MediaError.failed("VideoToolbox couldn't start a pixel transfer")
        }
        session = created
        pool = try makePixelBufferPool(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
    }

    deinit { VTPixelTransferSessionInvalidate(session) }

    func bgra(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { throw MediaError.failed("Out of frame buffers") }
        let status = VTPixelTransferSessionTransferImage(session, from: frame, to: out)
        guard status == noErr else { throw MediaError.failed("Couldn't convert a frame for the upscaler (\(status))") }
        return out
    }
}

/// The picture in overlapping tiles, each upscaled by the model when it has
/// changed, into a frame twice the size.
final class UpscaleTiles: @unchecked Sendable {
    /// The model's input size.
    static let tile = 512
    /// Each tile reads this far past the part it keeps, so the network
    /// (18 3x3 convolutions, reaching 18 px) sees the same neighbourhood
    /// whichever tile a pixel falls in, and the tiles meet without seams.
    static let pad = 24
    /// A tile counts as changed when a channel of a pixel moved by more
    /// than this since it last went through the model. HEVC wobbles still
    /// areas by a step or two; the pointer, typing and scrolling move by far
    /// more. Comparing with the frame it last went through (not the one
    /// before) means a slow fade can't creep past unnoticed.
    static let tolerance: UInt8 = 6

    struct Tile {
        /// The part of the frame this tile keeps.
        var keep: CGRect
        /// Where its model input starts (the tile's top left).
        var x: Int
        var y: Int
        /// The input as it last went through the model.
        var reference: [UInt8]?
    }

    let width: Int
    let height: Int
    private let model: MLModel
    private var tiles: [Tile] = []
    private let input: CVPixelBuffer
    private let result: CVPixelBuffer
    /// The upscaled frame so far, BGRA, twice the size.
    private var canvas: [UInt8]
    private let pool: CVPixelBufferPool
    /// Scratch space, made once: a tile's input, and two tiles as floats
    /// for comparing. Making them afresh for every tile of every frame was
    /// most of the job's time.
    private let pixels: UnsafeMutableBufferPointer<UInt8>
    private let scratchA: UnsafeMutableBufferPointer<Float>
    private let scratchB: UnsafeMutableBufferPointer<Float>

    var count: Int { tiles.count }

    init(model: MLModel, width: Int, height: Int) throws {
        self.model = model
        self.width = width
        self.height = height
        let size = Self.tile, step = Self.tile - 2 * Self.pad
        for top in stride(from: 0, to: height, by: step) {
            for left in stride(from: 0, to: width, by: step) {
                let keep = CGRect(x: left, y: top, width: min(step, width - left), height: min(step, height - top))
                tiles.append(Tile(keep: keep, x: min(max(0, left - Self.pad), width - size), y: min(max(0, top - Self.pad), height - size)))
            }
        }
        input = try Self.buffer(size, size)
        result = try Self.buffer(2 * size, 2 * size)
        // Opaque black until the first frame fills it.
        canvas = [UInt8](repeating: 0, count: 4 * width * height * 4)
        var black: [UInt8] = [0, 0, 0, 255]
        canvas.withUnsafeMutableBytes { memset_pattern4($0.baseAddress!, &black, $0.count) }
        pool = try makePixelBufferPool(width: 2 * width, height: 2 * height, pixelFormat: kCVPixelFormatType_32BGRA)
        let bytes = size * size * 4
        pixels = .allocate(capacity: bytes)
        scratchA = .allocate(capacity: bytes)
        scratchB = .allocate(capacity: bytes)
    }

    deinit {
        pixels.deallocate()
        scratchA.deallocate()
        scratchB.deallocate()
    }

    static func buffer(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { throw MediaError.failed("Couldn't make a \(width) x \(height) frame buffer") }
        return buffer
    }

    /// Brings the canvas up to date with `frame` (BGRA, the source size).
    /// Returns how many tiles went through the model.
    func upscale(_ frame: CVPixelBuffer) throws -> Int {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        let size = Self.tile
        var redone = 0
        for index in tiles.indices {
            let tile = tiles[index]
            // The tile's input, row by row.
            for row in 0..<size {
                memcpy(pixels.baseAddress! + row * size * 4, base + (tile.y + row) * rowBytes + tile.x * 4, size * 4)
            }
            let current = UnsafeBufferPointer(pixels)
            if let reference = tile.reference,
               !reference.withUnsafeBufferPointer({ Self.differs($0, current, by: Self.tolerance, scratch: (scratchA, scratchB)) }) { continue }
            try run(current, tile)
            tiles[index].reference = Array(current)
            redone += 1
        }
        return redone
    }

    /// One tile through the model, its kept part into the canvas.
    private func run(_ pixels: UnsafeBufferPointer<UInt8>, _ tile: Tile) throws {
        let size = Self.tile
        CVPixelBufferLockBaseAddress(input, [])
        let inBase = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
        let inRow = CVPixelBufferGetBytesPerRow(input)
        for row in 0..<size { memcpy(inBase + row * inRow, pixels.baseAddress! + row * size * 4, size * 4) }
        CVPixelBufferUnlockBaseAddress(input, [])

        let options = MLPredictionOptions()
        options.outputBackings = ["output": result]
        let features = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(pixelBuffer: input)])
        _ = try model.prediction(from: features, options: options)

        CVPixelBufferLockBaseAddress(result, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(result, .readOnly) }
        let outBase = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        let outRow = CVPixelBufferGetBytesPerRow(result)
        let keepX = 2 * (Int(tile.keep.minX) - tile.x), keepY = 2 * (Int(tile.keep.minY) - tile.y)
        let keepWidth = 2 * Int(tile.keep.width), keepHeight = 2 * Int(tile.keep.height)
        let canvasRow = 2 * width * 4
        canvas.withUnsafeMutableBytes { canvas in
            for row in 0..<keepHeight {
                let to = (2 * Int(tile.keep.minY) + row) * canvasRow + 2 * Int(tile.keep.minX) * 4
                memcpy(canvas.baseAddress! + to, outBase + (keepY + row) * outRow + keepX * 4, keepWidth * 4)
            }
        }
    }

    /// The canvas in a new buffer for the encoder (which keeps it a while).
    func output() throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { throw MediaError.failed("Out of frame buffers") }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let base = CVPixelBufferGetBaseAddress(out)!
        let rowBytes = CVPixelBufferGetBytesPerRow(out), canvasRow = 2 * width * 4
        canvas.withUnsafeBytes { canvas in
            for row in 0..<(2 * height) { memcpy(base + row * rowBytes, canvas.baseAddress! + row * canvasRow, canvasRow) }
        }
        return out
    }

    /// A black frame the copy's size.
    func blank() throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { throw MediaError.failed("Out of frame buffers") }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        // BGRA black, opaque.
        var black: [UInt8] = [0, 0, 0, 255]
        memset_pattern4(CVPixelBufferGetBaseAddress(out)!, &black, CVPixelBufferGetBytesPerRow(out) * 2 * height)
        return out
    }

    /// Whether any byte of `a` and `b` is more than `tolerance` apart.
    /// Equal tiles stop at `memcmp`; the rest go through Accelerate, which
    /// is quick in debug builds too, unlike a Swift loop over a megabyte a
    /// tile. `scratch` holds `a.count` floats each.
    static func differs(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, by tolerance: UInt8,
                        scratch: (UnsafeMutableBufferPointer<Float>, UnsafeMutableBufferPointer<Float>)) -> Bool {
        precondition(a.count == b.count && scratch.0.count >= a.count && scratch.1.count >= a.count)
        if memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 { return false }
        let n = vDSP_Length(a.count)
        let x = scratch.0.baseAddress!, y = scratch.1.baseAddress!
        vDSP_vfltu8(a.baseAddress!, 1, x, 1, n)
        vDSP_vfltu8(b.baseAddress!, 1, y, 1, n)
        vDSP_vsub(y, 1, x, 1, x, 1, n)
        var largest: Float = 0
        vDSP_maxmgv(x, 1, &largest, n)
        return largest > Float(tolerance)
    }

    static func differs(_ a: [UInt8], _ b: [UInt8], by tolerance: UInt8) -> Bool {
        let x = UnsafeMutableBufferPointer<Float>.allocate(capacity: a.count), y = UnsafeMutableBufferPointer<Float>.allocate(capacity: a.count)
        defer { x.deallocate(); y.deallocate() }
        return a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { b in differs(a, b, by: tolerance, scratch: (x, y)) } }
    }
}
