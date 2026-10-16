import CryptoKit
import Foundation
import Testing
@testable import PaperPlaneCore

/// GitHub as the updater sees it, in memory: no test reaches the network.
final class FakeReleases: ReleaseFetching, @unchecked Sendable {
    private let lock = NSLock()
    var tag: String
    var files: [URL: Data]
    var failsLatest = false
    /// How long a download takes.
    var delay: Duration = .zero
    private(set) var requests: [String] = []

    init(tag: String, files: [URL: Data] = [:]) {
        self.tag = tag
        self.files = files
    }

    private func note(_ request: String) {
        lock.withLock { requests.append(request) }
    }

    func latestTag() async throws -> String {
        note("latest")
        if failsLatest { throw URLError(.notConnectedToInternet) }
        return tag
    }

    func data(from url: URL, limit: Int) async throws -> Data {
        note(url.absoluteString)
        guard let data = files[url], data.count <= limit else { throw URLError(.fileDoesNotExist) }
        return data
    }

    func download(_ url: URL, into folder: URL, limit: Int) async throws -> URL {
        note(url.absoluteString)
        try await Task.sleep(for: delay)
        guard let data = files[url], data.count <= limit else { throw URLError(.fileDoesNotExist) }
        let file = folder.appendingPathComponent(".download-\(UUID().uuidString)")
        try data.write(to: file)
        return file
    }

    /// A release `tag` whose yt-dlp_macos is `binary`, its sums saying `digest` (the right one by default).
    static func release(_ tag: String, binary: Data, digest: String? = nil) -> FakeReleases {
        let folder = YtDlpUpdater.releaseBase.appendingPathComponent(tag, isDirectory: true)
        let right = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        let sums = """
        \(String(repeating: "1", count: 64))  yt-dlp
        \(digest ?? right)  yt-dlp_macos
        \(String(repeating: "2", count: 64))  yt-dlp_macos.zip
        """
        return FakeReleases(tag: tag, files: [
            folder.appendingPathComponent("SHA2-256SUMS"): Data(sums.utf8),
            folder.appendingPathComponent("yt-dlp_macos"): binary,
        ])
    }
}

