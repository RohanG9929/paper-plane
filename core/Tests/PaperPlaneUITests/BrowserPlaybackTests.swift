import Foundation
import os
@testable import PaperPlaneCore
import Testing
@testable import PaperPlaneUI

/// Videos sent from the browser (spec §5.3), from scripts/serve-hls.py acting as a site: its
/// `/cookie/<name>=<value>/…` paths need that cookie and `/status/<code>/…` paths refuse.
@MainActor
@Suite(.enabled(if: UITestMedia.available, "Needs ffmpeg and scripts/make-test-media.sh"))
struct BrowserPlaybackTests {
    static let refused = "The site stopped the stream — reload the page, then click Paper Plane again."

    static func request(_ url: URL, kind: String = "stream", format: String = "progressive", cookie: String? = nil,
                        startAt: Double = 0, title: String = "A film") throws -> PlayRequest {
        var source: [String: Any] = ["kind": kind, "url": url.absoluteString]
        if kind == "stream" {
            source["format"] = format
        }
        if let cookie {
            source["headers"] = ["Cookie": cookie]
        }
        let message: [String: Any] = ["type": "play", "v": 1, "source": source, "title": title, "startAt": startAt]
        return try PlayRequest.decode(JSONSerialization.data(withJSONObject: message))
    }

    static func controller(_ environment: PlaybackController.Environment) -> PlaybackController {
        let controller = PlaybackController(environment: environment, showsWelcome: true, welcomeSeen: {})
        controller.player.isMuted = true
        return controller
    }

    /// The reply waits until the video is ready for the TV, so the browser pauses only once
    /// Paper Plane has it (spec §5.1).
    @Test func aBrowserStreamIsAnsweredOnceItIsReadyForTheTV() async throws {
        let server = try await UITestServer(directory: UITestMedia.file(""))
        defer { server.stop() }
        let thumbnails = OSAllocatedUnfairLock(initialState: 0)
        var environment = try PlaybackControllerMediaTests.environment()
        environment.thumbnail = { _, _, _ in
            thumbnails.withLock { $0 += 1 }
            return nil
        }
        let controller = Self.controller(environment)
        let reply = await controller.play(try Self.request(server.url("cookie/pp=1/h264_aac.mp4"), cookie: "pp=1", startAt: 4))
        #expect(reply == .ok)
        #expect(controller.phase == .waitingForTV)
        #expect(controller.title == "A film")
        #expect(!controller.showsWelcome)
        #expect(abs((controller.stream?.session.offset ?? 0) - 4) < 0.05) // where the browser had got to
        #expect(!controller.remoteState.isLive)
        #expect(thumbnails.withLock { $0 } == 0) // nothing more is fetched from the site than playing needs
        await controller.shutDown()
    }

    @Test func aSiteThatRefusesTheStreamIsNamed() async throws {
        let server = try await UITestServer(directory: UITestMedia.file(""))
        defer { server.stop() }
        let controller = Self.controller(try PlaybackControllerMediaTests.environment())
        let reply = await controller.play(try Self.request(server.url("status/403/h264_aac.mp4")))
        #expect(reply == .failed(Self.refused))
        #expect(controller.phase == .failed(Self.refused))
        await controller.shutDown()
    }

    /// A link that expires while converting: ffmpeg skips the segments it's refused and finishes
    /// early without a word, so Paper Plane says why the video will end there.
    @Test func aSiteThatRefusesTheRestPartWayIsNamed() async throws {
        let folder = try await UITestServer.liveHLS()
        let playlist = folder.appendingPathComponent("index.m3u8")
        let text = try String(contentsOf: playlist, encoding: .utf8).replacingOccurrences(of: "seg2.ts", with: "status/403/seg2.ts")
        try (text + "\n#EXT-X-ENDLIST\n").write(to: playlist, atomically: true, encoding: .utf8)
        let server = try await UITestServer(directory: folder)
        defer { server.stop() }
        let controller = Self.controller(try PlaybackControllerMediaTests.environment())
        #expect(await controller.play(try Self.request(server.url("index.m3u8"), format: "hls")) == .ok)
        await PlaybackControllerTests.eventually { controller.conversionFinished }
        #expect(controller.notice == "The site stopped sending this video part-way through. Reload the page, then click Paper Plane again for the rest.")
        #expect((controller.convertedEnd ?? 0) < 25) // not claimed as converted to the end
        await controller.shutDown()
    }

