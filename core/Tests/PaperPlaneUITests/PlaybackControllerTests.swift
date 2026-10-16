import AVFoundation
import Foundation
import os
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
        saveLog: @escaping @Sendable (String, any Error) -> URL? = { _, _ in nil },
        probe: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> PlaybackMedia
    ) -> PlaybackController.Environment {
        PlaybackController.Environment(
            tools: { tools }, host: { host },
            folders: SessionFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID())")),
            probe: probe, thumbnail: { _, _, _ in nil }, saveLog: saveLog)
    }

    /// Waits for a condition the controller reaches asynchronously.
    static func eventually(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Never finishes on its own: the video stays "preparing" until stopped.
    static let preparesForever: @Sendable (StreamPipeline, ResolvedInput) async throws -> PlaybackMedia = { _, _ in
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
        let controller = PlaybackController(environment: Self.environment(probe: Self.preparesForever),
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
        let controller = PlaybackController(environment: Self.environment(probe: Self.preparesForever),
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

    @Test func explainsMissingFFmpegAndNoNetworkWithoutALog() async {
        let logged = OSAllocatedUnfairLock(initialState: 0)
        let saveLog: @Sendable (String, any Error) -> URL? = { _, _ in
            logged.withLock { $0 += 1 }
            return nil
        }
        let noTools = PlaybackController(
            environment: Self.environment(tools: nil, saveLog: saveLog, probe: Self.preparesForever),
            showsWelcome: false, welcomeSeen: {})
        noTools.play([URL(fileURLWithPath: "/Movies/a.mkv")])
        await Self.eventually { noTools.phase != .preparing }
        #expect(noTools.phase == .failed("Paper Plane's video converter is missing. Reinstall Paper Plane."))

        let offline = PlaybackController(
            environment: Self.environment(host: nil, saveLog: saveLog, probe: Self.preparesForever),
            showsWelcome: false, welcomeSeen: {})
        offline.play([URL(fileURLWithPath: "/Movies/a.mkv")])
        await Self.eventually { offline.phase != .preparing }
        #expect(offline.phase == .failed(
            "Your Mac isn't on a network, so the TV can't reach it. Connect to your network and try again."))
        #expect(logged.withLock { $0 } == 0) // nothing for a bug report: these explain themselves
        #expect(!offline.remoteState.canShowLog)
    }

    @Test func unreadableFilesGetAPlainMessageAndALog() async {
        let log = URL(fileURLWithPath: "/tmp/Paper Plane test.log")
        let saved = OSAllocatedUnfairLock<String?>(initialState: nil)
        let controller = PlaybackController(
            environment: Self.environment(saveLog: { message, _ in
                saved.withLock { $0 = message }
                return log
            }) { _, _ in throw MediaProbeError.ffprobeFailed(status: 1, message: "x") },
            showsWelcome: false, welcomeSeen: {})
        controller.play([URL(fileURLWithPath: "/Movies/a.mkv")])
        await Self.eventually { controller.phase != .preparing }
        #expect(controller.phase == .failed("Paper Plane couldn't read this file. It may be damaged or not a video."))
        #expect(controller.title == "a")
        #expect(controller.failureLog == log)
        #expect(controller.remoteState.canShowLog)
        #expect(saved.withLock { $0 } == "Paper Plane couldn't read this file. It may be damaged or not a video.")

        controller.stop()
        #expect(!controller.remoteState.canShowLog)
    }

    /// A release build uses only the ffmpeg it ships, never whatever is on PATH; a development
    /// build without one falls back to Homebrew's.
    @Test func onlyADevelopmentBuildFallsBackToAnInstalledFFmpeg() {
        let bundleWithoutFFmpeg = FileManager.default.temporaryDirectory.appendingPathComponent("NoHelpers-\(UUID()).app")
        let release = PlaybackController.Environment.live(bundleURL: bundleWithoutFFmpeg, fallsBackToInstalledFFmpeg: false,
                                                          settings: { PlaybackSettings() })
        #expect(release.tools() == nil)
        let development = PlaybackController.Environment.live(bundleURL: bundleWithoutFFmpeg,
                                                              fallsBackToInstalledFFmpeg: true,
                                                              settings: { PlaybackSettings() })
        #expect(development.tools() == ToolPaths.locate())
    }

    @Test func openingAVideoRemembersTheWelcomeWasSeen() {
        var seen = 0
        let controller = PlaybackController(environment: Self.environment(probe: Self.preparesForever),
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
    static func environment(
        host: @escaping @Sendable () -> String? = { "127.0.0.1" },
        settings: PlaybackSettings = PlaybackSettings(),
        freeSpace: @escaping @Sendable () -> Int64? = { 100_000_000_000 },
        extractSubtitles: @escaping @Sendable (StreamPipeline, PlaybackMedia) async throws -> SubtitleFiles
            = { try await $0.extractSubtitles($1) },
        startStream: @escaping @Sendable (StreamPipeline, PlaybackMedia, StreamRequest) async throws -> ServedStream
            = { pipeline, media, request in
                try await pipeline.start(media, at: request.start, audio: request.audio, burnIn: request.burnIn,
                                         subtitles: request.subtitles)
            },
        saveLog: @escaping @Sendable (String, any Error) -> URL? = { _, _ in nil }
    ) throws -> PlaybackController.Environment {
        let tools = try #require(ToolPaths.locate())
        return PlaybackController.Environment(
            tools: { tools }, host: host,
            folders: SessionFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID())")),
            settings: { settings }, extractSubtitles: extractSubtitles, startStream: startStream, freeSpace: freeSpace,
            saveLog: saveLog)
    }

    /// Waits without heeding cancellation, as ffmpeg's own shutdown does.
    static func uncancellableDelay(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    /// A controller holding `file` ready for a TV.
    private func readyController(_ file: URL = UITestMedia.file("h264_aac.mp4"),
                                 environment: PlaybackController.Environment? = nil) async throws -> PlaybackController {
        let controller = PlaybackController(environment: try environment ?? Self.environment(), showsWelcome: false,
                                            welcomeSeen: {})
        controller.player.isMuted = true
        controller.play([file])
        await PlaybackControllerTests.eventually { controller.phase != .preparing }
        try #require(controller.phase == .waitingForTV)
        return controller
    }

    /// A controller playing `file` "on the TV", with all of it converted.
    private func playingController(_ file: URL = UITestMedia.file("h264_aac.mp4"),
                                   environment: PlaybackController.Environment? = nil) async throws
        -> PlaybackController {
        let controller = try await readyController(file, environment: environment)
        controller.externalPlaybackChanged(active: true)
        await PlaybackControllerTests.eventually { controller.conversionFinished && !controller.isPaused }
        try #require(controller.conversionFinished)
        return controller
    }

    @Test func holdsTheVideoUntilATVTakesOverAndKeepsTheMacAwakeWhileItPlays() async throws {
        let controller = try await readyController()
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.player.rate == 0) // nothing plays on the Mac
        #expect(controller.duration.map { abs($0 - 10) < 0.5 } == true)
        #expect(controller.detail == "720p · 10 s")
        #expect(!controller.preventsSleep)

        controller.externalPlaybackChanged(active: true)
        #expect(controller.phase == .onTV)
        #expect(controller.player.rate > 0)
        await PlaybackControllerTests.eventually { controller.preventsSleep }
        #expect(controller.preventsSleep)
        controller.togglePause()
        await PlaybackControllerTests.eventually { !controller.preventsSleep }
        #expect(!controller.preventsSleep)
        await controller.shutDown()
    }

    /// The "choose your TV" box shows until a TV has been chosen once (design audit, move 2).
    @Test func theTVHintGoesOnceATVHasBeenChosen() async throws {
        var chosen = 0
        let controller = PlaybackController(environment: try Self.environment(), showsWelcome: false, welcomeSeen: {},
                                            showsTVHelp: true, tvChosen: { chosen += 1 })
        controller.player.isMuted = true
        controller.play([UITestMedia.file("h264_aac.mp4")])
        await PlaybackControllerTests.eventually { controller.phase == .waitingForTV }
        #expect(controller.remoteState.showsTVHelp)
        controller.externalPlaybackChanged(active: true)
        #expect(!controller.remoteState.showsTVHelp)
        controller.externalPlaybackChanged(active: false)
        controller.externalPlaybackChanged(active: true)
        #expect(chosen == 1)
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
        let logged = OSAllocatedUnfairLock<String?>(initialState: nil)
        let environment = try Self.environment(startStream: { pipeline, media, request in
            let stream = try await pipeline.start(media, at: request.start)
            let master = stream.session.folder.appendingPathComponent("master.m3u8")
            let refused = try String(contentsOf: master, encoding: .utf8)
                .replacingOccurrences(of: "FRAME-RATE=30.000,", with: "")
                .replacingOccurrences(of: "VIDEO-RANGE=SDR", with: "VIDEO-RANGE=PQ")
            try refused.write(to: master, atomically: true, encoding: .utf8)
            return stream
        }, saveLog: { message, error in
            logged.withLock { $0 = "\(message) | \(error)" }
            return URL(fileURLWithPath: "/tmp/log.txt")
        })
        let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
        controller.player.isMuted = true
        controller.play([UITestMedia.file("h264_aac.mp4")])
        await PlaybackControllerTests.eventually {
            if case .failed = controller.phase { true } else { false }
        }
        #expect(controller.phase == .failed("Paper Plane couldn't play this video. Try another file."))
        #expect(controller.title == "h264_aac")
        // Show Log has the player's reason, for a bug report.
        #expect(controller.remoteState.canShowLog)
        #expect(logged.withLock { $0 }?.contains("The player stopped") == true)
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
    /// up after both, including converted subtitles.
    @Test func shutDownWaitsForAReplacedStart() async throws {
        let environment = try Self.environment()
        let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
        controller.play([UITestMedia.file("h264_ac3_51.mkv")])
        await PlaybackControllerTests.eventually { !Self.sessionFolders(in: environment).isEmpty }
        try #require(!Self.sessionFolders(in: environment).isEmpty)
        controller.play([UITestMedia.file("h264_aac.mp4")])
        await controller.shutDown()
        #expect(Self.sessionFolders(in: environment).isEmpty)
    }

    private static func sessionFolders(in environment: PlaybackController.Environment) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: environment.folders.root.path)) ?? []
    }

    // MARK: - Milestone 2: sessions

    /// Inside what's converted a seek is a plain player seek; outside it, a new session starts
    /// there (spec §4.2).
    @Test func seekingOutsideTheSessionStartsANewOneThere() async throws {
        let controller = try await playingController()
        let first = try #require(controller.stream)
        controller.seek(toMovieTime: 4)
        #expect(controller.stream === first)
        #expect(controller.loading == nil)

        controller.restart(at: 6, loading: "Moving to 0:06…")
        #expect(controller.remoteState.status == "Moving to 0:06…")
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(abs((controller.stream?.session.offset ?? 0) - 6) < 0.05)
        #expect(controller.phase == .onTV)

        controller.seek(toMovieTime: 2) // before the new session's start
        await PlaybackControllerTests.eventually { controller.loading == nil && controller.stream?.session.offset != 6 }
        #expect(abs((controller.stream?.session.offset ?? 0) - 2) < 0.05)
        controller.seek(toMovieTime: 500) // past the end: the last second
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(controller.phase == .onTV)
        #expect(abs(controller.movieTime - 9) < 0.6)
        await controller.shutDown()
    }

    /// While a track change's new session starts (here waiting on the subtitles' conversion),
    /// the TV plays on: the clock keeps going, and the new session starts where playback has got
    /// to by then, not where it was when the track was chosen.
    @Test func aTrackChangeFollowsPlaybackWhileItLoads() async throws {
        let environment = try Self.environment(extractSubtitles: { pipeline, media in
            await Self.uncancellableDelay(3.5)
            return try await pipeline.extractSubtitles(media)
        })
        let controller = try await playingController(UITestMedia.file("h264_ac3_51.mkv"), environment: environment)
        await PlaybackControllerTests.eventually { controller.movieTime > 0.2 } // playing, not still buffering
        let chosenAt = controller.movieTime
        controller.selectSubtitle("track-0-2")
        await PlaybackControllerTests.eventually { controller.movieTime > chosenAt + 0.4 }
        #expect(controller.loading != nil)
        #expect(controller.movieTime > chosenAt + 0.4, "the clock keeps going")
        await PlaybackControllerTests.eventually { controller.loading == nil }
        // Copied video starts on the keyframe (every second here) before where playback was.
        #expect((controller.stream?.session.offset ?? 0) >= chosenAt + 1)
        await controller.shutDown()
    }

    /// Free space is asked for at most every few seconds: the query takes milliseconds of the
    /// main thread, and the window is checked on every tick and segment.
    @Test func freeSpaceIsAskedForSparingly() async throws {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let environment = try Self.environment(freeSpace: {
            asked.withLock { $0 += 1 }
            return 100_000_000_000
        })
        let controller = try await playingController(environment: environment)
        let before = asked.withLock { $0 }
        for _ in 0..<5 {
            controller.manageWindow()
        }
        #expect(asked.withLock { $0 } - before <= 1)
        await controller.shutDown()
    }

    @Test func seekingBeforeTheStartGoesToTheStart() async throws {
        let controller = try await playingController()
        let first = try #require(controller.stream)
        controller.seek(toMovieTime: -20)
        #expect(controller.movieTime == 0)
        #expect(controller.stream === first) // the start is in the session: no new one
        await controller.shutDown()
    }

    /// Quitting while a seek's new session is starting leaves no ffmpeg or folder behind.
    @Test func quittingDuringASeekLeavesNothing() async throws {
        let environment = try Self.environment()
        let controller = try await playingController(environment: environment)
        controller.restart(at: 5, loading: "Moving…")
        await controller.shutDown()
        #expect(Self.sessionFolders(in: environment).isEmpty)
    }

    /// Quitting straight after several quick seeks waits for every replaced session to clean up.
    @Test func quittingDuringRapidSeeksLeavesNothing() async throws {
        let environment = try Self.environment()
        let controller = try await playingController(environment: environment)
        for target in [7.0, 2, 8, 3, 6] {
            controller.restart(at: target, loading: "Moving…")
            try await Task.sleep(for: .milliseconds(40))
        }
        await controller.shutDown()
        #expect(Self.sessionFolders(in: environment).isEmpty)
    }

    /// A replaced seek whose cleanup is slow (ffmpeg can take seconds to stop) is still waited
    /// for when quitting, not just the latest one.
    @Test func quittingWaitsForASlowCleanupOfAReplacedSeek() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cleaning = OSAllocatedUnfairLock(initialState: 0)
        let environment = try Self.environment(startStream: { pipeline, media, request in
            let call = calls.withLock { $0 += 1; return $0 }
            do {
                return try await pipeline.start(media, at: request.start, audio: request.audio,
                                                burnIn: request.burnIn, subtitles: request.subtitles)
            } catch {
                // The replaced seek (call 2) takes a second to clean up; the last one (call 3) a moment.
                cleaning.withLock { $0 += 1 }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + (call == 2 ? 1.0 : 0.1)) { continuation.resume() }
                }
                cleaning.withLock { $0 -= 1 }
                throw error
            }
        })
        let controller = try await playingController(environment: environment)
        controller.restart(at: 7, loading: "Moving…")
        try await Task.sleep(for: .milliseconds(20))
        controller.restart(at: 3, loading: "Moving…")
        try await Task.sleep(for: .milliseconds(20))
        await controller.shutDown()
        #expect(calls.withLock { $0 } == 3)
        #expect(cleaning.withLock { $0 } == 0)
    }

    /// While a seek's new session starts, the old one keeps playing on the TV: the window must not
    /// treat the seek's target as the playhead and delete what the TV is about to fetch.
    @Test func theWindowLeavesThePlayingSessionAloneDuringASeek() async throws {
        let controller = try await playingController()
        let folder = try #require(controller.stream?.session.folder)
        controller.conversionFinished = false
        controller.restart(at: 9, loading: "Moving…")
        controller.movieTime = 400 // as if the seek's target were far ahead
        controller.manageWindow()
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("seg_00000.m4s").path))
        #expect(controller.segments.count == 2)
        await controller.shutDown()
    }

    /// A subtitle choice waiting on a slow conversion, then Stop: the abandoned choice must not
    /// leave a notice or converted files behind on the idle remote (or the next video).
    @Test func aStoppedSubtitleChoiceLeavesNoTrace() async throws {
        // Converting finishes only once the test says so, ignoring cancellation as ffmpeg's does. (A
        // fixed delay starts at play() and could be over under load before the choice is made.)
        let released = OSAllocatedUnfairLock(initialState: false)
        let environment = try Self.environment(extractSubtitles: { pipeline, _ in
            while !released.withLock({ $0 }) {
                await Self.uncancellableDelay(0.05)
            }
            return SubtitleFiles(folder: pipeline.folders.root, files: [:])
        })
        let controller = try await playingController(UITestMedia.file("h264_ac3_51.mkv"), environment: environment)
        controller.selectSubtitle("track-0-2")
        #expect(controller.loading != nil) // waiting for the conversion
        try await Task.sleep(for: .milliseconds(100))
        controller.stop()
        released.withLock { $0 = true }
        try await Task.sleep(for: .seconds(1))
        #expect(controller.notice == nil)
        #expect(controller.subtitleFiles == nil)
        await controller.shutDown()
    }

    /// The address changes while a seek's new session is starting from the old one: once it's
    /// ready, Paper Plane serves again from the new address.
    @Test func aNetworkChangeDuringASeekIsNotLost() async throws {
        let host = OSAllocatedUnfairLock<String?>(initialState: "127.0.0.1")
        let seekStarted = OSAllocatedUnfairLock(initialState: false)
        let environment = try Self.environment(host: { host.withLock { $0 } }, startStream: { pipeline, media, request in
            if request.start == 3 { // the seek: it has its address; hold it a moment
                seekStarted.withLock { $0 = true }
                await Self.uncancellableDelay(0.3)
            }
            return try await pipeline.start(media, at: request.start)
        })
        let controller = try await playingController(environment: environment)
        controller.restart(at: 3, loading: "Moving…")
        await PlaybackControllerTests.eventually { seekStarted.withLock { $0 } }
        host.withLock { $0 = "localhost" }
        controller.networkChanged()
        await PlaybackControllerTests.eventually {
            controller.loading == nil && controller.stream?.server.baseURL.host() == "localhost"
        }
        #expect(controller.stream?.server.baseURL.host() == "localhost")
        await controller.shutDown()
    }

    /// Subtitles ffmpeg can't read don't stop the video: they turn off and a notice says so.
    @Test func subtitlesThatCantBeReadTurnOffWithANotice() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pp-badsubs-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("Film.mp4")
        try FileManager.default.createSymbolicLink(at: movie, withDestinationURL: UITestMedia.file("h264_aac.mp4"))
        try Data([0xFF, 0x00, 0xFE, 0x01]).write(to: folder.appendingPathComponent("Film.en.srt"))
        let controller = try await playingController(movie)
        controller.selectSubtitle("file-Film.en.srt")
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(controller.subtitle == nil)
        #expect(controller.notice == "Paper Plane couldn't read the subtitles “English — Film.en.srt”.")
        #expect(controller.phase == .onTV)
        #expect(controller.player.rate > 0)
        await controller.shutDown()
    }

    /// Five quick skips past what's converted: each replaces the last, and only the last
    /// session survives.
    @Test func rapidSeeksLeaveOneSession() async throws {
        let environment = try Self.environment()
        let controller = try await playingController(environment: environment)
        for target in [7.0, 2, 8, 3, 6] {
            controller.restart(at: target, loading: "Moving…")
        }
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(abs((controller.stream?.session.offset ?? 0) - 6) < 0.05)
        try await Task.sleep(for: .milliseconds(500))
        #expect(Self.sessionFolders(in: environment).count == 1)
        await controller.shutDown()
        #expect(Self.sessionFolders(in: environment).isEmpty)
    }

    /// Between 1 and 2 GB free the window already keeps less ahead, so the user hears why then.
    @Test func theLowSpaceNoticeComesWithTheSmallerWindow() async throws {
        let controller = try await playingController(environment: try Self.environment(freeSpace: { 1_500_000_000 }))
        controller.manageWindow()
        #expect(controller.notice == "Your Mac is low on disk space, so Paper Plane converts only a few minutes ahead.")
        await controller.shutDown()
    }

    @Test func somethingUnexpectedSaysWhatToDoWithoutTheErrorText() {
        struct Odd: Error {}
        #expect(PlaybackError.message(for: Odd()) == "Something went wrong. Try again, or choose another video.")
    }

    @Test func switchingAudioStartsANewSessionWithIt() async throws {
        let controller = try await playingController(UITestMedia.file("h264_multiaudio.mkv"))
        let state = controller.remoteState
        #expect(state.audioChoices.map(\.name) == ["English (Stereo)", "Japanese (5.1)"])
        #expect(state.audio == state.audioChoices[1].id) // the file's default
        controller.selectAudio(state.audioChoices[0].id)
        #expect(controller.remoteState.status == "Switching to English (Stereo)…")
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(controller.stream?.plan.audio == controller.audioTracks[0].ref)
        #expect(controller.remoteState.audio == state.audioChoices[0].id)
        await controller.shutDown()
    }

    @Test func textSubtitlesSwitchOnAndOff() async throws {
        let controller = try await playingController(UITestMedia.file("h264_ac3_51.mkv"))
        #expect(controller.remoteState.subtitleChoices.map(\.name) == ["Subtitles"])
        #expect(controller.subtitle == nil) // off unless forced
        controller.selectSubtitle("track-0-2")
        await PlaybackControllerTests.eventually { controller.loading == nil }
        await PlaybackControllerTests.eventually { await Self.selectedSubtitleTitle(controller) == "Subtitles" }
        #expect(await Self.selectedSubtitleTitle(controller) == "Subtitles")

        controller.selectSubtitle(nil)
        await PlaybackControllerTests.eventually { await Self.selectedSubtitleTitle(controller) == nil }
        #expect(await Self.selectedSubtitleTitle(controller) == nil)
        #expect(controller.subtitle == nil)
        await controller.shutDown()
    }

    /// A sidecar marked forced is on from the start (spec §4, step 2).
    @Test func forcedSubtitlesAreOnFromTheStart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pp-forced-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("Film.mp4")
        try FileManager.default.createSymbolicLink(at: movie, withDestinationURL: UITestMedia.file("h264_aac.mp4"))
        try FileManager.default.copyItem(at: UITestMedia.file("sample.srt"),
                                         to: folder.appendingPathComponent("Film.en.forced.srt"))
        let controller = try await readyController(movie)
        #expect(controller.subtitle == "file-Film.en.forced.srt")
        await PlaybackControllerTests.eventually { await Self.selectedSubtitleTitle(controller) != nil }
        #expect(await Self.selectedSubtitleTitle(controller) == "English — Film.en.forced.srt (Forced)")
        await controller.shutDown()
    }

    @Test(.enabled("Needs an ffmpeg built with libass, like the bundled one") {
        await UITestMedia.ffmpegHasFilter("subtitles")
    })
    func alwaysBurnInDrawsTextSubtitlesIntoThePicture() async throws {
        let environment = try Self.environment(settings: PlaybackSettings(alwaysBurnInSubtitles: true))
        let controller = try await playingController(UITestMedia.file("h264_ac3_51.mkv"), environment: environment)
        controller.selectSubtitle("track-0-2")
        #expect(controller.remoteState.status == "Adding subtitles…")
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(controller.stream?.plan.burnIn == .text)
        controller.selectSubtitle(nil)
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(controller.stream?.plan.burnIn == nil)
        await controller.shutDown()
    }

    /// When the Mac's address changes, the TV can't reach the old one: serve again from the new
    /// address at the current time (spec §6).
    @Test func aNewNetworkAddressServesTheVideoAgain() async throws {
        let host = OSAllocatedUnfairLock<String?>(initialState: "127.0.0.1")
        let controller = try await playingController(environment: try Self.environment(host: { host.withLock { $0 } }))
        let first = try #require(controller.stream)
        controller.networkChanged() // same address: nothing to do
        #expect(controller.loading == nil) // a new session would have started loading
        #expect(controller.stream === first)
        host.withLock { $0 = nil }
        controller.networkChanged() // offline for now: carry on, and serve again once back
        #expect(controller.loading == nil)
        #expect(controller.stream === first)

        host.withLock { $0 = "localhost" }
        controller.networkChanged()
        #expect(controller.remoteState.status == "Reconnecting…")
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(controller.stream?.server.baseURL.host() == "localhost")
        await controller.shutDown()
    }

    /// The converted-video window applied to a real session (its numbers are SegmentWindow's
    /// tests): with little disk space ffmpeg rests once 5 minutes ahead and the user is told
    /// once; what the player has left more than 5 minutes behind is deleted, and seeking back
    /// there starts a new session (spec §4.2, §6). A test clip converts in a blink, so the
    /// conversion's progress is set by hand.
    @Test func theWindowRestsFFmpegAndDeletesWhatIsBehind() async throws {
        let controller = try await playingController(environment: try Self.environment(freeSpace: { 900_000_000 }))
        let folder = try #require(controller.stream?.session.folder)
        let real = controller.segments // seg_00000 and seg_00001
        try #require(real.count == 2)
        controller.togglePause()
        controller.conversionFinished = false
        controller.segments = real + (2..<61).map { SegmentWindow.Segment(index: $0, start: Double($0) * 6, end: Double($0 + 1) * 6) }
        controller.convertedEnd = 366

        controller.manageWindow()
        #expect(controller.conversionPaused) // 366 s ahead of 0: past 5 minutes
        #expect(controller.notice == "Your Mac is low on disk space, so Paper Plane converts only a few minutes ahead.")

        controller.movieTime = 360
        controller.manageWindow()
        #expect(!controller.conversionPaused) // 6 s ahead: converting again
        #expect(controller.segments.first?.index == 9) // 0–8 ended more than 300 s before 360
        #expect(controller.remoteState.convertedFrom == 54) // the scrubber doesn't show deleted parts as ready
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("seg_00000.m4s").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("seg_00001.m4s").path))

        controller.dismissNotice()
        controller.manageWindow()
        #expect(controller.notice == nil) // said once

        controller.seek(toMovieTime: 1) // deleted: a new session
        await PlaybackControllerTests.eventually { controller.loading == nil }
        #expect(abs((controller.stream?.session.offset ?? 0) - 1) < 0.05)
        await controller.shutDown()
    }

    /// The title of the subtitle option the player shows, or nil.
    private static func selectedSubtitleTitle(_ controller: PlaybackController) async -> String? {
        guard let item = controller.player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              let option = item.currentMediaSelection.selectedMediaOption(in: group)
        else { return nil }
        let titles = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
        return try? await titles.first?.load(.stringValue)
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

    /// Whether the ffmpeg under test has a filter, e.g. `subtitles` (libass).
    static func ffmpegHasFilter(_ name: String) async -> Bool {
        guard let tools = ToolPaths.locate() else { return false }
        let process = Process()
        process.executableURL = tools.ffmpeg
        process.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").contains { $0.split(separator: " ").dropFirst().first == Substring(name) }
    }
}
