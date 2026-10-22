import CoreML
import CryptoKit
import Foundation

/// Where Bark 3.0 Pro's Core ML model lives and how it gets there.
///
/// The files are the `coreml/` folder of ConwayResearch/Underdog-Bark-3.0-Pro
/// on Hugging Face at a pinned commit, each checked by size and SHA-256 as
/// it arrives, into ~/Library/Application Support/Tandem/Models/bark-3.0-pro/
/// next to RVM's. The four `.mlpackage`s are then compiled for this Mac once,
/// into `compiled/`, and `compiled/ready.json` records each file's size and
/// date as they were checked. A job only compares those (15 stats), not the
/// 1.2 GB of checksums; a file that changed since sends the model back
/// through the checks and the compile.
///
/// The download is 1.23 GB, so in the app a transcript doesn't wait for it:
/// `BarkModelPreparer` fetches and compiles it in the background while
/// transcripts use SpeechAnalyzer, then says so with
/// `BarkModelStore.readyNotification`. A `tandem` command exits when its
/// work is done, which would end that download, so its transcripts wait for
/// the model instead (`waitsForModel`). Each file downloads into
/// `.downloads/` and carries on from there next time, so a command that
/// timed out or was stopped still got somewhere.
///
/// Licence: CC-BY 4.0 (from NVIDIA's Parakeet TDT 0.6B v3 and Moondream's
/// Parakeet Ultra). The model's own `LICENSE` and `NOTICE` come down with it
/// and stay beside it; README.md and docs/MEDIA.md carry the attribution.
public struct BarkModelStore: Sendable {
    /// One file of the model, by its path inside `coreml/`.
    struct File: Sendable, Equatable {
        var path: String
        var size: Int64
        var sha256: String
    }

