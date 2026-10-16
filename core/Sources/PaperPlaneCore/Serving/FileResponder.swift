import Foundation

/// Answers one HTTP request for a file in a session folder. Only `/<token>/<file name>` is
/// served; everything else is 404. Files are read when asked for, so a playlist ffmpeg is still
/// rewriting and segments that appear later are always current.
struct FileResponder: Sendable {
    var folder: URL
    var token: String

    static let contentTypes = [
        "m3u8": "application/vnd.apple.mpegurl",
        "m4s": "video/iso.segment",
        "mp4": "video/mp4",
        "ts": "video/mp2t",
        "vtt": "text/vtt",
    ]

    /// `head` is the request line and headers, without the blank line that ends them.
    func response(to head: String) -> Data {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return Self.message(400, "Bad Request")
        }
        let method = requestLine[0]
        guard method == "GET" || method == "HEAD" else {
            return Self.message(405, "Method Not Allowed", extraHeaders: ["Allow: GET, HEAD"])
        }
        let path = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == token, Self.isPlainFileName(parts[2]),
              let data = try? Data(contentsOf: folder.appendingPathComponent(String(parts[2])), options: .mappedIfSafe)
        else {
            return Self.message(404, "Not Found")
        }

        let contentType = Self.contentTypes[(String(parts[2]) as NSString).pathExtension.lowercased()]
            ?? "application/octet-stream"
        var status = "200 OK"
        var headers = ["Content-Type: \(contentType)", "Accept-Ranges: bytes", "Cache-Control: no-cache"]
        var body = data
        switch Self.byteRange(header(named: "range", in: lines), size: data.count) {
        case .whole:
            break
        case .partial(let range):
            status = "206 Partial Content"
            headers.append("Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)")
            body = data.subdata(in: range)
        case .unsatisfiable:
            return Self.message(416, "Range Not Satisfiable", extraHeaders: ["Content-Range: bytes */\(data.count)"])
        }
        headers.append("Content-Length: \(body.count)")
        return Self.head(status, headers) + (method == "HEAD" ? Data() : body)
    }

    // MARK: - Ranges

    enum ByteRange: Equatable {
        case whole
        case partial(Range<Int>)
        case unsatisfiable
    }

    /// One `bytes=` range (RFC 9110 §14). Anything else, including several ranges, gets the whole
    /// file, which the RFC allows.
    static func byteRange(_ value: String?, size: Int) -> ByteRange {
        guard let value, value.hasPrefix("bytes="), !value.contains(",") else { return .whole }
        let spec = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2 else { return .whole }
        let first = Int(spec[0].trimmingCharacters(in: .whitespaces))
        let last = Int(spec[1].trimmingCharacters(in: .whitespaces))
        switch (first, last) {
        case (let first?, let last?) where first <= last:
            return first < size ? .partial(first..<min(last + 1, size)) : .unsatisfiable
        case (let first?, nil) where spec[1].isEmpty:
            return first < size ? .partial(first..<size) : .unsatisfiable
        case (nil, let suffix?) where spec[0].isEmpty:
            return suffix > 0 && size > 0 ? .partial(max(0, size - suffix)..<size) : .unsatisfiable
        default:
            return .whole
        }
    }

    // MARK: - Helpers

    /// Letters, digits, `.`, `_` and `-`, not starting with `.`: no paths, no hidden files.
    static func isPlainFileName(_ name: Substring) -> Bool {
        guard let first = name.first, first != "." else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    private func header(named name: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == name {
                return pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func head(_ status: String, _ headers: [String]) -> Data {
        Data((["HTTP/1.1 \(status)"] + headers + ["Connection: close", "", ""]).joined(separator: "\r\n").utf8)
    }

    private static func message(_ code: Int, _ reason: String, extraHeaders: [String] = []) -> Data {
        let body = Data("\(reason)\n".utf8)
        let headers = ["Content-Type: text/plain; charset=utf-8", "Content-Length: \(body.count)"] + extraHeaders
        return head("\(code) \(reason)", headers) + body
    }
}