    /// A site's DASH manifest through the proxy and the real ffmpeg, as the extension sends it:
    /// the TV gets one representation, copied, with its sound.
    @Test(.enabled("Needs an ffmpeg built with libxml2 (DASH)") { await UITestMedia.ffmpegHasDemuxer("dash") })
    func aDashStreamPlaysThroughTheProxyWithAudio() async throws {
        let server = try await UITestServer(directory: try await UITestServer.dash())
        defer { server.stop() }
        let controller = Self.controller(try PlaybackControllerMediaTests.environment())
        let reply = await controller.play(try Self.request(server.url("index.mpd"), format: "dash"))
        #expect(reply == .ok)
        #expect(controller.phase == .waitingForTV)
        #expect(controller.detail == "720p · 10 s")
        let plan = try #require(controller.stream?.plan)
        #expect(plan.videoAction == .copy(.h264))
        #expect(plan.audioAction == .copy(.aac))
        #expect(controller.audioTracks.count == 1)
        await PlaybackControllerTests.eventually { controller.player.currentItem?.status == .readyToPlay }
        #expect(controller.player.currentItem?.status == .readyToPlay)
        await controller.shutDown()
    }

    /// A DASH manifest ffmpeg can't decrypt (CENC, no key) fails plainly: the browser is told, and
    /// the controller is left failed, rather than passing the TV samples that are only noise.
    @Test(.enabled("Needs an ffmpeg built with libxml2 (DASH)") { await UITestMedia.ffmpegHasDemuxer("dash") },
          .timeLimit(.minutes(1)))
    func anEncryptedManifestFailsClearly() async throws {
        let server = try await UITestServer(directory: try await UITestServer.dash(encrypted: true))
        defer { server.stop() }
        let controller = Self.controller(try PlaybackControllerMediaTests.environment())
        let reply = await controller.play(try Self.request(server.url("index.mpd"), format: "dash"))
        guard case .failed(let message) = reply else {
            Issue.record("an encrypted stream was taken: \(reply)")
            return
        }
        #expect(message == "This video is protected, so Paper Plane can't play it.")
        #expect(message == PlaybackError.message(for: MediaProbeError.protectedContent, origin: .browser))
        #expect(controller.phase == .failed(message))
        await controller.shutDown()
    }