    /// The Hugging Face commit the files below come from.
    static let revision = "4b5c51e04aa8d16dda9ecdff71bc29f7360149e4"
    static let remote = URL(string: "https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Pro/resolve/\(revision)/coreml/")!
    static let vocabulary = "parakeet_v3_vocab.json"
    static let files: [File] = [
        File(path: "Preprocessor.mlpackage/Manifest.json", size: 617, sha256: "75753d7f53c12f47bef18a0f84eacdf8e7e93db1a2e3af368c50b4f686317220"),
        File(path: "Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 18_839, sha256: "dd4a5266ed9048aae620e73aa983eab93256654a343ded1226f9456b79f79a67"),
        File(path: "Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 1_184_512, sha256: "7a31e2bd311bfa97ea3fe73d4a6c029824327a71590397bd8784089a88754a77"),
        File(path: "Encoder.mlpackage/Manifest.json", size: 617, sha256: "a6f16e318952af66b69fa84820b6417846ad0c9208a3c2779aa788a7c244a75e"),
        File(path: "Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 1_206_573, sha256: "d82718558f523dc13f9c0ede57d6f8e37d953950808a5aaa3a4633a7f752dd77"),
        File(path: "Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 1_195_742_464, sha256: "619757bd47bc5cc131a85e54e94ffacc1b8c1bce737c1f1f6569eda8621a30d6"),
        File(path: "Decoder.mlpackage/Manifest.json", size: 617, sha256: "123808ff526bf8d5f47b69d5833ff91477f438f92056a3531ae0a7b4f2945d7e"),
        File(path: "Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 11_612, sha256: "00cd3bdf438e859eff16d1376cab86f6214d0e44b1876316e30550e35d012763"),
        File(path: "Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 23_604_992, sha256: "b6bfa9053e8e20d1e80a7522ddba5c66e2c8c77cfc956d4ebccf749baf4d3d69"),
        File(path: "JointDecisionv3.mlpackage/Manifest.json", size: 617, sha256: "264b4403e1cada9a6148a10190e91b9e7fe6ead871db0aedcd87d2f4d84df1e7"),
        File(path: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 8_759, sha256: "1057c2d9e9efce23258dbf2e7747e6facf7a42f4fcbcf2a21cdd160e065b18ac"),
        File(path: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 12_642_764, sha256: "90257de4d4582921c31db6efe9668017274b7c4cfdfe5aac9b9183233f7a9bdd"),
        File(path: vocabulary, size: 143_080, sha256: "3c278905d679b4b3e6b7be337edb8f9c0fce73a3708d5fe7a4a3bc7a12e719e1"),
        File(path: "LICENSE", size: 18_657, sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"),
        File(path: "NOTICE", size: 611, sha256: "6bd6d22b4414b3ac97869dd8a97a813d668216ef66b04148ac858b988f8d063d")
    ]

    /// Posted (by `BarkModelPreparer`) when a store's model has become
    /// ready, so open projects ask again for the transcripts that fell back.
    public static let readyNotification = Notification.Name("TandemBarkModelReady")

    /// The downloaded files, laid out as the repository's `coreml/` folder.
    var folder: URL
    /// The compiled models and `ready.json`.
    var compiledFolder: URL
    var files: [File] = Self.files
    var remote: URL = Self.remote
    /// Downloads one URL into the partial file given (carrying on from
    /// what's already in it) and returns the finished file, which the store
    /// may delete, calling back with the bytes so far. Tests swap in copies
    /// so they never touch the network.
    var fetch: @Sendable (URL, URL, @escaping @Sendable (Int64) -> Void) async throws -> URL
    /// Whether a transcript that finds no model starts the download. Off
    /// while testing: tests never download, or compile 1.2 GB, behind
    /// anyone's back.
    var autoPrepare: Bool
    /// Whether a transcript that finds no model waits for it (showing the
    /// download's progress) rather than falling back to SpeechAnalyzer
    /// while it downloads. On for `tandem` commands, which exit when they're
    /// done and would take the download with them; off in the app, which
    /// stays open to finish it and remake the transcript.
    var waitsForModel = false

    static let standard: BarkModelStore = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tandem/Models/bark-3.0-pro", isDirectory: true)
        let testing = NSClassFromString("XCTestCase") != nil
        return BarkModelStore(
            folder: root, compiledFolder: root.appendingPathComponent("compiled", isDirectory: true),
            fetch: { url, partial, progress in
                if testing { throw MediaError.failed("downloads are off while testing") }
                return try await ModelDownload.fetch(url, into: partial, progress: progress)
            },
            autoPrepare: !testing
        )
    }()

    /// A store for the model in `folder` (laid out as the repository's
    /// `coreml/`), compiled into `compiledFolder`. With `download` it
    /// fetches missing or damaged files from the pinned commit; without, a
    /// missing file is an error.
    public init(folder: URL, compiledFolder: URL, download: Bool = false) {
        self.init(folder: folder, compiledFolder: compiledFolder, fetch: { url, partial, progress in
            guard download else { throw MediaError.failed("\(url.lastPathComponent) isn't in the Bark model folder") }
            return try await ModelDownload.fetch(url, into: partial, progress: progress)
        }, autoPrepare: false)
    }

    init(folder: URL, compiledFolder: URL, files: [File] = Self.files, remote: URL = Self.remote,
         fetch: @escaping @Sendable (URL, URL, @escaping @Sendable (Int64) -> Void) async throws -> URL, autoPrepare: Bool) {
        self.folder = folder
        self.compiledFolder = compiledFolder
        self.files = files
        self.remote = remote
        self.fetch = fetch
        self.autoPrepare = autoPrepare
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    /// The packages among the files, by name, each compiled to `<name>.mlmodelc`.
    var packages: [String] {
        var names: [String] = []
        for file in files {
            guard let top = file.path.split(separator: "/").first, top.hasSuffix(".mlpackage") else { continue }
            let name = String(top.dropLast(".mlpackage".count))
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
    var readyFile: URL { compiledFolder.appendingPathComponent("ready.json") }

    /// Where a file downloads to until it's checked: outside the packages,
    /// so a compile never sees one, and named by its checksum, so a part of
    /// some other revision's file is never carried on.
    func partialFile(_ file: File) -> URL {
        folder.appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent("\(file.sha256.prefix(16))-\((file.path as NSString).lastPathComponent)")
    }

    /// What a ready model was checked against.
    struct Ready: Codable, Equatable {
        var revision: String
        /// "size-date" of each downloaded file, by path.
        var files: [String: String]
    }

    /// `ready.json`'s size and date, or "absent": cheap enough for every
    /// cache lookup, and it changes exactly when the model becomes ready
    /// (or is made ready again), which is what retires a fallback.
    func stamp() -> String {
        Self.stat(readyFile) ?? "absent"
    }

    static func stat(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return "\(size)-\(date.timeIntervalSince1970)"
    }

    /// The compiled model folder when the model is ready to load: compiled,
    /// and no downloaded file has changed since it was checked. Nil
    /// otherwise, with no side effects.
    func readyFolder() -> URL? {
        guard let data = try? Data(contentsOf: readyFile),
              let ready = try? JSONDecoder().decode(Ready.self, from: data),
              ready == currentReady() else { return nil }
        for name in packages {
            guard FileManager.default.fileExists(atPath: compiledFolder.appendingPathComponent("\(name).mlmodelc").path) else { return nil }
        }
        return compiledFolder
    }

    private func currentReady() -> Ready {
        var stats: [String: String] = [:]
        for file in files {
            stats[file.path] = Self.stat(folder.appendingPathComponent(file.path)) ?? "absent"
        }
        return Ready(revision: Self.revision, files: stats)
    }

    /// Makes the model ready: checks every file (fetching any that's
    /// missing or doesn't match), compiles the packages and writes
    /// `ready.json`. Progress is 0...1 over the bytes checked or fetched,
    /// then the compile.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws {
        if readyFolder() != nil { return }
        let total = Double(totalBytes)
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = folder.appendingPathComponent(file.path)
            if !(try Self.matches(target, file)) {
                let before = done
                let partial = partialFile(file)
                try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A partial that's all there (the last run stopped before
                // checking it) is used as it is. One as long as the file or
                // longer, but wrong, can't be the start of it.
                let downloaded: URL
                if try Self.matches(partial, file) {
                    downloaded = partial
                } else {
                    if let size = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber, size.int64Value >= file.size {
                        try? FileManager.default.removeItem(at: partial)
                    }
                    downloaded = try await fetch(remote.appendingPathComponent(file.path), partial) { bytes in
                        progress(0.95 * Double(before + bytes) / total, "Downloading Bark 3.0 Pro")
                    }
                }
                defer { try? FileManager.default.removeItem(at: downloaded) }
                guard try Self.matches(downloaded, file) else {
                    throw MediaError.failed("The Bark model's \(file.path) didn't match its checksum")
                }
                try Self.place(downloaded, at: target)
            }
            done += file.size
            progress(0.95 * Double(done) / total, "Checking Bark 3.0 Pro")
        }
        progress(0.95, "Compiling Bark 3.0 Pro")
        try await compile()
        progress(1, "Bark 3.0 Pro is ready")
    }

    /// Size first (cheap), then the checksum, read 8 MB at a time.
    static func matches(_ url: URL, _ file: File) throws -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == file.size else { return false }
        return try checksum(of: url) == file.sha256
    }

    static func checksum(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Staged next to the target and swapped in, so a half-written file is
    /// never where the next check looks.
    static func place(_ downloaded: URL, at target: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)")
        try fileManager.copyItem(at: downloaded, to: staged)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: target)
        }
    }

    /// Compiles the four packages into a staging folder, swaps them in and
    /// writes `ready.json` last, so a model is only ever ready complete.
    private func compile() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: compiledFolder, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: readyFile)
        let staging = compiledFolder.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        for name in packages {
            try Task.checkCancellation()
            let compiled = try await MLModel.compileModel(at: folder.appendingPathComponent("\(name).mlpackage"))
            try fileManager.moveItem(at: compiled, to: staging.appendingPathComponent("\(name).mlmodelc"))
        }
        for name in packages {
            let target = compiledFolder.appendingPathComponent("\(name).mlmodelc")
            try? fileManager.removeItem(at: target)
            try fileManager.moveItem(at: staging.appendingPathComponent("\(name).mlmodelc"), to: target)
        }
        try JSONEncoder().encode(currentReady()).write(to: readyFile, options: .atomic)
    }
}

/// Makes stores ready in the background, one run per store folder at a
/// time, so the jobs that find no model can fall back straight away. A
/// failed run is tried again by the next job that asks, after a minute.
public actor BarkModelPreparer {
    public static let shared = BarkModelPreparer()

    struct Run {
        var task: Task<Void, Never>?
        var progress: Double = 0
        var message = "Downloading Bark 3.0 Pro"
        var failure: String?
        var failedAt: Date?
    }

    private var runs: [URL: Run] = [:]

    /// Starts making `store` ready if it isn't and nothing is already.
    func start(_ store: BarkModelStore) {
        let key = store.folder.standardizedFileURL
        var run = runs[key] ?? Run()
        guard run.task == nil, store.readyFolder() == nil else { return }
        if let failedAt = run.failedAt, Date().timeIntervalSince(failedAt) < 60 { return }
        run.failure = nil
        run.progress = 0
        run.message = "Downloading Bark 3.0 Pro"
        run.task = Task.detached(priority: .utility) { [self] in
            do {
                try await store.prepare { fraction, message in
                    Task { await self.report(key, progress: fraction, message: message) }
                }
                await finish(key, failure: nil)
                NotificationCenter.default.post(name: BarkModelStore.readyNotification, object: nil)
            } catch {
                await finish(key, failure: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        runs[key] = run
    }

    /// How far a run has got and what it's doing, or why the last one failed.
    func state(of store: BarkModelStore) -> (running: Bool, progress: Double, message: String, failure: String?) {
        let run = runs[store.folder.standardizedFileURL] ?? Run()
        return (run.task != nil, run.progress, run.message, run.failure)
    }

    /// Waits for the store's current run, if there is one (tests).
    func wait(for store: BarkModelStore) async {
        await runs[store.folder.standardizedFileURL]?.task?.value
    }

    private func report(_ key: URL, progress: Double, message: String) {
        guard var run = runs[key], run.task != nil, progress >= run.progress else { return }
        run.progress = progress
        run.message = message
        runs[key] = run
    }

    private func finish(_ key: URL, failure: String?) {
        runs[key]?.task = nil
        runs[key]?.failure = failure
        runs[key]?.failedAt = failure == nil ? nil : Date()
    }
}

/// One file from the network into a partial file, carrying on from what's
/// already there with an HTTP range request, so a download that was cut off
/// (a command that timed out, a Mac that went to sleep) loses nothing. A
/// server that ignores the range sends the whole file, which starts it again.
/// The partial is locked while it's written, so two processes never append
/// to the same one.
enum ModelDownload {
    /// - Parameter configuration: tests pass one with a stand-in server.
    static func fetch(_ url: URL, into partial: URL, configuration: URLSessionConfiguration = .default,
                      progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let descriptor = open(partial.path, O_WRONLY | O_CREAT | O_EXLOCK | O_NONBLOCK, 0o644)
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK { throw MediaError.failed("Another Tandem is downloading \(url.lastPathComponent)") }
            throw MediaError.failed("Couldn't write \(partial.path) (\(String(cString: strerror(errno))))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let delegate = Delegate(handle: handle, offset: Int64(offset), progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        return partial
    }

    final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        let progress: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var written: Int64
        private var reported: Int64
        private var failure: Error?

        init(handle: FileHandle, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) {
            self.handle = handle
            written = offset
            reported = offset
            self.progress = progress
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            switch status {
            case 206:
                // Carrying on from `written`.
                completionHandler(.allow)
            case 200:
                // The whole file: start the partial again.
                do {
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                    written = 0
                    reported = 0
                    completionHandler(.allow)
                } catch {
                    failure = error
                    completionHandler(.cancel)
                }
            default:
                // 416 when the partial is no use: it goes, and the next try
                // starts from nothing.
                if status == 416 { try? handle.truncate(atOffset: 0) }
                failure = MediaError.failed("Downloading \(dataTask.originalRequest?.url?.lastPathComponent ?? "the model") failed (HTTP \(status))")
                completionHandler(.cancel)
            }
        }

        /// Every 8 MB: a chunk at a time would be thousands of calls.
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            do {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
            } catch {
                failure = error
                dataTask.cancel()
                return
            }
            guard written - reported >= 8 << 20 else { return }
            reported = written
            progress(written)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = failure ?? error {
                continuation?.resume(throwing: error)
            } else {
                try? handle.synchronize()
                progress(written)
                continuation?.resume()
            }
            continuation = nil
        }
    }
}
