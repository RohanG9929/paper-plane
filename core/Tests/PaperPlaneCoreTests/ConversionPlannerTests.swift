import Foundation
import Testing
@testable import PaperPlaneCore

struct ConversionPlannerTests {
    // MARK: - Builders

    static func video(_ codec: VideoCodecName, height: Int = 1080, pixelFormat: String = "yuv420p",
                      hdr: HDRFormat? = nil, index: Int = 0) -> VideoTrack {
        VideoTrack(ref: TrackRef(index: index), codec: codec, width: height * 16 / 9, height: height,
                   pixelFormat: pixelFormat, hdr: hdr)
    }

    static func audio(_ codec: AudioCodecName, channels: Int = 2, isDefault: Bool = false, index: Int = 1) -> AudioTrack {
        AudioTrack(ref: TrackRef(index: index), codec: codec, channels: channels, language: nil, title: nil,
                   isDefault: isDefault)
    }

    static func media(_ video: [VideoTrack], _ audio: [AudioTrack]) -> MediaInfo {
        MediaInfo(duration: 60, video: video, audio: audio, subtitles: [])
    }

    static let noSurroundNoHDR = OutputProfile(surround: false, hdr: false)

    // MARK: - Video

    @Test func copiesH264AndHEVC() throws {
        #expect(ConversionPlanner.videoAction(for: Self.video(.h264), profile: .default) == .copy(.h264))
        #expect(ConversionPlanner.videoAction(for: Self.video(.hevc, height: 2160), profile: .default) == .copy(.hevc))
    }

    @Test func copiesHDRWhenTheTVAcceptsIt() {
        let track = Self.video(.hevc, height: 2160, pixelFormat: "yuv420p10le", hdr: .pq)
        #expect(ConversionPlanner.videoAction(for: track, profile: .default) == .copy(.hevc))
    }

    @Test func reencodesOtherCodecsToH264UpTo1080p() {
        for codec in [VideoCodecName.other("vp9"), .other("av1"), .other("mpeg2video"), .other("vc1")] {
            let action = ConversionPlanner.videoAction(for: Self.video(codec, height: 1080), profile: .default)
            #expect(action == .encode(VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false,
                                                  bitrate: 8_000_000)))
        }
    }

    @Test func reencodesLargeSourcesToHEVC() {
        let action = ConversionPlanner.videoAction(for: Self.video(.other("vp9"), height: 2160), profile: .default)
        #expect(action == .encode(VideoEncode(encoder: .hevc, keepHDR: nil, toneMapToSDR: false,
                                              bitrate: 16_000_000)))
    }

    @Test func reencodesTenBitH264BecauseAppleCannotDecodeIt() {
        let track = Self.video(.h264, height: 720, pixelFormat: "yuv420p10le")
        #expect(ConversionPlanner.videoAction(for: track, profile: .default)
            == .encode(VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false, bitrate: 5_000_000)))
    }

    @Test func reencodesHDRNonHEVCKeepingHDR() {
        let track = Self.video(.other("av1"), height: 2160, pixelFormat: "yuv420p10le", hdr: .hlg)
        #expect(ConversionPlanner.videoAction(for: track, profile: .default)
            == .encode(VideoEncode(encoder: .hevc, keepHDR: .hlg, toneMapToSDR: false, bitrate: 16_000_000)))
    }

    @Test func toneMapsHDRWhenTheTVRejectsIt() {
        let track = Self.video(.hevc, height: 1080, pixelFormat: "yuv420p10le", hdr: .pq)
        #expect(ConversionPlanner.videoAction(for: track, profile: Self.noSurroundNoHDR)
            == .encode(VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: true, bitrate: 8_000_000)))
    }

    @Test func noVideoTrackThrows() {
        #expect(throws: PlanError.noVideoTrack) {
            try ConversionPlanner.plan(Self.media([], [Self.audio(.aac)]))
        }
    }

    // MARK: - Audio

    @Test(arguments: [
        (AudioCodecName.aac, 2, AudioAction.copy),
        (.aac, 6, .copy),
        (.ac3, 6, .copy),
        (.eac3, 6, .copy),
        (.other("dts"), 6, .eac3Surround),
        (.other("truehd"), 8, .eac3Surround),
        (.other("flac"), 8, .eac3Surround),
        (.other("opus"), 2, .aacStereo),
        (.other("mp3"), 1, .aacStereo),
    ])
    func audioWithSurroundTV(codec: AudioCodecName, channels: Int, expected: AudioAction) {
        let action = ConversionPlanner.audioAction(for: Self.audio(codec, channels: channels), profile: .default)
        #expect(action == expected)
    }

    @Test(arguments: [
        (AudioCodecName.aac, 2, AudioAction.copy),
        (.aac, 6, .aacStereo),
        (.ac3, 6, .aacStereo),
        (.eac3, 2, .aacStereo),
        (.other("dts"), 6, .aacStereo),
    ])
    func audioWithStereoOnlyTV(codec: AudioCodecName, channels: Int, expected: AudioAction) {
        let action = ConversionPlanner.audioAction(for: Self.audio(codec, channels: channels),
                                                   profile: Self.noSurroundNoHDR)
        #expect(action == expected)
    }

    @Test func picksTheDefaultAudioTrackThenTheFirst() throws {
        let english = Self.audio(.aac, index: 1)
        let japanese = Self.audio(.ac3, channels: 6, isDefault: true, index: 2)
        let flagged = try ConversionPlanner.plan(Self.media([Self.video(.h264)], [english, japanese]))
        #expect(flagged.audio == japanese.ref)
        #expect(flagged.audioAction == .copy)

        var unflagged = japanese
        unflagged.isDefault = false
        let first = try ConversionPlanner.plan(Self.media([Self.video(.h264)], [english, unflagged]))
        #expect(first.audio == english.ref)
    }

    @Test func honoursAnExplicitAudioChoice() throws {
        let english = Self.audio(.aac, index: 1)
        let japanese = Self.audio(.ac3, channels: 6, isDefault: true, index: 2)
        let plan = try ConversionPlanner.plan(Self.media([Self.video(.h264)], [english, japanese]),
                                              choice: TrackChoice(audio: english.ref))
        #expect(plan.audio == english.ref)
    }

    @Test func unknownAudioChoiceThrows() {
        let missing = TrackRef(index: 9)
        #expect(throws: PlanError.noSuchAudioTrack(missing)) {
            try ConversionPlanner.plan(Self.media([Self.video(.h264)], [Self.audio(.aac)]),
                                       choice: TrackChoice(audio: missing))
        }
    }

    @Test func videoWithoutAudioHasNoAudioPlan() throws {
        let plan = try ConversionPlanner.plan(Self.media([Self.video(.h264)], []))
        #expect(plan.audio == nil)
        #expect(plan.audioAction == nil)
    }
}
