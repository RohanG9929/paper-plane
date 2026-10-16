import Foundation
import os

/// A long-running child process (ffmpeg converting a video). Its exit can be awaited from any
/// number of tasks, it can be paused and stopped with signals, and the end of its stderr is
/// kept for error messages.
final class BackgroundProcess: @unchecked Sendable {
    private struct State {
        /// Set the moment the process exits. No signal is sent after this: its ID may be reused.
        var terminationStatus: Int32?
        var stderrClosed = false
        /// Published once the process has exited and its stderr has been read to the end, so
        /// an error written just before exiting is never cut off.
        var exitStatus: Int32?
        var exitWaiters: [CheckedContinuation<Int32, Never>] = []
        var stderrTail = Data()
    }

    private static let stderrLimit = 64 * 1024
    /// How long to wait for stderr to close after the exit. A child the process left behind
    /// can hold it open indefinitely.
    private static let stderrGrace = DispatchTimeInterval.seconds(1)
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
                state.withLock { $0.stderrClosed = true }
                Self.publishExit(state)
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
            state.withLock { $0.terminationStatus = status }
            Self.publishExit(state)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.stderrGrace) {
                Self.publishExit(state, evenIfStderrIsOpen: true)
            }
        }
        try process.run()
    }

    /// Publishes the exit to `exitStatus` and the waiters once, when the process has exited
    /// and stderr has closed.
    private static func publishExit(_ state: OSAllocatedUnfairLock<State>, evenIfStderrIsOpen: Bool = false) {
        let (status, waiters) = state.withLock { state -> (Int32?, [CheckedContinuation<Int32, Never>]) in
            guard state.exitStatus == nil, let status = state.terminationStatus,
                  state.stderrClosed || evenIfStderrIsOpen
            else { return (nil, []) }
            state.exitStatus = status
            defer { state.exitWaiters = [] }
            return (status, state.exitWaiters)
        }
        if let status {
            waiters.forEach { $0.resume(returning: status) }
        }
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
            if state.terminationStatus == nil {
                kill(process.processIdentifier, signal)
            }
        }
    }
}
