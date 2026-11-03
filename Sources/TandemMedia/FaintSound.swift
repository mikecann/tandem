import Foundation

/// Sound in a pause that's no voice and no breath: room tone a cut can go
/// through.
///
/// Tighten and `tandem cut` never cut through sound no word accounts for
/// (#11: someone off mic, an app talking, a breath). But on the Threadbear
/// launch video (November 2026) the camera mic picked up a foot tapping or
/// a fan all through the long pauses: low bumps 0.15 to 0.2 s long every
/// 0.43 s, about 20 dB under Mike's softer words, with a mouse click now
/// and then. Each bump was sound, so a 9 s pause became 20 cuts round them
/// and the picture jumped every 0.2 s, and `tandem cut` found no pause
/// within 0.3 s of four editor's notes.
///
/// By level alone the bumps were no fainter than #11's second voice, 20 dB
/// under the speaker. What set them apart (measured there):
/// - above 300 Hz (`SpeechEnergy.voice`), where a voice is, the bumps and
///   the chair's rumble were 30 to 40 dB under the softest word beside
///   them, where the breath before "Yeah." was 10 under;
/// - the clicks came near the voice above 300 Hz for 30 ms at most, and
///   rang over the line above 4 kHz for 65 ms at most, where the breath
///   before "Yeah." did both for 0.3 s or more.
///
/// So sound is faint when less than `briefest` of it is within
/// `voiceUnder` of the louder word either side above 300 Hz (or of the
/// voice's loud end round them), and less than a real pause's worth
/// (`CutAudit.minPause`, 80 ms) is over the line for sound above 4 kHz
/// (`highUnder` under the voice's loud tenth there, and over the floor).
/// Kept beside a word it's inaudible under the speech; cut through, nobody
/// misses it.
public enum FaintSound {
    /// Between #11's second voice (20 dB under, in the voice band too) and
    /// the clicks, 17 to 30 dB under the words beside them (a guess).
    public static let voiceUnder: Float = 25
    /// A breath's hiss is within a few dB of an "s" above 4 kHz, and the
    /// clicks were 10 to 20 dB under the words there (a guess).
    public static let highUnder: Float = 15
    /// The clicks were near the voice above 300 Hz for 30 ms at most; a
    /// short word, or a 0.1 s sound of someone off mic 20 dB under the
    /// voice (`GapSoundTests`), for 70 ms or more (a guess between them).
    public static let briefest = 0.04

    /// One 5 ms frame: above 300 Hz and above 4 kHz, dB, and the line above
    /// 4 kHz over which it's sound anyway (`GapSound.highOverFloor`).
    public struct Frame: Sendable {
        public var voice: Float
        public var high: Float
        public var highLine: Float

        public init(voice: Float, high: Float, highLine: Float) {
            self.voice = voice
            self.high = high
            self.highLine = highLine
        }
    }

    /// The frames' power in dB, averaged.
    static func power(_ levels: [Float]) -> Float {
        guard !levels.isEmpty else { return -120 }
        let mean = levels.reduce(0.0) { $0 + pow(10, Double($1) / 10) } / Double(levels.count)
        return mean > 0 ? Float(10 * log10(mean)) : -120
    }

    /// The loud tenth.
    static func loud(_ levels: [Float]) -> Float {
        let sorted = levels.sorted()
        return sorted.isEmpty ? -120 : sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
    }

    /// Whether `sound` is faint beside `words` (each a word's frames, the
    /// louder one counting), on one track, where the voice's loud end
    /// round the words is `speech` (`speech(in:around:)`). With no words,
    /// nothing is.
    public static func isFaint(_ sound: [Frame], beside words: [[Frame]], speech: Speech = .none) -> Bool {
        // The louder word: a soft one either side shouldn't make the sound
        // beside it count as loud. Nor should a word whose sound is only
        // partly read ("And" of "And we also have" before a 20 s pause on
        // the Threadbear video), so the voice round it counts too.
        guard let near = near(sound, beside: words, speech: speech) else { return false }
        return !near.voiced && !near.hiss
    }

