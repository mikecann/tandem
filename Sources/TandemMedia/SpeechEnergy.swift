import Accelerate
import AVFoundation
import Foundation

/// How loud a stretch of a file's sound is, in 5 ms frames: RMS in dB over
/// the full band, again above 4 kHz, and above 300 Hz.
///
/// The high band is there for the ends of words: a final "s" or "t" hardly
/// registers below 4 kHz, so a cut that only looks at the full band (or at
/// the cached waveform's peaks) can land after "take" and before its "s".
/// Agents who checked their own cuts (about 15 times, with ffmpeg RMS
/// envelopes) found the same: the cuts Mike heard clipped were the ones the
/// full band called quiet and the high band didn't.
public struct SpeechEnergy: Sendable {
    /// 5 ms, as the pause search that worked on the Ian video used (#64):
    /// a 25 ms join is five frames, and a pause is placed to within one.
    public static let frameSeconds = 0.005
    /// Where the high band starts.
    public static let highBand = 4000.0
    /// Where the voice band starts: under it is a room's rumble, a fan or
    /// a foot tapping, and little of a voice (`FaintSound`).
    public static let voiceBand = 300.0
    /// What a file is read at: high enough to keep an "s" (up to 16 kHz).
    static let readRate = 32_000.0

    /// Media time of the first frame.
    public var start: Double
    /// dB per frame, full band and above `highBand`.
    public var full: [Float]
    public var high: [Float]
    /// Above `voiceBand`. The full band where it wasn't measured.
    public var voice: [Float]

    public init(start: Double, full: [Float], high: [Float], voice: [Float]? = nil) {
        self.start = start
        self.full = full
        self.high = high
        self.voice = voice ?? full
    }

    /// Frames of mono `samples` starting at media time `start`.
    public init(samples: [Float], sampleRate: Double, start: Double) {
        self.start = start
        let perFrame = max(1, Int((sampleRate * Self.frameSeconds).rounded()))
        let count = samples.count / perFrame
        let highPassed = Self.highBand < sampleRate * 0.45 ? Self.highPass(samples, sampleRate: sampleRate) : nil
        let voicePassed = Self.highPass(samples, sampleRate: sampleRate, from: Self.voiceBand)
        func levels(_ values: [Float]) -> [Float] {
            values.withUnsafeBufferPointer { buffer in
                (0..<count).map { frame in
                    var rms: Float = 0
                    vDSP_rmsqv(buffer.baseAddress! + frame * perFrame, 1, &rms, vDSP_Length(perFrame))
                    return rms > 1e-6 ? 20 * log10(rms) : -120
                }
            }
        }
        full = levels(samples)
        high = highPassed.map(levels) ?? [Float](repeating: -120, count: count)
        voice = levels(voicePassed)
    }

    /// Media time just past the last frame.
    public var end: Double { start + Double(full.count) * Self.frameSeconds }

    /// The frame holding media time `time` (may be outside the frames).
    public func index(of time: Double) -> Int {
        Int(((time - start) / Self.frameSeconds + 1e-6).rounded(.down))
    }

    /// Two second-order Butterworth high-passes at `cutoff` (`highBand`
    /// unless said), one after the other (what
    /// `highpass=f=4000,highpass=f=4000` does in ffmpeg), so the voice's
    /// harmonics under 4 kHz don't leak into the high band.
    static func highPass(_ samples: [Float], sampleRate: Double, from cutoff: Double = highBand) -> [Float] {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.5.squareRoot())
        let a0 = 1 + alpha
        let b0 = (1 + cos(w0)) / 2 / a0
        let b1 = -(1 + cos(w0)) / a0
        let b2 = b0
        let a1 = -2 * cos(w0) / a0
        let a2 = (1 - alpha) / a0
        var out = samples
        for _ in 0..<2 {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in out.indices {
                let x = Double(out[i])
                let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1
                x1 = x
                y2 = y1
                y1 = y
                out[i] = Float(y)
            }
        }
        return out
    }

    /// The file's sound from `from` to `to` (media time, as AVFoundation
    /// reads it), mixed to mono. Stops early at the end of the file.
    public static func read(url: URL, from: Double, to: Double) async throws -> SpeechEnergy {
        let start = max(0, from)
        guard to > start else { return SpeechEnergy(start: start, full: [], high: []) }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), end: CMTime(seconds: to, preferredTimescale: 48_000))
        let reader = try await AudioReader(url: url, sampleRate: readRate, channels: 1, timeRange: range)
        let samples = try await Blocking.run(qos: .userInitiated) {
            var samples = [Float](repeating: 0, count: Int(((to - start) * readRate).rounded()))
            var reached = 0
            while try reader.next({ chunk, frames, stamp in
                // Placed by time stamp, like the waveform, so a file whose
                // sound starts late still lines up with media time.
                var position = Int(((stamp.seconds - start) * readRate).rounded())
                var offset = 0
                if position < 0 {
                    offset = min(frames, -position)
                    position += offset
                }
                let count = min(frames - offset, samples.count - position)
                guard count > 0 else { return }
                for i in 0..<count { samples[position + i] = chunk[offset + i] }
                reached = max(reached, position + count)
            }) {}
            return Array(samples.prefix(reached))
        }
        return SpeechEnergy(samples: samples, sampleRate: readRate, start: start)
    }
}

