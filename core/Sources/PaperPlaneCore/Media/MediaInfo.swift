import Foundation

/// Points at one stream: which ffmpeg input it's in, and ffprobe's index within that input.
public struct TrackRef: Hashable, Sendable {
    /// Position of the ffmpeg input (0 unless a web video has separate audio).
    public var input: Int = 0
    /// ffprobe's stream index within that input.
    public var index: Int

    /// The value for ffmpeg's `-map`.
    public var mapSpecifier: String { "\(input):\(index)" }
}

public enum VideoCodecName: Hashable, Sendable {
    case h264
    case hevc
    case other(String)

    public init(ffprobeName: String) {
        switch ffprobeName {
        case "h264": self = .h264
        case "hevc": self = .hevc
        default: self = .other(ffprobeName)
        }
    }
}

public enum HDRFormat: Equatable, Sendable {
    /// HDR10 / Dolby Vision base layer (SMPTE ST 2084).
    case pq
    /// Hybrid Log-Gamma.
    case hlg

    public init?(colorTransfer: String?) {
        switch colorTransfer ?? "" {
        case "smpte2084": self = .pq
        case "arib-std-b67": self = .hlg
        default: return nil
        }
    }
}

public enum AudioCodecName: Equatable, Sendable {
    case aac
    case ac3
    case eac3
    case other(String)

    public init(ffprobeName: String) {
        switch ffprobeName {
        case "aac": self = .aac
        case "ac3": self = .ac3
        case "eac3": self = .eac3
        default: self = .other(ffprobeName)
        }
    }
}

public enum SubtitleKind: Equatable, Sendable {
    case text
    case picture
    case unsupported

    public init(ffprobeName: String) {
        switch ffprobeName {
        case "subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text": self = .text
        case "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub": self = .picture
        default: self = .unsupported
        }
    }
}

public struct VideoTrack: Equatable, Sendable {
    public var ref: TrackRef
    public var codec: VideoCodecName
    public var width: Int
    public var height: Int
    /// ffprobe's `pix_fmt`, e.g. `yuv420p` or `yuv420p10le`.
    public var pixelFormat: String?
    public var hdr: HDRFormat?
    /// Frames per second, from ffprobe's `avg_frame_rate` (or `r_frame_rate`). nil when unknown.
    public var frameRate: Double? = nil
}

public struct AudioTrack: Equatable, Sendable {
    public var ref: TrackRef
    public var codec: AudioCodecName
    public var channels: Int
    public var language: String?
    public var title: String?
    public var isDefault: Bool
}

public struct SubtitleTrack: Equatable, Sendable {
    public var ref: TrackRef
    public var codecName: String
    public var kind: SubtitleKind
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    public var isForced: Bool
}

/// What Paper Plane knows about a video after probing it.
public struct MediaInfo: Equatable, Sendable {
    /// Seconds, or nil when unknown (live streams).
    public var duration: Double?
    /// Real video tracks only. Cover art (attached pictures) is left out.
    public var video: [VideoTrack]
    public var audio: [AudioTrack]
    public var subtitles: [SubtitleTrack]

    /// Combines probes of several inputs (for example separate web video and audio streams).
    static func merging(_ parts: [MediaInfo]) -> MediaInfo {
        MediaInfo(
            duration: parts.lazy.compactMap(\.duration).first,
            video: parts.flatMap(\.video),
            audio: parts.flatMap(\.audio),
            subtitles: parts.flatMap(\.subtitles))
    }
}
