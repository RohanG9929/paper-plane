import Foundation

public enum MediaProbeError: Error, Equatable {
    /// A ResolvedInput with no inputs was probed.
    case noInputs
    /// ffprobe's output wasn't the JSON we asked for.
    case unreadableOutput
    /// ffprobe exited with an error. `message` is redacted (no URL queries).
    case ffprobeFailed(status: Int32, message: String)
}

/// Turns `ffprobe -print_format json -show_format -show_streams` output into a MediaInfo.
enum FFprobeParser {
    private struct Output: Decodable {
        struct Stream: Decodable {
            var index: Int
            var codecType: String?
            var codecName: String?
            var width: Int?
            var height: Int?
            var pixFmt: String?
            var channels: Int?
            var colorTransfer: String?
            var avgFrameRate: String?
            var rFrameRate: String?
            var disposition: [String: Int]?
            var tags: [String: String]?

            enum CodingKeys: String, CodingKey {
                case index, width, height, channels, disposition, tags
                case codecType = "codec_type"
                case codecName = "codec_name"
                case pixFmt = "pix_fmt"
                case colorTransfer = "color_transfer"
                case avgFrameRate = "avg_frame_rate"
                case rFrameRate = "r_frame_rate"
            }

            /// Tag lookup that ignores case (MKV files sometimes use `LANGUAGE`).
            func tag(_ name: String) -> String? {
                tags?.first(where: { $0.key.lowercased() == name })?.value
            }

            func flag(_ name: String) -> Bool { disposition?[name] == 1 }
        }

        struct Format: Decodable {
            var duration: String?
        }

        var streams: [Stream]?
        var format: Format?
    }

    /// `input` is the ffmpeg input position, recorded in each track's ref.
    static func parse(_ data: Data, input: Int = 0) throws -> MediaInfo {
        let output: Output
        do {
            output = try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw MediaProbeError.unreadableOutput
        }

        var info = MediaInfo(duration: duration(output.format?.duration), video: [], audio: [], subtitles: [])
        for stream in output.streams ?? [] {
            let ref = TrackRef(input: input, index: stream.index)
            let codec = stream.codecName ?? "unknown"
            switch stream.codecType ?? "" {
            case "video" where !stream.flag("attached_pic"):
                info.video.append(VideoTrack(
                    ref: ref,
                    codec: VideoCodecName(ffprobeName: codec),
                    width: stream.width ?? 0,
                    height: stream.height ?? 0,
                    pixelFormat: stream.pixFmt,
                    hdr: HDRFormat(colorTransfer: stream.colorTransfer),
                    frameRate: frameRate(stream.avgFrameRate) ?? frameRate(stream.rFrameRate)))
            case "audio":
                info.audio.append(AudioTrack(
                    ref: ref,
                    codec: AudioCodecName(ffprobeName: codec),
                    channels: stream.channels ?? 2,
                    language: language(stream.tag("language")),
                    title: stream.tag("title"),
                    isDefault: stream.flag("default")))
            case "subtitle":
                info.subtitles.append(SubtitleTrack(
                    ref: ref,
                    codecName: codec,
                    kind: SubtitleKind(ffprobeName: codec),
                    language: language(stream.tag("language")),
                    title: stream.tag("title"),
                    isDefault: stream.flag("default"),
                    isForced: stream.flag("forced")))
            default:
                continue
            }
        }
        return info
    }

    private static func duration(_ text: String?) -> Double? {
        guard let text, let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// ffprobe writes rates as fractions: `24000/1001`, or `0/0` when it doesn't know.
    private static func frameRate(_ fraction: String?) -> Double? {
        guard let rate = fraction.flatMap(Fraction.value), rate > 0 else { return nil }
        return rate
    }

    private static func language(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return code
    }
}
