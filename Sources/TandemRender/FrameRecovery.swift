import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A media track the compositor can decode frames from itself.
struct SourceTrack: @unchecked Sendable {
    var url: URL
    var asset: AVAsset
    var track: AVAssetTrack
    /// The track's media time range, for clamping.
    var timeRange: CMTimeRange
    /// Leading frames AVFoundation can't seek to, when the file doesn't
    /// mark them (see `LeadingFrameMap`).
    var leading: LeadingFrameMap?
}

/// Decodes a source frame when AVFoundation hands the compositor nothing.
///
/// HEVC with open GOPs has keyframes (CRA pictures) whose leading frames
/// show before them but decode after them, referring back to the previous
/// GOP. A file has to say which keyframes are like that (a `sync` sample
/// group); record-it's files do, but copies remuxed by other tools lose it
/// (ffmpeg's `-c copy`, which made decision-models' `edit/main-screen.mov`).
/// AVFoundation then starts decoding at the keyframe, the leading frames
/// fail ("Cannot Decode"), and a seek or frame grab there shows nothing:
/// about 4% of that file's time. Decoding on from a little earlier gets
/// them right, which is why exports, reading straight through, were fine.
///
/// So when a layer's frame is missing this reads the file from a second
/// before the wanted time, backing off further if the start itself lands on
/// undecodable leading frames, and returns the last frame at or before the
/// time (so gaps in variable frame rate footage hold the frame before them).
/// Readers stay open for a moment: the next few frames continue from where
/// the last one stopped instead of decoding the run again.
final class FrameRecovery: @unchecked Sendable {
    static let shared = FrameRecovery()

    private let lock = NSLock()
    private var sessions: [Session] = []
    private let maxSessions = 3
    /// Frames asked for, and readers opened to decode them, since launch.
    private(set) var requests = 0
    private(set) var readersOpened = 0
    /// Off shows what AVFoundation alone produces, for diagnostics.
    var enabled = true
    /// Freeze frames' pictures, by file and time, most recently used last.
    /// Copies, so they don't hold a reader's buffers.
    private var stills: [(asset: AVAsset, path: String, time: CMTime, pixels: CVPixelBuffer)] = []
    private let maxStills = 8

    /// An open reader positioned just after the last frame it returned.
    private final class Session {
        let path: String
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let end: CMTime
        var lastTime: CMTime
        var current: CVPixelBuffer
        /// The first sample after `lastTime`, read but not used yet.
        var pending: CMSampleBuffer?

        init(path: String, reader: AVAssetReader, output: AVAssetReaderTrackOutput, end: CMTime, time: CMTime, current: CVPixelBuffer, pending: CMSampleBuffer?) {
            self.path = path
            self.reader = reader
            self.output = output
            self.end = end
            self.lastTime = time
            self.current = current
            self.pending = pending
        }
    }

    /// How far back each attempt starts reading, in seconds.
    static let lookbacks: [Double] = [1, 4, 16, 64]
    /// How far past the wanted time a reader runs, so later frames can
    /// continue from it.
    static let readAhead = 2.0
    private static let tolerance = CMTime(value: 1, timescale: 1000)

    /// The frame shown at media time `time`: the last one at or before it.
    /// Times past the end hold the last frame; before the start, the first.
    func frame(_ source: SourceTrack, at requested: CMTime) -> CVPixelBuffer? {
        let range = source.timeRange
        guard enabled, range.duration > .zero, requested.isNumeric else { return nil }
        let latest = CMTimeSubtract(range.end, Self.tolerance)
        let time = CMTimeMaximum(range.start, CMTimeMinimum(requested, latest))
        return lock.withLock {
            requests += 1
            if let frame = continueSession(source.url.path, to: time) { return frame }
            for lookback in Self.lookbacks {
                let start = CMTimeMaximum(range.start, CMTimeSubtract(time, CMTime(seconds: lookback, preferredTimescale: 600)))
                let atFileStart = CMTimeCompare(start, range.start) == 0
                guard let session = open(source, from: start, to: time) else {
                    if atFileStart { break }
                    continue
                }
                if session.decodedFromStart || atFileStart {
                    keep(session.session)
                    return session.session.current
                }
                // The first frames were undecodable leading frames, and so
                // may the wanted one have been: start further back.
                session.session.reader.cancelReading()
                if atFileStart { break }
            }
            return nil
        }
    }

