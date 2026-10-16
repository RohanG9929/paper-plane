import Foundation
import Testing
@testable import PaperPlaneCore

struct ProcessRunnerTests {
    @Test func capturesStdoutAndStatus() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"])
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n")
    }

    /// Work nobody waits on (converting subtitles) runs at background priority, which macOS also
    /// throttles for disk reads, so it doesn't compete with the video the TV is fetching.
    @Test func runsAtTheQualityOfServiceAsked() async throws {
        let priority: @Sendable (QualityOfService?) async throws -> String = { qos in
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                                     arguments: ["-c", "ps -o pri= -p $$"], qualityOfService: qos)
            return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try await priority(.background) == "4")
        #expect(try await priority(nil) != "4")
    }

    @Test func reportsNonZeroExitAndStderr() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo oops >&2; exit 3"])
        #expect(result.status == 3)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "oops\n")
    }

    @Test func handlesOutputLargerThanThePipeBuffer() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 1000000 /dev/zero; head -c 300000 /dev/zero >&2"])
        #expect(result.stdout.count == 1_000_000)
        #expect(result.stderr.count == 300_000)
    }

    /// waitUntilExit() can deadlock on the main thread, which Swift Testing sometimes runs tests on.
    @MainActor @Test(.timeLimit(.minutes(1)))
    func completesWhenAwaitedFromTheMainActor() async throws {
        for _ in 0..<20 {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
            #expect(result.status == 0)
        }
    }

    @Test func cancellingStopsTheChildAndThrows() async throws {
        let run = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        run.cancel()
        await #expect(throws: CancellationError.self) {
            try await run.value
        }
        // Returning early means the child exited: run() only returns once its pipes close.
        #expect(ContinuousClock.now - cancelledAt < .seconds(5))
    }

    /// yt-dlp reads the cookie from standard input (Milestone 4, decision 5).
    @Test(.timeLimit(.minutes(1))) func processRunnerFeedsStandardInput() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                                 input: Data("Cookie: a=1\n".utf8))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "Cookie: a=1\n")
    }

    /// A child that exits without reading what it was given doesn't take the app down with SIGPIPE.
    @Test func aChildThatIgnoresStandardInputIsFine() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                                                 input: Data(count: 1 << 20))
        #expect(result.status == 0)
    }

    @Test func processRunnerSetsTheEnvironment() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
                                                 environment: ["PAPERPLANE_TEST": "1"])
        #expect(String(decoding: result.stdout, as: UTF8.self) == "PAPERPLANE_TEST=1\n")
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        }
    }
}
