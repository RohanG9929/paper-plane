import Foundation

/// The helper's work (spec §5.2). Chrome starts `paperplane-host` for each message: it relays the
/// one request to the app's socket and the app's reply back, starting the app if nothing is
/// listening. Blocking calls throughout, for a command-line tool that does nothing else.
public enum HostRelay {
    struct SocketError: Error {
        var code: Int32
    }

    /// Reads one framed message from `input`, or nil if it's cut short or too large.
    public static func readRequest(from input: FileHandle) -> Data? {
        guard let header = read(4, from: input), let length = NativeMessaging.announcedLength(in: header),
              length < NativeMessaging.maximumLength
        else { return nil }
        return read(length, from: input)
    }

    /// Relays `request` to the app listening at `socket` and returns its reply. With nothing
    /// listening, calls `startApp` once and keeps trying for `startLimit` seconds; a reply that
    /// hasn't come within `replyLimit` seconds is given up on.
    public static func relay(_ request: Data, socket: URL, startApp: () -> Void,
                             startLimit: Double = 10, replyLimit: Double = 120) -> Data {
        guard let descriptor = connect(to: socket, startingApp: startApp, within: startLimit) else {
            return PlayReply.failed("Couldn't start Paper Plane.").encoded()
        }
        defer { close(descriptor) }
        do {
            try write(NativeMessaging.frame(request), to: descriptor)
            var buffer = Data()
            return try readFrame(from: descriptor, into: &buffer, limit: replyLimit)
        } catch {
            return PlayReply.failed("Paper Plane didn't answer.").encoded()
        }
    }

    /// The app bundle the helper is in: `…/Paper Plane.app/Contents/Helpers/paperplane-host`.
    public static func app(containing helper: URL) -> URL? {
        let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// Opens `app` without bringing it to the front; it comes forward itself when asked to play.
    public static func open(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", app.path]
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    // MARK: - Sockets

    private static func connect(to socket: URL, startingApp startApp: () -> Void, within limit: Double) -> Int32? {
        if let descriptor = try? connect(to: socket) {
            return descriptor
        }
        startApp()
        let deadline = Date(timeIntervalSinceNow: limit)
        while Date() < deadline {
            usleep(100_000)
            if let descriptor = try? connect(to: socket) {
                return descriptor
            }
        }
        return nil
    }

    static func connect(to socket: URL) throws -> Int32 {
        var address = sockaddr_un()
        let path = socket.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError(code: ENAMETOOLONG) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError(code: errno) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError(code: code)
        }
        // If the app closes early, a write fails instead of killing the helper with SIGPIPE.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { throw SocketError(code: errno) }
                offset += written
            }
        }
    }

    /// Reads until `buffer` holds a whole frame and returns its message. Throws when the other
    /// end closes first, the frame is too large, or `limit` seconds pass.
    static func readFrame(from descriptor: Int32, into buffer: inout Data, limit: Double) throws -> Data {
        let deadline = Date(timeIntervalSinceNow: limit)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let message = try NativeMessaging.take(from: &buffer) {
                return message
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SocketError(code: ETIMEDOUT) }
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(min(remaining, 3600) * 1000))
            if ready < 0, errno == EINTR {
                continue
            }
            guard ready >= 0 else { throw SocketError(code: errno) }
            guard ready > 0 else { continue }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            guard count > 0 else { throw SocketError(code: count == 0 ? ECONNRESET : errno) }
            buffer += chunk[0..<count]
        }
    }

    /// Exactly `count` bytes from `input`, or nil if it ends first.
    private static func read(_ count: Int, from input: FileHandle) -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? input.read(upToCount: count - data.count), !chunk.isEmpty else { return nil }
            data += chunk
        }
        return data
    }
}
