import Foundation

/// A site refusing a web stream (spec §6): a link that has expired, or cookies it no longer
/// accepts. Clicking Paper Plane in the browser again sends a fresh link.
public enum SiteRefusal {
    /// How ffmpeg reports HTTP 400, 401, 403, 404 and the other 4xx answers (410 Gone among them).
    static let signs = ["Server returned 400", "Server returned 401", "Server returned 403", "Server returned 404",
                        "Server returned 4XX"]

    public static func isRefusal(_ error: any Error) -> Bool {
        switch error {
        case MediaProbeError.ffprobeFailed(_, let message), TranscodeError.ffmpegFailed(_, let message):
            isRefusal(stderr: message)
        default:
            false
        }
    }

    public static func isRefusal(stderr: String) -> Bool {
        signs.contains { stderr.contains($0) }
    }
}
