import Foundation
import Testing
@testable import PaperPlaneCore

struct FFprobeParserTests {
    /// Trimmed real-world shape: cover art first, two audio tracks, text + picture subtitles, a font attachment.
    static let movieJSON = """
    {
      "streams": [
        {"index": 0, "codec_name": "png", "codec_type": "video", "width": 300, "height": 300, "pix_fmt": "rgb24",
         "disposition": {"default": 0, "forced": 0, "attached_pic": 1}},
        {"index": 1, "codec_name": "h264", "codec_type": "video", "width": 1920, "height": 1080, "pix_fmt": "yuv420p",
         "color_transfer": "bt709", "disposition": {"default": 1, "forced": 0, "attached_pic": 0}},
        {"index": 2, "codec_name": "ac3", "codec_type": "audio", "channels": 6,
         "disposition": {"default": 0, "forced": 0, "attached_pic": 0}, "tags": {"language": "eng", "title": "Surround"}},
        {"index": 3, "codec_name": "aac", "codec_type": "audio", "channels": 2,
         "disposition": {"default": 1, "forced": 0, "attached_pic": 0}, "tags": {"language": "jpn"}},
        {"index": 4, "codec_name": "subrip", "codec_type": "subtitle",
         "disposition": {"default": 0, "forced": 1, "attached_pic": 0}, "tags": {"language": "und"}},
        {"index": 5, "codec_name": "hdmv_pgs_subtitle", "codec_type": "subtitle",
         "disposition": {"default": 0, "forced": 0, "attached_pic": 0}, "tags": {"LANGUAGE": "fre"}},
        {"index": 6, "codec_name": "ttf", "codec_type": "attachment", "tags": {"filename": "font.ttf"}}
      ],
      "format": {"filename": "movie.mkv", "duration": "5423.104000"}
    }
    """

    /// An HLS master playlist (ffprobe's real output): every variant's streams, each tagged with
    /// its variant's bandwidth, the smallest listed first; an audio rendition shared by both
    /// variants has no tag.
    static let masterJSON = """
    {
      "streams": [
        {"index": 0, "codec_name": "h264", "codec_type": "video", "width": 320, "height": 180, "tags": {"variant_bitrate": "400000"}},
        {"index": 1, "codec_name": "aac", "codec_type": "audio", "channels": 2, "tags": {"variant_bitrate": "400000"}},
        {"index": 2, "codec_name": "h264", "codec_type": "video", "width": 1280, "height": 720, "tags": {"variant_bitrate": "3000000"}},
        {"index": 3, "codec_name": "aac", "codec_type": "audio", "channels": 2, "tags": {"variant_bitrate": "3000000"}},
        {"index": 4, "codec_name": "aac", "codec_type": "audio", "channels": 2, "tags": {"language": "fre"}},
        {"index": 5, "codec_name": "h264", "codec_type": "video", "width": 1280, "height": 720, "tags": {"variant_bitrate": "2000000"}}
      ],
      "format": {"duration": "10.0"}
    }
    """

    /// Paper Plane plays the best variant: the tallest, the highest bandwidth among equals, with
    /// its own audio and any shared rendition; the rest ffmpeg needn't download.
    @Test func keepsTheBestVariantOfAMasterPlaylist() throws {
        let info = try FFprobeParser.parse(Data(Self.masterJSON.utf8)).keepingBestVariant()
        #expect(info.video.map(\.ref.index) == [2])
        #expect(info.audio.map(\.ref.index) == [3, 4])
        #expect(info.video.first?.variant == 3_000_000)
        let file = try FFprobeParser.parse(Data(Self.movieJSON.utf8))
        #expect(file.keepingBestVariant() == file) // a file has no variants
    }

    /// ffprobe's real output for a DASH manifest of CENC-encrypted fMP4 with no key to give it: it
    /// reads the tracks, and marks each packet it can't decrypt with "Encryption info" side data.
    static let encryptedJSON = """
        {"packets": [{"codec_type": "video", "stream_index": 0, "size": "7742",
                      "side_data_list": [{"side_data_type": "Encryption info"}]}],
         "streams": [{"index": 0, "codec_type": "video", "codec_name": "h264", "width": 1280, "height": 720}],
         "format": {"duration": "10.000000"}}
        """

