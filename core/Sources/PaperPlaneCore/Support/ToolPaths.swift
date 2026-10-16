import Foundation

/// Where the ffmpeg and ffprobe executables are.
public struct ToolPaths: Equatable, Sendable {
    public var ffmpeg: URL
    public var ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Where Homebrew installs tools, which apps started from the Dock don't have on PATH.
    public static let homebrewFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Looks in `PAPERPLANE_FFMPEG` / `PAPERPLANE_FFPROBE` first, then each `PATH` directory,
    /// then `fallbackDirectories` (Homebrew's default locations).
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = homebrewFolders
    ) -> ToolPaths? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + fallbackDirectories
        guard let ffmpeg = find("ffmpeg", override: environment["PAPERPLANE_FFMPEG"], in: directories),
              let ffprobe = find("ffprobe", override: environment["PAPERPLANE_FFPROBE"], in: directories)
        else { return nil }
        return ToolPaths(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    /// `Contents/Helpers/` of the app at `bundleURL`, where it keeps the tools it ships.
    static func helpers(inBundle bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    /// The ffmpeg and ffprobe the app ships, in `Contents/Helpers/` of the bundle at `bundleURL`.
    /// nil if either is missing (a development build made without scripts/build-ffmpeg.sh).
    public static func inBundle(at bundleURL: URL) -> ToolPaths? {
        let helpers = helpers(inBundle: bundleURL)
        let ffmpeg = helpers.appendingPathComponent("ffmpeg")
        let ffprobe = helpers.appendingPathComponent("ffprobe")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: ffmpeg.path), files.isExecutableFile(atPath: ffprobe.path) else {
            return nil
        }
        return ToolPaths(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    /// The executable `name` at `override`, else in the first of `directories` that has it.
    static func find(_ name: String, override: String? = nil, in directories: [String]) -> URL? {
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
