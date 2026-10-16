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
    /// Only formats ffmpeg can't read (DASH, RTMP, …).
    case noPlayableFormat
    /// yt-dlp's own reason, the first sentence of its last error (nil when it gave none), and its
    /// last words, redacted, for the failure log. Two failures are the same if their reasons are.
    case failed(reason: String?, log: String = "")
    /// The site took longer than the time limit.
    case timedOut

    public static func == (lhs: YtDlpFailure, rhs: YtDlpFailure) -> Bool {
        switch (lhs, rhs) {
        case (.missing, .missing), (.unsupported, .unsupported), (.noPlayableFormat, .noPlayableFormat), (.timedOut, .timedOut):
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
        if message.contains("Unsupported URL") {
            return .unsupported
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
    /// What ffmpeg may be given: plain HTTP(S) files and HLS. Never DASH, RTMP and the like.
    static let playableProtocols: Set = ["https", "http", "m3u8", "m3u8_native"]
    /// Headers the proxy sets or that only make sense on one connection: a format can't override them.
    static let reservedHeaders: Set = ["accept-encoding", "connection", "content-length", "host", "range",
                                       "transfer-encoding", "keep-alive", "upgrade", "te", "trailer"]

    static func page(from data: Data, page: URL, fallbackTitle: String) throws -> ResolvedPage {
        guard let answer = try? JSONDecoder().decode(Info.self, from: data) else { throw YtDlpFailure.unsupported }
        // A playlist link plays its first video: playlists aren't played (spec, non-goals).
        let video = answer.type == "playlist" ? answer.entries?.lazy.compactMap { $0 }.first : answer
        guard let video else { throw YtDlpFailure.unsupported }
        let formats = video.requestedFormats ?? (video.url == nil ? [] : [video.format])
        guard !formats.isEmpty else { throw YtDlpFailure.unsupported }
        let inputs = try formats.map(input(for:))

        let title = (video.title ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let start = video.startTime.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return ResolvedPage(
            input: ResolvedInput(inputs: inputs, title: String((title.isEmpty ? fallbackTitle : title).prefix(PlayRequest.maximumTitleLength)),
                                 page: page),
            startTime: start)
    }

    private static func input(for format: Format) throws -> ResolvedInput.Input {
        guard let text = format.url, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host(), !host.isEmpty,
              playableProtocols.contains(format.protocol ?? scheme)
        else { throw YtDlpFailure.noPlayableFormat }
        var headers: [String: String] = [:]
        for (name, value) in format.headers ?? [:] where isToken(name) && !reservedHeaders.contains(name.lowercased()) {
            headers[name] = String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
        }
        return ResolvedInput.Input(url: url, headers: headers, isHLS: (format.protocol ?? "").hasPrefix("m3u8"))
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

        enum CodingKeys: String, CodingKey {
            case url, `protocol`, headers = "http_headers"
        }
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

        /// A single format's fields sit in the answer itself.
        var format: Format { Format(url: url, protocol: `protocol`, headers: headers) }

        enum CodingKeys: String, CodingKey {
            case type = "_type", title, startTime = "start_time", entries, requestedFormats = "requested_formats"
            case url, `protocol`, headers = "http_headers"
        }
    }
}
