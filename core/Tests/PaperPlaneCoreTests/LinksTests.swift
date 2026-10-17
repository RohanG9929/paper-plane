import Foundation
import Testing
@testable import PaperPlaneCore

struct LinksTests {
    @Test func aCopiedLinkIsTrimmed() {
        #expect(Links.webLink(in: "  https://youtu.be/aqz-KE-bpKQ \n") == URL(string: "https://youtu.be/aqz-KE-bpKQ"))
        #expect(Links.webLink(in: "HTTP://Example.com/v") == URL(string: "HTTP://Example.com/v"))
    }

    @Test(arguments: [nil, "", " ", "hello", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/v.mp4",
                      "https://", "https:///path", "www.youtube.com/watch?v=1", "https://exa mple.com/v",
                      "https://example.com/a\nhttps://example.com/b", "data:text/html,hi"])
    func onlyAWebLinkIsTaken(_ text: String?) {
        #expect(Links.webLink(in: text) == nil)
    }

    @Test func aLinkToAPlaylistOrAFileIsPlayedAsItIs() throws {
        let hls = try #require(Links.direct(URL(string: "https://cdn.example.com/live/index.M3U8?token=1")!))
        #expect(hls.inputs.map(\.manifest) == [.hls])
        #expect(hls.title == "index")
        for name in ["film.mp4", "film.m4v", "film.mov", "film.webm", "film.mkv"] {
            let file = try #require(Links.direct(URL(string: "https://cdn.example.com/\(name)")!))
            #expect(file.inputs.map(\.manifest) == [.none])
            #expect(file.title == "film")
        }
        #expect(Links.direct(URL(string: "https://cdn.example.com/films/A%20film.mp4")!)?.title == "A film")
        #expect(Links.direct(URL(string: "https://www.youtube.com/watch?v=1")!) == nil)
        #expect(Links.direct(URL(string: "https://vimeo.com/76979871")!) == nil)
    }

    /// A link straight to a DASH manifest plays as it is, read by ffmpeg like an HLS playlist.
    @Test func aDotMpdLinkPlaysAsDash() throws {
        let dash = try #require(Links.direct(URL(string: "https://cdn.example.com/video/x.mpd?token=1")!))
        #expect(dash.inputs.map(\.manifest) == [.dash])
        #expect(dash.inputs.map(\.url.absoluteString) == ["https://cdn.example.com/video/x.mpd?token=1"])
        #expect(dash.title == "x")
        #expect(try #require(Links.direct(URL(string: "https://cdn.example.com/video/X.MPD")!)).inputs.map(\.manifest) == [.dash])
    }

    /// Milestone 4, decision 10: what the browser may send as a page.
    @Test func youTubePagesOnly() {
        for page in ["https://www.youtube.com/watch?v=1", "https://youtube.com/shorts/1", "https://m.youtube.com/watch?v=1",
                     "https://music.youtube.com/watch?v=1", "https://youtu.be/1", "https://WWW.YouTube.com/watch?v=1"] {
            #expect(Links.isYouTubePage(URL(string: page)!), "\(page)")
        }
        for page in ["http://www.youtube.com/watch?v=1", "https://youtube.com.example.net/watch", "https://notyoutube.com/",
                     "https://example.com/youtube.com", "https://youtu.be.example.com/1", "https://www.youtube.com:8443/watch?v=1"] {
            #expect(!Links.isYouTubePage(URL(string: page)!), "\(page)")
        }
    }

    /// yt-dlp keeps a cookie to the exact host of the page it's given, and asks www.youtube.com
    /// for the video: every YouTube page goes to it as www.youtube.com, so the browser's
    /// sign-in reaches the requests that need it.
    @Test func youTubePagesGoToYtDlpAsWwwYouTube() {
        let cases = [
            ("https://www.youtube.com/watch?v=abc&t=90", "https://www.youtube.com/watch?v=abc&t=90"),
            ("https://youtube.com/watch?v=abc", "https://www.youtube.com/watch?v=abc"),
            ("https://m.youtube.com/watch?v=abc&t=5s", "https://www.youtube.com/watch?v=abc&t=5s"),
            ("https://music.youtube.com/watch?v=abc&list=RDx", "https://www.youtube.com/watch?v=abc&list=RDx"),
            ("https://youtube.com/shorts/abc", "https://www.youtube.com/shorts/abc"),
            ("https://youtu.be/abc?t=90", "https://www.youtube.com/watch?v=abc&t=90"),
            ("https://youtu.be/abc", "https://www.youtube.com/watch?v=abc"),
            ("https://vimeo.com/76979871", "https://vimeo.com/76979871"),
            ("https://youtu.be/", "https://youtu.be/"),
        ]
        for (page, expected) in cases {
            #expect(Links.forYtDlp(URL(string: page)!).absoluteString == expected, "\(page)")
        }
    }

    /// A title until yt-dlp gives one.
    @Test func aPagesTitleIsItsSiteUntilItsKnown() {
        #expect(Links.placeholderTitle(for: URL(string: "https://www.vimeo.com/76979871")!) == "vimeo.com")
        #expect(Links.placeholderTitle(for: URL(string: "https://youtu.be/1")!) == "youtu.be")
    }
}
