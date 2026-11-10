import Foundation

// How much B-roll covers the camera, for `tandem check`.
//
// The skill says the first hand-back has everything in, "the cut plus
// B-roll, sound effects and music, never a dialogue-only cut first", and
// agents still hand back a talking head. On the Exact + Convex demo (10 Nov
// 2026) the first round had two shots over 36 s of Mike on camera, none
// on what he named (Let's Build It, Expo's post, Exact's README), and he
// asked "How come you aren't adding the B-roll as usual?" His finished solo
// edits cover 35% (Threadbear launch) to 86% (Convex 1.49) of the time he's
// on camera full screen, at seven to nine shots a minute of it; that round
// covered 19%. So the check measures it, as a note: how much B-roll a
// stretch wants is a judgement call, but none at all never is.

extension QualityCheck {
    /// Less of the camera full screen than this with anything over it is
    /// little B-roll. Mike's least covered finished solo edit is 35%.
    public static let brollLeastCovered = 0.25
    /// The camera has to be full screen this long in the stretches checked
    /// for the note: a short change, or an edit that's mostly a screen
    /// recording, isn't judged.
    public static let brollLeastCameraTime = Time(seconds: 30)
    /// Bare stretches at least this long are listed, longest first.
    static let brollBareListed = Time(seconds: 6)
    static let brollStep = Time(seconds: 0.25)

    /// A note when B-roll covers little or none of the time the camera is
    /// full screen in `ranges`, with the longest bare stretches and what's
    /// said in them. Anything shown over the camera counts: B-roll, a
    /// picture-in-picture, a phone frame, a title or a section card, but
    /// not captions. Not in a Short or a conversation, which are cut from
    /// the talk itself.
    public static func littleBRoll(in project: Project, ranges: [TimeRange], speech: Speech) -> [CheckProblem] {
        guard project.settings.width >= project.settings.height, !speech.words.isEmpty, !isConversation(project, speech: speech) else { return [] }
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tracks = project.videoTracks.reversed().filter { !$0.hidden && !Editing.isPrivacyTrack($0) }
        var cameraTime = 0.0, coveredTime = 0.0
        var shots = Set<String>()
        var bare: [(range: TimeRange, clipID: String)] = []
        var run: (start: Time, end: Time, clipID: String)?
        var first: Time?, last: Time?
        let step = brollStep
        for range in ranges {
            var time = range.start
            while time < range.end {
                defer { time = time + step }
                var over: Clip?
                var camera: Clip?
                for track in tracks {
                    guard let clip = track.clip(at: time), clip.enabled else { continue }
                    if case .adjustment = clip.content { continue }
                    if isCaption(clip, on: track) { continue }
                    if track.rippleMode == .cut {
                        if cameraFullScreen(clip, item: clip.mediaID.flatMap { media[$0] }, at: time, in: project) { camera = clip }
                        break
                    }
                    over = over ?? clip
                }
                guard let camera else {
                    if let open = run { bare.append((TimeRange(start: open.start, end: open.end), open.clipID)) }
                    run = nil
                    continue
                }
                cameraTime += step.seconds
                first = first ?? time
                last = time + step
                if let over {
                    coveredTime += step.seconds
                    shots.insert(over.id)
                    if let open = run { bare.append((TimeRange(start: open.start, end: open.end), open.clipID)) }
                    run = nil
                } else {
                    run = run.map { ($0.start, time + step, $0.clipID) } ?? (time, time + step, camera.id)
                }
            }
            if let open = run { bare.append((TimeRange(start: open.start, end: open.end), open.clipID)) }
            run = nil
        }
        guard cameraTime >= brollLeastCameraTime.seconds, let first, let last else { return [] }
        let share = coveredTime / cameraTime
        guard share < brollLeastCovered else { return [] }

        let longest = bare.filter { $0.range.duration >= brollBareListed }.sorted { $0.range.duration > $1.range.duration }.prefix(3)
        let stretches = longest.map { piece -> String in
            let said = speech.words.filter { piece.range.contains($0.start) }.prefix(14).map(\.text).joined(separator: " ")
            return "\(piece.range.start)-\(piece.range.end) (\(seconds(piece.range.duration))) \"\(said)...\""
        }
        let onCamera = seconds(Time(seconds: cameraTime))
        var message: String
        if shots.isEmpty {
            message = "No B-roll: \(onCamera) on camera full screen and nothing shown over any of it."
        } else {
            message = "Little B-roll: \(percent(share)) of the \(onCamera) on camera full screen has anything over it (\(shots.count) shot\(shots.count == 1 ? "" : "s")). Mike's finished talking edits cover 35 to 85%."
        }
        message += " The first hand-back has everything in: show what he names as he says it (the product, the post, the page)."
        if !stretches.isEmpty { message += " Longest bare: " + stretches.joined(separator: "; ") }
        return [CheckProblem(kind: .littleBRoll, start: first, end: last, message: message, clipIDs: longest.first.map { [$0.clipID] } ?? [])]
    }

    /// A take clip of the camera (not the screen recording) that fills the
    /// frame: a picture-in-picture over the screen doesn't count.
    static func cameraFullScreen(_ clip: Clip, item: MediaItem?, at time: Time, in project: Project) -> Bool {
        guard let item, item.role != .screen, item.hasVideo else { return false }
        guard let box = onScreen(clip, item: item, at: time, in: project) else { return false }
        let slack = 0.01
        return box.x0 <= slack && box.y0 <= slack && box.x1 >= 1 - slack && box.y1 >= 1 - slack
    }

    /// Captions don't show anything new: word-timed text, or text on a
    /// captions track.
    static func isCaption(_ clip: Clip, on track: Track) -> Bool {
        guard case .text(let text) = clip.content else { return false }
        return text.words != nil || track.name.lowercased().contains("caption")
    }
}
