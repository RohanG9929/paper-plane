import Foundation

/// What every ffmpeg run starts with: no banner, no stdin, no progress, errors only.
let ffmpegQuietArguments = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error"]

/// The names ffmpeg writes in a session folder and Paper Plane reads back.
enum HLSFileNames {
    static let mediaPlaylist = "index.m3u8"
    static let initSegment = "init.mp4"
    static let segmentPattern = "seg_%05d.m4s"
    /// The text subtitles to burn in, as WebVTT on the session's timeline.
    static let burnInSubtitles = "burn-in.vtt"
}

extension ResolvedInput {
    /// Every input's options, seek and `-i`, in order.
    func ffmpegInputArguments(seek: Double) -> [String] {
        inputs.flatMap { $0.ffmpegInputArguments(seek: seek) }
    }
}

extension ResolvedInput.Input {
    /// This input's options, a seek when `seek` > 0 (before `-i`, so ffmpeg jumps straight
    /// there), and `-i`.
    func ffmpegInputArguments(seek: Double) -> [String] {
        ffmpegOptions + (seek > 0 ? ["-ss", String(format: "%.3f", seek)] : []) + ["-i", ffmpegLocation]
    }
}

extension ConversionPlan {
    /// HLS segment length target, in seconds.
    public static let segmentSeconds = 6

    /// HDR → SDR tone mapping chain. Needs an ffmpeg built with zimg (`zscale`).
    static let toneMapFilter =
        "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,"
        + "zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

    /// The ffmpeg command line (without the executable) that writes this plan as an HLS
    /// event playlist (`index.m3u8`, `init.mp4`, `seg_00000.m4s`, …) into `output`,
    /// starting `start` seconds into the media.
    public func ffmpegArguments(input: ResolvedInput, start: Double, output: URL) -> [String] {
        var args = ffmpegQuietArguments + input.ffmpegInputArguments(seek: start)

        var filters = burnIn == .text ? ["subtitles=f=\(HLSFileNames.burnInSubtitles)"] : []
        if case .encode(let encode) = videoAction, encode.toneMapToSDR {
            // Tone-map before drawing subtitles, so they keep their own colours.
            filters.insert(Self.toneMapFilter, at: 0)
        }
        if case .picture(let subtitles) = burnIn {
            // The video's own filters first, the subtitles scaled from their own canvas (1080p
            // even on 4K discs) to the video's size, then laid on top.
            var graph = ""
            var base = "[\(video.mapSpecifier)]"
            if !filters.isEmpty {
                graph += base + filters.joined(separator: ",") + "[base];"
                base = "[base]"
            }
            var overlay = "[\(subtitles.mapSpecifier)]"
            if let videoSize {
                graph += overlay + "scale=\(videoSize.width):\(videoSize.height)[subtitles];"
                overlay = "[subtitles]"
            }
            args += ["-filter_complex", graph + base + overlay + "overlay=eof_action=pass[video]", "-map", "[video]"]
        } else {
            args += ["-map", video.mapSpecifier]
            if !filters.isEmpty {
                args += ["-vf", filters.joined(separator: ",")]
            }
        }
        if let audio {
            args += ["-map", audio.mapSpecifier]
        } else {
            args += ["-an"]
        }
        args += ["-map_chapters", "-1"]
        args += videoArguments()
        args += audioArguments()
        args += ["-max_muxing_queue_size", "4096"]
        args += [
            "-f", "hls",
            "-hls_time", String(Self.segmentSeconds),
            "-hls_playlist_type", "event",
            "-hls_segment_type", "fmp4",
            "-hls_fmp4_init_filename", HLSFileNames.initSegment,
            "-hls_segment_filename", output.appendingPathComponent(HLSFileNames.segmentPattern).path,
            "-hls_flags", "independent_segments+temp_file",
            "-start_number", "0",
            output.appendingPathComponent(HLSFileNames.mediaPlaylist).path,
        ]
        return args
    }

    private func videoArguments() -> [String] {
        switch videoAction {
        case .copy(.hevc):
            return ["-c:v", "copy", "-tag:v", "hvc1"]
        case .copy:
            return ["-c:v", "copy"]
        case .encode(let encode):
            var args: [String]
            switch (encode.encoder, encode.keepHDR) {
            case (.h264, _):
                args = ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p"]
            case (.hevc, nil):
                args = ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-profile:v", "main", "-pix_fmt", "yuv420p"]
            case (.hevc, let hdr?):
                args = ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-profile:v", "main10", "-pix_fmt", "p010le",
                        "-color_primaries", "bt2020", "-colorspace", "bt2020nc",
                        "-color_trc", hdr == .pq ? "smpte2084" : "arib-std-b67"]
            }
            args += [
                "-allow_sw", "1",
                "-b:v", String(encode.bitrate),
                "-force_key_frames", "expr:gte(t,n_forced*\(Self.segmentSeconds))",
            ]
            return args
        }
    }

    private func audioArguments() -> [String] {
        switch audioAction {
        case nil: return []
        // AAC from MPEG-TS has ADTS headers fMP4 can't hold; the filter passes other AAC through.
        case .copy(.aac): return ["-c:a", "copy", "-bsf:a", "aac_adtstoasc"]
        case .copy: return ["-c:a", "copy"]
        case .eac3Surround: return ["-c:a", "eac3", "-b:a", "640k", "-ac", "6"]
        case .aacStereo: return ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        }
    }
}