/// When the updater last looked, in memory.
final class CheckTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?
    var last: Date? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct YtDlpUpdaterTests {
    let binary = Data("#!/bin/sh\necho new\n".utf8)

    func setUp(shipped: String? = "2026.10.01") throws -> YtDlpCopies {
        let root = try TestSupport.makeTemporaryDirectory()
        let bundle = root.appendingPathComponent("Paper Plane.app")
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        if let shipped {
            let executable = helpers.appendingPathComponent("yt-dlp")
            try Data("#!/bin/sh\necho shipped\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try "\(shipped)\n".write(to: helpers.appendingPathComponent("yt-dlp.version"), atomically: true, encoding: .utf8)
        }
        return YtDlpCopies(bundle: bundle, updatedFolder: root.appendingPathComponent("Paper Plane/bin"),
                           fallsBackToInstalled: false)
    }

    func updater(_ copies: YtDlpCopies, _ releases: FakeReleases, times: CheckTimes = CheckTimes(),
                 now: @escaping @Sendable () -> Date = { Date() }) -> YtDlpUpdater {
        YtDlpUpdater(copies: copies, fetching: releases,
                     lastCheck: { times.last }, setLastCheck: { times.last = $0 }, now: now)
    }

    func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func aNewerReleaseIsInstalled() async throws {
        let copies = try setUp()
        let installed = try await updater(copies, .release("2026.10.12", binary: binary)).update()
        #expect(installed)
        #expect(try Data(contentsOf: copies.updatedFolder.appendingPathComponent("yt-dlp")) == binary)
        #expect(try String(contentsOf: copies.updatedFolder.appendingPathComponent("yt-dlp.version"), encoding: .utf8) == "2026.10.12\n")
        #expect(copies.current()?.executable == copies.updatedFolder.appendingPathComponent("yt-dlp"))
        #expect(contents(of: copies.updatedFolder) == ["yt-dlp", "yt-dlp.version"])
    }

    @Test func theSameVersionIsLeftAlone() async throws {
        let copies = try setUp(shipped: "2026.10.12")
        let releases = FakeReleases.release("2026.10.12", binary: binary)
        #expect(try await updater(copies, releases).update() == false)
        #expect(releases.requests == ["latest"])
        let older = FakeReleases.release("2026.09.30", binary: binary)
        #expect(try await updater(copies, older).update() == false)
        #expect(contents(of: copies.updatedFolder).isEmpty)
    }

    /// No copy at all (a development build, or one deleted): the latest is fetched.
    @Test func aMissingYtDlpIsInstalled() async throws {
        let copies = try setUp(shipped: nil)
        #expect(try await updater(copies, .release("2026.10.12", binary: binary)).update())
        #expect(copies.current()?.version == YtDlpVersion("2026.10.12"))
    }

    /// Review Focus 4: what doesn't match the release's sums never runs, and the copy that worked
    /// still does.
    @Test func aMismatchedDownloadLeavesTheOldCopy() async throws {
        let copies = try setUp()
        _ = try await updater(copies, .release("2026.10.05", binary: Data("old".utf8))).update()
        let releases = FakeReleases.release("2026.10.12", binary: binary, digest: String(repeating: "a", count: 64))
        await #expect(throws: YtDlpUpdateError.mismatch) { try await updater(copies, releases).update() }
        #expect(try Data(contentsOf: copies.updatedFolder.appendingPathComponent("yt-dlp")) == Data("old".utf8))
        #expect(copies.current()?.version == YtDlpVersion("2026.10.05"))
        #expect(contents(of: copies.updatedFolder) == ["yt-dlp", "yt-dlp.version"])
    }

    @Test func aFailedDownloadLeavesNothingBehind() async throws {
        let copies = try setUp()
        let releases = FakeReleases.release("2026.10.12", binary: binary)
        releases.files.removeValue(forKey: YtDlpUpdater.releaseBase.appendingPathComponent("2026.10.12/yt-dlp_macos"))
        await #expect(throws: (any Error).self) { try await updater(copies, releases).update() }
        #expect(contents(of: copies.updatedFolder).isEmpty)
        #expect(copies.current()?.version == YtDlpVersion("2026.10.01"))
    }

    /// The tag becomes part of the download address: anything but a version stops the update
    /// before anything else is fetched.
    @Test(arguments: ["v2026.10.12", "2026.10.12/../../../evil", "latest", ""])
    func aTagThatIsntAVersionIsRefused(_ tag: String) async throws {
        let copies = try setUp()
        let releases = FakeReleases(tag: tag)
        await #expect(throws: YtDlpUpdateError.notAVersion) { try await updater(copies, releases).update() }
        #expect(releases.requests == ["latest"])
    }

    /// Spec §5.3: only from github.com/yt-dlp/yt-dlp releases.
    @Test func filesComeOnlyFromTheReleaseFolder() async throws {
        let copies = try setUp()
        let releases = FakeReleases.release("2026.10.12", binary: binary)
        _ = try await updater(copies, releases).update()
        #expect(releases.requests == [
            "latest",
            "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.12/SHA2-256SUMS",
            "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.12/yt-dlp_macos",
        ])
    }

    /// Spec §5.3: at most once a day.
    @Test func checksAtMostOnceADay() async throws {
        let copies = try setUp(shipped: "2026.10.12")
        let releases = FakeReleases.release("2026.10.12", binary: binary)
        let times = CheckTimes()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for (hours, checks) in [(0.0, 1), (1, 1), (23.9, 1), (24.1, 2), (30, 2), (-5, 3)] {
            _ = await updater(copies, releases, times: times, now: { start.addingTimeInterval(hours * 3600) }).updateIfDue()
            #expect(releases.requests.filter { $0 == "latest" }.count == checks, "at \(hours) h")
        }
    }

    /// A failed page asks GitHub at once (spec §6), unless it was asked within the hour: a few
    /// bad links in a row cost one request, not one each.
    @Test func aFailureChecksAgainOnlyAfterAnHour() async throws {
        let copies = try setUp(shipped: "2026.10.12")
        let releases = FakeReleases.release("2026.10.12", binary: binary)
        let times = CheckTimes()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for (minutes, checks) in [(0.0, 1), (10, 1), (59, 1), (61, 2), (62, 2)] {
            _ = try await updater(copies, releases, times: times, now: { start.addingTimeInterval(minutes * 60) })
                .updateAfterFailure()
            #expect(releases.requests.filter { $0 == "latest" }.count == checks, "at \(minutes) min")
        }
        // With no yt-dlp at all, every failure looks.
        let none = try setUp(shipped: nil)
        let empty = FakeReleases(tag: "x")
        let recent = CheckTimes()
        recent.last = start
        _ = try? await updater(none, empty, times: recent, now: { start.addingTimeInterval(60) }).updateAfterFailure()
        #expect(empty.requests == ["latest"])
    }

    @Test func aFailedCheckIsTriedAgainNextLaunch() async throws {
        let copies = try setUp()
        let releases = FakeReleases.release("2026.10.12", binary: binary)
        releases.failsLatest = true
        let times = CheckTimes()
        #expect(await updater(copies, releases, times: times).updateIfDue() == false)
        #expect(times.last == nil)
        releases.failsLatest = false
        #expect(await updater(copies, releases, times: times).updateIfDue())
        #expect(times.last != nil)
    }

    /// A download cut short by a quit or a crash doesn't stay for ever.
    @Test func leftoverDownloadsAreRemoved() async throws {
        let copies = try setUp()
        try FileManager.default.createDirectory(at: copies.updatedFolder, withIntermediateDirectories: true)
        let leftover = copies.updatedFolder.appendingPathComponent(".yt-dlp-0E8B1E9A-0000-0000-0000-000000000000.download")
        try Data(count: 1000).write(to: leftover)
        _ = try await updater(copies, .release("2026.10.12", binary: binary)).update()
        #expect(contents(of: copies.updatedFolder) == ["yt-dlp", "yt-dlp.version"])
    }

    @Test func theInstalledCopyIsExecutableInAPrivateFolder() async throws {
        let copies = try setUp()
        _ = try await updater(copies, .release("2026.10.12", binary: binary)).update()
        let files = FileManager.default
        #expect(try files.attributesOfItem(atPath: copies.updatedFolder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try files.attributesOfItem(atPath: copies.updatedFolder.appendingPathComponent("yt-dlp").path)[.posixPermissions] as? Int == 0o755)
    }

    /// A launch check and a failed extraction can ask at once: one download.
    @Test func twoUpdatesAtOnceDownloadOnce() async throws {
        let copies = try setUp()
        let releases = FakeReleases.release("2026.10.12", binary: binary)
        releases.delay = .milliseconds(300)
        let shared = updater(copies, releases)
        async let first = shared.update()
        async let second = shared.update()
        let results = try await [first, second]
        #expect(results.contains(true))
        #expect(releases.requests.filter { $0.hasSuffix("/yt-dlp_macos") }.count == 1)
    }

    @Test func sumsLinesAreReadExactly() {
        let digest = String(repeating: "ab", count: 32)
        #expect(SHA256Sums.digest(for: "yt-dlp_macos", in: "\(digest)  yt-dlp_macos\n") == digest)
        #expect(SHA256Sums.digest(for: "yt-dlp_macos", in: "\(digest) *yt-dlp_macos") == digest)
        #expect(SHA256Sums.digest(for: "yt-dlp_macos", in: "\(digest.uppercased())  yt-dlp_macos") == digest)
        #expect(SHA256Sums.digest(for: "yt-dlp_macos", in: "\(digest)  yt-dlp_macos.zip\n\(digest)  yt-dlp_macos_legacy") == nil)
        #expect(SHA256Sums.digest(for: "yt-dlp_macos", in: "\(digest.dropLast())  yt-dlp_macos") == nil)
        #expect(SHA256Sums.digest(for: "yt-dlp_macos", in: "\(String(repeating: "zz", count: 32))  yt-dlp_macos") == nil)
        #expect(SHA256Sums.digest(for: "yt-dlp_macos", in: "\(digest)  yt-dlp_macos\n\(String(repeating: "cd", count: 32))  yt-dlp_macos") == nil,
                "two different digests for one name")
        #expect(SHA256Sums.digest(for: "yt-dlp_macos", in: "\(digest)  yt-dlp_macos extra") == nil)
    }

    @Test func theLatestTagIsReadFromGitHubsAnswer() throws {
        #expect(try GitHubReleases.tag(fromLatestRelease: Data(#"{"tag_name": "2026.10.12", "name": "yt-dlp 2026.10.12"}"#.utf8)) == "2026.10.12")
        #expect(throws: (any Error).self) { try GitHubReleases.tag(fromLatestRelease: Data(#"{"message": "API rate limit exceeded"}"#.utf8)) }
    }
}

