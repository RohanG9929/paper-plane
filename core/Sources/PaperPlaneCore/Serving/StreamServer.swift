import Foundation
import Network
import os

/// Serves one session folder over HTTP, so the TV can fetch the stream itself
/// (docs/sony-test-results.md, row 0). Each server listens on a random port and a random
/// 128-bit token path: `http://<host>:<port>/<token>/master.m3u8`.
public final class StreamServer: Sendable {
    /// `http://<host>:<port>/<token>/`
    public let baseURL: URL
    private let listener: NWListener

    private init(baseURL: URL, listener: NWListener) {
        self.baseURL = baseURL
        self.listener = listener
    }

    /// Starts serving `folder` on `host`, an IPv4 address: the Mac's LAN address
    /// (`LANAddress.current()`) for the TV, or `127.0.0.1` in tests.
    public static func start(serving folder: URL, on host: String) async throws -> StreamServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        let listener = try NWListener(using: parameters)
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let responder = FileResponder(folder: folder, token: token)
        let queue = DispatchQueue(label: "dev.paperplane.stream-server")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            receiveHead(on: connection, responder: responder, buffer: Data())
        }

        // .waiting means the address isn't available (say, the Mac's IP just changed): it throws.
        try await listener.startAndWaitUntilReady(queue: queue)
        guard let port = listener.port else {
            listener.cancel()
            throw NWError.posix(.EADDRNOTAVAIL)
        }
        return StreamServer(baseURL: URL(string: "http://\(host):\(port.rawValue)/\(token)/")!, listener: listener)
    }

    public func url(for file: String) -> URL {
        baseURL.appendingPathComponent(file)
    }

    /// Stops accepting connections. Requests already being answered finish.
    public func stop() {
        listener.cancel()
    }

    /// Reads up to the end of the request headers (at most 16 KB), answers, and closes.
    private static func receiveHead(on connection: NWConnection, responder: FileResponder, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let response = responder.response(to: head)
                connection.send(content: response.head, contentContext: .finalMessage, isComplete: false,
                                completion: .idempotent)
                connection.send(content: response.body, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            } else if error != nil || isComplete || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                receiveHead(on: connection, responder: responder, buffer: buffer)
            }
        }
    }
}