/// What a take's voice is like, from the frames read around its cuts:
/// how loud its loud tenth is above 4 kHz, and whether there's a voice at
/// all. What's quiet is worked out at each edge instead
/// (`CutPlacer.around`), from the sound either side of it.
public struct SpeechLevels: Equatable, Sendable {
    /// The loud tenth above 4 kHz: a "k" or "t" released after its closure
    /// gets near it.
    public var highLoud: Float
    /// Speech above 4 kHz, where an "s" sits, is at or over this: within
    /// 10 dB of the loud tenth.
    public var highSpeech: Float
    /// A take whose loud tenth is this quiet carries no voice (a screen
    /// recording's system sound, mostly digital silence), so its cuts
    /// aren't judged.
    public var isVoice: Bool

    static let highSpeechUnderLoud: Float = 10
    static let quietestVoice: Float = -60

    public init(highLoud: Float, isVoice: Bool = true) {
        self.highLoud = highLoud
        highSpeech = highLoud - Self.highSpeechUnderLoud
        self.isVoice = isVoice
    }

    /// Levels from every frame read of one take.
    public init(of readings: [SpeechEnergy]) {
        func loud(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return sorted.isEmpty ? -120 : sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
        }
        self.init(highLoud: loud(readings.flatMap(\.high)), isVoice: loud(readings.flatMap(\.full)) > Self.quietestVoice)
    }
}

