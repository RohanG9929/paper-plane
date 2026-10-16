import Darwin
import Foundation
import os

/// Starting a child as its own "responsible process" (security review, Plan 5). macOS grants a
/// child its parent's privacy permissions (Desktop, Documents, Downloads, …) unless the parent
/// disclaims responsibility for it, as browsers do for their helpers. yt-dlp, which may be a copy
/// downloaded into Application Support, runs that way, so neither it nor anything put in its
/// place can borrow Paper Plane's permissions.
extension ProcessRunner {
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// `responsibility_spawnattrs_setdisclaim`, a private call in libsystem since macOS 10.14.
    private static let disclaim: Disclaim? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") // RTLD_DEFAULT
            .map { unsafeBitCast($0, to: Disclaim.self) }

    /// Whether this macOS lets a child be started disclaimed.
    static var canDisclaim: Bool {
        disclaim != nil
    }

    /// `run`, with the child started by posix_spawn as its own responsible process.
    static func runDisclaimed(_ executable: URL, arguments: [String], input: Data?,
                              environment: [String: String]?) async throws -> ProcessResult {
        guard let disclaim else { throw POSIXError(.ENOTSUP) }
        let stdin = try Self.pipe(), stdout = try Self.pipe(), stderr = try Self.pipe()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin.read, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout.write, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr.write, 2)
        // It starts in the temporary folder: without the app's permissions it may not be able to
        // read the app's own working folder (in Documents, say).
        posix_spawn_file_actions_addchdir_np(&actions, FileManager.default.temporaryDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the child, with default signal handling.
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        guard disclaim(&attributes, 1) == 0 else { throw POSIXError(.EINVAL) }

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0)=\($1)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        // The child's ends are the child's now (or nobody's, if it didn't start).
        close(stdin.read)
        close(stdout.write)
        close(stderr.write)
        guard spawned == 0 else {
            close(stdin.write)
            close(stdout.read)
            close(stderr.read)
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
        }

        let child = SpawnedChild(pid: pid)
        let stdinHandle = FileHandle(fileDescriptor: stdin.write, closeOnDealloc: true)
        if let input {
            feed(input, to: stdinHandle)
        } else {
            try? stdinHandle.close()
        }
        let stdoutHandle = FileHandle(fileDescriptor: stdout.read, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: stderr.read, closeOnDealloc: true)
        return try await withTaskCancellationHandler {
            async let out = readToEnd(stdoutHandle)
            async let err = readToEnd(stderrHandle)
            let (output, errors) = await (out, err)
            let status = await child.exit()
            try Task.checkCancellation()
            return ProcessResult(status: status, stdout: output, stderr: errors)
        } onCancel: {
            child.terminate()
        }
    }

    /// A pipe whose ends don't leak into other children.
    private static func pipe() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard Darwin.pipe(&ends) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        ends.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        return (ends[0], ends[1])
    }
}

/// A spawned child: waited for on a thread of its own, and signalled only until it's reaped, so a
/// reused process ID is never signalled by mistake.
private final class SpawnedChild: Sendable {
    let pid: pid_t
    private let state = OSAllocatedUnfairLock(initialState: (reaped: false, status: Int32?.none))
    private let exited: AsyncStream<Int32>

    init(pid: pid_t) {
        self.pid = pid
        let (stream, continuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        exited = stream
        let state = state
        DispatchQueue.global().async {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
            // Exited: its code; killed by a signal: 128 plus the signal, as shells report it.
            let signal = raw & 0x7F
            let status = signal == 0 ? (raw >> 8) & 0xFF : 128 + signal
            state.withLock { $0 = (true, status) }
            continuation.yield(status)
            continuation.finish()
        }
    }

    func exit() async -> Int32 {
        for await status in exited {
            return status
        }
        return state.withLock { $0.status } ?? -1
    }

    func terminate() {
        state.withLock { state in
            if !state.reaped {
                kill(pid, SIGTERM)
            }
        }
    }
}
