import Foundation
import os
import Testing
@testable import PaperPlaneCore

/// Requests and sockets the bridge tests share.
enum BridgeFixtures {
    /// A socket in a folder of its own under the temporary folder (short enough for sun_path).
    static func socket() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("bridge.sock")
    }

    static let play = Data(#"""
        {"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.m3u8","format":"hls"},"title":"Film"}
        """#.utf8)

    /// Relays `request` from a background thread, as the helper does, so a blocking socket never
    /// holds up a Swift concurrency thread the server needs.
    static func relay(_ request: Data, socket: URL, startApp: @escaping @Sendable () -> Void = {},
                      startLimit: Double = 0.3, replyLimit: Double = 10) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: HostRelay.relay(request, socket: socket, startApp: startApp,
                                                               startLimit: startLimit, replyLimit: replyLimit))
            }
        }
    }
}

struct BridgeServerTests {
    @Test func answersAPlayRequest() async throws {
        let socket = BridgeFixtures.socket()
        let received = OSAllocatedUnfairLock<PlayRequest?>(initialState: nil)
        let server = try await BridgeServer.start(at: socket) { request in
            received.withLock { $0 = request }
            return .ok
        }
        defer { server.stop() }
        #expect(await BridgeFixtures.relay(BridgeFixtures.play, socket: socket) == PlayReply.ok.encoded())
        #expect(received.withLock { $0 }?.title == "Film")
    }

    /// Spec §5.2: only this user may connect.
    @Test func onlyThisUserCanConnect() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket) { _ in .ok }
        defer { server.stop() }
        let file = try FileManager.default.attributesOfItem(atPath: socket.path)
        let folder = try FileManager.default.attributesOfItem(atPath: socket.deletingLastPathComponent().path)
        #expect(file[.posixPermissions] as? Int == 0o600)
        #expect(folder[.posixPermissions] as? Int == 0o700)
    }

    /// A crash leaves the socket file behind; the next launch must still listen.
    @Test func replacesALeftoverSocket() async throws {
        let socket = BridgeFixtures.socket()
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: socket)
        let server = try await BridgeServer.start(at: socket) { _ in .ok }
        defer { server.stop() }
        #expect(await BridgeFixtures.relay(BridgeFixtures.play, socket: socket) == PlayReply.ok.encoded())
        // A folder that was already there is closed to others too.
        let folder = try FileManager.default.attributesOfItem(atPath: socket.deletingLastPathComponent().path)
        #expect(folder[.posixPermissions] as? Int == 0o700)
    }

    /// A second copy of the app (a development build beside the installed one) leaves a running
    /// app's socket alone instead of taking it over.
    @Test func leavesALiveSocketAlone() async throws {
        let socket = BridgeFixtures.socket()
        let first = try await BridgeServer.start(at: socket) { _ in .ok }
        defer { first.stop() }
        await #expect(throws: BridgeServer.Failure.alreadyListening) {
            try await BridgeServer.start(at: socket) { _ in .failed("the second") }
        }
        #expect(await BridgeFixtures.relay(BridgeFixtures.play, socket: socket) == PlayReply.ok.encoded())
    }

    @Test func refusesWhatItCantReadWithoutAskingThePlayer() async throws {
        let socket = BridgeFixtures.socket()
        let asked = OSAllocatedUnfairLock(initialState: false)
        let server = try await BridgeServer.start(at: socket) { _ in
            asked.withLock { $0 = true }
            return .ok
        }
        defer { server.stop() }
        let reply = await BridgeFixtures.relay(Data(#"{"type":"play","v":1,"source":{"kind":"stream","url":"file:///etc/passwd","format":"hls"}}"#.utf8),
                                               socket: socket)
        #expect(PlayReply.decode(reply) == .failed("Paper Plane can't play this (not a web address)."))
        #expect(!asked.withLock { $0 })
    }

    /// A length over the limit is refused before anything that size is read.
    @Test func refusesOversizedRequests() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket) { _ in .ok }
        defer { server.stop() }
        let reply = try await Self.exchangeRaw(Data([0, 0, 0x20, 0]), socket: socket) // 2 MB
        #expect(PlayReply.decode(reply) == .failed("Paper Plane can't play this (request too large)."))
    }

    /// Something that connects and says nothing is let go, and the next request still works.
    @Test func dropsASilentConnection() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket, requestLimit: .milliseconds(200)) { _ in .ok }
        defer { server.stop() }
        let clock = ContinuousClock()
        let started = clock.now
        let reply = try await Self.exchangeRaw(Data(), socket: socket)
        #expect(reply.isEmpty) // closed without an answer…
        #expect(clock.now - started < .seconds(2)) // …as soon as the limit passed
        #expect(await BridgeFixtures.relay(BridgeFixtures.play, socket: socket) == PlayReply.ok.encoded())
    }

    /// One slow request (a site that takes a while to probe) doesn't hold up the next.
    @Test func answersRequestsAtTheSameTime() async throws {
        let socket = BridgeFixtures.socket()
        let secondAnswered = OSAllocatedUnfairLock(initialState: false)
        let server = try await BridgeServer.start(at: socket) { request in
            if request.title == "First" {
                for _ in 0..<100 where !secondAnswered.withLock({ $0 }) {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return secondAnswered.withLock { $0 } ? .ok : .failed("waited in line")
            }
            return .ok
        }
        defer { server.stop() }
        let first = Data(String(decoding: BridgeFixtures.play, as: UTF8.self).replacingOccurrences(of: "Film", with: "First").utf8)
        async let firstReply = BridgeFixtures.relay(first, socket: socket)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await BridgeFixtures.relay(BridgeFixtures.play, socket: socket) == PlayReply.ok.encoded())
        secondAnswered.withLock { $0 = true }
        #expect(await firstReply == PlayReply.ok.encoded())
    }

    @Test func stoppingRemovesTheSocket() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket) { _ in .ok }
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        let reply = await BridgeFixtures.relay(BridgeFixtures.play, socket: socket, startLimit: 0.2)
        #expect(PlayReply.decode(reply) == .failed("Couldn't start Paper Plane."))
    }

    /// sun_path holds 104 bytes; a longer path would be cut short silently.
    @Test func refusesAPathTooLongForASocket() async {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 100) + "/bridge.sock")
        await #expect(throws: BridgeServer.Failure.pathTooLong) {
            try await BridgeServer.start(at: long) { _ in .ok }
        }
    }

    /// Sends raw bytes and reads whatever comes back until the server closes.
    static func exchangeRaw(_ bytes: Data, socket: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let descriptor = try HostRelay.connect(to: socket)
                    defer { close(descriptor) }
                    try HostRelay.write(bytes, to: descriptor)
                    if let message = try? HostRelay.readFrame(from: descriptor, limit: 5) {
                        continuation.resume(returning: message)
                    } else {
                        continuation.resume(returning: Data())
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct HostRelayTests {
    /// Spec §5.2: with nothing listening, the helper starts the app and waits for its socket.
    @Test func startsTheAppWhenNothingListens() async throws {
        let socket = BridgeFixtures.socket()
        let starts = OSAllocatedUnfairLock(initialState: 0)
        let server = OSAllocatedUnfairLock<BridgeServer?>(initialState: nil)
        let reply = await BridgeFixtures.relay(BridgeFixtures.play, socket: socket, startApp: {
            starts.withLock { $0 += 1 }
            Task { // the app takes a moment to launch
                try? await Task.sleep(for: .milliseconds(300))
                let started = try? await BridgeServer.start(at: socket) { _ in .ok }
                server.withLock { $0 = started }
            }
        }, startLimit: 5)
        defer { server.withLock { $0?.stop() } }
        #expect(reply == PlayReply.ok.encoded())
        #expect(starts.withLock { $0 } == 1)
    }

    @Test func givesUpWhenTheAppDoesntStart() async {
        let clock = ContinuousClock()
        let started = clock.now
        let reply = await BridgeFixtures.relay(BridgeFixtures.play, socket: BridgeFixtures.socket(), startLimit: 0.5)
        #expect(PlayReply.decode(reply) == .failed("Couldn't start Paper Plane."))
        #expect(clock.now - started < .seconds(3))
    }

    @Test func givesUpWhenTheAppDoesntAnswer() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket) { _ in
            try? await Task.sleep(for: .seconds(10))
            return .ok
        }
        defer { server.stop() }
        let reply = await BridgeFixtures.relay(BridgeFixtures.play, socket: socket, replyLimit: 0.3)
        #expect(PlayReply.decode(reply) == .failed("Paper Plane didn't answer."))
    }

    @Test func readsOneFramedMessage() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(NativeMessaging.frame(BridgeFixtures.play))
        try pipe.fileHandleForWriting.close()
        #expect(HostRelay.readRequest(from: pipe.fileHandleForReading) == BridgeFixtures.play)
    }

    /// Cut short, or 2 MB announced and sent (from a file: a pipe would hold up the writer).
    @Test(arguments: [Data([5, 0, 0, 0]) + Data("ab".utf8), Data([0, 0, 0x20, 0]) + Data(count: 0x20_0000), Data([1])])
    func refusesTruncatedOrOversizedInput(_ bytes: Data) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pp-request-\(UUID())")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(HostRelay.readRequest(from: try FileHandle(forReadingFrom: file)) == nil)
    }

    @Test func findsTheAppItLivesIn() {
        let helper = URL(fileURLWithPath: "/Applications/Paper Plane.app/Contents/Helpers/paperplane-host")
        #expect(HostRelay.app(containing: helper)?.path == "/Applications/Paper Plane.app")
        #expect(HostRelay.app(containing: URL(fileURLWithPath: "/usr/local/bin/paperplane-host")) == nil)
    }
}
