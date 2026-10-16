import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Runs a command to completion and captures its output.
enum ProcessRunner {
    static func run(_ executable: URL, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        // Learn the exit status from the termination handler: waitUntilExit() deadlocks when it
        // runs on the main thread, because Foundation can need that thread to report the exit.
        let (exits, exitContinuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }
        try process.run()

        // Drain both pipes at the same time so a full pipe buffer can't stall the child.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        async let stdout = readToEnd(stdoutHandle)
        async let stderr = readToEnd(stderrHandle)
        let (out, err) = await (stdout, stderr)
        var status: Int32 = -1
        for await code in exits {
            status = code
        }
        return ProcessResult(status: status, stdout: out, stderr: err)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
