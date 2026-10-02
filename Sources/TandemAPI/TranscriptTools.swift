import Foundation
import TandemCore
import TandemMedia

/// Transcript maths: mapping words from media time onto the timeline,
/// finding phrases, finding pauses and planning how to tighten them.
///
/// Transcripts are in media time (seconds into the file), with their word
/// edges pulled in to the voice when they're read (`TranscriptAlignment`).
/// A clip plays media from `sourceStart` at `speed`, so a word at media time
/// `m` plays at `clip.start + (m - sourceStart) / speed`, if the clip reaches
/// it. Which clip shows a word a cut runs through follows one rule,
/// `Transcript.placements(on:)`: the clip that plays most of it, and none
/// when less than half of it is left.
public enum TranscriptTools {
    public static let defaultMinimum = 0.6
    public static let defaultKeep = 0.15

    /// A word as it plays on the timeline.
    public struct SpokenWord: Equatable, Sendable {
        public var text: String
        public var start: Time
        public var end: Time
        public var clipID: String
        public var mediaID: String
        public var confidence: Double?
    }

    /// Everything said on the speech tracks, in timeline order.
    public struct SpeechMap: Sendable {
        public var words: [SpokenWord]
        /// Timeline ranges covered by speech clips with a transcript.
        public var covered: [TimeRange]
        /// Timeline ranges of speech clips whose transcript isn't ready, where
        /// nobody knows yet what's said.
        public var unknown: [TimeRange]
        /// Media IDs whose transcripts aren't ready.
        public var missing: [String]
        /// Speech clips with their track, for naming clips under a pause.
        public var clips: [Clip]
    }

    /// The tracks that carry dialogue: unmuted audio tracks that ripple as
    /// part of the take (Voice). Falls back to every unmuted audio track.
    public static func speechTracks(_ project: Project) -> [Track] {
        let audio = project.audioTracks.filter { !$0.muted }
        let take = audio.filter { $0.rippleMode == .cut }
        return take.isEmpty ? audio : take
    }

    public static func timelineTime(ofMediaTime media: Time, in clip: Clip) -> Time {
        clip.start + Time(seconds: (media - clip.sourceStart).seconds / clip.speed)
    }

    /// Whether a clip's sound is heard: enabled, not muted, not a freeze.
    static func isHeard(_ clip: Clip) -> Bool {
        clip.enabled && !(clip.audio?.muted ?? false) && !clip.freezeFrame
    }

    /// The words of `transcript` that `clips` play, in timeline order.
    /// `clips` are one track's clips of the transcript's file; a word shows
    /// once, on the clip that plays most of it, clamped to that clip, and not
    /// at all when less than half of it is left (`Transcript.placements(on:)`).
    public static func words(_ transcript: Transcript, playedBy clips: [Clip], mediaID: String) -> [SpokenWord] {
        transcript.placements(on: clips).map { placed in
            let word = transcript.words[placed.index]
            return SpokenWord(
                text: word.text, start: placed.start, end: placed.end,
                clipID: placed.clipID, mediaID: mediaID, confidence: word.confidence
            )
        }
    }

    /// The words one clip plays, placed among the clips of `track` that play
    /// the same file, so a word a cut runs through shows on one side only.
    public static func words(_ transcript: Transcript, playedBy clip: Clip, on track: Track) -> [SpokenWord] {
        guard let mediaID = clip.mediaID else { return [] }
        let siblings = track.clips.filter { $0.mediaID == mediaID && ($0.id == clip.id || isHeard($0)) }
        return words(transcript, playedBy: siblings, mediaID: mediaID).filter { $0.clipID == clip.id }
    }

    public static func speechMap(_ project: Project, analysis: AnalysisSource) -> SpeechMap {
        speechMap(project) { analysis.transcript(for: $0) }
    }

