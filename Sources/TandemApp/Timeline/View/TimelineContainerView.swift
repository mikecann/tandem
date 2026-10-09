import AppKit
import TandemCore

/// The timeline: ruler on top, track headers on the left, lanes filling the
/// rest, and the playhead over both. Layer-backed AppKit throughout. When
/// the model changes it redraws only the views, and the parts of the lanes,
/// that look different (see `TimelineDamage`); while playing it moves only
/// the playhead view.
@MainActor
final class TimelineContainerView: NSView {
    let model: EditorModel
    let ruler = TimelineRulerView()
    /// Markers, to-dos and comments, each in a strip under the ruler while
    /// there are any, so nothing covers the ruler's time code.
    let strips = MarkerStrip.allCases.map(TimelineMarkerStripView.init(strip:))
    let stripHeaders = MarkerStrip.allCases.map(TimelineMarkerStripHeaderView.init(strip:))
    /// The comment box while it's open.
    private(set) var commentBox: CommentBox?
    let headers = TimelineHeaderView()
    let lanes = TimelineLanesView()
    let corner = TimelineCornerView()
    let scroller = TimelineScrollerView()
    /// Agent changes waiting for review, marked over the lanes.
    let reviewOverlay = ReviewOverlayView()
    private let playheadView = PlayheadView()
    /// The scissors on the playhead, as in Filmora: a click cuts there, a
    /// drag moves the playhead.
    let cutButton = PlayheadCutButton()
    private(set) var artwork: MediaArtwork
    private var loops: [ObservationLoop] = []
    /// The lane layout for the project being shown (which may be a drag
    /// preview).
    private(set) var layoutCache: TimelineLayout
    /// What the views draw, copied from the model (see `TimelineDrawState`).
    private(set) var drawState: TimelineDrawState
    /// The playhead's time, kept here so layout and drawing never read the
    /// playback controller (which would redraw them 60 times a second).
    private(set) var playheadTime: Time
    /// Model changes and drag previews wait here for the next frame.
    private var modelPending = false
    private var previewPending = false
    private lazy var pacer = FramePacer(view: self) { [weak self] in self?.applyPending() }

