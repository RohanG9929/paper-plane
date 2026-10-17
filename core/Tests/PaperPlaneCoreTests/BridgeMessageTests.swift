import Foundation
import Testing
@testable import PaperPlaneCore

struct NativeMessagingTests {
    @Test func framesWithALittleEndianLength() {
        #expect(NativeMessaging.frame(Data("{}".utf8)) == Data([2, 0, 0, 0]) + Data("{}".utf8))
    }

    @Test func takesWholeMessagesFromABuffer() throws {
        var buffer = NativeMessaging.frame(Data("one".utf8)) + NativeMessaging.frame(Data("two".utf8)).prefix(5)
        #expect(try NativeMessaging.take(from: &buffer) == Data("one".utf8))
        #expect(try NativeMessaging.take(from: &buffer) == nil) // the second isn't all here yet
        buffer += NativeMessaging.frame(Data("two".utf8)).dropFirst(5)
        #expect(try NativeMessaging.take(from: &buffer) == Data("two".utf8))
        #expect(buffer.isEmpty)
    }

    @Test func refusesOversizedMessages() {
        var buffer = Data([0, 0, 0x10, 0]) // 1 MB
        #expect(throws: NativeMessaging.Error.tooLarge) { try NativeMessaging.take(from: &buffer) }
    }
}

struct PlayRequestTests {
    static func json(_ text: String) -> Data { Data(text.utf8) }

    @Test func decodesAStreamRequest() throws {
        let request = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"stream","url":"https://cdn.example/v/master.m3u8?token=abc",
             "format":"hls","headers":{"Cookie":"session=1","Referer":"https://site.example/watch",
             "User-Agent":"Mozilla/5.0","Origin":"https://site.example","X-Other":"dropped"}},
             "pageUrl":"https://site.example/watch","title":"A film","startAt":12.5}
            """))
        #expect(request.title == "A film")
        #expect(request.startAt == 12.5)
        guard case .stream(let url, let format, let headers) = request.source else {
            Issue.record("not a stream")
            return
        }
        #expect(url.absoluteString == "https://cdn.example/v/master.m3u8?token=abc")
        #expect(format == .hls)
        #expect(headers == ["Cookie": "session=1", "Referer": "https://site.example/watch",
                            "User-Agent": "Mozilla/5.0", "Origin": "https://site.example"])
        #expect(request.input?.inputs.first?.headers.count == 4)
        #expect(request.input?.inputs.first?.manifest == .hls)
        #expect(request.input?.title == "A film")
    }

    /// YouTube (spec §5.1): the page, with the site's cookies for yt-dlp in a later version.
    @Test func decodesAPageRequest() throws {
        let request = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"page","url":"https://www.youtube.com/watch?v=x",
             "headers":{"Cookie":"SID=1","Authorization":"dropped"}},"title":"Clip"}
            """))
        #expect(request.source == .page(URL(string: "https://www.youtube.com/watch?v=x")!, headers: ["Cookie": "SID=1"]))
        #expect(request.startAt == 0)
        #expect(request.input == nil) // pages need yt-dlp
    }

    @Test(arguments: [
        #"{"type":"pause","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"progressive"}}"#,
        #"{"type":"play","v":2,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"progressive"}}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"file:///etc/passwd","format":"progressive"}}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"ftp://a.example/v.mp4","format":"progressive"}}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"rtmp"}}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"hls"},"startAt":-1}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"hls"},"startAt":1e400}"#,
        #"{"type":"play","v":1,"source":{"kind":"magic","url":"https://a.example/"}}"#,
        #"{"type":"play","v":1}"#,
        #"not json"#,
    ])
    func refusesWhatItCantSafelyPlay(_ text: String) {
        #expect(throws: PlayRequest.Invalid.self) { try PlayRequest.decode(Self.json(text)) }
    }

    @Test func titlesAreTidied() throws {
        let request = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"progressive"},
             "title":"  Line one\\nline two  "}
            """))
        #expect(request.title == "Line one line two")
        let untitled = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/videos/clip.mp4","format":"progressive"}}
            """))
        #expect(untitled.title == "clip")
        let percent = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v/100%25.mp4","format":"progressive"}}
            """))
        #expect(percent.title == "100%")
    }

    /// A page decides its own title; the remote, the menu and Control Center get a sensible length.
    @Test func longTitlesAreCut() throws {
        let long = String(repeating: "word ", count: 20_000)
        let request = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"page","url":"https://a.example/"},"title":"\(long)"}
            """))
        #expect(request.title.count == PlayRequest.maximumTitleLength)
    }

    @Test func repliesInTheSpecsShape() throws {
        #expect(String(decoding: PlayReply.ok.encoded(), as: UTF8.self) == #"{"ok":true}"#)
        #expect(String(decoding: PlayReply.failed("No TV").encoded(), as: UTF8.self) == #"{"error":"No TV","ok":false}"#)
    }
}
