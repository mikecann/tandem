import Foundation
import TandemCore
import TandemMedia

// MARK: - comments

/// The comments Mike left on the timeline for the next round of edits,
/// with what's said and what plays at each, so an agent can do what they
/// ask without looking the moment up.
public struct CommentsRequest: ServiceCall {
    public static let operation = ServiceOperation.comments

    public init() {}

    public func run(on service: TandemService, context: CallContext) async throws -> CommentsResult {
        service.comments()
    }
}

public struct CommentsResult: Codable, Sendable {
    public var revision: Int
    /// Earliest first.
    public var comments: [CommentInfo]
}

public struct CommentInfo: Codable, Sendable {
    /// The comment's marker ID: remove it (`removeMarker`) once it's done.
    public var id: String
    public var time: Time
    /// What Mike asked.
    public var text: String
    /// What's said a few seconds either side, with `|` where the comment is.
    public var said: String?
    /// The clips playing at its time, top track first.
    public var clips: [CommentClip]
}

public struct CommentClip: Codable, Sendable {
    /// As `timeline` names tracks: V1 is the bottom video track, A1 the top
    /// audio one.
    public var track: String
    public var trackID: String
    public var clipID: String
    public var start: Time
    public var end: Time
    /// The file and source range, or the title's words.
    public var content: String
}

extension CommentsResult: ReadableResult {
    public var readableText: String {
        guard !comments.isEmpty else {
            return "No comments (revision \(revision)). Mike adds them in Tandem with Add comment (Shift-C) or a double-click on an empty stretch; they show in a Comments strip under the ruler."
        }
        var lines = ["\(comments.count == 1 ? "1 comment" : "\(comments.count) comments") from Mike, earliest first (revision \(revision)):"]
        let trackWidth = comments.flatMap(\.clips).map(\.track.count).max() ?? 0
        for comment in comments {
            lines.append("")
            lines.append("\(comment.id)  \(comment.time)  \"\(CommentEdits.oneLine(comment.text))\"")
            if let said = comment.said { lines.append("  said: \(said)") }
            for clip in comment.clips {
                let track = clip.track.padding(toLength: trackWidth, withPad: " ", startingAt: 0)
                lines.append("  \(track)  \(clip.clipID)  \(clip.start)-\(clip.end)  \(clip.content)")
            }
        }
        lines.append("")
        lines.append("Do what each asks and label the edit with what you did. Remove the comment in the same apply batch, {\"removeMarker\": {\"markerID\": \"<id>\"}}, or afterwards with tandem comments resolve <id>. Comments move with ripple edits, so read them again after one.")
        return lines.joined(separator: "\n")
    }
}

extension TandemService {
    /// How far either side of a comment `said` reaches.
    static let commentContext = Time(seconds: 4)

    public func comments() -> CommentsResult {
        let (project, revision) = coordinator.snapshot()
        let comments = project.comments
        guard !comments.isEmpty else { return CommentsResult(revision: revision, comments: []) }
        let words = TranscriptTools.speechMap(project, analysis: analysis).words
        let names = TimelineDump.mediaNames(project)
        // Tracks as the app shows them, top to bottom.
        var tracks: [(label: String, track: Track)] = []
        for (index, track) in project.videoTracks.enumerated().reversed() { tracks.append(("V\(index + 1) \(track.name)", track)) }
        for (index, track) in project.audioTracks.enumerated() { tracks.append(("A\(index + 1) \(track.name)", track)) }

        let infos = comments.map { comment -> CommentInfo in
            let time = comment.time
            var clips: [CommentClip] = []
            for (label, track) in tracks {
                for clip in track.clips where clip.start <= time && time < clip.end {
                    clips.append(CommentClip(
                        track: label, trackID: track.id, clipID: clip.id, start: clip.start, end: clip.end,
                        content: TimelineDump.content(clip, project: project, names: names)
                    ))
                }
            }
            return CommentInfo(id: comment.id, time: time, text: comment.name, said: Self.said(around: time, in: words), clips: clips)
        }
        return CommentsResult(revision: revision, comments: infos)
    }

    /// The words spoken a few seconds either side of `time`, with `|` at it.
    static func said(around time: Time, in words: [TranscriptTools.SpokenWord]) -> String? {
        let near = words.filter { $0.end > time - commentContext && $0.start < time + commentContext }
        guard !near.isEmpty else { return nil }
        let before = near.filter { $0.start < time }.map(\.text)
        let after = near.filter { $0.start >= time }.map(\.text)
        return (before + ["|"] + after).joined(separator: " ")
    }
}
