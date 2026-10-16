import Foundation

/// Keeps secrets out of error messages and logs.
enum Redaction {
    /// Replaces URL query strings, which often carry access tokens, with `?…`.
    static func redactQueries(_ text: String) -> String {
        text.replacing(/\?[^\s'"]+/, with: "?…")
    }

    /// Everything that must go before ffmpeg output is shown or saved: the values of cookie and
    /// authorization headers, user names and passwords in URLs, and URL query strings.
    static func redact(_ text: String) -> String {
        let headers = text.replacing(/(?i)\b(set-cookie|cookie|proxy-authorization|authorization)\s*:[^\r\n]*/) {
            "\($0.1): …"
        }
        let userInfo = headers.replacing(#/([A-Za-z][A-Za-z0-9+.\-]*://)[^/\s@'"]+@/#) { "\($0.1)…@" }
        return redactQueries(userInfo)
    }

    /// The last 20 non-empty lines of a tool's stderr, redacted, for error messages.
    static func summary(of stderr: Data) -> String {
        let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return redact(lines.suffix(20).joined(separator: "\n"))
    }
}
