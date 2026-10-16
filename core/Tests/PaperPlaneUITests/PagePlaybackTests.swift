import Foundation
import os
@testable import PaperPlaneCore
import Testing
@testable import PaperPlaneUI

/// What the controller asked of yt-dlp, and what yt-dlp is to answer.
final class FakeYtDlpService: Sendable {
    struct Call: Equatable {
        var page: URL
        var cookie: String?
        var title: String
    }

    private let state = OSAllocatedUnfairLock(initialState: (calls: [Call](), updates: 0))
    /// Answers in turn; the last one again once they run out.
    private let answers: [@Sendable () async throws -> ResolvedPage]
    private let updateInstalls: Bool

    init(updateInstalls: Bool = false, _ answers: [@Sendable () async throws -> ResolvedPage]) {
        self.answers = answers
        self.updateInstalls = updateInstalls
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var updates: Int { state.withLock { $0.updates } }

    func install(in environment: inout PlaybackController.Environment) {
        environment.resolvePage = { page, cookie, title in
            let index = self.state.withLock { state in
                state.calls.append(Call(page: page, cookie: cookie, title: title))
                return state.calls.count - 1
            }
            return try await self.answers[min(index, self.answers.count - 1)]()
        }
        environment.updateYtDlp = {
            self.state.withLock { $0.updates += 1 }
            return self.updateInstalls
        }
    }

    static func failing(_ failure: YtDlpFailure) -> @Sendable () async throws -> ResolvedPage {
        { throw failure }
    }

    static let hangs: @Sendable () async throws -> ResolvedPage = {
        try await Task.sleep(for: .seconds(600))
        throw CancellationError()
    }

    /// A stand-in answer: what a page resolves to, never probed for real.
    static func answer(title: String = "Clean title", start: Double? = nil,
                       urls: [String] = ["https://media.example.com/v.mp4"]) -> @Sendable () async throws -> ResolvedPage {
        { ResolvedPage(input: ResolvedInput(inputs: urls.map { .init(url: URL(string: $0)!) }, title: title), startTime: start) }
    }
}

/// YouTube from the browser and links from the clipboard (Milestone 4), with yt-dlp and the
/// probe stood in for.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PagePlaybackTests {
    static let youtube = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!

    static func page(_ url: URL = youtube, cookie: String? = "SID=1", startAt: Double = 0,
                     title: String = "Big Buck Bunny - YouTube") throws -> PlayRequest {
        try BrowserPlaybackTests.request(url, kind: "page", cookie: cookie, startAt: startAt, title: title)
    }

    /// A controller whose probe records what it was given and then waits for ever.
    static func controller(_ service: FakeYtDlpService, probed: OSAllocatedUnfairLock<[ResolvedInput]> = .init(initialState: []),
                           saveLog: @escaping @Sendable (String, any Error) -> URL? = { _, _ in nil }) -> PlaybackController {
        var environment = PlaybackControllerTests.environment(saveLog: saveLog) { pipeline, input in
            probed.withLock { $0.append(input) }
            return try await PlaybackControllerTests.preparesForever(pipeline, input)
        }
        service.install(in: &environment)
        return PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
    }

