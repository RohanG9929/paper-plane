import Foundation
import Testing
@testable import PaperPlaneCore

/// `keepingBestVariant()` picks the one representation of a multi-variant stream to play: the
/// tallest that fits in 1080p, preferring a codec Paper Plane copies over one it re-encodes.
struct MediaInfoTests {
    // MARK: - Builders

    static func video(_ codec: VideoCodecName, _ width: Int, _ height: Int, bandwidth: Int?,
                      pixelFormat: String? = "yuv420p", index: Int) -> VideoTrack {
        VideoTrack(ref: TrackRef(index: index), codec: codec, width: width, height: height,
                   pixelFormat: pixelFormat, hdr: nil, variant: bandwidth)
    }

    static func audio(bandwidth: Int?, index: Int) -> AudioTrack {
        AudioTrack(ref: TrackRef(index: index), codec: .aac, channels: 2, language: nil, title: nil,
                   isDefault: false, variant: bandwidth)
    }

    static func media(_ video: [VideoTrack], _ audio: [AudioTrack] = []) -> MediaInfo {
        MediaInfo(duration: 60, video: video, audio: audio, subtitles: [])
    }

    // MARK: - Fixtures

    /// 2160p h264, 1080p h264 (copyable), 1080p vp9 (needs re-encoding, and the highest bandwidth
    /// of the 1080p pair), 720p h264.
    static let multiRep = media([
        video(.h264, 3840, 2160, bandwidth: 12_000_000, index: 0),
        video(.h264, 1920, 1080, bandwidth: 5_000_000, index: 1),
        video(.other("vp9"), 1920, 1080, bandwidth: 6_000_000, index: 2),
        video(.h264, 1280, 720, bandwidth: 2_500_000, index: 3),
    ])

    /// Nothing at or under the cap: only 2160p and 1440p.
    static let allOver1080 = media([
        video(.other("av1"), 3840, 2160, bandwidth: 15_000_000, index: 0),
        video(.h264, 2560, 1440, bandwidth: 8_000_000, index: 1),
    ])

    /// Portrait video: 1080x1920 has a shorter side of 1080; 2160x3840 does not.
    static let verticalReps = media([
        video(.h264, 2160, 3840, bandwidth: 12_000_000, index: 0),
        video(.h264, 1080, 1920, bandwidth: 5_000_000, index: 1),
        video(.h264, 720, 1280, bandwidth: 2_500_000, index: 2),
    ])

    /// A plain file: no variants.
    static let single = media([video(.h264, 1920, 1080, bandwidth: nil, index: 0)], [audio(bandwidth: nil, index: 1)])

    // MARK: - Tests

    @Test func capsAFourKManifestToACopyable1080p() {
        let kept = Self.multiRep.keepingBestVariant()
        #expect(kept.video.count == 1)
        #expect(kept.video.first?.height == 1080)
        #expect(kept.video.first?.codec == .h264)        // the copyable 1080p, not the 2160p, not the 1080p vp9
    }

    @Test func withNothingUnder1080pItKeepsTheSmallestOverCap() {
        // Only 2160p and 1440p offered → keep 1440p (smallest over the cap), to re-encode the least.
        #expect(Self.allOver1080.keepingBestVariant().video.first?.height == 1440)
    }

    @Test func aVerticalVideoIsCappedByItsShorterSide() {
        // 1080x1920 (shorter side 1080) is kept; 2160x3840 is not.
        #expect(Self.verticalReps.keepingBestVariant().video.first?.width == 1080)
    }

    @Test func withNoVariantsItIsUnchanged() {
        #expect(Self.single.keepingBestVariant().video.count == Self.single.video.count)
        #expect(Self.single.keepingBestVariant() == Self.single)
    }

    /// The copyable rule is the planner's: 10-bit H.264 (Hi10P) isn't one Apple decodes.
    @Test func aTenBitH264IsNotPreferredAsCopyable() {
        let info = Self.media([
            Self.video(.h264, 1920, 1080, bandwidth: 9_000_000, pixelFormat: "yuv420p10le", index: 0),
            Self.video(.h264, 1920, 1080, bandwidth: 5_000_000, index: 1),
        ])
        #expect(info.keepingBestVariant().video.map(\.ref.index) == [1])
    }

    /// Height comes before copyability: a 1080p that must be re-encoded still beats a copyable 720p.
    @Test func theTallestWithinTheCapBeatsACopyableCodec() {
        let info = Self.media([
            Self.video(.h264, 1280, 720, bandwidth: 2_500_000, index: 0),
            Self.video(.other("vp9"), 1920, 1080, bandwidth: 5_000_000, index: 1),
        ])
        #expect(info.keepingBestVariant().video.map(\.ref.index) == [1])
    }

    @Test func amongEqualsItKeepsTheHighestBandwidthAndItsAudio() {
        let info = Self.media([
            Self.video(.h264, 1920, 1080, bandwidth: 3_000_000, index: 0),
            Self.video(.h264, 1920, 1080, bandwidth: 5_000_000, index: 2),
        ], [
            Self.audio(bandwidth: 3_000_000, index: 1),
            Self.audio(bandwidth: 5_000_000, index: 3),
            Self.audio(bandwidth: nil, index: 4),          // a rendition the variants share
        ])
        let kept = info.keepingBestVariant()
        #expect(kept.video.map(\.ref.index) == [2])
        #expect(kept.audio.map(\.ref.index) == [3, 4])
    }
}
