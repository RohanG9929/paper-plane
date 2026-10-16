import Foundation

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
        var args = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error"]
        for item in input.inputs {
            args += item.ffmpegOptions
            if start > 0 {
                args += ["-ss", String(format: "%.3f", start)]
            }
            args += ["-i", item.ffmpegLocation]
        }

        args += ["-map", video.mapSpecifier]
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
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_segment_filename", output.appendingPathComponent("seg_%05d.m4s").path,
            "-hls_flags", "independent_segments+temp_file",
            "-start_number", "0",
            output.appendingPathComponent("index.m3u8").path,
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
            if encode.toneMapToSDR {
                args += ["-vf", Self.toneMapFilter]
            }
            return args
        }
    }

    private func audioArguments() -> [String] {
        switch audioAction {
        case nil: return []
        case .copy: return ["-c:a", "copy"]
        case .eac3Surround: return ["-c:a", "eac3", "-b:a", "640k", "-ac", "6"]
        case .aacStereo: return ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        }
    }
}
