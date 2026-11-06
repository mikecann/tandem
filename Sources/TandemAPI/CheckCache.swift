import CryptoKit
import Foundation
import TandemCore
import TandemMedia
import TandemRender

/// What `tandem check` measured in each 10 s piece of the timeline, kept
/// between runs in `.tandem/cache/check`, so the next check only renders
/// the pieces that changed.
///
/// `check --changed` took 9 to 13 minutes over about 22 minutes of the
/// Tandem video's changed timeline, a long wait between review rounds, and
/// most of what it read hadn't changed since the round before. A piece is
/// keyed by everything that draws in it: the project's settings, the video
/// tracks with the clips and transitions over it (and a margin either side,
/// for transitions), the files those clips play with whether their proxy,
/// matte and converted copy are ready, the scan's width, and which scan it
/// is. Anything else changing leaves it alone.
struct CheckCache: Sendable {
    /// Bump when what's stored, or how a frame is measured or drawn,
    /// changes. 2: clip edges within a millisecond of a frame are on it
    /// (`RenderPlanner.onFrames`), so frames scanned black at such cuts
    /// before aren't any more.
    /// 3: keyed by the matte served too (an older RVM matte stands in
    /// while a new version is made).
    static let version = 3
    /// The newest pieces are kept up to this many bytes.
    static let sizeLimit: Int64 = 256 * 1024 * 1024

    let root: URL

    init(folder: ProjectFolder) {
        root = folder.cacheFolder.appendingPathComponent("check", isDirectory: true)
    }

    /// The scan of `ranges`, from the cache where each piece is there and
    /// from `render` for the rest (the missing pieces, joined where they
    /// touch), which are then kept.
    func scan(
        project: Project, analysis: AnalysisSource, ranges: [TimeRange], width: Int, scanlines: Bool,
        render: @Sendable ([TimeRange]) async throws -> [FrameStats]
    ) async throws -> [FrameStats] {
        let pieces = QualityCheck.pieces(of: ranges, every: FrameScanner.pieceLength)
        let keys = pieces.map { key(for: $0, project: project, analysis: analysis, width: width, scanlines: scanlines) }
        var found: [[FrameStats]?] = keys.map(load)
        let missing = found.indices.filter { found[$0] == nil }
        if !missing.isEmpty {
            let read = try await render(QualityCheck.merge(missing.map { pieces[$0] }))
            for index in missing {
                let piece = pieces[index]
                let frames = read.filter { piece.contains($0.time) }
                found[index] = frames
                save(frames, key: keys[index])
            }
            evict()
        }
        return found.flatMap { $0 ?? [] }
    }

    // MARK: - Keys

    /// What draws in one piece, encoded and hashed.
    struct Inputs: Encodable {
        var version: Int
        var width: Int
        var scanlines: Bool
        var start: Int64
        var end: Int64
        var settings: ProjectSettings
        var tracks: [Track]
        var media: [MediaItem]
        /// Proxy, matte and converted copy ready, by media ID.
        var ready: [String: [Bool]]
        /// The matte served, by media ID: a stand-in renders differently
        /// from none, though neither is "ready".
        var mattes: [String: String]
    }

    func key(for piece: TimeRange, project: Project, analysis: AnalysisSource, width: Int, scanlines: Bool) -> String {
        // Transitions reach this far either side of a cut.
        let longest = project.videoTracks.flatMap(\.transitions).map(\.duration).max() ?? .zero
        let margin = max(Time(seconds: 1), longest)
        let near = TimeRange(start: piece.start - margin, end: piece.end + margin)
        var used = Set<String>()
        let tracks = project.videoTracks.map { track -> Track in
            var copy = track
            copy.clips = track.clips.filter { $0.range.overlaps(near) || $0.range.contains(near.start) }
            let ids = Set(copy.clips.map(\.id))
            copy.transitions = track.transitions.filter { ids.contains($0.fromClipID ?? "") || ids.contains($0.toClipID ?? "") }
            used.formUnion(copy.clips.compactMap(\.mediaID))
            return copy
        }
        let media = project.media.filter { used.contains($0.id) }.sorted { $0.id < $1.id }
        var ready: [String: [Bool]] = [:], mattes: [String: String] = [:]
        for item in media {
            ready[item.id] = [AnalysisKind.proxy, .matte, .converted].map { analysis.isReady($0, for: item) }
            mattes[item.id] = analysis.servedMatte(for: item) ?? ""
        }
        let inputs = Inputs(
            version: Self.version, width: width, scanlines: scanlines, start: piece.start.flicks, end: piece.end.flicks,
            settings: project.settings, tracks: tracks, media: media, ready: ready, mattes: mattes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(inputs)) ?? Data(UUID().uuidString.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Storage

    private func url(_ key: String) -> URL { root.appendingPathComponent(key + ".stats") }

    func load(_ key: String) -> [FrameStats]? {
        let url = url(key)
        guard let compressed = try? Data(contentsOf: url),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let frames = Self.decode(data) else { return nil }
        // Kept the longest when used the most recently.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return frames
    }

    func save(_ frames: [FrameStats], key: String) {
        guard let compressed = try? (Self.encode(frames) as NSData).compressed(using: .lzfse) as Data else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? compressed.write(to: url(key), options: .atomic)
    }

    /// Removes the least recently used pieces past `sizeLimit`.
    func evict() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > Self.sizeLimit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Frames one after another: time in flicks, the four measurements, then
    /// the thumbnail and scanlines with their lengths, little-endian.
    static func encode(_ frames: [FrameStats]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(frames.count))
        for frame in frames {
            append(frame.time.flicks)
            for value in [frame.luma, frame.brightestTile, frame.flatGreen, frame.flatWhite] { append(value.bitPattern) }
            append(UInt32(frame.columns))
            append(UInt32(frame.thumbnail.count))
            data.append(contentsOf: frame.thumbnail)
            append(UInt32(frame.scanlines.count))
            data.append(contentsOf: frame.scanlines)
        }
        return data
    }

    static func decode(_ data: Data) -> [FrameStats]? {
        let bytes = [UInt8](data)
        var offset = 0
        func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= bytes.count else { return nil }
            var value: T = 0
            for index in 0..<size { value |= T(bytes[offset + index]) << (8 * index) }
            offset += size
            return value
        }
        func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }
        guard let count = read(UInt32.self), Int(count) <= bytes.count else { return nil }
        var frames: [FrameStats] = []
        frames.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let flicks = read(Int64.self), let luma = read(UInt64.self), let brightest = read(UInt64.self),
                  let green = read(UInt64.self), let white = read(UInt64.self), let columns = read(UInt32.self),
                  let thumbnailCount = read(UInt32.self), let thumbnail = take(Int(thumbnailCount)),
                  let scanlineCount = read(UInt32.self), let scanlines = take(Int(scanlineCount)) else { return nil }
            frames.append(FrameStats(
                time: Time(flicks: flicks), luma: Double(bitPattern: luma), brightestTile: Double(bitPattern: brightest),
                flatGreen: Double(bitPattern: green), flatWhite: Double(bitPattern: white), thumbnail: thumbnail,
                columns: Int(columns), scanlines: scanlines
            ))
        }
        return offset == bytes.count ? frames : nil
    }
}
