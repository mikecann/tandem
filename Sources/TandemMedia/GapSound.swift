import Foundation

/// One track's sound as it plays on the timeline: the clips on it, each
/// with its file's sound (`CutPlacer`) and where it plays from.
///
/// Times here are seconds on the timeline, so the sound of every track can
/// be laid over the others: a pause is only a pause when it's quiet on all
/// of them (#11).
public struct SoundLayer: Sendable {
    public struct Piece: Sendable {
        /// Where the clip plays on the timeline.
        public var timeline: Range<Double>
        /// The file's media time at `timeline.lowerBound`.
        public var mediaStart: Double
        public var speed: Double
        public var placer: CutPlacer

        public init(timeline: Range<Double>, mediaStart: Double, speed: Double, placer: CutPlacer) {
            self.timeline = timeline
            self.mediaStart = mediaStart
            self.speed = speed
            self.placer = placer
        }

        public func media(_ time: Double) -> Double { mediaStart + (time - timeline.lowerBound) * speed }
    }

    /// The track's name, to say where a sound is.
    public var name: String
    public var pieces: [Piece]

    public init(name: String, pieces: [Piece]) {
        self.name = name
        self.pieces = pieces
    }

    /// The piece playing at `time`, or (`ending`) the one playing up to it.
    func piece(at time: Double, ending: Bool = false) -> Piece? {
        pieces.first { ending ? ($0.timeline.lowerBound < time && time <= $0.timeline.upperBound) : $0.timeline.contains(time) }
    }
}

/// What the sound under a gap between two transcript words has in it, and
/// where tighten's cut goes there.
///
/// The transcript only says roughly where the gap is. Its word times are
/// 30 to 200 ms off the sound (#64), and its word edges come from where the
/// waveform is over one floor for the whole take, so a quiet second
/// speaker, an app talking, or a breath reads as silence (#11). So the gap
/// is measured from the sound, on every track that plays there: from the
/// end of the last word's sound to the start of the next word's. Sound is
/// measured as `CutPlacer` measures it, in 5 ms frames against each file's
/// own floor (the quietest tenth of 3 s either side), and a real pause is
/// 80 ms or more with no sound on any track (`fullOverFloor`,
/// `highOverFloor`).
///
/// Sound in the gap that isn't either word (an island no transcript word
/// calls home) is `heard`: a cut never goes through it, only in the quiet
/// either side of it. Then each join is judged by `CutPlacer.judge`,
/// exactly as `tandem check --cuts` will judge it.
public struct GapSound: Equatable, Sendable {
    /// Sound in the gap the transcript has no word for, in timeline time,
    /// with the tracks it's heard on.
    public struct Heard: Equatable, Sendable {
        public var range: ClosedRange<Double>
        public var layers: [String]
        /// Some of it is near the voice above 300 Hz on a track
        /// (`FaintSound.near`): it could be a word. False for a breath's
        /// hiss alone, or with no words either side to go by.
        public var voiced = true
    }

    /// From the end of the last word's sound to the start of the next
    /// word's, in timeline time. The transcript's gap when the sound runs
    /// right through it.
    public var span: ClosedRange<Double>
    /// The real pauses in `span`: quiet on every track.
    public var pauses: [ClosedRange<Double>]
    public var heard: [Heard]
    /// The two words' sound runs together with no real pause between them:
    /// the transcript has a gap in running speech, or speech too quiet for
    /// its word edges.
    public var runsThrough: Bool
    /// Faint sound in the pauses (`FaintSound`): part of them, so a cut can
    /// go through it, but its edges go in the quiet beside it.
    public var faint: [ClosedRange<Double>] = []
    /// The silence as Mike hears it: from where his voice stops to where it
    /// starts again, in timeline time. Nil when the voice runs on through.
    ///
    /// `span` goes from sound to sound, and sound there is anything over
    /// the room's floor, which is right for where a cut can go but not for
    /// how long the pause sounds. On the Examples Page video (19 Nov 2026)
    /// two 0.8 s gaps ("engineering land. | Over the past year", "or so. |
    /// So if") had a low bump under 300 Hz in them, 20 dB over the floor
    /// with nothing in the voice band or above 4 kHz. It joined the words'
    /// sound, so `pauses` said "heard as 0.20 s" and nothing flagged them,
    /// and Mike called them "awkward silence". A 0.21 s hitch inside a
    /// phrase ("for that | framework") had room tone 25 dB under the words
    /// in it and read as the voice running through; he heard a gap.
    ///
    /// So here only his voice is sound: frames near it above 300 Hz
    /// (`FaintSound.lines`, as for faint sound), and the hiss of an "s" or
    /// a "t" that runs straight on from them. A breath, a bump, a click or
    /// the room is silence, as Mike hears it.
    public var silence: ClosedRange<Double>?

