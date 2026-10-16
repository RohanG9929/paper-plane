import Foundation
import IOKit.pwr_mgt
import Testing
@testable import PaperPlaneCore

struct SleepAssertionTests {
    /// How many of this process's power assertions are called `name`, as the system reports them.
    static func count(named name: String) -> Int {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return 0 }
        let mine = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return mine.filter { $0[kIOPMAssertionNameKey as String] as? String == name }.count
    }

    /// Each test names its own assertion: tests run in parallel in one process.
    let name = "Paper Plane test \(UUID().uuidString)"

    @Test func holdsAndReleasesAnIdleSleepAssertion() {
        let assertion = SleepAssertion(name: name)
        assertion.hold(true)
        #expect(assertion.isHeld)
        #expect(Self.count(named: name) == 1)
        assertion.hold(true) // a second hold doesn't stack
        #expect(Self.count(named: name) == 1)

        assertion.hold(false)
        #expect(!assertion.isHeld)
        #expect(Self.count(named: name) == 0)
        assertion.hold(false) // nor does a second release
    }

    @Test func releasesWhenGone() {
        var assertion: SleepAssertion? = SleepAssertion(name: name)
        assertion?.hold(true)
        #expect(Self.count(named: name) == 1)
        assertion = nil
        #expect(Self.count(named: name) == 0)
    }
}
