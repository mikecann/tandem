import AVFoundation
import Foundation
import TandemCore
import TandemMedia

// Runs Bark 3.0 Pro, as Tandem's transcripts do, on audio files and writes
// each one's transcript (Tandem's transcript.json format) to a folder, for
// scoring against other engines (tests/bark-check/).
//
//   tandem-bark-check [--models <coreml folder>] [--compiled <folder>] [--download] [--whole] --out <folder> <audio>...
//
// --models is a folder laid out as the model repository's coreml/ (the
// default is the one Tandem downloads to). --compiled is where the compiled
// models go (default <models>/compiled). --download fetches whatever is
// missing or damaged there from the pinned Hugging Face commit, as Tandem
// does (it always does for the default folder). --whole hands each file to
// FluidAudio in one go, so its own long-audio chunking cuts it.
// TANDEM_BARK_UNITS=cpu runs the encoder on the CPU instead of the Neural
// Engine.

var arguments = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
var flags = Set<String>()
var files: [URL] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--models", "--compiled", "--out":
        guard !arguments.isEmpty else { FileHandle.standardError.write(Data("\(argument) needs a value\n".utf8)); exit(2) }
        options[argument] = arguments.removeFirst()
    case "--whole", "--download":
        flags.insert(argument)
    default:
        files.append(URL(fileURLWithPath: argument))
    }
}
guard let out = options["--out"].map({ URL(fileURLWithPath: $0, isDirectory: true) }), !files.isEmpty else {
    print("usage: tandem-bark-check [--models <coreml folder>] [--compiled <folder>] [--download] [--whole] --out <folder> <audio>...")
    exit(2)
}
let models = options["--models"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tandem/Models/bark-3.0-pro", isDirectory: true)
let compiled = options["--compiled"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? models.appendingPathComponent("compiled", isDirectory: true)
let transcriber = BarkTranscriber(store: BarkModelStore(folder: models, compiledFolder: compiled,
                                                       download: flags.contains("--download") || options["--models"] == nil))

func peakMemory() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1e6
}

do {
    let started = Date()
    try await transcriber.prepare { fraction, message in
        FileHandle.standardError.write(Data(String(format: "\r%@ %3.0f%%", message, fraction * 100).utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))
    print(String(format: "ready in %.1f s", Date().timeIntervalSince(started)))
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var totalAudio = 0.0, totalWall = 0.0
    for file in files {
        let started = Date()
        let transcript = try await transcriber.transcribe(file, wholeFile: flags.contains("--whole"))
        let wall = Date().timeIntervalSince(started)
        let audio = try await AVURLAsset(url: file).load(.duration).seconds
        totalAudio += audio
        totalWall += wall
        let name = file.deletingPathExtension().lastPathComponent
        try encoder.encode(transcript).write(to: out.appendingPathComponent("\(name).json"))
        print(String(format: "%@: %d words, %.1f s of audio in %.2f s (%.0fx realtime)", name, transcript.words.count, audio, wall, audio / wall))
    }
    print(String(format: "total: %.1f s of audio in %.2f s (%.0fx realtime), peak memory %.0f MB",
                 totalAudio, totalWall, totalAudio / max(totalWall, 0.001), peakMemory()))
} catch {
    FileHandle.standardError.write(Data("tandem-bark-check: \((error as? LocalizedError)?.errorDescription ?? "\(error)")\n".utf8))
    exit(1)
}
