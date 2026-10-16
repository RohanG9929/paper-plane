import Foundation
import Testing
@testable import PaperPlaneCore

struct ResolvedInputTests {
    @Test func fileInputUsesPlainPathAndFileNameTitle() {
        let url = URL(fileURLWithPath: "/Movies/Movie: Part 1 (Director's Cut) é.mkv")
        let input = ResolvedInput.file(url)
        #expect(input.title == "Movie: Part 1 (Director's Cut) é")
        #expect(input.inputs.count == 1)
        #expect(input.inputs[0].ffmpegLocation == "/Movies/Movie: Part 1 (Director's Cut) é.mkv")
        #expect(input.inputs[0].ffmpegOptions == [])
    }

    @Test func webInputPassesUserAgentAndSortedHeaders() {
        let input = ResolvedInput.Input(
            url: URL(string: "https://cdn.example.com/v/master.m3u8?token=abc")!,
            headers: ["Referer": "https://example.com/watch", "Cookie": "a=1; b=2", "user-agent": "Chrome/140"])
        #expect(input.ffmpegLocation == "https://cdn.example.com/v/master.m3u8?token=abc")
        #expect(input.ffmpegOptions == [
            "-user_agent", "Chrome/140",
            "-headers", "Cookie: a=1; b=2\r\nReferer: https://example.com/watch\r\n",
        ])
    }

    @Test func webInputWithoutHeadersHasNoOptions() {
        let input = ResolvedInput.Input(url: URL(string: "https://example.com/v.mp4")!)
        #expect(input.ffmpegOptions == [])
    }

    @Test func headerLineBreaksAreStripped() {
        let input = ResolvedInput.Input(
            url: URL(string: "https://example.com/v.mp4")!,
            headers: ["Cookie": "a=1\r\nX-Injected: yes"])
        #expect(input.ffmpegOptions == ["-headers", "Cookie: a=1X-Injected: yes\r\n"])
    }
}
