import Foundation
import Testing
@testable import PaperPlaneCore

struct SidecarSubtitlesTests {
    @Test func findsPlainLanguageAndForcedFiles() {
        let names = ["Movie.mkv", "Movie.srt", "Movie.en.srt", "Movie.pt-BR.srt", "movie.FR.SRT", "Movie.en.forced.srt",
                     "Movie.forced.srt", "Movie Extras.srt", "Movie.Extras.Part.srt", "Other.en.srt", "Movie.mkv.srt",
                     "Movie.Commentary.srt", "Movie.nfo"] // Movie.Commentary.srt belongs to Movie.Commentary.mkv
        let found = SidecarSubtitles.files(forVideoNamed: "Movie.mkv", among: names)
        #expect(found.map(\.name) == ["Movie.en.forced.srt", "Movie.en.srt", "Movie.forced.srt", "Movie.mkv.srt",
                                      "Movie.pt-BR.srt", "Movie.srt", "movie.FR.SRT"])
        #expect(found.map(\.language) == ["en", "en", nil, nil, "pt-BR", nil, "FR"])
        #expect(found.map(\.isForced) == [true, false, true, false, false, false, false])
    }

    /// Subtitles for the deaf and hard of hearing are often marked `sdh`, `hi` or `cc`; `sdh` alone
    /// is not a language (Foundation would call it Southern Kurdish).
    @Test func findsHearingImpairedFiles() {
        let found = SidecarSubtitles.files(forVideoNamed: "Movie.mkv",
                                           among: ["Movie.en.sdh.srt", "Movie.en.hi.srt", "Movie.sdh.srt",
                                                   "Movie.en.cc.forced.srt", "Movie.en.sdh.extra.srt"])
        #expect(found.map(\.name) == ["Movie.en.cc.forced.srt", "Movie.en.hi.srt", "Movie.en.sdh.srt", "Movie.sdh.srt"])
        #expect(found.map(\.language) == ["en", "en", "en", nil])
        #expect(found.map(\.isForced) == [true, false, false, false])
    }

    @Test func awkwardNamesStillMatch() {
        let found = SidecarSubtitles.files(forVideoNamed: "Movie: Part 1 (Director's Cut) é.mp4",
                                           among: ["Movie: Part 1 (Director's Cut) é.en.srt", "Movie: Part 1.srt"])
        #expect(found.map(\.name) == ["Movie: Part 1 (Director's Cut) é.en.srt"])
    }

    @Test func findsFilesOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Show.mkv", "Show.en.srt", "Show.srt"] {
            try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8).write(to: folder.appendingPathComponent(name))
        }
        let found = await SidecarSubtitles.find(for: folder.appendingPathComponent("Show.mkv"))
        #expect(found.map(\.url.lastPathComponent) == ["Show.en.srt", "Show.srt"])
        #expect(await SidecarSubtitles.find(for: URL(fileURLWithPath: "/nonexistent/x.mkv")).isEmpty)
    }

    /// Listing a folder in Desktop, Documents or Downloads waits on the macOS privacy prompt until
    /// it's answered. A start that's cancelled (by quitting, or a newer video) must not wait too.
    @Test func aLookupStuckOnThePrivacyPromptCanBeAbandoned() async {
        let started = ContinuousClock.now
        let lookup = Task {
            await SidecarSubtitles.find(for: URL(fileURLWithPath: "/Movies/a.mkv")) { _ in
                Thread.sleep(forTimeInterval: 5) // blocked, as on the prompt
                return ["a.srt"]
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        lookup.cancel()
        #expect(await lookup.value.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aLookupCancelledBeforeItStartsReturnsAtOnce() async {
        let lookup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SidecarSubtitles.find(for: URL(fileURLWithPath: "/Movies/a.mkv")) { _ in
                Thread.sleep(forTimeInterval: 5)
                return ["a.srt"]
            }
        }
        let started = ContinuousClock.now
        #expect(await lookup.value.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
