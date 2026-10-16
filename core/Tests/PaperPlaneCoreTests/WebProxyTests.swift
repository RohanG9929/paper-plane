import Foundation
import Testing
@testable import PaperPlaneCore

/// ffmpeg reads web streams through the proxy (security review, Plan 4): the site's cookie goes
/// only to the site, and nothing reaches the Mac or the local network unless the stream lives
/// there. scripts/serve-hls.py plays the sites; it answers as 127.0.0.1 and as localhost, which
/// count as two hosts of two sites.
@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct WebProxyTests {
    /// A folder holding the test clip's MPEG-TS segments, and `playlist` naming them as `segment(i)`.
    static func site(playlist name: String = "index.m3u8", segment: (Int) -> String) async throws -> URL {
        let folder = try await WebInputTests.makeHLS(live: false)
        let count = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".ts") }.count
        let lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:3"]
            + (0..<count).flatMap { ["#EXTINF:2.0,", segment($0)] } + ["#EXT-X-ENDLIST"]
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return folder
    }

    static func requests(in log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    static func web(_ url: URL) -> ResolvedInput {
        ResolvedInput(inputs: [.init(url: url, headers: ["Cookie": "session=secret", "Referer": "https://site.example/"])],
                      title: "Web")
    }

    @Test func passesTheCookieOnlyToTheStreamsOwnSite() async throws {
        let tools = try #require(TestSupport.tools)
        let log = try TestSupport.makeTemporaryDirectory().appendingPathComponent("requests.log")
        // An "ad" on another host: localhost, where the playlist is on 127.0.0.1.
        let folder = try await Self.site { index in "http://localhost:\(Self.placeholderPort)/seg\(index).ts" }
        let server = try await HLSServer(directory: folder, log: log)
        defer { server.stop() }
        let port = server.port
        try Self.fillInPort(port, in: folder.appendingPathComponent("index.m3u8"))

        let proxy = try await WebProxy.start(serving: Self.web(server.url("index.m3u8")))
        defer { proxy.stop() }
        let info = try await MediaProbe(tools: tools).probe(proxy.input)
        #expect(info.video.count == 1)
        let requests = Self.requests(in: log)
        #expect(requests.contains { $0.hasPrefix("127.0.0.1:\(port) /index.m3u8 cookie=session=secret") })
        #expect(requests.contains { $0.hasPrefix("localhost:\(port) /seg0.ts cookie=None") })
        #expect(!requests.contains { $0.hasPrefix("localhost") && $0.contains("secret") })
        #expect(proxy.input.inputs[0].headers.isEmpty) // ffmpeg itself never sees the cookie
    }

    /// A page's playlist naming the router, or a service on the Mac, gets nowhere (SSRF).
    @Test func refusesLocalAddressesForAStreamThatIsNt() async throws {
        let tools = try #require(TestSupport.tools)
        let log = try TestSupport.makeTemporaryDirectory().appendingPathComponent("requests.log")
        let folder = try await Self.site { index in "http://127.0.0.1:\(Self.placeholderPort)/seg\(index).ts" }
        let server = try await HLSServer(directory: folder, log: log)
        defer { server.stop() }
        try Self.fillInPort(server.port, in: folder.appendingPathComponent("index.m3u8"))
        // The stream is on "localhost", taken here for a site on the internet; 127.0.0.1 is local.
        let proxy = try await WebProxy.start(serving: Self.web(URL(string: "http://localhost:\(server.port)/index.m3u8")!),
                                             isLocal: { $0 == "127.0.0.1" })
        defer { proxy.stop() }
        _ = try? await MediaProbe(tools: tools).probe(proxy.input)
        let requests = Self.requests(in: log)
        #expect(requests.contains { $0.hasPrefix("localhost:\(server.port) /index.m3u8") })
        #expect(!requests.contains { $0.hasPrefix("127.0.0.1") })
    }

    /// A redirect is a new request, and passes the same checks.
    @Test func checksWhereARedirectGoes() async throws {
        let tools = try #require(TestSupport.tools)
        let log = try TestSupport.makeTemporaryDirectory().appendingPathComponent("requests.log")
        let server = try await HLSServer(directory: TestSupport.mediaDirectory, log: log)
        defer { server.stop() }
        let toLocal = URL(string: "http://localhost:\(server.port)/redirect/127.0.0.1:\(server.port)/h264_aac.mp4")!
        let proxy = try await WebProxy.start(serving: Self.web(toLocal), isLocal: { $0 == "127.0.0.1" })
        defer { proxy.stop() }
        await #expect(throws: MediaProbeError.self) { try await MediaProbe(tools: tools).probe(proxy.input) }
        #expect(!Self.requests(in: log).contains { $0.hasPrefix("127.0.0.1") })

        // Redirects that stay allowed are followed, with the file fetched in ranges as ffmpeg asks.
        let allowed = try await WebProxy.start(serving: Self.web(server.url("redirect/localhost:\(server.port)/h264_aac.mp4")))
        defer { allowed.stop() }
        let info = try await MediaProbe(tools: tools).probe(allowed.input)
        #expect(info.duration.map { abs($0 - 10) < 0.5 } == true)
    }

    /// A playlist under another name, as some sites serve them, is rewritten all the same.
    @Test func rewritesAPlaylistWhateverItsName() async throws {
        let tools = try #require(TestSupport.tools)
        let log = try TestSupport.makeTemporaryDirectory().appendingPathComponent("requests.log")
        let folder = try await Self.site(playlist: "playlist") { index in "http://127.0.0.1:\(Self.placeholderPort)/seg\(index).ts" }
        let server = try await HLSServer(directory: folder, log: log)
        defer { server.stop() }
        try Self.fillInPort(server.port, in: folder.appendingPathComponent("playlist"))
        let proxy = try await WebProxy.start(serving: Self.web(server.url("playlist")))
        defer { proxy.stop() }
        let info = try await MediaProbe(tools: tools).probe(proxy.input)
        #expect(info.video.count == 1)
        // Every segment came through the proxy, with the cookie (same host).
        #expect(Self.requests(in: log).filter { $0.contains("/seg") }.allSatisfy { $0.contains("secret") })
    }

    @Test func passesOnASitesRefusal() async throws {
        let tools = try #require(TestSupport.tools)
        let server = try await HLSServer(directory: TestSupport.mediaDirectory)
        defer { server.stop() }
        let proxy = try await WebProxy.start(serving: Self.web(server.url("status/403/h264_aac.mp4")))
        defer { proxy.stop() }
        do {
            _ = try await MediaProbe(tools: tools).probe(proxy.input)
            Issue.record("probed a refused stream")
        } catch {
            #expect(SiteRefusal.isRefusal(error), "\(error)")
        }
    }

    /// Playlists are written before the server's port is known.
    static let placeholderPort = 1

    static func fillInPort(_ port: Int, in playlist: URL) throws {
        let text = try String(contentsOf: playlist, encoding: .utf8)
            .replacingOccurrences(of: ":\(placeholderPort)/", with: ":\(port)/")
        try text.write(to: playlist, atomically: true, encoding: .utf8)
    }
}
