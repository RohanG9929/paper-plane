import Foundation
import Testing
@testable import PaperPlaneCore

/// yt-dlp's `-J` answers, written by hand from its documented fields (decision 1): the real
/// program is never run by the tests.
enum YtDlpFixtures {
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// A YouTube video: 1080p H.264 and AAC, separate.
    static let youtube = """
    {"id": "aqz-KE-bpKQ", "_type": "video", "title": "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film",
     "duration": 635, "is_live": false, "webpage_url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ", "format_id": "137+140",
     "requested_formats": [
      {"format_id": "137", "url": "https://rr3---sn-q4fl6nds.googlevideo.com/videoplayback?expire=1760000000&itag=137&sig=AAA",
       "protocol": "https", "vcodec": "avc1.640028", "acodec": "none", "height": 1080, "ext": "mp4",
       "http_headers": {"User-Agent": "\(agent)", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                        "Accept-Language": "en-us,en;q=0.5", "Sec-Fetch-Mode": "navigate"}},
      {"format_id": "140", "url": "https://rr3---sn-q4fl6nds.googlevideo.com/videoplayback?expire=1760000000&itag=140&sig=BBB",
       "protocol": "https", "vcodec": "none", "acodec": "mp4a.40.2", "ext": "m4a",
       "http_headers": {"User-Agent": "\(agent)", "Accept-Language": "en-us,en;q=0.5"}}
     ]}
    """

    /// A YouTube live stream: one HLS format with both.
    static let live = """
    {"id": "jfKfPfyJRdk", "_type": "video", "title": "lofi hip hop radio 📚 beats to relax/study to", "is_live": true,
     "format_id": "96", "url": "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/1760000000/itag/96/index.m3u8",
     "protocol": "m3u8_native", "vcodec": "avc1.640028", "acodec": "mp4a.40.2", "ext": "mp4",
     "http_headers": {"User-Agent": "\(agent)"}}
    """

    /// Another site: one progressive file with both, and a start time from the link's t=.
    static let single = """
    {"id": "clip", "_type": "video", "title": "  A   clip\\nwith spaces ", "start_time": 90, "duration": 300,
     "url": "https://media.example.com/videos/clip.mp4", "protocol": "https", "ext": "mp4",
     "http_headers": {"User-Agent": "\(agent)", "Referer": "https://example.com/watch/clip"}}
    """

    static let playlist = """
    {"_type": "playlist", "id": "PL1", "title": "A playlist",
     "entries": [null, \(single)]}
    """

    static let emptyPlaylist = """
    {"_type": "playlist", "id": "PL2", "title": "Nothing here", "entries": []}
    """

    static func with(protocol: String, url: String = "https://media.example.com/v.mpd") -> String {
        """
        {"id": "x", "_type": "video", "title": "x", "url": "\(url)", "protocol": "\(`protocol`)"}
        """
    }
}

struct YtDlpOutputTests {
    let page = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!

    func resolve(_ json: String, title: String = "From the tab") throws -> ResolvedPage {
        try YtDlpOutput.page(from: Data(json.utf8), page: page, fallbackTitle: title)
    }

