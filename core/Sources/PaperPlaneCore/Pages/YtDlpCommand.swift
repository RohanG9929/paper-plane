import Foundation

/// How Paper Plane asks yt-dlp about a page (spec §5.3; Milestone 4, decisions 5–8).
enum YtDlpCommand {
    /// Formats that can be copied (H.264 with AAC) up to 1080p first, then anything up to 1080p,
    /// then anything at all; separate video and audio before a combined file. Never DASH, which
    /// ffmpeg can't read.
    static let formats = [
        "bv[height<=1080][vcodec^=avc1][protocol!*=dash]+ba[acodec^=mp4a][protocol!*=dash]",
        "b[height<=1080][vcodec^=avc1][protocol!*=dash]",
        "bv[height<=1080][protocol!*=dash]+ba[protocol!*=dash]",
        "b[height<=1080][protocol!*=dash]",
        "bv[protocol!*=dash]+ba[protocol!*=dash]",
        "b[protocol!*=dash]",
    ].joined(separator: "/")

    /// One JSON answer for one video (a playlist link gives its first). Configuration comes only
    /// from standard input, never from the owner's own yt-dlp settings, and the page comes after
    /// `--`, so it can never be read as an option.
    static func arguments(page: URL, cacheFolder: URL) -> [String] {
        [
            "-J", "--no-playlist", "--playlist-items", "1",
            "--socket-timeout", "20",
            "--cache-dir", cacheFolder.path,
            "-f", formats,
            "--ignore-config", "--config-locations", "-",
            "--", page.absoluteString,
        ]
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
        for folder in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(folder) {
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
