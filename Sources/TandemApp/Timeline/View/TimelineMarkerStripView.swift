import AppKit
import QuartzCore
import TandemCore

/// Which markers a strip under the ruler holds. Markers have strips of
/// their own, as the transcript has its lane, so nothing covers the
/// ruler's time code or gets in the way of a click there. Each strip
/// shows while it has anything in it.
enum MarkerStrip: CaseIterable {
    /// Mike's markers, sections and chapters.
    case markers
    /// Notes left for Mike: a shot to record or find, a title to make.
    case todos
    /// Mike's notes for the next round of agent edits.
    case comments

    func holds(_ marker: Marker) -> Bool {
        switch self {
        case .markers: return [.marker, .section, .chapter].contains(marker.kind)
        case .todos: return marker.kind == .todo
        case .comments: return marker.kind == .comment
        }
    }

    /// Its markers in `project`, earliest first.
    func markers(in project: Project) -> [Marker] {
        project.markers.filter(holds).sorted { $0.time < $1.time }
    }

    var title: String {
        switch self {
        case .markers: return "Markers"
        case .todos: return "To-dos"
        case .comments: return "Comments"
        }
    }

    /// One of them, in menus and undo labels.
    var noun: String {
        switch self {
        case .markers: return "marker"
        case .todos: return "to-do"
        case .comments: return "comment"
        }
    }

    var colour: Swatch {
        switch self {
        case .markers: return Theme.amber
        case .todos: return Theme.red
        case .comments: return Theme.comment
        }
    }

    var symbol: String {
        switch self {
        case .markers: return "bookmark"
        case .todos: return "checklist"
        case .comments: return "text.bubble"
        }
    }

    /// The strips `project` shows, top to bottom.
    static func shown(in project: Project) -> [MarkerStrip] {
        allCases.filter { strip in project.markers.contains(where: strip.holds) }
    }

    /// How much room the strips take under the ruler.
    static func height(in project: Project) -> CGFloat {
        CGFloat(shown(in: project).count) * Theme.Metrics.markerStripHeight
    }
}

/// One strip of markers under the ruler. A click on a marker takes the
/// playhead to it and a drag moves it; a double-click renames it (or
/// changes what a comment says). Between markers a click or drag moves the
/// playhead, as on the ruler, and a double-click adds a marker or comment
/// there. Each marker's tooltip has its whole name and note.
@MainActor
final class TimelineMarkerStripView: TimelineChildView {
    let strip: MarkerStrip
    private var model: EditorModel? { container?.model }
    /// The marker being dragged, where on it it was grabbed, and whether it
    /// has moved yet (a click that doesn't move goes to it instead).
    private var dragging: (id: String, offset: Double, moved: Bool)?
    private var preview: Time?
    private var pressPoint: CGPoint = .zero
    /// What a double-click asked for, done as the button comes up so the
    /// release can't close the box or dialog it opens.
    private var pending: Pending?
    private var trackingArea: NSTrackingArea?
    private var tipRects: [CGRect] = []

    private enum Pending {
        case add(Time)
        case change(Marker)
    }

    static let font = Theme.Fonts.ui(10.5, .semibold)
    /// A marker's words run this far at most; its tooltip has the rest.
    static let maxWidth: CGFloat = 320

