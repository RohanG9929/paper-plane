import Foundation
import Testing
@testable import PaperPlaneCore

struct LocalAddressTests {
    /// A host is refused when any of its addresses is local, and lets local fetches through only
    /// when all of them are: a public name with an extra 127.0.0.1 record is neither trusted nor used.
    @Test func anyLocalAddressRefusesButAllAreNeededToAllow() {
        #expect(LocalAddresses.decide(["8.8.8.8", "127.0.0.1"], all: false))
        #expect(!LocalAddresses.decide(["8.8.8.8", "127.0.0.1"], all: true))
        #expect(LocalAddresses.decide(["192.168.1.2", "10.0.0.1"], all: true))
        #expect(!LocalAddresses.decide([], all: true))
        #expect(!LocalAddresses.decide([], all: false))
        #expect(LocalAddresses.isWhollyLocal("127.0.0.1"))
        #expect(!LocalAddresses.isWhollyLocal("8.8.8.8"))
    }
}

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
    @Test func rewritesAnHLSPlaylist() throws {
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
        let rewritten = try #require(ManifestRewriter.rewrite(playlist, kind: .hls,
                                                              from: URL(string: "https://cdn.example.com/v/index.m3u8")!,
                                                              input: 0, route: Self.route).text)
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

    @Test func rewritesADASHManifestButNotItsNamespaces() throws {
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
        let rewritten = try #require(ManifestRewriter.rewrite(manifest, kind: .dash,
                                                              from: URL(string: "https://media.example.com/v/m.mpd")!,
                                                              input: 2, route: Self.route).text)
        #expect(rewritten.contains(#"xmlns:xlink="http://www.w3.org/1999/xlink""#))
        #expect(rewritten.contains("<BaseURL>http://127.0.0.1:5000/t0k3n/2/https/media.example.com/v/</BaseURL>"))
        #expect(rewritten.contains(#"initialization="/t0k3n/2/https/media.example.com/v/init-$RepresentationID$.mp4""#))
        #expect(rewritten.contains(#"media="seg-$Number$.m4s""#))
        #expect(rewritten.contains("<BaseURL>/t0k3n/2/https/other.example.com/x/</BaseURL>"))
    }

    /// A DASH manifest can name any host: a BaseURL, a remote element's xlink:href, a new
    /// manifest's Location. Every such address reaches ffmpeg as the proxy's, so ffmpeg can't be
    /// steered to fetch an external host itself (the proxy applies its checks to what it relays).
    /// ffmpeg's DASH demuxer follows no xlink or Location at all; this holds either way, whatever
    /// form the address takes (absolute, `//host/x`, or `/x`).
    @Test func aDASHManifestCantSteerFFmpegToAnExternalHost() throws {
        let manifest = """
            <?xml version="1.0"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xlink="http://www.w3.org/1999/xlink">
              <Location>https://evil.example/new.mpd</Location>
              <BaseURL>https://evil.example/seg/</BaseURL>
              <Period xlink:href="https://evil.example/part.mpd" xlink:actuate="onLoad">
                <AdaptationSet><Representation id="1">
                  <BaseURL>//evil.example/rep/</BaseURL>
                  <SegmentList><SegmentURL media="https://evil.example/s1.m4s"/></SegmentList>
                </Representation></AdaptationSet>
              </Period>
              <Period xlink:href="//evil.example/part2.mpd" xlink:actuate="onRequest"/>
              <Period xlink:href="/evil/part3.mpd" xlink:actuate="onRequest"/>
            </MPD>
            """
        let rewritten = try #require(ManifestRewriter.rewrite(manifest, kind: .dash,
                                                              from: URL(string: "https://media.example.com/v/m.mpd")!,
                                                              input: 0, route: Self.route).text)
        let proxied = "http://127.0.0.1:5000/t0k3n/0/https/evil.example/"
        #expect(rewritten.contains("<Location>\(proxied)new.mpd</Location>"))
        #expect(rewritten.contains("<BaseURL>\(proxied)seg/</BaseURL>"))
        #expect(rewritten.contains(#"xlink:href="\#(proxied)part.mpd""#))
        #expect(rewritten.contains(#"media="\#(proxied)s1.m4s""#))
        #expect(rewritten.contains("<BaseURL>/t0k3n/0/https/evil.example/rep/</BaseURL>")) // on the proxy's own host
        // A remote element's `//host/x` and `/x` are the proxy's too: the latter on the manifest's own host.
        #expect(rewritten.contains(#"xlink:href="/t0k3n/0/https/evil.example/part2.mpd""#))
        #expect(rewritten.contains(#"xlink:href="/t0k3n/0/https/media.example.com/evil/part3.mpd""#))
        #expect(!rewritten.contains(#"href="//"#) && !rewritten.contains(#"href="/evil"#))
        // Nothing names the external host except by way of the proxy.
        let direct = rewritten.replacingOccurrences(of: "/t0k3n/0/https/evil.example/", with: "")
        #expect(!direct.contains("evil.example"))
        // The namespaces are declarations, not addresses to fetch.
        #expect(rewritten.contains(#"xmlns:xlink="http://www.w3.org/1999/xlink""#))
    }

    /// The segment-URL rewrite is quote-agnostic and tolerant of spaces around `=`: a hostile
    /// manifest can't slip a scheme-relative (`//host/x`) or root-relative (`/x`) address past it
    /// with single quotes or `media = "…"`. Left raw, ffmpeg's DASH demuxer would resolve such a
    /// value against the proxied base (`http://127.0.0.1:…`) and fetch the external host directly
    /// (http is whitelisted), bypassing the proxy's SSRF checks.
    @Test func aDASHManifestsSingleQuotedAndSpacedSegmentURLsStayOnTheProxy() throws {
        let manifest = """
            <?xml version="1.0"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xlink="http://www.w3.org/1999/xlink">
              <Period><AdaptationSet><Representation id="1"><SegmentList>
                <SegmentURL media='//evil.example/single.m4s'/>
                <SegmentURL media = "//evil.example/spaced.m4s"/>
                <SegmentURL media='/evil/relative.m4s' initialization = '//evil.example/init.m4s'/>
                <SegmentURL media="//evil.example/a'b.m4s"/>
                <SegmentURL media='//evil.example/a"b.m4s'/>
              </SegmentList></Representation></AdaptationSet></Period>
            </MPD>
            """
        let rewritten = try #require(ManifestRewriter.rewrite(manifest, kind: .dash,
                                                              from: URL(string: "https://media.example.com/v/m.mpd")!,
                                                              input: 0, route: Self.route).text)
        // A scheme-relative (`//host`) value becomes the proxy on the manifest's scheme, as a
        // host-relative path (it resolves to the proxy, not the external host).
        let proxied = "/t0k3n/0/https/evil.example/"
        #expect(rewritten.contains(#"media='\#(proxied)single.m4s'"#)) // single-quoted `//host`
        #expect(rewritten.contains(#"media = "\#(proxied)spaced.m4s""#)) // spaced `=`, double-quoted
        #expect(rewritten.contains(#"initialization = '\#(proxied)init.m4s'"#)) // spaced `=`, single-quoted
        // A value may legally hold the other quote: a double-quoted value with an apostrophe, and a
        // single-quoted value with a double quote, are both still rewritten (each excludes only its own).
        #expect(rewritten.contains(#"media="\#(proxied)a'b.m4s""#))
        #expect(rewritten.contains(#"media='\#(proxied)a"b.m4s'"#))
        // A single-quoted `/`-relative value maps to the proxy on the manifest's own host.
        #expect(rewritten.contains(#"media='/t0k3n/0/https/media.example.com/evil/relative.m4s'"#))
        // Nothing names the external host except by way of the proxy.
        let direct = rewritten.replacingOccurrences(of: "/t0k3n/0/https/evil.example/", with: "")
        #expect(!direct.contains("evil.example"))
        // The namespace is a declaration, not an address to fetch: left exactly as it was.
        #expect(rewritten.contains(#"xmlns:xlink="http://www.w3.org/1999/xlink""#))
    }

    /// Rewrites a DASH manifest from the usual stand-in origin, for the bypass tests below.
    static func dash(_ manifest: String) -> ManifestRewriter.Outcome {
        ManifestRewriter.rewrite(manifest, kind: .dash, from: URL(string: "https://media.example.com/v/m.mpd")!,
                                 input: 0, route: route)
    }

    /// The regex rewrites what it can see in the raw bytes; ffmpeg's DASH demuxer reads the manifest
    /// through an XML parser that first decodes character references. A hostile manifest hides a
    /// scheme-relative (`&#47;/host`) or absolute (`htt&#112;://host`) address behind them, so the
    /// regex leaves it alone but ffmpeg would fetch the external host directly. The manifest is
    /// refused rather than handed over — decimal and hex references alike, in any fetchable slot.
    @Test(arguments: [
        #"<SegmentURL media="&#47;/evil.example/x.m4s"/>"#,           // decimal `/` → `//evil…`
        #"<SegmentURL media="&#x2F;/evil.example/x.m4s"/>"#,          // hex `/`
        #"<SegmentURL media="&#x2f;&#x2f;evil.example/x.m4s"/>"#,     // both slashes encoded
        #"<SegmentURL media="htt&#112;://evil.example/x.m4s"/>"#,     // the scheme itself encoded
        #"<SegmentURL initialization="&#47;/evil.example/i.m4s"/>"#, // another fetchable attribute
        #"<SegmentTemplate media="&#x2f;/evil.example/$Number$.m4s"/>"#,
        #"<BaseURL>&#47;/evil.example/seg/</BaseURL>"#,               // in element text, not an attribute
        #"<Location>htt&#112;s://evil.example/new.mpd</Location>"#,
        #"<Period xlink:href="&#47;/evil.example/p.mpd"/>"#,          // and in a namespaced attribute
    ])
    func refusesAnEntityEncodedAddressThatWouldLeaveTheProxy(_ hostile: String) {
        let manifest = """
            <?xml version="1.0"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xlink="http://www.w3.org/1999/xlink">
              <Period><AdaptationSet><Representation id="1"><SegmentList>
                \(hostile)
              </SegmentList></Representation></AdaptationSet></Period>
            </MPD>
            """
        #expect(Self.dash(manifest) == .refused)
    }

    /// A CDATA section is text to the regex (it starts with `<`, not `/`) but decoded content to
    /// ffmpeg's parser. An external address wrapped in one slips past the rewrite, so a manifest
    /// carrying one that would leave the proxy is refused.
    @Test(arguments: [
        "<BaseURL><![CDATA[//evil.example/seg/]]></BaseURL>",
        "<Location><![CDATA[//evil.example/new.mpd]]></Location>",
        "<BaseURL><![CDATA[//]]>evil.example/seg/</BaseURL>", // the `//` split across CDATA and text
    ])
    func refusesACDATAWrappedAddressThatWouldLeaveTheProxy(_ hostile: String) {
        let manifest = """
            <?xml version="1.0"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xlink="http://www.w3.org/1999/xlink">
              <Period><AdaptationSet><Representation id="1">
                \(hostile)
              </Representation></AdaptationSet></Period>
            </MPD>
            """
        #expect(Self.dash(manifest) == .refused)
    }

    /// A BaseURL or Location holds only text in real DASH, but a hostile manifest can nest an empty
    /// element so the address sits in the text *after* it. ffmpeg reads the element's whole content
    /// (xmlNodeGetContent concatenates every descendant's text), so it would still see `//evil…`,
    /// while a linear scan that stops at the nested tag's end would miss it. Any element nested inside
    /// a BaseURL/Location is refused — real DASH never nests them.
    @Test(arguments: [
        "<BaseURL><BaseURL/>&#47;/evil.example/seg/</BaseURL>",       // address in the tail after a nested empty tag
        "<BaseURL><Location/><![CDATA[//evil.example/seg/]]></BaseURL>", // the tail in a CDATA section
        "<Location><Period/>&#47;/evil.example/new.mpd</Location>",   // same shape in a Location
        "<BaseURL><x/>media.example.com/seg/</BaseURL>",              // any child at all is refused, benign tail or not
    ])
    func refusesANestedElementInsideABaseURLOrLocation(_ hostile: String) {
        let manifest = """
            <?xml version="1.0"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xlink="http://www.w3.org/1999/xlink">
              <Period><AdaptationSet><Representation id="1">
                \(hostile)
              </Representation></AdaptationSet></Period>
            </MPD>
            """
        #expect(Self.dash(manifest) == .refused)
    }

    /// A DTD lets a manifest define its own entities, which parsers may expand differently or not at
    /// all — the kind of gap the rewriter can't reason about. Real DASH carries none, so any manifest
    /// that declares a DOCTYPE or an entity is refused outright, used in a URL or not.
    @Test func refusesAManifestThatCarriesItsOwnDTDOrEntities() {
        let withEntity = """
            <?xml version="1.0"?>
            <!DOCTYPE MPD [ <!ENTITY e "//evil.example/seg/"> ]>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
              <Period><AdaptationSet><Representation id="1">
                <BaseURL>&e;</BaseURL>
              </Representation></AdaptationSet></Period>
            </MPD>
            """
        #expect(Self.dash(withEntity) == .refused)
        // A DOCTYPE on its own — even without an address in sight — is still refused.
        let justDoctype = """
            <?xml version="1.0"?>
            <!DOCTYPE MPD>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><BaseURL>seg/</BaseURL></MPD>
            """
        #expect(Self.dash(justDoctype) == .refused)
    }

    /// Verification is fail-closed, not blanket: a benign entity (an escaped `&` in a query, say) in
    /// a value that still resolves to the proxy is left to play, not refused. The scheme-relative and
    /// spaced/single-quoted forms the regex already neutralises are rewritten, so they pass too.
    @Test func keepsManifestsWhoseDecodedAddressesStillReachOnlyTheProxy() throws {
        let manifest = """
            <?xml version="1.0"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xlink="http://www.w3.org/1999/xlink">
              <BaseURL>https://media.example.com/v/</BaseURL>
              <Period><AdaptationSet><Representation id="1"><SegmentList>
                <SegmentURL media="seg-1&#45;hi.m4s"/>
                <SegmentURL media="q.m4s?a=1&amp;b=2"/>
                <SegmentURL media='//media.example.com/spaced.m4s'/>
                <Initialization sourceURL="&#47;v/init.m4s"/>
              </SegmentList></Representation></AdaptationSet></Period>
            </MPD>
            """
        let rewritten = try #require(Self.dash(manifest).text)
        // The decoded relative/root-relative values all resolve to the proxy, so nothing is refused.
        #expect(rewritten.contains(#"media="seg-1&#45;hi.m4s""#))      // a hyphen entity, left as text
        #expect(rewritten.contains(#"media="q.m4s?a=1&amp;b=2""#))     // an escaped ampersand, untouched
        #expect(rewritten.contains("http://127.0.0.1:5000/t0k3n/0/https/media.example.com/v/"))
        // Nothing resolves off the proxy.
        let direct = rewritten.replacingOccurrences(of: "/t0k3n/0/https/media.example.com/", with: "")
        #expect(!direct.contains("media.example.com"))
    }

    /// A real manifest, as ffmpeg's own DASH muxer writes one: relative segment templates, a
    /// `SegmentTimeline`, an `xsi:schemaLocation` and a `schemeIdUri` that are identifiers rather
    /// than addresses to fetch. None of it leaves the proxy, so it plays — the verification is
    /// fail-closed, not a blanket refusal of every absolute URL (the schema and channel-config URIs
    /// are left for ffmpeg to resolve, and are never fetched).
    @Test func keepsARealFFmpegWrittenDASHManifest() throws {
        let manifest = """
            <?xml version="1.0" encoding="utf-8"?>
            <MPD xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                xmlns="urn:mpeg:dash:schema:mpd:2011"
                xmlns:xlink="http://www.w3.org/1999/xlink"
                xsi:schemaLocation="urn:mpeg:DASH:schema:MPD:2011 http://standards.iso.org/ittf/DASH-MPD.xsd"
                profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static" minBufferTime="PT4.0S">
              <Period id="0" start="PT0.0S">
                <AdaptationSet id="0" contentType="video" frameRate="30/1" maxWidth="1280" maxHeight="720">
                  <Representation id="0" mimeType="video/mp4" codecs="avc1.6e001f" bandwidth="135864" width="1280" height="720">
                    <SegmentTemplate timescale="16000" initialization="init-stream$RepresentationID$.m4s" media="chunk-stream$RepresentationID$-$Number%05d$.m4s" startNumber="1">
                      <SegmentTimeline><S t="0" d="32000" r="4"/></SegmentTimeline>
                    </SegmentTemplate>
                  </Representation>
                </AdaptationSet>
                <AdaptationSet id="1" contentType="audio">
                  <Representation id="2" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="128056" audioSamplingRate="48000">
                    <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>
                    <SegmentTemplate timescale="48000" initialization="init-stream$RepresentationID$.m4s" media="chunk-stream$RepresentationID$-$Number%05d$.m4s" startNumber="1">
                      <SegmentTimeline><S t="0" d="93184"/></SegmentTimeline>
                    </SegmentTemplate>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let rewritten = try #require(Self.dash(manifest).text) // not refused
        // The relative segment templates are left to resolve against the proxied manifest's URL.
        #expect(rewritten.contains(#"initialization="init-stream$RepresentationID$.m4s""#))
        #expect(rewritten.contains(#"media="chunk-stream$RepresentationID$-$Number%05d$.m4s""#))
        // The channel-config identifier is untouched; nothing points off the proxy.
        #expect(rewritten.contains(#"schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011""#))
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