    init(model: EditorModel) {
        self.model = model
        self.artwork = MediaArtwork(analysis: model.session.analysis)
        self.layoutCache = TimelineLayout.make(project: model.project, showTranscript: model.showTranscript, heightOverrides: model.timeline.trackHeights)
        self.drawState = TimelineDrawState(model: model)
        self.playheadTime = model.playback.time
        super.init(frame: NSRect(x: 0, y: 0, width: 1_200, height: 320))
        wantsLayer = true
        // Since macOS 14 views don't clip drawing to their bounds by
        // default, and a dirty rect can reach past them. The timeline
        // fills its dirty rects, so it has to clip.
        clipsToBounds = true
        layer?.backgroundColor = Theme.window.cg
        for view in [ruler] + strips + stripHeaders + [headers, lanes, corner, scroller] as [TimelineChildView] {
            view.container = self
            addSubview(view)
        }
        reviewOverlay.container = self
        addSubview(reviewOverlay)
        addSubview(playheadView)
        cutButton.container = self
        addSubview(cutButton)
        model.timeline.showCommentBox = { [weak self] request in
            self?.showCommentBox(request)
        }
        model.timeline.playheadX = { [weak self] in
            guard let self else { return nil }
            return self.model.timeline.scale.x(self.model.playback.time)
        }
        loops.append(ObservationLoop(read: { [weak self] in self?.readDrawingState() }, onChange: { [weak self] in self?.modelChangeArrived() }))
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.model.playback.time }, onChange: { [weak self] in self?.playheadMoved() }))
        // A new tool changes what a press would do, so the cursor too.
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.model.tool }, onChange: { [weak self] in self?.lanes.refreshCursor() }))
        // New thumbnails, waveforms or transcripts: look again and redraw.
        // Job progress alone doesn't redraw the timeline.
        artwork.onDecoded = { [weak self] in self?.lanes.artworkDecoded() }
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.model.artworkRevision }, onChange: { [weak self] in
            self?.artwork.invalidate()
            self?.modelChangeArrived()
        }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        MainActor.assumeIsolated {
            for loop in loops { loop.cancel() }
        }
    }

    override var isFlipped: Bool { true }

    /// Touches everything the timeline draws, so the observation loop knows
    /// what to watch.
    private func readDrawingState() {
        _ = TimelineDrawState(model: model)
    }

    /// The model changed: the timeline catches up at the next frame.
    private func modelChangeArrived() {
        modelPending = true
        pacer.request()
    }

    private func applyPending() {
        let started = CACurrentMediaTime()
        defer { DrawTiming.record("timeline updates", CACurrentMediaTime() - started) }
        if modelPending {
            modelPending = false
            modelChanged()
        }
        if previewPending {
            previewPending = false
            if relayoutLanes() { headers.needsDisplay = true }
            lanes.previewDidChange()
            reviewOverlay.update()
        }
    }

    /// Copies the model's new state and redraws what it changed.
    private func modelChanged() {
        let old = drawState
        drawState = TimelineDrawState(model: model)
        let layoutChanged = relayoutLanes()
        let damage = TimelineDamage.between(old, drawState, layout: layoutCache, layoutChanged: layoutChanged)
        if damage.ruler {
            ruler.needsDisplay = true
            for view in strips { view.needsDisplay = true }
            for view in stripHeaders { view.needsDisplay = true }
        }
        // A strip comes and goes with its markers.
        if MarkerStrip.shown(in: drawState.project) != MarkerStrip.shown(in: old.project) { needsLayout = true }
        if damage.headers { headers.needsDisplay = true }
        if damage.lanesReshaped {
            lanes.reshaped()
        } else if damage.allLanes {
            lanes.redrawAll()
        } else {
            if damage.lanesMoved { lanes.lanesMoved() }
            if damage.lanesEdited { lanes.contentChanged() }
            for rect in damage.laneRects { lanes.redraw(rect) }
        }
        if old.scale != drawState.scale || old.showTranscript != drawState.showTranscript || old.revision != drawState.revision {
            lanes.playheadMoved(to: playheadTime)
        }
        if old.scale != drawState.scale || old.project.duration != drawState.project.duration {
            scroller.needsDisplay = true
        }
        positionPlayhead()
        reviewOverlay.update()
        model.refreshNearPlayhead()
        // A new track opens its name for typing.
        if model.timeline.renamingTrackID != nil { headers.syncRename() }
    }

    /// The lanes' drag or drop preview changed: at the next frame they
    /// redraw, and so do the headers when the lanes moved (a drop can add a
    /// track).
    func previewChanged() {
        previewPending = true
        pacer.request()
    }

    // MARK: - Painted positions

    /// The content point (x is seconds times pixels a second, y down from
    /// the top of the tracks) at the lanes' top left, on whole points so
    /// that painted tiles land on whole pixels wherever they're scrolled.
    var contentOrigin: CGPoint {
        let scale = drawState.scale
        return CGPoint(x: (scale.scrollSeconds * scale.pixelsPerSecond).rounded(), y: drawState.verticalOffset.rounded())
    }

    /// The scale the timeline is painted at: the model's, scrolled to a
    /// whole point.
    var drawScale: TimelineScale {
        let scale = drawState.scale
        return TimelineScale(pixelsPerSecond: scale.pixelsPerSecond, scrollSeconds: contentOrigin.x / scale.pixelsPerSecond)
    }

    // MARK: - Layout

    /// The project the lanes show: the drag preview while dragging.
    var displayedProject: Project { lanes.previewProject ?? drawState.project }

    /// Lays the lanes out again for the project shown, and says whether
    /// they moved.
    @discardableResult
    func relayoutLanes() -> Bool {
        let project = displayedProject
        let layout = TimelineLayout.make(project: project, showTranscript: drawState.showTranscript, heightOverrides: drawState.trackHeights)
        let changed = layout != layoutCache
        if changed { layoutCache = layout }
        clampVerticalOffset()
        return changed
    }

    /// The strip that holds `strip`'s markers.
    func stripView(_ strip: MarkerStrip) -> TimelineMarkerStripView {
        strips.first { $0.strip == strip }!
    }

    override func layout() {
        super.layout()
        let header = Theme.Metrics.trackHeaderWidth
        let rulerHeight = Theme.Metrics.rulerHeight
        // The strips that have something in them, top to bottom.
        let shown = MarkerStrip.shown(in: drawState.project)
        var top = rulerHeight
        for (view, label) in zip(strips, stripHeaders) {
            let height = shown.contains(view.strip) ? Theme.Metrics.markerStripHeight : 0
            label.frame = CGRect(x: 0, y: top, width: header, height: height)
            view.frame = CGRect(x: header, y: top, width: max(0, bounds.width - header), height: height)
            view.isHidden = height == 0
            label.isHidden = height == 0
            top += height
        }
        let barHeight = Theme.Metrics.timelineScrollerHeight
        let tracksHeight = max(0, bounds.height - top - barHeight)
        corner.frame = CGRect(x: 0, y: 0, width: header, height: rulerHeight)
        ruler.frame = CGRect(x: header, y: 0, width: max(0, bounds.width - header), height: rulerHeight)
        headers.frame = CGRect(x: 0, y: top, width: header, height: tracksHeight)
        lanes.frame = CGRect(x: header, y: top, width: max(0, bounds.width - header), height: tracksHeight)
        scroller.frame = CGRect(x: header, y: top + tracksHeight, width: max(0, bounds.width - header), height: barHeight)
        reviewOverlay.frame = lanes.frame
        let width = lanes.bounds.width
        if abs(model.timeline.lanesWidth - width) > 0.5 { model.timeline.lanesWidth = width }
        if model.timeline.fitPending && width > 200 {
            model.timeline.fit(model.project.duration)
            // Drawn at the fitted scale in this same pass, not the next.
            modelChanged()
        }
        clampVerticalOffset()
        positionPlayhead()
    }

    // MARK: - Comments

    /// Opens the comment box at the request's time: under its comment in
    /// the strip, or under the ruler while there are none. One at a time.
    func showCommentBox(_ request: CommentBoxRequest) {
        guard window != nil else { return }
        commentBox?.cancel()
        layoutSubtreeIfNeeded()
        let comments = stripView(.comments)
        let anchor: TimelineChildView = comments.isHidden ? ruler : comments
        let x = min(max(model.timeline.scale.x(request.time), 8), max(8, anchor.bounds.width - 8))
        let box = CommentBox(request: request, rate: model.frameRate) { [weak model] text in
            model?.saveComment(text, for: request)
        }
        commentBox = box
        box.show(pointingAt: CGRect(x: x - 1, y: 0, width: 2, height: anchor.bounds.height), in: anchor)
    }

    func clampVerticalOffset() {
        let maximum = max(0, layoutCache.contentHeight - lanes.bounds.height)
        let clamped = min(max(model.timeline.verticalOffset, 0), maximum)
        if clamped != model.timeline.verticalOffset { model.timeline.verticalOffset = clamped }
    }

    // MARK: - Playhead

    private func playheadMoved() {
        playheadTime = model.playback.time
        positionPlayhead()
        followPlayhead()
        lanes.playheadMoved(to: playheadTime)
        scroller.needsDisplay = true
        model.refreshNearPlayhead()
        model.notePlayhead()
    }

    func positionPlayhead() {
        let x = Theme.Metrics.trackHeaderWidth + drawScale.x(playheadTime)
        let width = Theme.Metrics.playheadHeadWidth
        let visible = x >= Theme.Metrics.trackHeaderWidth - width / 2 && x <= bounds.width + width
        playheadView.isHidden = !visible
        // Down to the scroll bar, which marks the playhead itself.
        let frame = CGRect(x: (x - width / 2).rounded(), y: Theme.Metrics.rulerHeight - Theme.Metrics.playheadHeadHeight + 2, width: width, height: max(0, bounds.height - Theme.Metrics.timelineScrollerHeight - Theme.Metrics.rulerHeight + Theme.Metrics.playheadHeadHeight - 2))
        if playheadView.frame != frame { playheadView.frame = frame }
        // The scissors ride the line where Mike left them, or at the top of
        // the tracks, under the transcript so they never hide the word
        // being said.
        let size = PlayheadCutButton.size
        let top: CGFloat
        if let resting = cutButton.restingY {
            top = min(max(resting, 4), lanes.frame.height - size.height - 4)
        } else {
            let firstTrack = layoutCache.lanes.first { !$0.isTranscript }?.y ?? 0
            top = max(0, firstTrack - contentOrigin.y) + 4
        }
        let button = CGRect(x: (x - size.width / 2).rounded(), y: (lanes.frame.minY + top).rounded(), width: size.width, height: size.height)
        if cutButton.frame != button {
            cutButton.frame = button
            cutButton.moved()
        }
        cutButton.isHidden = !visible || button.maxY > lanes.frame.maxY - 4
    }

    /// Pages the view along while playing, like Premiere.
    private func followPlayhead() {
        guard model.playback.isPlaying, lanes.bounds.width > 100 else { return }
        let x = model.timeline.scale.x(model.playback.time)
        let width = lanes.bounds.width
        if x > width - 20 || x < 0 {
            model.timeline.scale.scrollSeconds = model.playback.time.seconds - Double(width * (model.playback.rate >= 0 ? 0.1 : 0.9)) / model.timeline.scale.pixelsPerSecond
        }
    }

    // MARK: - Scrolling and zoom

    /// Horizontal gestures scroll time; vertical ones scroll the tracks when
    /// they don't fit, otherwise time. Option or Cmd with the wheel zooms
    /// around the playhead (the edge nearest it when it's off screen).
    func handleScroll(_ event: NSEvent) {
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 12
            dy *= 12
        }
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            // Around the playhead, as the zoom keys do, not the pointer:
            // the moment Mike's looking at stays put (Filmora's way).
            let factor = pow(1.01, Double(dy + dx))
            model.timeline.zoom(by: factor, anchorX: nil)
            return
        }
        let overflow = layoutCache.contentHeight > lanes.bounds.height + 1
        if abs(dx) >= abs(dy) || !overflow || event.modifierFlags.contains(.shift) {
            let delta = abs(dx) >= abs(dy) ? dx : dy
            let seconds = model.timeline.scale.scrollSeconds - Double(delta) / model.timeline.scale.pixelsPerSecond
            model.timeline.scale.scrollSeconds = min(max(0, seconds), maxScrollSeconds)
        } else {
            model.timeline.verticalOffset -= dy
            clampVerticalOffset()
        }
    }

    /// A pinch zooms around the playhead too.
    func handleMagnify(_ event: NSEvent) {
        model.timeline.zoom(by: 1 + Double(event.magnification), anchorX: nil)
    }

    /// How far right you can scroll: until the end of the project sits in
    /// the middle of the lanes.
    var maxScrollSeconds: Double {
        let visibleSeconds = Double(max(lanes.bounds.width, 100)) / model.timeline.scale.pixelsPerSecond
        return max(0, model.project.duration.seconds - visibleSeconds * 0.5)
    }

    override func scrollWheel(with event: NSEvent) {
        handleScroll(event)
    }

    // MARK: - Hand drag

    /// A middle-button drag in progress. The ruler, headers and lanes pass
    /// the button up to here, so a drag can start anywhere on the timeline,
    /// clips included: the middle button does nothing else.
    private var pan: TimelinePan?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        pan = TimelinePan(start: convert(event.locationInWindow, from: nil), scrollSeconds: model.timeline.scale.scrollSeconds, verticalOffset: model.timeline.verticalOffset)
        CursorKind.grabbing.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let pan else { return super.otherMouseDragged(with: event) }
        let next = pan.offsets(
            at: convert(event.locationInWindow, from: nil), pixelsPerSecond: model.timeline.scale.pixelsPerSecond,
            maxScrollSeconds: maxScrollSeconds, maxVerticalOffset: layoutCache.contentHeight - lanes.bounds.height
        )
        if next.scrollSeconds != model.timeline.scale.scrollSeconds { model.timeline.scale.scrollSeconds = next.scrollSeconds }
        if next.verticalOffset != model.timeline.verticalOffset { model.timeline.verticalOffset = next.verticalOffset }
        CursorKind.grabbing.set()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard pan != nil, event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        pan = nil
        NSCursor.arrow.set()
    }
}

