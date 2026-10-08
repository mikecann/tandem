import AppKit
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// A real editor window, offscreen, driven the way Mike drives it: keys go
/// through the keymap and the keyboard router, clicks, drags and drops go
/// to the views under the pointer (`InputSimulator`), and the tests check
/// what changed. Behaviour tests use it to catch a feature that still
/// passes its own unit tests but no longer works from the keyboard or the
/// mouse.
///
/// The project is `AppFixture`'s miniature of Mike's timeline: a 60 s take
/// (camera, screen and camera sound, linked), a B-roll shot at 20 to 25
/// from 1 s into a 10 s file, a music bed, and a section marker at 30. The
/// timeline shows 20 points a second from 0.
@MainActor
final class EditorHarness {
    let folder: URL
    let model: EditorModel
    let controller: ProjectWindowController
    var window: NSWindow { controller.window! }
    private let previousKeymap: Keymap

    init(file: StaticString = #filePath, line: UInt = #line) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-behaviour-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Behaviour.tandem"), name: "Behaviour", owner: .app)
        model = EditorModel(session: session)
        let fixture = try AppFixture()
        model.apply(EditBatch(label: "Media", commands: fixture.project.media.map { .addMedia(item: $0) }))
        model.apply(EditBatch(label: "Build", commands: [
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60)),
            .placeMedia(mediaIDs: ["med_broll"], at: t(20), sourceStart: t(1), duration: t(5)),
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(60)),
            .addMarker(marker: Marker(id: "mk_s2", time: t(30), name: "Section 2", kind: .section))
        ]))
        let keymap = try Keymap.load(KeymapTests.bundledKeymapData())
        // The buttons' tooltips and ⌘ hints read the app's keymap.
        previousKeymap = ProjectDocuments.shared.keymap
        ProjectDocuments.shared.keymap = keymap
        EditorWindow.staysWhereItsPut = true
        controller = ProjectWindowController(model: model, keymap: keymap, frame: NSRect(x: -30_000, y: -30_000, width: 1_600, height: 1_000))
        EditorHarness.placeOffscreen(controller.window!, size: CGSize(width: 1_600, height: 1_000))
        model.timeline.fitPending = false
        model.timeline.scale = TimelineScale(pixelsPerSecond: 20, scrollSeconds: 0)
        settle()
    }

    /// AppKit puts a titled window back on a screen when it's ordered in,
    /// shrunk to fit: on a laptop screen the timeline lost its lower tracks
    /// and clicks on them missed. Ordered in unseen first, then moved, it
    /// stays offscreen at the size the tests expect.
    static func placeOffscreen(_ window: NSWindow, size: CGSize) {
        window.alphaValue = 0
        window.orderBack(nil)
        window.setFrame(NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), display: false)
    }

    func close() {
        ProjectDocuments.shared.keymap = previousKeymap
        // Where its window and timeline were isn't worth remembering.
        let path = model.fileURL.standardizedFileURL.path
        let store = AppDefaults.store
        if var frames = store.dictionary(forKey: WindowPlacement.projectsKey) as? [String: String], frames.removeValue(forKey: path) != nil {
            store.set(frames, forKey: WindowPlacement.projectsKey)
        }
        if var timelines = store.dictionary(forKey: TimelinePlacement.key) as? [String: [String: Double]], timelines.removeValue(forKey: path) != nil {
            store.set(timelines, forKey: TimelinePlacement.key)
        }
        window.orderOut(nil)
        EditorWindow.staysWhereItsPut = false
        model.tearDown()
        _ = model.session.close()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Lets observation, layout and anything queued on the main thread
    /// catch up: for `seconds`, and for at least `minimumTurns` turns of
    /// the run loop.
    func settle(_ seconds: TimeInterval = 0.25) {
        let end = Date().addingTimeInterval(seconds)
        var turns = 0
        while Date() < end || turns < Self.minimumTurns {
            turns += 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// A model change reaches the views over a few turns: the observation
    /// loop hears of it on one, the timeline's frame pacer copies it on
    /// the next, and only then are the strips and lanes laid out where a
    /// click lands. On a CI runner one turn of drawing can take longer
    /// than the whole quarter second, so a wait counted only in time
    /// clicked the old layout: a click meant for a comment moved the
    /// playhead, and a transition dropped on a clip missed it. With every
    /// turn slowed to 0.4 s the behaviour tests pass with three, and two
    /// isn't enough.
    static let minimumTurns = 3

    // MARK: - The project

    var project: Project { model.project }

    func clips(_ track: String) -> [Clip] { project.track(named: track)?.clips ?? [] }

    func clip(_ track: String, _ index: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> Clip {
        let all = clips(track)
        guard all.indices.contains(index) else {
            XCTFail("\(track) has no clip \(index)", file: file, line: line)
            return Clip(content: .adjustment, start: .zero, duration: t(1))
        }
        return all[index]
    }

    // MARK: - Keys

    /// Presses a chord written as in a keymap file: `c`, `shift+delete`,
    /// `cmd+shift+a`, `option+]`.
    @discardableResult
    func press(_ chord: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let parsed = KeyChord(chord) else {
            XCTFail("\(chord) isn't a chord", file: file, line: line)
            return false
        }
        let used = controller.router.route(parsed, keyUp: false, isRepeat: false)
        _ = controller.router.route(parsed, keyUp: true, isRepeat: false)
        settle()
        return used
    }

    // MARK: - The mouse

    /// Where a clip is drawn, in window points from the top left, at
    /// `time` (timeline seconds) or across its middle.
    func point(of clipID: String, at time: Double? = nil, file: StaticString = #filePath, line: UInt = #line) -> CGPoint {
        guard let lanes = view(TimelineLanesView.self), let container = view(TimelineContainerView.self),
              let track = project.track(containingClip: clipID), let clip = project.clip(clipID),
              let lane = container.layoutCache.lanes.first(where: { $0.trackID == track.id }) else {
            XCTFail("clip \(clipID) isn't on the timeline", file: file, line: line)
            return .zero
        }
        let tester = TimelineHitTester(project: project, layout: container.layoutCache, scale: model.timeline.scale)
        let rect = tester.rect(of: clip, in: lane)
        let x = time.map { CGFloat(model.timeline.scale.x(t($0))) } ?? rect.midX
        let inView = CGPoint(x: x, y: rect.midY - model.timeline.verticalOffset)
        let inWindow = lanes.convert(inView, to: nil)
        return CGPoint(x: inWindow.x, y: frameHeight - inWindow.y)
    }

    /// A point on the track named `track` at `seconds`, in window points
    /// from the top left: on an empty stretch, nothing's there.
    func point(onTrack track: String, at seconds: Double) -> CGPoint {
        guard let lanes = view(TimelineLanesView.self), let container = view(TimelineContainerView.self),
              let id = project.track(named: track)?.id,
              let lane = container.layoutCache.lanes.first(where: { $0.trackID == id }) else { return .zero }
        let inView = CGPoint(x: CGFloat(model.timeline.scale.x(t(seconds))), y: lane.y + lane.height / 2 - model.timeline.verticalOffset)
        let inWindow = lanes.convert(inView, to: nil)
        return CGPoint(x: inWindow.x, y: frameHeight - inWindow.y)
    }

    /// A point in the comments strip at `seconds`, in window points from
    /// the top left: half a second in, it's on a comment that starts there.
    func commentsPoint(at seconds: Double) -> CGPoint {
        stripPoint(.comments, at: seconds)
    }

    /// A point in a strip under the ruler at `seconds`, in window points
    /// from the top left.
    func stripPoint(_ which: MarkerStrip, at seconds: Double) -> CGPoint {
        guard let strip = view(TimelineContainerView.self)?.stripView(which) else { return .zero }
        let inWindow = strip.convert(CGPoint(x: CGFloat(model.timeline.scale.x(t(seconds))), y: strip.bounds.midY), to: nil)
        return CGPoint(x: inWindow.x, y: frameHeight - inWindow.y)
    }

    /// A point on the ruler just right of `seconds`, where a marker or
    /// comment there is drawn, in window points from the top left.
    func rulerPoint(at seconds: Double) -> CGPoint {
        guard let ruler = view(TimelineRulerView.self) else { return .zero }
        let inWindow = ruler.convert(CGPoint(x: CGFloat(model.timeline.scale.x(t(seconds))) + 6, y: 10), to: nil)
        return CGPoint(x: inWindow.x, y: frameHeight - inWindow.y)
    }

    /// Moves the pointer to `point` (window points from the top left).
    func hover(_ point: CGPoint) {
        run(InputSimulator.Gesture(kind: .hover, at: point, modifiers: []))
    }

    /// A point in `view`'s own coordinates as window points from the top left.
    func windowPoint(_ point: CGPoint, in view: NSView) -> CGPoint {
        let inWindow = view.convert(point, to: nil)
        return CGPoint(x: inWindow.x, y: frameHeight - inWindow.y)
    }

    /// The middle of the toolbar control whose tooltip starts with
    /// `prefix`, found by its `.tip` anchor, in window points from the top
    /// left: how a test finds a SwiftUI button to click.
    func point(ofTip prefix: String) -> CGPoint? {
        func find(_ view: NSView) -> NSView? {
            if view is TipAnchorView, view.toolTip?.hasPrefix(prefix) == true { return view }
            for subview in view.subviews {
                if let found = find(subview) { return found }
            }
            return nil
        }
        guard let root = window.contentView?.superview ?? window.contentView, let anchor = find(root) else { return nil }
        return windowPoint(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), in: anchor)
    }

    func click(_ point: CGPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        run(InputSimulator.Gesture(kind: .click(count: count), at: point, modifiers: modifiers))
    }

    /// The titles of the right-click menu at `point`.
    func menu(at point: CGPoint) throws -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-menu-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        run(InputSimulator.Gesture(kind: .menu(out: out.path), at: point, modifiers: []))
        return try String(contentsOf: out, encoding: .utf8)
    }

    /// Picks the item called `title` from the right-click menu at `point`,
    /// as if clicked. Items in submenus are found too.
    func choose(_ title: String, at point: CGPoint) {
        run(InputSimulator.Gesture(kind: .choose(title), at: point, modifiers: []))
    }

    func drag(_ from: CGPoint, to: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        run(InputSimulator.Gesture(kind: .drag(to: to, steps: 12), at: from, modifiers: modifiers))
    }

    /// Drops a library item (`tandem-transition:push`, `tandem-effect:...`)
    /// at a point, as if dragged there from its tab.
    func drop(_ payload: String, at point: CGPoint) {
        run(InputSimulator.Gesture(kind: .drop(payload: payload), at: point, modifiers: []))
    }

    /// The x a timeline time is drawn at, in window points from the left.
    func x(at seconds: Double) -> CGFloat {
        guard let lanes = view(TimelineLanesView.self) else { return 0 }
        return lanes.convert(CGPoint(x: CGFloat(model.timeline.scale.x(t(seconds))), y: 0), to: nil).x
    }

    private func run(_ gesture: InputSimulator.Gesture) {
        InputSimulator.run(gesture, in: window)
        settle()
    }

    private var frameHeight: CGFloat {
        (window.contentView?.superview ?? window.contentView)?.bounds.height ?? 0
    }

    /// The first view of a type in the window.
    func view<V: NSView>(_ type: V.Type) -> V? {
        func find(_ view: NSView) -> V? {
            if let match = view as? V { return match }
            for subview in view.subviews {
                if let match = find(subview) { return match }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }
}
