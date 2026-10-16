import Foundation

/// The master playlist Paper Plane hands to the player (`master.m3u8`). It points at ffmpeg's
/// `index.m3u8` and adds what ffmpeg can't:
/// - `EXT-X-START:TIME-OFFSET=0`, so a still-growing playlist starts at its beginning instead of
///   its live edge (docs/sony-test-results.md, row 7a).
/// - `CODECS`, `RESOLUTION`, `FRAME-RATE` and `VIDEO-RANGE`, which Apple's HLS authoring spec
///   asks for and which tell the TV up front that a stream is HDR. AVFoundation refuses a
///   `VIDEO-RANGE=PQ` variant that has no `FRAME-RATE`, and refuses HDR video declared as SDR.
/// - The text subtitles, as WebVTT renditions the player can switch between without a restart
///   (docs/sony-test-results.md, row 5).
enum MasterPlaylist {
    static let fileName = "master.m3u8"

    /// One subtitle rendition. `name` must be unique in the playlist: the player's subtitle
    /// options are matched to tracks by it.
    struct Subtitle: Equatable, Sendable {
        var name: String
        /// An RFC 5646 tag (`TrackNames.languageTag`), or nil.
        var language: String?
        var isForced: Bool
        var uri: String
    }

    static func text(bandwidth: Int, initSegment: InitSegment, frameRate: Double?, videoRange: VideoRange,
                     subtitles: [Subtitle] = []) -> String {
        var attributes = ["BANDWIDTH=\(bandwidth)"]
        if let codecs = initSegment.codecs {
            attributes.append("CODECS=\"\(codecs.joined(separator: ","))\"")
        }
        if let width = initSegment.width, let height = initSegment.height, width > 0, height > 0 {
            attributes.append("RESOLUTION=\(width)x\(height)")
        }
        if let frameRate, frameRate > 0 {
            attributes.append(String(format: "FRAME-RATE=%.3f", frameRate))
        }
        attributes.append("VIDEO-RANGE=\(videoRange.rawValue)")
        if !subtitles.isEmpty {
            attributes.append("SUBTITLES=\"subs\"")
        }
        let media = subtitles.map { subtitle in
            var fields = ["TYPE=SUBTITLES", "GROUP-ID=\"subs\"", "NAME=\"\(quoted(subtitle.name))\""]
            if let language = subtitle.language {
                fields.append("LANGUAGE=\"\(quoted(language))\"")
            }
            // Nothing is on by default: the controller picks, so a forced track still needs
            // AUTOSELECT (which FORCED=YES requires) but not DEFAULT.
            fields += ["DEFAULT=NO", "AUTOSELECT=YES", "FORCED=\(subtitle.isForced ? "YES" : "NO")",
                       "URI=\"\(quoted(subtitle.uri))\""]
            return "#EXT-X-MEDIA:" + fields.joined(separator: ",")
        }
        return ([
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-START:TIME-OFFSET=0",
        ] + media + [
            "#EXT-X-STREAM-INF:" + attributes.joined(separator: ","),
            HLSFileNames.mediaPlaylist,
            "",
        ]).joined(separator: "\n")
    }

    /// The playlist for one subtitle rendition: a single WebVTT file covering the session
    /// (the shape the Sony test played, row 5).
    static func subtitlePlaylist(file: String, duration: Double) -> String {
        [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(Int(duration.rounded(.up)))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            String(format: "#EXTINF:%.3f,", duration),
            file,
            "#EXT-X-ENDLIST",
            "",
        ].joined(separator: "\n")
    }

    /// Peak bits per second over the segments so far, with 10% headroom.
    static func bandwidth(segmentSizes: [(bytes: Int, duration: Double)]) -> Int {
        let peak = segmentSizes
            .filter { $0.duration > 0 }
            .map { Double($0.bytes) * 8 / $0.duration }
            .max() ?? 0
        return max(Int((peak * 1.1).rounded(.up)), 100_000)
    }

    /// A quoted-string attribute value can't hold a double quote or a line break.
    private static func quoted(_ text: String) -> String {
        String(text.map { $0 == "\"" ? "'" : $0.isNewline ? " " : $0 })
    }
}
