import Foundation

// Pauses longer than Mike leaves them, for `tandem check`.
//
// The mid-sentence note only looked at pauses of 0.5 s or more inside a
// sentence, and dead air only at a still picture. So on the Examples Page
// video (19 Nov 2026) two 0.8 s gaps between sentences went back to him
// with B-roll moving over them, and he called them "awkward silence": "I
// have to keep telling you about these silences." Each kind of pause now
// has a length he leaves and a length from which he'd trim it, learned from
// his own trims (`PauseTaste`), and a pause past that is a note to tighten
// or answer.

extension SpokenPause {
    /// The kind a pause is held to for its length (`PauseTaste`). With no
    /// punctuation before a word that starts sentences ("one of your pages
    /// | it goes from this", "made | I guess"), the transcript may have
    /// missed a full stop, so it's held to a comma's length, not
    /// mid-sentence's: on the Examples Page edit Mike had signed off, 14 of
    /// the 30 mid-sentence pauses over 0.25 s were these.
    public static func heldKind(before: String, next: String) -> Kind {
        let kind = kind(before: before, next: next)
        guard kind == .mid, punctuation(edgeWord(before, last: true)) == .mid else { return kind }
        let word = bareWord(edgeWord(next, last: false))
        return starters.contains(word) || openers.contains(word) ? .comma : kind
    }

    /// Words that start a sentence in Mike's run-on speech but can't be in
    /// `starters`, which also reads capitals: "I" always has one.
    static let openers: Set<String> = ["i", "i'm", "i've", "i'll", "i'd", "gonna", "thanks", "thank", "maybe", "obviously", "cheers", "cheerio"]
}

extension QualityCheck {
    /// Longer than this, a gap is a beat for something on screen or a
    /// change of section, which dead air and the section cards cover.
    public static let longPauseLongest = Time(seconds: 4)
    /// The most a check lists.
    static let longPausesListed = 40

    static func flagKind(_ pause: HeardPause) -> SpokenPause.Kind {
        SpokenPause.heldKind(before: pause.before, next: pause.after)
    }

    /// Notes for pauses in `ranges` whose silence is at least `taste`'s
    /// flag for their kind, with the `tighten` that takes each to what
    /// Mike leaves. A pause the mid-sentence note already has is left to
    /// it, and so is a conversation, where a gap is often the other
    /// person's turn.
    public static func longPauses(_ pauses: [HeardPause], taste: PauseTaste, in project: Project, ranges: [TimeRange], speech: Speech) -> [CheckProblem] {
        guard !isConversation(project, speech: speech) else { return [] }
        // The pauses the mid-sentence note has one by one: not its last
        // line, which only counts how many more there are.
        let flagged = midSentencePauses(pauses, in: project, ranges: ranges, speech: speech)
            .prefix(midSentencePausesListed).map { TimeRange(start: $0.start, end: $0.end) }
        let rules = Dictionary(uniqueKeysWithValues: taste.rules.map { ($0.kind, $0) })
        var found: [HeardPause] = []
        for pause in pauses.sorted(by: { $0.range.start < $1.range.start }) {
            guard let silence = pause.silence, let rule = rules[flagKind(pause)],
                  silence.duration.seconds >= rule.flag - 1e-9, silence.duration <= longPauseLongest,
                  ranges.contains(where: { $0.overlaps(pause.range) }),
                  !flagged.contains(where: { $0.overlaps(silence) }) else { continue }
            // Two gaps either side of a word too soft to hear as voice
            // ("Okay, | stick | around") are one silence: noted once.
            if let last = found.last?.silence, last.overlaps(silence) { continue }
            found.append(pause)
        }

        func keep(_ kind: SpokenPause.Kind) -> String { String(format: "%.2f", rules[kind]?.leave ?? 0.35) }
        return found.prefix(longPausesListed).map { pause in
            let kind = flagKind(pause)
            let rule = rules[kind]!
            let silence = pause.silence!
            // Just past the pause, so the pauses beside it stay as they are.
            let from = max(.zero, pause.range.start - Time(seconds: 0.1)), to = pause.range.end + Time(seconds: 0.1)
            let what: String
            switch kind {
            case .sentence: what = "after a sentence"
            case .comma: what = SpokenPause.kind(before: pause.before, next: pause.after) == .comma ? "after a comma" : "where a new sentence may start"
            case .mid: what = "mid-sentence"
            }
            let source = rule.learned ? "the middle of \(rule.trims) of his own trims" : "his usual, until he's trimmed \(PauseTaste.fewest) of these"
            // Every pause in the stretch to what he leaves for this one's
            // kind: tighten's own reading of the kind goes by punctuation
            // alone, and a different reading would leave it as it is.
            let tighten = "tandem tighten --from \(from) --to \(to) --keep \(keep(kind)) --min \(String(format: "%.2f", rule.leave + 0.05))"
            let message = "Long pause: \"...\(pause.before) [\(seconds(silence.duration)) of silence] \(pause.after)...\", \(what). "
                + "Mike leaves \(seconds(Time(seconds: rule.leave))) there (\(source)) and hears \(seconds(Time(seconds: rule.flag))) or more as too long: "
                + "\"I have to keep telling you about these silences.\" Tighten it: \(tighten) (a dry run, then --apply), then check --cuts. "
                + "Keep it only for a beat something on screen needs, and say so with --reason."
            return CheckProblem(kind: .longPause, start: silence.start, end: silence.end, message: message, clipIDs: pause.clipIDs)
        }
    }
}
