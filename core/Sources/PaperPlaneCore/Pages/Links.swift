import Foundation

/// Links from the clipboard, a drop or the browser (Milestone 4, decisions 10 and 11).
public enum Links {
    /// The web link `text` is, trimmed: `http` or `https` with a host. Anything else (a file, a
    /// script, several lines, a bare domain) is nil.
    public static func webLink(in text: String?) -> URL? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// A link straight to an HLS playlist, a DASH manifest or a video file, which ffmpeg reads as
    /// it is; nil for a page, which yt-dlp has to look at first.
    public static func direct(_ url: URL) -> ResolvedInput? {
        let title = PlayRequest.fallbackTitle(for: url, otherwise: placeholderTitle(for: url))
        switch url.pathExtension.lowercased() {
        case "m3u8": return ResolvedInput(inputs: [.init(url: url, manifest: .hls)], title: title)
        case "mpd": return ResolvedInput(inputs: [.init(url: url, manifest: .dash)], title: title)
        default: break
        }
        return VideoFiles.isVideo(extension: url.pathExtension) ? ResolvedInput(inputs: [.init(url: url)], title: title) : nil
    }

    /// Pages the browser may send for yt-dlp: YouTube's, over HTTPS (the extension sends no others).
    public static func isYouTubePage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil, let host = url.host()?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// The address to give yt-dlp for `page`: a YouTube page as www.youtube.com, where yt-dlp
    /// asks for the video, since it keeps a cookie to the exact host it's given (youtu.be/ID
    /// becomes watch?v=ID). Any other page as it is.
    public static func forYtDlp(_ page: URL) -> URL {
        guard let host = page.host()?.lowercased(), host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com"),
              var parts = URLComponents(url: page, resolvingAgainstBaseURL: false)
        else { return page }
        if host == "youtu.be" {
            let id = page.path().split(separator: "/").first.map(String.init)
            guard let id else { return page }
            parts.path = "/watch"
            parts.queryItems = [URLQueryItem(name: "v", value: id)] + (parts.queryItems ?? [])
        }
        parts.host = "www.youtube.com"
        return parts.url ?? page
    }

    /// What to call a page until yt-dlp names it: its site.
    public static func placeholderTitle(for url: URL) -> String {
        let host = url.host() ?? "Link"
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
