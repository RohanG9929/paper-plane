import Foundation

/// How Paper Plane asks yt-dlp about a page (spec §5.3; Milestone 4, decisions 5–8).
enum YtDlpCommand {
    /// Only what ffmpeg reads: never RTMP, RTSP, MMS, Smooth Streaming, Flash's f4m, websockets or
    /// storyboards. Excluding them here lets yt-dlp fall through to a format that plays instead of
    /// handing one back that won't. DASH is allowed: ffmpeg reads it from its manifest.
    static let readable = "[protocol!^=rtmp][protocol!=rtsp][protocol!=mms][protocol!=ism]"
        + "[protocol!=f4m][protocol!=websocket_frag][protocol!=mhtml]"

    /// Formats that can be copied (H.264 with AAC) first, then anything; separate video and audio
    /// before a combined file. Which of each comes from the sort: up to 1080p by the shorter side
    /// (`-S res:1080`), so a vertical Short is 1080×1920, not 480×854.
    static let formats = [
        "bv[vcodec^=avc1]\(readable)+ba[acodec^=mp4a]\(readable)",
        "b[vcodec^=avc1]\(readable)",
        "bv\(readable)+ba\(readable)",
        "b\(readable)",
    ].joined(separator: "/")

    /// One JSON answer for one video (a playlist link gives its first). Configuration comes only
    /// from standard input, never from the owner's own yt-dlp settings, and the page comes after
    /// `--`, so it can never be read as an option. `ffmpeg` is the app's, which yt-dlp uses to
    /// judge which formats it can merge.
    static func arguments(page: URL, cacheFolder: URL, ffmpeg: URL? = nil) -> [String] {
        ["-J", "--no-playlist", "--playlist-items", "1", "--socket-timeout", "20", "--cache-dir", cacheFolder.path]
            + (ffmpeg.map { ["--ffmpeg-location", $0.path] } ?? [])
            + ["-f", formats, "-S", "res:1080", "--ignore-config", "--config-locations", "-", "--", page.absoluteString]
    }

    /// The configuration yt-dlp reads from standard input: the site's cookie, which yt-dlp keeps
    /// to the page's own domain. On standard input it never shows on a command line, where other
    /// processes could read it, nor in a file (spec §5.4).
    static func configuration(cookie: String?) -> String {
        let cookie = printable(cookie ?? "")
        guard !cookie.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return "--add-headers \(quoted("Cookie:" + cookie))\n"
    }

    /// The app's environment, with Homebrew's folders after the system's on PATH, so yt-dlp finds
    /// a JavaScript runtime (Deno) installed there.
    static func environment(base: [String: String]) -> [String: String] {
        var environment = base
        var path = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for folder in ToolPaths.homebrewFolders where !path.contains(folder) {
            path.append(folder)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    /// Visible ASCII and spaces only: a header has no business holding anything else, and line
    /// breaks or control characters could end the quoted argument early.
    private static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }))
    }

    /// Single-quoted for Python's shlex (how yt-dlp reads a configuration): nothing inside single
    /// quotes is special, and a single quote is closed, escaped and reopened.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }
}
