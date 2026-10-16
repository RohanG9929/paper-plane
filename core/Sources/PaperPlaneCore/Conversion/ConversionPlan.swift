import Foundation

/// What the TV accepts over AirPlay. Receivers can't be queried, so this comes from
/// testing (the Sony test sets the default) plus user overrides in Settings.
public struct OutputProfile: Equatable, Sendable {
    /// Accepts AC3 / E-AC3 surround. When false, everything becomes stereo AAC.
    public var surround: Bool
    /// Accepts HDR10 / HLG HEVC. When false, HDR video is tone-mapped to SDR.
    public var hdr: Bool

    public init(surround: Bool, hdr: Bool) {
        self.surround = surround
        self.hdr = hdr
    }

    public static let `default` = OutputProfile(surround: true, hdr: true)
}

/// The user's track picks. nil means "use the default".
public struct TrackChoice: Equatable, Sendable {
    public var audio: TrackRef?

    public init(audio: TrackRef? = nil) {
        self.audio = audio
    }
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

/// Exactly what to do with each stream for one playback.
public struct ConversionPlan: Equatable, Sendable {
    public var video: TrackRef
    public var videoAction: VideoAction
    /// nil when the source has no audio.
    public var audio: TrackRef?
    public var audioAction: AudioAction?
}

public enum PlanError: Error, Equatable {
    /// Nothing to show: the file has no video (or only cover art).
    case noVideoTrack
    /// The chosen audio track doesn't exist in this media.
    case noSuchAudioTrack(TrackRef)
}
