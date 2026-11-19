import Foundation

extension QualityCheck {
    /// Where the picture and the voice of one take play the same file at
    /// different moments: the lips out of step with the words.
    ///
    /// On the workbench short (19 Nov 2026) a `holdFrame` split the camera
    /// into pieces sharing the voice's link group, and a later linked ripple
    /// trim moved each piece's edge, leaving the camera 0.2 to 0.4 s behind
    /// the voice from 0:10 to the end. Mike saw the lips. Nothing in the
    /// check did: the frames rendered fine, the cuts heard fine, and `sync
    /// --check` saw no mouth move. It's in the model, though: a camera clip
    /// over a voice clip of its file should map each moment to the same
    /// place in the file.
    ///
    /// So for each camera clip shown, the sound of its own take linked to
    /// it and under it (or, for an unlinked camera clip on a cut track, any
    /// sound of its file under it, when none of it is in step) playing the
    /// file at a different moment is a problem, compared at both ends of where they overlap (speeds can
    /// differ). The next clip's sound under an L-cut isn't its voice, and a
    /// shot of the take on a follow track (B-roll of his hands) is a
    /// cutaway. Only sound that's heard there counts: a muted or silent
    /// clip, a muted track or one left out by another's solo isn't the
    /// voice. Freeze frames hold on purpose, and privacy copies and hidden
    /// clips aren't seen. The fix slips the camera clip to the voice's
    /// offset, when one voice clip covers all of it at the same speed, its
    /// file has the frames, its track isn't locked and no copy of it on
    /// another track would be left behind.
    public static func pictureOffVoice(in project: Project, ranges: [TimeRange]) -> [CheckProblem] {
        let frame = project.settings.frameRate.frameDuration
        let slack = frame.seconds / 2
        var voices: [String: [Clip]] = [:]
        let soloing = project.audioTracks.contains { $0.solo && !$0.muted }
        for track in project.audioTracks where !track.muted && (!soloing || track.solo) {
            for clip in track.clips where clip.enabled && !(clip.audio?.muted ?? false) && clip.duration > .zero && !clip.freezeFrame {
                if let id = clip.mediaID { voices[id, default: []].append(clip) }
            }
        }
        var found: [CheckProblem] = []
        for track in project.videoTracks where !track.hidden && !track.isPrivacy {
            for picture in track.clips where picture.enabled && picture.duration > .zero && !picture.freezeFrame && !picture.isObscured
                && (picture.video?.opacity ?? 1) > 0.01 {
                guard let mediaID = picture.mediaID, let item = project.media(mediaID), item.hasVideo,
                      let heard = voices[mediaID] else { continue }
                // Heard under it, judged over just where they overlap.
                let under: [(voice: Clip, both: TimeRange)] = heard.compactMap { voice in
                    guard let both = picture.range.intersection(voice.range), both.duration >= frame,
                          !silent(voice, over: both) else { return nil }
                    return (voice, both)
                }
                // Its own sound when it's linked to some under it: the next
                // clip's sound under an L-cut isn't its voice. Otherwise any
                // of the file's sound under a clip on a cut track (the
                // Camera), linked or not; a shot of the take on a follow
                // track (B-roll of his hands) is a cutaway, shown as it is.
                let compared: [(voice: Clip, both: TimeRange)]
                let voiced = picture.linkGroup.map { group in project.audioTracks.contains { $0.clips.contains { $0.linkGroup == group && $0.mediaID == mediaID } } } ?? false
                if voiced, let group = picture.linkGroup {
                    // Linked: its own sound only. None of it under this
                    // stretch is an L-cut's tail (or its sound is muted).
                    compared = under.filter { $0.voice.linkGroup == group }
                } else if track.rippleMode == .cut, item.role == .camera || picture.linkGroup != nil {
                    // Unlinked (or its group has none of its sound): any of
                    // the file's sound, except, when some is in step with
                    // it, a second or less at its start or end that's
                    // another shot's sound (linked to another clip of the
                    // file): the next clip's sound under a J or L-cut.
                    let steady = under.contains { inStep(picture, $0.voice, over: $0.both, slack: slack) }
                    compared = under.filter { voice in
                        let atEdge = voice.both.start == picture.start || voice.both.end == picture.end
                        let anotherShot = voice.voice.linkGroup.map { group in
                            project.videoTracks.contains { $0.clips.contains { $0.linkGroup == group && $0.id != picture.id && $0.mediaID == mediaID } }
                        } ?? false
                        return !(steady && atEdge && anotherShot && voice.both.duration <= Time(seconds: 1))
                    }
                } else {
                    compared = []
                }
                var off: [(voice: Clip, both: TimeRange, apart: Time)] = []
                for (voice, both) in compared {
                    // How far apart they are in the file, and on the
                    // timeline at the picture's speed: 10 ms of file is 3
                    // frames at 0.1x.
                    func apart(at time: Time) -> Time { picture.sourceTime(atTimelineTime: time) - voice.sourceTime(atTimelineTime: time) }
                    let ends = [apart(at: both.start), apart(at: both.end)]
                    let speed = max(picture.speed, 0.0001)
                    guard let most = ends.max(by: { abs($0.seconds) < abs($1.seconds) }), abs(most.seconds) / speed > slack,
                          ranges.contains(where: { $0.overlaps(both) }) else { continue }
                    off.append((voice, both, most))
                }
                // A copy of the shot on another track (a privacy blur over
                // it) would stay where it is if this one slipped alone.
                let copied = project.videoTracks.contains { other in
                    other.id != track.id && other.clips.contains { $0.mediaID == mediaID && $0.range.overlaps(picture.range) }
                }
                let name = URL(fileURLWithPath: item.path).lastPathComponent
                for (voice, both, apart) in off {
                    let late = apart < .zero
                    let onTimeline = Time(seconds: abs(apart.seconds) / max(picture.speed, 0.0001))
                    var problem = CheckProblem(
                        kind: .pictureOffVoice, start: both.start, end: both.end,
                        message: "Picture off the voice: \(picture.id) shows \(name) \(seconds(onTimeline)) \(late ? "behind" : "ahead of") \(voice.id), the sound of the same take, so the lips are out of step with the words.",
                        clipIDs: [picture.id, voice.id]
                    )
                    // One voice clip under it and speeds that match: a slip
                    // puts every frame back on its word.
                    let slipped = picture.sourceStart - apart
                    let fits = (picture.holdEdges || slipped >= .zero - frame)
                        && (picture.holdEdges || project.sourceLimit(for: picture).map { slipped + picture.sourceDuration <= $0 + frame } ?? true)
                    let covers = voice.start <= picture.start && picture.end <= voice.end
                    if compared.count == 1, covers, !track.locked, !copied, abs(picture.speed - voice.speed) < 1e-9, fits {
                        problem.fix = EditCommand.slip(clipID: picture.id, delta: -apart, includeLinked: false)
                        problem.message += " Slip it \(seconds(apart < .zero ? -apart : apart)) of its file \(late ? "later" : "earlier"): slip on \(picture.id)."
                    } else if track.locked {
                        problem.message += " \"\(track.name)\" is locked: unlock it, then slip \(picture.id) to the voice."
                    } else {
                        problem.message += " Rebuild the picture from the voice's clips (same file, start and source start), then link them."
                    }
                    found.append(problem)
                }
            }
        }
        return found
    }

