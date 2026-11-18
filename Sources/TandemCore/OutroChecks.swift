import Foundation

// The outro's stings and wipe, for `tandem check`.
//
// Mike's finished solo videos put the library's "Comment below" segment on
// screen as he asks for comments, "Like and subscribe" as he asks for
// those, and a Convex wipe (or a section card) into the outro: "I want
// section swipes, particularly the outro, intro, etc." Agents left them out
// of first cuts round after round, and the rule only lived in the skill,
// so the check reads the transcript for the asks and the timeline for the
// segments, and notes what's missing with the command that puts it in.

extension QualityCheck {
    /// A sting this far either side of what's said goes with it.
    public static let outroStingReach = Time(seconds: 4)
    /// A sting goes in this far before the words it goes with.
    public static let outroStingLead = Time(seconds: 0.3)
    /// "Subscribe" on its own counts as the ask this close to the end;
    /// earlier it's as likely a query subscribing to data.
    public static let outroSubscribeReach = Time(seconds: 120)
    /// The sign-off is looked for in this last share of the timeline.
    public static let outroShare = 0.25
    /// A card, a wipe segment or a wipe transition this long before the
    /// sign-off takes the viewer into the outro.
    public static let outroWipeReach = Time(seconds: 60)
    /// The Convex wipe covers the frame from 0.38 to 0.55 s, so the cut
    /// under it goes this far in (the skill's "A Convex wipe without a card").
    public static let convexWipeCut = Time(seconds: 0.47)

    static let commentAsks: [[String]] = [
        ["comment", "below"], ["comments", "below"], ["comment", "down", "below"], ["comments", "down", "below"],
        ["let", "me", "know", "in", "the", "comments"], ["let", "us", "know", "in", "the", "comments"], ["leave", "a", "comment"],
        ["drop", "a", "comment"]
    ]
    static let subscribeAsks: [[String]] = [["like", "and", "subscribe"], ["like", "and", "sub"], ["hit", "subscribe"], ["hit", "that", "subscribe"]]
    static let signOffs: [[String]] = [
        ["thanks", "for", "watching"], ["thank", "you", "for", "watching"], ["see", "you", "next", "time"], ["see", "you", "in", "the", "next"],
        ["until", "next", "time"], ["catch", "you"],
        // How he starts winding up: "anyways, I think that's it for this
        // one", "that's all I got for you guys".
        ["that's", "it", "for", "this", "one"], ["thats", "it", "for", "this", "one"], ["that's", "all", "i", "got"], ["thats", "all", "i", "got"],
        ["that's", "it", "for", "today"], ["that's", "all", "for", "today"],
        // His own goodbye, last in nearly every video, and the word he
        // winds up with ("So yeah, anyways, super early days for Exact").
        ["cheerio"], ["anyways"]
    ]
    /// Asks and goodbyes closer together than this are one sign-off.
    static let outroCluster = Time(seconds: 30)

    /// A phrase said, timeline time.
    struct Said: Equatable {
        var start: Time
        var end: Time
        var words: String
    }

    /// The library segments the outro wants, by the name `tandem segments`
    /// gives them.
    enum Sting: String {
        case commentBelow = "Comment below"
        case likeAndSubscribe = "Like and subscribe"
        case convexWipe = "Convex wipe"
    }

    /// A note for each ask for comments with no "Comment below" segment
    /// near it, and each ask to like and subscribe in the last couple of
    /// minutes with no "Like and subscribe", in `ranges`. Not in a Short or
    /// a conversation, whose outros are other people's or cut away.
    public static func outroStings(in project: Project, ranges: [TimeRange], speech: Speech) -> [CheckProblem] {
        guard isSoloLandscape(project, speech: speech) else { return [] }
        let tokens = outroTokens(speech)
        let end = speech.words.last?.end ?? project.duration
        var found: [CheckProblem] = []
        func check(_ asks: [Said], _ sting: Sting, what: String) {
            let placed = stingClips(sting, in: project)
            var noted: Time?
            for ask in asks {
                // Judged where a check reaches the stretch the sting goes
                // in: a sting taken out is a change just beside the words.
                let near = TimeRange(start: ask.start - outroStingReach, end: ask.end + outroStingReach)
                guard ranges.contains(where: { $0.overlaps(near) }) else { continue }
                guard !placed.contains(where: { $0.range.overlaps(near) }) else { continue }
                // Said twice in a breath ("leave a comment, comment below")
                // is one ask.
                if let last = noted, ask.start - last < outroStingReach { continue }
                noted = ask.start
                // Mike starts it a moment before the words: 0.2 to 0.8 s
                // on Auth v2, 1.50 and Let's Build It.
                let at = max(.zero, ask.start - outroStingLead)
                found.append(CheckProblem(
                    kind: .outroSting, start: ask.start, end: ask.end,
                    message: "No \"\(sting.rawValue)\" segment where he says \"\(ask.words)\": Mike's finished videos put it on screen as he \(what). tandem segments insert \"\(sting.rawValue)\" --at \(at)"
                ))
            }
        }
        check(find(commentAsks, in: tokens), .commentBelow, what: "asks for comments")
        // Near the end only: Bark heard "like and sub" in the middle of
        // the Auth v2 demo, where he said nothing of the kind.
        let subscribing = (find(subscribeAsks, in: tokens) + soleSubscribes(tokens)).filter { end - $0.start <= outroSubscribeReach }
        check(subscribing.sorted { $0.start < $1.start }, .likeAndSubscribe, what: "asks people to like and subscribe")
        return found
    }

