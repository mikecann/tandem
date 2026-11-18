import Foundation

// The proof list: every line Mike says that names something or makes a
// claim, what's on screen over it, and the agent's answer for it, for
// `tandem claims` and the `bareClaim` note in `tandem check`.
//
// The one review comment on every one of his last eight videos is "show
// what I'm saying": "We need to show something here", "justify what I'm
// saying", "Show these on screen, show per user billing pricing", "you
// should show the actual request... while I'm talking about it" (the 1.50.0
// release video's only comment). The skill told agents to read the
// transcript line by line for these, and they still missed the lines he
// ad-libbed. `littleBRoll` only measures how much of the camera is
// covered, not whether each claim has its proof. So the lines are listed
// for the agent to answer one by one (a shot and a link, or why nothing
// needs showing), and the check notes the ones still bare.
//
// What counts was tuned on five finished edits (the Convex Auth v2, Let's
// Build It technical, 1.50.0 release, Exact + Convex and Threadbear launch
// videos): a name that isn't a sentence's first word (Bark capitalises
// products, companies and people well, and a word it mostly writes in lower
// case isn't one), a number, money, a percentage or a version, and phrases
// that point at something real (the docs, a PR, a pricing page, "he says
// here", a command). A name said again within a minute is the same proof,
// and the video's own subject (Convex in a Convex video, said in an eighth
// of its sentences) counts only the first time, or every line would be listed.

/// A line Mike says that names something or makes a checkable claim.
public struct SpokenClaim: Equatable, Sendable {
    /// Stable across cuts that move it: from the line's words.
    public var id: String
    /// The line's words in lower case without fillers, which an answer is
    /// matched back by.
    public var key: String
    public var start: Time
    public var end: Time
    public var said: String
    /// The words that made it a claim.
    public var because: [String]
    /// The clips on screen while he says it, over him or instead of him,
    /// top first: B-roll, a title, the screen recording. Captions and the
    /// camera itself aren't listed.
    public var shownClipIDs: [String]
    /// How much of the line has the camera full screen with nothing over
    /// it, 0 to 1.
    public var bare: Double
    /// The camera clip he's on while he says it, when he's on camera.
    public var cameraClipID: String?

    public init(id: String, key: String, start: Time, end: Time, said: String, because: [String], shownClipIDs: [String] = [], bare: Double = 0, cameraClipID: String? = nil) {
        self.id = id
        self.key = key
        self.start = start
        self.end = end
        self.said = said
        self.because = because
        self.shownClipIDs = shownClipIDs
        self.bare = bare
        self.cameraClipID = cameraClipID
    }
}

/// What an agent answered for a claim: what will show it, the real page,
/// or why nothing needs showing.
public struct ClaimAnswer: Equatable, Sendable {
    /// The claim's ID when it was answered.
    public var id: String?
    /// The line as it was said when it was answered.
    public var said: String
    /// Where it was on the timeline then, to tell apart a line said twice.
    public var at: Time?
    public var shot: String?
    public var link: String?
    public var skip: String?

    public init(id: String? = nil, said: String, at: Time? = nil, shot: String? = nil, link: String? = nil, skip: String? = nil) {
        self.id = id
        self.said = said
        self.at = at
        self.shot = Self.filled(shot)
        self.link = Self.filled(link)
        self.skip = Self.filled(skip)
    }

    /// Something to show, a link, or a reason to show nothing.
    public var isAnswered: Bool { shot != nil || link != nil || skip != nil }

