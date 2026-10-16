import Foundation

/// A still frame for the remote's artwork.
public enum Thumbnail {
    /// A JPEG of the frame `seconds` into `input`, `width` pixels wide. nil when there is no
    /// such frame (corrupt input, audio only, past the end) or ffmpeg fails.
    public static func jpeg(tools: ToolPaths, input: ResolvedInput.Input, at seconds: Double,
                            width: Int = 640) async -> Data? {
        let arguments = ffmpegQuietArguments + input.ffmpegInputArguments(seek: seconds) + [
            "-map", "0:V:0", "-frames:v", "1", "-vf", "scale=\(width):-2",
            "-c:v", "mjpeg", "-q:v", "4", "-f", "image2pipe", "-",
        ]
        guard let result = try? await ProcessRunner.run(tools.ffmpeg, arguments: arguments),
              result.status == 0, result.stdout.prefix(2) == Data([0xFF, 0xD8])
        else { return nil }
        return result.stdout
    }

    /// Where to take the frame: a tenth of the way in, past opening titles and black frames.
    public static func moment(duration: Double?) -> Double {
        guard let duration, duration.isFinite, duration > 0 else { return 5 }
        return duration / 10
    }
}