    public static func speechMap(_ project: Project, transcripts: (MediaItem) -> Transcript?) -> SpeechMap {
        var words: [SpokenWord] = []
        var covered: [TimeRange] = []
        var unknown: [TimeRange] = []
        var missing = Set<String>()
        var clips: [Clip] = []
        var cache: [String: Transcript?] = [:]
        for track in speechTracks(project) {
            // Each file's words are placed among all of its clips on the
            // track at once, so a cut between two of them shows a word once.
            var byMedia: [String: [Clip]] = [:]
            var order: [String] = []
            for clip in track.clips where isHeard(clip) {
                guard let mediaID = clip.mediaID, project.media(mediaID) != nil else { continue }
                clips.append(clip)
                if byMedia[mediaID] == nil { order.append(mediaID) }
                byMedia[mediaID, default: []].append(clip)
            }
            for mediaID in order {
                guard let item = project.media(mediaID), let group = byMedia[mediaID] else { continue }
                let transcript: Transcript?
                if let cached = cache[mediaID] {
                    transcript = cached
                } else {
                    transcript = transcripts(item)
                    cache[mediaID] = transcript
                }
                guard let transcript else {
                    missing.insert(mediaID)
                    unknown += group.map(\.range)
                    continue
                }
                covered += group.map(\.range)
                words += Self.words(transcript, playedBy: group, mediaID: mediaID)
            }
        }
        words.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        return SpeechMap(
            words: words,
            covered: TimeRange.union(covered),
            unknown: TimeRange.union(unknown),
            missing: missing.sorted(),
            clips: clips
        )
    }

    // MARK: - Pauses

    /// Silences between words of at least `minimum`, in timeline time. A gap
    /// only counts when speech clips with transcripts cover all of it: a hole
    /// in the take, or a clip whose transcript isn't ready, isn't a pause.
    public static func pauses(in map: SpeechMap, minimum: Time, from: Time? = nil, to: Time? = nil) -> [Pause] {
        var result: [Pause] = []
        var lastEnd: Time?
        for (index, word) in map.words.enumerated() {
            defer { lastEnd = max(lastEnd ?? word.end, word.end) }
            guard let previousEnd = lastEnd, word.start - previousEnd >= minimum else { continue }
            let gap = TimeRange(start: previousEnd, end: word.start)
            if let from, gap.start < from { continue }
            if let to, gap.end > to { continue }
            guard isCovered(gap, map) else { continue }
            let under = map.clips.filter { $0.range.overlaps(gap) }.map(\.id)
            result.append(Pause(
                start: gap.start,
                end: gap.end,
                duration: gap.duration,
                before: context(map.words, upTo: index),
                after: context(map.words, from: index),
                clipIDs: under
            ))
        }
        return result
    }

    static func isCovered(_ gap: TimeRange, _ map: SpeechMap) -> Bool {
        guard map.covered.contains(where: { $0.start <= gap.start && gap.end <= $0.end }) else { return false }
        return !map.unknown.contains { $0.overlaps(gap) }
    }

    static func context(_ words: [SpokenWord], upTo index: Int, count: Int = 4) -> String {
        words[max(0, index - count)..<index].map(\.text).joined(separator: " ")
    }

    static func context(_ words: [SpokenWord], from index: Int, count: Int = 4) -> String {
        words[index..<min(words.count, index + count)].map(\.text).joined(separator: " ")
    }

    // MARK: - Tightening

    /// Shortens each pause to `keep`, cutting from the middle so half the
    /// kept silence stays after the last word and half before the next one.
    /// Cut edges are rounded inwards to frame boundaries, so the kept
    /// silence is never shorter than `keep`. Pauses that would lose less
    /// than a frame are left alone.
    public static func plan(_ pauses: [Pause], keep: Time, frameRate: FrameRate) -> [PlannedCut] {
        let half = Time(flicks: keep.flicks / 2)
        let rest = keep - half
        return pauses.compactMap { pause in
            let start = TimeText.ceilToFrame(pause.start + half, frameRate)
            let end = TimeText.floorToFrame(pause.end - rest, frameRate)
            guard end - start >= frameRate.frameDuration else { return nil }
            return PlannedCut(pause: pause, cut: TimeRange(start: start, end: end))
        }
    }

