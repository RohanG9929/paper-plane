import AVFoundation
import Foundation
import PaperPlaneCore
import Testing
@testable import PaperPlaneUI

/// The controller's decisions, with stand-ins for ffmpeg where timing has to be exact.
@MainActor
struct PlaybackControllerTests {
    static let fakeTools = ToolPaths(ffmpeg: URL(fileURLWithPath: "/usr/bin/true"),
                                     ffprobe: URL(fileURLWithPath: "/usr/bin/true"))

    static func environment(
        tools: ToolPaths? = fakeTools, host: String? = "127.0.0.1",
        start: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream
    ) -> PlaybackController.Environment {
        PlaybackController.Environment(
            tools: { tools }, host: { host },
            folders: SessionFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID())")),
            startStream: start, thumbnail: { _, _, _ in nil })
    }

    /// Waits for a condition the controller reaches asynchronously.
    static func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Never finishes on its own: the video stays "preparing" until stopped.
    static let preparesForever: @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream = { _, _ in
        try await Task.sleep(for: .seconds(600))
        throw CancellationError()
    }

    @Test func aFailureFromAReplacedVideoDoesNotStopTheNewOne() async throws {
        let environment = Self.environment { pipeline, input in
            guard input.title == "broken" else { return try await Self.preparesForever(pipeline, input) }
            // The broken file's probe fails only after the newer video has taken over.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            throw MediaProbeError.unreadableOutput
        }
        let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
        controller.play([URL(fileURLWithPath: "/Movies/broken.mkv")])
        controller.play([URL(fileURLWithPath: "/Movies/good.mkv")])
        try await Task.sleep(for: .milliseconds(300))

        #expect(controller.phase == .preparing)
        #expect(controller.title == "good")
        controller.stop()
    }

    /// Dropping a song on the remote by mistake must not stop the video on the TV.
    @Test func aFileThatIsNotAVideoLeavesPlaybackAloneWithANotice() {
        let controller = PlaybackController(environment: Self.environment(start: Self.preparesForever),
                                            showsWelcome: false, welcomeSeen: {})
        controller.play([URL(fileURLWithPath: "/Movies/a.mkv")])
        controller.play([URL(fileURLWithPath: "/Music/song.mp3")])
        #expect(controller.phase == .preparing)
        #expect(controller.title == "a")
        #expect(controller.notice == "“song.mp3” isn't a video file.")
        #expect(controller.remoteState.notice == "“song.mp3” isn't a video file.")

        controller.play([URL(fileURLWithPath: "/Movies/b.mkv")])
        #expect(controller.notice == nil)
        controller.stop()
    }

    @Test func aNoticeCanBeDismissedAndGoesAwayOnItsOwn() async {
        let controller = PlaybackController(environment: Self.environment(start: Self.preparesForever),
                                            showsWelcome: false, welcomeSeen: {})
        controller.play([URL(fileURLWithPath: "/Music/song.mp3")])
        #expect(controller.phase == .idle)
        #expect(controller.title == nil)
        #expect(controller.notice == "“song.mp3” isn't a video file.")
        controller.dismissNotice()
        #expect(controller.notice == nil)

        controller.noticeDuration = .milliseconds(100)
        controller.play([URL(fileURLWithPath: "/Documents/notes.pdf")])
        #expect(controller.notice == "“notes.pdf” isn't a video file.")
        await Self.eventually { controller.notice == nil }
        #expect(controller.notice == nil)
    }

    @Test func explainsMissingFFmpegAndNoNetwork() async {
        let noTools = PlaybackController(environment: Self.environment(tools: nil, start: Self.preparesForever),
                                         showsWelcome: false, welcomeSeen: {})
        noTools.play([URL(fileURLWithPath: "/Movies/a.mkv")])
        await Self.eventually { noTools.phase != .preparing }
        #expect(noTools.phase == .failed("Paper Plane's video converter is missing. Reinstall Paper Plane."))

        let offline = PlaybackController(environment: Self.environment(host: nil, start: Self.preparesForever),
                                         showsWelcome: false, welcomeSeen: {})
        offline.play([URL(fileURLWithPath: "/Movies/a.mkv")])
        await Self.eventually { offline.phase != .preparing }
        #expect(offline.phase == .failed(
            "Your Mac isn't on a network, so the TV can't reach it. Connect to Wi-Fi and try again."))
    }

    @Test func unreadableFilesGetAPlainMessage() async {
        let controller = PlaybackController(
            environment: Self.environment { _, _ in throw MediaProbeError.ffprobeFailed(status: 1, message: "x") },
            showsWelcome: false, welcomeSeen: {})
        controller.play([URL(fileURLWithPath: "/Movies/a.mkv")])
        await Self.eventually { controller.phase != .preparing }
        #expect(controller.phase == .failed("Paper Plane couldn't read this file. It may be damaged or not a video."))
        #expect(controller.title == "a")
    }

    /// A release build uses only the ffmpeg it ships, never whatever is on PATH; a development
    /// build without one falls back to Homebrew's.
    @Test func onlyADevelopmentBuildFallsBackToAnInstalledFFmpeg() {
        let bundleWithoutFFmpeg = FileManager.default.temporaryDirectory.appendingPathComponent("NoHelpers-\(UUID()).app")
        let release = PlaybackController.Environment.live(bundleURL: bundleWithoutFFmpeg, fallsBackToInstalledFFmpeg: false)
        #expect(release.tools() == nil)
        let development = PlaybackController.Environment.live(bundleURL: bundleWithoutFFmpeg, fallsBackToInstalledFFmpeg: true)
        #expect(development.tools() == ToolPaths.locate())
    }

    @Test func openingAVideoRemembersTheWelcomeWasSeen() {
        var seen = 0
        let controller = PlaybackController(environment: Self.environment(start: Self.preparesForever),
                                            showsWelcome: true, welcomeSeen: { seen += 1 })
        controller.play([URL(fileURLWithPath: "/Movies/a.mkv")])
        #expect(!controller.showsWelcome)
        #expect(seen == 1)
        controller.stop()
    }
}

