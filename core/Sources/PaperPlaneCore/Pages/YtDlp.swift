import Foundation

/// Runs yt-dlp to find a page's video (spec §3.1, §5.3).
public enum YtDlp {
    /// Asks the yt-dlp at `executable` for `page`'s video, with the site's `cookie` and the app's
    /// `ffmpeg`, and gives up after `timeLimit`. Cancelling the calling task stops yt-dlp. It runs with `environment`
    /// (the app's), Homebrew's folders added to PATH.
    public static func resolve(page: URL, cookie: String?, executable: URL, cacheFolder: URL, ffmpeg: URL? = nil,
                               fallbackTitle: String, timeLimit: Duration = .seconds(60),
                               environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ResolvedPage {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw YtDlpFailure.missing }
        let arguments = YtDlpCommand.arguments(page: Links.forYtDlp(page), cacheFolder: cacheFolder, ffmpeg: ffmpeg)
        let configuration = Data(YtDlpCommand.configuration(cookie: cookie).utf8)
        let environment = YtDlpCommand.environment(base: environment)
        let result = try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask {
                // Its own responsible process: whatever runs here borrows none of Paper Plane's
                // privacy permissions (security review, Plan 5).
                try await ProcessRunner.run(executable, arguments: arguments, input: configuration, environment: environment,
                                            disclaimsResponsibility: true)
            }
            group.addTask {
                try await Task.sleep(for: timeLimit)
                return nil // the time limit came first
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else { throw YtDlpFailure.timedOut }
            return result
        }
        guard result.status == 0 else { throw YtDlpFailure.from(stderr: result.stderr) }
        return try YtDlpOutput.page(from: result.stdout, page: page, fallbackTitle: fallbackTitle)
    }
}