    /// The frame shown at `time`, as `frame`, kept for the next ask. A
    /// freeze frame asks for the same picture on every frame it shows, while
    /// other frames of its file come and go between (a run of cuts over
    /// two held screens), so it doesn't wait on a reader's single frame.
    func still(_ source: SourceTrack, at requested: CMTime) -> CVPixelBuffer? {
        let range = source.timeRange
        guard enabled, range.duration > .zero, requested.isNumeric else { return nil }
        let time = CMTimeMaximum(range.start, CMTimeMinimum(requested, CMTimeSubtract(range.end, Self.tolerance)))
        let path = source.url.path
        let cached: CVPixelBuffer? = lock.withLock {
            guard let index = stills.firstIndex(where: { $0.path == path && $0.asset === source.asset && CMTimeCompare($0.time, time) == 0 }) else { return nil }
            let entry = stills.remove(at: index)
            stills.append(entry)
            return entry.pixels
        }
        if let cached { return cached }
        guard let decoded = frame(source, at: time), let copy = Self.copy(decoded) else { return nil }
        lock.withLock {
            stills.removeAll { $0.path == path && CMTimeCompare($0.time, time) == 0 }
            stills.append((source.asset, path, time, copy))
            if stills.count > maxStills { stills.removeFirst(stills.count - maxStills) }
        }
        return copy
    }

    /// A pixel buffer's own copy, with its attachments (colour tags).
    static func copy(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, CVPixelBufferGetPixelFormatType(buffer), attributes as CFDictionary, &made) == kCVReturnSuccess,
              let copy = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        if CVPixelBufferIsPlanar(buffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                guard let from = CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
                      let to = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { return nil }
                let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let fromStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let toStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                for row in 0..<rows {
                    memcpy(to + row * toStride, from + row * fromStride, min(fromStride, toStride))
                }
            }
        } else {
            guard let from = CVPixelBufferGetBaseAddress(buffer), let to = CVPixelBufferGetBaseAddress(copy) else { return nil }
            let fromStride = CVPixelBufferGetBytesPerRow(buffer)
            let toStride = CVPixelBufferGetBytesPerRow(copy)
            for row in 0..<height {
                memcpy(to + row * toStride, from + row * fromStride, min(fromStride, toStride))
            }
        }
        CVBufferPropagateAttachments(buffer, copy)
        return copy
    }

    /// Continues an open reader when the wanted time is a little later than
    /// the last one it returned.
    private func continueSession(_ path: String, to time: CMTime) -> CVPixelBuffer? {
        guard let index = sessions.firstIndex(where: { $0.path == path }) else { return nil }
        let session = sessions[index]
        if CMTimeCompare(time, session.lastTime) == 0 { return session.current }
        guard CMTimeCompare(time, session.lastTime) > 0, CMTimeCompare(time, session.end) < 0 else { return nil }
        let limit = CMTimeAdd(time, Self.tolerance)
        while true {
            let sample = session.pending ?? session.output.copyNextSampleBuffer()
            session.pending = nil
            guard let sample else { break }
            if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), limit) > 0 {
                session.pending = sample
                break
            }
            if let pixels = CMSampleBufferGetImageBuffer(sample) { session.current = pixels }
        }
        session.lastTime = time
        // Most recently used last.
        sessions.remove(at: index)
        sessions.append(session)
        return session.current
    }

    private func open(_ source: SourceTrack, from start: CMTime, to time: CMTime) -> (session: Session, decodedFromStart: Bool)? {
        readersOpened += 1
        guard let reader = try? AVAssetReader(asset: source.asset) else { return nil }
        let end = CMTimeMinimum(source.timeRange.end, CMTimeAdd(time, CMTime(seconds: Self.readAhead, preferredTimescale: 600)))
        reader.timeRange = CMTimeRange(start: start, end: end)
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        let limit = CMTimeAdd(time, Self.tolerance)
        var first: CMTime?
        var best: CVPixelBuffer?
        var pending: CMSampleBuffer?
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if first == nil { first = pts }
            if CMTimeCompare(pts, limit) > 0 {
                pending = sample
                break
            }
            if let pixels = CMSampleBufferGetImageBuffer(sample) { best = pixels }
        }
        guard let best else {
            reader.cancelReading()
            return nil
        }
        // A reader gives the frame showing at its start time that time, so
        // a first frame later than the start means frames there failed.
        let decodedFromStart = first.map { CMTimeCompare($0, CMTimeAdd(start, Self.tolerance)) <= 0 } ?? false
        let session = Session(path: source.url.path, reader: reader, output: output, end: end, time: time, current: best, pending: pending)
        return (session, decodedFromStart)
    }

    private func keep(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.path == session.path }) {
            sessions[index].reader.cancelReading()
            sessions.remove(at: index)
        }
        sessions.append(session)
        while sessions.count > maxSessions {
            sessions.removeFirst().reader.cancelReading()
        }
    }

    /// Closes every open reader.
    func reset() {
        lock.withLock {
            sessions.forEach { $0.reader.cancelReading() }
            sessions.removeAll()
            stills.removeAll()
        }
    }
}