    /// Whether `picture` plays the file at the same moments as `voice` over
    /// `range`, within `slack` seconds on the timeline.
    static func inStep(_ picture: Clip, _ voice: Clip, over range: TimeRange, slack: Double) -> Bool {
        let speed = max(picture.speed, 0.0001)
        return [range.start, range.end].allSatisfy { time in
            abs((picture.sourceTime(atTimelineTime: time) - voice.sourceTime(atTimelineTime: time)).seconds) / speed <= slack
        }
    }

    /// A clip turned all the way down (Filmora mutes with -100 dB), its
    /// gain keyframes too, over `range` on the timeline (all of it by
    /// default): not heard there, so not the voice. Between keyframes the
    /// gain eases from one to the next, so its loudest is at the range's
    /// ends or a keyframe inside it; the end itself isn't played, so it's
    /// read a moment before, and a keyframe kept past the end (to shape the
    /// curve) isn't heard.
    static func silent(_ clip: Clip, over range: TimeRange? = nil) -> Bool {
        let keys = clip.keyframes["audio.gainDB"] ?? []
        guard !keys.isEmpty else { return (clip.audio?.gainDB ?? 0) <= -96 }
        let played = range?.intersection(clip.range) ?? clip.range
        let from = played.start - clip.start
        let to = played.end - clip.start - Time(seconds: 0.0005)
        let times = [from, max(from, to)] + keys.map(\.time).filter { $0 > from && $0 < to }
        return times.allSatisfy { (keys.value(at: $0)?.number ?? 0) <= -96 }
    }
}
