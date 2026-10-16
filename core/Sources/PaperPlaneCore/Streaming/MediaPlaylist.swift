import Foundation

/// The parts of ffmpeg's HLS media playlist (`index.m3u8`) that Paper Plane reads back.
struct MediaPlaylist: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        var uri: String
        /// Seconds, from `#EXTINF`.
        var duration: Double
    }

    var segments: [Segment]
    /// True once `#EXT-X-ENDLIST` is there: ffmpeg has written the whole stream.
    var isComplete: Bool

    init(segments: [Segment], isComplete: Bool) {
        self.segments = segments
        self.isComplete = isComplete
    }

    init(parsing text: String) {
        var segments: [Segment] = []
        var pendingDuration: Double?
        var isComplete = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                pendingDuration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
            } else if line == "#EXT-X-ENDLIST" {
                isComplete = true
            } else if !line.isEmpty, !line.hasPrefix("#"), let duration = pendingDuration {
                segments.append(Segment(uri: line, duration: duration))
                pendingDuration = nil
            }
        }
        self.init(segments: segments, isComplete: isComplete)
    }
}
