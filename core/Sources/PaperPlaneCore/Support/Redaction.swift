import Foundation

/// Keeps secrets out of error messages and logs.
enum Redaction {
    /// Replaces URL query strings, which often carry access tokens, with `?…`.
    static func redactQueries(_ text: String) -> String {
        text.replacing(/\?[^\s'"]+/, with: "?…")
    }

    /// The last 20 non-empty lines of a tool's stderr, redacted, for error messages.
    static func summary(of stderr: Data) -> String {
        let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return redactQueries(lines.suffix(20).joined(separator: "\n"))
    }
}