    /// The least of a pause kept beside sound in a gap that isn't one of
    /// its words, either side of it: the Ian video's fixes put edges 30 ms
    /// inside a real pause (#64, measured), so a soft tail or the start of
    /// the next sound isn't on the cut.
    public static var edgeGuard: Double { CutAudit.pad }
    /// How far past the transcript's gap the words' sound can be.
    static var slack: Double { CutPlanner.slack }
    /// A frame is sound when it's this many dB over its file's local floor
    /// in the full band: `CutAudit.overFloor` and 3 more, since 5 ms frames
    /// of a room's rumble reach a dB or two over floor + 9 every so often,
    /// and a voice 20 dB under the speaker is 5 to 10 over it (a guess
    /// between the two, on synthetic rumble).
    static let fullOverFloor: Float = CutAudit.overFloor + 3
    /// And this many over it above 4 kHz, not `CutAudit.highOverFloor`'s
    /// 20: a breath sits 10 to 20 dB over the floor there, and
    /// `check --cuts` lets a join's edge sit in one, but a breath cut in
    /// half is something Mike hears. So in a gap a breath is sound, and
    /// tighten cuts beside it. Hiss above 4 kHz is steady, so it needs no
    /// margin over the 9 dB the full band's quiet line has.
    static let highOverFloor: Float = CutAudit.overFloor
    /// Sound reaches out through frames up to this far under those lines
    /// that touch it: a word's soft tail is the word's.
    static let tailUnder: Float = 3

    // MARK: - Listening