    /// Samples nothing can decrypt would be copied to the TV as noise: better a plain failure.
    @Test func protectedStreamsAreRefused() throws {
        #expect(throws: MediaProbeError.protectedContent) {
            try FFprobeParser.parse(Data(Self.encryptedJSON.utf8))
        }
        let clear = """
            {"packets": [{"codec_type": "video", "stream_index": 0, "side_data_list": [{"side_data_type": "Skip Samples"}]},
                         {"codec_type": "audio", "stream_index": 1}],
             "streams": [{"index": 0, "codec_type": "video", "codec_name": "h264", "width": 1280, "height": 720}]}
            """
        #expect(try FFprobeParser.parse(Data(clear.utf8)).video.count == 1)
    }

    @Test func readsFrameRates() throws {
        let json = """
            {"streams": [
              {"index": 0, "codec_type": "video", "codec_name": "h264", "avg_frame_rate": "24000/1001", "r_frame_rate": "24/1"},
              {"index": 1, "codec_type": "video", "codec_name": "h264", "avg_frame_rate": "0/0", "r_frame_rate": "25/1"},
              {"index": 2, "codec_type": "video", "codec_name": "h264", "avg_frame_rate": "0/0", "r_frame_rate": "0/0"}
            ]}
            """
        let rates = try FFprobeParser.parse(Data(json.utf8)).video.map(\.frameRate)
        #expect(rates == [24000.0 / 1001, 25, nil])
    }

    @Test func parsesTracksAndSkipsCoverArt() throws {
        let info = try FFprobeParser.parse(Data(Self.movieJSON.utf8))
        #expect(info.duration == 5423.104)
        #expect(info.video == [
            VideoTrack(ref: TrackRef(index: 1), codec: .h264, width: 1920, height: 1080, pixelFormat: "yuv420p", hdr: nil),
        ])
        #expect(info.audio == [
            AudioTrack(ref: TrackRef(index: 2), codec: .ac3, channels: 6, language: "eng", title: "Surround", isDefault: false),
            AudioTrack(ref: TrackRef(index: 3), codec: .aac, channels: 2, language: "jpn", title: nil, isDefault: true),
        ])
        #expect(info.subtitles == [
            SubtitleTrack(ref: TrackRef(index: 4), codecName: "subrip", kind: .text, language: nil, title: nil,
                          isDefault: false, isForced: true),
            SubtitleTrack(ref: TrackRef(index: 5), codecName: "hdmv_pgs_subtitle", kind: .picture, language: "fre",
                          title: nil, isDefault: false, isForced: false),
        ])
    }

    @Test func recordsInputPositionInRefs() throws {
        let info = try FFprobeParser.parse(Data(Self.movieJSON.utf8), input: 1)
        #expect(info.video.first?.ref == TrackRef(input: 1, index: 1))
        #expect(info.video.first?.ref.mapSpecifier == "1:1")
    }

    @Test func detectsHDR() throws {
        let json = """
        {"streams": [
          {"index": 0, "codec_name": "hevc", "codec_type": "video", "width": 3840, "height": 2160,
           "pix_fmt": "yuv420p10le", "color_transfer": "smpte2084"},
          {"index": 1, "codec_name": "hevc", "codec_type": "video", "width": 3840, "height": 2160,
           "pix_fmt": "yuv420p10le", "color_transfer": "arib-std-b67"}
        ], "format": {"duration": "60.0"}}
        """
        let info = try FFprobeParser.parse(Data(json.utf8))
        #expect(info.video.map(\.hdr) == [.pq, .hlg])
        #expect(info.video.first?.codec == .hevc)
    }

    @Test func missingOrInvalidDurationIsNil() throws {
        let live = try FFprobeParser.parse(Data(#"{"streams": [], "format": {"duration": "N/A"}}"#.utf8))
        #expect(live.duration == nil)
        let none = try FFprobeParser.parse(Data(#"{"streams": []}"#.utf8))
        #expect(none.duration == nil)
    }

    @Test func unknownCodecsAreKeptAsOther() throws {
        let json = """
        {"streams": [
          {"index": 0, "codec_name": "vp9", "codec_type": "video", "width": 1280, "height": 720},
          {"index": 1, "codec_name": "dts", "codec_type": "audio", "channels": 6},
          {"index": 2, "codec_name": "eia_608", "codec_type": "subtitle"}
        ]}
        """
        let info = try FFprobeParser.parse(Data(json.utf8))
        #expect(info.video.first?.codec == .other("vp9"))
        #expect(info.audio.first?.codec == .other("dts"))
        #expect(info.subtitles.first?.kind == .unsupported)
    }

    @Test func garbageThrowsUnreadableOutput() {
        #expect(throws: MediaProbeError.unreadableOutput) {
            try FFprobeParser.parse(Data("not json".utf8))
        }
    }

    @Test func mergingCombinesInputsAndTakesFirstKnownDuration() {
        let video = MediaInfo(duration: nil, video: [
            VideoTrack(ref: TrackRef(input: 0, index: 0), codec: .h264, width: 1920, height: 1080,
                       pixelFormat: "yuv420p", hdr: nil),
        ], audio: [], subtitles: [])
        let audio = MediaInfo(duration: 212.5, video: [], audio: [
            AudioTrack(ref: TrackRef(input: 1, index: 0), codec: .aac, channels: 2, language: nil, title: nil,
                       isDefault: true),
        ], subtitles: [])
        let merged = MediaInfo.merging([video, audio])
        #expect(merged.duration == 212.5)
        #expect(merged.video == video.video)
        #expect(merged.audio == audio.audio)
    }
}
