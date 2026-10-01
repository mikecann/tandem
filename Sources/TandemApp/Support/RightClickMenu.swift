import AppKit
import SwiftUI

/// One item in a `rightClickMenu`, or a separator.
struct MenuAction {
    var title: String
    var action: @MainActor () -> Void

    static let separator = MenuAction(title: "", action: {})

    var isSeparator: Bool { title.isEmpty }
}

extension View {
    /// A right-click (and Control-click) menu made by AppKit, as the
    /// timeline's are, so it works wherever AppKit's menus do and the input
    /// simulator can open it. The items are read when the menu opens.
    func rightClickMenu(_ items: @escaping () -> [MenuAction]) -> some View {
        overlay(RightClickMenu(items: items))
    }
}

private struct RightClickMenu: NSViewRepresentable {
    let items: () -> [MenuAction]

    func makeNSView(context: Context) -> RightClickMenuView {
        let view = RightClickMenuView()
        view.items = items
        return view
    }

    func updateNSView(_ view: RightClickMenuView, context: Context) {
        view.items = items
    }
}

/// A see-through view over a SwiftUI view that only takes right clicks and
/// Control-clicks, and answers them with its menu. Every other event goes
/// through to the view underneath.
final class RightClickMenuView: NSView {
    var items: () -> [MenuAction] = { [] }

    /// True while the event being handled opens a context menu.
    static var isContextClick: () -> Bool = {
        if InputSimulator.isOpeningMenu { return true }
        guard let event = NSApp.currentEvent else { return false }
        return event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.isContextClick() ? super.hitTest(point) : nil
    }

    override var acceptsFirstResponder: Bool { false }

    override func menu(for event: NSEvent) -> NSMenu? {
        let actions = items()
        guard !actions.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions {
            let run = action.action
            menu.addItem(action.isSeparator ? .separator() : ClosureMenuItem(action.title) { MainActor.assumeIsolated { run() } })
        }
        return menu
    }

    /// A Control-click opens the menu as a right click does.
    override func mouseDown(with event: NSEvent) {
        if let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
