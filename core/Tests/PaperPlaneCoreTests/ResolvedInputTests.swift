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
        #expect(input.ffmpegOptions == ResolvedInput.Input.webOnly + [
            "-user_agent", "Chrome/140",
            "-headers", "Cookie: a=1; b=2\r\nReferer: https://example.com/watch\r\n",
        ])
    }

    /// A site's playlist can name any URL; ffmpeg may follow only web ones, never file:, udp: or
    /// rtp: (security review, Plan 4).
    @Test func webInputsReachOnlyTheWebAndGiveUpOnAStalledSite() {
        let input = ResolvedInput.Input(url: URL(string: "https://example.com/v.mp4")!)
        #expect(input.ffmpegOptions == ["-protocol_whitelist", "https,http,tls,tcp,crypto,data", "-rw_timeout", "30000000"])
        #expect(ResolvedInput(inputs: [input], title: "").isWeb)
        #expect(!ResolvedInput.file(URL(fileURLWithPath: "/Movies/a.mkv")).isWeb)
    }

    /// Many sites name segments without a media extension, which ffmpeg 9 refuses by default;
    /// only an HLS input may take the option (ffmpeg rejects it for others).
    @Test func hlsSegmentsMayHaveAnyName() {
        var input = ResolvedInput.Input(url: URL(string: "https://example.com/master.m3u8")!)
        input.isHLS = true
        #expect(input.ffmpegOptions.suffix(2) == ["-extension_picky", "0"])
    }

    @Test func headerLineBreaksAreStripped() {
        let input = ResolvedInput.Input(
            url: URL(string: "https://example.com/v.mp4")!,
            headers: ["Cookie": "a=1\r\nX-Injected: yes"])
        #expect(input.ffmpegOptions == ResolvedInput.Input.webOnly + ["-headers", "Cookie: a=1X-Injected: yes\r\n"])
    }
}