    /// `rippleDeleteRange` commands for a plan, latest first so every range
    /// is still in the current timeline's times when it runs.
    public static func commands(for cuts: [PlannedCut]) -> [EditCommand] {
        cuts.sorted { $0.cut.start > $1.cut.start }.map { .rippleDeleteRange(range: $0.cut, trackIDs: nil) }
    }

    // MARK: - Section cuts

    /// Silence a section card's room keeps beside the words either side of
    /// it, when the pause has it (`sectionCut`). A voice starts a little
    /// before it's loud enough to find, so a cut right on a word's start
    /// leaves its first sound on the other side of the room.
    public static let sectionLead = Time(seconds: 0.2)
    /// A cut already in the take is used for the room if it's at least
    /// this far from the words either side, or the voice doesn't play on
    /// across it.
    static let cutMargin = Time(seconds: 0.05)
    /// A piece of a clip shorter than this, cut off beside a card's room,
    /// is a sliver: a flash of a shot under the wipe.
    static let sliver = Time(seconds: 0.25)

    /// Where `cards --insert` cuts the take for a section card's room.
    public struct SectionCut: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// The marker is clear of the words, so the cut is on it: on its
            /// nearest frame, or on a cut already in the take beside it so
            /// no sliver of a clip is left by the room.
            case clear
            /// The marker is on `word` (`on`), or so close to it that a cut
            /// there could clip it, so the cut moved into the pause beside it.
            case movedOff(word: SpokenWord, on: Bool)
            /// The marker is inside `word` with no pause it may move to, so
            /// the cut stays on it.
            case inSpeech(word: SpokenWord)
            /// Speech around the marker has no transcript yet, so nobody
            /// knows what a cut there would clip, and it stays on the marker.
            case untranscribed(mediaIDs: [String])
        }

        public var time: Time
        public var reason: Reason
    }

    /// Where to cut the take for a section card's room at `marker`: in the
    /// pause before the section's first word, not through it.
    ///
    /// Agents put section markers on the first word, where its transcript
    /// starts it, and room made right there left the word's first sound
    /// before the room and the rest after it (Mike heard "Now" clipped). So
    /// the cut goes in the pause beside the word the marker is on or near:
    /// the one before it, or after it when the marker is in the word's
    /// second half. It keeps `sectionLead` of silence beside each word, or
    /// half the pause when that's shorter, and lands on a frame. Word edges
    /// come from the voice (`speechMap`), as they do for `pauses`. When that
    /// would leave a sliver of a clip beside the room (a tightened pause,
    /// with its cut in the middle), a cut already in the pause is used, so
    /// the take isn't cut again. The cut moves at most `reach` from the
    /// marker (`SectionCard.Placement.cutReach`), so its card still covers it.
    public static func sectionCut(at marker: Time, in map: SpeechMap, project: Project, reach: Time = SectionCard.maxCutShift) -> SectionCut {
        let around = TimeRange(start: marker - reach, end: marker + reach)
        if map.unknown.contains(where: { $0.overlaps(around) }) {
            let media = map.clips.filter { $0.range.overlaps(around) }.compactMap(\.mediaID).filter(map.missing.contains)
            return SectionCut(time: marker, reason: .untranscribed(mediaIDs: Set(media).sorted()))
        }
        let words = map.words
        // The word the marker is on, or the first one after it.
        let index = words.firstIndex { $0.end > marker }
        let on = index.map { words[$0] }.flatMap { $0.start <= marker ? $0 : nil }
        // The pause the cut goes in: from the end of `before` to the start
        // of `after`. No word on a side leaves that side open.
        var before: SpokenWord?
        var after: SpokenWord?
        if let index, let on, marker - on.start > on.end - marker {
            before = on
            after = index + 1 < words.count ? words[index + 1] : nil
        } else {
            before = words[..<(index ?? words.count)].max { $0.end < $1.end }
            after = index.map { words[$0] }
        }
        let high = after?.start
        let low = before.map { word in min(word.end, high ?? word.end) }
        let half = low.flatMap { low in high.map { Time(flicks: ($0 - low).flicks / 2) } }
        let lead = min(sectionLead, half ?? sectionLead)
        var ideal = marker
        if let high, ideal > high - lead { ideal = high - lead }
        if let low, ideal < low + lead { ideal = low + lead }
        ideal = max(ideal, .zero)
        func inPause(_ time: Time) -> Bool {
            time >= .zero && (low.map { time >= $0 } ?? true) && (high.map { time <= $0 } ?? true)
        }
        // Only as far as `reach`, and not at all when that's still inside a word.
        var target = ideal
        if abs((target - marker).flicks) > reach.flicks {
            target = target < marker ? marker - reach : marker + reach
            guard inPause(target) else {
                return SectionCut(time: marker, reason: on.map { .inSpeech(word: $0) } ?? .clear)
            }
        }
        func fits(_ time: Time) -> Bool {
            inPause(time) && abs((time - marker).flicks) <= reach.flicks
        }
        let rate = project.settings.frameRate
        let down = Time.frames(target.frameIndex(at: rate), at: rate)
        let up = down == target ? down : down + rate.frameDuration
        var cut = [down, up].sorted { abs(($0 - target).flicks) < abs(($1 - target).flicks) }.first(where: fits) ?? target

        // A cut beside one already in the take would leave a sliver of a
        // clip next to the room: make the room at that cut instead, if it's
        // clear of the words or the voice doesn't play on across it (or
        // it's within a frame of here, as good a place).
        let take = project.allTracks.filter { $0.rippleMode == .cut && !$0.locked }
        func leavesSliver(_ time: Time) -> Bool {
            take.contains { track in
                track.clips.contains { $0.start < time && time < $0.end && min(time - $0.start, $0.end - time) < sliver }
            }
        }
        if leavesSliver(cut) {
            let margin = min(cutMargin, half ?? cutMargin)
            let edges = Set(take.flatMap { $0.clips.flatMap { [$0.start, $0.end] } })
            let usable = edges.filter { edge in
                guard fits(edge), !leavesSliver(edge) else { return false }
                if abs((edge - cut).flicks) < rate.flicksPerFrame { return true }
                let clear = (low.map { edge - $0 >= margin } ?? true) && (high.map { $0 - edge >= margin } ?? true)
                return clear || voiceBreaks(at: edge, in: project)
            }
            if let nearest = usable.min(by: { abs(($0 - cut).flicks) < abs(($1 - cut).flicks) }) { cut = nearest }
        }

        // Said only when the marker was too close to a word and the cut
        // moved off it by a frame or more.
        if abs((cut - marker).flicks) >= rate.flicksPerFrame, let word = ideal < marker ? after : ideal > marker ? before : nil {
            return SectionCut(time: cut, reason: .movedOff(word: word, on: word.start <= marker && marker < word.end))
        }
        return SectionCut(time: cut, reason: .clear)
    }

    /// Whether the voice already breaks at `time`: no speech clip plays on
    /// across it, because the take jumps in its file there or stops. Room
    /// made there can't split a sound that was playing.
    static func voiceBreaks(at time: Time, in project: Project) -> Bool {
        let tolerance = project.settings.frameRate.flicksPerFrame / 2
        for track in speechTracks(project) {
            let heard = track.clips.filter(isHeard)
            if heard.contains(where: { $0.start < time && time < $0.end }) { return false }
            guard let left = heard.first(where: { $0.end == time }), let right = heard.first(where: { $0.start == time }) else { continue }
            if left.mediaID == right.mediaID, left.speed == right.speed, abs((right.sourceStart - left.sourceEnd).flicks) <= tolerance {
                return false
            }
        }
        return true
    }

    // MARK: - Search

    /// Lower-case words with punctuation removed, so "Don't," matches "dont".
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// Where `phrase` occurs in a transcript: ranges of word indices.
    public static func matches(of phrase: String, in transcript: Transcript) -> [ClosedRange<Int>] {
        let wanted = tokens(phrase)
        guard !wanted.isEmpty else { return [] }
        var stream: [(token: String, word: Int)] = []
        for (index, word) in transcript.words.enumerated() {
            for token in tokens(word.text) { stream.append((token, index)) }
        }
        guard stream.count >= wanted.count else { return [] }
        var result: [ClosedRange<Int>] = []
        var i = 0
        while i <= stream.count - wanted.count {
            if (0..<wanted.count).allSatisfy({ stream[i + $0].token == wanted[$0] }) {
                let range = stream[i].word...stream[i + wanted.count - 1].word
                if result.last != range { result.append(range) }
                i += wanted.count
            } else {
                i += 1
            }
        }
        return result
    }

    public static func search(
        _ phrase: String,
        in project: Project,
        analysis: AnalysisSource
    ) -> (hits: [SearchHit], unused: [UnusedHit], missing: [String]) {
        var hits: [SearchHit] = []
        var unused: [UnusedHit] = []
        var missing: [String] = []
        let speechMedia = Set(speechTracks(project).flatMap(\.clips).compactMap(\.mediaID))
        for item in project.media where item.hasAudio {
            guard let transcript = analysis.transcript(for: item) else {
                if speechMedia.contains(item.id) { missing.append(item.id) }
                continue
            }
            let found = matches(of: phrase, in: transcript)
            guard !found.isEmpty else { continue }
            // Where each word plays, track by track (the camera picture and
            // its sound both play it), by the same rule as everything else.
            var placed: [Int: [PlacedWord]] = [:]
            var rank: [String: Int] = [:]
            for track in project.allTracks {
                let clips = track.clips.filter { $0.mediaID == item.id }
                for clip in clips { rank[clip.id] = rank.count }
                for word in transcript.placements(on: clips) { placed[word.index, default: []].append(word) }
            }
            let words = transcript.words
            for match in found {
                let mediaStart = words[match.lowerBound].start
                let mediaEnd = words[match.upperBound].end
                let text = words[match].map(\.text).joined(separator: " ")
                let before = words[max(0, match.lowerBound - 4)..<match.lowerBound].map(\.text).joined(separator: " ")
                let after = words[(match.upperBound + 1)..<min(words.count, match.upperBound + 5)].map(\.text).joined(separator: " ")
                // The phrase's words on each clip: a cut through the phrase
                // leaves part of it on each side, each marked partial.
                var byClip: [String: (start: Time, end: Time, count: Int)] = [:]
                for index in match {
                    for word in placed[index] ?? [] {
                        if let entry = byClip[word.clipID] {
                            byClip[word.clipID] = (min(entry.start, word.start), max(entry.end, word.end), entry.count + 1)
                        } else {
                            byClip[word.clipID] = (word.start, word.end, 1)
                        }
                    }
                }
                if byClip.isEmpty {
                    unused.append(UnusedHit(
                        mediaID: item.id, path: item.path, text: text,
                        mediaStart: mediaStart, mediaEnd: mediaEnd, before: before, after: after
                    ))
                }
                var byRange: [TimeRange: (clipIDs: [String], partial: Bool)] = [:]
                for clipID in byClip.keys.sorted(by: { rank[$0, default: 0] < rank[$1, default: 0] }) {
                    let entry = byClip[clipID]!
                    let range = TimeRange(start: entry.start, end: entry.end)
                    var hit = byRange[range] ?? ([], false)
                    hit.clipIDs.append(clipID)
                    hit.partial = hit.partial || entry.count < match.count
                    byRange[range] = hit
                }
                for (range, entry) in byRange {
                    hits.append(SearchHit(
                        text: text, start: range.start, end: range.end, clipIDs: entry.clipIDs,
                        mediaID: item.id, mediaStart: mediaStart, mediaEnd: mediaEnd,
                        partial: entry.partial, before: before, after: after
                    ))
                }
            }
        }
        hits.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        unused.sort { ($0.mediaID, $0.mediaStart) < ($1.mediaID, $1.mediaStart) }
        return (hits, unused, missing.sorted())
    }
}
