import Foundation

/// Where a clip of a talking take should start: a frame or two before the
/// first word's sound, so Mike's face isn't on screen waiting to talk.
///
/// Reviewing the "Let's Build It technical" video (13 Nov 2026), at a
/// sentence join: "often what you do is you don't start the next clip soon
/// enough. So you end up with like my gormless face on screen for like a
/// couple of hundred milliseconds... it should start the next clip like one
/// frame or two frames before the speech starts... you should add that
/// extra time onto the end of the previous clip." On that edit 77 joins had
/// the incoming clip running 0.12 to 0.51 s before he spoke, because
/// `tighten` and `cut` split the pause they keep between both sides.
///
/// So the pause a join keeps goes on the end of the clip going out, and the
/// one coming in starts `lead` before its first word. The word's start is
/// read from the same sound `tandem check --cuts` reads (`CutPlacer`): 20 ms
/// of unbroken sound over the line for a word (`wordLine`) that carries on
/// (`carry`, so a click isn't the word), then back down
/// the word's ramp (`ramp`), so a soft first consonant stays. A breath
/// before the word is pause, as it is to tighten and to Mike.
///
/// The line isn't `check --cuts`'s quiet line (the local floor + 9 dB): in a
/// quiet room a breath is well over that. On the Let's Build It take the
/// floor was -81 dB and the breaths before "So, what I ended up with" and
/// "I probably should" sat at -64 to -65 dB for 0.15 to 0.2 s, so the clips
/// read as starting on speech when his face waited 0.35 to 0.5 s. The hand
/// fix that Mike signed off went by -45 dB, walked back to -55: about 20 dB
/// under his speech, then 10 more down the ramp.
public enum LeadIn {
    /// What's left before the first word's sound: a frame and a half at
    /// 30 fps. The hand-rolled version on the Let's Build It edit left this
    /// and `check --cuts --listen` heard nothing clipped across 77 joins.
    public static let lead = 0.05
    /// A clip that runs longer than this before its first word shows his
    /// face waiting (`tandem check`'s note).
    public static let longestWait = 0.1
    /// A word is within this of the local speech level (`CutPlacer`'s loud
    /// end), in the full band, or over `check --cuts`'s line for sound
    /// above 4 kHz (an "s" or "f"), whichever line is higher. A breath sits
    /// 35 to 40 dB under his speech.
    static let wordUnderSpeech: Float = 25
    /// A word's sound carries on: at least `carried` of the first `carry`
    /// is over the line. A short "I" does; a click doesn't.
    static let carry = 0.06
    static let carried = 0.04
    /// A burst this long over the word line stops a clip growing into
    /// what was cut: a click or a lip smack is 10 to 30 ms.
    static let burstShortest = 0.01
    /// How far back from the line a word's onset is followed, dB: a soft
    /// "f", "h" or "th" ramps up under it.
    static let ramp: Float = 10
    /// And for no longer than this: a soft "f" or "h" before its vowel.
    static let rampLongest = 0.08
    /// How far past the start a word is looked for. Further on, the clip
    /// opens on a long silence on purpose (a beat for something on screen),
    /// which isn't a face waiting to talk.
    public static let reach = 1.5

    /// Where speech starts at or after `time` (media seconds) in `placer`'s
    /// sound, within `reach`: the first `CutAudit.minSpeech` of unbroken
    /// sound, walked back down its ramp. `time` itself when the sound is already going there.
    /// Nil when there's no speech in reach.
    public static func speechStart(_ placer: CutPlacer, after time: Double, reach: Double = reach) -> Double? {
        let energy = placer.energy
        let step = SpeechEnergy.frameSeconds
        let near = placer.around(time + min(reach, CutAudit.around) / 2)
        let first = max(0, energy.index(of: time))
        let last = min(energy.full.count, energy.index(of: time + reach))
        guard first < last else { return nil }
        // Speech is `CutAudit.minSpeech` (20 ms) of sound without a break:
        // the room's rumble pokes over the line for a frame every 50 ms or
        // so, which a count of loud frames up to the next pause adds up.
        let soundFrames = Int((CutAudit.minSpeech / step).rounded())
        let carryFrames = Int((carry / step).rounded()), carriesOn = Int((carried / step).rounded())
        let line = wordLine(near)
        func word(_ i: Int) -> Bool { i < energy.full.count && (energy.full[i] >= line.full || energy.high[i] >= line.high) }
        var index = first
        while index < last {
            // And it carries on: a click or a lip smack before he speaks is
            // a 20 to 30 ms burst and then quiet again (on the Let's Build
            // It take, 0.3 s before "Oh, and I am working on").
            guard (index..<index + soundFrames).allSatisfy(word),
                  (index..<index + carryFrames).filter(word).count >= carriesOn else { index += 1; continue }
            // Back down the word's ramp: frames just under the line, each
            // no louder than the one after it (a rumble's blips go up and
            // down), for at most `rampLongest`.
            // Sound less than a real pause (`CutAudit.minPause`) before it
            // is part of the word: "It" on the Let's Build It take opens on
            // a 20 ms burst, 50 ms of something softer, then the vowel.
            let gap = Int((CutAudit.minPause / step).rounded())
            var start = index, back = index - 1
            while back >= first, start - back <= gap {
                if word(back) { start = back }
                back -= 1
            }
            let lowest = max(first, start - Int((rampLongest / step).rounded()))
            func under(_ i: Int, _ level: [Float], _ line: Float) -> Bool { level[i] >= line - ramp && level[i] <= level[i + 1] + 1 }
            while start > lowest, under(start - 1, energy.full, line.full) || under(start - 1, energy.high, line.high) {
                start -= 1
            }
            return max(time, energy.start + Double(start) * step)
        }
        return nil
    }