    /// Whether `sound` has `briefest` or more near the voice above 300 Hz
    /// (a voice), and a real pause's worth over the line above 4 kHz (a
    /// breath's hiss). Nil with no sound or no words to go by.
    public static func near(_ sound: [Frame], beside words: [[Frame]], speech: Speech = .none) -> (voiced: Bool, hiss: Bool)? {
        guard !sound.isEmpty, let lines = lines(beside: words, speech: speech) else { return nil }
        let voiced = Double(sound.filter { $0.voice >= lines.voice }.count) * SpeechEnergy.frameSeconds
        let hiss = Double(sound.filter { $0.high >= max(lines.high, $0.highLine) }.count) * SpeechEnergy.frameSeconds
        return (voiced >= briefest - 1e-9, hiss >= CutAudit.minPause - 1e-9)
    }

    /// The lines a frame of sound is near the voice over, above 300 Hz and
    /// above 4 kHz (before the floor's line there): nil with no words.
    static func lines(beside words: [[Frame]], speech: Speech) -> (voice: Float, high: Float)? {
        guard let word = words.filter({ !$0.isEmpty }).max(by: { power($0.map(\.voice)) < power($1.map(\.voice)) }) else { return nil }
        return (max(power(word.map(\.voice)), speech.voice) - voiceUnder, max(loud(word.map(\.high)), speech.high) - highUnder)
    }

    /// How many frames at each end of `island` are faint beside `words`
    /// (`isFaint`'s lines, frame by frame), when they run for
    /// `CutPlanner.slack` or more: a bump of a foot tapping that runs
    /// straight into a word, with no quiet between, isn't the word. On the
    /// Threadbear video one made "Editor's note" start 0.6 s early, past
    /// the slack `tandem cut` allows. Shorter runs are left as they were:
    /// the pause before them is within the slack anyway, and the join
    /// check hears a room's rumble at a word's end as part of it.
    public static func faintEnds(
        of island: Range<Int>, beside words: [Range<Int>], in energy: SpeechEnergy, highLine: Float, speech: Speech
    ) -> (start: Int, end: Int) {
        let words = words.map { $0.clamped(to: 0..<energy.full.count).map { Frame(voice: energy.voice[$0], high: energy.high[$0], highLine: highLine) } }
        guard let lines = lines(beside: words, speech: speech) else { return (0, 0) }
        let inside = island.clamped(to: 0..<energy.full.count)
        func faint(_ index: Int) -> Bool { energy.voice[index] < lines.voice && energy.high[index] < max(lines.high, highLine) }
        let start = inside.prefix { faint($0) }.count
        let end = start == inside.count ? 0 : inside.reversed().prefix { faint($0) }.count
        let shortest = Int((CutPlanner.slack / SpeechEnergy.frameSeconds).rounded())
        // Never the whole island: that's no word at all, and left alone.
        guard start < inside.count else { return (0, 0) }
        return (start >= shortest ? start : 0, end >= shortest ? end : 0)
    }

    /// The same for a file's frames, by index.
    public static func isFaint(_ sound: Range<Int>, beside words: [Range<Int>], in energy: SpeechEnergy, highLine: Float, speech: Speech) -> Bool {
        func frames(_ range: Range<Int>) -> [Frame] {
            range.clamped(to: 0..<energy.full.count).map { Frame(voice: energy.voice[$0], high: energy.high[$0], highLine: highLine) }
        }
        return isFaint(frames(sound), beside: words.map(frames), speech: speech)
    }

    /// The voice's loud end, above 300 Hz and above 4 kHz, dB.
    public struct Speech: Sendable {
        public var voice: Float
        public var high: Float

        public static let none = Speech(voice: -120, high: -120)

        /// The louder of each.
        public static func louder(_ all: [Speech]) -> Speech {
            Speech(voice: all.map(\.voice).max() ?? -120, high: all.map(\.high).max() ?? -120)
        }
    }

    /// The voice's loud end in the file's sound `CutAudit.around` either
    /// side of media time `time`, as `CutPlacer.Around.speech` is in the
    /// full band.
    public static func speech(in energy: SpeechEnergy, around time: Double) -> Speech {
        let span = Int((CutAudit.around / SpeechEnergy.frameSeconds).rounded()), centre = energy.index(of: time)
        let frames = max(0, min(energy.voice.count, centre - span))..<max(0, min(energy.voice.count, centre + span))
        func percentile(_ values: ArraySlice<Float>) -> Float {
            let sorted = values.sorted()
            return sorted.isEmpty ? -120 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * CutAudit.speechPercentile))]
        }
        return Speech(voice: percentile(energy.voice[frames]), high: percentile(energy.high[frames]))
    }
}
