import Foundation

/// Where the ffmpeg and ffprobe executables are.
public struct ToolPaths: Equatable, Sendable {
    public var ffmpeg: URL
    public var ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Looks in `PAPERPLANE_FFMPEG` / `PAPERPLANE_FFPROBE` first, then each `PATH` directory,
    /// then `fallbackDirectories` (Homebrew's default locations).
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    ) -> ToolPaths? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + fallbackDirectories
        guard let ffmpeg = find("ffmpeg", override: environment["PAPERPLANE_FFMPEG"], in: directories),
              let ffprobe = find("ffprobe", override: environment["PAPERPLANE_FFPROBE"], in: directories)
        else { return nil }
        return ToolPaths(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    /// The ffmpeg and ffprobe the app ships, in `Contents/Helpers/` of the bundle at `bundleURL`.
    /// nil if either is missing (a development build made without scripts/build-ffmpeg.sh).
    public static func inBundle(at bundleURL: URL) -> ToolPaths? {
        let helpers = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let ffmpeg = helpers.appendingPathComponent("ffmpeg")
        let ffprobe = helpers.appendingPathComponent("ffprobe")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: ffmpeg.path), files.isExecutableFile(atPath: ffprobe.path) else {
            return nil
        }
        return ToolPaths(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    private static func find(_ name: String, override: String?, in directories: [String]) -> URL? {
        let files = FileManager.default
        if let override, files.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for directory in directories {
            let path = (directory as NSString).appendingPathComponent(name)
            if files.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