    @Test func onlyYouTubePagesAreTakenFromTheBrowser() async throws {
        let refusing = FakeYtDlpService([FakeYtDlpService.failing(.unsupported)])
        let refused = Self.controller(refusing)
        for page in ["https://example.com/watch?v=1", "https://youtube.com.example.net/watch?v=1",
                     "http://www.youtube.com/watch?v=1", "https://notyoutube.com/watch?v=1"] {
            let reply = await refused.play(try Self.page(URL(string: page)!))
            #expect(reply == .failed("Paper Plane takes only YouTube pages from the browser."), "\(page)")
        }
        #expect(refusing.calls.isEmpty)
        #expect(refused.phase == .idle)
        let service = FakeYtDlpService([FakeYtDlpService.hangs])
        let controller = Self.controller(service)
        for (index, page) in ["https://youtu.be/aqz-KE-bpKQ", "https://m.youtube.com/watch?v=1", "https://youtube.com/shorts/1"].enumerated() {
            let request = try Self.page(URL(string: page)!)
            Task { await controller.play(request) }
            await PlaybackControllerTests.eventually { service.calls.count == index + 1 }
        }
        #expect(service.calls.map(\.page.absoluteString) == ["https://youtu.be/aqz-KE-bpKQ", "https://m.youtube.com/watch?v=1",
                                                              "https://youtube.com/shorts/1"])
        controller.stop()
    }

    /// Review Focus 1: YouTube's reason, in plain words; nothing else is touched.
    @Test func aPageThatCantBeResolvedSaysWhy() async throws {
        let service = FakeYtDlpService([FakeYtDlpService.failing(.failed(reason: "Private video."))])
        let logs = OSAllocatedUnfairLock(initialState: 0)
        let controller = Self.controller(service, saveLog: { _, _ in logs.withLock { $0 += 1 }; return nil })
        let reply = await controller.play(try Self.page())
        let message = "Paper Plane couldn't get this video: Private video."
        #expect(reply == .failed(message))
        #expect(controller.phase == .failed(message))
        #expect(controller.title == "Big Buck Bunny - YouTube")
        #expect(service.calls == [.init(page: Self.youtube, cookie: "SID=1", title: "Big Buck Bunny - YouTube")])
        #expect(service.updates == 1) // nothing newer, so no second try
        #expect(logs.withLock { $0 } == 1)
    }

    /// Spec §6: update yt-dlp and retry once, then show the error.
    @Test func aFailedResolveUpdatesAndTriesOnceMore() async throws {
        let service = FakeYtDlpService(updateInstalls: true, [FakeYtDlpService.failing(.failed(reason: nil)),
                                                              FakeYtDlpService.answer()])
        let probed = OSAllocatedUnfairLock<[ResolvedInput]>(initialState: [])
        let controller = Self.controller(service, probed: probed)
        let request = try Self.page()
        Task { await controller.play(request) }
        await PlaybackControllerTests.eventually { !probed.withLock { $0 }.isEmpty }
        #expect(service.calls.count == 2)
        #expect(service.updates == 1)
        #expect(controller.phase == .preparing)
        controller.stop()

        let stillFailing = FakeYtDlpService(updateInstalls: true, [FakeYtDlpService.failing(.noPlayableFormat),
                                                                   FakeYtDlpService.failing(.unsupported)])
        let reply = await Self.controller(stillFailing).play(try Self.page())
        #expect(reply == .failed("Paper Plane didn't find a video at this link."))
        #expect(stillFailing.calls.count == 2)
        #expect(stillFailing.updates == 1)
    }

    @Test func aMissingYtDlpIsInstalledThenUsed() async throws {
        let service = FakeYtDlpService(updateInstalls: true, [FakeYtDlpService.failing(.missing), FakeYtDlpService.answer()])
        let probed = OSAllocatedUnfairLock<[ResolvedInput]>(initialState: [])
        let controller = Self.controller(service, probed: probed)
        let request = try Self.page()
        Task { await controller.play(request) }
        await PlaybackControllerTests.eventually { !probed.withLock { $0 }.isEmpty }
        #expect(service.calls.count == 2)
        controller.stop()

        let none = FakeYtDlpService([FakeYtDlpService.failing(.missing)])
        #expect(await Self.controller(none).play(try Self.page())
            == .failed("Paper Plane's YouTube helper is missing. Reinstall Paper Plane."))
    }

    /// A link to something that isn't a video (an article, say) isn't worth asking GitHub about.
    @Test func anUnsupportedLinkIsntRetried() async throws {
        let service = FakeYtDlpService(updateInstalls: true, [FakeYtDlpService.failing(.unsupported)])
        let reply = await Self.controller(service).play(try Self.page())
        #expect(reply == .failed("Paper Plane didn't find a video at this link."))
        #expect(service.calls.count == 1)
        #expect(service.updates == 0)
    }

    /// With no network there's nothing to ask yt-dlp; the remote says so plainly.
    @Test func offlineSaysSoBeforeAskingYtDlp() async throws {
        let service = FakeYtDlpService([FakeYtDlpService.hangs])
        var environment = PlaybackControllerTests.environment(host: nil) { _, _ in throw CancellationError() }
        service.install(in: &environment)
        let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
        let reply = await controller.play(try Self.page())
        #expect(reply == .failed("Your Mac isn't on a network, so the TV can't reach it. Connect to your network and try again."))
        #expect(service.calls.isEmpty)
    }

    /// Neither a newer yt-dlp nor a retry helps a site that can't be reached or a missing runtime.
    @Test(arguments: [YtDlpFailure.unreachable, .needsJavaScriptRuntime])
    func failuresAnUpdateCantHelpArentRetried(_ failure: YtDlpFailure) async throws {
        let service = FakeYtDlpService(updateInstalls: true, [FakeYtDlpService.failing(failure)])
        _ = await Self.controller(service).play(try Self.page())
        #expect(service.calls.count == 1)
        #expect(service.updates == 0)
    }

    /// A site too slow to answer won't answer faster for a newer yt-dlp.
    @Test func aTimedOutResolveIsntRetried() async throws {
        let service = FakeYtDlpService(updateInstalls: true, [FakeYtDlpService.failing(.timedOut)])
        let reply = await Self.controller(service).play(try Self.page())
        #expect(reply == .failed("The site took too long to answer. Try again."))
        #expect(service.calls.count == 1)
        #expect(service.updates == 0)
    }

    /// Review Focus 2.
    @Test func stoppingWhileAPageResolvesAnswersStopped() async throws {
        let service = FakeYtDlpService([FakeYtDlpService.hangs])
        let controller = Self.controller(service)
        let request = try Self.page()
        let reply = Task { await controller.play(request) }
        await PlaybackControllerTests.eventually { service.calls.count == 1 }
        #expect(controller.phase == .preparing)
        controller.stop()
        #expect(await reply.value == .failed("Stopped in Paper Plane."))
        #expect(controller.phase == .idle)
    }

    @Test func aNewerPageReplacesOneStillResolving() async throws {
        let service = FakeYtDlpService([FakeYtDlpService.hangs])
        let controller = Self.controller(service)
        let first = try Self.page()
        let reply = Task { await controller.play(first) }
        await PlaybackControllerTests.eventually { service.calls.count == 1 }
        controller.play([URL(fileURLWithPath: "/Movies/other.mkv")])
        #expect(await reply.value == .failed("Another video took its place."))
        #expect(controller.title == "other")
        #expect(controller.phase == .preparing)
        controller.stop()
    }

    /// yt-dlp's title is cleaner than the tab's.
    @Test func theAnswersTitleReplacesTheTabs() async throws {
        let answered = OSAllocatedUnfairLock(initialState: false)
        let service = FakeYtDlpService([{
            while !answered.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            return try await FakeYtDlpService.answer(title: "Big Buck Bunny")()
        }])
        let probed = OSAllocatedUnfairLock<[ResolvedInput]>(initialState: [])
        let controller = Self.controller(service, probed: probed)
        let request = try Self.page()
        Task { await controller.play(request) }
        await PlaybackControllerTests.eventually { service.calls.count == 1 }
        #expect(controller.title == "Big Buck Bunny - YouTube") // the tab's, while yt-dlp works
        answered.withLock { $0 = true }
        await PlaybackControllerTests.eventually { !probed.withLock { $0 }.isEmpty }
        #expect(controller.title == "Big Buck Bunny")
        controller.stop()
    }

    @Test func aCopiedLinkToAPagePlays() async throws {
        let service = FakeYtDlpService([FakeYtDlpService.hangs])
        let controller = Self.controller(service)
        controller.playLink("  https://vimeo.com/76979871\n")
        await PlaybackControllerTests.eventually { service.calls.count == 1 }
        #expect(service.calls == [.init(page: URL(string: "https://vimeo.com/76979871")!, cookie: nil, title: "vimeo.com")])
        #expect(controller.phase == .preparing)
        #expect(controller.title == "vimeo.com")
        controller.stop()
    }

    /// A link straight to a playlist or a video file needs no yt-dlp.
    @Test func aCopiedLinkToAPlaylistFilePlaysDirectly() async throws {
        let service = FakeYtDlpService([FakeYtDlpService.hangs])
        let probed = OSAllocatedUnfairLock<[ResolvedInput]>(initialState: [])
        let controller = Self.controller(service, probed: probed)
        controller.playLink("https://cdn.example.com/live/index.m3u8?token=1")
        await PlaybackControllerTests.eventually { probed.withLock { $0 }.count == 1 }
        controller.playLink("https://cdn.example.com/films/Big%20Buck%20Bunny.MP4")
        await PlaybackControllerTests.eventually { probed.withLock { $0 }.count == 2 }
        let inputs = probed.withLock { $0 }
        #expect(inputs.map { $0.inputs.map(\.isHLS) } == [[true], [false]])
        #expect(inputs.map(\.title) == ["index", "Big Buck Bunny"])
        #expect(service.calls.isEmpty)
        controller.stop()
    }

    /// Review Focus 5: nothing playable on the clipboard leaves what's playing alone.
    @Test(arguments: [nil, "", "   \n", "hello world", "file:///Users/someone/Movies/film.mkv", "javascript:alert(1)",
                      "ftp://example.com/film.mp4", "https://", "www.youtube.com/watch?v=1", "https://exa mple.com/v"])
    func copiedTextThatIsntALinkLeavesPlaybackAlone(_ text: String?) async throws {
        let service = FakeYtDlpService([FakeYtDlpService.hangs])
        let controller = Self.controller(service)
        controller.play([URL(fileURLWithPath: "/Movies/film.mkv")])
        controller.playLink(text)
        #expect(controller.notice == "Copy a link to a video first, then choose Play Copied Link.")
        #expect(controller.title == "film")
        #expect(controller.phase == .preparing)
        #expect(service.calls.isEmpty)
        controller.stop()
    }

    /// A link dragged from the browser's address bar onto the remote or the menu bar icon.
    @Test func aDroppedWebLinkPlays() async throws {
        let service = FakeYtDlpService([FakeYtDlpService.hangs])
        let controller = Self.controller(service)
        controller.play([URL(string: "https://youtu.be/aqz-KE-bpKQ")!])
        await PlaybackControllerTests.eventually { service.calls.count == 1 }
        #expect(service.calls.first?.page == URL(string: "https://youtu.be/aqz-KE-bpKQ")!)
        // A video file among what's dropped comes first.
        controller.play([URL(string: "https://youtu.be/other")!, URL(fileURLWithPath: "/Movies/film.mkv")])
        #expect(controller.title == "film")
        #expect(service.calls.count == 1)
        controller.stop()
    }

    @Test func pageFailuresSayWhatHappened() {
        let messages: [(YtDlpFailure, String)] = [
            (.missing, "Paper Plane's YouTube helper is missing. Reinstall Paper Plane."),
            (.unsupported, "Paper Plane didn't find a video at this link."),
            (.noPlayableFormat, "Paper Plane can't play this site's kind of stream yet."),
            (.failed(reason: "Sign in to confirm you're not a bot."), "Paper Plane couldn't get this video: Sign in to confirm you're not a bot."),
            (.failed(reason: nil), "Paper Plane couldn't get this video from the page."),
            (.timedOut, "The site took too long to answer. Try again."),
            (.unreachable, "Paper Plane couldn't reach the site. Check your connection, then try again."),
            (.needsJavaScriptRuntime, "YouTube now needs Deno to give Paper Plane this video. Install it with \"brew install deno\" in Terminal, then try again."),
        ]
        for (failure, message) in messages {
            #expect(PlaybackError.message(for: failure, origin: .link) == message)
            #expect(PlaybackError.message(for: failure, origin: .browser) == message)
        }
    }

    /// What to do next depends on where the video came from: the page in the browser, or the link.
    @Test func aRefusedLinkSaysToPlayItAgain() {
        let refused = MediaProbeError.ffprobeFailed(status: 1, message: "Server returned 403 Forbidden (access denied)")
        #expect(PlaybackError.message(for: refused, origin: .browser) == BrowserPlaybackTests.refused)
        #expect(PlaybackError.message(for: refused, origin: .link) == "The site stopped the stream — choose Play Copied Link again.")
        #expect(PlaybackError.message(for: MediaProbeError.unreadableOutput, origin: .link)
            == "Paper Plane couldn't get this video from the site. Choose Play Copied Link again.")
        #expect(PlaybackError.message(for: MediaProbeError.unreadableOutput, origin: .file)
            == "Paper Plane couldn't read this file. It may be damaged or not a video.")
    }
}