    /// A note at the sign-off (the first ask or goodbye in the last quarter)
    /// when nothing takes the viewer into the outro in the minute before it:
    /// no section card, Convex wipe segment or wipe transition. Only in an
    /// edit with sections (a card, a wipe or a section marker somewhere
    /// else): a three-minute release video in one piece, like Convex 1.50,
    /// signs off without one.
    public static func outroWipe(in project: Project, ranges: [TimeRange], speech: Speech) -> [CheckProblem] {
        guard isSoloLandscape(project, speech: speech), let signOff = signOff(in: project, speech: speech) else { return [] }
        let (cut, sentence) = cutBefore(signOff.start, in: project, speech: speech)
        // Judged where a check reaches the cut the wipe goes over or the
        // sign-off itself: a wipe taken out is a change just before it.
        let spot = TimeRange(start: cut - Time(seconds: 1), end: max(signOff.end, cut + Time(seconds: 1)))
        guard ranges.contains(where: { $0.overlaps(spot) }) else { return [] }
        let before = TimeRange(start: signOff.start - outroWipeReach, end: signOff.start + Time(seconds: 2))
        if hasWipe(in: project, over: before) { return [] }
        let earlier = TimeRange(start: .zero, end: before.start)
        let sectioned = earlier.duration > .zero && hasWipe(in: project, over: earlier)
            || project.markers.contains { $0.kind == .section && $0.time > .zero }
        guard sectioned else { return [] }
        let at = max(.zero, cut - convexWipeCut)
        var quoted = speech.words.filter { $0.start >= sentence }.prefix(8).map(\.text).joined(separator: " ")
        if quoted.isEmpty { quoted = signOff.words }
        return [CheckProblem(
            kind: .outroWipe, start: cut, end: signOff.end,
            message: "No wipe into the outro: nothing in the minute before the sign-off (\"\(quoted)...\"), no section card, Convex wipe or wipe transition. Mike wants a section wipe into the outro. tandem segments insert \"Convex wipe\" --at \(at) (the cut at \(cut) goes 0.47 s in)"
        )]
    }

    /// Landscape, and one person talking.
    static func isSoloLandscape(_ project: Project, speech: Speech) -> Bool {
        project.settings.width >= project.settings.height && !speech.words.isEmpty && !isConversation(project, speech: speech)
    }

    /// The first goodbye or ask in the last quarter of the talk.
    ///
    /// The last run of them, that is: Auth v2 asks for comments at 5:32,
    /// after a section's wipe, and signs off at 6:53 after its own.
    static func signOff(in project: Project, speech: Speech) -> Said? {
        let tokens = outroTokens(speech)
        let end = speech.words.last?.end ?? project.duration
        let from = Time(seconds: end.seconds * (1 - outroShare))
        let candidates = (find(commentAsks + subscribeAsks + signOffs, in: tokens) + soleSubscribes(tokens))
            .filter { $0.start >= from }.sorted { $0.start < $1.start }
        guard var first = candidates.last else { return nil }
        for said in candidates.reversed().dropFirst() {
            guard first.start - said.start <= outroCluster else { break }
            first = said
        }
        return first
    }

    /// The words as plain lowercase tokens, with where each was said.
    static func outroTokens(_ speech: Speech) -> [(text: String, start: Time, end: Time, stop: Bool)] {
        speech.words.flatMap { word -> [(text: String, start: Time, end: Time, stop: Bool)] in
            let stop = word.text.trimmingCharacters(in: .whitespaces).last.map { ".!?".contains($0) } ?? false
            let pieces = word.text.lowercased().replacingOccurrences(of: "’", with: "'").split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
            return pieces.enumerated().map { index, piece in (piece, word.start, word.end, stop && index == pieces.count - 1) }
        }
    }

