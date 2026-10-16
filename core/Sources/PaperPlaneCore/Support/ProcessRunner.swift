import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Runs a command to completion and captures its output. Cancelling the calling task
/// terminates the child and throws `CancellationError`.
enum ProcessRunner {
    /// `qualityOfService` `.background` also has macOS throttle the child's disk reads.
    static func run(_ executable: URL, arguments: [String],
                    qualityOfService: QualityOfService? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let qualityOfService {
            process.qualityOfService = qualityOfService
        }
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
        let running = RunningProcess(process)

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        return try await withTaskCancellationHandler {
            // Drain both pipes at the same time so a full pipe buffer can't stall the child.
            async let stdout = readToEnd(stdoutHandle)
            async let stderr = readToEnd(stderrHandle)
            let (out, err) = await (stdout, stderr)
            var status: Int32 = -1
            for await code in exits {
                status = code
            }
            try Task.checkCancellation()
            return ProcessResult(status: status, stdout: out, stderr: err)
        } onCancel: {
            running.terminate()
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}

/// Lets the cancellation handler, which can run on any thread, stop the child.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        process.terminate()
    }
}