/// The same with real files from scripts/serve-hls.py: separate video and audio, as YouTube
/// sends them.
@MainActor
@Suite(.enabled(if: UITestMedia.available, "Needs ffmpeg and scripts/make-test-media.sh"), .timeLimit(.minutes(1)))
struct PageMediaTests {
    @Test func aYouTubePagePlaysWhatYtDlpFinds() async throws {
        let server = try await UITestServer(directory: UITestMedia.file(""))
        defer { server.stop() }
        let video = server.url("h264_noaudio.mkv")
        let audio = server.url("audio_only.m4a")
        let service = FakeYtDlpService([{
            ResolvedPage(input: ResolvedInput(inputs: [.init(url: video), .init(url: audio)], title: "Big Buck Bunny"))
        }])
        var environment = try PlaybackControllerMediaTests.environment()
        service.install(in: &environment)
        let controller = BrowserPlaybackTests.controller(environment)
        let reply = await controller.play(try PagePlaybackTests.page(startAt: 3))
        #expect(reply == .ok)
        #expect(controller.phase == .waitingForTV)
        #expect(controller.title == "Big Buck Bunny")
        #expect(controller.media?.input.inputs.count == 2)
        #expect(controller.audio?.input == 1) // the separate audio, mapped with the video
        await controller.shutDown()
    }

    /// A link's own t= starts it there; the browser's time, when there is one, wins.
    @Test func aLinksOwnStartTimeIsUsed() async throws {
        let server = try await UITestServer(directory: UITestMedia.file(""))
        defer { server.stop() }
        let file = server.url("h264_aac.mp4")
        let starts = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let service = FakeYtDlpService([{ ResolvedPage(input: ResolvedInput(inputs: [.init(url: file)], title: "Clip"), startTime: 4) }])
        var environment = try PlaybackControllerMediaTests.environment(startStream: { pipeline, media, request in
            starts.withLock { $0.append(request.start) }
            return try await pipeline.start(media, at: request.start, audio: request.audio, burnIn: request.burnIn,
                                            subtitles: request.subtitles)
        })
        service.install(in: &environment)
        let controller = BrowserPlaybackTests.controller(environment)
        controller.playLink("https://example.com/clip?t=4")
        await PlaybackControllerTests.eventually { controller.phase == .waitingForTV }
        #expect(await controller.play(try PagePlaybackTests.page(startAt: 2)) == .ok)
        #expect(starts.withLock { $0 } == [4, 2])
        await controller.shutDown()
    }
}
