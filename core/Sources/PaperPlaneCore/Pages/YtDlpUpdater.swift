import CryptoKit
import Foundation
import os

public enum YtDlpUpdateError: Error, Equatable {
    /// The latest release's tag isn't a yt-dlp version.
    case notAVersion
    /// The release's SHA2-256SUMS has no single line for yt-dlp_macos.
    case noDigest
    /// The download doesn't match its line in SHA2-256SUMS.
    case mismatch
    case tooLarge
    case status(Int)
}

/// Where updates come from: GitHub, or a stand-in in tests.
public protocol ReleaseFetching: Sendable {
    /// The latest yt-dlp release's tag.
    func latestTag() async throws -> String
    /// A small file, at most `limit` bytes.
    func data(from url: URL, limit: Int) async throws -> Data
    /// A file of at most `limit` bytes, saved into `folder` (readable only by this user); where it went.
    func download(_ url: URL, into folder: URL, limit: Int) async throws -> URL
}

/// Keeps yt-dlp current (spec §5.3; Milestone 4, decision 4): the latest release's
/// `yt-dlp_macos`, checked against its `SHA2-256SUMS`, into Application Support, never into the
/// app. At most once a day, and right after an extraction fails.
public final class YtDlpUpdater: Sendable {
    /// The only folder files are fetched from: `<tag>/SHA2-256SUMS` and `<tag>/yt-dlp_macos`.
    public static let releaseBase = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/")!
    static let assetName = "yt-dlp_macos"
    static let maximumSize = 200 << 20
    static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let log = Logger(subsystem: "dev.paperplane.app", category: "yt-dlp")

    let copies: YtDlpCopies
    let fetching: any ReleaseFetching
    let lastCheck: @Sendable () -> Date?
    let setLastCheck: @Sendable (Date) -> Void
    let now: @Sendable () -> Date
    /// One update at a time: the launch check and a failed extraction can ask together.
    private let running = OSAllocatedUnfairLock<Task<Bool, any Error>?>(initialState: nil)

    public init(copies: YtDlpCopies, fetching: any ReleaseFetching = GitHubReleases(),
                lastCheck: @escaping @Sendable () -> Date?, setLastCheck: @escaping @Sendable (Date) -> Void,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.copies = copies
        self.fetching = fetching
        self.lastCheck = lastCheck
        self.setLastCheck = setLastCheck
        self.now = now
    }

    /// The app's: when it last looked is kept in its defaults.
    public static func standard(copies: YtDlpCopies) -> YtDlpUpdater {
        let key = "ytDlpLastUpdateCheck"
        return YtDlpUpdater(copies: copies,
                            lastCheck: { UserDefaults.standard.object(forKey: key) as? Date },
                            setLastCheck: { UserDefaults.standard.set($0, forKey: key) })
    }