    static func filled(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

extension QualityCheck {
    /// A claim with the camera full screen and nothing over more than this
    /// share of it is bare.
    public static let claimBareShare = 0.5
    /// A pause this long ends a sentence the engine didn't punctuate.
    static let claimSentenceGap = Time(seconds: 1)
    /// A sentence longer than this many words (Bark runs on where Mike
    /// does) is split at its longest pause.
    static let claimLongestSentence = 40
    /// A name or phrase said again this soon counts as the same proof.
    static let claimRepeatWithin = Time(seconds: 60)
    /// A name in at least this share of the sentences (and four of them) is
    /// what the video is about: only its first mention counts.
    static let claimTopicShare = 0.12

    /// Words a sentence can start with that Bark capitalises mid-sentence
    /// when it misses a full stop ("cancel them For a while now", "Out of
    /// the box"), and that are never names on their own.
    static let claimCommonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "if", "then", "i", "i'm", "i've", "i'll", "i'd", "you", "you're", "you've", "you'll",
        "we", "we're", "we've", "we'll", "it", "it's", "its", "is", "are", "was", "were", "be", "been", "being", "to", "of", "in", "on",
        "at", "for", "with", "as", "that", "that's", "this", "these", "those", "there", "there's", "here", "here's", "just", "like",
        "okay", "ok", "yeah", "yes", "well", "really", "now", "next", "also", "because", "when", "what", "what's", "which", "who", "how",
        "why", "where", "let", "let's", "my", "your", "our", "their", "they", "they're", "he", "he's", "she", "she's", "um", "uh", "oh",
        "right", "anyway", "anyways", "first", "second", "third", "finally", "before", "after", "once", "since", "while", "all", "one",
        "no", "not", "maybe", "actually", "basically", "even", "still", "though", "although", "instead", "plus", "hey", "hi", "hello",
        "thanks", "thank", "cheerio", "until", "today", "tomorrow", "out", "from", "by", "up", "down", "over", "under", "into", "onto",
        "off", "about", "can", "could", "should", "would", "will", "shall", "do", "does", "did", "don't", "doesn't", "didn't", "have",
        "has", "had", "me", "him", "her", "them", "us", "cool", "nice", "great", "good", "bad", "yep", "nope", "sure", "hmm", "wow",
        "ah", "oops", "whoops", "god", "some", "any", "every", "each", "many", "much", "more", "most", "other", "another", "such",
        "very", "quite", "pretty", "kind", "sort", "thing", "things", "way", "ways", "time", "times", "bit", "lot", "lots", "go",
        "going", "gonna", "get", "got", "make", "made", "see", "look", "say", "said", "know", "think", "want", "wanna", "need", "use",
        "using", "used", "new", "old", "big", "small", "little", "super", "far", "again", "too", "only", "both", "either", "never",
        "always", "often", "sometimes", "obviously", "hopefully", "honestly", "literally", "definitely", "probably", "apparently",
        "otherwise", "meanwhile", "however", "except", "unless", "whether", "yet", "already", "soon", "later", "earlier", "back"
    ]
    /// Capitalised words that are everywhere in his videos and name nothing
    /// to show on their own.
    static let claimGenericWords: Set<String> = ["ai", "agentic", "api", "apis", "ui", "ux", "url", "urls", "id", "ids", "llm", "llms", "tv"]
    /// Number words big enough to be a claim. One to nine are in every
    /// other sentence ("one thing", "two ways").
    static let claimNumberWords: Set<String> = [
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "hundreds", "thousand", "thousands", "million", "millions",
        "billion", "billions", "percent", "dozens"
    ]
    static let claimDigitWords: Set<String> = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    /// Phrases that point at something real to show, or make a claim that
    /// can be checked: from Mike's comments ("show per user billing
    /// pricing", "the actual request", "Charlie's posts", "v2 is finally
    /// here", "non-beta forever") and his scripts.
    static let claimPhrases: [[String]] = [
        "docs", "documentation", "pull request", "pr", "prs", "pricing page", "pricing", "price", "prices", "priced", "dollar", "dollars",
        "bucks", "cents", "per user", "per month", "a month", "per seat", "billing", "free tier", "free plan", "for free", "it's free",
        "subscription", "cheaper", "expensive", "blog post", "blog", "tweet", "tweeted", "his post", "her post", "their post",
        "this post", "announcement", "announced", "readme", "changelog", "release notes", "repo", "github issue", "website", "landing page",
        "benchmark", "benchmarks", "leaderboard", "paper", "article", "says here", "he says", "she says", "they say", "feature request",
        "request board", "faster", "slower", "quicker", "better than", "worse than", "more than", "less than", "fewer than", "times faster",
        "the fastest", "the cheapest", "nobody else", "no one else", "npx", "npm", "bunx", "dash dash", "actual ad",
        "this file", "this warning", "this error", "this page", "this button", "this command", "this function", "this code",
        "this message", "this email", "this request", "this chart", "this graph", "this table", "this dashboard", "this setting",
        "this ad", "this clip", "this repo", "this link", "this folder", "this prompt", "this card", "this list", "this screen",
        "this tool", "this library", "this package", "this feature", "this issue",
        // A launch or a status, which the docs, the announcement or the old
        // label proves: "it's finally here", "non-beta forever".
        "finally here", "it's here", "is here", "beta", "non-beta", "out now", "is out", "just shipped", "shipped", "launched",
        "brand new", "quick start", "quickstart", "getting started",
        // Something of his to link: "I'll link it".
        "i'll link"
    ].map { $0.split(separator: " ").map(String.init) }
    static let claimFillers: Set<String> = ["um", "uh", "uhm", "er", "erm", "ah", "hmm", "mm", "oh"]

    // MARK: - Finding them

    /// Every line in `speech` that names something or makes a claim, in
    /// timeline order, with what's on screen while it's said.
    public static func claims(in project: Project, speech: Speech) -> [SpokenClaim] {
        var found = claims(in: speech.words, subject: project.name)
        for index in found.indices {
            let cover = claimCover(TimeRange(start: found[index].start, end: found[index].end), in: project)
            found[index].shownClipIDs = cover.shown
            found[index].bare = cover.bare
            found[index].cameraClipID = cover.camera
        }
        return found
    }

    /// The claims in `words` (timeline order), without what's on screen.
    /// `subject` is the project's name: what the video is about, whose
    /// words count only the first time, however Bark spells them
    /// ("Threadbare" in Threadbear Launch).
    public static func claims(in words: [Speech.Word], subject: String = "") -> [SpokenClaim] {
        let sentences = claimSentences(words)
        let tokens = sentences.map { $0.map { cleanToken(words[$0].text) } }
        let names = learnedNames(tokens)
        let subjectWords = subject.split(separator: " ").map { cleanToken(String($0)).lowercased() }.filter { $0.count >= 3 && !claimCommonWords.contains($0) }

        // The project name's own word for any spelling of it, so
        // "Threadbare" is the same mention as "Threadbear".
        func canonical(_ key: String) -> String {
            subjectWords.first { isSubject(key, [$0]) } ?? key
        }
        // What each sentence mentions, to find the video's own subject.
        func keys(_ sentence: [String]) -> Set<String> {
            let lower = sentence.map { $0.lowercased() }
            var found = Set(lower.filter { names.contains($0) || isNumber($0) }.map(canonical))
            for phrase in claimPhrases where contains(phrase, in: lower) { found.insert(phrase.joined(separator: " ")) }
            return found
        }
        var mentions: [String: Int] = [:]
        for sentence in tokens { for key in keys(sentence) { mentions[key, default: 0] += 1 } }
        let least = max(4, Int((claimTopicShare * Double(sentences.count)).rounded(.up)))
        let topics = Set(mentions.filter { $0.value >= least || isSubject($0.key, subjectWords) }.keys)

        var lastSaid: [String: Time] = [:]
        // Counts a mention unless it's the same proof as one just before:
        // the same name within a minute, or the subject after its first time.
        func counts(_ said: String, at time: Time) -> Bool {
            let key = canonical(said)
            defer { lastSaid[key] = time }
            guard let last = lastSaid[key] else { return true }
            return !topics.contains(key) && time - last > claimRepeatWithin
        }

        var claims: [SpokenClaim] = []
        var seen: [String: Int] = [:]
        for (sentence, said) in zip(sentences, tokens) {
            let lower = said.map { $0.lowercased() }
            var because: [String] = []
            func add(_ text: String) { if !because.contains(where: { $0.lowercased() == text.lowercased() }) { because.append(text) } }
            var index = 0
            while index < said.count {
                defer { index += 1 }
                let token = said[index], low = lower[index]
                guard !token.isEmpty else { continue }
                let time = words[sentence[index]].start
                if isNumber(low) || names.contains(low) {
                    // A run of names is one: Snake Math Rescue, Better Auth.
                    var end = index
                    while end + 1 < said.count, names.contains(lower[end + 1]) { end += 1 }
                    let fresh = (index...end).filter { counts(lower[$0], at: time) }
                    if !fresh.isEmpty { add(said[index...end].joined(separator: " ")) }
                    index = end
                    continue
                }
                // A version said out loud: "one dot five zero".
                if claimDigitWords.contains(low), index + 2 < said.count, ["dot", "point"].contains(lower[index + 1]), claimDigitWords.contains(lower[index + 2]) {
                    add(said[index...(index + 2)].joined(separator: " "))
                    index += 2
                    continue
                }
                // Code: camelCase or dotted names (useQuery, Next.js, convex.dev).
                if token.range(of: #"[a-z][A-Z]|\w\.\w"#, options: .regularExpression) != nil { add(token) }
            }
            for phrase in claimPhrases {
                guard let at = firstIndex(of: phrase, in: lower) else { continue }
                let key = phrase.joined(separator: " ")
                if counts(key, at: words[sentence[at]].start) { add(key) }
            }
            guard !because.isEmpty, let first = sentence.first, let last = sentence.last else { continue }
            let key = claimKey(said)
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            claims.append(SpokenClaim(
                id: claimID(key) + (count > 1 ? "-\(count)" : ""), key: key, start: words[first].start, end: words[last].end,
                said: sentence.map { words[$0].text }.joined(separator: " "), because: because
            ))
        }
        return claims
    }

    /// The words in sentences, by index: ended by a full stop, question or
    /// exclamation mark, a pause of a second or more, or a common word Bark
    /// capitalised where it missed a full stop. Fragments of a word or two
    /// ("Oh.", "m.") go with the sentence after them, and a run-on longer
    /// than `claimLongestSentence` words is split at its longest pauses.
    static func claimSentences(_ words: [Speech.Word]) -> [[Int]] {
        var sentences: [[Int]] = []
        var current: [Int] = []
        for index in words.indices {
            let text = words[index].text.trimmingCharacters(in: .whitespaces)
            if let last = current.last {
                let before = words[last].text.trimmingCharacters(in: .whitespaces)
                let token = cleanToken(text)
                let restarts = token.first?.isUppercase == true && claimCommonWords.contains(token.lowercased()) && token.lowercased() != "i"
                    && !(before.last.map { ",;:".contains($0) } ?? false)
                if words[index].start - words[last].end >= claimSentenceGap || restarts {
                    sentences.append(current)
                    current = []
                }
            }
            current.append(index)
            if let end = text.last, ".?!".contains(end) {
                sentences.append(current)
                current = []
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var merged: [[Int]] = []
        var carried: [Int] = []
        for sentence in sentences {
            let whole = carried + sentence
            carried = []
            if whole.count <= 2 {
                carried = whole
                continue
            }
            merged.append(whole)
        }
        if !carried.isEmpty {
            if merged.isEmpty { merged.append(carried) } else { merged[merged.count - 1] += carried }
        }
        return merged.flatMap { splitRunOn($0, words: words) }
    }

    /// A run-on split at its longest pauses until each piece is short enough.
    static func splitRunOn(_ sentence: [Int], words: [Speech.Word]) -> [[Int]] {
        guard sentence.count > claimLongestSentence else { return [sentence] }
        // The longest pause away from the very ends.
        let edge = 3
        var best: Int?
        var longest = Time.zero
        for position in edge..<(sentence.count - edge) {
            let gap = words[sentence[position]].start - words[sentence[position - 1]].end
            if gap > longest { longest = gap; best = position }
        }
        guard let best else { return [sentence] }
        return splitRunOn(Array(sentence[..<best]), words: words) + splitRunOn(Array(sentence[best...]), words: words)
    }

    /// Names learned from the whole transcript: words Bark capitalises
    /// where they aren't a sentence's first word, at least half as often as
    /// it writes them in lower case (so "Clerk" counts said as "clerk" too,
    /// and "Build" in "Let's Build It" doesn't make every "build" a name),
    /// and whatever he says something is "called".
    static func learnedNames(_ sentences: [[String]]) -> Set<String> {
        var capitalised: [String: Int] = [:]
        var lowerCase: [String: Int] = [:]
        for sentence in sentences {
            for (position, token) in sentence.enumerated() {
                let low = token.lowercased()
                guard let first = token.first, !isNumber(low), !claimCommonWords.contains(low), !claimGenericWords.contains(low), first.isLetter else { continue }
                if first.isUppercase {
                    if position > 0 { capitalised[low, default: 0] += 1 }
                } else {
                    lowerCase[low, default: 0] += 1
                }
            }
        }
        var names = Set(capitalised.filter { Double($0.value) >= 0.5 * Double(lowerCase[$0.key] ?? 0) }.keys)
        for sentence in sentences {
            let lower = sentence.map { $0.lowercased() }
            for position in lower.indices.dropLast() where ["called", "named"].contains(lower[position]) {
                let next = lower[position + 1]
                if !next.isEmpty, !claimCommonWords.contains(next), !claimFillers.contains(next) { names.insert(next) }
            }
        }
        return names
    }

    /// Whether `key` is one of the project name's words, or Bark's spelling
    /// of one: within two letters for a long word, one for a short one.
    static func isSubject(_ key: String, _ subject: [String]) -> Bool {
        subject.contains { word in
            let allowed = min(word.count, key.count) >= 6 ? 2 : (min(word.count, key.count) >= 4 ? 1 : 0)
            return editDistance(key, word, atMost: allowed) <= allowed
        }
    }

    /// Levenshtein distance, stopping early once it's past `atMost`.
    static func editDistance(_ a: String, _ b: String, atMost limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if (current.min() ?? 0) > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }

    /// A word's text without the punctuation around it, keeping a leading $
    /// and a trailing %.
    static func cleanToken(_ text: String) -> String {
        var scalars = Substring(text)
        while let first = scalars.first, !(first.isLetter || first.isNumber || first == "$") { scalars = scalars.dropFirst() }
        while let last = scalars.last, !(last.isLetter || last.isNumber || last == "%") { scalars = scalars.dropLast() }
        return String(scalars)
    }

    static func isNumber(_ token: String) -> Bool {
        token.contains { $0.isNumber } || token.contains("$") || token.contains("%") || claimNumberWords.contains(token)
    }

    static func contains(_ phrase: [String], in tokens: [String]) -> Bool {
        firstIndex(of: phrase, in: tokens) != nil
    }

    static func firstIndex(of phrase: [String], in tokens: [String]) -> Int? {
        guard tokens.count >= phrase.count else { return nil }
        for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<(start + phrase.count)]) == phrase { return start }
        return nil
    }

    /// The line's words in lower case, without fillers or punctuation: what
    /// an answer is matched back by after a cut moves the line.
    public static func claimKey(_ said: String) -> String {
        claimKey(said.split(separator: " ").map { cleanToken(String($0)) })
    }

    static func claimKey(_ tokens: [String]) -> String {
        tokens.map { $0.lowercased() }.filter { !$0.isEmpty && !claimFillers.contains($0) }.joined(separator: " ")
    }

    /// A short ID from the line's words (FNV-1a, which unlike Swift's own
    /// hashing is the same from one run to the next).
    static func claimID(_ key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "c" + String(String(hash, radix: 16).suffix(6)).leftPadded(to: 6)
    }

    // MARK: - What's on screen

    /// What's on screen over `range`, sampled as `littleBRoll` samples it:
    /// the clips shown over the camera or in its place, top first, and how
    /// much of it has the camera full screen with nothing over it.
    static func claimCover(_ range: TimeRange, in project: Project) -> (shown: [String], bare: Double, camera: String?) {
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tracks = project.videoTracks.reversed().filter { !$0.hidden && !Editing.isPrivacyTrack($0) }
        var shown: [String] = []
        var steps = 0, bareSteps = 0
        var cameras: [String: Int] = [:]
        var time = range.start
        while time < range.end || steps == 0 {
            defer { time = time + brollStep; steps += 1 }
            var over = false
            for track in tracks {
                guard let clip = track.clip(at: time), clip.enabled else { continue }
                if case .adjustment = clip.content { continue }
                if isCaption(clip, on: track) { continue }
                let item = clip.mediaID.flatMap { media[$0] }
                if track.rippleMode == .cut {
                    // Only the camera is him talking. The screen recording, a
                    // finished video played in the take (Let's Build It's
                    // launch video) or phone footage shows something instead.
                    if item?.role == .camera {
                        if cameraFullScreen(clip, item: item, at: time, in: project) {
                            cameras[clip.id, default: 0] += 1
                            if !over { bareSteps += 1 }
                            break
                        }
                        // Him small in the corner: what's under him shows.
                        continue
                    }
                    if !shown.contains(clip.id) { shown.append(clip.id) }
                    break
                }
                over = true
                if !shown.contains(clip.id) { shown.append(clip.id) }
            }
        }
        let camera = cameras.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        return (shown, Double(bareSteps) / Double(max(steps, 1)), camera)
    }

    // MARK: - Answers

    /// Each claim's answer, matched by its words: the same words first, then
    /// a line most of whose words are the same (a cut took a word or two),
    /// the nearest in time when several are. Returns the answers by claim
    /// ID and those whose line is no longer said.
    public static func match(_ claims: [SpokenClaim], answers: [ClaimAnswer]) -> (byClaim: [String: ClaimAnswer], unmatched: [ClaimAnswer]) {
        var byClaim: [String: ClaimAnswer] = [:]
        var left = Array(answers.indices)
        func nearest(_ candidates: [Int], to claim: SpokenClaim) -> Int? {
            candidates.min { a, b in
                let da = answers[a].at.map { abs(($0 - claim.start).seconds) } ?? .infinity
                let db = answers[b].at.map { abs(($0 - claim.start).seconds) } ?? .infinity
                return da < db
            }
        }
        // The same words (and the same ID, for a line said twice).
        for claim in claims {
            let same = left.filter { claimKey(answers[$0].said) == claim.key }
            // A line said twice is told apart by time, not by its ID: IDs
            // number the repeats in order, so cutting the first one would
            // give the second its answer.
            let pick = nearest(same, to: claim) ?? same.first { answers[$0].id == claim.id }
            guard let pick else { continue }
            byClaim[claim.id] = answers[pick]
            left.removeAll { $0 == pick }
        }
        // Most of the words the same.
        for claim in claims where byClaim[claim.id] == nil {
            let words = Set(claim.key.split(separator: " "))
            let mine = anchors(claim.said)
            let close = left.filter { index in
                let theirs = Set(claimKey(answers[index].said).split(separator: " "))
                guard !words.isEmpty, !theirs.isEmpty else { return false }
                // "ten dollars" isn't "twenty dollars", nor Clerk WorkOS:
                // a near match keeps the same numbers and names.
                guard anchors(answers[index].said) == mine else { return false }
                return 2 * Double(words.intersection(theirs).count) / Double(words.count + theirs.count) >= 0.6
            }
            guard let pick = nearest(close, to: claim) ?? close.first else { continue }
            byClaim[claim.id] = answers[pick]
            left.removeAll { $0 == pick }
        }
        return (byClaim, left.map { answers[$0] })
    }

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "percent", "half", "no", "not", "never",
    ]

    /// What a near match must keep: the numbers (and "not" and "never"),
    /// and the names, words capitalised after the line's first.
    static func anchors(_ said: String) -> Set<String> {
        let words = said.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        var found = Set<String>()
        for (index, word) in words.enumerated() {
            let lower = word.lowercased()
            if word.contains(where: \.isNumber) || numberWords.contains(lower) || lower.hasSuffix("n't") {
                found.insert(lower)
            } else if index > 0, word != "I", word.first?.isUppercase == true {
                found.insert(lower)
            }
        }
        return found
    }

    // MARK: - The check

    /// A note for each claim in `ranges` said with the camera full screen
    /// and nothing over most of it, unless its answer says why nothing needs
    /// showing. Not in a Short, whose picture is laid out by its own rules
    /// (the screen over the camera, his face for the first seconds' hook)
    /// and whose claims are proven in the video it's cut from, nor in a
    /// conversation, where the people talking are the picture.
    public static func bareClaims(in project: Project, ranges: [TimeRange], speech: Speech, answers: [ClaimAnswer]?) -> [CheckProblem] {
        guard project.settings.width >= project.settings.height, !speech.words.isEmpty, !isConversation(project, speech: speech) else { return [] }
        let found = claims(in: project, speech: speech)
        let matched = match(found, answers: answers ?? []).byClaim
        return found.compactMap { claim in
            let range = TimeRange(start: claim.start, end: claim.end)
            guard claim.bare > claimBareShare, ranges.contains(where: { $0.overlaps(range) }) else { return nil }
            let answer = matched[claim.id]
            if answer?.skip != nil { return nil }
            let line = claim.said.count > 160 ? String(claim.said.prefix(160)) + "..." : claim.said
            var message = "Bare claim at \(claim.start): \"\(line)\" (\(claim.because.joined(separator: ", "))), with the camera full screen and nothing over it."
            if let shot = answer?.shot {
                message += " The claims list plans \"\(shot)\" for it, but nothing is over the camera there yet: place it as he says it."
            } else {
                message += " Show it as he says it, or answer it in the claims list (tandem claims): a shot and a link, or skip with why nothing needs showing."
            }
            return CheckProblem(kind: .bareClaim, start: claim.start, end: claim.end, message: message, clipIDs: claim.cameraClipID.map { [$0] } ?? [])
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
