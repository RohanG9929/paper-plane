import Foundation

/// Decides what to copy and what to convert so the TV can play the media (spec §4.1).
public enum ConversionPlanner {
    public static func plan(
        _ media: MediaInfo,
        choice: TrackChoice = TrackChoice(),
        profile: OutputProfile = .default
    ) throws -> ConversionPlan {
        guard let video = media.video.first else { throw PlanError.noVideoTrack }
        let audio = try pickAudio(media.audio, choice: choice.audio)
        let action = videoAction(for: video, profile: profile, burningIn: choice.burnIn != nil)
        return ConversionPlan(
            video: video.ref,
            videoAction: action,
            audio: audio?.ref,
            audioAction: audio.map { audioAction(for: $0, profile: profile) },
            videoRange: videoRange(of: video, after: action),
            frameRate: video.frameRate,
            burnIn: choice.burnIn,
            videoSize: video.width > 0 && video.height > 0 ? VideoSize(width: video.width, height: video.height) : nil)
    }

    // MARK: - Video

    /// Copy what Apple can decode, unless subtitles are drawn into it; otherwise convert.
    static func videoAction(for track: VideoTrack, profile: OutputProfile, burningIn: Bool = false) -> VideoAction {
        let needsToneMap = track.hdr != nil && !profile.hdr
        if !burningIn, track.isCopyPlayable, !needsToneMap {
            return .copy(track.codec)
        }
        let keepHDR = profile.hdr ? track.hdr : nil
        let encoder: VideoEncoder = (track.height > 1080 || keepHDR != nil) ? .hevc : .h264
        return .encode(VideoEncode(
            encoder: encoder,
            keepHDR: keepHDR,
            toneMapToSDR: needsToneMap,
            bitrate: bitrate(height: track.height, encoder: encoder)))
    }

    static func videoRange(of track: VideoTrack, after action: VideoAction) -> VideoRange {
        switch action {
        case .copy: VideoRange(track.hdr)
        case .encode(let encode): VideoRange(encode.keepHDR)
        }
    }

    static func bitrate(height: Int, encoder: VideoEncoder) -> Int {
        switch (encoder, height) {
        case (.h264, ...720): return 5_000_000
        case (.h264, ...1080): return 8_000_000
        case (.h264, _): return 20_000_000
        case (.hevc, ...720): return 4_000_000
        case (.hevc, ...1080): return 6_000_000
        case (.hevc, _): return 16_000_000
        }
    }

    // MARK: - Audio

    private static func pickAudio(_ tracks: [AudioTrack], choice: TrackRef?) throws -> AudioTrack? {
        if let choice {
            guard let chosen = tracks.first(where: { $0.ref == choice }) else {
                throw PlanError.noSuchAudioTrack(choice)
            }
            return chosen
        }
        return tracks.first(where: \.isDefault) ?? tracks.first
    }

    static func audioAction(for track: AudioTrack, profile: OutputProfile) -> AudioAction {
        if profile.surround {
            switch track.codec {
            case .aac, .ac3, .eac3: return .copy(track.codec)
            case .other: return track.channels > 2 ? .eac3Surround : .aacStereo
            }
        }
        return track.codec == .aac && track.channels <= 2 ? .copy(.aac) : .aacStereo
    }
}
