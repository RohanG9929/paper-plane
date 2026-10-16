import Foundation
import Testing
@testable import PaperPlaneCore

struct FileResponderTests {
    static let token = "0123456789abcdef0123456789abcdef"

    private func respond(_ head: String, files: [String: String] = ["index.m3u8": "#EXTM3U\n"]) throws -> String {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        let data = FileResponder(folder: folder, token: Self.token).response(to: head)
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: [
        "GET /wrongtoken/index.m3u8 HTTP/1.1",
        "GET /index.m3u8 HTTP/1.1",
        "GET /\(token)/ HTTP/1.1",
        "GET /\(token)/../index.m3u8 HTTP/1.1",
        "GET /\(token)/sub/index.m3u8 HTTP/1.1",
        "GET /\(token)/%2e%2e%2fsecret HTTP/1.1",
        "GET /\(token)/.hidden HTTP/1.1",
        "GET /\(token)/missing.m4s HTTP/1.1",
    ])
    func refusesAnythingButAFileUnderTheToken(_ requestLine: String) throws {
        let response = try respond(requestLine + "\r\nHost: x", files: ["index.m3u8": "#EXTM3U\n", ".hidden": "x"])
        #expect(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    }

    @Test func servesAFileWithItsHLSContentType() throws {
        let response = try respond("GET /\(Self.token)/index.m3u8?t=1 HTTP/1.1\r\nHost: x")
        #expect(response == [
            "HTTP/1.1 200 OK", "Content-Type: application/vnd.apple.mpegurl", "Accept-Ranges: bytes",
            "Cache-Control: no-cache", "Content-Length: 8", "Connection: close", "", "#EXTM3U\n",
        ].joined(separator: "\r\n"))
    }

    @Test func headSendsHeadersOnly() throws {
        let response = try respond("HEAD /\(Self.token)/index.m3u8 HTTP/1.1")
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("Content-Length: 8\r\n"))
        #expect(response.hasSuffix("\r\n\r\n"))
    }

    @Test func servesOneByteRange() throws {
        let response = try respond("GET /\(Self.token)/seg_00000.m4s HTTP/1.1\r\nrange: bytes=2-5",
                                   files: ["seg_00000.m4s": "0123456789"])
        #expect(response.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(response.contains("Content-Type: video/iso.segment\r\n"))
        #expect(response.contains("Content-Range: bytes 2-5/10\r\n"))
        #expect(response.hasSuffix("\r\n\r\n2345"))
    }

    @Test func refusesOtherMethodsAndGarbage() throws {
        #expect(try respond("POST /\(Self.token)/index.m3u8 HTTP/1.1").hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
        #expect(try respond("hello").hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(try respond("").hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }

    @Test(arguments: [
        (nil, FileResponder.ByteRange.whole),
        ("bytes=0-99", .partial(0..<10)),
        ("bytes=3-", .partial(3..<10)),
        ("bytes=-4", .partial(6..<10)),
        ("bytes=-40", .partial(0..<10)),
        ("bytes=10-12", .unsatisfiable),
        ("bytes=-0", .unsatisfiable),
        ("bytes=5-2", .whole),
        ("bytes=0-1,4-5", .whole),
        ("items=0-1", .whole),
        ("bytes=x-y", .whole),
        ("bytes=0-9223372036854775807", .partial(0..<10)), // Int.max: must not overflow and crash
        ("bytes=-9223372036854775807", .partial(0..<10)),
    ] as [(String?, FileResponder.ByteRange)])
    func byteRanges(header: String?, expected: FileResponder.ByteRange) {
        #expect(FileResponder.byteRange(header, size: 10) == expected)
    }

    @Test func contentTypesForEveryHLSFile() {
        #expect(FileResponder.contentTypes == [
            "m3u8": "application/vnd.apple.mpegurl", "m4s": "video/iso.segment", "mp4": "video/mp4",
            "ts": "video/mp2t", "vtt": "text/vtt",
        ])
    }
}

