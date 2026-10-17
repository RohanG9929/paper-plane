import Foundation

/// A yt-dlp release: `2026.10.09`, or `2026.10.09.1` for a later one the same day.
public struct YtDlpVersion: Comparable, Sendable, CustomStringConvertible {
    /// The tag exactly as released, since it names the release's folder.
    public let description: String
    private let parts: [Int]

    /// Only a version, digit for digit: it becomes part of a download address.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]{1,6})?/) != nil else { return nil }
        description = trimmed
        parts = trimmed.split(separator: ".").compactMap { Int($0) }
    }

    public static func < (lhs: YtDlpVersion, rhs: YtDlpVersion) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }

    /// The same release, whatever zeros its text has.
    public static func == (lhs: YtDlpVersion, rhs: YtDlpVersion) -> Bool {
        lhs.parts == rhs.parts
    }
}

/// The copies of yt-dlp Paper Plane may run (Milestone 4, decision 3): the one it ships in
/// `Contents/Helpers/`, its `yt-dlp.version` among the app's resources (a text file among the
/// helpers would stop the app signing: macOS takes everything there for code), and the one the
/// updater keeps in Application Support with its `yt-dlp.version` beside it. The newer runs.
public struct YtDlpCopies: Sendable {
    public struct Copy: Equatable, Sendable {
        public var executable: URL
        /// nil when the copy doesn't say (a development build's, or one installed by Homebrew).
        public var version: YtDlpVersion?
    }

    public var bundle: URL
    public var updatedFolder: URL
    /// Only a development build may run a yt-dlp it didn't ship or download.
    public var fallsBackToInstalled: Bool
    var environment: [String: String]
    var fallbackFolders: [String]

    public init(bundle: URL, updatedFolder: URL, fallsBackToInstalled: Bool,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                fallbackFolders: [String] = ToolPaths.homebrewFolders) {
        self.bundle = bundle
        self.updatedFolder = updatedFolder
        self.fallsBackToInstalled = fallsBackToInstalled
        self.environment = environment
        self.fallbackFolders = fallbackFolders
    }

    /// The app at `bundle`, updates in `~/Library/Application Support/Paper Plane/bin/`.
    public static func standard(bundle: URL, fallsBackToInstalled: Bool) -> YtDlpCopies {
        YtDlpCopies(bundle: bundle,
                    updatedFolder: BrowserHosts.standardApplicationSupport
                        .appendingPathComponent("Paper Plane/bin", isDirectory: true),
                    fallsBackToInstalled: fallsBackToInstalled)
    }

    var shipped: Copy? {
        copy(in: ToolPaths.helpers(inBundle: bundle), version: Self.shippedVersionFile(inBundle: bundle))
    }

    var updated: Copy? {
        copy(in: updatedFolder, version: updatedFolder.appendingPathComponent("yt-dlp.version"))
    }

    /// Where the shipped copy's version is recorded: `Contents/Resources/yt-dlp.version`, not
    /// beside the executable in `Contents/Helpers/`, where macOS expects only code it can sign.
    public static func shippedVersionFile(inBundle bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/yt-dlp.version")
    }

    /// The copy to run, or nil when there's none.
    public func current() -> Copy? {
        switch (shipped, updated) {
        case let (shipped?, updated?):
            // A copy that doesn't say its version loses; the same version runs from the app.
            guard let newer = updated.version else { return shipped }
            return shipped.version.map { newer > $0 } ?? true ? updated : shipped
        case let (shipped?, nil):
            return shipped
        case let (nil, updated?):
            return updated
        case (nil, nil):
            return fallsBackToInstalled ? installed() : nil
        }
    }

    private func copy(in folder: URL, version versionFile: URL) -> Copy? {
        let executable = folder.appendingPathComponent("yt-dlp")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let version = (try? String(contentsOf: versionFile, encoding: .utf8)).flatMap(YtDlpVersion.init)
        return Copy(executable: executable, version: version)
    }

    /// One on PATH, then in Homebrew's folders.
    private func installed() -> Copy? {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + fallbackFolders
        return ToolPaths.find("yt-dlp", in: folders).map { Copy(executable: $0, version: nil) }
    }
}
