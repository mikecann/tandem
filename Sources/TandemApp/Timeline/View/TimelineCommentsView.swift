import AppKit
import QuartzCore
import TandemCore

/// Mike's comments, in a strip of their own under the ruler, so the ruler
/// stays free for moving the playhead. It shows while there are comments.
/// A click on a comment takes the playhead to it and a drag moves it; a
/// double-click changes it. Between comments a click or drag moves the
/// playhead, as on the ruler, and a double-click adds a comment there.
@MainActor
final class TimelineCommentsView: TimelineChildView {
    private var model: EditorModel? { container?.model }
    /// The comment being dragged, where on it it was grabbed, and whether
    /// it has moved yet (a click that doesn't move goes to it instead).
    private var dragging: (id: String, offset: Double, moved: Bool)?
    private var preview: Time?
    private var pressPoint: CGPoint = .zero
    /// What a double-click asked for, done as the button comes up so the
    /// release can't close the box it opens.
    private var pending: Pending?
    private var trackingArea: NSTrackingArea?
    private var tipRects: [CGRect] = []

    private enum Pending {
        case add(Time)
        case change(Marker)
    }

    static let font = Theme.Fonts.ui(10.5, .semibold)
    /// A comment's words run this far at most; its tooltip has the rest.
    static let maxWidth: CGFloat = 320

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Where comments go

    /// Each comment's box, left edge on its time, cut short of the next
    /// one so they never overlap: in `project`'s time order, as `scale`
    /// places them. `moving` puts one comment somewhere else (a drag).
    static func boxes(for project: Project, scale: TimelineScale, height: CGFloat, moving: (id: String, time: Time)? = nil) -> [(rect: CGRect, comment: Marker)] {
        let placed = project.comments.map { comment in
            (comment, comment.id == moving?.id ? moving!.time : comment.time)
        }.sorted { $0.1 < $1.1 }
        var boxes: [(rect: CGRect, comment: Marker)] = []
        for (index, (comment, time)) in placed.enumerated() {
            let x = scale.x(time)
            var width = min((CommentEdits.oneLine(comment.name) as NSString).size(withAttributes: [.font: font]).width + 24, maxWidth)
            if index + 1 < placed.count { width = min(width, scale.x(placed[index + 1].1) - x - 2) }
            boxes.append((CGRect(x: x, y: 3, width: max(width, 16), height: max(0, height - 6)), comment))
        }
        return boxes
    }

