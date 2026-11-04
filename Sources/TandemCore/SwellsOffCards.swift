import Foundation

extension QualityCheck {
    /// How far a card's swell can start from where the other cards' swells
    /// start in theirs before it's worth a note: a few frames.
    static let swellDrift = Time(seconds: 0.15)
    /// How far past its card a swell can run, as its release, before it's
    /// under whatever follows the card.
    static let swellOverrun = Time(seconds: 0.25)
    /// How close a swell has to be to a card with none under it to count as
    /// that card's, left beside it.
    static let swellReach = Time(seconds: 5)

    /// Music swells that no longer sit under the section card they were set
    /// for. Mike's cards each get the same swell, laid the same way in each
    /// card, so one that starts somewhere else in its card than the rest do
    /// has usually been left behind by an edit: in the Threadbear launch
    /// video his own delete left card 2's swell 0.44 s late and a cut left
    /// card 5's 1.4 s late. A swell running on past its card is under the
    /// words after it, and one just beside a card with no swell under it
    /// has missed it. Notes, as a swell can be off a card on purpose.
    public static func swellsOffCards(in project: Project, ranges: [TimeRange]) -> [CheckProblem] {
        let cards = project.videoTracks.filter { !$0.hidden }.flatMap { track in
            track.clips.filter { $0.enabled && SectionCard.isCard($0.content) }
        }.sorted { $0.start < $1.start }
        guard !cards.isEmpty else { return [] }
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let soloing = project.audioTracks.contains { $0.solo && !$0.muted }
        var swells: [(range: TimeRange, clipID: String)] = []
        var music: [TimeRange] = []
        for track in project.audioTracks where !track.muted && (!soloing || track.solo) {
            for clip in track.clips where clip.enabled && !(clip.audio?.muted ?? false) {
                guard let id = clip.mediaID, media[id]?.role == .music else { continue }
                music.append(clip.range)
                // Without the bed's arrival, which `swells(of:)` counts too.
                swells += keyedSwells(of: clip).map { ($0, clip.id) }
            }
        }
        func name(_ card: Clip) -> String {
            let title = SectionCard.props(of: card)?.title ?? ""
            return title.isEmpty ? "the section card at \(card.start)" : "the \"\(title)\" card at \(card.start)"
        }
        // Each card's swell: the first one overlapping it.
        let under = cards.map { card in swells.first { $0.range.overlaps(card.range) } }
        let offsets = zip(cards, under).compactMap { card, swell in swell.map { $0.range.start - card.start } }
        var found: [CheckProblem] = []
        for (index, card) in cards.enumerated() where ranges.contains(where: { $0.overlaps(card.range) }) {
            guard let swell = under[index] else {
                // Music under the card, but its swell is just beside it.
                guard music.contains(where: { $0.overlaps(card.range) }) else { continue }
                let near = swells.filter { swell in
                    let gap = swell.range.start >= card.end ? swell.range.start - card.end : card.start - swell.range.end
                    return gap >= .zero && gap <= swellReach && !cards.contains { $0.range.overlaps(swell.range) }
                }.min { distance($0.range, card.range) < distance($1.range, card.range) }
                guard let near else { continue }
                let side = near.range.start >= card.end ? "after it ends" : "before it starts"
                found.append(CheckProblem(
                    kind: .swellOffCard, start: card.start, end: card.end,
                    message: "Swell off its card: nothing swells under \(name(card)), and the music swells \(seconds(distance(near.range, card.range))) \(side). A cut may have left it behind: move its audio.gainDB keyframes back under the card.",
                    clipIDs: [near.clipID, card.id]
                ))
                continue
            }
            var problems: [String] = []
            // Against the other cards' swells, so one card's own odd
            // placement doesn't set the bar for itself.
            var others = offsets
            if let mine = others.firstIndex(of: swell.range.start - card.start) { others.remove(at: mine) }
            if others.count >= 2 {
                let usual = others.sorted()[others.count / 2]
                let offset = swell.range.start - card.start
                let drift = offset - usual
                if abs(drift.flicks) > swellDrift.flicks {
                    let way = drift > .zero ? "later" : "earlier"
                    problems.append("it swells \(seconds(Time(flicks: abs(drift.flicks)))) \(way) in its card than the other cards' swells do (\(seconds(offset)) in, against \(seconds(usual)))")
                }
            }
            if swell.range.end - card.end > swellOverrun {
                problems.append("it runs \(seconds(swell.range.end - card.end)) past the card's end, under what follows")
            }
            guard !problems.isEmpty else { continue }
            found.append(CheckProblem(
                kind: .swellOffCard, start: swell.range.start, end: swell.range.end,
                message: "Swell off its card: under \(name(card)), \(problems.joined(separator: ", and ")). A cut may have left it behind: move its audio.gainDB keyframes to match the other cards.",
                clipIDs: [swell.clipID, card.id]
            ))
        }
        return found
    }

    /// The swells `swells(of:)` finds from a clip's gain keyframes, without
    /// the bed coming in, which it always lists first.
    static func keyedSwells(of clip: Clip) -> [TimeRange] {
        Array(swells(of: clip).dropFirst())
    }

    private static func distance(_ a: TimeRange, _ b: TimeRange) -> Time {
        if a.start >= b.end { return a.start - b.end }
        if b.start >= a.end { return b.start - a.end }
        return .zero
    }
}
