import Foundation

// Mid-sentence pauses for `tandem check`.
//
// On the Convex Auth v2 video (12 Nov 2026) the first hand-back kept "And I
// built the entire thing from scratch using. [0.65 s] The latest and
// greatest convex best principles", and Mike: "There's weird pause here when
// it's mid sentence... don't forget mid sentence no big pause."
// `tighten --filmora` now closes mid-sentence pauses itself (#117), going by
// the word before the pause, but an edit tightened before that, or by hand,
// or where its reading of the words missed one, still has them. So the
// check looks for what's left, and its fix is `--filmora` over the pause
// with `--mid-at`, which closes it whatever the words say.
//
// Bark's full stops can't be trusted in his fast runs: it wrote "using."
// there, "OS. | but more on that" and "etc. | so you can" on the same
// video. So what a pause follows goes by the words either side as well as
// the punctuation (`SpokenPause.kind`), a little wider than tighten's own
// reading: the check only flags, and Mike's agent reads each one.

/// What a pause between two words follows: the end of a sentence, a comma,
/// or neither (the middle of a sentence).
public enum SpokenPause {
    public enum Kind: String, Sendable {
        case sentence, comma, mid
    }

    /// What a pause follows, from the last word of `before` and the first
    /// of `next` (either can be a few words; only the edges count).
    ///
    /// Punctuation first: . ? ! or ... ends a sentence, , ; : is a comma.
    /// Then the words, since the transcription engine's full stops slip:
    /// - a word no sentence ends on ("the", "using", "and", "it's") carries
    ///   on whatever follows it: "using. | The latest" is mid-sentence;
    /// - a full stop followed by a lowercase joining word ("etc. | so you
    ///   can", "OS. | but more on that") carries on;
    /// - "etc." and other abbreviations end a sentence only before a capital;
    /// - no punctuation before a capitalised word that starts sentences
    ///   ("now | And I built", "later | Out of the box") is a sentence the
    ///   engine didn't punctuate. A capitalised name ("using | Convex")
    ///   isn't one, so it stays mid-sentence.
    public static func kind(before: String, next: String? = nil) -> Kind {
        let last = edgeWord(before, last: true)
        let bare = bareWord(last)
        let following = next.map { edgeWord($0, last: false) } ?? ""
        let followingBare = bareWord(following)
        let nextIsLower = following.first(where: \.isLetter)?.isLowercase ?? false
        let nextIsCapital = following.first(where: \.isLetter)?.isUppercase ?? false

        var kind = punctuation(last)
        if kind == .sentence, abbreviations.contains(bare) {
            // "etc." ends a sentence only when the next one starts.
            kind = nextIsLower ? .mid : .sentence
        }
        // Only a full stop is overridden: Bark's slip is a "." where Mike
        // ran on. A question mark or "!" ("What is it made of?") is meant.
        let fullStop = last.trimmingCharacters(in: closers).hasSuffix(".") && !last.hasSuffix("...")
        if (kind == .mid || (kind == .sentence && fullStop)), neverEnds.contains(bare) { return .mid }
        // A preposition can end a sentence when it's stranded ("the tool
        // I'm using.", "where I'm coming from."), but not after a noun
        // ("from scratch using. | The latest").
        if kind == .sentence, fullStop, runsOn.contains(bare), !strands(bareWord(wordBefore(before))) { return .mid }
        if kind == .sentence, fullStop, nextIsLower, joiners.contains(followingBare) {
            return .mid
        }
        if kind == .mid, nextIsCapital, !isI(followingBare), starters.contains(followingBare) {
            return .sentence
        }
        return kind
    }

