import Foundation

// Talk cut from a take, for `tandem check`.
//
// The skill has said "Live demos: cut the mistakes, not the material...
// keep every point he makes" since 16 Oct 2026, and agents still cut real
// lines for length. On the Exact + Convex demo (10 Nov 2026) the first
// hand-back dropped Mike's opener ("I love Expo. Let's Build It, my vibe
// coding app for kids, is built on it"), "very much kind of in the Expo
// vein", the likes and most of the demo's talk. He asked "Why have you cut
// out the bit about Let's Build It, my initial opener?" and then "you just
// cut out way too much of me talking". Rules in the skill hadn't stopped
// it, so the check compares what's kept with the take's transcript and
// quotes the whole sentences of real talk that a cut took out.
//
// Noisy is worse than missing here, so what a take always loses isn't
// counted: retakes (the same words said again just after, or just before),
// false starts, slips and asides to himself ("let me just redo that bit",
// "editor's note"), short fragments, and whatever follows the last kept
// word. Excerpt edits (a social cut keeping a tenth of a talk), Shorts and
// conversations, where most of the take goes on purpose, aren't checked.
// Run over the Exact demo's history and Mike's other finished edits, it
// flagged every line he asked to have back in the first cut, and nothing in
// the 4:08 cut he shipped.

extension QualityCheck {
    /// A take whose edit keeps less of it than this is an excerpt (a social
    /// cut, a highlight): most of it goes on purpose. The Exact demo's
    /// over-cut first round still kept 24%; the Databased social cut kept 8%.
    public static let cutTalkLeastKept = 0.15
    /// Talk cut before the first kept word counts as his opener for this
    /// long before it. Earlier is pre-roll: settling in, mic checks.
    public static let cutTalkOpeningReach = Time(seconds: 30)
    /// A cut in the middle needs this many words of real talk, across at
    /// least two sentences, to be noted. Its opener needs fewer, and one
    /// sentence: the opener is often his own reason for the video.
    static let cutTalkLeastWords = 8
    static let cutTalkLeastSentences = 2
    static let cutTalkOpeningLeastWords = 4
    /// A sentence needs this many words that carry meaning to count.
    static let cutTalkSentenceWords = 3
    /// A sentence this much of whose words come again just after it, or
    /// were just said before, is a retake.
    static let cutTalkRetakeShare = 0.5
    /// A pause this long ends a sentence the engine didn't punctuate.
    static let cutTalkSentenceGap = Time(seconds: 1)

    /// Phrases that mark a sentence as a slip or an aside to himself or the
    /// crew, not a point: from the Exact demo ("let me just redo that bit",
    /// the window dragging), the Threadbear videos ("editor's note, get rid
    /// of that") and the James interview's set-up chat.
    static let cutTalkAsides: [String] = [
        "redo", "let me redo", "let me just", "start again", "start over", "one more time", "try that again", "say that again",
        "ask that again", "ask the question again", "ask a question again", "ask me the question",
        "editor's note", "editors note", "edit that out", "cut that", "get rid of that", "get rid of this",
        "whoops", "oops", "struggling", "for some reason", "rearrange", "move this window", "can't drag", "hang on",
        "take two", "take 2", "final take", "tape two", "are we live", "can you hear me", "i'll pause", "this noise",
        "looking in the right place", "look in the camera"
    ]

