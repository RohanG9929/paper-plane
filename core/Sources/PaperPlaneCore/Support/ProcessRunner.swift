import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Runs a command to completion and captures its output. Cancelling the calling task
/// terminates the child and throws `CancellationError`.
enum ProcessRunner {
    /// `input` is written to the child's standard input, which is otherwise empty. `environment`
    /// replaces the app's. `qualityOfService` `.background` also has macOS throttle the child's
    /// disk reads. With `disclaimsResponsibility`, the child gets none of the app's privacy
    /// permissions (DisclaimedSpawn.swift).
    static func run(_ executable: URL, arguments: [String], input: Data? = nil, environment: [String: String]? = nil,
                    qualityOfService: QualityOfService? = nil, disclaimsResponsibility: Bool = false) async throws -> ProcessResult {
        if disclaimsResponsibility {
            return try await runDisclaimed(executable, arguments: arguments, input: input, environment: environment)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let qualityOfService {
            process.qualityOfService = qualityOfService
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = input.map { _ in Pipe() }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        // Learn the exit status from the termination handler: waitUntilExit() deadlocks when it
        // runs on the main thread, because Foundation can need that thread to report the exit.
        let (exits, exitContinuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }
        try process.run()
        let running = RunningProcess(process)
        if let input, let stdinPipe {
            feed(input, to: stdinPipe.fileHandleForWriting)
        }

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

    /// Writes `data` on another thread, so a child that reads slowly can't hold the caller up, and
    /// without SIGPIPE, so a child that exits without reading can't take the app down with it.
    static func feed(_ data: Data, to handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global().async {
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, base + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        break // the child closed its end
                    }
                }
            }
            try? handle.close()
        }
    }

    static func readToEnd(_ handle: FileHandle) async -> Data {
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