/// A subview of the timeline that can reach its container.
class TimelineChildView: NSView {
    weak var container: TimelineContainerView?

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func scrollWheel(with event: NSEvent) {
        guard let container else { return super.scrollWheel(with: event) }
        container.handleScroll(event)
    }

    override func magnify(with event: NSEvent) {
        container?.handleMagnify(event)
    }
}

/// The amber playhead: a pentagon head on the ruler's edge and a line down
/// through the lanes. Moving it is a frame change, not a redraw.
final class PlayheadView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        let head = Theme.Metrics.playheadHeadHeight
        context.setFillColor(Theme.amber.cg)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: head / 2))
        path.addLine(to: CGPoint(x: width / 2, y: head))
        path.addLine(to: CGPoint(x: 0, y: head / 2))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
        let line = Theme.Metrics.playheadWidth
        context.fill(CGRect(x: width / 2 - line / 2, y: head - 2, width: line, height: bounds.height - head + 2))
    }
}

/// The selection box over the lanes: a tinted, outlined layer that moves
/// by changing its frame, so dragging it never redraws the clips under it.
final class MarqueeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.marqueeFill.cg
        layer?.borderColor = Theme.amber.opacity(0.7).cg
        layer?.borderWidth = 1
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the box at `rect`, in the lanes' view coordinates.
    func show(_ rect: CGRect) {
        let frame = rect.integral
        if self.frame != frame { self.frame = frame }
        isHidden = false
    }
}

