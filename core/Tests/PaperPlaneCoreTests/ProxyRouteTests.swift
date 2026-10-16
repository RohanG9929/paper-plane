import Foundation
import Testing
@testable import PaperPlaneCore

struct ProxyRouteTests {
    static let route = ProxyRoute(base: URL(string: "http://127.0.0.1:5000/t0k3n/")!)

    @Test func proxiesAndRecoversWebAddresses() throws {
        let upstream = URL(string: "https://cdn.example.com:8443/v/a%20b/master.m3u8?token=x&y=1")!
        let proxied = try #require(Self.route.proxied(upstream, input: 1))
        #expect(proxied.absoluteString == "http://127.0.0.1:5000/t0k3n/1/https/cdn.example.com:8443/v/a%20b/master.m3u8?token=x&y=1")
        let back = try #require(Self.route.upstream(for: "/t0k3n/1/https/cdn.example.com:8443/v/a%20b/master.m3u8?token=x&y=1"))
        #expect(back.url == upstream)
        #expect(back.input == 1)
    }

    @Test(arguments: ["/wrong/0/https/cdn.example.com/x", "/t0k3n/0/ftp/cdn.example.com/x", "/t0k3n/x/https/cdn.example.com/x",
                      "/t0k3n/0/https", "/t0k3n/0/https//x", "/"])
    func refusesWhatItDidntHandOut(_ target: String) {
        #expect(Self.route.upstream(for: target) == nil)
    }

    /// Relative URLs already resolve to the proxy; absolute, root-relative and protocol-relative
    /// ones are rewritten, so nothing in a playlist reaches ffmpeg as an address it would fetch
    /// directly.
    @Test func rewritesAnHLSPlaylist() {
        let playlist = """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k?id=1"
            #EXT-X-MAP:URI="/v/init.mp4"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",URI="//audio.example.com/en.m3u8"
            #EXTINF:6.0,
            seg-1.ts
            #EXTINF:6.0,
            /v/seg-2.ts
            #EXTINF:6.0,
            https://ads.example.net/ad.ts
            #EXTINF:6.0,
            //cdn2.example.com/seg-4.ts
            """
        let rewritten = ManifestRewriter.rewrite(playlist, kind: .hls, from: URL(string: "https://cdn.example.com/v/index.m3u8")!,
                                                 input: 0, route: Self.route)
        #expect(rewritten == """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:5000/t0k3n/0/https/keys.example.com/k?id=1"
            #EXT-X-MAP:URI="/t0k3n/0/https/cdn.example.com/v/init.mp4"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",URI="/t0k3n/0/https/audio.example.com/en.m3u8"
            #EXTINF:6.0,
            seg-1.ts
            #EXTINF:6.0,
            /t0k3n/0/https/cdn.example.com/v/seg-2.ts
            #EXTINF:6.0,
            http://127.0.0.1:5000/t0k3n/0/https/ads.example.net/ad.ts
            #EXTINF:6.0,
            /t0k3n/0/https/cdn2.example.com/seg-4.ts
            """)
    }

    @Test func rewritesADASHManifestButNotItsNamespaces() {
        let manifest = """
            <?xml version="1.0"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xlink="http://www.w3.org/1999/xlink">
              <BaseURL>https://media.example.com/v/</BaseURL>
              <Period><AdaptationSet><Representation id="1">
                <SegmentTemplate initialization="/v/init-$RepresentationID$.mp4" media="seg-$Number$.m4s"/>
                <BaseURL>//other.example.com/x/</BaseURL>
              </Representation></AdaptationSet></Period>
            </MPD>
            """
        let rewritten = ManifestRewriter.rewrite(manifest, kind: .dash, from: URL(string: "https://media.example.com/v/m.mpd")!,
                                                 input: 2, route: Self.route)
        #expect(rewritten.contains(#"xmlns:xlink="http://www.w3.org/1999/xlink""#))
        #expect(rewritten.contains("<BaseURL>http://127.0.0.1:5000/t0k3n/2/https/media.example.com/v/</BaseURL>"))
        #expect(rewritten.contains(#"initialization="/t0k3n/2/https/media.example.com/v/init-$RepresentationID$.mp4""#))
        #expect(rewritten.contains(#"media="seg-$Number$.m4s""#))
        #expect(rewritten.contains("<BaseURL>/t0k3n/2/https/other.example.com/x/</BaseURL>"))
    }

    @Test func recognisesManifestsByTypeNameOrContent() {
        let url = URL(string: "https://cdn.example.com/v/playlist")!
        #expect(ManifestRewriter.kind(contentType: "application/vnd.apple.mpegurl", url: url, start: Data()) == .hls)
        #expect(ManifestRewriter.kind(contentType: nil, url: URL(string: "https://x.example/a.mpd")!, start: Data()) == .dash)
        // Served as anything, under any name: still a playlist, and still rewritten.
        #expect(ManifestRewriter.kind(contentType: "application/octet-stream", url: url, start: Data("\u{FEFF}#EXTM3U\n".utf8)) == .hls)
        #expect(ManifestRewriter.kind(contentType: "text/xml", url: url, start: Data("<?xml version=\"1.0\"?>\n<MPD ".utf8)) == .dash)
        #expect(ManifestRewriter.kind(contentType: "video/mp2t", url: url, start: Data([0x47, 0x40])) == nil)
    }

    /// Cookies go where the browser would have sent them: the stream's own site.
    @Test func knowsWhichHostsShareASite() {
        #expect(Site.same("cdn.example.com", "video.example.com"))
        #expect(Site.same("example.com", "www.example.com"))
        #expect(!Site.same("cdn.example.com", "example.net"))
        #expect(!Site.same("victim.com", "evilvictim.com"))
        #expect(Site.same("a.bbc.co.uk", "b.bbc.co.uk"))
        #expect(!Site.same("bbc.co.uk", "evil.co.uk"))
        #expect(Site.same("127.0.0.1", "127.0.0.1"))
        #expect(!Site.same("10.0.0.1", "10.0.0.2"))
    }

    /// The Mac itself and the local network: off limits unless the stream lives there.
    @Test(arguments: [("127.0.0.1", true), ("10.1.2.3", true), ("172.16.0.1", true), ("172.32.0.1", false),
                      ("192.168.1.1", true), ("169.254.0.5", true), ("100.64.0.1", true), ("0.0.0.0", true),
                      ("224.0.0.1", true), ("8.8.8.8", false), ("::1", true), ("fe80::1", true), ("fd00::1", true),
                      ("::ffff:192.168.1.1", true), ("2001:4860:4860::8888", false), ("localhost", true)])
    func knowsLocalAddresses(_ host: String, _ local: Bool) {
        #expect(LocalAddresses.isLocal(host) == local)
    }
}
