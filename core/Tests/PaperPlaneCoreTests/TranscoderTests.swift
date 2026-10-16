import AVFoundation
import Foundation
import Testing
@testable import PaperPlaneCore

/// Transcoder behaviour with a scripted stand-in for ffmpeg, so timing and failures are exact.
struct TranscoderTests {
    static let plan = ConversionPlan(video: TrackRef(index: 0), videoAction: .copy(.h264),
                                     audio: TrackRef(index: 1), audioAction: .copy)
    static let input = ResolvedInput.file(URL(fileURLWithPath: "/Movies/movie.mkv"))

    @Test func returnsOnceTwoSegmentsAndTheMasterPlaylistExist() async throws {
        let fake = try FakeFFmpeg(segments: 5, interval: 0.1)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)

        let playlist = MediaPlaylist(parsing: try String(contentsOf: fake.output.appendingPathComponent("index.m3u8"),
                                                         encoding: .utf8))
        #expect(playlist.segments.count >= 2)
        let master = try String(contentsOf: fake.output.appendingPathComponent("master.m3u8"), encoding: .utf8)
        #expect(master.contains("#EXT-X-START:TIME-OFFSET=0"))
        #expect(master.contains("VIDEO-RANGE=SDR"))
        #expect(session.offset == 0)
        await session.stop()
    }

    @Test func reportsEverySegmentThenFinished() async throws {
        let fake = try FakeFFmpeg(segments: 4, interval: 0.05)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        var events: [TranscodeEvent] = []
        for await event in session.events {
            events.append(event)
        }
        #expect(events == [
            .segment(index: 0, end: 6), .segment(index: 1, end: 12), .segment(index: 2, end: 18),
            .segment(index: 3, end: 24), .finished,
        ])
        await session.stop()
    }

    @Test func shortVideoIsReadyWithOneSegment() async throws {
        let fake = try FakeFFmpeg(segments: 1, interval: 0.05)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        #expect(FileManager.default.fileExists(atPath: fake.output.appendingPathComponent("master.m3u8").path))
        await session.stop()
    }

    @Test func failureBeforeReadyThrowsARedactedErrorAndDeletesTheFolder() async throws {
        let fake = try FakeFFmpeg(segments: 0, interval: 0, exitStatus: 1,
                                  stderr: "Cookie: sid=SECRET\nhttps://cdn.test/v.m3u8?token=SECRET: Invalid data")
        defer { fake.remove() }
        await #expect(throws: TranscodeError.ffmpegFailed(
            status: 1, message: "Cookie: …\nhttps://cdn.test/v.m3u8?… Invalid data")) {
            try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        }
        #expect(!FileManager.default.fileExists(atPath: fake.output.path))
    }

    @Test func failureAfterReadyIsAnEvent() async throws {
        let fake = try FakeFFmpeg(segments: 3, interval: 0.05, exitStatus: 1, stderr: "Error while decoding stream #0:0")
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        var last: TranscodeEvent?
        for await event in session.events {
            last = event
        }
        #expect(last == .failed("Error while decoding stream #0:0"))
        await session.stop()
    }

    @Test func cancellingTheStartStopsFFmpegAndDeletesTheFolder() async throws {
        let fake = try FakeFFmpeg(segments: 1, interval: 30)
        defer { fake.remove() }
        let start = Task {
            try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        start.cancel()
        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(ContinuousClock.now - cancelledAt < .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: fake.output.path))
    }

    @Test func pauseHoldsFFmpegUntilResume() async throws {
        let fake = try FakeFFmpeg(segments: 100, interval: 0.1)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        session.pause()
        try await Task.sleep(for: .milliseconds(300)) // let a write in progress land
        let paused = try fake.segmentCount()
        try await Task.sleep(for: .milliseconds(800))
        #expect(try fake.segmentCount() == paused)

        session.resume()
        try await Task.sleep(for: .milliseconds(800))
        #expect(try fake.segmentCount() > paused)
        await session.stop()
    }

    @Test func stopEndsAPausedSessionAndDeletesTheFolder() async throws {
        let fake = try FakeFFmpeg(segments: 100, interval: 0.1)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        session.pause()
        let stoppedAt = ContinuousClock.now
        await session.stop()
        #expect(ContinuousClock.now - stoppedAt < .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: fake.output.path))
        await session.stop() // a second stop is harmless
    }

    @Test func readsTheFirstPacketTimeFromFramecrc() {
        let output = """
            #extradata 0:       45, 0x23bb0eb7
            #tb 0: 1/15360
            #media_type 0: video
            0,      -8704,      -7680,      512,     7977, 0xf707803e
            """
        #expect(Transcoder.firstPacketTime(framecrc: output) == -0.5)
        #expect(Transcoder.firstPacketTime(framecrc: "#tb 0: 1/1000\n") == nil)
        #expect(Transcoder.firstPacketTime(framecrc: "0, 1, 2, 3, 4\n") == nil)
    }
}

