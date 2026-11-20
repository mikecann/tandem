import CoreVideo
import Foundation
import VideoToolbox

/// HDR video (an iPhone's HLG, PQ) brought down to SDR BT.709 for the
/// compositor, the same way in every path.
///
/// Left to AVFoundation, each path converted it its own way: an
/// AVAssetReader (exports, `tandem check`) decodes it straight to BT.709,
/// while the player and frame grabs got a brighter conversion, so a paused
/// frame or `tandem frame` didn't look like the export (a warm grey came
/// out 154/116/78 in a still and 135/83/52 exported, 20 Nov 2026). So the
/// compositor takes HDR frames as they are (`supportsHDRSourceFrames`) and
/// converts them here with VideoToolbox, which lands within a level of
/// what exports have always shown.
final class HDRFrames: @unchecked Sendable {
    static let shared = HDRFrames()

    private let lock = NSLock()
    /// Sessions aren't for sharing between threads; the compositor renders
    /// several frames at once, so each takes one of its own for a frame.
    private var idle: [VTPixelTransferSession] = []
    private var pools: [String: CVPixelBufferPool] = [:]

    static let hdrTransfers: Set<String> = [
        kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
    ]

    /// Whether a frame is tagged HLG or PQ.
    static func isHDR(_ buffer: CVPixelBuffer) -> Bool {
        guard let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String else { return false }
        return hdrTransfers.contains(transfer)
    }

    /// The frame in SDR BT.709, or the frame itself when it isn't HDR:
    /// 8-bit 4:2:0 video range (as decoders hand the compositor SDR video),
    /// or BGRA for a frame with alpha, which keeps it.
    func sdr(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        guard Self.isHDR(buffer) else { return buffer }
        let format: OSType = CVPixelBufferIsPlanar(buffer) ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        if let converted = convert(buffer, to: format, pooled: true) { return converted }
        // Short of memory, most likely: once more with a buffer of its own.
        // An HDR frame shown as it is comes out a flash of wrong colour.
        if let converted = convert(buffer, to: format, pooled: false) { return converted }
        NSLog("Tandem: couldn't convert an HDR frame to SDR; it shows unconverted")
        return buffer
    }

    private func convert(_ buffer: CVPixelBuffer, to format: OSType, pooled: Bool) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let session = pooled ? take() : Self.makeSession() else { return nil }
        defer { if pooled { give(session) } }
        var made: CVPixelBuffer?
        if pooled {
            guard let pool = pool(width: width, height: height, format: format),
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess else { return nil }
        } else {
            guard CVPixelBufferCreate(nil, width, height, format, Self.attributes(width: width, height: height, format: format) as CFDictionary, &made) == kCVReturnSuccess else { return nil }
        }
        guard let out = made, VTPixelTransferSessionTransferImage(session, from: buffer, to: out) == noErr else { return nil }
        return out
    }

    private func take() -> VTPixelTransferSession? {
        if let session = lock.withLock({ idle.popLast() }) { return session }
        return Self.makeSession()
    }

    private static func makeSession() -> VTPixelTransferSession? {
        var made: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &made) == noErr, let session = made else { return nil }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        return session
    }

    private func give(_ session: VTPixelTransferSession) {
        lock.withLock { if idle.count < 8 { idle.append(session) } }
    }

    private static func attributes(width: Int, height: Int, format: OSType) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    /// A pool per frame size and format. Pools let go of buffers nobody has
    /// used for a second by themselves.
    private func pool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let key = "\(width)x\(height) \(format)"
        return lock.withLock {
            if let pool = pools[key] { return pool }
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, Self.attributes(width: width, height: height, format: format) as CFDictionary, &made)
            if pools.count >= 8, let any = pools.keys.first { pools[any] = nil }
            pools[key] = made
            return made
        }
    }
}
