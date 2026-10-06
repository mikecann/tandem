import AppKit
import Foundation
import TandemCore

/// What the comment box is for: a new comment at a time, or changing one.
struct CommentBoxRequest: Equatable {
    var time: Time
    /// The comment being changed; nil for a new one.
    var comment: Marker?
}

/// Comments: notes Mike leaves at a moment for the next round of agent
/// edits. He writes them in a box on the timeline and they show in a strip
/// under the ruler; agents read them with `tandem comments` and remove
/// each one they do.
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

/// Markers and to-dos, in their strips under the ruler.
extension EditorModel {
    /// The playhead's scissors: cuts the selected clips under the playhead,
    /// or every clip under it, then picks out the pieces before the cut, as
    /// the blade tool does, so Delete takes them straight away.
    @discardableResult
    func cutAtPlayhead() -> Bool {
        let time = playback.time
        guard let batch = TimelineEdits.bladeAtPlayhead(project, playhead: time, selection: selection) else {
            show(.info, "Nothing under the playhead to cut.")
            return false
        }
        let before = project
        let chosen = selection
        guard apply(batch) != nil else { return false }
        // A cut keeps each left piece's ID, so the selected clips it cut are
        // their own pieces before it; selected clips elsewhere drop out.
        let pieces = TimelineEdits.piecesBefore(time, cutFrom: before, in: project)
        let cutChosen = pieces.intersection(chosen)
        selection = cutChosen.isEmpty ? pieces : cutChosen
        return true
    }

    /// Works out what's near the playhead again, keeping the old value when
    /// nothing's changed so the sidebar doesn't redraw.
    func refreshNearPlayhead() {
        let near = NearThePlayhead.at(playback.time, in: project, review: review)
        if near != nearPlayhead { setNearPlayhead(near) }
    }

    /// Takes the playhead to a marker, comment or to-do in the sidebar.
    func goTo(_ marker: Marker) {
        playback.pause()
        playback.seek(to: marker.time)
        timeline.bringIntoView(marker.time)
    }

    /// Asks for a marker's new name.
    func renameMarker(_ marker: Marker) {
        let noun = marker.kind == .todo ? "to-do" : "marker"
        let alert = NSAlert()
        alert.messageText = "Rename \(noun)"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: marker.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != marker.name else { return }
        apply(EditBatch(label: "Rename \(noun)", commands: [.updateMarker(markerID: marker.id, patch: .object(["name": .string(name)]))]))
    }
}
