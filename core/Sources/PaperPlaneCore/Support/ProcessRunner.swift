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
        try process.run()

        // Drain both pipes at the same time so a full pipe buffer can't stall the child.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        async let stdout = readToEnd(stdoutHandle)
        async let stderr = readToEnd(stderrHandle)
        let (out, err) = await (stdout, stderr)
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: out, stderr: err)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
