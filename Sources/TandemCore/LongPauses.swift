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

extension QualityCheck {
    /// Longer than this, a gap is a beat for something on screen or a
    /// change of section, which dead air and the section cards cover.
    public static let longPauseLongest = Time(seconds: 4)
    /// The most a check lists.
    static let longPausesListed = 40

    /// Notes for pauses in `ranges` whose silence is at least `taste`'s
    /// flag for their kind, with the `tighten` that takes each to what
    /// Mike leaves. A pause the mid-sentence note already has is left to
    /// it, and so is a conversation, where a gap is often the other
    /// person's turn.
    public static func longPauses(_ pauses: [HeardPause], taste: PauseTaste, in project: Project, ranges: [TimeRange], speech: Speech) -> [CheckProblem] {
        guard !isConversation(project, speech: speech) else { return [] }
        let flagged = Set(midSentencePauses(pauses, in: project, ranges: ranges, speech: speech).map(\.start))
        let rules = Dictionary(uniqueKeysWithValues: taste.rules.map { ($0.kind, $0) })
        let found = pauses.filter { pause in
            guard let silence = pause.silence, let rule = rules[SpokenPause.kind(before: pause.before, next: pause.after)] else { return false }
            return silence.duration.seconds >= rule.flag - 1e-9 && silence.duration <= longPauseLongest
                && ranges.contains { $0.overlaps(pause.range) } && !flagged.contains(pause.range.start)
        }.sorted { $0.range.start < $1.range.start }

        func keep(_ kind: SpokenPause.Kind) -> String { String(format: "%.2f", rules[kind]?.leave ?? 0.35) }
        return found.prefix(longPausesListed).map { pause in
            let kind = SpokenPause.kind(before: pause.before, next: pause.after)
            let rule = rules[kind]!
            let silence = pause.silence!
            let from = max(.zero, pause.range.start - Time(seconds: 0.5)), to = pause.range.end + Time(seconds: 0.5)
            let what: String
            switch kind {
            case .sentence: what = "after a sentence"
            case .comma: what = "after a comma"
            case .mid: what = "mid-sentence"
            }
            let source = rule.learned ? "the middle of \(rule.trims) of his own trims" : "his usual, until he's trimmed \(PauseTaste.fewest) of these"
            let tighten = "tandem tighten --from \(from) --to \(to) --sentence \(keep(.sentence)) --comma \(keep(.comma)) --mid \(keep(.mid)) --min 0.2 --mid-min 0.15"
            let message = "Long pause: \"...\(pause.before) [\(seconds(silence.duration)) of silence] \(pause.after)...\", \(what). "
                + "Mike leaves \(seconds(Time(seconds: rule.leave))) there (\(source)) and hears \(seconds(Time(seconds: rule.flag))) or more as too long: "
                + "\"I have to keep telling you about these silences.\" Tighten it: \(tighten) (a dry run, then --apply), then check --cuts. "
                + "Keep it only for a beat something on screen needs, and say so with --reason."
            return CheckProblem(kind: .longPause, start: silence.start, end: silence.end, message: message, clipIDs: pause.clipIDs)
        }
    }
}
