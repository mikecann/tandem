import Foundation
import TandemCore
import TandemMedia

/// `tandem separate`: runs Meta's SAM Audio over one file for one or more
/// prompts on a rented RunPod GPU, through Mike's `render-box` tool, and keeps
/// the stems in the project's cache (`SeparationStore`) for clips to play.
///
/// Why it's shaped like this (all measured in October 2026):
/// - SAM Audio's large model and its rankers need more than a 24 GB card in
///   full precision, so it asks for an RTX 5090 (32 GB). Some 5090 hosts come
///   up without direct SSH, which render-box rejects, so it tries a few.
/// - Loading the model takes about six minutes, so every prompt for a file
///   goes in one job. Separating runs at about real time per prompt.
/// - The weights are gated on Hugging Face: the token comes from the Keychain
///   (service `huggingface`) via render-box's --secret, never an argument.
public struct Separator {
    public struct Outcome: Codable, Equatable, Sendable {
        public var prompt: String
        public var target: String
        public var residual: String
        /// Already made by an earlier run, so nothing was spent on it.
        public var reused: Bool
        public var gpu: String?
        public var costUSD: Double?
    }

    public let folder: ProjectFolder
    public let environment: [String: String]

    public init(folder: ProjectFolder, environment: [String: String]) {
        self.folder = folder
        self.environment = environment
    }

