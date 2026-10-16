import Foundation

/// The master playlist Paper Plane hands to the player (`master.m3u8`). It points at ffmpeg's
/// `index.m3u8` and adds what ffmpeg can't:
/// - `EXT-X-START:TIME-OFFSET=0`, so a still-growing playlist starts at its beginning instead of
///   its live edge (docs/sony-test-results.md, row 7a).
/// - `CODECS`, `RESOLUTION`, `FRAME-RATE` and `VIDEO-RANGE`, which Apple's HLS authoring spec
///   asks for and which tell the TV up front that a stream is HDR. AVFoundation refuses a
///   `VIDEO-RANGE=PQ` variant that has no `FRAME-RATE`, and refuses HDR video declared as SDR.
enum MasterPlaylist {
    static let fileName = "master.m3u8"

    static func text(bandwidth: Int, initSegment: InitSegment, frameRate: Double?, videoRange: VideoRange) -> String {
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
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-START:TIME-OFFSET=0",
            "#EXT-X-STREAM-INF:" + attributes.joined(separator: ","),
            HLSFileNames.mediaPlaylist,
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
}