    /// Words that carry no point of their own, so a sentence of them isn't
    /// real talk however long it runs.
    static let cutTalkStopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "if", "then", "i", "i'm", "i've", "i'll", "i'd", "you", "we", "it", "it's", "its",
        "is", "are", "was", "were", "be", "been", "to", "of", "in", "on", "at", "for", "with", "as", "that", "this", "these", "those",
        "there", "there's", "here", "just", "like", "kind", "sort", "okay", "ok", "yeah", "yes", "well", "really", "very", "can",
        "could", "should", "would", "will", "do", "does", "did", "have", "has", "had", "me", "my", "your", "our", "they", "them",
        "he", "his", "she", "her", "what", "which", "who", "not", "no", "go", "going", "gonna", "get", "got", "all", "also",
        "about", "up", "out", "from", "by", "into", "one", "some", "thing", "things", "um", "uh", "uhm", "er", "erm", "ah",
        "hmm", "mm", "oh"
    ]

    /// A note for each cut in `ranges` that takes out whole sentences of
    /// real talk from a take, quoting them. A cut is at the join where the
    /// talk was taken out, so `check --changed` only judges the cuts an
    /// agent made since Mike's last review, not the ones he made himself.
    public static func cutTalk(in project: Project, ranges: [TimeRange], speech: Speech) -> [CheckProblem] {
        // A Short is an excerpt by design, and in a conversation the other
        // voices' takes go in and out on purpose.
        guard project.settings.width >= project.settings.height, !isConversation(project, speech: speech) else { return [] }
        return speech.takes.filter(isCutDown).flatMap { cutTalk($0, ranges: ranges) }
    }

    /// Whether the edit is a conversation: its name or files say so, or
    /// two voice files play over each other for long (several people's
    /// mics, as on Databased, whose mics share one take). A camera's own
    /// sound heard under an external mic counts too, so that edit goes
    /// unchecked rather than noted wrongly.
    static func isConversation(_ project: Project, speech: Speech) -> Bool {
        conversation(project) || talkOverEachOther(speech.takes.filter { $0.words.filter { $0.played != nil }.count >= 20 })
    }

    /// A take cut down, not an excerpt: enough of it kept.
    static func isCutDown(_ take: Speech.Take) -> Bool {
        let kept = take.words.filter { $0.played != nil }.count
        return kept >= 20 && Double(kept) >= Double(take.words.count) * cutTalkLeastKept
    }

    /// Whether two takes play over each other for long: several people's
    /// mics, a conversation.
    static func talkOverEachOther(_ takes: [Speech.Take]) -> Bool {
        let spans = takes.compactMap { take -> TimeRange? in
            let played = take.words.compactMap(\.played)
            guard let first = played.min(), let last = played.max(), last > first else { return nil }
            return TimeRange(start: first, end: last)
        }
        for (index, a) in spans.enumerated() {
            for b in spans[(index + 1)...] {
                guard let both = a.intersection(b) else { continue }
                if both.duration.seconds > min(a.duration.seconds, b.duration.seconds) * 0.3 { return true }
            }
        }
        return false
    }

    static func cutTalk(_ take: Speech.Take, ranges: [TimeRange]) -> [CheckProblem] {
        let words = take.words
        var found: [CheckProblem] = []
        var index = 0
        var lastKept: Int?
        while index < words.count {
            guard words[index].played == nil else {
                lastKept = index
                index += 1
                continue
            }
            var end = index
            while end < words.count, words[end].played == nil { end += 1 }
            defer { index = end }
            // Whatever follows the last kept word is the tail: the sign-off
            // has been said, and the rest is stopping the recording.
            guard end < words.count, let at = words[end].played else { continue }
            guard ranges.contains(where: { $0.start <= at && at <= $0.end }) else { continue }
            let opening = lastKept == nil
            var start = index
            if opening {
                let reach = words[end].start - cutTalkOpeningReach
                while start < end, words[start].start < reach { start += 1 }
            }
            let real = realSentences(in: words, start..<end, keptBefore: lastKept)
            let count = real.reduce(0) { $0 + $1.words }
            let enough = opening
                ? count >= cutTalkOpeningLeastWords && !real.isEmpty
                : count >= cutTalkLeastWords && real.count >= cutTalkLeastSentences
            guard enough else { continue }
            let said = real.map(\.text).joined(separator: " ")
            let quoted = said.count > 240 ? String(said.prefix(240)) + "..." : said
            let clips = [lastKept.flatMap { words[$0].clipID }, words[end].clipID].compactMap { $0 }
            let message: String
            if opening {
                message = "Talk cut: his opening lines, before the first line kept: \"\(quoted)\" An opener is often his own reason for the video, and the last thing to go. Put it back unless it's a retake, and leave cuts for length to Mike."
            } else {
                let length = String(format: "%.0f", (words[end - 1].end - words[index].start).seconds)
                message = "Talk cut: \(real.count) sentences of what he says (\(length) s of the take) at this join: \"\(quoted)\" Mike wants every point he makes kept, even over length. Put it back, or name it in the hand-back as a cut he can undo."
            }
            var seen = Set<String>()
            found.append(CheckProblem(kind: .cutTalk, start: at, end: at, message: message, clipIDs: clips.filter { seen.insert($0).inserted }))
        }
        return found
    }

    struct TalkSentence {
        var text: String
        /// Words that carry meaning.
        var words: Int
    }

    /// The sentences in `span` that are real talk: enough words that carry
    /// meaning, no slip or aside, not said again just after it (a retake)
    /// or just before it.
    static func realSentences(in words: [Speech.Take.Word], _ span: Range<Int>, keptBefore: Int?) -> [TalkSentence] {
        var real: [TalkSentence] = []
        for sentence in sentences(in: words, span) {
            let text = sentence.map { words[$0].text }.joined(separator: " ")
            let tokens = openingTokens(text)
            let meaning = meaningful(tokens)
            guard meaning.count >= cutTalkSentenceWords else { continue }
            let padded = " " + tokens.joined(separator: " ") + " "
            guard !cutTalkAsides.contains(where: { padded.contains(" \($0) ") }) else { continue }
            // What he says next, kept or not (a retake comes straight
            // after), and what was said just before.
            let after = sentence.upperBound..<min(words.count, sentence.upperBound + max(25, 2 * sentence.count))
            let before = max(0, sentence.lowerBound - 30)..<sentence.lowerBound
            let ahead = Set(meaningful(openingTokens(after.map { words[$0].text }.joined(separator: " "))))
            let behind = Set(meaningful(openingTokens(before.filter { words[$0].played != nil || $0 >= span.lowerBound }.map { words[$0].text }.joined(separator: " "))))
            let share = { (seen: Set<String>) in Double(meaning.filter(seen.contains).count) / Double(meaning.count) }
            guard share(ahead) < cutTalkRetakeShare, share(behind) < cutTalkRetakeShare else { continue }
            real.append(TalkSentence(text: text, words: meaning.count))
        }
        return real
    }

    /// The span's words in sentences: ended by a full stop, question or
    /// exclamation mark, or a long pause.
    static func sentences(in words: [Speech.Take.Word], _ span: Range<Int>) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var start = span.lowerBound
        for index in span {
            let last = words[index].text.trimmingCharacters(in: .whitespaces).last
            let stops = last == "." || last == "?" || last == "!"
            let pause = index + 1 < span.upperBound && words[index + 1].start - words[index].end > cutTalkSentenceGap
            if stops || pause || index == span.upperBound - 1 {
                found.append(start..<(index + 1))
                start = index + 1
            }
        }
        return found
    }

    /// The tokens that carry meaning, with plurals and endings off so
    /// "anyway" meets "anyways".
    static func meaningful(_ tokens: [String]) -> [String] {
        tokens.filter { $0.count > 1 && !cutTalkStopWords.contains($0) }.map { token in
            guard token.count > 4 else { return token }
            for ending in ["ing", "ed", "es", "s"] where token.hasSuffix(ending) {
                return String(token.dropLast(ending.count))
            }
            return token
        }
    }
}