/// The real server on the loopback address.
struct StreamServerTests {
    private func get(_ url: URL, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    @Test func servesTheFolderUnderARandomTokenOnly() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("#EXTM3U\n".utf8).write(to: folder.appendingPathComponent("master.m3u8"))
        let server = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        defer { server.stop() }

        #expect(server.baseURL.absoluteString.wholeMatch(of: /http:\/\/127\.0\.0\.1:\d+\/[0-9a-f]{32}\//) != nil)
        let (data, response) = try await get(server.url(for: "master.m3u8"))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(data == Data("#EXTM3U\n".utf8))

        let port = try #require(server.baseURL.port)
        let (_, noToken) = try await get(URL(string: "http://127.0.0.1:\(port)/master.m3u8")!)
        #expect(noToken.statusCode == 404)
        let (_, wrongToken) = try await get(URL(string: "http://127.0.0.1:\(port)/\(String(repeating: "0", count: 32))/master.m3u8")!)
        #expect(wrongToken.statusCode == 404)
    }

    @Test func everyServerHasItsOwnToken() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        let second = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        defer { first.stop(); second.stop() }
        #expect(first.baseURL.lastPathComponent != second.baseURL.lastPathComponent)
    }

    @Test func servesFilesThatAreStillGrowing() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let playlist = folder.appendingPathComponent("index.m3u8")
        try Data("#EXTM3U\n#EXTINF:6.0,\nseg_00000.m4s\n".utf8).write(to: playlist)
        let server = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        defer { server.stop() }

        let (before, _) = try await get(server.url(for: "index.m3u8"))
        let (_, missing) = try await get(server.url(for: "seg_00001.m4s"))
        #expect(missing.statusCode == 404)

        let handle = try FileHandle(forWritingTo: playlist)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("#EXTINF:6.0,\nseg_00001.m4s\n".utf8))
        try handle.close()
        try Data(repeating: 7, count: 3_000_000).write(to: folder.appendingPathComponent("seg_00001.m4s"))

        let (after, _) = try await get(server.url(for: "index.m3u8"))
        #expect(after.count > before.count)
        let (segment, response) = try await get(server.url(for: "seg_00001.m4s"))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "video/iso.segment")
        #expect(segment.count == 3_000_000)
    }

    @Test func handlesManyRequestsAtOnce() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 1, count: 500_000).write(to: folder.appendingPathComponent("seg_00000.m4s"))
        let server = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        defer { server.stop() }
        let sizes = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask { try await get(server.url(for: "seg_00000.m4s")).0.count }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(sizes == Array(repeating: 500_000, count: 20))
    }

    @Test func stopClosesThePort() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.m4s"))
        let server = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: URLError.self) {
            try await get(server.url(for: "a.m4s"))
        }
    }

    @Test func refusesAnAddressThisMacDoesNotHave() async throws {
        await #expect(throws: (any Error).self) {
            try await StreamServer.start(serving: URL(fileURLWithPath: "/tmp"), on: "203.0.113.7")
        }
    }
}

struct LANAddressTests {
    typealias Interface = LANAddress.Interface

    @Test func prefersEn0AndSkipsAddressesATVCannotReach() {
        let interfaces = [
            Interface(name: "lo0", address: "127.0.0.1", isUp: true, isLoopback: true),
            Interface(name: "utun3", address: "10.8.0.2", isUp: true, isLoopback: false),
            Interface(name: "bridge0", address: "192.168.2.1", isUp: true, isLoopback: false),
            Interface(name: "en5", address: "169.254.10.20", isUp: true, isLoopback: false),
            Interface(name: "en1", address: "192.168.0.21", isUp: true, isLoopback: false),
            Interface(name: "en0", address: "192.168.0.13", isUp: true, isLoopback: false),
        ]
        #expect(LANAddress.pick(from: interfaces) == "192.168.0.13")
    }

    @Test func fallsBackToTheNextEthernetOrWiFiInterface() {
        let interfaces = [
            Interface(name: "en0", address: "192.168.0.13", isUp: false, isLoopback: false),
            Interface(name: "en10", address: "10.0.0.9", isUp: true, isLoopback: false),
            Interface(name: "en7", address: "172.20.10.3", isUp: true, isLoopback: false),
        ]
        #expect(LANAddress.pick(from: interfaces) == "172.20.10.3")
    }

    @Test func offlineHasNoAddress() {
        #expect(LANAddress.pick(from: [Interface(name: "lo0", address: "127.0.0.1", isUp: true, isLoopback: true)]) == nil)
    }

    @Test func readsThisMacsInterfaces() {
        #expect(LANAddress.interfaces().contains { $0.name == "lo0" && $0.address == "127.0.0.1" && $0.isLoopback })
    }
}
