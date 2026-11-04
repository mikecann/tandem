import Foundation

// How a Short opens, for `tandem check`.
//
// A Short is watched by people who never saw the video or talk it came
// from, so it has to stand on its own. Mike said so three times: a Tandem
// tip Short that "kind of refers back to the video" (20 Oct 2026), "each
// short is designed to be self-contained" (30 Oct), and all seven Abstract
// Fireside Shorts going out on the answer, "We don't know what the question
// is when it starts" (4 Nov). The skill already said it and agents still
// missed it, so the check reads the opening out. It's a note, never a
// failure: a tip Short can open on a strong claim with no question. And
// it's quiet when the opening is fine, so agents don't learn to skip it.

extension QualityCheck {
    /// How much of a Short counts as its opening: about what a viewer gives
    /// it before swiping, and what `build.py opening` read for the Fireside
    /// Shorts.
    public static let shortOpeningLength = Time(seconds: 12)

    /// Words a Short shouldn't start on, because they lean on something the
    /// viewer didn't see: a conjunction carrying on a thought, a reply, a
    /// pointer back ("the other", "like I said") or a host's segue. From the
    /// Fireside Shorts' first cuts ("And it's not to say...", "The other
    /// area...", "The biggest one...") and the abstract-talk-clips build.py.
    public static let backReferences: [String] = [
        "and", "so", "but", "or", "also", "plus", "then", "because", "which", "yeah", "yes", "well", "exactly", "anyway",
        "the other", "another", "the biggest one", "the next one", "the last one", "the second", "the third",
        "that one", "this one", "those", "these", "that's why", "it's not to say",
        "like i said", "as i said", "like i mentioned", "as i mentioned", "as we said", "as we talked about",
        "as you can see", "as you're seeing", "as you saw", "like you said", "as you said",
        "shifting gears", "last ninety seconds", "in the last ninety"
    ]

    /// Sounds before the first word that don't count as how it starts.
    static let openingFillers: Set<String> = ["um", "uh", "uhm", "er", "erm", "ah", "hmm", "mm"]

    /// Words in a Short's name, or the files it plays, that make it a
    /// conversation: one that should open on the question it answers.
    static let conversationWords: Set<String> = ["fireside", "interview", "interviews", "podcast", "q&a", "qa", "qna", "panel", "ama"]

    /// A note on a Short's opening (a project taller than it's wide) when it
    /// starts on a back-reference, or when it's a Q&A with no question in
    /// it. Only when `ranges` reach into the opening, so `check --changed`
    /// says it again only when the opening changed.
    public static func shortOpening(in project: Project, ranges: [TimeRange], speech: Speech) -> [CheckProblem] {
        guard project.settings.height > project.settings.width else { return [] }
        let opening = TimeRange(start: .zero, end: shortOpeningLength)
        guard ranges.contains(where: { $0.overlaps(opening) }) else { return [] }
        let words = speech.words.filter { $0.start < shortOpeningLength }
        guard !words.isEmpty else { return [] }
        let said = words.map(\.text).joined(separator: " ")
        let tokens = openingTokens(said)
        var leading = tokens[...]
        while let first = leading.first, openingFillers.contains(first) { leading = leading.dropFirst() }
        let backReference = backReferences
            .filter { phrase in
                let parts = phrase.split(separator: " ").map(String.init)
                return leading.starts(with: parts)
            }
            .max { $0.count < $1.count }
        let isConversation = conversation(project)
        let missingQuestion = isConversation && !asksAQuestion(said, tokens: tokens)
        guard backReference != nil || missingQuestion else { return [] }

        let quoted = said.count > 300 ? String(said.prefix(300)) + "..." : said
        var message = "How this Short opens (the first \(Int(shortOpeningLength.seconds)) s): \"\(quoted)\""
        if let backReference {
            // Quote it as said, so the agent can find it.
            let shown = said.split(separator: " ").drop { openingFillers.contains(openingTokens(String($0)).first ?? "") }
                .prefix(backReference.split(separator: " ").count).joined(separator: " ")
            message += " It starts on \"\(shown.trimmingCharacters(in: .punctuationCharacters))\", which refers back to something a viewer who hasn't seen the rest didn't hear. Start where the thought starts."
        }
        if missingQuestion {
            message += " It's a Q&A Short with no question in it: open on the question it answers, even from earlier or later in the talk."
        }
        return [CheckProblem(kind: .shortOpening, start: words[0].start, end: words[words.count - 1].end, message: message, clipIDs: pictures(at: words[0].start, in: project))]
    }

    /// Lower case words with their punctuation off (apostrophes kept).
    static func openingTokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    /// Whether a conversation's name or the files it plays say so.
    static func conversation(_ project: Project) -> Bool {
        var played: Set<String> = []
        for track in project.allTracks where !track.hidden {
            for clip in track.clips where clip.enabled {
                if case .media(let id) = clip.content { played.insert(id) }
            }
        }
        let names = [project.name] + project.media.filter { played.contains($0.id) }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        return names.contains { name in
            let lower = name.lowercased()
            if lower.contains("q&a") { return true }
            return lower.split { !($0.isLetter || $0.isNumber) }.contains { conversationWords.contains(String($0)) }
        }
    }

    /// Whether the opening asks something. Transcripts don't always punctuate
    /// (Fireside 7's came back with none, "what does developer infrastructure
    /// look like in five years"), so a question's opening words count as well
    /// as a question mark.
    static func asksAQuestion(_ said: String, tokens: [String]) -> Bool {
        if said.contains("?") { return true }
        let asking: Set<String> = ["what", "how", "why", "who", "where", "when", "which"]
        let then: Set<String> = ["do", "does", "did", "is", "are", "was", "were", "would", "could", "should", "can", "will", "if", "about", "happens", "happened"]
        let helpers: Set<String> = ["do", "does", "did", "would", "could", "can", "should", "are", "have", "will"]
        let people: Set<String> = ["you", "we", "they"]
        for (word, next) in zip(tokens, tokens.dropFirst()) {
            if asking.contains(word), then.contains(next) { return true }
            if helpers.contains(word), people.contains(next) { return true }
        }
        return tokens.contains { ["what's", "how's", "why's", "who's", "where's"].contains($0) }
    }
}
