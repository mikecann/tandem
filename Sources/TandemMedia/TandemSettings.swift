import Foundation
import TandemCore

/// Tandem's own settings, shared by the app and the `tandem` command so
/// both make projects the same way. Kept as JSON in
/// `~/Library/Application Support/Tandem/settings.json`, or the file
/// `$TANDEM_SETTINGS` names (tests use their own).
public struct TandemSettings: Codable, Equatable, Sendable {
    /// How late a new camera take's picture is against its sound, in
    /// seconds. Each camera file gets it as it joins a project
    /// (`MediaItem.pictureDelay`), so its clips play in sync from the
    /// start. Mike's webcam lags his mic by about 0.08 s (a clap test on
    /// 2026-10-02 measured 75 ms). Zero leaves new files as they are.
    public var cameraPictureDelay: Double

    public init(cameraPictureDelay: Double = 0) {
        self.cameraPictureDelay = cameraPictureDelay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraPictureDelay = try c.decodeIfPresent(Double.self, forKey: .cameraPictureDelay) ?? 0
    }

    /// Where they're kept.
    public static var url: URL {
        if let path = ProcessInfo.processInfo.environment["TANDEM_SETTINGS"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        // Tests never read (or write) Mike's own.
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("tandem-tests-\(ProcessInfo.processInfo.processIdentifier)-settings.json")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tandem/settings.json")
    }

    /// The saved settings, or the defaults when there are none (or the file
    /// can't be read).
    public static func load(from url: URL = TandemSettings.url) -> TandemSettings {
        guard let data = try? Data(contentsOf: url) else { return TandemSettings() }
        return (try? JSONDecoder().decode(TandemSettings.self, from: data)) ?? TandemSettings()
    }

    public func save(to url: URL = TandemSettings.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The delay a new file gets: the camera picture delay for a camera
    /// take's video, unless its recorder already took the lag out (Record
    /// It's Camera delay); nothing otherwise.
    public func pictureDelay(for item: MediaItem) -> Time? {
        guard item.role == .camera, item.kind == .video, item.hasVideo, item.pictureDelayCorrected == nil, cameraPictureDelay != 0 else { return nil }
        return Time(seconds: cameraPictureDelay)
    }
}
