import Foundation
import IOKit.pwr_mgt

final class SleepPrevention {
    private var assertion: IOPMAssertionID?

    var isActive: Bool { assertion != nil }

    @discardableResult
    func setActive(_ active: Bool) -> IOReturn {
        if let assertion {
            guard !active else { return kIOReturnSuccess }
            let result = IOPMAssertionRelease(assertion)
            if result == kIOReturnSuccess { self.assertion = nil }
            return result
        }
        guard active else { return kIOReturnSuccess }

        var id: IOPMAssertionID = 0
        // Prevent idle system sleep on battery or AC while allowing display sleep.
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacSignal: Prevent Sleep" as CFString, &id)
        if result == kIOReturnSuccess { assertion = id }
        return result
    }

    deinit { setActive(false) }
}