    /// The sound under `gap`, between transcript words `before` and
    /// `after` (all timeline time), on `layers`. Nil when some of the gap
    /// isn't played by any of them, so nobody knows what's there.
    public static func listen(
        gap: ClosedRange<Double>, before: ClosedRange<Double>, after: ClosedRange<Double>, layers: [SoundLayer]
    ) -> GapSound? {
        let step = SpeechEnergy.frameSeconds
        // Room for the words' own sound either side, which the transcript
        // can have up to `slack` out.
        let low = min(before.lowerBound - 0.1, gap.lowerBound - slack)
        let high = max(after.upperBound + 0.1, gap.upperBound + slack)
        let count = Int(((high - low) / step).rounded(.up))
        guard count > 0 else { return nil }
        func time(_ index: Int) -> Double { low + Double(index) * step }

        // How far over the line for sound each track is, against its own
        // floor where it's played (`around` either side, taken once a
        // second of its file): the louder of the full band and above 4 kHz.
        var arounds: [String: CutPlacer.Around] = [:]
        // Each track's own frames too, to tell faint sound from the words'
        // (`FaintSound`): nil where it doesn't play.
        var frames = [[FaintSound.Frame?]](repeating: [FaintSound.Frame?](repeating: nil, count: count), count: layers.count)
        func over(_ layer: Int, at t: Double, index: Int) -> Float? {
            guard let pieceIndex = layers[layer].pieces.firstIndex(where: { $0.timeline.contains(t) }) else { return nil }
            let piece = layers[layer].pieces[pieceIndex]
            let media = piece.media(t)
            let chunk = Int(media.rounded(.down))
            let key = "\(layer)/\(pieceIndex)/\(chunk)"
            let near = arounds[key] ?? piece.placer.around(Double(chunk) + 0.5)
            arounds[key] = near
            let energy = piece.placer.energy
            let frame = energy.index(of: media)
            // Past the file's ends is silence.
            let highLine = near.highFloor + highOverFloor
            guard frame >= 0, frame < energy.full.count else {
                frames[layer][index] = FaintSound.Frame(voice: -120, high: -120, highLine: highLine)
                return -120
            }
            frames[layer][index] = FaintSound.Frame(voice: energy.voice[frame], high: energy.high[frame], highLine: highLine)
            return max(energy.full[frame] - (near.floor + fullOverFloor), energy.high[frame] - (near.highFloor + highOverFloor))
        }

        // The loudest track's excess at each frame, and which tracks have
        // sound there.
        var excess = [Float](repeating: -120, count: count)
        var sounding = [[Bool]](repeating: [Bool](repeating: false, count: count), count: layers.count)
        for index in 0..<count {
            let t = time(index) + step / 2
            var heardBy = 0
            for layer in layers.indices {
                guard let level = over(layer, at: t, index: index) else { continue }
                heardBy += 1
                excess[index] = max(excess[index], level)
                if level >= 0 { sounding[layer][index] = true }
            }
            if heardBy == 0 {
                // Unplayed: inside the gap nothing can be said about it, and
                // beside it it's no pause to cut in.
                if gap.lowerBound < t && t < gap.upperBound { return nil }
                excess[index] = .infinity
            }
        }

        let silence = Self.silence(frames: frames, layers: layers, gap: gap, before: before, after: after, low: low)

        // Islands of sound: frames of it with less than a real pause
        // (`CutAudit.minPause`) between them. A group with less than
        // `CutPlanner.soundFrames` of them is a blip of room noise in a
        // pause. Each island reaches out from its sound through the frames
        // within `tailUnder` of the line touching it, a word's soft tail,
        // but not to a blip across the quiet.
        let pauseLength = Int((CutAudit.minPause / step).rounded())
        let loudFrames = (0..<count).filter { excess[$0] >= 0 }
        var groups: [[Int]] = []
        for frame in loudFrames {
            if let last = groups.last?.last, frame - last <= pauseLength { groups[groups.count - 1].append(frame) } else { groups.append([frame]) }
        }
        var islands: [Range<Int>] = []
        for group in groups where group.count >= CutPlanner.soundFrames {
            var low = group.first!, high = group.last! + 1
            func touching(_ frame: Int) -> Bool { frame >= 0 && frame < count && excess[frame] >= -tailUnder }
            while touching(low - 1) || touching(low - 2) { low -= touching(low - 1) ? 1 : 2 }
            while touching(high) || touching(high + 1) { high += touching(high) ? 1 : 2 }
            if let last = islands.last, low <= last.upperBound {
                islands[islands.count - 1] = last.lowerBound..<max(last.upperBound, high)
            } else {
                islands.append(low..<high)
            }
        }
        func span(_ island: Range<Int>) -> ClosedRange<Double> { time(island.lowerBound)...time(island.upperBound) }
        func overlap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
            max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        }
        func heardOn(_ island: Range<Int>) -> [String] {
            layers.indices.filter { layer in island.contains { sounding[layer][$0] } }.map { layers[$0].name }
        }
        // Each word's home: the island holding most of it, so a word the
        // transcript has 0.2 s out still lands in the right one.
        func home(_ word: ClosedRange<Double>) -> Int? {
            let best = islands.indices.max { overlap(span(islands[$0]), word) < overlap(span(islands[$1]), word) }
            return best.flatMap { overlap(span(islands[$0]), word) > 0 ? $0 : nil }
        }
        let last = home(before), next = home(after)
        let from = last.map { span(islands[$0]).upperBound } ?? before.upperBound
        let to = next.map { span(islands[$0]).lowerBound } ?? after.lowerBound
        if let last, let next, last >= next {
            let through = islands[last]
            let range = max(gap.lowerBound, span(through).lowerBound)...min(gap.upperBound, span(through).upperBound)
            return GapSound(span: gap, pauses: [], heard: [Heard(range: range, layers: heardOn(through))], runsThrough: true, silence: silence)
        }
        guard to > from else {
            return GapSound(span: gap, pauses: [], heard: [], runsThrough: true, silence: silence)
        }

