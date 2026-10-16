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

    @Test func refusesFilesThatAreNotVideos() {
        let controller = PlaybackController(environment: Self.environment(start: Self.preparesForever),
                                            showsWelcome: false, welcomeSeen: {})
        controller.play([URL(fileURLWithPath: "/Music/song.mp3")])
        #expect(controller.phase == .failed("“song.mp3” isn't a video file."))
        #expect(controller.title == "song.mp3")
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
    private func readyController() async throws -> PlaybackController {
        let tools = try #require(ToolPaths.locate())
        let environment = PlaybackController.Environment(
            tools: { tools }, host: { "127.0.0.1" },
            folders: SessionFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID())")))
        let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
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