    /// A link that expires while the video plays stops ffmpeg part-way through.
    @Test func aSiteThatStopsPartWayThroughIsNamedToo() {
        let refused = ConversionStopped(message: "[https @ 0x1] Server returned 403 Forbidden (access denied)")
        #expect(PlaybackError.message(for: refused, origin: .browser) == Self.refused)
        #expect(PlaybackError.message(for: ConversionStopped(message: "Invalid data found when processing input"))
            == "Converting the video stopped part-way through.")
    }

    @Test func aNewerVideoTakesOverAnUnansweredRequest() async throws {
        let server = try await UITestServer(directory: UITestMedia.file(""))
        defer { server.stop() }
        var environment = try PlaybackControllerMediaTests.environment()
        environment.probe = { pipeline, input in
            try await Task.sleep(for: .seconds(2))
            return try await pipeline.probe(input)
        }
        let controller = Self.controller(environment)
        let request = try Self.request(server.url("h264_aac.mp4"))
        let first = Task { await controller.play(request) }
        try await Task.sleep(for: .milliseconds(200))
        controller.play([UITestMedia.file("h264_aac.mp4")])
        #expect(await first.value == .failed("Another video took its place."))
        // Stopped from the remote before it was ready: the browser hears so.
        let second = Task { await controller.play(request) }
        try await Task.sleep(for: .milliseconds(200))
        controller.stop()
        #expect(await second.value == .failed("Stopped in Paper Plane."))
        await controller.shutDown()
    }

    /// Spec §5.3: a live stream starts at its live edge, can't be sought, and its conversion is
    /// never rested (addendum M3-15, M3-16).
    @Test func aLiveStreamPlaysLive() async throws {
        let folder = try await UITestServer.liveHLS()
        let server = try await UITestServer(directory: folder)
        defer { server.stop() }
        let failure = OSAllocatedUnfairLock(initialState: "")
        let controller = Self.controller(try PlaybackControllerMediaTests.environment(freeSpace: { 1_500_000_000 },
                                                                                       saveLog: { _, error in
            failure.withLock { $0 = "\(error)" }
            return nil
        }))
        let reply = await controller.play(try Self.request(server.url("index.m3u8"), format: "hls", startAt: 30))
        #expect(reply == .ok, "\(failure.withLock { $0 })")
        #expect(controller.remoteState.isLive)
        #expect(controller.stream?.session.offset == 0)

        controller.externalPlaybackChanged(active: true)
        controller.seek(toMovieTime: 5)
        #expect(controller.loading == nil) // nothing to seek in
        let nowPlaying = NowPlaying(controller: controller)
        #expect(!nowPlaying.handle(.skip(10)) && !nowPlaying.handle(.seek(to: 5))) // nor for the media keys
        #expect(nowPlaying.handle(.togglePlayPause))
        nowPlaying.handle(.togglePlayPause)
        // A new session (a network change, another audio track) starts at the live edge too,
        // not as far into the stream as the clock has run.
        controller.movieTime = 25
        controller.restart(at: nil, loading: "Reconnecting…")
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(controller.stream?.session.offset == 0)
        controller.segments = (0..<300).map { SegmentWindow.Segment(index: $0, start: Double($0) * 6, end: Double($0 + 1) * 6) }
        controller.movieTime = 400
        controller.manageWindow()
        #expect(!controller.conversionPaused)
        #expect(controller.segments.first?.index == 16) // what ended over 5 minutes ago is deleted
        // Low on space, it can't keep less ahead, and doesn't claim to.
        #expect(controller.notice == "Your Mac is low on disk space, so a long video may stop part-way through.")
        await controller.shutDown()
    }
}

/// Runs scripts/serve-hls.py on a random local port for the duration of a test.
final class UITestServer {
    private let process = Process()
    let port: Int

    init(directory: URL) async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", UITestMedia.repoRoot.appendingPathComponent("scripts/serve-hls.py").path,
                             directory.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        var found: Int?
        for try await line in stdout.fileHandleForReading.bytes.lines {
            if line.hasPrefix("PORT "), let port = Int(line.dropFirst(5)) {
                found = port
                break
            }
        }
        port = try #require(found, "serve-hls.py didn't report a port")
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    func stop() {
        process.terminate()
    }

    /// The 10-second test clip as a DASH manifest (`index.mpd`) of 2-second fMP4 segments, copied,
    /// not encoded: two video representations (8-bit and 10-bit H.264) and AAC audio. `encrypted`
    /// encrypts it with CENC (AES-CTR) under a key nothing here has.
    static func dash(encrypted: Bool = false) async throws -> URL {
        let tools = try #require(ToolPaths.locate())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pp-dash-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-i", UITestMedia.file("h264_10bit_aac.mkv").path,
            "-i", UITestMedia.file("h264_aac.mp4").path, "-map", "0:v", "-map", "1:v", "-map", "1:a", "-c", "copy",
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

    /// The test clip three times over as a live HLS playlist (no #EXT-X-ENDLIST) of 10-second
    /// segments: ffmpeg starts 3 segments from a live playlist's end, so it gets all 30 s.
    static func liveHLS() async throws -> URL {
        let tools = try #require(ToolPaths.locate())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pp-live-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let playlist = folder.appendingPathComponent("index.m3u8")
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-stream_loop", "2", "-i", UITestMedia.file("h264_aac.mp4").path,
            "-c", "copy", "-f", "hls", "-hls_time", "10", "-hls_list_size", "0", "-hls_segment_type", "mpegts",
            "-hls_segment_filename", folder.appendingPathComponent("seg%d.ts").path, playlist.path,
        ])
        try #require(result.status == 0)
        let lines = try String(contentsOf: playlist, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#EXT-X-ENDLIST") && !$0.hasPrefix("#EXT-X-PLAYLIST-TYPE") }
        try lines.joined(separator: "\n").write(to: playlist, atomically: true, encoding: .utf8)
        return folder
    }
}
