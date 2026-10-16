import AVFoundation
import Foundation
import Testing
@testable import PaperPlaneCore

/// Transcoder behaviour with a scripted stand-in for ffmpeg, so timing and failures are exact.
struct TranscoderTests {
    static let plan = ConversionPlan(video: TrackRef(index: 0), videoAction: .copy(.h264),
                                     audio: TrackRef(index: 1), audioAction: .copy(.aac))
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

    // ffprobe packet lines are `pts_time,dts_time,flags`; D marks frames an edit list hides.

    @Test func aHiddenLeadInStartsAtTheFirstShownKeyframe() {
        let packets = """
            -2.500000,-2.566667,KD_
            -2.466667,-2.533333,_D_
            2.500000,2.433333,K__
            2.533333,2.466667,___
            """
        #expect(Transcoder.leadInStart(packets: packets) == .init(keyframe: 2.5, decodeTime: 2.433333))
    }

    @Test func aFileWithoutALeadInNeedsNoTrim() {
        #expect(Transcoder.leadInStart(packets: "0.000000,-0.066667,K__\n0.033333,-0.033333,___\n") == nil)
        #expect(Transcoder.leadInStart(packets: "") == nil)
    }

    @Test func aKeyframeDecodedBeforeZeroCannotBeKeptSoTheNextOneIsUsed() {
        // Trimming at a decode time at or before 0 would drop that keyframe too.
        let packets = """
            -1.000000,-1.066667,KD_
            0.040000,-0.026667,K__
            0.073333,0.006667,___
            5.000000,4.933333,K__
            """
        #expect(Transcoder.leadInStart(packets: packets) == .init(keyframe: 5, decodeTime: 4.933333))
    }

    @Test func aLeadInWithNoShownKeyframeInSightIsLeftAlone() {
        #expect(Transcoder.leadInStart(packets: "-1.000000,-1.066667,KD_\n-0.966667,-1.033333,_D_\n") == nil)
    }

