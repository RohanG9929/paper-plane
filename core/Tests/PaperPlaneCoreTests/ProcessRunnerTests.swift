import Foundation
import Testing
@testable import PaperPlaneCore

struct ProcessRunnerTests {
    @Test func capturesStdoutAndStatus() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"])
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n")
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

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        }
    }
}