        // Faint sound (`FaintSound`): on every track it's heard on, no
        // voice or breath beside the words either side there. A foot tapping or a fan
        // through a long pause is a row of these, and cutting round each
        // one made a 9 s pause twenty cuts (the Threadbear launch video).
        // How near the voice it comes on each track it's heard on: nil
        // when there are no words to go by.
        func near(_ island: Range<Int>) -> [(voiced: Bool, hiss: Bool)]? {
            guard let last, let next else { return nil }
            var all: [(voiced: Bool, hiss: Bool)] = []
            for layer in layers.indices where island.contains(where: { sounding[layer][$0] }) {
                let words = [islands[last], islands[next]].map { $0.compactMap { frames[layer][$0] } }
                // The voice round each word where this track plays it.
                let speech = FaintSound.Speech.louder([before.upperBound, after.lowerBound].compactMap { t in
                    layers[layer].piece(at: t).map { FaintSound.speech(in: $0.placer.energy, around: $0.media(t)) }
                })
                guard let found = FaintSound.near(island.compactMap { frames[layer][$0] }, beside: words, speech: speech) else { return nil }
                all.append(found)
            }
            return all
        }

        // Other sound between the two words' own is heard: never cut through.
        var heard: [Heard] = []
        var faint: [ClosedRange<Double>] = []
        for (number, island) in islands.enumerated() where number != last && number != next {
            let range = span(island)
            guard range.upperBound > from, range.lowerBound < to else { continue }
            let clipped = max(from, range.lowerBound)...min(to, range.upperBound)
            let found = near(island)
            if let found, found.allSatisfy({ !$0.voiced && !$0.hiss }) {
                faint.append(clipped)
            } else {
                heard.append(Heard(range: clipped, layers: heardOn(island), voiced: found?.contains { $0.voiced } ?? true))
            }
        }
        var pauses: [ClosedRange<Double>] = []
        var start = from
        for sound in heard {
            if sound.range.lowerBound > start { pauses.append(start...sound.range.lowerBound) }
            start = max(start, sound.range.upperBound)
        }
        if to > start { pauses.append(start...to) }
        return GapSound(span: from...to, pauses: pauses, heard: heard, runsThrough: false, faint: faint, silence: silence)
    }

    // MARK: - Silence as it's heard

    /// A run of voice shorter than this in a pause is a click or a lip
    /// smack, not a word (`FaintSound.briefest`).
    static var briefestVoice: Double { FaintSound.briefest }

    /// `silence`, from each track's frames (`frames[layer][index]`, nil
    /// where the track doesn't play), the first at `low`: the stretch with
    /// no voice in it that overlaps the transcript's gap most, or the
    /// longest within `slack` of it when none does.
    static func silence(
        frames: [[FaintSound.Frame?]], layers: [SoundLayer], gap: ClosedRange<Double>,
        before: ClosedRange<Double>, after: ClosedRange<Double>, low: Double
    ) -> ClosedRange<Double>? {
        let step = SpeechEnergy.frameSeconds
        let count = frames.first?.count ?? 0
        guard count > 0 else { return nil }
        func time(_ index: Int) -> Double { low + Double(index) * step }
        // Each track's lines for its voice, from the words either side as
        // the transcript has them and the voice round them.
        let lines: [(voice: Float, high: Float)?] = layers.indices.map { layer in
            func word(_ range: ClosedRange<Double>) -> [FaintSound.Frame] {
                (0..<count).filter { range.contains(time($0) + step / 2) }.compactMap { frames[layer][$0] }
            }
            let speech = FaintSound.Speech.louder([before.upperBound, after.lowerBound].compactMap { t in
                layers[layer].piece(at: t).map { FaintSound.speech(in: $0.placer.energy, around: $0.media(t)) }
            })
            return FaintSound.lines(beside: [word(before), word(after)], speech: speech)
        }
        guard lines.contains(where: { $0 != nil }) else { return nil }
        var played = [Bool](repeating: false, count: count)
        var voiced = [Bool](repeating: false, count: count)
        var hiss = [Bool](repeating: false, count: count)
        for index in 0..<count {
            for layer in layers.indices {
                guard let frame = frames[layer][index] else { continue }
                played[index] = true
                guard let line = lines[layer] else { continue }
                if frame.voice >= line.voice { voiced[index] = true }
                if frame.high >= max(line.high, frame.highLine) { hiss[index] = true }
            }
        }
        func runs(_ flags: [Bool], holes: Int = 0) -> [Range<Int>] {
            var found: [Range<Int>] = []
            var index = 0
            while index < count {
                guard flags[index] else { index += 1; continue }
                var end = index + 1
                while end < count {
                    if flags[end] { end += 1; continue }
                    // A hole of `holes` frames or fewer inside a run is part of it.
                    if let next = (end..<min(count, end + holes + 1)).first(where: { flags[$0] }) { end = next; continue }
                    break
                }
                found.append(index..<end)
                index = end
            }
            return found
        }
        // A blip of voice too short to be a word is silence: a click, a
        // lip smack, the room's bump just touching the line.
        let shortest = Int((briefestVoice / step).rounded())
        var speaking = [Bool](repeating: false, count: count)
        for run in runs(voiced, holes: 1) where run.count >= shortest {
            for index in run { speaking[index] = true }
        }
        // Hiss that runs straight on from the voice is the word's "s" or
        // "t"; hiss with quiet between it and the voice is a breath.
        for run in runs(hiss, holes: 1) {
            let reach = max(0, run.lowerBound - 2)..<min(count, run.upperBound + 2)
            if reach.contains(where: { speaking[$0] }) { for index in run { speaking[index] = true } }
        }
        // Where the track doesn't play (past the timeline's ends) is no
        // silence to hear.
        let quiet = (0..<count).map { played[$0] && !speaking[$0] }
        let window = (gap.lowerBound - slack)...(gap.upperBound + slack)
        let candidates = runs(quiet).map { time($0.lowerBound)...time($0.upperBound) }.filter { $0.overlaps(window) }
        func overlap(_ range: ClosedRange<Double>, _ other: ClosedRange<Double>) -> Double {
            max(0, min(range.upperBound, other.upperBound) - max(range.lowerBound, other.lowerBound))
        }
        func length(_ range: ClosedRange<Double>) -> Double { range.upperBound - range.lowerBound }
        return candidates.max { a, b in
            let (x, y) = (overlap(a, gap), overlap(b, gap))
            return abs(x - y) > 1e-9 ? x < y : length(a) < length(b)
        }
    }

    // MARK: - Placing the cut

    /// Why a gap isn't cut.
    public enum Refusal: String, Error, Codable, Sendable {
        /// The voice runs right through it: no real pause.
        case speech
        /// Sound the transcript doesn't know about leaves no pause long
        /// enough to cut in.
        case sound
        /// Measured from the sound, the gap is shorter than the minimum.
        case short
        /// It's already no longer than the keep: nothing to cut.
        case fits
    }

    /// One cut in a gap.
    public struct Placement: Equatable, Sendable {
        /// The real pause the cut is in.
        public var pause: ClosedRange<Double>
        /// The cut, before it's put on frames.
        public var from: Double
        public var to: Double
        /// As far as an edge may go towards the pause's ends when it's put
        /// on a frame: the least kept at that end (`least(after:)`,
        /// `least(before:)`).
        public var earliest: Double
        public var latest: Double
    }

    /// The least of a pause kept after the word before a cut and before the
    /// word after it, as `tandem cut` keeps (`CutPlanner.minimumTail`,
    /// `minimumLead`): 30 ms past a word's tail, and 80 ms before a word,
    /// whose sound can start before its burst ("processed" on the Ian
    /// video). Beside sound in the gap that isn't a word, `edgeGuard`: its
    /// island already reaches out through its soft edges (`tailUnder`), and
    /// the join is judged on it anyway.
    static func least(after word: Bool) -> Double { word ? CutPlanner.minimumTail : edgeGuard }
    static func least(before word: Bool) -> Double { word ? CutPlanner.minimumLead : edgeGuard }
    /// A quiet stretch beside sound in the gap is only cut when that takes
    /// out at least a real pause (`CutAudit.minPause`): less doesn't change
    /// how the gap sounds, and each cut is two more joins in the room's
    /// sound. A gap with nothing in it is cut for a frame, as it always was.
    public static var shortestBesideSound: Double { CutAudit.minPause }

    /// Where the cuts go to leave `keep` between the two words' sound, when
    /// the gap is at least `minimum`. Every real pause in it long enough is
    /// cut, around the sound in the gap that stays (a breath, someone off
    /// mic, an "um" the transcript missed), so what's left is that sound
    /// and the keep, not more.
    ///
    /// How the keep is shared: the sound in the gap counts towards it, and
    /// so does the least kept beside each piece of it and the words
    /// (`least(after:)`, `least(before:)`). Whatever's left of the keep goes
    /// after the word before and before the word after, as evenly as their
    /// least allows, as a gap with nothing in it shares it: Mike's pause is
    /// between his words, and the sound in it keeps its own place beside
    /// whatever it was close to. Only when those two can't take it (their
    /// quiet is all kept) does it go beside the sound. A quiet stretch that
    /// would lose less than a frame (or `shortestBesideSound`) is kept whole
    /// and counts towards the keep too. Each cut needs room for at least a
    /// `frame`.
    ///
    /// With a `lead` (`LeadIn`), the word after keeps just that before it,
    /// and the rest of the keep goes after the word before, then beside the
    /// sound, and only before the word after when neither can take it: the
    /// clip coming in starts a frame or two before he speaks.
    public func place(keep: Double, minimum: Double, frame: Double, lead: Double? = nil) -> Result<[Placement], Refusal> {
        if runsThrough { return .failure(.speech) }
        func length(_ range: ClosedRange<Double>) -> Double { range.upperBound - range.lowerBound }
        guard length(span) >= minimum - 1e-9 else { return .failure(.short) }
        guard !pauses.isEmpty else { return .failure(.sound) }

        let shortest = heard.isEmpty ? frame : max(frame, Self.shortestBesideSound)
        let sound = length(span) - pauses.reduce(0) { $0 + length($1) }
        // Which ends of each stretch are beside a word, and the least kept there.
        let afterWord = pauses.map { abs($0.lowerBound - span.lowerBound) < 1e-9 }
        let beforeWord = pauses.map { abs($0.upperBound - span.upperBound) < 1e-9 }
        let lowest = pauses.indices.map { Self.least(after: afterWord[$0]) }
        let highest = pauses.indices.map { beforeWord[$0] ? lead ?? Self.least(before: true) : Self.least(before: false) }

        var whole = pauses.indices.map { length(pauses[$0]) - lowest[$0] - highest[$0] < shortest - 1e-9 }
        var low = lowest, high = highest
        while true {
            low = lowest
            high = highest
            let kept = pauses.indices.reduce(sound) { total, index in
                total + (whole[index] ? length(pauses[index]) : lowest[index] + highest[index])
            }
            var spare = keep - kept
            // Beside the words first, then beside the sound. With a lead,
            // after the word before, then beside the sound, then (only when
            // neither can take it) before the word after.
            typealias Round = (words: Bool, low: Bool, high: Bool)
            let rounds: [Round] = lead == nil
                ? [(true, true, true), (false, true, true)]
                : [(true, true, false), (false, true, true), (true, false, true)]
            for round in rounds where spare > 1e-12 {
                var edges: [(index: Int, low: Bool)] = []
                for index in pauses.indices where !whole[index] {
                    if round.low, afterWord[index] == round.words { edges.append((index, true)) }
                    if round.high, beforeWord[index] == round.words { edges.append((index, false)) }
                }
                guard !edges.isEmpty else { continue }
                let least = edges.map { $0.low ? lowest[$0.index] : highest[$0.index] }
                // The level every edge is brought up to, from its least:
                // what it takes in all is the spare.
                func taken(_ level: Double) -> Double { least.reduce(0) { $0 + max(0, level - $1) } }
                var bottom = least.min()!, top = least.max()! + spare
                for _ in 0..<60 {
                    let middle = (bottom + top) / 2
                    if taken(middle) < spare { bottom = middle } else { top = middle }
                }
                for (edge, least) in zip(edges, least) {
                    let value = max(least, top)
                    if edge.low { low[edge.index] = value } else { high[edge.index] = value }
                }
                spare = 0
            }
            // A stretch left too little to cut is kept whole, the one most
            // short first, and the keep shared again.
            let over = pauses.indices.filter { !whole[$0] }.map { ($0, length(pauses[$0]) - low[$0] - high[$0] - shortest) }
            guard let worst = over.min(by: { $0.1 < $1.1 }), worst.1 < -1e-9 else { break }
            whole[worst.0] = true
        }

        let cuts = pauses.indices.filter { !whole[$0] }.map { index in
            let pause = pauses[index]
            let (from, to) = clearOfFaint(from: pause.lowerBound + low[index], to: pause.upperBound - high[index], shortest: shortest)
            return Placement(
                pause: pause, from: from, to: to,
                earliest: pause.lowerBound + lowest[index], latest: pause.upperBound - highest[index]
            )
        }
        guard cuts.isEmpty else { return .success(cuts) }
        if length(span) <= keep + frame { return .failure(.fits) }
        return .failure(heard.isEmpty ? .short : .sound)
    }

    /// A cut's edges moved out of any faint sound they land in, into the
    /// quiet beside it, keeping more of the pause rather than less: the
    /// start on past the sound, the end back before it. The join is then in
    /// the room's quiet rather than halfway through a bump. An edge stays
    /// put when moving it would leave less than `shortest` to cut.
    func clearOfFaint(from: Double, to: Double, shortest: Double) -> (Double, Double) {
        var from = from, to = to
        if let sound = faint.first(where: { $0.lowerBound < from && from < $0.upperBound }),
           to - (sound.upperBound + Self.edgeGuard) >= shortest - 1e-9 {
            from = sound.upperBound + Self.edgeGuard
        }
        if let sound = faint.first(where: { $0.lowerBound < to && to < $0.upperBound }),
           (sound.lowerBound - Self.edgeGuard) - from >= shortest - 1e-9 {
            to = sound.lowerBound - Self.edgeGuard
        }
        return (from, to)
    }

    // MARK: - Judging the join

    /// How one side of a join sounds, the worst of the tracks that carry a
    /// voice there, as `tandem check --cuts` judges each.
    public struct Join: Equatable, Sendable {
        public var verdict: CutAudit.Verdict
        /// How far the clip's 25 ms beside the edge is under the speech, dB,
        /// on the track it's worst on. Nil when no track has a voice.
        public var margin: Float?
        public var layer: String?

        static let silent = Join(verdict: .clean, margin: nil, layer: nil)
    }

    /// Both sides of the join a cut from `from` to `to` (timeline) leaves,
    /// judged on every layer playing there that carries a voice. A track
    /// with no voice (a device's recording that's digital silence) has
    /// nothing to clip; its quiet already counted in the pause.
    public static func judge(_ layers: [SoundLayer], from: Double, to: Double) -> (start: Join, end: Join) {
        var start = Join.silent, end = Join.silent
        func worse(_ a: Join, than b: Join) -> Bool {
            let rank: [CutAudit.Verdict: Int] = [.clean: 0, .marginal: 1, .clipped: 2]
            if rank[a.verdict]! != rank[b.verdict]! { return rank[a.verdict]! > rank[b.verdict]! }
            return (a.margin ?? .infinity) < (b.margin ?? .infinity)
        }
        for layer in layers {
            let before = layer.piece(at: from, ending: true), after = layer.piece(at: to)
            // What's cut out between them, when one piece of the file plays
            // both sides: a fix there would only reach into it.
            var removed: ClosedRange<Double>?
            if let before, let after, before.timeline == after.timeline, before.media(from) <= after.media(to) {
                removed = before.media(from)...after.media(to)
            }
            if let before, before.placer.levels.isVoice {
                let time = before.media(from)
                let edge = before.placer.judge(at: time, keeps: .before, removed: removed)
                let join = Join(verdict: edge.verdict, margin: before.placer.score(at: time, keeps: .before).margin, layer: layer.name)
                if worse(join, than: start) { start = join }
            }
            if let after, after.placer.levels.isVoice {
                let time = after.media(to)
                let edge = after.placer.judge(at: time, keeps: .after, removed: removed)
                let join = Join(verdict: edge.verdict, margin: after.placer.score(at: time, keeps: .after).margin, layer: layer.name)
                if worse(join, than: end) { end = join }
            }
        }
        return (start, end)
    }
}
