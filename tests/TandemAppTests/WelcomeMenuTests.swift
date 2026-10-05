import AppKit
import XCTest
@testable import TandemApp
import TandemCore

/// Right-clicking a project on the project list.
@MainActor
final class WelcomeMenuTests: XCTestCase {
    func testAProjectsMenuOffersOpenDuplicateFinderAndRemove() throws {
        guard NSScreen.screens.first != nil else { throw XCTSkip("no screen") }
        let controller = WelcomeWindowController(documents: ProjectDocuments.shared)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        EditorHarness.placeOffscreen(window, size: CGSize(width: 760, height: 480))
        controller.state.recent = [
            URL(fileURLWithPath: "/videos/eslint/ESLint.tandem"),
            URL(fileURLWithPath: "/videos/decision-models/Decision Models.tandem")
        ]
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
        for item in ["Open", "Rename…", "Duplicate…", "Show in Finder", "Remove from Recent"] {
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

    /// Two projects with the same name tell apart by their files.
    func testAWindowSaysWhichFileItIs() throws {
        let editor = try EditorHarness()
        defer { editor.close() }
        XCTAssertEqual(editor.model.shortPath, "\(editor.model.folderName)/Behaviour.tandem")
        XCTAssertEqual(editor.model.windowTitle, "Behaviour", "the file goes by the project's name")
        editor.model.apply(EditBatch(label: "Rename", commands: [.updateProject(patch: .object(["name": .string("Behaviour v2")]))]))
        editor.settle()
        XCTAssertEqual(editor.model.windowTitle, "Behaviour v2 · Behaviour.tandem")
        XCTAssertEqual(editor.window.title, "Behaviour v2 · Behaviour.tandem", "the Window menu follows a rename")
    }

    /// A renamed project keeps its place in the list, and its timeline and
    /// window come back where they were.
    func testARenamedProjectKeepsItsPlace() throws {
        var recent = RecentProjects(paths: ["/v/a/A.tandem", "/v/b/B.tandem", "/v/c/C.tandem"])
        recent.replace("/v/b/B.tandem", with: "/v/b/Better.tandem")
        XCTAssertEqual(recent.paths, ["/v/a/A.tandem", "/v/b/Better.tandem", "/v/c/C.tandem"])
        recent.replace("/v/x/Gone.tandem", with: "/v/x/New.tandem")
        XCTAssertEqual(recent.paths.first, "/v/x/New.tandem", "one that wasn't listed goes on top")

        let name = "tandem-rename-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        let old = URL(fileURLWithPath: "/v/b/B.tandem")
        let new = URL(fileURLWithPath: "/v/b/Better.tandem")
        TimelinePlacement.save(TimelinePlacement.Saved(playhead: 42, pixelsPerSecond: 20, scrollSeconds: 30, verticalOffset: 0), for: old, to: store)
        WindowPlacement.save(NSRect(x: 10, y: 10, width: 1_200, height: 800), for: old, to: store)
        TimelinePlacement.move(from: old, to: new, in: store)
        WindowPlacement.move(from: old, to: new, in: store)
        XCTAssertEqual(TimelinePlacement.saved(for: new, in: store)?.playhead, 42)
        XCTAssertNil(TimelinePlacement.saved(for: old, in: store))
        XCTAssertEqual(WindowPlacement.saved(for: new, in: store), NSRect(x: 10, y: 10, width: 1_200, height: 800))
    }
}