/// The controller with the real pipeline on the loopback address. Only a real AirPlay TV can
/// switch external playback on, so the tests tell the controller directly.
@MainActor
@Suite(.enabled(if: UITestMedia.available, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct PlaybackControllerMediaTests {
    private static func environment(
        startStream: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream
            = { try await $0.start($1) }
    ) throws -> PlaybackController.Environment {
        let tools = try #require(ToolPaths.locate())
        return PlaybackController.Environment(
            tools: { tools }, host: { "127.0.0.1" },
            folders: SessionFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID())")),
            startStream: startStream)
    }

    private func readyController() async throws -> PlaybackController {
        let controller = PlaybackController(environment: try Self.environment(), showsWelcome: false, welcomeSeen: {})
        controller.player.isMuted = true
        controller.play([UITestMedia.file("h264_aac.mp4")])
        await PlaybackControllerTests.eventually { controller.phase != .preparing }
        try #require(controller.phase == .waitingForTV)
        return controller
    }

    @Test func holdsTheVideoUntilATVTakesOver() async throws {
        let controller = try await readyController()
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.player.rate == 0) // nothing plays on the Mac
        #expect(controller.duration.map { abs($0 - 10) < 0.5 } == true)
        #expect(controller.detail == "720p · 10 s")

        controller.externalPlaybackChanged(active: true)
        #expect(controller.phase == .onTV)
        #expect(controller.player.rate > 0)
        await controller.shutDown()
    }

    @Test func aTVThatDropsOutPausesAndResumesTheWayItWas() async throws {
        let controller = try await readyController()
        controller.externalPlaybackChanged(active: true)
        await PlaybackControllerTests.eventually { !controller.isPaused }
        controller.togglePause()
        await PlaybackControllerTests.eventually { controller.isPaused }

        controller.externalPlaybackChanged(active: false)
        #expect(controller.phase == .waitingForTV)
        #expect(controller.tvWentAway)
        #expect(controller.player.rate == 0)

        controller.externalPlaybackChanged(active: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.phase == .onTV)
        #expect(controller.player.rate == 0, "it was paused before the TV dropped, so it stays paused")
        await controller.shutDown()
    }

    /// AVPlayer may pause by itself as the TV drops out, before the controller hears of it.
    /// That isn't the user pausing, so playback resumes when the TV is back.
    @Test func aTVThatDropsOutWhilePlayingResumesPlaying() async throws {
        let controller = try await readyController()
        controller.externalPlaybackChanged(active: true)
        await PlaybackControllerTests.eventually { !controller.isPaused }
        controller.player.pause() // the player, not the user
        await PlaybackControllerTests.eventually { controller.isPaused }

        controller.externalPlaybackChanged(active: false)
        controller.externalPlaybackChanged(active: true)
        await PlaybackControllerTests.eventually { !controller.isPaused }
        #expect(controller.player.rate > 0)
        await controller.shutDown()
    }

    /// A stream the Mac's player refuses (here an HDR master playlist with no FRAME-RATE, which
    /// AVFoundation rejects) ends in a plain message instead of waiting for a TV forever.
    @Test func aStreamThePlayerRefusesEndsInAPlainMessage() async throws {
        let environment = try Self.environment { pipeline, input in
            let stream = try await pipeline.start(input)
            let master = stream.session.folder.appendingPathComponent("master.m3u8")
            let refused = try String(contentsOf: master, encoding: .utf8)
                .replacingOccurrences(of: "FRAME-RATE=30.000,", with: "")
                .replacingOccurrences(of: "VIDEO-RANGE=SDR", with: "VIDEO-RANGE=PQ")
            try refused.write(to: master, atomically: true, encoding: .utf8)
            return stream
        }
        let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
        controller.player.isMuted = true
        controller.play([UITestMedia.file("h264_aac.mp4")])
        await PlaybackControllerTests.eventually {
            if case .failed = controller.phase { true } else { false }
        }
        #expect(controller.phase == .failed("Paper Plane couldn't play this video. Try another file."))
        #expect(controller.title == "h264_aac")
        await controller.shutDown()
    }

    /// Quitting straight after Stop must still end ffmpeg and delete the session folder.
    @Test func shutDownWaitsForAStoppedVideo() async throws {
        let environment = try Self.environment()
        let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
        controller.play([UITestMedia.file("h264_aac.mp4")])
        await PlaybackControllerTests.eventually { controller.phase != .preparing }
        try #require(controller.phase == .waitingForTV)
        controller.stop()
        await controller.shutDown()
        #expect(Self.sessionFolders(in: environment).isEmpty)
    }

    /// Quitting straight after opening a second video over one still being prepared must clean
    /// up after both.
    @Test func shutDownWaitsForAReplacedStart() async throws {
        let environment = try Self.environment()
        let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
        controller.play([UITestMedia.file("h264_aac.mp4")])
        await PlaybackControllerTests.eventually { !Self.sessionFolders(in: environment).isEmpty }
        try #require(!Self.sessionFolders(in: environment).isEmpty)
        controller.play([UITestMedia.file("h264_ac3_51.mkv")])
        await controller.shutDown()
        #expect(Self.sessionFolders(in: environment).isEmpty)
    }

    private static func sessionFolders(in environment: PlaybackController.Environment) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: environment.folders.root.path)) ?? []
    }

    /// Playing within the last second of what's converted, "forward 10 seconds" must not jump
    /// back to the seek limit.
    @Test func skippingForwardNeverGoesBack() async throws {
        let controller = try await readyController()
        controller.externalPlaybackChanged(active: true)
        await PlaybackControllerTests.eventually { controller.convertedEnd.map { $0 > 9 } == true }
        let converted = try #require(controller.convertedEnd)
        controller.seek(toMovieTime: converted) // lands a second short of the converted end
        await PlaybackControllerTests.eventually { controller.movieTime > converted - 0.9 }
        let before = controller.movieTime
        try #require(before > converted - 1)
        controller.skip(by: 10)
        #expect(controller.movieTime >= before)
        await controller.shutDown()
    }

    @Test func seeksStayWithinWhatIsConverted() async throws {
        let controller = try await readyController()
        controller.externalPlaybackChanged(active: true)
        await PlaybackControllerTests.eventually { controller.convertedEnd.map { $0 > 9 } == true }
        controller.seek(toMovieTime: 500)
        #expect(controller.movieTime <= (controller.convertedEnd ?? 0))
        controller.seek(toMovieTime: -20)
        #expect(controller.movieTime == 0)
        await controller.shutDown()
    }
}

enum UITestMedia {
    /// core/Tests/PaperPlaneUITests/PlaybackControllerTests.swift → the repository root.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func file(_ name: String) -> URL {
        repoRoot.appendingPathComponent("testdata/media/\(name)")
    }

    static var available: Bool {
        ToolPaths.locate() != nil && FileManager.default.fileExists(atPath: file("h264_aac.mp4").path)
    }
}