/// The live downloader against scripts/serve-hls.py: its size limit, redirects and leftovers.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
struct GitHubReleasesTests {
    func site() async throws -> (HLSServer, URL) {
        let served = try TestSupport.makeTemporaryDirectory()
        try Data(repeating: 7, count: 300_000).write(to: served.appendingPathComponent("yt-dlp_macos"))
        return (try await HLSServer(directory: served), try TestSupport.makeTemporaryDirectory())
    }

    @Test func downloadKeepsWithinItsLimit() async throws {
        let (server, folder) = try await site()
        defer { server.stop() }
        await #expect(throws: YtDlpUpdateError.tooLarge) {
            try await GitHubReleases().download(server.url("yt-dlp_macos"), into: folder, limit: 100_000)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        let file = try await GitHubReleases().download(server.url("yt-dlp_macos"), into: folder, limit: 300_000)
        #expect(try Data(contentsOf: file) == Data(repeating: 7, count: 300_000))
        #expect(file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    /// GitHub sends release files from another host.
    @Test func downloadFollowsRedirects() async throws {
        let (server, folder) = try await site()
        defer { server.stop() }
        let file = try await GitHubReleases().download(server.url("redirect/127.0.0.1:\(server.port)/yt-dlp_macos"),
                                                       into: folder, limit: 1 << 20)
        #expect(try Data(contentsOf: file).count == 300_000)
    }

    /// GitHub sends release files from another host, over HTTPS; never down to plain HTTP.
    @Test func redirectsNeverLeaveHTTPS() {
        let https = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.12/yt-dlp_macos")
        #expect(UpstreamFetch.isDowngrade(from: https, to: URL(string: "http://objects.example.com/x")))
        #expect(UpstreamFetch.isDowngrade(from: https, to: URL(string: "ftp://objects.example.com/x")))
        #expect(UpstreamFetch.isDowngrade(from: https, to: nil))
        #expect(!UpstreamFetch.isDowngrade(from: https, to: URL(string: "HTTPS://release-assets.githubusercontent.com/x")))
        #expect(!UpstreamFetch.isDowngrade(from: URL(string: "http://127.0.0.1/x"), to: URL(string: "http://127.0.0.1/y")))
    }

    @Test func aFailingStatusIsAnError() async throws {
        let (server, folder) = try await site()
        defer { server.stop() }
        await #expect(throws: YtDlpUpdateError.status(404)) {
            try await GitHubReleases().download(server.url("status/404/yt-dlp_macos"), into: folder, limit: 1 << 20)
        }
        await #expect(throws: YtDlpUpdateError.status(404)) {
            try await GitHubReleases().data(from: server.url("status/404/SHA2-256SUMS"), limit: 1 << 20)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// Stopping or quitting doesn't wait for a site that says nothing.
    @Test func aSilentSiteIsGivenUpOnWhenCancelled() async throws {
        let (server, folder) = try await site()
        defer { server.stop() }
        let url = server.url("hang/20/yt-dlp_macos")
        let fetching = Task { try await GitHubReleases().download(url, into: folder, limit: 1 << 20) }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        fetching.cancel()
        await #expect(throws: (any Error).self) { try await fetching.value }
        #expect(ContinuousClock.now - cancelledAt < .seconds(3))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func smallFilesKeepWithinTheirLimit() async throws {
        let (server, _) = try await site()
        defer { server.stop() }
        await #expect(throws: YtDlpUpdateError.tooLarge) {
            try await GitHubReleases().data(from: server.url("yt-dlp_macos"), limit: 1000)
        }
    }
}
