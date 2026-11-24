import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import TandemCore

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
    /// The picture has transparency (a sticker in HEVC with alpha, ProRes
    /// 4444, a converted QuickTime Animation): decoded with alpha.
    var alpha = false
    var opaque = false
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
    /// A frame that couldn't be decoded is kept too, as nil, for a moment
    /// (`failureLife`), so a broken file isn't read again for every frame
    /// of an export, but is tried again later.
    private var stills: [(asset: AVAsset, path: String, time: CMTime, alpha: Bool, pixels: CVPixelBuffer?, at: Date)] = []
    private let maxStills = 8
    static let failureLife: TimeInterval = 2

    /// An open reader positioned just after the last frame it returned.
    private final class Session {
        let path: String
        /// The file as loaded: a file replaced at the same path is a new
        /// asset (`SourceCache`), and mustn't continue the old one's reader.
        let asset: AVAsset
        let alpha: Bool
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let end: CMTime
        var lastTime: CMTime
        var current: CVPixelBuffer
        /// The first sample after `lastTime`, read but not used yet.
        var pending: CMSampleBuffer?

        init(path: String, asset: AVAsset, alpha: Bool, reader: AVAssetReader, output: AVAssetReaderTrackOutput, end: CMTime, time: CMTime, current: CVPixelBuffer, pending: CMSampleBuffer?) {
            self.path = path
            self.asset = asset
            self.alpha = alpha
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
    /// How late a file's first frame can start and still be the one shown
    /// before it.
    private static let firstFrameSlack = CMTime(value: 1, timescale: 4)

    static func clampedTime(_ requested: CMTime, within range: CMTimeRange) -> CMTime {
        CMTimeMaximum(range.start, CMTimeMinimum(requested, CMTimeSubtract(range.end, tolerance)))
    }

    /// Privacy must follow the same boundary clamp and look-ahead as the
    /// decoder, including negative transition handles on fast source files.
    static func sampleLimit(at requested: CMTime, within range: CMTimeRange) -> CMTime {
        CMTimeAdd(clampedTime(requested, within: range), tolerance)
    }

    /// A reader with no decodable opening image can hold a later frame in
    /// this window. Privacy must include every sample it could choose.
    static func openingWindow(at requested: CMTime, within range: CMTimeRange) -> TimeRange? {
        let end = CMTimeMinimum(range.end, CMTimeAdd(range.start, firstFrameSlack))
        guard CMTimeCompare(clampedTime(requested, within: range), end) <= 0 else { return nil }
        return TimeRange(start: Time(cmTime: range.start), end: Time(cmTime: end) + Time(flicks: 1))
    }

    /// The frame shown at media time `time`: the last one at or before it.
    /// Times past the end hold the last frame; before the start, the first.
    func frame(_ source: SourceTrack, at requested: CMTime) -> CVPixelBuffer? {
        let range = source.timeRange
        guard enabled, range.duration > .zero, requested.isNumeric else { return nil }
        let time = Self.clampedTime(requested, within: range)
        return lock.withLock {
            requests += 1
            if let frame = continueSession(source, to: time) { return frame }
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
        let cached: CVPixelBuffer?? = lock.withLock {
            guard let index = stills.firstIndex(where: { $0.path == path && $0.asset === source.asset && $0.alpha == source.alpha && CMTimeCompare($0.time, time) == 0 }) else { return nil }
            if stills[index].pixels == nil, Date().timeIntervalSince(stills[index].at) > Self.failureLife { return nil }
            let entry = stills.remove(at: index)
            stills.append(entry)
            return .some(entry.pixels)
        }
        if let cached { return cached }
        let decoded = frame(source, at: time)
        // Without a buffer for the copy (memory short), show the decoded
        // frame and keep nothing: the next frame tries again.
        let copy = decoded.flatMap(Self.copy)
        if let decoded, copy == nil { return decoded }
        // Switched off meanwhile: nothing was tried, so nothing failed.
        guard enabled else { return copy }
        lock.withLock {
            stills.removeAll { $0.path == path && $0.alpha == source.alpha && CMTimeCompare($0.time, time) == 0 }
            stills.append((source.asset, path, time, source.alpha, copy, Date()))
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
    private func continueSession(_ source: SourceTrack, to time: CMTime) -> CVPixelBuffer? {
        guard let index = sessions.firstIndex(where: { $0.path == source.url.path && $0.asset === source.asset && $0.alpha == source.alpha }) else { return nil }
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
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: source.alpha ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ]
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: settings)
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
        // Asked for a time before the file's first frame shows (its first
        // sample a little after the track's start, B-frames' delay): that
        // first frame. Not a frame further on, after leading frames that
        // failed to decode.
        if best == nil, CMTimeCompare(start, source.timeRange.start) == 0, let opening = pending,
           CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(opening), CMTimeAdd(source.timeRange.start, Self.firstFrameSlack)) <= 0,
           let pixels = CMSampleBufferGetImageBuffer(opening) {
            best = pixels
            pending = nil
        }
        guard let best else {
            reader.cancelReading()
            return nil
        }
        // A reader gives the frame showing at its start time that time, so
        // a first frame later than the start means frames there failed.
        let decodedFromStart = first.map { CMTimeCompare($0, CMTimeAdd(start, Self.tolerance)) <= 0 } ?? false
        let session = Session(path: source.url.path, asset: source.asset, alpha: source.alpha, reader: reader, output: output, end: end, time: time, current: best, pending: pending)
        return (session, decodedFromStart)
    }

    private func keep(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.path == session.path && $0.alpha == session.alpha }) {
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
