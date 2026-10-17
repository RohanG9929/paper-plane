import Foundation

/// A page yt-dlp has resolved: what ffmpeg reads, and where the link itself says to start.
public struct ResolvedPage: Equatable, Sendable {
    public var input: ResolvedInput
    /// From the link (YouTube's `t=`), in seconds; nil when it names none.
    public var startTime: Double?

    public init(input: ResolvedInput, startTime: Double? = nil) {
        self.input = input
        self.startTime = startTime
    }
}

/// Why a page gave no video (Milestone 4, decision 13).
public enum YtDlpFailure: Error, Equatable, Sendable {
    /// No yt-dlp to run.
    case missing
    /// yt-dlp knows no video at this address.
    case unsupported
    /// Only formats ffmpeg can't read (RTMP, Smooth Streaming, …).
    case noPlayableFormat
    /// yt-dlp's own reason, the first sentence of its last error (nil when it gave none), and its
    /// last words, redacted, for the failure log. Two failures are the same if their reasons are.
    case failed(reason: String?, log: String = "")
    /// The site took longer than the time limit.
    case timedOut
    /// No network, or the site doesn't answer.
    case unreachable
    /// YouTube needs a JavaScript runtime (Deno) that yt-dlp didn't find.
    case needsJavaScriptRuntime

    public static func == (lhs: YtDlpFailure, rhs: YtDlpFailure) -> Bool {
        switch (lhs, rhs) {
        case (.missing, .missing), (.unsupported, .unsupported), (.noPlayableFormat, .noPlayableFormat), (.timedOut, .timedOut),
             (.unreachable, .unreachable), (.needsJavaScriptRuntime, .needsJavaScriptRuntime):
            true
        case let (.failed(left, _), .failed(right, _)):
            left == right
        default:
            false
        }
    }

    /// Reads yt-dlp's stderr after it failed.
    static func from(stderr: Data) -> YtDlpFailure {
        let lines = String(decoding: stderr, as: UTF8.self).split(whereSeparator: \.isNewline)
        let log = Redaction.summary(of: stderr)
        guard let error = lines.last(where: { $0.hasPrefix("ERROR:") }) else { return .failed(reason: nil, log: log) }
        var message = error.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
        if lines.contains(where: { $0.hasPrefix("WARNING:") && $0.localizedCaseInsensitiveContains("JavaScript runtime") }) {
            return .needsJavaScriptRuntime
        }
        if ["TransportError", "timed out", "nodename nor servname", "Connection refused", "Network is unreachable"]
            .contains(where: { message.contains($0) }) {
            return .unreachable
        }
        if message.contains("Unsupported URL") {
            return .unsupported
        }
        // Python's own account of the error isn't for the remote.
        if let cause = message.range(of: " (caused by ") {
            message = String(message[..<cause.lowerBound])
        }
        if message.contains("Requested format is not available") {
            return .noPlayableFormat
        }
        // "[youtube] aqz-KE-bpKQ: Private video. Sign in if …" → "Private video."
        if let prefix = message.firstMatch(of: /^\[[^\]]*\]\s*([^\s:]+:\s*)?/) {
            message.removeSubrange(prefix.range)
        }
        if let end = message.firstMatch(of: /[.!?](\s|$)/) {
            message = String(message[..<end.range.lowerBound]) + String(message[end.range].prefix(1))
        }
        message = Redaction.redact(message)
        if message.count > 200 {
            message = String(message.prefix(200)) + "…"
        }
        return .failed(reason: message.isEmpty ? nil : message, log: log)
    }
}

/// Turns yt-dlp's `-J` answer into ffmpeg inputs (Milestone 4, decision 9).
enum YtDlpOutput {
    /// How yt-dlp names a format that is one representation of a DASH manifest (it has no other
    /// name for DASH).
    static let dashProtocol = "http_dash_segments"
    /// What ffmpeg may be given: plain HTTP(S) files, HLS, and DASH (as its manifest). Never RTMP
    /// and the like.
    static let playableProtocols: Set = ["https", "http", "m3u8", "m3u8_native", dashProtocol]
    /// Headers the proxy sets or that only make sense on one connection: a format can't override them.
    static let reservedHeaders: Set = ["accept-encoding", "connection", "content-length", "host", "range",
                                       "transfer-encoding", "keep-alive", "upgrade", "te", "trailer"]

