import AppKit
import QuartzCore
import TandemCore

/// Time labels, ticks, the in and out range and the band over agent
/// changes waiting for review. Click or drag to move the playhead. Markers,
/// to-dos and comments have strips of their own below
/// (`TimelineMarkerStripView`), so nothing covers the time code or gets in
/// the way of a click here.
@MainActor
final class TimelineRulerView: TimelineChildView {
    private var model: EditorModel? { container?.model }
    private var trackingArea: NSTrackingArea?
    /// Where a double-click away from the markers asked for a comment,
    /// until the button comes up and the box opens.
    private var commentAt: Time?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(event)
    }

    private func updateCursor(_ event: NSEvent) {
        CursorKind.arrow.set()
        updateReviewToolTip(at: convert(event.locationInWindow, from: nil))
    }

    /// Over the review band, who changed what there and when: the ruler's
    /// tooltip, as the lanes' clips have theirs.
    private func updateReviewToolTip(at point: CGPoint) {
        guard let container else { return }
        let scale = container.drawScale
        let slop = scale.duration(forPixels: ReviewBand.minimumWidth / 2 + 1)
        let edits = container.drawState.review.edits(at: Time(seconds: scale.seconds(atX: point.x)), slop: slop)
        let tip = edits.isEmpty ? nil : TimelineReview.tooltip(for: edits)
        if toolTip != tip { toolTip = tip }
    }

    override func draw(_ dirtyRect: NSRect) {
        let started = CACurrentMediaTime()
        defer { DrawTiming.record("ruler", CACurrentMediaTime() - started) }
        // The container's copy of the model, never the model itself: see
        // `TimelineDrawState`.
        guard let state = container?.drawState, let context = NSGraphicsContext.current?.cgContext else { return }
        // Scrolled to the whole point the lanes are painted at.
        guard let scale = container?.drawScale else { return }
        let rate = state.frameRate
        context.setFillColor(Theme.window.cg)
        context.fill(bounds)
        ReviewBand.draw(state.review, scale: scale, in: bounds, context: context)

        // In to out.
        if state.inPoint != nil || state.outPoint != nil {
            let start = state.inPoint ?? .zero
            let end = state.outPoint ?? state.project.duration
            let x0 = scale.x(start)
            let x1 = scale.x(max(start, end))
            context.setFillColor(Theme.amber.opacity(0.14).cg)
            context.fill(CGRect(x: x0, y: bounds.height - 9, width: max(0, x1 - x0), height: 8))
            context.setFillColor(Theme.amber.opacity(0.9).cg)
            if state.inPoint != nil {
                context.fill(CGRect(x: x0, y: bounds.height - 12, width: 1.5, height: 11))
                context.fill(CGRect(x: x0, y: bounds.height - 12, width: 5, height: 1.5))
            }
            if state.outPoint != nil {
                context.fill(CGRect(x: x1 - 1.5, y: bounds.height - 12, width: 1.5, height: 11))
                context.fill(CGRect(x: x1 - 5, y: bounds.height - 12, width: 5, height: 1.5))
            }
        }

        let step = scale.rulerStep(minimumGap: 110, rate: rate)
        let minor = step / 4
        let firstMinor = (scale.scrollSeconds / minor).rounded(.down) * minor
        let labelFont = Theme.Fonts.digits(10)
        context.setStrokeColor(Theme.tick.cg)
        context.setLineWidth(1)
        var seconds = firstMinor
        let endSeconds = scale.seconds(atX: bounds.width + 60)
        while seconds <= endSeconds {
            let x = scale.x(seconds: seconds).rounded() + 0.5
            let isMajor = abs((seconds / step).rounded() * step - seconds) < minor / 10
            context.move(to: CGPoint(x: x, y: isMajor ? bounds.height - 10 : bounds.height - 5))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            if isMajor {
                let label = Timecode.rulerLabel(max(0, seconds), step: step, rate: rate)
                let size = (label as NSString).size(withAttributes: [.font: labelFont])
                let rect = CGRect(x: x + 4, y: 3, width: size.width, height: 12)
                if seconds >= 0 {
                    (label as NSString).draw(at: CGPoint(x: rect.minX, y: rect.minY), withAttributes: [.font: labelFont, .foregroundColor: Theme.textFaint.ns])
                }
            }
            seconds += minor
        }
        context.strokePath()

        context.setFillColor(Theme.rulerLine.cg)
        context.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // Clicking here takes the keys back from any text field.
        window?.makeFirstResponder(self)
        commentAt = nil
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        model.playback.pause()
        // A double-click: a comment there, as on an empty stretch of the
        // tracks.
        if event.clickCount == 2 {
            commentAt = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
            return
        }
        scrub(to: point, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard commentAt == nil else { return }
        scrub(to: convert(event.locationInWindow, from: nil), event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { updateCursor(event) }
        guard let model else { return }
        if let time = commentAt {
            commentAt = nil
            model.playback.seek(to: time)
            model.beginComment(at: time)
        }
    }

    /// Moves the playhead; Shift snaps it to edits and markers.
    private func scrub(to point: CGPoint, event: NSEvent) {
        guard let model else { return }
        var time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
        if event.modifierFlags.contains(.shift) {
            let targets = SnapTargets.collect(in: model.project, inPoint: model.inPoint, outPoint: model.outPoint)
            if let snapped = targets.nearest(to: time, within: model.timeline.scale.duration(forPixels: 12)) { time = snapped }
        }
        model.playback.seek(to: time)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
        let menu = NSMenu()
        menu.add("Add marker here") { model.apply(TimelineEdits.addMarker(model.project, at: time)) }
        menu.add("Add comment here…") { model.beginComment(at: time) }
        menu.add("Mark in here") { model.inPoint = time }
        menu.add("Mark out here") { model.outPoint = time }
        menu.add("Clear in and out", enabled: model.inPoint != nil || model.outPoint != nil) {
            model.inPoint = nil
            model.outPoint = nil
        }
        return menu
    }
}