/// Amber outlines over the clips a selection box is picking up, drawn by a
/// shape layer so the clips under them don't redraw while the box moves.
final class ClipOutlineView: NSView {
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = nil
        shape.strokeColor = Theme.amber.cg
        shape.lineWidth = 2
        shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shape)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        shape.frame = bounds
    }

    /// Shows `outlines`, in this view's (flipped) coordinates.
    func show(_ outlines: [Marquee.Outline]) {
        let path = CGMutablePath()
        for outline in outlines {
            path.addRoundedRect(in: outline.rect, cornerWidth: outline.radius, cornerHeight: outline.radius)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        // The path is in flipped view coordinates. Whether the layer's y
        // runs down too depends on the flips above it in the layer tree
        // (the backing layer itself isn't flipped, a parent is).
        if shape.contentsAreFlipped() {
            shape.path = path
        } else {
            var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
            shape.path = path.copy(using: &flip)
        }
        CATransaction.commit()
        isHidden = outlines.isEmpty
    }
}

/// The scissors on the playhead, as in Filmora: an amber pill on the line.
/// A click cuts at the playhead (Blade at playhead: the selected clips, or
/// every clip under it). A drag moves the playhead with the pointer's x and
/// slides the pill up or down the line with its y; it stays where it's left
/// (`restingY`, kept between launches). Hovering shows arrows either side,
/// and dragging swaps the scissors for a move sign.
@MainActor
final class PlayheadCutButton: TimelineChildView {
    static let size = CGSize(width: 22, height: 34)
    /// Where the pill was left on the line, in the app's preferences.
    static let restingKey = "playheadScissorsY"

