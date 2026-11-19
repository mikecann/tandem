import Foundation

/// `tandem check --cuts --listen`: what the levels, the transcript's rules
/// and listening say together about one join.
///
/// Each on its own over-flags. On Mike's published Tandem video `check
/// --cuts --listen` flagged 38 of 257 joins, and reading each one again
/// found 4 real. The levels flagged tight joins in fluent speech, where the
/// voice runs straight through the cut and every word is heard whole. The
/// last-word rule flagged a word the engine then heard ("stuff like that."),
/// so the transcript's times were off, not the cut. And most of what
/// listening flagged as a word left in was a word the take's transcript has
/// just past the edge, heard whole ("my own", "hopefully see"): the
/// transcript put it in the cut, but the cut keeps it.
///
/// So where a join was heard, each side checks the other:
/// - a level flag, or a transcript rule's flag, whose words are heard whole
///   and in place is dismissed, unless listening has a finding there too;
/// - a listening finding the take's own transcript explains is a note;
/// - a join with both stays a problem, with both said.
///
/// Levels win where the sound itself says the cut is inside a word: the
/// clip's last or first 25 ms under `heardOver` dB below the speech. On the
/// Ian video four joins Mike heard clipped (a fluent join or a cut inside a
/// word) were all at 4.7 dB or less, and the engine heard every word of
/// them, filling in what was cut. The Tandem video's tight joins in fluent
/// speech were mostly 6 dB or more under.
public enum CutEvidence {
    /// A level flag is only dismissed when the clip's 25 ms at the cut is at
    /// least this far under the speech (dB).
    public static let heardOver: Float = 6

    /// What the levels and the transcript's rules said at one edge of a join
    /// (`CutAudit.Edge`, or the `cut` of a `clippedWord` problem).
    public struct Flag: Equatable, Sendable {
        public var keeps: CutAudit.Side
        /// dB the clip's 25 ms at the cut is under the speech.
        public var margin: Float?
        public var lastWordCut: String?
        public var firstWordCut: String?
        public var fragment: String?
        public var beforeFiller: String?

        public init(keeps: CutAudit.Side, margin: Float?, lastWordCut: String? = nil, firstWordCut: String? = nil, fragment: String? = nil, beforeFiller: String? = nil) {
            self.keeps = keeps
            self.margin = margin
            self.lastWordCut = lastWordCut
            self.firstWordCut = firstWordCut
            self.fragment = fragment
            self.beforeFiller = beforeFiller
        }

        public init(_ edge: CutAudit.Edge, keeps: CutAudit.Side) {
            self.init(keeps: keeps, margin: edge.margin, lastWordCut: edge.lastWordCut, firstWordCut: edge.firstWordCut,
                      fragment: edge.fragment, beforeFiller: edge.beforeFiller)
        }

        /// The cut word a transcript rule says the join loses: heard, it's
        /// kept after all.
        var cutWord: String? { lastWordCut ?? firstWordCut ?? beforeFiller }
    }

    public struct Verdict: Equatable, Sendable {
        /// Why each flag, by index, is dismissed: listening hears its words
        /// whole and in place.
        public var dismissed: [Int: String] = [:]
        /// Why the take's own transcript explains each finding, by index into
        /// the join's findings.
        public var explained: [Int: String] = [:]
        /// The findings, by index, that back a flag up: not explained, and
        /// either not slip-prone or a kept word at the join not heard right.
        public var confirming: [Int] = []
        /// A finding that isn't slip-prone and isn't explained: listening's
        /// own problem.
        public var heardCutOff = false
        /// Level flags, by index, whose words are all heard but which stand,
        /// since the clip at the cut is under `heardOver` dB below the
        /// speech, with that margin: listening can't settle these, an ear
        /// can.
        public var tooClose: [Int: Float] = [:]
    }

    /// Weighs the flags at a heard join against what was heard there.
    ///
    /// - Parameters:
    ///   - join: what was heard, compared with the take (`CutListen.compare`).
    ///   - flags: each edge's flag at the join, from the levels or the
    ///     transcript's rules.
    ///   - cut: the take's words cut beside the join, by the transcript: the
    ///     ones cut past the clip before it and before the clip after it.
    public static func judge(_ join: CutListen.Join, flags: [Flag], cut: [String]) -> Verdict {
        var verdict = Verdict()
        let said = sides(join.said), heard = sides(join.heard)
        let cutWords = cut + flags.compactMap(\.cutWord)

        // Sides a slip on a join word backs up, and whether a finding that
        // isn't slip-prone backs up every flag.
        var confirmedSides: Set<CutAudit.Side> = []
        var confirmsAll = false
        for (index, finding) in join.findings.enumerated() {
            if let why = explanation(finding, in: join, said: said, heard: heard, cut: cutWords) {
                verdict.explained[index] = why
                continue
            }
            if !finding.slip { verdict.heardCutOff = true; confirmsAll = true }
            // A slip on the kept word at the join only backs up a flag on
            // that word's side. On the workbench short (19 Nov 2026) "in
            // like | the first wood project", with "the first time" cut,
            // was heard without "like", and that kept the level flag on the
            // start of the clip after the join standing, whose fix put the
            // cut words back.
            let side: CutAudit.Side = finding.time <= join.time ? .before : .after
            // The kept word right at the join on the finding's own side.
            let joinWord = (side == .before ? said.before.last : said.after.first).map(CutListen.canonical)
            let onJoinWord = finding.kind != .extra && finding.said.map { CutListen.canonical($0) == joinWord && !isFiller($0) } == true
                && flags.contains { $0.keeps == side }
            if onJoinWord { confirmedSides.insert(side) }
            if !finding.slip || onJoinWord { verdict.confirming.append(index) }
        }
        guard !confirmsAll else { return verdict }

        // A flag on the other side of the join from a confirmed slip is
        // judged on its own.
        for (index, flag) in flags.enumerated() where !confirmedSides.contains(flag.keeps) {
            if flag.fragment != nil {
                // Hearing the leftover only says it's there: whether it reads
                // wrong is the sentence's, not the sound's.
                continue
            } else if let word = flag.cutWord {
                let side = flag.keeps == .before ? (heard.before.suffix(3), said.before.suffix(3)) : (heard.after.prefix(3), said.after.prefix(3))
                let target = CutListen.canonical(word)
                let heardIt = side.0.filter { CutListen.canonical($0) == target }.count > side.1.filter { CutListen.canonical($0) == target }.count
                if heardIt { verdict.dismissed[index] = "\"\(word)\" is heard, so the cut keeps it" }
            } else if let margin = flag.margin, margin >= heardOver {
                verdict.dismissed[index] = "levels flagged it, but every kept word is heard whole"
            } else if let margin = flag.margin {
                verdict.tooClose[index] = margin
            }
        }
        return verdict
    }

