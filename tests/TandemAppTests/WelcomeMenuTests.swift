import AppKit
import XCTest
@testable import TandemApp

/// Right-clicking a project on the project list.
@MainActor
final class WelcomeMenuTests: XCTestCase {
    func testAProjectsMenuOffersOpenDuplicateFinderAndRemove() throws {
        guard NSScreen.screens.first != nil else { throw XCTSkip("no screen") }
        let controller = WelcomeWindowController(documents: ProjectDocuments.shared)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        window.setFrame(NSRect(x: -30_000, y: -30_000, width: 760, height: 480), display: false)
        controller.state.recent = [
            URL(fileURLWithPath: "/videos/eslint/ESLint.tandem"),
            URL(fileURLWithPath: "/videos/decision-models/Decision Models.tandem")
        ]
        window.orderBack(nil)
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-welcome-menu-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        // The first project's row, in the list on the right.
        InputSimulator.run(InputSimulator.Gesture(kind: .menu(out: out.path), at: CGPoint(x: 480, y: 100), modifiers: []), in: window)
        let menu = try String(contentsOf: out, encoding: .utf8)
        for item in ["Open", "Duplicate…", "Show in Finder", "Remove from Recent"] {
            XCTAssertTrue(menu.contains(item), "\(item) in:\n\(menu)")
        }
    }

    /// The menu's layer takes only the clicks that open menus; a plain
    /// click still opens the project, and hover still lights the row.
    func testOnlyMenuClicksStopAtTheMenusLayer() {
        let view = RightClickMenuView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let saved = RightClickMenuView.isContextClick
        defer { RightClickMenuView.isContextClick = saved }
        RightClickMenuView.isContextClick = { false }
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
        RightClickMenuView.isContextClick = { true }
        XCTAssertTrue(view.hitTest(NSPoint(x: 10, y: 10)) === view)
        view.items = { [MenuAction(title: "Open") {}, .separator, MenuAction(title: "Show in Finder") {}] }
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        XCTAssertEqual(view.menu(for: event)?.items.map(\.isSeparatorItem), [false, true, false])
    }
}