    init(strip: MarkerStrip) {
        self.strip = strip
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Where markers go

    /// Each marker's box, left edge on its time, cut short of the next one
    /// so they never overlap, as `scale` places them. `moving` puts one
    /// somewhere else (a drag).
    func boxes(for project: Project, scale: TimelineScale, height: CGFloat, moving: (id: String, time: Time)? = nil) -> [(rect: CGRect, marker: Marker)] {
        let placed = strip.markers(in: project).map { marker in
            (marker, marker.id == moving?.id ? moving!.time : marker.time)
        }.sorted { $0.1 < $1.1 }
        var boxes: [(rect: CGRect, marker: Marker)] = []
        for (index, (marker, time)) in placed.enumerated() {
            let x = scale.x(time)
            var width = min((Self.label(marker) as NSString).size(withAttributes: [.font: Self.font]).width + 24, Self.maxWidth)
            if index + 1 < placed.count { width = min(width, scale.x(placed[index + 1].1) - x - 2) }
            boxes.append((CGRect(x: x, y: 3, width: max(width, 16), height: max(0, height - 6)), marker))
        }
        return boxes
    }

    /// What the strip writes: the name, on one line.
    static func label(_ marker: Marker) -> String {
        CommentEdits.oneLine(marker.name)
    }

    /// The marker under `point`, as the model has it now.
    func marker(at point: CGPoint) -> Marker? {
        guard let model else { return nil }
        return boxes(for: model.project, scale: model.timeline.scale, height: bounds.height).last { $0.rect.contains(point) }?.marker
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The container's copy of the model: see `TimelineDrawState`.
        guard let container, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = container.drawScale
        context.setFillColor(Theme.window.cg)
        context.fill(bounds)
        let moving = dragging.flatMap { drag in preview.map { (drag.id, $0) } }
        let boxes = boxes(for: container.drawState.project, scale: scale, height: bounds.height, moving: moving)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let colour = strip.colour
        for (rect, marker) in boxes where rect.maxX > 0 && rect.minX < bounds.width {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.setFillColor(colour.opacity(marker.id == dragging?.id ? 0.26 : 0.13).cg)
            context.fillPath()
            // Its time: the box's left edge, marked.
            context.setFillColor(colour.cg)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 1.5, height: rect.height))
            drawGlyph(at: CGPoint(x: rect.minX + 8, y: rect.midY), in: context)
            let textWidth = rect.width - 24
            if textWidth > 8 {
                (Self.label(marker) as NSString).draw(
                    with: CGRect(x: rect.minX + 21, y: rect.midY - 7.5, width: textWidth, height: 14),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: Self.font, .foregroundColor: (strip == .comments ? colour : Theme.textStrong).ns, .paragraphStyle: paragraph]
                )
            }
        }
        context.setFillColor(Theme.rulerLine.cg)
        context.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
        // Each marker's tooltip is its own, so moving from one to the next
        // shows the next one's words.
        let rects = boxes.map(\.rect).filter { $0.maxX > 0 && $0.minX < bounds.width }
        if rects != tipRects {
            tipRects = rects
            DispatchQueue.main.async { [weak self] in self?.resetToolTips() }
        }
    }

    /// A speech bubble for a comment, a diamond for the rest, in the
    /// strip's colour (set by the caller).
    private func drawGlyph(at centre: CGPoint, in context: CGContext) {
        let path = CGMutablePath()
        if strip == .comments {
            path.addRoundedRect(in: CGRect(x: centre.x - 1, y: centre.y - 4.5, width: 10, height: 7.5), cornerWidth: 2, cornerHeight: 2)
            path.move(to: CGPoint(x: centre.x - 1, y: centre.y + 0.5))
            path.addLine(to: CGPoint(x: centre.x - 1, y: centre.y + 5.5))
            path.addLine(to: CGPoint(x: centre.x + 3.5, y: centre.y + 2.5))
            path.closeSubpath()
        } else {
            let middle = CGPoint(x: centre.x + 4, y: centre.y)
            path.move(to: CGPoint(x: middle.x, y: middle.y - 4))
            path.addLine(to: CGPoint(x: middle.x + 4, y: middle.y))
            path.addLine(to: CGPoint(x: middle.x, y: middle.y + 4))
            path.addLine(to: CGPoint(x: middle.x - 4, y: middle.y))
            path.closeSubpath()
        }
        context.addPath(path)
        context.fillPath()
    }

    private func resetToolTips() {
        removeAllToolTips()
        for rect in tipRects { addToolTip(rect, owner: self, userData: nil) }
    }

    /// The whole of a marker, for its tooltip.
    func toolTip(for marker: Marker) -> String {
        if strip == .comments {
            return "\(marker.name)\n\nClick to go there, drag to move it, double-click to change it, right-click to delete it."
        }
        var lines = [marker.name]
        if let note = marker.note, !note.isEmpty { lines.append(note) }
        lines.append("Click to go there, drag to move it, double-click to rename it, right-click for more.")
        return lines.joined(separator: "\n\n")
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
        (marker(at: convert(event.locationInWindow, from: nil)) != nil ? CursorKind.grab : .arrow).set()
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
        if let marker = marker(at: point) {
            if event.clickCount == 2 {
                pending = .change(marker)
                return
            }
            dragging = (marker.id, model.timeline.scale.seconds(atX: point.x) - marker.time.seconds, false)
            preview = marker.time
            CursorKind.grabbing.set()
            return
        }
        if event.clickCount == 2, strip != .todos {
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
        let asked = pending
        pending = nil
        if let drag = dragging, let marker = model.project.markers.first(where: { $0.id == drag.id }) {
            if drag.moved, let time = preview, time != marker.time {
                model.apply(EditBatch(label: "Move \(strip.noun)", commands: [.updateMarker(markerID: marker.id, patch: .object(["time": .number(time.seconds)]))]))
            } else if !drag.moved {
                // A click on a marker goes to it.
                model.playback.seek(to: marker.time)
            }
        }
        dragging = nil
        preview = nil
        needsDisplay = true
        switch asked {
        case .add(let time):
            model.playback.seek(to: time)
            if strip == .comments {
                model.beginComment(at: time)
            } else {
                model.apply(TimelineEdits.addMarker(model.project, at: time))
            }
        case .change(let marker):
            if strip == .comments {
                model.editComment(marker)
            } else {
                model.renameMarker(marker)
            }
        case nil:
            break
        }
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
        if let marker = marker(at: point) {
            if strip == .comments {
                menu.add("Change comment…") { model.editComment(marker) }
                menu.add("Delete comment") { model.deleteComment(marker) }
            } else {
                menu.add("Rename \(strip.noun)…") { model.renameMarker(marker) }
                menu.addSubmenu("Kind") { sub in
                    for kind in [MarkerKind.marker, .section, .chapter, .todo] {
                        sub.add(kind == .todo ? "To-do" : kind.rawValue.capitalized, checked: marker.kind == kind) {
                            model.apply(EditBatch(label: "Marker kind", commands: [.updateMarker(markerID: marker.id, patch: .object(["kind": .string(kind.rawValue)]))]))
                        }
                    }
                }
                menu.add("Delete \(strip.noun)") {
                    model.apply(EditBatch(label: "Delete \(self.strip.noun)", commands: [.removeMarker(markerID: marker.id)]))
                }
            }
            menu.addItem(.separator())
        }
        switch strip {
        case .comments:
            menu.add("Add comment here…") { model.beginComment(at: time) }
        case .markers:
            menu.add("Add marker here") { model.apply(TimelineEdits.addMarker(model.project, at: time)) }
        case .todos:
            break
        }
        let all = strip.markers(in: model.project)
        if strip != .markers, all.count > 1 {
            menu.add("Delete all \(all.count) \(strip.title.lowercased())") {
                model.apply(CommentEdits.remove(all.map(\.id), label: "Delete \(all.count) \(self.strip.title.lowercased())"))
            }
        }
        return menu.items.isEmpty ? nil : menu
    }
}

extension TimelineMarkerStripView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        marker(at: point).map(toolTip(for:)) ?? ""
    }
}

/// A strip's name and count, in the track header column beside it.
@MainActor
final class TimelineMarkerStripHeaderView: TimelineChildView {
    let strip: MarkerStrip
    private var symbol: NSImage?

    init(strip: MarkerStrip) {
        self.strip = strip
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(Theme.window.cg)
        context.fill(bounds)
        if symbol == nil {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium).applying(.init(paletteColors: [strip.colour.ns]))
            symbol = NSImage(systemSymbolName: strip.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        if let symbol {
            let size = symbol.size
            symbol.draw(in: CGRect(x: 12 + (12 - size.width) / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let count = container.map { strip.markers(in: $0.drawState.project).count } ?? 0
        (strip.title + (count > 1 ? " \(count)" : "") as NSString).draw(
            at: CGPoint(x: TimelineHeaderView.nameX, y: bounds.midY - 7),
            withAttributes: [.font: Theme.Fonts.ui(10.5), .foregroundColor: Theme.textFaint.ns]
        )
        context.setFillColor(Theme.rulerLine.cg)
        context.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
    }
}
