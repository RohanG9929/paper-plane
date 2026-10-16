import Foundation
import Testing
@testable import PaperPlaneCore

struct FFmpegArgumentsTests {
    static let output = URL(fileURLWithPath: "/tmp/session")
    static let movie = ResolvedInput.file(URL(fileURLWithPath: "/Movies/Movie: Part 1 (Director's Cut) é.mkv"))

    static let hlsTail = [
        "-max_muxing_queue_size", "4096",
        "-f", "hls", "-hls_time", "6", "-hls_playlist_type", "event", "-hls_segment_type", "fmp4",
        "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", "/tmp/session/seg_%05d.m4s",
        "-hls_flags", "independent_segments+temp_file", "-start_number", "0", "/tmp/session/index.m3u8",
    ]

    static func plan(_ video: VideoAction, audio: AudioAction? = .copy) -> ConversionPlan {
        ConversionPlan(video: TrackRef(index: 0), videoAction: video,
                       audio: audio == nil ? nil : TrackRef(index: 2), audioAction: audio)
    }

    @Test func copyPlanFromTheStart() {
        let args = Self.plan(.copy(.h264)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args == [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-i", "/Movies/Movie: Part 1 (Director's Cut) é.mkv",
            "-map", "0:0", "-map", "0:2", "-map_chapters", "-1",
            "-c:v", "copy", "-c:a", "copy",
        ] + Self.hlsTail)
    }

    @Test func aTrimDropsEverythingBeforeItAsAnOutputOption() {
        // After the input, so ffmpeg drops packets (both tracks) instead of seeking the input.
        let args = Self.plan(.copy(.h264)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output,
                                                           trim: 2.432833)
        #expect(args == [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-i", "/Movies/Movie: Part 1 (Director's Cut) é.mkv",
            "-map", "0:0", "-map", "0:2", "-map_chapters", "-1", "-ss", "2.432833",
            "-c:v", "copy", "-c:a", "copy",
        ] + Self.hlsTail)
    }

    @Test func startOffsetGoesBeforeEachInput() {
        let input = ResolvedInput(inputs: [
            .init(url: URL(string: "https://cdn.example.com/video.mp4")!, headers: ["Cookie": "a=1"]),
            .init(url: URL(string: "https://cdn.example.com/audio.m4a")!, headers: ["Cookie": "a=1"]),
        ], title: "Clip")
        let plan = ConversionPlan(video: TrackRef(input: 0, index: 0), videoAction: .copy(.h264),
                                  audio: TrackRef(input: 1, index: 0), audioAction: .copy)
        let args = plan.ffmpegArguments(input: input, start: 754.25, output: Self.output)
        #expect(Array(args.prefix(20)) == [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-headers", "Cookie: a=1\r\n", "-ss", "754.250", "-i", "https://cdn.example.com/video.mp4",
            "-headers", "Cookie: a=1\r\n", "-ss", "754.250", "-i", "https://cdn.example.com/audio.m4a",
            "-map", "0:0", "-map",
        ])
        #expect(args[20] == "1:0")
    }

    @Test func hevcCopyIsTaggedForApple() {
        let args = Self.plan(.copy(.hevc)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains(subsequence: ["-c:v", "copy", "-tag:v", "hvc1"]))
    }

    @Test func h264EncodeUsesVideoToolboxWithSegmentAlignedKeyframes() {
        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false, bitrate: 8_000_000)
        let args = Self.plan(.encode(encode)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains(subsequence: [
            "-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p",
            "-allow_sw", "1", "-b:v", "8000000", "-force_key_frames", "expr:gte(t,n_forced*6)",
        ]))
        #expect(!args.contains("-vf"))
    }

    @Test func hdrEncodeKeepsTenBitAndColorTags() {
        let encode = VideoEncode(encoder: .hevc, keepHDR: .pq, toneMapToSDR: false, bitrate: 16_000_000)
        let args = Self.plan(.encode(encode)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains(subsequence: [
            "-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-profile:v", "main10", "-pix_fmt", "p010le",
            "-color_primaries", "bt2020", "-colorspace", "bt2020nc", "-color_trc", "smpte2084",
        ]))
    }

    @Test func toneMappingAddsTheFilterChain() {
        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: true, bitrate: 8_000_000)
        let args = Self.plan(.encode(encode)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains(subsequence: ["-vf", ConversionPlan.toneMapFilter]))
    }

    @Test func audioConversions() {
        let surround = Self.plan(.copy(.h264), audio: .eac3Surround)
            .ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(surround.contains(subsequence: ["-c:a", "eac3", "-b:a", "640k", "-ac", "6"]))

        let stereo = Self.plan(.copy(.h264), audio: .aacStereo)
            .ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(stereo.contains(subsequence: ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]))
    }

    @Test func pictureSubtitlesAreOverlaid() {
        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: true, bitrate: 8_000_000)
        var plan = Self.plan(.encode(encode))
        plan.burnIn = .picture(TrackRef(index: 4))
        let args = plan.ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        // The video is tone-mapped first, so the subtitles keep their own colours.
        #expect(args.contains(subsequence: [
            "-filter_complex", "[0:0]" + ConversionPlan.toneMapFilter + "[base];[base][0:4]overlay=eof_action=pass[video]",
            "-map", "[video]", "-map", "0:2",
        ]))
        #expect(!args.contains("-vf"))
        #expect(!args.contains("0:0"))

        plan.videoAction = .encode(VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false, bitrate: 8_000_000))
        #expect(plan.ffmpegArguments(input: Self.movie, start: 0, output: Self.output).contains(subsequence: [
            "-filter_complex", "[0:0][0:4]overlay=eof_action=pass[video]",
        ]))
    }

    /// Blu-ray subtitles are drawn on a canvas of their own (1080p even for 4K discs); scaled to
    /// the video, they land where they belong on any size.
    @Test func pictureSubtitlesAreScaledToTheVideo() {
        let encode = VideoEncode(encoder: .hevc, keepHDR: nil, toneMapToSDR: false, bitrate: 16_000_000)
        var plan = Self.plan(.encode(encode))
        plan.burnIn = .picture(TrackRef(index: 4))
        plan.videoSize = VideoSize(width: 3840, height: 2160)
        #expect(plan.ffmpegArguments(input: Self.movie, start: 0, output: Self.output).contains(subsequence: [
            "-filter_complex", "[0:4]scale=3840:2160[subtitles];[0:0][subtitles]overlay=eof_action=pass[video]",
        ]))
    }

    @Test func textSubtitlesAreDrawnAfterToneMapping() {
        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: true, bitrate: 8_000_000)
        var plan = Self.plan(.encode(encode))
        plan.burnIn = .text
        let args = plan.ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains(subsequence: ["-vf", ConversionPlan.toneMapFilter + ",subtitles=f=burn-in.vtt"]))
    }

    @Test func textSubtitlesAreDrawnFromTheSessionsWebVTT() {
        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false, bitrate: 8_000_000)
        var plan = Self.plan(.encode(encode))
        plan.burnIn = .text
        let args = plan.ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        // A plain relative name: ffmpeg runs in the session folder, so no path needs escaping.
        #expect(args.contains(subsequence: ["-vf", "subtitles=f=burn-in.vtt"]))
        #expect(args.contains(subsequence: ["-map", "0:0"]))
    }

    @Test func noAudioDisablesAudio() {
        let args = Self.plan(.copy(.h264), audio: nil).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains("-an"))
        #expect(!args.contains("-c:a"))
        #expect(args.filter { $0 == "-map" }.count == 1)
    }
}

extension Array where Element: Equatable {
    /// True if `subsequence` appears contiguously in this array.
    func contains(subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return subsequence.isEmpty }
        return (0...(count - subsequence.count)).contains { start in
            Array(self[start..<(start + subsequence.count)]) == subsequence
        }
    }
}