    /// Spec §5.3: video and audio arrive as two inputs and are mapped together, video first.
    @Test func twoFormatsBecomeTwoInputs() throws {
        let resolved = try resolve(YtDlpFixtures.youtube)
        #expect(resolved.input.inputs.map(\.url.absoluteString) == [
            "https://rr3---sn-q4fl6nds.googlevideo.com/videoplayback?expire=1760000000&itag=137&sig=AAA",
            "https://rr3---sn-q4fl6nds.googlevideo.com/videoplayback?expire=1760000000&itag=140&sig=BBB",
        ])
        #expect(resolved.input.inputs.allSatisfy { !$0.isHLS })
        #expect(resolved.input.page == page)
        #expect(resolved.startTime == nil)
    }

    @Test func oneFormatBecomesOneInput() throws {
        let resolved = try resolve(YtDlpFixtures.single)
        #expect(resolved.input.inputs.map(\.url.absoluteString) == ["https://media.example.com/videos/clip.mp4"])
    }

    @Test func liveStreamIsHLS() throws {
        let resolved = try resolve(YtDlpFixtures.live)
        #expect(resolved.input.inputs.count == 1)
        #expect(resolved.input.inputs[0].isHLS)
        #expect(try resolve(YtDlpFixtures.with(protocol: "m3u8", url: "https://example.com/a.m3u8")).input.inputs[0].isHLS)
    }

    /// Playlists aren't played (spec non-goals); a link to one plays its first video.
    @Test func aPlaylistGivesItsFirstEntry() throws {
        let resolved = try resolve(YtDlpFixtures.playlist)
        #expect(resolved.input.inputs.map(\.url.absoluteString) == ["https://media.example.com/videos/clip.mp4"])
        #expect(resolved.input.title == "A clip with spaces")
    }

    @Test func anEmptyPlaylistIsUnsupported() {
        #expect(throws: YtDlpFailure.unsupported) { try resolve(YtDlpFixtures.emptyPlaylist) }
        #expect(throws: YtDlpFailure.unsupported) { try resolve(#"{"_type": "video", "title": "No formats"}"#) }
        #expect(throws: YtDlpFailure.unsupported) { try resolve("not json") }
    }

    /// ffmpeg can't read DASH (Milestone 3, decision 10), and nothing but HTTP(S) goes to ffmpeg.
    @Test(arguments: ["http_dash_segments", "dash", "f4m", "ism", "rtmp", "rtsp", "mms", "websocket_frag", "mhtml"])
    func dashAndOtherProtocolsAreRefused(_ name: String) {
        #expect(throws: YtDlpFailure.noPlayableFormat) { try resolve(YtDlpFixtures.with(protocol: name)) }
    }

    @Test(arguments: ["file:///etc/passwd", "ftp://example.com/v.mp4", "data:video/mp4;base64,AAAA", "https:///nohost", "not a url"])
    func onlyWebAddressesAreTaken(_ url: String) {
        #expect(throws: YtDlpFailure.noPlayableFormat) { try resolve(YtDlpFixtures.with(protocol: "https", url: url)) }
    }

    /// Each format's headers go with it to the proxy, which keeps them on the format's own site.
    /// Line breaks can't add headers, and what the proxy sets itself isn't overridden.
    @Test func formatHeadersTravelWithTheirInput() throws {
        let resolved = try resolve(YtDlpFixtures.youtube)
        #expect(resolved.input.inputs[0].headers == [
            "User-Agent": YtDlpFixtures.agent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-us,en;q=0.5", "Sec-Fetch-Mode": "navigate",
        ])
        #expect(resolved.input.inputs[1].headers == ["User-Agent": YtDlpFixtures.agent, "Accept-Language": "en-us,en;q=0.5"])
        let tricky = """
        {"_type": "video", "title": "x", "url": "https://example.com/v.mp4", "protocol": "https",
         "http_headers": {"X-A": "1\\r\\nCookie: stolen", "Range": "bytes=5-", "Accept-Encoding": "gzip", "Host": "other",
                          "Connection": "close", "Bad Name": "1", "": "2", "Referer": "https://example.com/"}}
        """
        #expect(try resolve(tricky).input.inputs[0].headers == ["X-A": "1Cookie: stolen", "Referer": "https://example.com/"])
    }

    /// yt-dlp's title is cleaner than the tab's (" - YouTube", notification counts); a link's own
    /// start (t=) is kept for when the browser gave none.
    @Test func titleAndStartTimeComeFromTheAnswer() throws {
        #expect(try resolve(YtDlpFixtures.youtube).input.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(try resolve(YtDlpFixtures.single).startTime == 90)
        let long = #"{"_type": "video", "title": "\#(String(repeating: "x", count: 500))", "url": "https://e.com/v.mp4", "protocol": "https", "start_time": -3}"#
        let resolved = try resolve(long)
        #expect(resolved.input.title.count == PlayRequest.maximumTitleLength)
        #expect(resolved.startTime == nil)
    }

    @Test func theTabsTitleIsKeptWhenTheAnswerHasNone() throws {
        let untitled = #"{"_type": "video", "title": "  ", "url": "https://e.com/v.mp4", "protocol": "https"}"#
        #expect(try resolve(untitled, title: "From the tab").input.title == "From the tab")
    }

    /// The remote shows yt-dlp's own words, cut to their first sentence: the rest is advice about
    /// yt-dlp's options, which mean nothing here.
    @Test func reasonIsTheFirstSentenceOfTheLastError() {
        let stderr = """
        WARNING: [youtube] Falling back to generic n function search
        ERROR: [youtube] abc: An earlier error.
        ERROR: [youtube] aqz-KE-bpKQ: Sign in to confirm you're not a bot. Use --cookies-from-browser or --cookies for the authentication. See  https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp  for how to manually pass cookies
        """
        #expect(YtDlpFailure.from(stderr: Data(stderr.utf8)) == .failed(reason: "Sign in to confirm you're not a bot."))
        #expect(YtDlpFailure.from(stderr: Data("ERROR: [youtube] x: Private video. Sign in if you've been granted access to this video".utf8))
            == .failed(reason: "Private video."))
        #expect(YtDlpFailure.from(stderr: Data("ERROR: [generic] Video unavailable at https://e.com/v?token=secret".utf8))
            == .failed(reason: "Video unavailable at https://e.com/v?…"))
        #expect(YtDlpFailure.from(stderr: Data("ERROR: \(String(repeating: "y", count: 400))".utf8))
            == .failed(reason: String(repeating: "y", count: 200) + "…"))
        #expect(YtDlpFailure.from(stderr: Data("Traceback (most recent call last):\n  boom".utf8)) == .failed(reason: nil))
        #expect(YtDlpFailure.from(stderr: Data()) == .failed(reason: nil))
    }

    @Test func unsupportedURLIsNamedAsSuch() {
        #expect(YtDlpFailure.from(stderr: Data("ERROR: Unsupported URL: https://example.com/".utf8)) == .unsupported)
        #expect(YtDlpFailure.from(stderr: Data("ERROR: [youtube] x: Requested format is not available. Use --list-formats for a list of available formats".utf8))
            == .noPlayableFormat)
    }
}