    static func page(from data: Data, page: URL, fallbackTitle: String) throws -> ResolvedPage {
        guard let answer = try? JSONDecoder().decode(Info.self, from: data) else { throw YtDlpFailure.unsupported }
        guard let video = firstVideo(in: answer) else { throw YtDlpFailure.unsupported }
        let formats = video.requestedFormats ?? (video.format.address == nil ? [] : [video.format])
        guard !formats.isEmpty else { throw YtDlpFailure.unsupported }
        var inputs: [ResolvedInput.Input] = []
        for format in formats {
            let next = try input(for: format)
            // A manifest holds the video and the audio: yt-dlp lists each representation as a
            // format of its own, all naming the one manifest, which is read once.
            if next.manifest == .dash, inputs.contains(where: { $0.manifest == .dash && $0.url == next.url }) { continue }
            inputs.append(next)
        }

        let start = video.startTime.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return ResolvedPage(
            input: ResolvedInput(inputs: inputs, title: PlayRequest.tidyTitle(video.title, otherwise: fallbackTitle), page: page),
            startTime: start)
    }

    /// The answer itself, or a playlist's first video: playlists aren't played (spec, non-goals).
    /// A channel is a playlist of playlists; a page with several parts is a `multi_video`.
    private static func firstVideo(in info: Info, depth: Int = 0) -> Info? {
        guard info.type == "playlist" || info.type == "multi_video" else { return info }
        guard depth < 3, let first = info.entries?.lazy.compactMap({ $0 }).first else { return nil }
        return firstVideo(in: first, depth: depth + 1)
    }

    private static func input(for format: Format) throws -> ResolvedInput.Input {
        guard let url = Links.webLink(in: format.address), let scheme = url.scheme?.lowercased(),
              playableProtocols.contains(format.protocol ?? scheme)
        else { throw YtDlpFailure.noPlayableFormat }
        var headers: [String: String] = [:]
        for (name, value) in format.headers ?? [:] where isToken(name) && !reservedHeaders.contains(name.lowercased()) {
            headers[name] = ResolvedInput.Input.stripLineBreaks(value)
        }
        let manifest: ManifestKind = format.isDash ? .dash : (format.protocol ?? "").hasPrefix("m3u8") ? .hls : .none
        return ResolvedInput.Input(url: url, headers: headers, manifest: manifest)
    }

    /// An HTTP header name: letters, digits and a few marks, nothing else.
    private static func isToken(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "!#$%&'*+-.^_`|~".unicodeScalars.contains($0))
        }
    }

    private struct Format: Decodable {
        var url: String?
        var `protocol`: String?
        var headers: [String: String]?
        /// The manifest a DASH or HLS format came from; the same for all of a DASH manifest's formats.
        var manifestURL: String?

        enum CodingKeys: String, CodingKey {
            case url, `protocol`, headers = "http_headers", manifestURL = "manifest_url"
        }

        var isDash: Bool { `protocol` == YtDlpOutput.dashProtocol }

        /// What ffmpeg is given. A DASH format's own `url` is a template for one representation's
        /// segments, not something ffmpeg can open: it reads the manifest (`manifest_url`), with
        /// `url` only if there is none. Any other format is read at its `url`, even if it has a
        /// `manifest_url` (an HLS media playlist names its master playlist).
        var address: String? { isDash ? (manifestURL ?? url) : url }
    }

    private struct Info: Decodable {
        var type: String?
        var title: String?
        var startTime: Double?
        var entries: [Info?]?
        var requestedFormats: [Format]?
        var url: String?
        var `protocol`: String?
        var headers: [String: String]?
        var manifestURL: String?

        /// A single format's fields sit in the answer itself.
        var format: Format { Format(url: url, protocol: `protocol`, headers: headers, manifestURL: manifestURL) }

        enum CodingKeys: String, CodingKey {
            case type = "_type", title, startTime = "start_time", entries, requestedFormats = "requested_formats"
            case url, `protocol`, headers = "http_headers", manifestURL = "manifest_url"
        }
    }
}