    /// From the punctuation alone, as `tighten` always went.
    static func punctuation(_ word: String) -> Kind {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: closers)
        guard let last = trimmed.last else { return .mid }
        if ".?!\u{2026}".contains(last) { return .sentence }
        if ",;:".contains(last) { return .comma }
        return .mid
    }

    static let closers = CharacterSet(charactersIn: "\"'\u{201D}\u{2019})]\u{BB}")

    static func edgeWord(_ text: String, last: Bool) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return String((last ? words.last : words.first) ?? "")
    }

    /// Lowercased, without punctuation either side ("Using." is "using",
    /// "it's," is "it's").
    static func bareWord(_ word: String) -> String {
        var text = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        while let first = text.first, !first.isLetter, !first.isNumber { text.removeFirst() }
        while let last = text.last, !last.isLetter, !last.isNumber { text.removeLast() }
        return text
    }

    /// The word as written, without punctuation either side ("OS." is "OS").
    static func trimmed(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    static func isI(_ bare: String) -> Bool {
        bare == "i" || bare.hasPrefix("i'")
    }

    /// Words a sentence doesn't end on in Mike's talk: articles and
    /// possessives, joining words, the prepositions he runs into a list
    /// with, and the contractions that open a clause. "to", "for", "on",
    /// "like" and "though" can end one ("I'd love to", "turn it on", "it
    /// works, though"), so they're not here.
    static let neverEnds: Set<String> = [
        "a", "an", "the", "my", "your", "our", "their", "its",
        "and", "or", "but", "nor", "because", "than", "if", "whether", "although",
        "very",
        "it's", "there's", "here's", "that's", "what's", "let's", "i'm", "we're", "you're", "they're",
        "i've", "we've", "you've", "i'll", "we'll", "you'll", "i'd", "we'd", "you'd", "i",
    ]

    /// Words that lead into what follows unless they're stranded at the
    /// end of a clause (`strands`).
    static let runsOn: Set<String> = ["using", "with", "of", "from", "into", "onto", "via"]

    /// The word before the last in `text`.
    static func wordBefore(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count >= 2 ? String(words[words.count - 2]) : ""
    }

    /// Whether a word before a preposition leaves it stranded at the end of
    /// a clause: a pronoun or a form of "be" ("I'm using", "it is from"), a
    /// verb in -ing or -ed ("coming from", "worked with"), or a common
    /// irregular participle ("made of", "built with"). Nothing before it
    /// (the start of the context) counts as stranded, to be safe.
    static func strands(_ word: String) -> Bool {
        guard !word.isEmpty else { return true }
        if word.hasSuffix("ing") || word.hasSuffix("ed") { return true }
        return [
            "i", "i'm", "we", "we're", "you", "you're", "they", "they're", "he", "she", "it", "it's", "that's", "what's",
            "is", "are", "was", "were", "am", "be", "been", "being", "made", "built", "done", "known", "written", "come", "gone",
            "what", "which", "who", "where", "that", "this", "these", "those", "them", "me", "us", "him", "her",
        ].contains(word)
    }

    /// Lowercase words after a full stop that join on to what came before:
    /// the engine put the stop in, not Mike.
    static let joiners: Set<String> = [
        "and", "but", "or", "so", "because", "which", "that", "like", "with", "to", "then", "plus", "where", "who", "than", "as",
    ]

    static let abbreviations: Set<String> = ["etc", "e.g", "i.e", "eg", "ie", "vs", "approx"]

    /// Everyday words that start a sentence when capitalised mid-run, as
    /// the engine starts one where it heard it: not names.
    static let starters: Set<String> = [
        "and", "but", "so", "now", "okay", "ok", "then", "well", "right", "oh", "the", "this", "that", "these", "those", "it", "it's",
        "we", "we're", "you", "you're", "they", "if", "what", "how", "why", "when", "where", "let", "let's", "here", "here's", "there",
        "there's", "anyway", "anyways", "basically", "actually", "also", "yeah", "yes", "no", "alright", "out", "in", "on", "of", "for",
        "to", "with", "my", "our", "your", "a", "an", "just", "because", "once", "all", "plus", "however", "anyhow", "hey", "hi", "hello",
        "next", "first", "finally", "otherwise", "unfortunately", "luckily", "hopefully", "honestly", "sure", "cool", "nice", "great",
    ]
}

extension QualityCheck {
    /// A pause between two words, as the transcript has it and as it's
    /// heard (`tandem pauses`).
    public struct HeardPause: Equatable, Sendable {
        /// The longest stretch of real quiet in it, in timeline time, as
        /// `tandem pauses` hears it: a breath is sound there.
        public var start: Time
        public var end: Time
        /// The transcript's gap.
        public var gap: TimeRange
        /// The last words before it and the first after it.
        public var before: String
        public var after: String
        public var clipIDs: [String]
        /// Every stretch of real quiet in it, the longest included: a click
        /// or a breath can split it.
        public var quiets: [TimeRange]

        public init(start: Time, end: Time, gap: TimeRange? = nil, before: String, after: String, clipIDs: [String] = [], quiets: [TimeRange]? = nil) {
            self.start = start
            self.end = end
            self.gap = gap ?? TimeRange(start: start, end: end)
            self.before = before
            self.after = after
            self.clipIDs = clipIDs
            self.quiets = quiets ?? (end > start ? [TimeRange(start: start, end: end)] : [])
        }

        /// The quiet in it.
        public var quiet: Time { end - start }
        /// How long the pause sounds: the longer of the quiet and the
        /// transcript's gap. On the Auth v2 video "using. | The latest"
        /// was 0.65 s between the words and 0.19 s of it quiet, the rest a
        /// breath (-64 dB over a -80 dB room), and Mike heard all of it
        /// as a pause.
        public var duration: Time { max(quiet, gap.duration) }
        /// Both, in timeline time.
        public var range: TimeRange { TimeRange(start: min(start, gap.start), end: max(end, gap.end)) }
    }

