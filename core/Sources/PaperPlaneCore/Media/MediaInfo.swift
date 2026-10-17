import Foundation

/// Points at one stream: which ffmpeg input it's in, and ffprobe's index within that input.
public struct TrackRef: Hashable, Sendable {
    /// Position of the ffmpeg input (0 unless a web video has separate audio).
    public var input: Int = 0
    /// ffprobe's stream index within that input.
    public var index: Int

    /// The value for ffmpeg's `-map`.
    public var mapSpecifier: String { "\(input):\(index)" }

    /// Names the track in pickers and menus, for audio and subtitles alike.
    public var id: String { "track-\(input)-\(index)" }
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
    /// In an HLS master playlist, the bandwidth of the variant it belongs to.
    public var variant: Int? = nil
}

extension VideoTrack {
    /// Pixel formats Apple's decoders handle for each codec we copy. 10-bit H.264 ("Hi10P") isn't one.
    private static let copyablePixelFormats: [VideoCodecName: Set<String>] = [
        .h264: ["yuv420p", "yuvj420p"],
        .hevc: ["yuv420p", "yuvj420p", "yuv420p10le"],
    ]

    /// Whether Apple can decode the track as it is, so it can be copied to the TV rather than
    /// re-encoded. The one rule behind both the conversion plan and the choice of a variant.
    var isCopyPlayable: Bool {
        guard let formats = Self.copyablePixelFormats[codec] else { return false }
        return formats.contains(pixelFormat ?? "yuv420p")
    }

    /// The smaller of width and height: 1080 for both 1920x1080 and 1080x1920.
    fileprivate var shorterSide: Int { min(width, height) }
}

public struct AudioTrack: Equatable, Sendable {
    public var ref: TrackRef
    public var codec: AudioCodecName
    public var channels: Int
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    /// In an HLS master playlist, the bandwidth of the variant it belongs to; nil for a rendition
    /// the variants share.
    public var variant: Int? = nil
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

    /// The tallest a variant may be, measured by its shorter side so portrait video counts the same.
    /// A variant over it loses to any that fit: a 4K representation isn't played, and re-encoded,
    /// when a 1080p one is on offer.
    private static let variantCap = 1080

    /// A master playlist (HLS, and DASH's representations) lists every variant's streams. This
    /// keeps the one to play and its audio, with any rendition the variants share, so ffmpeg
    /// fetches only that variant. Of those within `variantCap` it takes the tallest, a codec
    /// Paper Plane copies over one it re-encodes among equals, then the highest bandwidth; when
    /// every variant is over the cap it takes the smallest, to re-encode the least. Anything
    /// without variants is unchanged.
    func keepingBestVariant() -> MediaInfo {
        let variants = video.compactMap { track in track.variant.map { (track: track, bandwidth: $0) } }
        var candidates = variants.filter { $0.track.shorterSide <= Self.variantCap }
        if candidates.isEmpty, let smallest = variants.map(\.track.shorterSide).min() {
            candidates = variants.filter { $0.track.shorterSide == smallest }
        }
        let best = candidates.max {
            ($0.track.height, $0.track.isCopyPlayable ? 1 : 0, $0.bandwidth)
                < ($1.track.height, $1.track.isCopyPlayable ? 1 : 0, $1.bandwidth)
        }
        guard let best else { return self }
        var kept = self
        kept.video = [best.track]
        kept.audio = audio.filter { $0.variant == nil || $0.variant == best.bandwidth }
        return kept
    }
}
