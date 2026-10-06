import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while the timeline plays, as a video player
/// does, so the screen saver and the lock screen don't come up in the
/// middle of a watch-through. Paused, the Mac sleeps as it usually would.
@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID?

    var isHeld: Bool { assertion != nil }

    /// Holds the display awake, or lets it go.
    func hold(_ awake: Bool) {
        if awake, assertion == nil {
            var id = IOPMAssertionID(0)
            let made = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Tandem is playing the timeline" as CFString,
                &id
            )
            if made == kIOReturnSuccess { assertion = id }
        } else if !awake, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