    /// Updates if a day has passed since the last check (or the clock went back). A failed check
    /// isn't counted, so the next launch tries again. Returns whether a newer copy was installed.
    public func updateIfDue() async -> Bool {
        let now = now()
        if let last = lastCheck(), last <= now, now.timeIntervalSince(last) < Self.checkInterval {
            return false
        }
        do {
            let installed = try await update()
            setLastCheck(now)
            return installed
        } catch {
            Self.log.error("Couldn't update yt-dlp: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Installs the latest release now if it's newer than the copy that runs. Returns whether it
    /// did. Cancelling stops waiting and the download.
    public func update() async throws -> Bool {
        let task = running.withLock { running in
            if let running { return running }
            let task = Task { try await self.install() }
            running = task
            return task
        }
        defer { running.withLock { if $0 == task { $0 = nil } } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func install() async throws -> Bool {
        guard let latest = YtDlpVersion(try await fetching.latestTag()) else { throw YtDlpUpdateError.notAVersion }
        if let current = copies.current()?.version, current >= latest {
            return false
        }
        let release = Self.releaseBase.appendingPathComponent(latest.description, isDirectory: true)
        let sums = try await fetching.data(from: release.appendingPathComponent("SHA2-256SUMS"), limit: 1 << 20)
        guard let expected = SHA256Sums.digest(for: Self.assetName, in: String(decoding: sums, as: UTF8.self)) else {
            throw YtDlpUpdateError.noDigest
        }
        let folder = copies.updatedFolder
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let download = try await fetching.download(release.appendingPathComponent(Self.assetName), into: folder,
                                                   limit: Self.maximumSize)
        defer { try? files.removeItem(at: download) } // nothing once it's moved into place
        guard try SHA256Sums.digest(ofFileAt: download) == expected else { throw YtDlpUpdateError.mismatch }
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: download.path)
        // The program first, then its version: a crash between leaves a newer program that says
        // it's older, which costs at most one more download.
        guard rename(download.path, folder.appendingPathComponent("yt-dlp").path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try Data("\(latest)\n".utf8).write(to: folder.appendingPathComponent("yt-dlp.version"), options: .atomic)
        Self.log.info("Installed yt-dlp \(latest.description, privacy: .public)")
        return true
    }
}

/// Reads a release's `SHA2-256SUMS`: lines of a hex SHA-256 and a file name.
enum SHA256Sums {
    /// `name`'s digest, in lowercase hex; nil unless exactly one digest is given for exactly that name.
    static func digest(for name: String, in text: String) -> String? {
        var found: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2 else { continue }
            let file = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1]
            let digest = fields[0].lowercased()
            guard file == name, digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { continue }
            found.insert(digest)
        }
        return found.count == 1 ? found.first : nil
    }

    /// The SHA-256 of the file at `url`, read a megabyte at a time.
    static func digest(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// GitHub's yt-dlp releases, over HTTPS, with no cookies or cache.
public struct GitHubReleases: ReleaseFetching {
    static let latestRelease = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    public init() {}

    public func latestTag() async throws -> String {
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try Self.tag(fromLatestRelease: try await fetch(request, limit: 1 << 20))
    }

    static func tag(fromLatestRelease data: Data) throws -> String {
        struct Release: Decodable {
            var tagName: String
            enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
        }
        return try JSONDecoder().decode(Release.self, from: data).tagName
    }

    public func data(from url: URL, limit: Int) async throws -> Data {
        try await fetch(URLRequest(url: url), limit: limit)
    }

    public func download(_ url: URL, into folder: URL, limit: Int) async throws -> URL {
        let (response, fetch) = try await UpstreamFetch.start(Self.prepared(URLRequest(url: url)), followsRedirects: true)
        defer { fetch.cancel() }
        guard response.statusCode == 200 else { throw YtDlpUpdateError.status(response.statusCode) }
        let file = folder.appendingPathComponent(".yt-dlp-\(UUID().uuidString).download")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var count = 0
            for try await chunk in fetch.body {
                count += chunk.count
                guard count <= limit else { throw YtDlpUpdateError.tooLarge }
                try handle.write(contentsOf: chunk)
            }
            try Task.checkCancellation() // a cancelled stream just ends
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    private func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        let (response, fetch) = try await UpstreamFetch.start(Self.prepared(request), followsRedirects: true)
        defer { fetch.cancel() }
        guard response.statusCode == 200 else { throw YtDlpUpdateError.status(response.statusCode) }
        var data = Data()
        for try await chunk in fetch.body {
            data.append(chunk)
            guard data.count <= limit else { throw YtDlpUpdateError.tooLarge }
        }
        try Task.checkCancellation()
        return data
    }

    /// GitHub's API wants a User-Agent; a site silent for 30 seconds is given up on.
    private static func prepared(_ request: URLRequest) -> URLRequest {
        var request = request
        request.timeoutInterval = 30
        request.setValue("Paper Plane", forHTTPHeaderField: "User-Agent")
        return request
    }
}
