import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PaperPlaneCore

@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct StreamPipelineTests {
    private func pipeline(_ root: URL) throws -> StreamPipeline {
        StreamPipeline(tools: try #require(TestSupport.tools), folders: SessionFolders(root: root), host: "127.0.0.1")
    }

    /// Milestone 1's case: an MKV whose video is copied plays from the served URL.
    @Test func servesACopyModeMKVThatApplesPlayerAccepts() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = try await pipeline(root).start(.file(TestSupport.media("h264_ac3_51.mkv")))

        #expect(stream.title == "h264_ac3_51")
        #expect(stream.plan.videoAction == .copy(.h264))
        #expect(stream.url.lastPathComponent == "master.m3u8")
        #expect(stream.url.host == "127.0.0.1")
        let asset = AVURLAsset(url: stream.url)
        let playable = try await asset.load(.isPlayable)
        let folder = stream.session.folder

        await stream.stop()
        #expect(playable)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await #expect(throws: URLError.self) {
            _ = try await URLSession.shared.data(from: stream.url)
        }
    }

    @Test func unreadableFilesFailWithoutLeavingAFolder() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: MediaProbeError.self) {
            try await pipeline(root).start(.file(TestSupport.media("corrupt.mkv")))
        }
        await #expect(throws: PlanError.noVideoTrack) {
            try await pipeline(root).start(.file(TestSupport.media("audio_only.m4a")))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func cancellingTheStartLeavesNothingBehind() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try pipeline(root)
        let start = Task { try await pipeline.start(.file(TestSupport.media("vp9_opus.webm"))) }
        start.cancel()
        _ = try? await start.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

struct VideoFilesTests {
    @Test(arguments: ["Movie.mkv", "clip.MP4", "home.mov", "talk.webm", "show.m4v", "broadcast.ts", "old.avi",
                      "Movie: Part 1 (Director's Cut) é.mkv"])
    func acceptsVideo(_ name: String) {
        #expect(VideoFiles.isVideo(URL(fileURLWithPath: "/Movies/\(name)")))
    }

    @Test(arguments: ["song.mp3", "song.m4a", "Movie.srt", "cover.png", "notes.txt", "README", "Movie.mkv.part"])
    func rejectsEverythingElse(_ name: String) {
        #expect(!VideoFiles.isVideo(URL(fileURLWithPath: "/Movies/\(name)")))
    }

    /// Whether macOS calls `.mkv` a movie depends on which apps are installed (here it does, on a
    /// fresh Mac or CI runner it may not), so the containers ffmpeg reads are listed explicitly.
    @Test func knowsContainersMacOSMayNotDeclare() {
        for name in ["mkv", "webm", "avi", "ts", "m2ts", "flv", "wmv"] {
            #expect(VideoFiles.knownExtensions.contains(name), "\(name)")
        }
    }

    @Test func rejectsFoldersAndWebURLs() {
        #expect(!VideoFiles.isVideo(URL(fileURLWithPath: "/Movies/Season 1.mkv/", isDirectory: true)))
        #expect(!VideoFiles.isVideo(URL(string: "https://example.com/video.mp4")!))
    }

    @Test func openPanelsOfferMatroskaAndOrdinaryMovies() {
        let types = VideoFiles.contentTypes
        for name in ["mkv", "webm", "mp4", "mov"] {
            let type = UTType(filenameExtension: name)!
            #expect(types.contains { type.conforms(to: $0) }, "\(name)")
        }
        #expect(!types.contains { UTType.mp3.conforms(to: $0) })
    }

    @Test func keepsOnlyVideosInOrder() {
        let urls = ["b.mkv", "a.srt", "c.mp4"].map { URL(fileURLWithPath: "/Movies/\($0)") }
        #expect(VideoFiles.videos(in: urls).map(\.lastPathComponent) == ["b.mkv", "c.mp4"])
    }
}