    /// Points down from the top of the tracks where Mike left the pill, or
    /// nil for the top of the tracks, under the transcript.
    var restingY: CGFloat?
    var store: UserDefaults = AppDefaults.store {
        didSet { restingY = Self.restingY(in: store) }
    }

    var hovering = false { didSet { if hovering != oldValue { stateChanged() } } }
    var pressed = false { didSet { if pressed != oldValue { stateChanged() } } }
    var dragging = false { didSet { if dragging != oldValue { stateChanged() } } }
    /// The arrows either side that say it can be dragged.
    var showsArrows: Bool { !arrows.isHidden }

    private let arrows = CAShapeLayer()
    private var trackingArea: NSTrackingArea?
    /// Where the press was, how far from the line, and where the pill sat.
    private var press = (point: CGPoint.zero, fromLine: CGFloat(0), restingY: CGFloat(0))

    override init(frame: NSRect) {
        super.init(frame: frame)
        restingY = Self.restingY(in: store)
        // The arrows sit outside the pill.
        clipsToBounds = false
        let size = Self.size
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: -3, y: size.height / 2 - 4), CGPoint(x: -3, y: size.height / 2 + 4), CGPoint(x: -8, y: size.height / 2)])
        path.closeSubpath()
        path.addLines(between: [CGPoint(x: size.width + 3, y: size.height / 2 - 4), CGPoint(x: size.width + 3, y: size.height / 2 + 4), CGPoint(x: size.width + 8, y: size.height / 2)])
        path.closeSubpath()
        arrows.path = path
        arrows.fillColor = Theme.amber.cg
        arrows.isHidden = true
        layer?.addSublayer(arrows)
        updateTip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func restingY(in store: UserDefaults) -> CGFloat? {
        (store.object(forKey: restingKey) as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    /// Whether the pointer at `windowPoint` is on the pill.
    func isUnder(_ windowPoint: CGPoint) -> Bool {
        !isHidden && window != nil && bounds.contains(convert(windowPoint, from: nil))
    }

    /// The pill moved, maybe out from under a pointer that's standing
    /// still (the playhead playing on), which AppKit doesn't always say.
    func moved() {
        guard hovering, !dragging, let window else { return }
        if !isUnder(window.mouseLocationOutsideOfEventStream) { hovering = false }
    }

    private func stateChanged() {
        needsDisplay = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrows.isHidden = !hovering || dragging
        CATransaction.commit()
    }

    /// "Click to cut (⌘B)", with whatever key the keymap gives it now.
    private func updateTip() {
        let key = Shortcuts.symbol(for: .bladeAtPlayhead).map { " (\($0))" } ?? ""
        let tip = "Click to cut\(key)\nDrag to move the playhead"
        if toolTip != tip { toolTip = tip }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateTip()
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragging else { return }
        hovering = false
    }

    override func cursorUpdate(with event: NSEvent) {
        CursorKind.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let pill = bounds.insetBy(dx: 0.5, dy: 0.5)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: pill.width / 2, cornerHeight: pill.width / 2, transform: nil))
        context.setFillColor((pressed || dragging ? Theme.amberPressed : Theme.amber).cg)
        context.fillPath()
        guard let symbol = dragging ? Self.move : Self.scissors else { return }
        let size = symbol.size
        symbol.draw(in: CGRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(), width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Scissors standing up, blades at the top, like Filmora's.
    private static let scissors: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [Theme.onAmber.ns]))
        guard let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Cut")?.withSymbolConfiguration(config) else { return nil }
        let lying = symbol.size
        return NSImage(size: NSSize(width: lying.height, height: lying.width), flipped: false) { rect in
            // The symbol's blades point right; a quarter turn puts them up.
            let turn = NSAffineTransform()
            turn.translateX(by: rect.midX, yBy: rect.midY)
            turn.rotate(byDegrees: 90)
            turn.translateX(by: -lying.width / 2, yBy: -lying.height / 2)
            turn.concat()
            symbol.draw(in: CGRect(origin: .zero, size: lying))
            return true
        }
    }()

    private static let move: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold).applying(.init(paletteColors: [Theme.onAmber.ns]))
        return NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: "Move")?.withSymbolConfiguration(config)
    }()

    override func mouseDown(with event: NSEvent) {
        guard let container else { return }
        let point = event.locationInWindow
        press = (point, point.x - convert(CGPoint(x: bounds.midX, y: 0), to: nil).x, frame.minY - container.lanes.frame.minY)
        pressed = true
        dragging = false
        container.model.playback.pause()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let container else { return }
        let point = event.locationInWindow
        guard dragging || hypot(point.x - press.point.x, point.y - press.point.y) >= 3 else { return }
        dragging = true
        // Up and down slides the pill along the line (window y grows up)...
        let rise = point.y - press.point.y
        if restingY != nil || abs(rise) >= 3 { restingY = press.restingY - rise }
        // ...and left and right moves the playhead, keeping the pill under
        // the pointer where it was picked up.
        let model = container.model
        let x = container.lanes.convert(CGPoint(x: point.x - press.fromLine, y: point.y), from: nil).x
        model.playback.seek(to: model.timeline.scale.time(atX: x, rate: model.frameRate))
        container.positionPlayhead()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = false
            dragging = false
            hovering = isUnder(event.locationInWindow)
        }
        if dragging {
            guard let container, restingY != nil else { return }
            // Keep where it is, inside the tracks, not where the pointer went.
            restingY = frame.minY - container.lanes.frame.minY
            store.set(Double(restingY ?? 0), forKey: Self.restingKey)
            return
        }
        // The second click of a double-click has nothing left to cut.
        guard event.clickCount < 2 else { return }
        container?.model.cutAtPlayhead()
    }
}
