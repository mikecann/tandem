import Foundation
import TandemAPI

/// The key a `tandem://` link has to carry before the app acts on it.
///
/// Any app or web page can open a tandem:// link, and the links click,
/// type, drop, run editor commands and write screenshots: enough for a
/// page to edit and save the open project. So each Mac gets its own random
/// key, in a file only its user can read, and the app ignores a link
/// without it. Smoke tests and agents send links with `tandem url`, which
/// adds the key:
///
///     tandem url "simulate?click=600,700"
///     tandem url "screenshot?out=/tmp/shot.png"
///
/// To change the key, delete the file and restart the app.
struct AppURLKey: Equatable {
    let value: String

    /// `~/Library/Application Support/Tandem/url-key`, where the `tandem`
    /// launcher reads it.
    static var defaultFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Tandem/url-key")
    }

    /// The key in `file`, made the first time.
    static func load(from file: URL = defaultFile) throws -> AppURLKey {
        if let key = read(file) {
            // One made or copied by hand may be readable by everyone.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return key
        }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Written whole, readable only by its owner, then put in place.
        let draft = folder.appendingPathComponent(".url-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: draft) }
        let contents = Data(TandemHTTPServer.makeToken().utf8)
        guard FileManager.default.createFile(atPath: draft.path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: draft.path])
        }
        // A link doesn't replace a key another launch has just made; a
        // rename does replace a file that isn't a key (empty, cut short).
        if link(draft.path, file.path) != 0 {
            let failure = errno
            guard failure == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
            if read(file) == nil, rename(draft.path, file.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard let key = read(file) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path]) }
        return key
    }

    private static func read(_ file: URL) -> AppURLKey? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 32, value.allSatisfy(\.isHexDigit) else { return nil }
        return AppURLKey(value: value)
    }

    /// Whether `url` carries this key as `key=`.
    func accepts(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let presented = items.first(where: { $0.name.lowercased() == "key" })?.value else { return false }
        let given = Array(presented.utf8)
        let expected = Array(value.utf8)
        guard given.count == expected.count else { return false }
        // Every byte is compared, so the time taken doesn't give it away.
        var difference: UInt8 = 0
        for (a, b) in zip(given, expected) { difference |= a ^ b }
        return difference == 0
    }
}
