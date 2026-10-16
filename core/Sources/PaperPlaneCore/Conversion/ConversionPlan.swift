import Foundation

/// What the TV accepts over AirPlay. Receivers can't be queried, so the default comes from
/// the Sony test (docs/sony-test-results.md) and users can override it in Settings.
public struct OutputProfile: Equatable, Sendable {
    /// Accepts AC3 / E-AC3 surround. When false, everything becomes stereo AAC.
    public var surround: Bool
    /// Accepts HDR10 / HLG HEVC. When false, HDR video is tone-mapped to SDR.
    public var hdr: Bool

    public init(surround: Bool, hdr: Bool) {
        self.surround = surround
        self.hdr = hdr
    }

    public static let `default` = OutputProfile(surround: false, hdr: true)
}

/// The user's track picks. nil means "use the default".
public struct TrackChoice: Equatable, Sendable {
    public var audio: TrackRef?
    /// Subtitles drawn into the picture, which means converting the video.
    public var burnIn: BurnIn?

    public init(audio: TrackRef? = nil, burnIn: BurnIn? = nil) {
        self.audio = audio
        self.burnIn = burnIn
    }
}

/// Subtitles burned into the video (spec §4.1).
public enum BurnIn: Equatable, Sendable {
    /// A picture track (PGS, VobSub, DVB), overlaid straight from the file.
    case picture(TrackRef)
    /// A text track, drawn by libass from the session's `burn-in.vtt` (the "Always burn in
    /// subtitles" setting, for TVs that don't show subtitle tracks).
    case text
}

public enum VideoEncoder: Equatable, Sendable {
    case h264
    case hevc
}

public struct VideoEncode: Equatable, Sendable {
    public var encoder: VideoEncoder
    /// Non-nil keeps HDR: 10-bit HEVC tagged with this transfer function.
    public var keepHDR: HDRFormat?
    public var toneMapToSDR: Bool
    /// Target bitrate in bits per second.
    public var bitrate: Int
}

public enum VideoAction: Equatable, Sendable {
    case copy(VideoCodecName)
    case encode(VideoEncode)
}

public enum AudioAction: Equatable, Sendable {
    case copy
    /// E-AC3 5.1 at 640 kb/s (7.1 sources are downmixed).
    case eac3Surround
    /// AAC stereo at 192 kb/s.
    case aacStereo
}

/// The brightness range of the output video, for the HLS master playlist's `VIDEO-RANGE`.
public enum VideoRange: String, Equatable, Sendable {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"

    init(_ hdr: HDRFormat?) {
        switch hdr {
        case .pq: self = .pq
        case .hlg: self = .hlg
        case nil: self = .sdr
        }
    }
}

/// Exactly what to do with each stream for one playback.
public struct ConversionPlan: Equatable, Sendable {
    public var video: TrackRef
    public var videoAction: VideoAction
    /// nil when the source has no audio.
    public var audio: TrackRef?
    public var audioAction: AudioAction?
    /// What the converted video is: HDR stays HDR unless it's tone-mapped.
    public var videoRange: VideoRange = .sdr
    /// The video's frames per second, which conversion keeps. nil when unknown.
    public var frameRate: Double? = nil
    /// Subtitles drawn into the picture. Only with `.encode`.
    public var burnIn: BurnIn? = nil
    /// The video's size, for scaling picture subtitles to it. nil when unknown.
    public var videoSize: VideoSize? = nil
}

public struct VideoSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum PlanError: Error, Equatable {
    /// Nothing to show: the file has no video (or only cover art).
    case noVideoTrack
    /// The chosen audio track doesn't exist in this media.
    case noSuchAudioTrack(TrackRef)
}
