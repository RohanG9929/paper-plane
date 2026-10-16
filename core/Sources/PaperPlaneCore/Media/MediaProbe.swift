import Foundation

/// Reads a video's tracks, codecs and duration with ffprobe.
public struct MediaProbe: Sendable {
    public var tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    /// Probes every input and merges the results.
    public func probe(_ input: ResolvedInput) async throws -> MediaInfo {
        guard !input.inputs.isEmpty else { throw MediaProbeError.noInputs }
        var parts: [MediaInfo] = []
        for (position, item) in input.inputs.enumerated() {
            let arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams"]
                + item.ffmpegOptions + [item.ffmpegLocation]
            let result = try await ProcessRunner.run(tools.ffprobe, arguments: arguments)
            guard result.status == 0 else {
                throw MediaProbeError.ffprobeFailed(status: result.status, message: Redaction.summary(of: result.stderr))
            }
            parts.append(try FFprobeParser.parse(result.stdout, input: position))
        }
        return MediaInfo.merging(parts)
    }
}
