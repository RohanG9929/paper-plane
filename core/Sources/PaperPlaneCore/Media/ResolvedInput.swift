import Foundation

/// The ffmpeg input(s) for one playback. Web videos can arrive as separate video and
/// audio streams, so there may be more than one.
public struct ResolvedInput: Equatable, Sendable {
    public struct Input: Equatable, Sendable {
        public var url: URL
        /// HTTP headers the site expects (cookies, referer, user agent). Never logged.
        public var headers: [String: String]

        public init(url: URL, headers: [String: String] = [:]) {
            self.url = url
            self.headers = headers
        }

        /// What to pass to ffmpeg's `-i`: a plain path for files, the full URL otherwise.
        public var ffmpegLocation: String {
            url.isFileURL ? url.path : url.absoluteString
        }

        /// Options that must come right before this input's `-i` (ffmpeg) or the input (ffprobe).
        public var ffmpegOptions: [String] {
            guard !url.isFileURL else { return [] }
            var remaining = Dictionary(
                headers.map { (Self.stripLineBreaks($0.key), Self.stripLineBreaks($0.value)) },
                uniquingKeysWith: { first, _ in first })
            var options: [String] = []
            if let key = remaining.keys.first(where: { $0.lowercased() == "user-agent" }),
               let agent = remaining.removeValue(forKey: key) {
                options += ["-user_agent", agent]
            }
            if !remaining.isEmpty {
                let block = remaining.keys.sorted().map { "\($0): \(remaining[$0]!)\r\n" }.joined()
                options += ["-headers", block]
            }
            return options
        }

        /// Removes CR and LF so a header value can't smuggle in extra headers.
        private static func stripLineBreaks(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
        }
    }

    public var inputs: [Input]
    public var title: String

    public init(inputs: [Input], title: String) {
        self.inputs = inputs
        self.title = title
    }

    /// A local file, titled by its name without the extension.
    public static func file(_ url: URL) -> ResolvedInput {
        ResolvedInput(inputs: [Input(url: url)], title: url.deletingPathExtension().lastPathComponent)
    }
}
