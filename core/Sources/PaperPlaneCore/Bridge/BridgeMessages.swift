import Foundation

/// Chrome's native messaging framing (spec §5.2): a 4-byte length in native byte order
/// (little-endian on Apple Silicon), then that many bytes of UTF-8 JSON. The bridge socket
/// uses the same framing, so the helper only relays bytes.
public enum NativeMessaging {
    /// Nothing legitimate is more than a few KB; this keeps a broken or hostile sender from
    /// making the app allocate gigabytes.
    public static let maximumLength = 1 << 20

    public enum Error: Swift.Error, Equatable {
        case tooLarge
    }

    public static func frame(_ message: Data) -> Data {
        var length = UInt32(message.count).littleEndian
        return Data(bytes: &length, count: 4) + message
    }

    /// The length a frame's first 4 bytes announce, or nil if they haven't all arrived.
    static func announcedLength(in buffer: Data) -> Int? {
        guard buffer.count >= 4 else { return nil }
        let bytes = [UInt8](buffer.prefix(4))
        return Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
    }

    /// Removes and returns the first whole message in `buffer`, or nil if it hasn't all
    /// arrived. Throws for a length of `maximumLength` or more, before reading that much.
    public static func take(from buffer: inout Data) throws -> Data? {
        guard let length = announcedLength(in: buffer) else { return nil }
        guard length < maximumLength else { throw Error.tooLarge }
        guard buffer.count >= 4 + length else { return nil }
        let start = buffer.startIndex + 4
        let message = Data(buffer[start..<(start + length)])
        buffer = Data(buffer[(start + length)...])
        return message
    }
}

/// A request from the extension to play something (spec §5.2, message v1), checked before
/// anything is done with it.
public struct PlayRequest: Equatable, Sendable {
    public enum Format: String, Sendable {
        case hls, dash, progressive

        /// What ffmpeg is told it is reading.
        public var manifest: ManifestKind {
            switch self {
            case .hls: .hls
            case .dash: .dash
            case .progressive: .none
            }
        }
    }

    public enum Source: Equatable, Sendable {
        /// A stream the extension found, with the headers the site expects.
        case stream(URL, Format, headers: [String: String])
        /// A page for yt-dlp to resolve (YouTube), with the site's cookies.
        case page(URL, headers: [String: String])
    }

    /// The request can't be played safely. `reason` is short and says nothing secret.
    public struct Invalid: Error, Equatable {
        public var reason: String
    }

    public var source: Source
    public var title: String
    /// Where the browser's video was, in seconds.
    public var startAt: Double

    /// The only headers passed on: what sites need to hand over the video, nothing else.
    static let allowedHeaders = ["Cookie", "Referer", "Origin", "User-Agent"]
    /// A page chooses its own title; the remote, the menu and Control Center get at most this.
    public static let maximumTitleLength = 200

    public static func decode(_ data: Data) throws -> PlayRequest {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else {
            throw Invalid(reason: "unreadable request")
        }
        guard message.type == "play", message.v == 1 else { throw Invalid(reason: "unknown request") }
        guard let source = message.source else { throw Invalid(reason: "nothing to play") }
        guard let url = Links.webLink(in: source.url) else { throw Invalid(reason: "not a web address") }
        let startAt = message.startAt ?? 0
        guard startAt.isFinite, startAt >= 0 else { throw Invalid(reason: "bad start time") }
        let headers = allowed(source.headers ?? [:])
        let decodedSource: Source
        switch source.kind {
        case "stream":
            guard let format = source.format.flatMap(Format.init(rawValue:)) else {
                throw Invalid(reason: "unknown format")
            }
            decodedSource = .stream(url, format, headers: headers)
        case "page":
            decodedSource = .page(url, headers: headers)
        default:
            throw Invalid(reason: "unknown source")
        }
        return PlayRequest(source: decodedSource, title: tidyTitle(message.title, otherwise: fallbackTitle(for: url)),
                           startAt: startAt)
    }

    /// What ffmpeg reads, for a stream. nil for a page, which needs yt-dlp first.
    public var input: ResolvedInput? {
        guard case .stream(let url, let format, let headers) = source else { return nil }
        return ResolvedInput(inputs: [ResolvedInput.Input(url: url, headers: headers, manifest: format.manifest)], title: title)
    }

    /// The allowed headers, named the usual way whatever case they came in.
    private static func allowed(_ headers: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for (name, value) in headers {
            if let allowed = allowedHeaders.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                kept[allowed] = value
            }
        }
        return kept
    }

    /// "clip" for …/videos/clip.mp4; `otherwise` when the path says nothing. (lastPathComponent is
    /// already decoded.)
    static func fallbackTitle(for url: URL, otherwise: String = "Video") -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty || name == "/" ? otherwise : name
    }

    /// A title a site chose, on one line and at most `maximumTitleLength` long; `otherwise` when
    /// it chose none.
    static func tidyTitle(_ given: String?, otherwise: @autoclosure () -> String) -> String {
        let line = (given ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String((line.isEmpty ? otherwise() : line).prefix(maximumTitleLength))
    }

    private struct Message: Decodable {
        struct Source: Decodable {
            var kind: String
            var url: String?
            var format: String?
            var headers: [String: String]?
        }

        var type: String
        var v: Int
        var source: Source?
        var title: String?
        var startAt: Double?
    }
}

/// The app's answer to a request (spec §5.2).
public enum PlayReply: Equatable, Sendable {
    case ok
    case failed(String)

    public func encoded() -> Data {
        let object: [String: Any] = switch self {
        case .ok: ["ok": true]
        case .failed(let message): ["ok": false, "error": message]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"ok":false}"#.utf8)
    }

    public static func decode(_ data: Data) -> PlayReply? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool
        else { return nil }
        return ok ? .ok : .failed(object["error"] as? String ?? "Something went wrong.")
    }
}
