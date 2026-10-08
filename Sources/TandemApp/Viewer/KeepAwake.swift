import Foundation
import TandemRender

/// Keeps the display awake while the timeline plays, as a video player
/// does, so the screen saver and the lock screen don't come up in the
/// middle of a watch-through. Paused, the Mac sleeps as it usually would.
@MainActor
final class KeepAwake {
    private var assertion: PowerAssertion?

    var isHeld: Bool { assertion != nil }

    /// Holds the display awake, or lets it go.
    func hold(_ awake: Bool) {
        if awake, assertion == nil {
            assertion = PowerAssertion(.display, reason: "Tandem is playing the timeline")
        } else if !awake, let assertion {
            assertion.release()
            self.assertion = nil
        }
    }
}