    static func find(_ phrases: [[String]], in tokens: [(text: String, start: Time, end: Time, stop: Bool)]) -> [Said] {
        var found: [Said] = []
        for index in tokens.indices {
            for phrase in phrases where index + phrase.count <= tokens.count {
                guard (0..<phrase.count).allSatisfy({ tokens[index + $0].text == phrase[$0] }) else { continue }
                found.append(Said(start: tokens[index].start, end: tokens[index + phrase.count - 1].end, words: phrase.joined(separator: " ")))
                break
            }
        }
        return found
    }

    /// "Subscribe" asked for on its own: "make sure you subscribe", "and
    /// subscribe to the channel". Not "subscribes", nor "subscribe to the
    /// query", which is Convex, not a sign-off.
    static func soleSubscribes(_ tokens: [(text: String, start: Time, end: Time, stop: Bool)]) -> [Said] {
        var found: [Said] = []
        for index in tokens.indices where tokens[index].text == "subscribe" {
            if index > 0, ["like", "hit", "that"].contains(tokens[index - 1].text) { continue }
            let following = tokens[(index + 1)..<min(tokens.count, index + 4)].map(\.text)
            let asks = tokens[index].stop || following.isEmpty || ["for", "and", "if"].contains(following[0])
                || (following[0] == "to" && following.contains("channel"))
            guard asks else { continue }
            found.append(Said(start: tokens[index].start, end: tokens[index].end, words: "subscribe"))
        }
        return found
    }

    /// Clips of a library segment: the ones it put in (tagged
    /// `template:segment:<name>`), or its picture placed by hand.
    static func stingClips(_ sting: Sting, in project: Project) -> [Clip] {
        let tag = "template:segment:\(sting.rawValue)".lowercased()
        let file = plain(sting == .likeAndSubscribe ? "Like and subscribe button" : sting == .convexWipe ? "convex-wipe" : sting.rawValue)
        return project.allTracks.filter { !$0.hidden }.flatMap(\.clips).filter { clip in
            guard clip.enabled else { return false }
            if clip.tags.contains(where: { $0.lowercased() == tag }) { return true }
            guard let mediaID = clip.mediaID, let item = project.media(mediaID) else { return false }
            return plain(URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent).contains(file)
        }
    }

    static func plain(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A section card, a Convex wipe segment or a wipe transition over
    /// any of `stretch`.
    static func hasWipe(in project: Project, over stretch: TimeRange) -> Bool {
        let shown = project.videoTracks.filter { !$0.hidden }
        for track in shown {
            for clip in track.clips where clip.enabled && clip.range.overlaps(stretch) {
                if case .graphic(let graphic) = clip.content, graphic.template == SectionCard.template { return true }
            }
        }
        if stingClips(.convexWipe, in: project).contains(where: { $0.range.overlaps(stretch) }) { return true }
        var clips: [String: Clip] = [:]
        for track in project.allTracks { for clip in track.clips { clips[clip.id] = clip } }
        for track in shown {
            for transition in track.transitions where transition.type == .wipe {
                guard let span = ReviewLog.span(of: transition, clips: clips) else { continue }
                if TimeRange(start: span.start, end: max(span.end, span.start + Time(seconds: 0.001))).overlaps(stretch) { return true }
            }
        }
        return false
    }

    /// The last join in the take before the sentence `time` is in starts:
    /// where a wipe goes. Without one close by, where the sentence starts.
    /// Also where the sentence starts.
    static func cutBefore(_ time: Time, in project: Project, speech: Speech) -> (cut: Time, sentence: Time) {
        // Back to the start of the sentence: a full stop, or a pause of
        // 0.6 s (tightened edits leave about that between sentences, and
        // Bark often leaves the full stop out), before it.
        var start = time
        if let index = speech.words.lastIndex(where: { $0.start <= time }) {
            var i = index
            while i > 0 {
                let previous = speech.words[i - 1]
                if previous.text.last.map({ ".!?".contains($0) }) == true || speech.words[i].start - previous.end >= Time(seconds: 0.6) { break }
                i -= 1
            }
            start = speech.words[i].start
        }
        let joins = project.videoTracks.filter { !$0.hidden && $0.rippleMode == .cut }.flatMap { track in
            track.clips.filter(\.enabled).map(\.start)
        }
        let reach = Time(seconds: 15)
        return (joins.filter { $0 <= start + Time(seconds: 0.1) && start - $0 <= reach && $0 > .zero }.max() ?? start, start)
    }
}