/// Converting real test media with the real ffmpeg.
@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct TranscoderMediaTests {
    /// The Sony's profile, spelled out so these tests don't move if the default changes.
    static let stereoHDR = OutputProfile(surround: false, hdr: true)

    private func start(_ file: String, from start: Double = 0, profile: OutputProfile = stereoHDR) async throws
        -> (session: TranscodeSession, master: String) {
        let tools = try #require(TestSupport.tools)
        let input = ResolvedInput.file(TestSupport.media(file))
        let plan = try ConversionPlanner.plan(try await MediaProbe(tools: tools).probe(input), profile: profile)
        let folder = try SessionFolders(root: TestSupport.makeTemporaryDirectory()).create()
        let session = try await Transcoder(tools: tools).start(plan, input: input, from: start, in: folder)
        let master = try String(contentsOf: folder.appendingPathComponent("master.m3u8"), encoding: .utf8)
        return (session, master)
    }

    @Test func copiedVideoStartsAtTheKeyframeBeforeTheRequestedTime() async throws {
        // The test clips have a keyframe every second.
        let (session, _) = try await start("h264_aac.mp4", from: 4.5)
        #expect(session.requestedStart == 4.5)
        #expect(abs(session.offset - 4.0) < 0.05)
        await session.stop()
    }

    @Test func reencodedVideoStartsExactlyAtTheRequestedTime() async throws {
        let (session, _) = try await start("vp9_opus.webm", from: 4.5)
        #expect(session.offset == 4.5)
        await session.stop()
    }

    @Test(arguments: [
        ("h264_aac.mp4", #"CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30.000,VIDEO-RANGE=SDR"#),
        ("hevc_hdr10_aac.mkv", #"CODECS="hvc1.2.4.L93.90,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30.000,VIDEO-RANGE=PQ"#),
        ("h264_ac3_51.mkv", #"CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30.000,VIDEO-RANGE=SDR"#),
    ])
    func masterPlaylistDescribesTheOutput(file: String, attributes: String) async throws {
        let (session, master) = try await start(file)
        #expect(master.contains(attributes), "\(master)")
        await session.stop()
    }

    @Test func surroundTVGetsDolbyCodecs() async throws {
        let (session, master) = try await start("hevc_eac3_51.mkv", profile: OutputProfile(surround: true, hdr: true))
        #expect(master.contains(#"CODECS="hvc1.1.6.L93.90,ec-3""#), "\(master)")
        await session.stop()
    }

    /// AVFoundation is stricter about master playlists than media playlists: an HDR variant
    /// without FRAME-RATE fails, so check the player really accepts SDR and HDR output.
    @Test(arguments: ["h264_aac.mp4", "hevc_hdr10_aac.mkv", "vp9_opus.webm"])
    func applesPlayerAcceptsTheMasterPlaylist(_ file: String) async throws {
        let (session, _) = try await start(file)
        _ = await session.events.first { $0 == .finished }
        let server = try await HLSServer(directory: session.folder)
        let status = await TestSupport.playerItemStatus(server.url("master.m3u8"))
        let duration = try await AVURLAsset(url: server.url("master.m3u8")).load(.duration).seconds
        server.stop()
        await session.stop()
        #expect(status == .readyToPlay)
        #expect(abs(duration - 10) < 1.5)
    }
}

struct SessionFoldersTests {
    @Test func createsFreshFoldersAndRemovesThemAll() throws {
        let root = try TestSupport.makeTemporaryDirectory().appendingPathComponent("sessions")
        let folders = SessionFolders(root: root)
        let first = try folders.create()
        let second = try folders.create()
        #expect(first != second)
        #expect(first.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        try folders.removeAll()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try folders.removeAll() // nothing there: no error
    }

    @Test func standardFolderIsInCaches() {
        #expect(SessionFolders.standard.root.path.hasSuffix("/Library/Caches/Paper Plane/sessions"))
    }
}

/// A shell script that behaves like ffmpeg writing HLS: it writes `segments` segments into the
/// folder given as its last argument, one every `interval` seconds, then exits with `exitStatus`.
/// For the keyframe probe (last argument `-`) it prints a framecrc line. Like ffmpeg, it handles
/// SIGTERM itself, so while it is stopped (SIGSTOP) a SIGTERM waits until SIGCONT.
struct FakeFFmpeg {
    let directory: URL
    let output: URL
    let tools: ToolPaths

    init(segments: Int, interval: Double, exitStatus: Int32 = 0, stderr: String = "") throws {
        directory = try TestSupport.makeTemporaryDirectory()
        output = directory.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            trap 'exit 255' TERM
            for last; do :; done
            if [ "$last" = "-" ]; then printf '#tb 0: 1/1000\\n0, -567, -500, 33, 6681, 0x0\\n'; exit 0; fi
            dir=$(dirname "$last")
            printf 'not really an mp4' > "$dir/init.mp4"
            list='#EXTM3U\\n#EXT-X-MAP:URI="init.mp4"\\n'
            i=0
            while [ $i -lt \(segments) ]; do
              sleep \(interval) & wait $!
              name=$(printf 'seg_%05d.m4s' $i)
              printf 'segment' > "$dir/$name"
              list="$list#EXTINF:6.000000,\\n$name\\n"
              printf "$list" > "$dir/index.tmp" && mv "$dir/index.tmp" "$last"
              i=$((i + 1))
            done
            [ \(segments) -gt 0 ] && printf "$list#EXT-X-ENDLIST\\n" > "$dir/index.tmp" && mv "$dir/index.tmp" "$last"
            printf '%s\\n' '\(stderr)' >&2
            exit \(exitStatus)
            """
        let ffmpeg = directory.appendingPathComponent("ffmpeg")
        try Data(script.utf8).write(to: ffmpeg)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
        tools = ToolPaths(ffmpeg: ffmpeg, ffprobe: URL(fileURLWithPath: "/usr/bin/false"))
    }

    func segmentCount() throws -> Int {
        let text = try String(contentsOf: output.appendingPathComponent("index.m3u8"), encoding: .utf8)
        return MediaPlaylist(parsing: text).segments.count
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
