import AVFoundation
import Foundation
import TandemCore

/// When each of a file's frames shows, in file time, for `tandem check`'s
/// low frame rate note: a screen recording's frame rate wanders, as macOS
/// records the screen when it changes.
///
/// The times come from the sample table, so nothing is decoded: about a
/// second for an hour of screen recording. They're cached per file (by its
/// fingerprint, or its size and modification time) in the project's
/// `.tandem/cache/frametimes`, so a check after the first reads them back in
/// milliseconds.
public enum FrameTimes {
    /// Bump when what's stored changes.
    static let version = 2

    /// The file's frame times, sorted, from the cache or the file. Nil when
    /// it has no video or can't be read.
    public static func read(_ item: MediaItem, in folder: ProjectFolder) async -> [Time]? {
        let url = folder.url(for: item)
        guard let key = cacheKey(item, url: url) else { return nil }
        let cached = folder.cacheFolder.appendingPathComponent("frametimes", isDirectory: true).appendingPathComponent(key + ".bin")
        if let times = load(cached) { return times }
        guard let times = await read(url) else { return nil }
        save(times, to: cached)
        return times
    }

    /// The frame times read from the file's sample table.
    public static func read(_ url: URL) async -> [Time]? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let ticks = MediaProbe.presentationTimes(of: track, timescale: CMTimeScale(Time.flicksPerSecond)) else { return nil }
        return ticks.map { Time(flicks: $0) }
    }

    static func cacheKey(_ item: MediaItem, url: URL) -> String? {
        if let fingerprint = item.fingerprint, !fingerprint.isEmpty { return "v\(version)-\(fingerprint)" }
        guard let stat = try? FileStat(url) else { return nil }
        return "v\(version)-\(stat.size)-\(stat.modified)-" + String(item.path.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 16)
    }

    /// Little-endian flicks, one after another.
    static func load(_ url: URL) -> [Time]? {
        guard let data = try? Data(contentsOf: url), data.count % 8 == 0, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<(data.count / 8)).map { Time(flicks: Int64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 8, as: Int64.self))) }
        }
    }

    static func save(_ times: [Time], to url: URL) {
        var data = Data(capacity: times.count * 8)
        for time in times {
            withUnsafeBytes(of: time.flicks.littleEndian) { data.append(contentsOf: $0) }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