/// Whether a cut clips a word, judged from the file's own sound. The
/// transcript's times are 30 to 100 ms off (sometimes 0.2 s, and Bark's
/// starts after a short gap about 110 ms late), so they never place
/// anything: they only say whether a word boundary can be where the sound
/// has a gap.
///
/// An edge in a real pause is clean: quiet for `minPause` or more in the
/// full band and above 4 kHz alike, where quiet is `overFloor` over the
/// quietest tenth of the sound `around` either side (`highOverFloor` above
/// 4 kHz). So is one in a shorter quiet gap of `minWordGap` or more with a
/// transcript word boundary by it (`boundaries`): a gap between words.
/// Other short gaps are inside words (the closure before the "t" of
/// "extract"), and without a transcript every one is.
///
/// Any other edge is in sound, and two things say how it sounds:
/// - voice at speech level (`runOnUnder`) past the edge, in the material
///   cut away, before a pause or a gap between words: the rest of the word,
///   or (with no transcript to say otherwise) the next word of fluent
///   speech, so it's clipped however quiet the clip's own side is.
///   That's the "t" released after the closure an edge is in, and the
///   "pro" of "processed" left before a clip that started on the
///   transcript's time for it;
/// - otherwise, how far under the speech level the clip's own 25 ms beside
///   the edge is (`CutPlacer.score`). On the Ian video (October 2026, #64)
///   the cut-offs Mike heard in his second review were within about 3 dB
///   of the speech, and the clean joins 15 dB or more under it, so under
///   `clippedUnder` is clipped and under `cleanFrom` marginal.
///
/// On the Ian video's 124 labelled cut edges (`CutScorecardTests`), a
/// take-wide quiet level, and a quiet clip's side counting as clean, passed
/// 37 of the 64 clipped edges; these rules pass 9, call 5 marginal, and
/// flag 4 of the 25 clean ones (two of them joins the edit kept at 6 to
/// 7 dB under the speech, which any level check flags).
///
/// A clip that ends just before the last word of its sentence, with that
/// word cut (`lastWordCut`), is clipped too, however clean it sounds.
///
/// With the Ian video's Bark transcripts, aligned as Tandem reads them, its
/// final cut's 290 joins Mike approved went from 25 flagged to 9 (the gap
/// between words, and voice past it being the next word's), and the edges
/// he heard clipped stayed caught.
///
/// A clipped edge's fix moves it into a real pause or a gap between words
/// (`CutPlacer`): on past the cut-off sound into the cut material,
/// finishing the word the edge is in, unless that would bring another cut
/// word back, or back into what the clip keeps, unless that would drop a
/// kept word. With neither, a cut of `putBackLimit` or less is better put
/// back whole, filler and all, which is what sounded right on the Ian
/// video.
public enum CutAudit {
    /// The quiet a real pause lasts. #64 measured 70 ms on the Ian video,
    /// but closures inside words there ran to 95 ms; 80 ms catches most of
    /// them and still passes the pauses Mike kept (fitted to its 124 edges).
    public static let minPause = 0.08
    /// Quiet is this many dB over the floor (#64, measured on the raw mic).
    public static let overFloor: Float = 9
    /// And this many over the floor above 4 kHz, where breath and mouth
    /// noise reach well over floor + 9 in a pause, and an "s" on Ian's mic
    /// 40 dB over it. 30 would pass one more of the Ian video's clean edges
    /// but miss three more clipped ones, and the higher it is, the more a
    /// soft "s" after the edge counts as a pause (a guess between the two).
    public static let highOverFloor: Float = 20
    /// The floor is the quietest tenth of the sound this far either side of
    /// the edge (#64's pause search took it over the 4 s past the join).
    public static let around = 3.0
    public static let floorPercentile = 0.1
    /// How far an edge may move to reach a pause, and how far past it voice
    /// counts as cut off. The fixes that worked on the Ian video moved edges
    /// up to half a second (fitted: 0.3 s reached too few of them, and 1.5 s
    /// went to pauses past the one that worked).
    public static let reach = 0.5
    /// How far into the pause a moved edge goes, so the word's tail (or the
    /// breath before the next one) isn't right on the cut (#64, measured).
    public static let pad = 0.03
    /// How far before its word the start of a clip goes when it moves back
    /// into the pause before it. The end of the quiet before a word is often
    /// its "p" or "t" bursting, not its start: "processed" started at
    /// 647.60 on Ian's mic, 60 ms before its "p" did.
    public static let lead = 0.08
    /// Voice past the edge at least this long, at speech level, is cut off.
    public static let minSpeech = 0.02
    /// Speech level for that is within this many dB of the speech level in
    /// the full band (or at `SpeechLevels.highSpeech` above 4 kHz). A guess,
    /// from #64's "fix anything within about 10 dB of speech".
    public static let runOnUnder: Float = 10
    /// The clip's 25 ms beside the edge, this many dB or less under the
    /// speech level, is clipped. Between Mike's cut-offs (about 3) and the
    /// clean joins (15 or more); the line itself is a guess.
    public static let clippedUnder: Float = 9
    /// And this many dB or more under it is a clean join (#64, measured).
    public static let cleanFrom: Float = 15
    /// How much of the clip beside the edge the join's level is taken over.
    public static let keptSpan = 0.025
    /// The speech level is the loud end (`speechPercentile` of 5 ms frames)
    /// of the sound `around` either side of the edge.
    public static let speechPercentile = 0.92
    /// A cut this long or shorter, with no pause to move to, is put back.
    public static let putBackLimit = 2.0
    /// A transcript word is in a stretch with more than this much of it
    /// inside (or half of a shorter word): its times can be off by this
    /// much without it counting.
    public static let wordTolerance = 0.05
    /// A quiet gap this long or longer, shorter than a pause, is a gap
    /// between words when the transcript has a word boundary by it (see
    /// `boundary`). Shorter quiet is flicker inside a syllable.
    public static let minWordGap = 0.025
    /// How far a word boundary can be from the gap in the sound and still
    /// be that gap: a gap between words lies after the earlier word ends,
    /// less `endSlack`, and before the later one starts, plus `startSlack`.
    /// Bark 3.0's word ends land within about 30 ms of the sound on Ian's
    /// mic, and its starts after a short gap about 110 ms late (October
    /// 2026), so a late start needs no slack of its own: the gap is still
    /// after the earlier word's end. Its times move in 80 ms steps.
    public static let endSlack = 0.05
    public static let startSlack = 0.05
    /// A sentence's last word starting this soon after the end of a clip,
    /// or this little before it, is the next word (`lastWordCut`).
    public static let lastWordReach = 0.15
    static let lastWordLead = 0.02
    /// Clause-ending words that are fillers Mike cuts ("you know,", "like.").
    static let fillers: Set<String> = ["like", "know", "um", "uh"]