    /// The runner: render-box, or a stand-in for tests (`TANDEM_SEPARATE_RUNNER`).
    func runner() throws -> URL {
        if let path = environment["TANDEM_SEPARATE_RUNNER"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for dir in paths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("render-box")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw ServiceError(.badRequest, "tandem separate runs SAM Audio on a RunPod GPU through render-box, and render-box isn't installed (~/dev/me/mikerosoft-tools/render-box, ./install.sh).")
    }

    /// Minutes the pod may live, covering setup, the model download and load
    /// (about 10 minutes together) and the prompts (about real time each, with
    /// room to spare). render-box deletes the pod at this deadline whatever happens.
    static func maxMinutes(seconds: Double, prompts: Int) -> Int {
        min(240, 18 + Int((seconds * Double(prompts) * 1.6 / 60).rounded(.up)))
    }

    public func separate(_ item: MediaItem, prompts: [String], again: Bool = false, progress: @escaping @Sendable (String) -> Void) async throws -> [Outcome] {
        let store = SeparationStore(folder: folder)
        let analysis = MediaAnalysis(folder: folder)
        guard let fingerprint = analysis.separationFingerprint(for: item) else {
            throw ServiceError(.notFound, "Couldn't read \(item.path).")
        }
        guard item.hasAudio else { throw ServiceError(.badRequest, "\(item.path) has no sound to separate.") }
        var seen = Set<String>()
        let wanted = prompts.map(SeparationStore.normalized).filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !wanted.isEmpty else { throw ServiceError(.badRequest, "Say what to separate, like \"speech\" or \"crowd chatter\".") }

        var outcomes: [String: Outcome] = [:]
        var todo: [String] = []
        for prompt in wanted {
            if !again, let stems = store.stems(fingerprint: fingerprint, prompt: prompt) {
                let info = store.info(fingerprint: fingerprint, prompt: prompt)
                outcomes[prompt] = Outcome(prompt: prompt, target: stems.target.path, residual: stems.residual.path, reused: true, gpu: info?.gpu, costUSD: info?.costUSD)
            } else {
                todo.append(prompt)
            }
        }
        if !todo.isEmpty {
            let runner = try runner()
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-separate-\(UUID().uuidString)", isDirectory: true)
            let job = work.appendingPathComponent("job", isDirectory: true)
            let out = work.appendingPathComponent("stems", isDirectory: true)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            progress("Preparing \(item.path) for SAM Audio...")
            let seconds = try await SeparationInput.write(source: folder.url(for: item), to: job.appendingPathComponent("input.wav"))
            try Data(SeparationScripts.run.utf8).write(to: job.appendingPathComponent("run.sh"))
            try Data(SeparationScripts.separate.utf8).write(to: job.appendingPathComponent("separate.py"))
            // Prompts go to the pod as p0, p1... so a quote in one can't break the command.
            let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let promptArgs = todo.enumerated().map { "--prompt \(quote("p\($0.offset)=\($0.element)"))" }.joined(separator: " ")
            let command = "bash run.sh --input input.wav --out stems --rerank 4 \(promptArgs)"
            let minutes = Self.maxMinutes(seconds: seconds, prompts: todo.count)
            let arguments = ["run", "--target", "runpod", "--gpu", "5090", "--plain", "--disk-gb", "80",
                             "--secret", "HF_TOKEN=huggingface", "--max-minutes", String(minutes),
                             "--up", job.path, "--down", "stems/:\(out.path)", "--", command]
            progress("Separating \(todo.map { "\"\($0)\"" }.joined(separator: ", ")) from \(TimeText.duration(Time(seconds: seconds))) of \(item.path) on a RunPod RTX 5090 (setup and the model's load take about 10 minutes; the pod is deleted after, or at \(minutes) minutes whatever happens).")
            var cost = 0.0
            var finished = false
            for attempt in 1...4 {
                let result = try await Self.run(runner, arguments, progress: progress)
                cost += result.costUSD ?? 0
                if result.status == 0 { finished = true; break }
                guard result.noCapacity, attempt < 4 else {
                    throw ServiceError(.internalError, "SAM Audio failed on the pod (render-box exited \(result.status)). The last lines:\n" + result.tail.joined(separator: "\n"))
                }
                progress("No RTX 5090 with direct SSH on that try; asking for another.")
            }
            guard finished else { throw ServiceError(.internalError, "No RunPod RTX 5090 was free after four tries. Try again later.") }
            let report = (try? JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("report.json")))) as? [String: Any]
            let gpu = (report?["gpu"] as? String).map { $0.replacingOccurrences(of: "NVIDIA GeForce ", with: "") }
            for (index, prompt) in todo.enumerated() {
                let target = out.appendingPathComponent("p\(index).target.wav")
                let residual = out.appendingPathComponent("p\(index).residual.wav")
                guard FileManager.default.fileExists(atPath: target.path), FileManager.default.fileExists(atPath: residual.path) else {
                    throw ServiceError(.internalError, "The pod finished without stems for \"\(prompt)\".")
                }
                let info = SeparationInfo(prompt: prompt, model: SeparationStore.model, mediaPath: item.path, seconds: seconds, gpu: gpu,
                                          costUSD: cost > 0 ? cost / Double(todo.count) : nil)
                let stems = try store.commit(fingerprint: fingerprint, target: target, residual: residual, info: info)
                outcomes[prompt] = Outcome(prompt: prompt, target: stems.target.path, residual: stems.residual.path, reused: false, gpu: gpu, costUSD: info.costUSD)
            }
        }
        return wanted.compactMap { outcomes[$0] }
    }

    struct RunResult {
        var status: Int32
        var noCapacity: Bool
        var costUSD: Double?
        var tail: [String]
    }

    /// Runs the runner, passing on the lines worth seeing as it goes.
    static func run(_ runner: URL, _ arguments: [String], drainSeconds: Double = 5, progress: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        let process = Process()
        process.executableURL = runner
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var buffer = Data()
            var all: [String] = []
        }
        let lines = Lines()
        let interesting = ["created", "ready after", "loaded", "window", "Traceback", "Error", "out of GPU memory", "No capacity", "deleted"]
        let keep = { (bytes: Data) in
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            lines.all.append(line)
            if interesting.contains(where: line.contains) { progress(line) }
        }
        let reachedEnd = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                reachedEnd.signal()
                return
            }
            lines.lock.withLock {
                lines.buffer.append(data)
                // Progress bars rewrite one line with carriage returns.
                while let end = lines.buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    keep(lines.buffer[..<end])
                    lines.buffer.removeSubrange(...end)
                }
            }
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            // Set before it starts, so an exit straight away can't be missed.
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
        // The exit can overtake the output: render-box's last lines (the metrics path,
        // "No capacity") may still be in the pipe, so read on until it's empty. Something
        // the runner left behind can hold the pipe open, and the job's been paid for by
        // now, so that wait has a limit.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = reachedEnd.wait(timeout: .now() + drainSeconds)
                done.resume()
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let all = lines.lock.withLock {
            // A last line with no newline never met the loop above.
            keep(lines.buffer)
            lines.buffer.removeAll()
            return lines.all
        }
        // render-box prints where it kept the job's metrics, with the estimated cost.
        var cost: Double?
        if let line = all.last(where: { $0.contains("metrics: ") }), let path = line.components(separatedBy: "metrics: ").last,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path.trimmingCharacters(in: .whitespaces))),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cost = json["estimated_cost_usd"] as? Double
        }
        return RunResult(status: process.terminationStatus, noCapacity: all.contains { $0.contains("No capacity in any allowed tier") },
                         costUSD: cost, tail: Array(all.suffix(12)))
    }
}
