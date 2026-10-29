import AppKit
import TandemCrashReports

// First, so a crash while launching is caught too. Only the installed
// release app reports (see CrashReports).
CrashReports.start(component: "mac")

// Tandem's entry point. AppKit owns the app lifecycle (so project windows,
// the keymap and the tandem:// URL scheme are under our control); the
// panels inside each window are SwiftUI.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
    _ = delegate
}
