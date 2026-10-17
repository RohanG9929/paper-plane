import Foundation

/// What a web input is, when it names the video's parts rather than being the video: an HLS
/// playlist or a DASH manifest, whose segments may be named anything and which ffmpeg reads
/// each its own way.
public enum ManifestKind: Equatable, Sendable {
    case none, hls, dash
}

/// The ffmpeg input(s) for one playback. Web videos can arrive as separate video and
/// audio streams, so there may be more than one.
public struct ResolvedInput: Equatable, Sendable {
    public struct Input: Equatable, Sendable {
        public var url: URL
        /// HTTP headers the site expects (cookies, referer, user agent, authorization). Never logged.
        public var headers: [String: String]
        /// Whether the input is an HLS playlist or a DASH manifest, rather than a video file.
        public var manifest: ManifestKind

        public init(url: URL, headers: [String: String] = [:], manifest: ManifestKind = .none) {
            self.url = url
            self.headers = headers
            self.manifest = manifest
        }

        /// What to pass to ffmpeg's `-i`: a plain path for files, the full URL otherwise.
        public var ffmpegLocation: String {
            url.isFileURL ? url.path : url.absoluteString
        }

        /// What a web input, and every playlist or segment it names, may be read over: never
        /// file:, udp: or rtp:, whatever a site's playlist says. A site that stops answering is
        /// given up on after 30 seconds rather than waited for for ever.
        static let webOnly = ["-protocol_whitelist", "https,http,tls,tcp,crypto,data", "-rw_timeout", "30000000"]

        /// Options that must come right before this input's `-i` (ffmpeg) or the input (ffprobe).
        public var ffmpegOptions: [String] {
            guard !url.isFileURL else { return [] }
            var remaining = Dictionary(
                headers.map { (Self.stripLineBreaks($0.key), Self.stripLineBreaks($0.value)) },
                uniquingKeysWith: { first, _ in first })
            var options = Self.webOnly
            if let key = remaining.keys.first(where: { $0.lowercased() == "user-agent" }),
               let agent = remaining.removeValue(forKey: key) {
                options += ["-user_agent", agent]
            }
            if !remaining.isEmpty {
                let block = remaining.keys.sorted().map { "\($0): \(remaining[$0]!)\r\n" }.joined()
                options += ["-headers", block]
            }
            if manifest == .hls { // (ffmpeg's DASH demuxer rejects the option)
                options += ["-extension_picky", "0"] // segments named anything (the whitelist guards)
            }
            return options
        }

        /// Removes CR and LF so a header value can't smuggle in extra headers.
        static func stripLineBreaks(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
        }
    }

    public var inputs: [Input]
    public var title: String
    /// The page yt-dlp found the inputs on, if any. Its address, not theirs, decides whether they
    /// may come from this Mac or the local network (Milestone 4, decision 12).
    public var page: URL?

    public init(inputs: [Input], title: String, page: URL? = nil) {
        self.inputs = inputs
        self.title = title
        self.page = page
    }

    /// From the web, as opposed to files on this Mac.
    public var isWeb: Bool {
        inputs.contains { !$0.url.isFileURL }
    }

    /// A local file, titled by its name without the extension.
    public static func file(_ url: URL) -> ResolvedInput {
        ResolvedInput(inputs: [Input(url: url)], title: url.deletingPathExtension().lastPathComponent)
    }
}