    /// The comment under `point`, as the model has it now.
    func comment(at point: CGPoint) -> Marker? {
        guard let model else { return nil }
        return Self.boxes(for: model.project, scale: model.timeline.scale, height: bounds.height).last { $0.rect.contains(point) }?.comment
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The container's copy of the model: see `TimelineDrawState`.
        guard let container, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = container.drawScale
        context.setFillColor(Theme.window.cg)
        context.fill(bounds)
        let moving = dragging.flatMap { drag in preview.map { (drag.id, $0) } }
        let boxes = Self.boxes(for: container.drawState.project, scale: scale, height: bounds.height, moving: moving)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (rect, comment) in boxes where rect.maxX > 0 && rect.minX < bounds.width {
            let box = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(box)
            context.setFillColor(Theme.comment.opacity(comment.id == dragging?.id ? 0.26 : 0.13).cg)
            context.fillPath()
            // Its time: the box's left edge, marked.
            context.setFillColor(Theme.comment.cg)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 1.5, height: rect.height))
            // A speech bubble, then the words.
            let centre = CGPoint(x: rect.minX + 8, y: rect.midY)
            let bubble = CGMutablePath()
            bubble.addRoundedRect(in: CGRect(x: centre.x - 1, y: centre.y - 4.5, width: 10, height: 7.5), cornerWidth: 2, cornerHeight: 2)
            bubble.move(to: CGPoint(x: centre.x - 1, y: centre.y + 0.5))
            bubble.addLine(to: CGPoint(x: centre.x - 1, y: centre.y + 5.5))
            bubble.addLine(to: CGPoint(x: centre.x + 3.5, y: centre.y + 2.5))
            bubble.closeSubpath()
            context.addPath(bubble)
            context.fillPath()
            let textWidth = rect.width - 24
            if textWidth > 8 {
                (CommentEdits.oneLine(comment.name) as NSString).draw(
                    with: CGRect(x: rect.minX + 21, y: rect.midY - 7.5, width: textWidth, height: 14),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: Self.font, .foregroundColor: Theme.comment.ns, .paragraphStyle: paragraph]
                )
            }
        }
        context.setFillColor(Theme.rulerLine.cg)
        context.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
        // Each comment's tooltip is its own, so moving from one to the next
        // shows the next one's words.
        let rects = boxes.map(\.rect).filter { $0.maxX > 0 && $0.minX < bounds.width }
        if rects != tipRects {
            tipRects = rects
            DispatchQueue.main.async { [weak self] in self?.resetToolTips() }
        }
    }

    private func resetToolTips() {
        removeAllToolTips()
        for rect in tipRects { addToolTip(rect, owner: self, userData: nil) }
    }


    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ event: NSEvent) {
        (comment(at: convert(event.locationInWindow, from: nil)) != nil ? CursorKind.grab : .arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pending = nil
        dragging = nil
        preview = nil
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        pressPoint = point
        model.playback.pause()
        if let comment = comment(at: point) {
            if event.clickCount == 2 {
                pending = .change(comment)
                return
            }
            dragging = (comment.id, model.timeline.scale.seconds(atX: point.x) - comment.time.seconds, false)
            preview = comment.time
            CursorKind.grabbing.set()
            return
        }
        if event.clickCount == 2 {
            pending = .add(model.timeline.scale.time(atX: point.x, rate: model.frameRate))
            return
        }
        scrub(to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if var drag = dragging {
            guard drag.moved || abs(point.x - pressPoint.x) >= 3 else { return }
            drag.moved = true
            dragging = drag
            var time = Time(seconds: max(0, model.timeline.scale.seconds(atX: point.x) - drag.offset)).roundedToFrame(model.frameRate)
            if model.snapping, let snapped = SnapTargets.collect(in: model.project, playhead: model.playback.time).nearest(to: time, within: model.timeline.scale.duration(forPixels: Theme.Metrics.snapDistance)) {
                time = snapped
            }
            preview = time
            needsDisplay = true
            return
        }
        if pending == nil { scrub(to: point) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { updateCursor(event) }
        guard let model else { return }
        switch pending {
        case .add(let time):
            model.playback.seek(to: time)
            model.beginComment(at: time)
        case .change(let comment):
            model.editComment(comment)
        case nil:
            break
        }
        pending = nil
        if let drag = dragging, let comment = model.project.comments.first(where: { $0.id == drag.id }) {
            if drag.moved, let time = preview, time != comment.time {
                model.apply(EditBatch(label: "Move comment", commands: [.updateMarker(markerID: comment.id, patch: .object(["time": .number(time.seconds)]))]))
            } else if !drag.moved {
                // A click on a comment goes to it.
                model.playback.seek(to: comment.time)
            }
        }
        dragging = nil
        preview = nil
        needsDisplay = true
    }

    private func scrub(to point: CGPoint) {
        guard let model else { return }
        model.playback.seek(to: model.timeline.scale.time(atX: point.x, rate: model.frameRate))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
        let menu = NSMenu()
        if let comment = comment(at: point) {
            menu.add("Change comment…") { model.editComment(comment) }
            menu.add("Delete comment") { model.deleteComment(comment) }
            menu.addItem(.separator())
        }
        menu.add("Add comment here…") { model.beginComment(at: time) }
        let all = model.project.comments
        if all.count > 1 {
            menu.add("Delete all \(all.count) comments") { model.apply(CommentEdits.remove(all.map(\.id))) }
        }
        return menu
    }
}

extension TimelineCommentsView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let comment = comment(at: point) else { return "" }
        return "\(comment.name)\n\nClick to go there, drag to move it, double-click to change it, right-click to delete it."
    }
}

/// The comments strip's name, in the track header column beside it.
@MainActor
final class TimelineCommentsHeaderView: TimelineChildView {
    private var symbol: NSImage?

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(Theme.window.cg)
        context.fill(bounds)
        if symbol == nil {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium).applying(.init(paletteColors: [Theme.comment.ns]))
            symbol = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        if let symbol {
            let size = symbol.size
            symbol.draw(in: CGRect(x: 12 + (12 - size.width) / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let count = container?.drawState.project.comments.count ?? 0
        ("Comments" + (count > 1 ? " \(count)" : "") as NSString).draw(
            at: CGPoint(x: TimelineHeaderView.nameX, y: bounds.midY - 7),
            withAttributes: [.font: Theme.Fonts.ui(10.5), .foregroundColor: Theme.textFaint.ns]
        )
        context.setFillColor(Theme.rulerLine.cg)
        context.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
    }
}
