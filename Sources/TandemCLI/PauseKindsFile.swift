import Foundation
import TandemAPI
import TandemCore

/// The file `tandem tighten --filmora --kinds <file>` writes on a dry run and
/// reads back: every pause with the words either side, the tool's guess at
/// its kind, and the kind the agent gives it after reading the words.
/// Bark puts a full stop wherever Mike pauses, so the guess is only a
/// start; `--apply` needs every kind filled in.
struct PauseKindsFile: Codable {
    struct Entry: Codable {
        var start: Double
        var end: Double
        /// Speech end to speech start, as it is now.
        var heard: Double
        var before: String
        var after: String
        var guess: String
        /// mid (0.12 s), clause (0.2 s), sentence (0.4 s), topic (0.8 s) or
        /// keep. Empty until the agent fills it in.
        var kind: String?
    }

    var revision: Int
    /// What the pauses were found with: an apply with other settings finds
    /// other pauses, so it's refused.
    var settings: Settings?
    struct Settings: Codable, Equatable {
        var threshold: Double?
        var min: Double?
        var from: Double?
        var to: Double?
    }
    var kinds = "mid: inside a phrase, no pause heard (0.12 s). clause: a comma, before and/but/so/because/which/if, a list item (0.2 s). sentence: between sentences in the same train of thought (0.4 s). topic: a new topic or paragraph (0.8 s). keep: deliberate, a scripted beat or a demo action on screen (left alone). Ignore Bark's punctuation: read the words."
    var pauses: [Entry]

    init(revision: Int, settings: Settings, pauses: [FilmoraPause]) {
        self.revision = revision
        self.settings = settings
        self.pauses = pauses.map {
            Entry(start: $0.start.seconds, end: $0.end.seconds, heard: $0.heard.seconds, before: $0.before, after: $0.after, guess: $0.guess.rawValue, kind: $0.kind?.rawValue)
        }
    }

    /// Each filled-in kind, at the middle of its pause.
    func marks() throws -> [PauseKindMark] {
        try pauses.compactMap { entry in
            guard let text = entry.kind?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
            guard let kind = SpokenPause(rawValue: text) else {
                throw UsageError(message: "\"\(text)\" at \(entry.start) isn't a kind: use mid, clause, sentence, topic or keep.")
            }
            return PauseKindMark(at: Time(seconds: (entry.start + entry.end) / 2), kind: kind)
        }
    }
}
