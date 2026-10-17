import Foundation
import Testing
@testable import PaperPlaneCore

struct BackgroundProcessTests {
    /// The exit is reported only once stderr has been read to the end, so an error message
    /// written just before exiting is never cut off.
    @Test func exitWaitsForTheLastOfStderr() async throws {
        let process = try BackgroundProcess(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "(sleep 0.3; echo the-real-error >&2) & exit 1"])
        let status = await process.waitForExit()
        #expect(status == 1)
        #expect(String(decoding: process.stderr, as: UTF8.self).contains("the-real-error"))
    }

    /// A child that leaves stderr open (here an orphaned sleep) must not hold up the exit.
    @Test func exitIsReportedEvenIfStderrStaysOpen() async throws {
        let process = try BackgroundProcess(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & exit 3"])
        let started = ContinuousClock.now
        let status = await process.waitForExit()
        #expect(status == 3)
        #expect(ContinuousClock.now - started < TestSupport.promptly(3))
    }

    @Test func signalsReachOnlyALiveProcess() async throws {
        let process = try BackgroundProcess(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        #expect(process.exitStatus == nil)
        process.send(SIGTERM)
        #expect(await process.waitForExit() == SIGTERM) // Foundation reports the signal number
        process.send(SIGTERM) // already gone: nothing happens
    }
}
