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

    /// A seek outside what's converted starts a new session there (spec §4.2).
    @Test func startsLaterInTheMovie() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try pipeline(root)
        let media = try await pipeline.probe(.file(TestSupport.media("h264_aac.mp4")))
        let stream = try await pipeline.start(media, at: 6)
        let duration = try await AVURLAsset(url: stream.url).load(.duration).seconds
        await stream.stop()
        #expect(abs(stream.session.offset - 6) < 0.05)
        #expect(abs(duration - 4) < 1)
    }

    @Test func switchesTheAudioTrack() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try pipeline(root)
        let media = try await pipeline.probe(.file(TestSupport.media("h264_multiaudio.mkv")))
        #expect(media.info.audio.map(\.displayName) == ["English (Stereo)", "Japanese (5.1)"])
        let byDefault = try await pipeline.start(media)
        await byDefault.stop()
        let english = try await pipeline.start(media, audio: media.info.audio[0].ref)
        await english.stop()
        #expect(byDefault.plan.audio == media.info.audio[1].ref) // the file's default
        #expect(english.plan.audio == media.info.audio[0].ref)
    }

    /// The file's own subtitles and a sidecar `.srt`, all offered at once.
    @Test func offersEmbeddedAndSidecarSubtitles() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        let movie = movies.appendingPathComponent("Movie: Part 1.mkv")
        try FileManager.default.createSymbolicLink(at: movie, withDestinationURL: TestSupport.media("h264_ac3_51.mkv"))
        try FileManager.default.copyItem(at: TestSupport.media("sample.srt"),
                                         to: movies.appendingPathComponent("Movie: Part 1.en.srt"))
        let pipeline = try pipeline(root.appendingPathComponent("sessions"))

        let media = try await pipeline.probe(.file(movie))
        #expect(media.subtitles.map(\.id) == ["track-0-2", "file-Movie: Part 1.en.srt"])
        let subtitles = try await pipeline.extractSubtitles(media)
        #expect(subtitles.files.count == 2)
        let stream = try await pipeline.start(media, subtitles: subtitles)
        let group = try #require(try await AVURLAsset(url: stream.url).loadMediaSelectionGroup(for: .legible))
        // AVFoundation names options by language; the playlist's NAME is their title.
        var titles: [String?] = []
        for option in group.options {
            let title = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
            titles.append(try await title.first?.load(.stringValue))
        }
        await stream.stop()
        subtitles.remove()

        #expect(stream.subtitleNames == ["track-0-2": "Subtitles", "file-Movie: Part 1.en.srt": "English — Movie: Part 1.en.srt"])
        #expect(titles == ["Subtitles", "English — Movie: Part 1.en.srt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path).isEmpty)
    }

    /// Subtitles not converted yet (or that couldn't be) aren't offered: the player would show
    /// an option that plays nothing.
    @Test func offersOnlyConvertedSubtitles() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try pipeline(root)
        let media = try await pipeline.probe(.file(TestSupport.media("h264_ac3_51.mkv")))
        let stream = try await pipeline.start(media, subtitles: SubtitleFiles(folder: root, files: [:]))
        await stream.stop()
        #expect(media.subtitles.count == 1)
        #expect(stream.subtitleNames.isEmpty)
    }

    /// A web stream's subtitles would mean downloading the whole video to extract them.
    @Test func convertsSubtitlesOfLocalFilesOnly() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let option = SubtitleOption(source: .embedded(TrackRef(index: 2)), language: "en", title: nil, isForced: false,
                                    isText: true)
        let web = PlaybackMedia(
            input: ResolvedInput(inputs: [.init(url: URL(string: "https://video.example/master.m3u8")!)], title: "Web"),
            info: MediaInfo(duration: 60, video: [], audio: [], subtitles: []), subtitles: [option])
        let files = try await pipeline(root).extractSubtitles(web)
        #expect(files.files.isEmpty)
    }

    @Test func burningInTextNeedsItsSubtitlesConverted() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try pipeline(root)
        let media = try await pipeline.probe(.file(TestSupport.media("h264_ac3_51.mkv")))
        await #expect(throws: SubtitleError.notConverted) {
            try await pipeline.start(media, burnIn: media.subtitles[0], subtitles: nil)
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
