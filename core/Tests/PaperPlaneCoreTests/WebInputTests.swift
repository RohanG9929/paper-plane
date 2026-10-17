import Foundation
import Testing
@testable import PaperPlaneCore

/// Streams from the browser (spec §5.3): served locally by scripts/serve-hls.py, whose
/// `/cookie/<name>=<value>/…` paths need that cookie and `/status/<code>/…` paths answer with
/// that status, as a site would.
@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct WebInputTests {
    static func web(_ url: URL, cookie: String? = nil) -> ResolvedInput {
        ResolvedInput(inputs: [.init(url: url, headers: cookie.map { ["Cookie": $0] } ?? [:])], title: "Web")
    }

    @Test func probesAndConvertsAStreamThatNeedsItsCookie() async throws {
        let tools = try #require(TestSupport.tools)
        let server = try await HLSServer(directory: TestSupport.mediaDirectory)
        defer { server.stop() }
        let input = Self.web(server.url("cookie/pp=1/h264_aac.mp4"), cookie: "pp=1")
        let pipeline = StreamPipeline(tools: tools, folders: SessionFolders(root: try TestSupport.makeTemporaryDirectory()),
                                      profile: .default, host: "127.0.0.1")
        let media = try await pipeline.probe(input)
        #expect(media.info.video.count == 1)
        let stream = try await pipeline.start(media, at: 2)
        await stream.stop()
    }

    /// Most sites' HLS is MPEG-TS segments with ADTS AAC, which is copied, not re-encoded.
    @Test func convertsAnHLSStreamOfMPEGTSSegments() async throws {
        let tools = try #require(TestSupport.tools)
        let server = try await HLSServer(directory: try await Self.makeHLS(live: false))
        defer { server.stop() }
        let pipeline = StreamPipeline(tools: tools, folders: SessionFolders(root: try TestSupport.makeTemporaryDirectory()),
                                      profile: .default, host: "127.0.0.1")
        let media = try await pipeline.probe(Self.web(server.url("index.m3u8")))
        let stream = try await pipeline.start(media, at: 0)
        #expect(stream.plan.audioAction == .copy(.aac))
        await stream.stop()
    }

    /// A site's master playlist lists its cheapest variant first; the TV gets the best one.
    @Test func playsTheBestVariantOfAMasterPlaylist() async throws {
        let tools = try #require(TestSupport.tools)
        let folder = try await Self.makeHLS(live: false)
        let master = ["#EXTM3U",
                      "#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=1280x720", "index.m3u8",
                      "#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720", "copy.m3u8"]
        try master.joined(separator: "\n").write(to: folder.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("index.m3u8"), to: folder.appendingPathComponent("copy.m3u8"))
        let server = try await HLSServer(directory: folder)
        defer { server.stop() }
        let pipeline = StreamPipeline(tools: tools, folders: SessionFolders(root: try TestSupport.makeTemporaryDirectory()),
                                      profile: .default, host: "127.0.0.1")
        let media = try await pipeline.probe(Self.web(server.url("master.m3u8")))
        #expect(media.info.video.map(\.variant) == [3_000_000])
        #expect(media.info.audio.map(\.variant) == [3_000_000])
        let stream = try await pipeline.start(media, at: 0)
        #expect(stream.plan.video == media.info.video.first?.ref)
        await stream.stop()
    }

    /// Plenty of sites name segments without a media extension, which ffmpeg 9 refuses unless told.
    @Test func readsSegmentsNamedAnything() async throws {
        let tools = try #require(TestSupport.tools)
        let folder = try await Self.makeHLS(live: false)
        var playlist = try String(contentsOf: folder.appendingPathComponent("index.m3u8"), encoding: .utf8)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".ts") {
            let bare = String(name.dropLast(3))
            try FileManager.default.moveItem(at: folder.appendingPathComponent(name), to: folder.appendingPathComponent(bare))
            playlist = playlist.replacingOccurrences(of: name, with: bare)
        }
        try playlist.write(to: folder.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
        let server = try await HLSServer(directory: folder)
        defer { server.stop() }
        let input = ResolvedInput(inputs: [.init(url: server.url("index.m3u8"), manifest: .hls)], title: "Web")
        let info = try await MediaProbe(tools: tools).probe(input)
        #expect(info.video.count == 1)
    }

    /// A DASH manifest is one input: every representation, and the audio. The TV gets the one
    /// Apple plays as it is (not the Hi10P one), with its sound.
    @Test(.enabled("Needs an ffmpeg built with libxml2 (DASH)") { await TestSupport.ffmpegHasDemuxer("dash") })
    func aDashStreamPlaysWithAudio() async throws {
        let tools = try #require(TestSupport.tools)
        let server = try await HLSServer(directory: try await Self.makeDASH())
        defer { server.stop() }
        let pipeline = StreamPipeline(tools: tools, folders: SessionFolders(root: try TestSupport.makeTemporaryDirectory()),
                                      profile: .default, host: "127.0.0.1")
        let input = ResolvedInput(inputs: [.init(url: server.url("index.mpd"), manifest: .dash)], title: "Web")
        let media = try await pipeline.probe(input)
        #expect(media.info.video.map(\.pixelFormat) == ["yuv420p"])
        #expect(media.info.audio.map(\.codec) == [.aac])
        let stream = try await pipeline.start(media, at: 0)
        #expect(stream.plan.videoAction == .copy(.h264))
        #expect(stream.plan.audioAction == .copy(.aac))
        #expect(await TestSupport.playerItemStatus(stream.url) == .readyToPlay)
        // What the TV is given has both tracks.
        let served = try await MediaProbe(tools: tools).probe(ResolvedInput(inputs: [.init(url: stream.mediaPlaylistURL)], title: ""))
        #expect(served.video.count == 1)
        #expect(served.audio.count == 1)
        await stream.stop()
    }

    /// A DASH manifest of CENC-encrypted video has no key to give ffmpeg, which would copy the
    /// samples through as noise: the probe refuses it, at once.
    @Test(.enabled("Needs an ffmpeg built with libxml2 (DASH)") { await TestSupport.ffmpegHasDemuxer("dash") },
          .timeLimit(.minutes(1)))
    func anEncryptedDashStreamIsRefusedAtOnce() async throws {
        let tools = try #require(TestSupport.tools)
        let server = try await HLSServer(directory: try await Self.makeDASH(encrypted: true))
        defer { server.stop() }
        let input = ResolvedInput(inputs: [.init(url: server.url("index.mpd"), manifest: .dash)], title: "Web")
        await #expect(throws: MediaProbeError.protectedContent) {
            try await MediaProbe(tools: tools).probe(input)
        }
    }

    /// Spec §6: a site that refuses the stream (an expired link or a missing cookie).
    @Test(arguments: ["status/403/h264_aac.mp4", "status/410/h264_aac.mp4", "status/401/h264_aac.mp4",
                      "status/404/h264_aac.mp4", "cookie/pp=1/h264_aac.mp4"])
    func recognisesASiteRefusingTheStream(_ path: String) async throws {
        let tools = try #require(TestSupport.tools)
        let server = try await HLSServer(directory: TestSupport.mediaDirectory)
        defer { server.stop() }
        do {
            _ = try await MediaProbe(tools: tools).probe(Self.web(server.url(path)))
            Issue.record("probed a refused stream")
        } catch {
            #expect(SiteRefusal.isRefusal(error), "\(error)")
        }
    }

    @Test func aMissingFileIsNotARefusal() {
        let error = MediaProbeError.ffprobeFailed(status: 1, message: "/Movies/a.mkv: No such file or directory")
        #expect(!SiteRefusal.isRefusal(error))
    }

    /// Spec §5.3: an HLS playlist without #EXT-X-ENDLIST is live, and has no duration.
    @Test func aLivePlaylistHasNoDuration() async throws {
        let tools = try #require(TestSupport.tools)
        let folder = try await Self.makeHLS(live: true)
        let server = try await HLSServer(directory: folder)
        defer { server.stop() }
        let info = try await MediaProbe(tools: tools).probe(Self.web(server.url("index.m3u8")))
        #expect(info.duration == nil)
        #expect(info.video.count == 1)
    }

    /// ffmpeg already refuses file: under a web playlist; the explicit list keeps it that way and
    /// shuts out udp: and rtp: too.
    @Test func aWebPlaylistCantReadLocalFiles() async throws {
        let tools = try #require(TestSupport.tools)
        let folder = try await Self.makeHLS(live: false)
        let segments = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".ts") }.sorted()
        let web = try TestSupport.makeTemporaryDirectory()
        let playlist = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:3"]
            + segments.flatMap { ["#EXTINF:2.0,", folder.appendingPathComponent($0).absoluteString] }
            + ["#EXT-X-ENDLIST"]
        try playlist.joined(separator: "\n").write(to: web.appendingPathComponent("local.m3u8"), atomically: true, encoding: .utf8)
        let server = try await HLSServer(directory: web)
        defer { server.stop() }
        await #expect(throws: MediaProbeError.self) {
            try await MediaProbe(tools: tools).probe(Self.web(server.url("local.m3u8")))
        }
    }

    /// The 10-second test clip as a DASH manifest of 2-second fMP4 segments, copied rather than
    /// encoded (so any ffmpeg can make it): one AdaptationSet of two video representations, 8-bit
    /// H.264 and 10-bit H.264, and one of AAC audio, as a site's manifest lists them. `encrypted`
    /// encrypts it with CENC (AES-CTR) under a key nothing here has.
    static func makeDASH(encrypted: Bool = false) async throws -> URL {
        let tools = try #require(TestSupport.tools)
        let folder = try TestSupport.makeTemporaryDirectory()
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-i", TestSupport.media("h264_10bit_aac.mkv").path,
            "-i", TestSupport.media("h264_aac.mp4").path, "-map", "0:v", "-map", "1:v", "-map", "1:a", "-c", "copy",
            "-f", "dash", "-seg_duration", "2", "-adaptation_sets", "id=0,streams=v id=1,streams=a",
        ]
        if encrypted {
            arguments += ["-format_options", "encryption_scheme=cenc-aes-ctr:encryption_key=76a6c65c5ea762046bd749a2e632ccbb"
                + ":encryption_kid=a7e61c373e219033c21091fa607bf3b8"]
        }
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: arguments + [folder.appendingPathComponent("index.mpd").path])
        try #require(result.status == 0, "ffmpeg failed: \(String(decoding: result.stderr, as: UTF8.self))")
        return folder
    }

    /// The 10-second test clip as 2-second MPEG-TS segments; `live` leaves out #EXT-X-ENDLIST.
    static func makeHLS(live: Bool) async throws -> URL {
        let tools = try #require(TestSupport.tools)
        let folder = try TestSupport.makeTemporaryDirectory()
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-i", TestSupport.media("h264_aac.mp4").path, "-c", "copy",
            "-f", "hls", "-hls_time", "2", "-hls_list_size", "0", "-hls_segment_type", "mpegts",
            "-hls_segment_filename", folder.appendingPathComponent("seg%d.ts").path,
            folder.appendingPathComponent("index.m3u8").path,
        ])
        try #require(result.status == 0)
        if live {
            let playlist = folder.appendingPathComponent("index.m3u8")
            let text = try String(contentsOf: playlist, encoding: .utf8)
                .split(separator: "\n").filter { !$0.hasPrefix("#EXT-X-ENDLIST") && !$0.hasPrefix("#EXT-X-PLAYLIST-TYPE") }
            try text.joined(separator: "\n").write(to: playlist, atomically: true, encoding: .utf8)
        }
        return folder
    }
}