    /// The line for a word near the frames `near` covers: in the full band,
    /// `wordUnderSpeech` under the speech there, never under `check --cuts`'s
    /// quiet line; above 4 kHz, that check's line for sound (its floor + 20
    /// dB, which a breath stays under).
    static func wordLine(_ near: CutPlacer.Around) -> (full: Float, high: Float) {
        (max(near.quiet, near.speech - wordUnderSpeech), near.highQuiet)
    }

    /// Where a clip whose word starts at `onset` (media seconds) should
    /// start: `lead` before it, and earlier a step at a time while the
    /// join wouldn't be clean there, never before `earliest` (where it
    /// starts now). Nil when that's `earliest` or before: nothing to gain.
    ///
    /// Judged as `check --cuts` judges it, `transcript` (the file's words,
    /// media time) and all: Bark's first word can start before the sound
    /// does, and check would call a clip starting after it clipped.
    /// `outgoingEnd` is where the clip before ends now (media time): rolled,
    /// what's cut between them moves on with the cut.
    public static func start(
        _ placer: CutPlacer, onset: Double, lead: Double = lead, earliest: Double, outgoingEnd: Double? = nil, transcript: [CutAudit.Word] = []
    ) -> Double? {
        let step = SpeechEnergy.frameSeconds
        var at = onset - lead
        func removed(_ at: Double) -> ClosedRange<Double>? { outgoingEnd.map { min(at, $0 + (at - earliest))...at } }
        while at > earliest, placer.judge(at: at, keeps: .after, removed: removed(at), cutAway: removed(at), transcript: transcript).verdict != .clean {
            at -= step
        }
        return at > earliest + 1e-9 ? at : nil
    }

    /// How far the clip ending at `time` (media seconds) can run on into
    /// its file, up to `limit`, through quiet only: it stops `CutAudit.pad`
    /// short of the next word (`speechStart`), and its end has to judge
    /// clean, as `check --cuts` judges it
    /// with `transcript`. `incomingStart` is where the clip after starts now
    /// (media time, in the same file).
    public static func quietAfter(
        _ placer: CutPlacer, from time: Double, limit: Double, incomingStart: Double? = nil, transcript: [CutAudit.Word] = []
    ) -> Double {
        let step = SpeechEnergy.frameSeconds
        var length = limit
        // Up to the next word by the same line as the word after the join
        // (25 dB under his speech): a breath after his last word is pause,
        // and grows on with the clip. Going by `check --cuts`'s own quiet
        // line instead (the floor + 9 dB), the Let's Build It take's quiet
        // room made most breaths sound and 59 of 155 waiting joins couldn't
        // move; the hand fix Mike's edit has went by -48 dB, about 27 under
        // his speech, and `--listen` heard every join clean. Its end is then
        // judged as check judges it, below.
        if let next = speechStart(placer, after: time, reach: limit + CutAudit.pad) {
            length = min(limit, next - time - CutAudit.pad)
        }
        // And short of any burst over that line: `speechStart` passes over a
        // click that's quiet again after it (it isn't a word to wait for),
        // but one that was cut away mustn't come back on the clip's end.
        let energy = placer.energy
        let line = wordLine(placer.around(time))
        let burst = Int((burstShortest / step).rounded())
        var index = max(0, energy.index(of: time))
        let last = min(energy.full.count, energy.index(of: time + length + CutAudit.pad))
        while index < last {
            if (index..<index + burst).allSatisfy({ $0 < energy.full.count && (energy.full[$0] >= line.full || energy.high[$0] >= line.high) }) {
                length = min(length, energy.start + Double(index) * step - time - CutAudit.pad)
                break
            }
            index += 1
        }
        func removed(_ length: Double) -> ClosedRange<Double>? {
            incomingStart.map { (time + length)...max(time + length, $0 + length) }
        }
        // A clip may only end in a pause: back off until the end is clean.
        while length > 0, placer.judge(at: time + length, keeps: .before, removed: removed(length), cutAway: removed(length), transcript: transcript).verdict != .clean {
            length -= step
        }
        return max(0, length)
    }
}
