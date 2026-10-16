import Foundation
import IOKit.pwr_mgt
import os

/// Keeps the Mac from idle-sleeping while a video plays on the TV (spec §6). The display may
/// still sleep, and closing a laptop's lid still sleeps it (a documented v1 limitation).
public final class SleepAssertion: Sendable {
    public static let defaultName = "Paper Plane is playing a video on your TV"
    /// What Activity Monitor and `pmset -g assertions` show.
    public let name: String
    /// The assertion's ID while held.
    private let held = OSAllocatedUnfairLock<IOPMAssertionID?>(initialState: nil)

    public init(name: String = SleepAssertion.defaultName) {
        self.name = name
    }

    deinit {
        hold(false)
    }

    /// Takes or releases the assertion. Calling it twice with the same value does nothing.
    public func hold(_ on: Bool) {
        held.withLock { held in
            if on, held == nil {
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                         IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                         name as CFString, &id)
                if result == kIOReturnSuccess {
                    held = id
                }
            } else if !on, let id = held {
                IOPMAssertionRelease(id)
                held = nil
            }
        }
    }

    public var isHeld: Bool {
        held.withLock { $0 != nil }
    }
}
