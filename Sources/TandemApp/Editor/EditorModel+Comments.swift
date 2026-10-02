import Foundation
import TandemCore

/// What the comment box is for: a new comment at a time, or changing one.
struct CommentBoxRequest: Equatable {
    var time: Time
    /// The comment being changed; nil for a new one.
    var comment: Marker?
}

/// Comments: notes Mike leaves at a moment for the next round of agent
/// edits. He writes them in a box on the ruler; agents read them with
/// `tandem comments` and remove each one they do.
extension EditorModel {
    /// Opens the comment box at the playhead, paused, so Mike can say what
    /// should change there. `time` comes from a menu's click instead.
    @discardableResult
    func beginComment(at time: Time? = nil) -> Bool {
        playback.pause()
        let at = time ?? playback.time
        timeline.bringIntoView(at)
        guard let show = timeline.showCommentBox else { return false }
        show(CommentBoxRequest(time: at, comment: nil))
        return true
    }

    /// Opens the box on a comment, to change what it says.
    func editComment(_ comment: Marker) {
        timeline.bringIntoView(comment.time)
        timeline.showCommentBox?(CommentBoxRequest(time: comment.time, comment: comment))
    }

    /// What the box does with `text`: adds the comment, or changes or
    /// (emptied) deletes the one it was opened on.
    @discardableResult
    func saveComment(_ text: String, for request: CommentBoxRequest) -> Bool {
        let batch: EditBatch?
        if let comment = request.comment {
            // It may have moved or gone while the box was open.
            guard let current = project.markers.first(where: { $0.id == comment.id }) else { return false }
            batch = CommentEdits.edit(current, to: text)
        } else {
            batch = CommentEdits.add(text, at: request.time)
        }
        guard let batch else { return false }
        return apply(batch) != nil
    }

    func deleteComment(_ comment: Marker) {
        apply(CommentEdits.remove([comment.id]))
    }
}
