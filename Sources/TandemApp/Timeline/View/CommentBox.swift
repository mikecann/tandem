import AppKit
import TandemCore

/// The box Mike writes a comment in, under the timeline's top at the
/// comment's time.
/// Return keeps it, Option-Return starts a new line, Escape drops it.
/// Clicking away keeps what's written, so a stray click doesn't lose a note.
@MainActor
final class CommentBox: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    let request: CommentBoxRequest
    let field = NSTextField()
    private let heading: String
    private let onSave: (String) -> Void
    private var finished = false
    private(set) var popover: NSPopover?

    init(request: CommentBoxRequest, rate: FrameRate, onSave: @escaping (String) -> Void) {
        self.request = request
        self.heading = (request.comment == nil ? "Comment at " : "Change the comment at ") + Timecode.string(request.time, rate: rate)
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let title = NSTextField(labelWithString: heading)
        title.font = Theme.Fonts.ui(11.5, .semibold)
        title.textColor = Theme.comment.ns

        field.stringValue = request.comment?.name ?? ""
        field.placeholderString = "What should change here?"
        field.font = Theme.Fonts.ui(13)
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        field.heightAnchor.constraint(equalToConstant: 58).isActive = true

        let hint = NSTextField(labelWithString: "Return saves · ⌥Return new line · Esc cancels")
        hint.font = Theme.Fonts.ui(10.5)
        hint.textColor = Theme.textFaint.ns

        let stack = NSStackView(views: [title, field, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        view = stack
    }

    /// Shows the box pointing at `rect` in `positioning`, below it.
    func show(pointingAt rect: NSRect, in positioning: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = self
        popover.delegate = self
        self.popover = popover
        // The ruler is flipped, so its bottom edge is maxY.
        popover.show(relativeTo: rect, of: positioning, preferredEdge: positioning.isFlipped ? .maxY : .minY)
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    /// Keeps the comment and closes the box.
    func save() {
        guard !finished else { return }
        finished = true
        onSave(field.stringValue)
        popover?.close()
    }

    /// Closes the box without changing anything.
    func cancel() {
        guard !finished else { return }
        finished = true
        popover?.close()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            save()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            // Option-Return inserts a new line by itself.
            return false
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Clicked away: what's written is kept, but clicking away never
        // deletes a comment.
        guard !finished else { return }
        finished = true
        if !CommentEdits.tidy(field.stringValue).isEmpty { onSave(field.stringValue) }
    }
}