    /// A pause in a sentence this long or longer is a thinking pause to
    /// close: `tighten --filmora` changes silences from 0.5 s (its `--min`).
    public static let midSentencePauseMinimum = Time(seconds: 0.5)
    /// Longer than this, a gap is a beat for something on screen (a page
    /// loading, a result appearing), not a thinking pause; dead air covers
    /// it if the picture is still.
    public static let midSentencePauseLongest = Time(seconds: 3)
    /// A pause with less quiet than `midSentencePauseMinimum` (the rest a
    /// breath or the words' tails) needs this much between the words, since
    /// the transcript's word edges can be 0.1 s or more off the sound.
    static let midSentenceBreathyPause = Time(seconds: 0.6)
    /// The most a check lists; past that it says how many more there are,
    /// to check again once these are closed.
    static let midSentencePausesListed = 40

    /// What closes a pause: `tighten --filmora` over it, which cuts by
    /// volume (a breath counts as silence) and keeps 0.08 s each side
    /// mid-sentence. `--mid-at` makes it read the pause as mid-sentence
    /// whatever it makes of the words, since it picks the word before by
    /// the sound's edges and reads it more narrowly than this check does.
    /// A time in each stretch of real quiet, as a click can split the
    /// silence it finds in two. Only ever over the pause (`from`, `to`):
    /// over the whole edit it would re-cut every long silence, a
    /// deliberate beat included.
    static func midSentenceFix(_ pause: HeardPause, from: Time, to: Time) -> String {
        let quiet = pause.quiets.filter { $0.duration >= Time(seconds: 0.1) }
        let marks = quiet.isEmpty ? [pause.range] : quiet
        let times = marks.map { "\($0.start + Time(seconds: $0.duration.seconds / 2))" }.joined(separator: ",")
        return "tandem tighten --filmora --from \(from) --to \(to) --mid-at \(times)"
    }

    /// Notes for pauses of `midSentencePauseMinimum` or more, heard, in the
    /// middle of a sentence or after a comma (`SpokenPause.kind`) in
    /// `ranges`, with the `tighten --filmora` that closes each. Not in a conversation,
    /// where a gap is often the other person's turn.
    public static func midSentencePauses(_ pauses: [HeardPause], in project: Project, ranges: [TimeRange], speech: Speech) -> [CheckProblem] {
        guard !isConversation(project, speech: speech) else { return [] }
        let found = pauses.filter { pause in
            pause.duration >= (pause.quiet >= midSentencePauseMinimum ? midSentencePauseMinimum : midSentenceBreathyPause)
                && pause.duration <= midSentencePauseLongest
                && SpokenPause.kind(before: pause.before, next: pause.after) != .sentence
                && ranges.contains { $0.overlaps(pause.range) }
        }.sorted { $0.range.start < $1.range.start }
        guard !found.isEmpty else { return [] }

        func quote(_ pause: HeardPause) -> String {
            "\"...\(pause.before) [\(seconds(pause.duration))] \(pause.after)...\""
        }
        func why(_ pause: HeardPause) -> String {
            let last = SpokenPause.edgeWord(pause.before, last: true)
            switch SpokenPause.punctuation(last) {
            case .comma: return "after a comma"
            case .sentence: return "the transcript's full stop after \"\(SpokenPause.trimmed(last))\" isn't the end of the sentence"
            case .mid: return "mid-sentence"
            }
        }
        let listed = found.prefix(midSentencePausesListed)
        var notes = listed.map { pause -> CheckProblem in
            let range = pause.range
            // Wide enough that the silence and the words either side are in.
            let from = max(.zero, range.start - Time(seconds: 0.5)), to = range.end + Time(seconds: 0.5)
            let message = "Mid-sentence pause: \(quote(pause)), \(why(pause)). Mike: \"don't forget mid sentence no big pause\". "
                + "Close it: \(midSentenceFix(pause, from: from, to: to)) (dry run, then --apply), then check --cuts."
            return CheckProblem(kind: .midSentencePause, start: range.start, end: range.end, message: message, clipIDs: pause.clipIDs)
        }
        let rest = found.dropFirst(midSentencePausesListed)
        if let first = rest.first, let last = rest.last {
            notes.append(CheckProblem(
                kind: .midSentencePause, start: first.range.start, end: last.range.end,
                message: "\(rest.count) more mid-sentence pause\(rest.count == 1 ? "" : "s") of \(seconds(midSentencePauseMinimum)) or more, \(found.count) in all, from \(quote(first)) on. "
                    + "Close the ones above, then check again for these.",
                clipIDs: first.clipIDs
            ))
        }
        return notes
    }
}
