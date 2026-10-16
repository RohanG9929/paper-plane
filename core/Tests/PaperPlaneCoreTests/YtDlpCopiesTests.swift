import Foundation
import Testing
@testable import PaperPlaneCore

struct YtDlpCopiesTests {
    /// yt-dlp's versions are dates, with a number after for a second release that day.
    @Test func versionsCompareAsNumbers() throws {
        let order = ["2025.12.31", "2026.01.02", "2026.10.09", "2026.10.09.1", "2026.10.09.2", "2026.10.10"]
        let versions = try order.map { try #require(YtDlpVersion($0)) }
        #expect(versions == versions.sorted())
        #expect(versions.shuffled().sorted() == versions)
        #expect(YtDlpVersion("2026.10.09\n") == YtDlpVersion("2026.10.09"))
        #expect(YtDlpVersion("2026.10.09")?.description == "2026.10.09")
        // The tag names a release folder: it comes back exactly, leading zeros and all.
        #expect(YtDlpVersion("2026.10.09.000915\n")?.description == "2026.10.09.000915")
        #expect(try #require(YtDlpVersion("2026.10.09.000915")) < #require(YtDlpVersion("2026.10.09.1000")))
        #expect(try #require(YtDlpVersion("2026.10.09.123456")) > #require(YtDlpVersion("2026.10.09.99")))
    }

    /// A tag becomes part of a download address, so nothing but a version is taken.
    @Test(arguments: ["", "latest", "v2026.10.09", "2026.10", "2026.10.09.", "2026.10.09/../../x", "2026.1.9",
                      "2026.10.09.1234567", "2026 .10.09", "../2026.10.09", "2026.10.09?x=1", "２０２６.10.09"])
    func versionsRejectAnythingElse(_ text: String) {
        #expect(YtDlpVersion(text) == nil)
    }

    func folders() throws -> (bundle: URL, helpers: URL, updated: URL) {
        let root = try TestSupport.makeTemporaryDirectory()
        let bundle = root.appendingPathComponent("Paper Plane.app")
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        let updated = root.appendingPathComponent("Application Support/Paper Plane/bin")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: updated, withIntermediateDirectories: true)
        return (bundle, helpers, updated)
    }

    func place(in folder: URL, version: String?) throws {
        let executable = folder.appendingPathComponent("yt-dlp")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if let version {
            try "\(version)\n".write(to: folder.appendingPathComponent("yt-dlp.version"), atomically: true, encoding: .utf8)
        }
    }

    func copies(_ f: (bundle: URL, helpers: URL, updated: URL), fallsBack: Bool = false,
                environment: [String: String] = [:], fallbackFolders: [String] = []) -> YtDlpCopies {
        YtDlpCopies(bundle: f.bundle, updatedFolder: f.updated, fallsBackToInstalled: fallsBack,
                    environment: environment, fallbackFolders: fallbackFolders)
    }

    @Test func theNewerCopyRuns() throws {
        let f = try folders()
        try place(in: f.helpers, version: "2026.10.09")
        try place(in: f.updated, version: "2026.10.12")
        #expect(copies(f).current()?.executable == f.updated.appendingPathComponent("yt-dlp"))
        #expect(copies(f).current()?.version == YtDlpVersion("2026.10.12"))
        // An app updated since: its own copy is newer than the one downloaded before.
        try "2026.11.01".write(to: f.helpers.appendingPathComponent("yt-dlp.version"), atomically: true, encoding: .utf8)
        #expect(copies(f).current()?.executable == f.helpers.appendingPathComponent("yt-dlp"))
        // The same version: the one inside the app.
        try "2026.11.01".write(to: f.updated.appendingPathComponent("yt-dlp.version"), atomically: true, encoding: .utf8)
        #expect(copies(f).current()?.executable == f.helpers.appendingPathComponent("yt-dlp"))
    }

    @Test func theUpdatedCopyRunsWhenTheBundleHasNone() throws {
        let f = try folders()
        #expect(copies(f).current() == nil)
        try place(in: f.updated, version: "2026.10.12")
        #expect(copies(f).current()?.executable == f.updated.appendingPathComponent("yt-dlp"))
        try place(in: f.helpers, version: "2026.10.01")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.updated.appendingPathComponent("yt-dlp").path)
        #expect(copies(f).current()?.executable == f.helpers.appendingPathComponent("yt-dlp"), "not executable: not a copy")
    }

    /// As for ffmpeg: a release never runs whatever happens to be installed under that name.
    @Test func onlyADevelopmentBuildFallsBackToAnInstalledYtDlp() throws {
        let f = try folders()
        let installed = try TestSupport.makeTemporaryDirectory()
        try place(in: installed, version: nil)
        #expect(copies(f, fallsBack: false, environment: ["PATH": installed.path]).current() == nil)
        #expect(copies(f, fallsBack: true, environment: ["PATH": installed.path]).current()?.executable
            == installed.appendingPathComponent("yt-dlp"))
        #expect(copies(f, fallsBack: true, environment: [:], fallbackFolders: [installed.path]).current()?.executable
            == installed.appendingPathComponent("yt-dlp"))
        try place(in: f.updated, version: "2026.10.12")
        #expect(copies(f, fallsBack: true, environment: ["PATH": installed.path]).current()?.executable
            == f.updated.appendingPathComponent("yt-dlp"), "the app's own copies come first")
    }

    @Test func aCopyWithoutItsVersionLosesToOneWithIt() throws {
        let f = try folders()
        try place(in: f.helpers, version: nil)
        try place(in: f.updated, version: "2026.01.01")
        #expect(copies(f).current()?.executable == f.updated.appendingPathComponent("yt-dlp"))
        try FileManager.default.removeItem(at: f.updated.appendingPathComponent("yt-dlp.version"))
        #expect(copies(f).current()?.executable == f.helpers.appendingPathComponent("yt-dlp"))
        #expect(copies(f).current()?.version == nil)
    }

    @Test func theStandardUpdatedFolderIsInApplicationSupport() {
        let standard = YtDlpCopies.standard(bundle: URL(fileURLWithPath: "/Applications/Paper Plane.app"), fallsBackToInstalled: false)
        #expect(standard.updatedFolder.path.hasSuffix("/Library/Application Support/Paper Plane/bin"))
    }
}