    /// A transcript word near an edge, in media time.
    public struct Word: Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }

        var range: ClosedRange<Double> { start...max(start, end) }
    }

    /// Where the gap between two neighbouring words can be in the sound,
    /// given how far the transcript's times can be off. Only between two
    /// words: before the first one given, or after the last, a word may be
    /// missing rather than not there.
    static func boundaries(_ words: [Word]) -> [ClosedRange<Double>] {
        let sorted = words.sorted { $0.start < $1.start }
        return zip(sorted, sorted.dropFirst()).map { a, b in
            (min(a.end, b.start) - endSlack)...(max(a.end, b.start) + startSlack)
        }
    }

    /// The last word of a sentence or clause, cut whole, starting right
    /// after a clip that ends just before it: the sentence is left hanging
    /// however clean the join sounds. On the Ian video "a couple of lies
    /// about [time.]" ended in the 55 ms gap between "about" and the "t" of
    /// "time", and Mike heard it cut off; on its final cut this matched
    /// that edge and five an agent fixed, and none of the 290 joins Mike
    /// approved once "like" and "know" fillers are left out.
    ///
    /// `cutAway` is the stretch of the file past the edge that nothing
    /// plays next. The word has to be all inside it: with no such stretch,
    /// the next clip may play the word (two clips of a take meeting at
    /// different speeds aren't a through-edit), and finishing it would play
    /// it twice.
    static func lastWordCut(_ words: [Word], at time: Double, cutAway: ClosedRange<Double>?) -> Word? {
        guard let cutAway else { return nil }
        let sorted = words.sorted { $0.start < $1.start }
        // A word starting a frame or so before the edge is still after it:
        // its first sound is past the edge, or the edge is mid-word anyway.
        guard let next = sorted.firstIndex(where: { $0.start >= time - lastWordLead }), next > 0 else { return nil }
        let kept = sorted[next - 1], word = sorted[next]
        guard word.start - time <= lastWordReach, endsClause(word.text), !endsClause(kept.text) else { return nil }
        guard !fillers.contains(word.text.lowercased().filter(\.isLetter)) else { return nil }
        guard cutAway.lowerBound <= max(time, word.start) + 1e-6, word.end + endSlack <= cutAway.upperBound else { return nil }
        return word
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!".contains(last)
    }

    static func endsClause(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!,;:".contains(last)
    }

    /// Words a sentence or clause often opens with that Mike cuts on their
    /// own ("So", "And", "Yeah,"), so losing one, or a clip opening on one,
    /// isn't a sentence cut short.
    static let openers: Set<String> = [
        "so", "and", "but", "or", "yeah", "yes", "no", "okay", "ok", "right", "well", "now", "oh", "um", "uh", "like", "sure", "cool", "anyway", "then",
    ]

    static func bare(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0 == "'" } }

    /// The mirror of `lastWordCut`: the first word of a sentence or clause,
    /// cut whole, ending right before a clip that starts just after it. On
    /// the Ian video the clip starting at 1298.325 dropped "It's" (1298.17
    /// to 1298.36) from "start TS. [It's] like the time", and the fix moved
    /// it back to 1298.173. The word follows one that ends a sentence or
    /// clause, doesn't end one itself, and isn't an opener Mike cuts.
    ///
    /// `cutAway` is the stretch of the file before the edge that nothing
    /// plays: the word has to be all inside it, so the clip before doesn't
    /// play it.
    static func firstWordCut(_ words: [Word], at time: Double, cutAway: ClosedRange<Double>?) -> Word? {
        guard let cutAway else { return nil }
        let sorted = words.sorted { $0.start < $1.start }
        // Most of the word before the edge is cut: "It's" was 1298.14 to
        // 1298.42 in the aligned transcript, against the edge at 1298.325.
        guard let index = sorted.lastIndex(where: { ($0.start + $0.end) / 2 <= time }), index > 0 else { return nil }
        let before = sorted[index - 1], word = sorted[index]
        // A comma isn't enough here: "when you, [if] you were to" was a
        // false start Mike kept cut.
        guard time - word.end <= lastWordReach, endsSentence(before.text), !endsClause(word.text) else { return nil }
        guard !openers.contains(bare(word.text)), !fillers.contains(bare(word.text)) else { return nil }
        guard word.start - startSlack >= cutAway.lowerBound, min(time, word.end) <= cutAway.upperBound + 1e-6 else { return nil }
        return word
    }

    /// A clip that opens on the last word of the sentence the cut before it
    /// takes: a short word ending a sentence or clause, starting just after
    /// the edge, after a cut word that doesn't end one, and before a kept
    /// word. On the Ian video the clip starting at 157.47 opened on "do,"
    /// (157.53 to 157.67), the end of "I've not seen other places do,",
    /// and read "filled out, do, but I want to start off"; the fix started
    /// it in the gap after "do," (157.715). An opener ("Yeah,", "So,")
    /// isn't one.
    static func fragment(_ words: [Word], at time: Double, cutAway: ClosedRange<Double>?) -> Word? {
        guard let cutAway else { return nil }
        let sorted = words.sorted { $0.start < $1.start }
        // Most of the word after the edge: "do," was 157.41 to 157.69 in
        // the aligned transcript, against the edge at 157.47.
        guard let index = sorted.firstIndex(where: { ($0.start + $0.end) / 2 > time }), index > 0, index + 1 < sorted.count else { return nil }
        let cut = sorted[index - 1], word = sorted[index]
        guard word.start - time <= lastWordReach, endsClause(word.text), !endsClause(cut.text) else { return nil }
        let letters = bare(word.text).filter(\.isLetter)
        guard (1...fragmentLetters).contains(letters.count), !openers.contains(bare(word.text)), !fillers.contains(letters) else { return nil }
        guard cut.start - startSlack >= cutAway.lowerBound, cut.end <= cutAway.upperBound + endSlack else { return nil }
        return word
    }

    /// The longest word `fragment` takes for a leftover: "do,", "it.",
    /// "too." (a guess; longer words left over read as a choice).
    static let fragmentLetters = 4

    static let determiners: Set<String> = ["the", "a", "an", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her", "its"]

    /// Fillers a cut aims at, which take a word with them when it runs
    /// straight into one.
    static let cutFillers: Set<String> = ["like", "um", "uh", "uhm", "erm", "er", "ah", "mm", "hmm"]

    /// A cut that takes a filler and the "the" (or another determiner)
    /// before it, and nothing else: the word was meant to stay. On the Ian
    /// video the cut from 611.81 to 614.33 took "the like" from "And [the,
    /// like,] challenge there", where "the" runs straight into "like"; the
    /// fix kept both (612.67). A cut that goes on through the word again
    /// ("the, like, the") is a false start, cut whole on purpose.
    ///
    /// `words` have to reach past the end of `removed` (a word after it),
    /// or a long cut looks like only the words near the edge: a 9 s cut
    /// from "the like" on through a false start would read as "the like"
    /// alone, and the fix would bring the false start back.
    static func wordBeforeFiller(_ words: [Word], at time: Double, removed: ClosedRange<Double>?) -> Word? {
        guard let removed else { return nil }
        let sorted = words.sorted { $0.start < $1.start }
        guard sorted.contains(where: { $0.end > removed.upperBound + endSlack }) else { return nil }
        let inside = sorted.filter { $0.start >= removed.lowerBound - lastWordLead && $0.end <= removed.upperBound + endSlack }
        guard inside.count >= 2, let index = sorted.firstIndex(of: inside[0]), index > 0 else { return nil }
        let kept = sorted[index - 1], word = inside[0]
        // Only a word the rest of the sentence needs: on the Ian video's
        // final cut, cuts of "is um", "of like." and "gets like" before a
        // word that carries on were all fine.
        guard !endsClause(kept.text), determiners.contains(bare(word.text)) else { return nil }
        guard inside.dropFirst().allSatisfy({ cutFillers.contains(bare($0.text)) }) else { return nil }
        return word
    }


    /// Which side of the edge the clip plays: `before` for a clip's end
    /// (it plays up to the edge), `after` for a clip's start.
    public enum Side: Sendable {
        case before, after
    }

    public enum Verdict: String, Codable, Sendable {
        case clean
        /// Not clean, not clipped: worth a listen, but it doesn't fail.
        case marginal
        case clipped
    }

    /// What to do about a clipped edge.
    public enum Fix: Equatable, Sendable {
        /// Move the edge here (media time), into a real pause.
        case trim(to: Double)
        /// No pause to move to without bringing a cut word back or dropping
        /// a kept one: put the cut back.
        case putBack
        /// Neither: a person has to listen and recut it.
        case nothingNearby
    }

    public struct Edge: Equatable, Sendable {
        public var verdict: Verdict
        public var clipped: Bool { verdict == .clipped }
        /// How far the clip's 25 ms beside the edge is under the speech
        /// level, in dB. Nil for an edge in a pause.
        public var margin: Float?
        /// Seconds of voice on the kept side running up to the edge.
        public var kept: Double
        /// Seconds of voice past the edge, in the material cut away, before
        /// a pause. Nil when there's no pause within `reach`.
        public var lost: Double?
        /// The edge sits in a quiet gap this long, too short to be a pause.
        public var gap: Double?
        /// What's cut off is only heard above 4 kHz: an "s" or a "t".
        public var highBandOnly: Bool
        /// The pause the suggested edge goes into, in media time.
        public var pause: ClosedRange<Double>?
        /// Where to move the edge (media time), when the fix is a trim.
        public var suggestion: Double?
        /// For a clipped edge.
        public var fix: Fix?
        /// The edge sits in a gap between words, not a real pause, when
        /// it's clean; or the suggested edge goes into one.
        public var betweenWords = false
        /// The kept word a trim back would drop, when that's why there's no
        /// trim: the transcript's text for it.
        public var drops: String?
        /// The last word of a sentence or clause the clip ends just before,
        /// cut with what follows (`lastWordCut`), when that's what clips it.
        public var lastWordCut: String?
        /// The first word of the sentence or clause the clip starts in, cut
        /// with what comes before (`firstWordCut`).
        public var firstWordCut: String?
        /// The last word of a cut sentence the clip opens on (`fragment`).
        public var fragment: String?
        /// The word a cut of a filler took with it (`wordBeforeFiller`).
        public var beforeFiller: String?

        static let clean = Edge(verdict: .clean, margin: nil, kept: 0, lost: 0, gap: nil, highBandOnly: false, pause: nil, suggestion: nil, fix: nil)
    }

    /// - Parameters:
    ///   - removed: at a cut between two pieces of one take, the stretch of
    ///     the file cut out between them; a fix only reaches into it.
    ///   - cutAway: at the end of a clip, the stretch of the file after it
    ///     that the next clip doesn't play, when that's more than `removed`
    ///     (see `CutPlacer.judge(at:keeps:removed:cutAway:transcript:)`).
    ///   - words: transcript words around the edge, in media time, with no
    ///     text (see `CutPlacer.judge(at:keeps:removed:transcript:)`).
    public static func judge(
        _ energy: SpeechEnergy, levels: SpeechLevels, at time: Double, keeps side: Side,
        removed: ClosedRange<Double>? = nil, words: [ClosedRange<Double>] = []
    ) -> Edge {
        CutPlacer(energy, levels: levels).judge(at: time, keeps: side, removed: removed, words: words)
    }

    public static func judge(
        _ energy: SpeechEnergy, levels: SpeechLevels, at time: Double, keeps side: Side,
        removed: ClosedRange<Double>? = nil, cutAway: ClosedRange<Double>? = nil, transcript: [Word]
    ) -> Edge {
        CutPlacer(energy, levels: levels).judge(at: time, keeps: side, removed: removed, cutAway: cutAway, transcript: transcript)
    }
}