    /// Why the take's own transcript explains a finding, or nil.
    static func explanation(
        _ finding: CutListen.Finding, in join: CutListen.Join, said: (before: [String], after: [String]),
        heard: (before: [String], after: [String]), cut: [String]
    ) -> String? {
        // A cut word heard whole: the transcript has a word just past the
        // edge, the cut keeps all of it. On the Tandem video that was "own",
        // "see", "mistakes,", "yet.", "hat." and "video.".
        func wholeCut(_ text: String) -> String? { cut.first { sameWord($0, text) } }
        let before = finding.time <= join.time
        switch finding.kind {
        case .extra:
            guard let text = finding.heard else { return nil }
            if let word = wholeCut(text) {
                return "the take's transcript has \"\(word)\" just past the edge, in the cut, and it's heard whole: the cut keeps it"
            }
        case .heardAs:
            guard let text = finding.said, let other = finding.heard else { return nil }
            if soundsAlike(text, other) { return "\"\(text)\" and \"\(other)\" sound the same: a spelling, not a cut" }
            // The said word heard whole beside another word the engine lined
            // up with it ("etc" heard as "etcetera", then "anyway").
            let elsewhere = join.findings.contains { extra in
                guard extra.kind == .extra, let heardText = extra.heard else { return false }
                let a = CutListen.canonical(text), b = CutListen.canonical(heardText)
                return a.count >= 3 && b.hasPrefix(a)
            }
            if elsewhere, wholeCut(other) != nil || CutListen.isFunctionWord(other) {
                return "\"\(text)\" is heard next to it, and \"\(other)\" is a word the take's transcript has in the cut, heard whole"
            }
            if let word = wholeCut(other) {
                return "the take's transcript has \"\(word)\" just past the edge, in the cut, and it's heard whole: the cut keeps it"
            }
        case .notHeard:
            guard let text = finding.said else { return nil }
            let side = before ? (said.before, heard.before) : (said.after, heard.after)
            if side.1.isEmpty, side.0.count > 1 {
                return "nothing at all is heard on that side of the join, where the take has \(side.0.count) words: the transcript's, over silence, not a cut-off"
            }
            // A retake, or two tracks' transcripts woven together: the take
            // has the word twice, and it's heard once.
            let target = CutListen.canonical(text)
            let near = before ? Array(side.0.suffix(4)) : Array(side.0.prefix(4))
            if near.filter({ CutListen.canonical($0) == target }).count >= 2, side.1.contains(where: { CutListen.canonical($0) == target }) {
                return "the take's transcript has \"\(text)\" twice here (a retake, or two tracks' words), and it's heard once"
            }
        }
        return nil
    }

    /// The words either side of " | " in a join's said or heard text.
    static func sides(_ text: String) -> (before: [String], after: [String]) {
        let parts = text.components(separatedBy: "|")
        func words(_ part: String) -> [String] { part.split(separator: " ").map(String.init).filter { !CutListen.canonical($0).isEmpty } }
        return (words(parts.first ?? ""), parts.count > 1 ? words(parts[1...].joined(separator: " ")) : [])
    }

    /// The same word, or with an inflection ("mistake" and "mistakes"), but
    /// not a piece of it ("extra" isn't "extract").
    static func sameWord(_ a: String, _ b: String) -> Bool {
        let a = CutListen.canonical(a), b = CutListen.canonical(b)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count >= 3 && long.hasPrefix(short) && CutListen.endings.contains(String(long.dropFirst(short.count)))
    }

    /// Spelled differently, said the same: "mic" and "Mike".
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        func sound(_ text: String) -> String {
            var word = CutListen.canonical(text)
            for (from, to) in [("ck", "k"), ("ph", "f"), ("c", "k"), ("z", "s")] { word = word.replacingOccurrences(of: from, with: to) }
            if word.count > 3, word.hasSuffix("e") { word.removeLast() }
            var squeezed = ""
            for letter in word where squeezed.last != letter { squeezed.append(letter) }
            return squeezed
        }
        let x = sound(a), y = sound(b)
        return !x.isEmpty && x == y
    }

    static let fillers: Set<String> = ["um", "uh", "uhm", "erm", "er", "ah", "oh", "mm", "hmm"]

    static func isFiller(_ text: String) -> Bool { fillers.contains(CutListen.canonical(text)) }
}
