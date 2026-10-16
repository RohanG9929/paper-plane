import Foundation
import os

/// A long-running child process (ffmpeg converting a video). Its exit can be awaited from any
/// number of tasks, it can be paused and stopped with signals, and the end of its stderr is
/// kept for error messages.
final class BackgroundProcess: @unchecked Sendable {
    private struct State {
        var exitStatus: Int32?
        var exitWaiters: [CheckedContinuation<Int32, Never>] = []
        var stderrTail = Data()
    }

    private static let stderrLimit = 64 * 1024
    private let process = Process()
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ executable: URL, arguments: [String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let state = state
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            state.withLock { state in
                state.stderrTail.append(chunk)
                if state.stderrTail.count > Self.stderrLimit {
                    state.stderrTail.removeFirst(state.stderrTail.count - Self.stderrLimit)
                }
            }
        }
        // Like ProcessRunner, learn the exit from the termination handler: waitUntilExit()
        // deadlocks on the main thread.
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let waiters = state.withLock { state in
                state.exitStatus = status
                defer { state.exitWaiters = [] }
                return state.exitWaiters
            }
            waiters.forEach { $0.resume(returning: status) }
        }
        try process.run()
    }

    /// nil while the process is running.
    var exitStatus: Int32? {
        state.withLock { $0.exitStatus }
    }

    /// The last 64 KB the process wrote to stderr.
    var stderr: Data {
        state.withLock { $0.stderrTail }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = state.withLock { state in
                if state.exitStatus == nil {
                    state.exitWaiters.append(continuation)
                }
                return state.exitStatus
            }
            if let status {
                continuation.resume(returning: status)
            }
        }
    }

    /// Sends `signal` (SIGSTOP, SIGCONT, SIGTERM, SIGKILL) unless the process has exited, so a
    /// recycled process ID never gets it.
    func send(_ signal: Int32) {
        state.withLock { state in
            if state.exitStatus == nil {
                kill(process.processIdentifier, signal)
            }
        }
    }
}
