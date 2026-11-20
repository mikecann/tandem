import Accelerate
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
    /// Pools by frame size and format, least recently used first.
    private var pools: [(key: String, pool: CVPixelBufferPool)] = []
    private let maxPools = 8

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
        if let converted = convert(buffer, pooled: true) { return converted }
        // Short of memory, most likely: once more with a session and buffers
        // of its own. An HDR frame shown as it is is a flash of wrong colour.
        if let converted = convert(buffer, pooled: false) { return converted }
        NSLog("Tandem: couldn't convert an HDR frame to SDR; it shows unconverted")
        return buffer
    }

    private func convert(_ buffer: CVPixelBuffer, pooled: Bool) -> CVPixelBuffer? {
        guard CVPixelBufferIsPlanar(buffer) else { return convertWithAlpha(buffer, pooled: pooled) }
        return transfer(buffer, to: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, pooled: pooled)
    }

    /// One VideoToolbox transfer to BT.709 in `format`. A session that
    /// fails is let go rather than handed to the next frame.
    private func transfer(_ buffer: CVPixelBuffer, to format: OSType, pooled: Bool) -> CVPixelBuffer? {
        guard let session = pooled ? take() : Self.makeSession() else { return nil }
        guard let out = makeBuffer(like: buffer, format: format, pooled: pooled) else {
            if pooled { give(session) } else { VTPixelTransferSessionInvalidate(session) }
            return nil
        }
        guard VTPixelTransferSessionTransferImage(session, from: buffer, to: out) == noErr else {
            VTPixelTransferSessionInvalidate(session)
            return nil
        }
        if pooled { give(session) } else { VTPixelTransferSessionInvalidate(session) }
        return out
    }

    /// A frame with alpha (BGRA). The conversion to SDR isn't linear, so it
    /// works on colours as they'd show at full opacity: premultiplied
    /// frames (Core Image's default) are unpremultiplied first and
    /// premultiplied again after, or a half-transparent edge comes out
    /// darker than it should. The result says which kind it is, as the
    /// frame did, since a pooled buffer may still carry the last one's tag.
    private func convertWithAlpha(_ buffer: CVPixelBuffer, pooled: Bool) -> CVPixelBuffer? {
        // Other packed formats: converted as they are, as BGRA.
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            return transfer(buffer, to: kCVPixelFormatType_32BGRA, pooled: pooled)
        }
        let mode = CVBufferCopyAttachment(buffer, kCVImageBufferAlphaChannelModeKey, nil) as? String
        let straight = mode == (kCVImageBufferAlphaChannelMode_StraightAlpha as String)
        var source = buffer
        if !straight {
            guard let copy = makeBuffer(like: buffer, format: kCVPixelFormatType_32BGRA, pooled: pooled),
                  Self.premultiply(buffer, into: copy, undo: true) else { return nil }
            CVBufferPropagateAttachments(buffer, copy)
            // Its colour tags too, even ones set not to carry over: without
            // them the copy wouldn't be converted at all.
            for key in [kCVImageBufferTransferFunctionKey, kCVImageBufferColorPrimariesKey, kCVImageBufferYCbCrMatrixKey, kCVImageBufferCGColorSpaceKey] {
                if let value = CVBufferCopyAttachment(buffer, key, nil) { CVBufferSetAttachment(copy, key, value, .shouldPropagate) }
            }
            CVBufferSetAttachment(copy, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
            source = copy
        }
        guard let out = transfer(source, to: kCVPixelFormatType_32BGRA, pooled: pooled) else { return nil }
        if !straight { guard Self.premultiply(out, into: out, undo: false) else { return nil } }
        CVBufferSetAttachment(out, kCVImageBufferAlphaChannelModeKey,
                              straight ? kCVImageBufferAlphaChannelMode_StraightAlpha : kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                              .shouldPropagate)
        return out
    }

    /// BGRA premultiplied by its alpha, or with `undo` unpremultiplied (the
    /// RGBA functions: alpha is last in both, and the rest is alike).
    private static func premultiply(_ from: CVPixelBuffer, into to: CVPixelBuffer, undo: Bool) -> Bool {
        let same = from === to
        CVPixelBufferLockBaseAddress(from, same ? [] : .readOnly)
        if !same { CVPixelBufferLockBaseAddress(to, []) }
        defer {
            if !same { CVPixelBufferUnlockBaseAddress(to, []) }
            CVPixelBufferUnlockBaseAddress(from, same ? [] : .readOnly)
        }
        guard let fromBase = CVPixelBufferGetBaseAddress(from), let toBase = CVPixelBufferGetBaseAddress(to) else { return false }
        let width = vImagePixelCount(CVPixelBufferGetWidth(from))
        let height = vImagePixelCount(CVPixelBufferGetHeight(from))
        var source = vImage_Buffer(data: fromBase, height: height, width: width, rowBytes: CVPixelBufferGetBytesPerRow(from))
        var destination = vImage_Buffer(data: toBase, height: height, width: width, rowBytes: CVPixelBufferGetBytesPerRow(to))
        let error = undo
            ? vImageUnpremultiplyData_RGBA8888(&source, &destination, vImage_Flags(kvImageNoFlags))
            : vImagePremultiplyData_RGBA8888(&source, &destination, vImage_Flags(kvImageNoFlags))
        return error == kvImageNoError
    }

    private func take() -> VTPixelTransferSession? {
        if let session = lock.withLock({ idle.popLast() }) { return session }
        return Self.makeSession()
    }

    private static func makeSession() -> VTPixelTransferSession? {
        var made: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &made) == noErr, let session = made else { return nil }
        // Without these it would copy the frame unconverted and say it had
        // worked.
        let set = [
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2),
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2),
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        ]
        guard set.allSatisfy({ $0 == noErr }) else {
            VTPixelTransferSessionInvalidate(session)
            return nil
        }
        return session
    }

    private func give(_ session: VTPixelTransferSession) {
        let kept = lock.withLock {
            guard idle.count < 8 else { return false }
            idle.append(session)
            return true
        }
        if !kept { VTPixelTransferSessionInvalidate(session) }
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

    private func makeBuffer(like buffer: CVPixelBuffer, format: OSType, pooled: Bool) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var made: CVPixelBuffer?
        if pooled {
            guard let pool = pool(width: width, height: height, format: format),
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess else { return nil }
            // A pooled buffer keeps the tags of the frame it last held.
            if let made { CVBufferRemoveAllAttachments(made) }
        } else {
            guard CVPixelBufferCreate(nil, width, height, format, Self.attributes(width: width, height: height, format: format) as CFDictionary, &made) == kCVReturnSuccess else { return nil }
        }
        return made
    }

    /// A pool for a frame size and format. Pools let go of buffers nobody
    /// has used for a second as they're next used; one dropped for a new
    /// size lets go of its spare buffers at once.
    private func pool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let key = "\(width)x\(height) \(format)"
        return lock.withLock {
            if let index = pools.firstIndex(where: { $0.key == key }) {
                let entry = pools.remove(at: index)
                pools.append(entry)
                return entry.pool
            }
            var made: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, Self.attributes(width: width, height: height, format: format) as CFDictionary, &made) == kCVReturnSuccess,
                  let pool = made else { return nil }
            if pools.count >= maxPools {
                CVPixelBufferPoolFlush(pools.removeFirst().pool, .excessBuffers)
            }
            pools.append((key, pool))
            return pool
        }
    }
}