    @Test func unreadableLinesAreSkipped() {
        let packets = "N/A,N/A,KD_\n-1.000000,-1.066667,KD_\ngarbage\n2.000000,1.933333,K__\n"
        #expect(Transcoder.leadInStart(packets: packets) == .init(keyframe: 2, decodeTime: 1.933333))
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

    // A TV lines up the first audio and the first video it receives, so copied video must not
    // start ahead of the audio. These tests read back what the session actually serves.

    @Test func copiedVideoAndAudioStartTogetherAfterASeek() async throws {
        // Keyframes every 5 s: a seek to 7 s starts the video at 5 s, so the audio must too.
        let source = TestSupport.media("h264_aac_longgop.mp4")
        let (session, _) = try await start("h264_aac_longgop.mp4", from: 7)
        #expect(abs(session.offset - 5) < 0.05)
        let served = try await ServedStream(session, source: source)
        #expect(served.firstVideoPacketIsKeyframe)
        #expect(served.isInSync, "\(served.description)")
        await session.stop()
    }

    @Test func aLosslessTrimsHiddenLeadInIsSkipped() async throws {
        // The edit list hides 2.5 s before the cut; the first keyframe the TV can show is at 2.5 s.
        let source = TestSupport.media("h264_aac_editlist.mp4")
        let (session, _) = try await start("h264_aac_editlist.mp4")
        #expect(abs(session.offset - 2.5) < 0.05)
        let served = try await ServedStream(session, source: source)
        #expect(served.firstVideoPacketIsKeyframe)
        #expect(served.isInSync, "\(served.description)")
        await session.stop()
    }

    @Test func aSeekBeforeTheFirstShownKeyframeAlsoSkipsTheLeadIn() async throws {
        // 1 s is before the first keyframe the TV can show (2.5 s), so it starts there too.
        let source = TestSupport.media("h264_aac_editlist.mp4")
        let (session, _) = try await start("h264_aac_editlist.mp4", from: 1)
        #expect(abs(session.offset - 2.5) < 0.05)
        let served = try await ServedStream(session, source: source)
        #expect(served.firstVideoPacketIsKeyframe)
        #expect(served.isInSync, "\(served.description)")
        await session.stop()
    }

    @Test func aSeekPastTheLeadInStartsAtTheKeyframeBeforeIt() async throws {
        let source = TestSupport.media("h264_aac_editlist.mp4")
        let (session, _) = try await start("h264_aac_editlist.mp4", from: 9)
        #expect(abs(session.offset - 7.5) < 0.05)
        let served = try await ServedStream(session, source: source)
        #expect(served.isInSync, "\(served.description)")
        await session.stop()
    }

    @Test func aPlainFileStillStartsAtZeroWithAudioAndVideoTogether() async throws {
        let source = TestSupport.media("h264_aac_longgop.mp4")
        let (session, _) = try await start("h264_aac_longgop.mp4")
        #expect(session.offset == 0)
        let served = try await ServedStream(session, source: source)
        #expect(served.firstVideoPacketIsKeyframe)
        #expect(served.video < 0.1)
        #expect(served.isInSync, "\(served.description)")
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
    /// without FRAME-RATE fails, so check the player really accepts SDR and HDR output. A Mac
    /// whose display can't show HDR (its main display an SDR monitor, say) refuses an HDR master
    /// whatever it says (-11868), and the app then opens the media playlist: that must play.
    @Test(arguments: ["h264_aac.mp4", "hevc_hdr10_aac.mkv", "vp9_opus.webm"])
    func applesPlayerAcceptsTheMasterPlaylist(_ file: String) async throws {
        let (session, _) = try await start(file)
        _ = await session.events.first { $0 == .finished }
        let server = try await HLSServer(directory: session.folder)
        var (status, error) = await TestSupport.playerItem(server.url("master.m3u8"))
        if (error as? AVError)?.code == .noCompatibleAlternatesForExternalDisplay {
            (status, error) = await TestSupport.playerItem(server.url("index.m3u8"))
        }
        let duration = try await AVURLAsset(url: server.url("master.m3u8")).load(.duration).seconds
        server.stop()
        await session.stop()
        #expect(status == .readyToPlay, "\(String(describing: error))")
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

/// What a session served, read back with ffprobe once ffmpeg has finished, against its source:
/// - `video` / `audio`: the earliest presentation time of each track.
/// - `endGap` / `sourceEndGap`: how much later the video ends than the audio, served and in the
///   source. They match unless one track's timestamps were shifted against the other.
/// - `firstVideoPacketIsKeyframe`: whether the TV can decode from the first packet.
struct ServedStream {
    var video: Double
    var audio: Double
    var endGap: Double
    var sourceEndGap: Double
    var firstVideoPacketIsKeyframe: Bool

    init(_ session: TranscodeSession, source: URL) async throws {
        for await event in session.events {
            if case .failed(let message) = event { Issue.record("ffmpeg failed: \(message)") }
        }
        let tools = try #require(TestSupport.tools)
        func packets(_ stream: String, of path: String) async throws -> [(pts: Double, duration: Double, flags: String)] {
            let result = try await ProcessRunner.run(tools.ffprobe, arguments: [
                "-v", "error", "-select_streams", stream, "-show_entries", "packet=pts_time,duration_time,flags",
                "-of", "csv=p=0", path,
            ])
            return String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
                let fields = $0.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 3, let pts = Double(fields[0]) else { return nil }
                return (pts, Double(fields[1]) ?? 0, String(fields[2]))
            }
        }
        func end(_ packets: [(pts: Double, duration: Double, flags: String)]) -> Double {
            packets.map { $0.pts + $0.duration }.max() ?? 0
        }
        let playlist = session.folder.appendingPathComponent("index.m3u8").path
        let video = try await packets("v:0", of: playlist)
        let audio = try await packets("a:0", of: playlist)
        self.video = try #require(video.prefix(8).map(\.pts).min())
        self.audio = try #require(audio.first?.pts)
        endGap = end(video) - end(audio)
        sourceEndGap = try await end(packets("v:0", of: source.path)) - end(packets("a:0", of: source.path))
        firstVideoPacketIsKeyframe = video.first?.flags.contains("K") ?? false
    }

    /// Both tracks start together (within a few B-frames) and neither was shifted.
    var isInSync: Bool { abs(video - audio) < 0.15 && abs(endGap - sourceEndGap) < 0.05 }
    var description: String {
        String(format: "video starts %.3f s, audio %.3f s; video ends %.3f s after audio (source: %.3f s)",
               video, audio, endGap, sourceEndGap)
    }
}
