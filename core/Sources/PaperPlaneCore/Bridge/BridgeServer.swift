import Foundation
import Network
import os

/// The app's end of the browser bridge (spec §5.2): a Unix-domain socket only this user can
/// connect to. Each connection carries one framed play request and gets one framed reply.
public final class BridgeServer: Sendable {
    public enum Failure: Error, Equatable {
        /// Longer than a socket address holds (104 bytes, with its terminating zero).
        case pathTooLong
        case cannotListen(String)
    }

    /// Where the app listens: `~/Library/Application Support/Paper Plane/bridge.sock`.
    public static var standardSocket: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Paper Plane/bridge.sock")
    }

    public let socket: URL
    private let listener: NWListener
    private static let log = Logger(subsystem: "dev.paperplane.app", category: "bridge")

    private init(socket: URL, listener: NWListener) {
        self.socket = socket
        self.listener = listener
    }

    /// Listens at `socket`, replacing a socket file a crash left behind, and answers each request
    /// with `handler`. A connection that hasn't sent a whole request within `requestLimit` is
    /// closed.
    public static func start(at socket: URL, requestLimit: Duration = .seconds(10),
                             handler: @escaping @Sendable (PlayRequest) async -> PlayReply) async throws -> BridgeServer {
        guard socket.path.utf8.count < 104 else { throw Failure.pathTooLong }
        let folder = socket.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        unlink(socket.path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socket.path)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.cannotListen(String(describing: error))
        }
        let queue = DispatchQueue(label: "dev.paperplane.bridge")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task { await serve(connection, requestLimit: requestLimit, handler: handler) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let result: Result<Void, any Error>? = switch state {
                case .ready: .success(())
                case .failed(let error): .failure(Failure.cannotListen(String(describing: error)))
                case .cancelled: .failure(Failure.cannotListen("cancelled"))
                default: nil
                }
                let first = resumed.withLock { (done: inout Bool) -> Bool in
                    defer { done = true }
                    return !done
                }
                guard let result, first else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        // The socket is created with the umask's mode; only this user may write to it.
        chmod(socket.path, 0o600)
        return BridgeServer(socket: socket, listener: listener)
    }

    /// Stops listening and removes the socket, so the helper knows the app isn't there.
    public func stop() {
        listener.cancel()
        unlink(socket.path)
    }

    private static func serve(_ connection: NWConnection, requestLimit: Duration,
                              handler: @Sendable (PlayRequest) async -> PlayReply) async {
        let reply: PlayReply
        do {
            let message = try await receiveRequest(on: connection, within: requestLimit)
            reply = await handler(try PlayRequest.decode(message))
        } catch let invalid as PlayRequest.Invalid {
            log.error("Refused a request: \(invalid.reason, privacy: .public)")
            reply = .failed("Paper Plane can't play this (\(invalid.reason)).")
        } catch NativeMessaging.Error.tooLarge {
            log.error("Refused a request: too large")
            reply = .failed("Paper Plane can't play this (request too large).")
        } catch {
            // Closed or silent: nobody to answer.
            connection.cancel()
            return
        }
        connection.send(content: NativeMessaging.frame(reply.encoded()), contentContext: .finalMessage,
                        isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct Silent: Error {}

    /// Reads until one whole frame has arrived. Gives up, closing the connection, after `limit`.
    private static func receiveRequest(on connection: NWConnection, within limit: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    if let message = try NativeMessaging.take(from: &buffer) {
                        return message
                    }
                    buffer += try await receive(on: connection)
                }
            }
            group.addTask {
                try await Task.sleep(for: limit)
                connection.cancel() // ends the pending receive
                throw Silent()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// The next bytes, or an error once the connection has closed.
    private static func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? Silent())
                }
            }
        }
    }
}
