import Foundation
import Testing
@testable import PaperPlaneCore

struct YtDlpCommandTests {
    let page = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!
    let cache = URL(fileURLWithPath: "/tmp/Paper Plane/yt-dlp")

    /// A page address can never be read as an option, whatever it starts with.
    @Test func argumentsEndWithThePageAfterADoubleDash() {
        let arguments = YtDlpCommand.arguments(page: page, cacheFolder: cache)
        #expect(Array(arguments.suffix(2)) == ["--", page.absoluteString])
        #expect(arguments.first == "-J")
        #expect(arguments.contains("--no-playlist"))
        #expect(Array(arguments.drop { $0 != "--playlist-items" }.prefix(2)) == ["--playlist-items", "1"])
        #expect(Array(arguments.drop { $0 != "--cache-dir" }.prefix(2)) == ["--cache-dir", cache.path])
        #expect(Array(arguments.drop { $0 != "--socket-timeout" }.prefix(2)) == ["--socket-timeout", "20"])
    }

    /// yt-dlp merges and checks formats with ffmpeg: the app's own, not whatever is on PATH, if any.
    @Test func argumentsNameTheAppsFFmpeg() {
        let ffmpeg = URL(fileURLWithPath: "/Applications/Paper Plane.app/Contents/Helpers/ffmpeg")
        let arguments = YtDlpCommand.arguments(page: page, cacheFolder: cache, ffmpeg: ffmpeg)
        #expect(Array(arguments.drop { $0 != "--ffmpeg-location" }.prefix(2)) == ["--ffmpeg-location", ffmpeg.path])
        #expect(Array(arguments.suffix(2)) == ["--", page.absoluteString])
        #expect(!YtDlpCommand.arguments(page: page, cacheFolder: cache).contains("--ffmpeg-location"))
    }

    /// The owner's own yt-dlp configuration never applies, and the cookie arrives on stdin (decision 5).
    @Test func argumentsReadConfigurationOnlyFromStandardInput() {
        let arguments = YtDlpCommand.arguments(page: page, cacheFolder: cache)
        #expect(arguments.contains("--ignore-config"))
        #expect(Array(arguments.drop { $0 != "--config-locations" }.prefix(2)) == ["--config-locations", "-"])
        #expect(!arguments.contains { $0.localizedCaseInsensitiveContains("cookie") })
    }

    /// Spec §5.3: formats that can be copied (H.264 with AAC) first, up to 1080p by the shorter
    /// side, so a vertical Short (1080×1920) isn't sent at 480p; and only formats ffmpeg can read
    /// (decision 7), so yt-dlp falls through to one when the best is DASH, RTMP and the like.
    @Test func formatsPreferH264AndAACUpTo1080pAndOnlyWhatFFmpegReads() {
        let arguments = YtDlpCommand.arguments(page: page, cacheFolder: cache)
        #expect(Array(arguments.drop { $0 != "-f" }.prefix(2)) == ["-f", YtDlpCommand.formats])
        #expect(Array(arguments.drop { $0 != "-S" }.prefix(2)) == ["-S", "res:1080"])
        let readable = YtDlpCommand.readable
        for refused in ["[protocol!*=dash]", "[protocol!^=rtmp]", "[protocol!=f4m]", "[protocol!=ism]",
                        "[protocol!=websocket_frag]", "[protocol!=rtsp]", "[protocol!=mms]", "[protocol!=mhtml]"] {
            #expect(readable.contains(refused), "\(refused)")
        }
        #expect(YtDlpCommand.formats.split(separator: "/").map(String.init) == [
            "bv[vcodec^=avc1]\(readable)+ba[acodec^=mp4a]\(readable)",
            "b[vcodec^=avc1]\(readable)",
            "bv\(readable)+ba\(readable)",
            "b\(readable)",
        ])
        #expect(!YtDlpCommand.formats.contains("height"), "a height cap sends Shorts at 480p")
    }

    @Test func noCookieMeansAnEmptyConfiguration() {
        #expect(YtDlpCommand.configuration(cookie: nil) == "")
        #expect(YtDlpCommand.configuration(cookie: "") == "")
        #expect(YtDlpCommand.configuration(cookie: "\r\n") == "")
        #expect(YtDlpCommand.configuration(cookie: "SID=abc; HSID=def") == "--add-headers 'Cookie:SID=abc; HSID=def'\n")
    }

    /// yt-dlp reads its configuration with Python's shlex. Whatever a cookie holds, it comes back as
    /// the one argument to --add-headers: no quote, comment or line break can add an option such as
    /// --plugin-dirs, which would load code (Review Focus 3).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func hostileCookiesStayOneArgument() throws {
        let hostile = "a=1; b='; --plugin-dirs /tmp/x; c=\"q\" # not a comment\nd=2\r--exec rm\u{0}; e=\\'x' '; f=é\u{7f}"
        let parsed = try Self.shlexSplit(YtDlpCommand.configuration(cookie: hostile))
        #expect(parsed == ["--add-headers", "Cookie:a=1; b='; --plugin-dirs /tmp/x; c=\"q\" # not a commentd=2--exec rm; e=\\'x' '; f="])
    }

    /// yt-dlp finds a JavaScript runtime (Deno) or other tools that Homebrew installed, though apps
    /// started from the Dock get only the system's PATH (decision 8).
    @Test func pathFindsHomebrewTools() {
        let environment = YtDlpCommand.environment(base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone"])
        #expect(environment["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(environment["HOME"] == "/Users/someone")
        #expect(YtDlpCommand.environment(base: ["PATH": "/opt/homebrew/bin:/usr/bin"])["PATH"]
            == "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
        #expect(YtDlpCommand.environment(base: [:])["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }

    /// Splits `text` the way yt-dlp reads a configuration: `shlex.split(text, comments=True)`.
    static func shlexSplit(_ text: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c",
                             "import json, shlex, sys; print(json.dumps(shlex.split(sys.stdin.read(), comments=True)))"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONDecoder().decode([String].self, from: data)
    }
}
