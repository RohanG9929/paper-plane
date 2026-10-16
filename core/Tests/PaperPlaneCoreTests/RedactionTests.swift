import Foundation
import Testing
@testable import PaperPlaneCore

struct RedactionTests {
    @Test func removesQueryStrings() {
        let text = "https://cdn.example.com/v/seg1.ts?token=SECRET&exp=99: Server returned 403 Forbidden"
        #expect(Redaction.redactQueries(text) == "https://cdn.example.com/v/seg1.ts?… Server returned 403 Forbidden")
    }

    @Test func summaryKeepsLastTwentyLinesRedacted() {
        let text = (1...30).map { "line \($0) https://x.test/a?k=\($0)" }.joined(separator: "\n")
        let summary = Redaction.summary(of: Data(text.utf8))
        let lines = summary.split(separator: "\n")
        #expect(lines.count == 20)
        #expect(lines.first == "line 11 https://x.test/a?…")
        #expect(!summary.contains("k="))
    }

    /// What ffmpeg prints at higher log levels for a web stream with `-headers`.
    static let webLog = """
        Reading option '-headers' ... matched as AVOption 'headers' with argument 'Cookie: sid=SECRET1; theme=dark
        Referer: https://example.com/watch
        '.
        [https @ 0x1] request: GET /v/master.m3u8 HTTP/1.1
        authorization: Bearer SECRET2
        Proxy-Authorization: Basic SECRET3
        [https @ 0x1] header: Set-Cookie: edge=SECRET4; Path=/; HttpOnly
        """

    @Test func removesCookieAndAuthorizationValues() {
        let redacted = Redaction.redact(Self.webLog)
        for secret in ["SECRET1", "SECRET2", "SECRET3", "SECRET4"] {
            #expect(!redacted.contains(secret), "\(secret) leaked")
        }
        #expect(redacted.contains("argument 'Cookie: …"))
        #expect(redacted.contains("authorization: …"))
        #expect(redacted.contains("Proxy-Authorization: …"))
        #expect(redacted.contains("header: Set-Cookie: …"))
        #expect(redacted.contains("Referer: https://example.com/watch"))
    }

    @Test func removesUserNamesAndPasswordsFromURLs() {
        #expect(Redaction.redact("Opening 'https://alice:hunter2@cdn.example.com/v.m3u8' for reading")
            == "Opening 'https://…@cdn.example.com/v.m3u8' for reading")
        #expect(Redaction.redact("rtmp://user@live.example.com/app") == "rtmp://…@live.example.com/app")
    }

    @Test func leavesOrdinaryTextAlone() {
        let text = "[h264 @ 0x2] Invalid NAL unit size (1234 > 567)\nError while decoding stream #0:0"
        #expect(Redaction.redact(text) == text)
    }

    @Test func summaryRedactsHeaders() {
        let summary = Redaction.summary(of: Data(Self.webLog.utf8))
        #expect(!summary.contains("SECRET"))
    }
}
