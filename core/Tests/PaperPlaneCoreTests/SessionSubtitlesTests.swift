import AVFoundation
import Foundation
import Testing
@testable import PaperPlaneCore

/// Subtitles in real sessions, with the real ffmpeg.
@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct SessionSubtitlesTests {
    static let profile = OutputProfile(surround: false, hdr: true)

    /// A WebVTT file on the movie's timeline, as SubtitleExtractor makes them.
    private static func movieSubtitles(_ cues: String) throws -> URL {
        let file = try TestSupport.makeTemporaryDirectory().appendingPathComponent("movie.vtt")
        try ("WEBVTT\n\n" + cues).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func start(_ file: String, from start: Double = 0, burnIn: BurnIn? = nil,
                              subtitles: SessionSubtitles) async throws -> TranscodeSession {
        let tools = try #require(TestSupport.tools)
        let input = ResolvedInput.file(TestSupport.media(file))
        let plan = try ConversionPlanner.plan(try await MediaProbe(tools: tools).probe(input),
                                              choice: TrackChoice(burnIn: burnIn), profile: profile)
        let folder = try SessionFolders(root: TestSupport.makeTemporaryDirectory()).create()
        return try await Transcoder(tools: tools).start(plan, input: input, from: start, in: folder,
                                                        subtitles: subtitles)
    }

    @Test func offersSubtitlesMovedToTheSessionsStart() async throws {
        let movie = try Self.movieSubtitles("00:01.000 --> 00:04.000\nOne\n\n00:05.000 --> 00:08.000\nTwo\n")
        let subtitles = SessionSubtitles(
            tracks: [SessionSubtitles.Track(name: "English", language: "eng", isForced: false, file: movie)],
            duration: 10)
        // Copied video with a keyframe every second: the session starts at exactly 3 s.
        let session = try await Self.start("h264_aac.mp4", from: 3, subtitles: subtitles)
        let folder = session.folder
        let master = try String(contentsOf: folder.appendingPathComponent("master.m3u8"), encoding: .utf8)

        #expect(session.subtitleNames == ["English"])
        #expect(master.contains(#"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en","#))
        #expect(master.contains(#",SUBTITLES="subs""#))
        #expect(try String(contentsOf: folder.appendingPathComponent("sub_0.vtt"), encoding: .utf8) == """
            WEBVTT

            00:00:00.000 --> 00:00:01.000
            One

            00:00:02.000 --> 00:00:05.000
            Two

            """)
        #expect(try String(contentsOf: folder.appendingPathComponent("sub_0.m3u8"), encoding: .utf8)
            .contains("#EXTINF:7.000,\nsub_0.vtt"))

        _ = await session.events.first { $0 == .finished }
        let server = try await HLSServer(directory: folder)
        let asset = AVURLAsset(url: server.url("master.m3u8"))
        let group = try await asset.loadMediaSelectionGroup(for: .legible)
        let status = await TestSupport.playerItemStatus(server.url("master.m3u8"))
        server.stop()
        await session.stop()
        #expect(group?.options.map(\.displayName) == ["English"])
        #expect(status == .readyToPlay)
    }

    @Test func aMissingSubtitleFileIsLeftOut() async throws {
        let subtitles = SessionSubtitles(tracks: [
            SessionSubtitles.Track(name: "Gone", language: nil, isForced: false,
                                   file: URL(fileURLWithPath: "/nonexistent/x.vtt")),
        ])
        let session = try await Self.start("h264_aac.mp4", subtitles: subtitles)
        let master = try String(contentsOf: session.folder.appendingPathComponent("master.m3u8"), encoding: .utf8)
        await session.stop()
        #expect(session.subtitleNames.isEmpty)
        #expect(!master.contains("SUBTITLES"))
    }

    /// The same re-encoded clip with and without burned-in text: only the bottom of the picture,
    /// where the text goes, differs.
    @Test(.enabled("Needs an ffmpeg built with libass, like the bundled one") {
        await TestSupport.ffmpegHasFilter("subtitles")
    })
    func burnsInTextSubtitles() async throws {
        let movie = try Self.movieSubtitles("00:00.000 --> 00:10.000\nPAPER PLANE PAPER PLANE\n")
        let plain = try await Self.start("vp9_opus.webm", subtitles: SessionSubtitles())
        let burned = try await Self.start("vp9_opus.webm", burnIn: .text, subtitles: SessionSubtitles(burnIn: movie))
        _ = await plain.events.first { $0 == .finished }
        _ = await burned.events.first { $0 == .finished }
        let plainFrame = try await Self.grayFrame(at: 2, in: plain.folder)
        let burnedFrame = try await Self.grayFrame(at: 2, in: burned.folder)
        await plain.stop()
        await burned.stop()

        let rows = 36, width = 64
        func difference(_ range: Range<Int>) -> Int {
            range.flatMap { row in (0..<width).map { row * width + $0 } }
                .reduce(0) { $0 + abs(Int(plainFrame[$1]) - Int(burnedFrame[$1])) }
        }
        let top = difference(0..<(rows / 3))
        let bottom = difference((rows * 2 / 3)..<rows)
        #expect(bottom > top * 5 + 500, "bottom \(bottom), top \(top)")
    }

    @Test func deletesTheSegmentsItIsTold() async throws {
        let session = try await Self.start("h264_aac.mp4", subtitles: SessionSubtitles())
        _ = await session.events.first { $0 == .finished }
        let first = SegmentWindow.Segment(index: 0, start: 0, end: 6)
        session.delete([first])
        #expect(!FileManager.default.fileExists(atPath: session.folder.appendingPathComponent("seg_00000.m4s").path))
        #expect(FileManager.default.fileExists(atPath: session.folder.appendingPathComponent("seg_00001.m4s").path))
        await session.stop()
    }

    /// A 64×36 greyscale frame `seconds` into a session's output.
    private static func grayFrame(at seconds: Double, in folder: URL) async throws -> [UInt8] {
        let tools = try #require(TestSupport.tools)
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-i", folder.appendingPathComponent("index.m3u8").path,
            "-ss", String(seconds), "-frames:v", "1", "-vf", "scale=64:36,format=gray", "-f", "rawvideo", "-",
        ])
        try #require(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        try #require(result.stdout.count == 64 * 36)
        return Array(result.stdout)
    }
}
