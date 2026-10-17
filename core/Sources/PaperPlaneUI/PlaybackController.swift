import AppKit
import AVFoundation
import Observation
import os
import PaperPlaneCore

/// Choices that apply to every playback, from Settings (spec §4.1).
public struct PlaybackSettings: Equatable, Sendable {
    public var profile: OutputProfile
    /// Draw text subtitles into the picture instead of offering them as tracks, for TVs that
    /// don't show subtitle tracks.
    public var alwaysBurnInSubtitles: Bool

    public init(profile: OutputProfile = .default, alwaysBurnInSubtitles: Bool = false) {
        self.profile = profile
        self.alwaysBurnInSubtitles = alwaysBurnInSubtitles
    }
}

/// Where a session starts and what it shows.
public struct StreamRequest: Sendable {
    public var start: Double
    public var audio: TrackRef?
    public var burnIn: SubtitleOption?
    public var subtitles: SubtitleFiles?
}

/// Plays one video at a time on the TV: probe → plan → transcode → serve → AVPlayer → AirPlay
/// (spec §4). Seeking outside what's converted and changing tracks start a new session
/// (spec §4.2); see PlaybackController+Sessions.swift.
@MainActor @Observable
public final class PlaybackController {
    /// What the controller needs from the outside world, so tests can stand in for it.
    public struct Environment: Sendable {
        /// ffmpeg and ffprobe, or nil when missing.
        public var tools: @Sendable () -> ToolPaths?
        /// The address the stream server listens on, or nil when the Mac is offline.
        public var host: @Sendable () -> String?
        public var folders: SessionFolders
        public var settings: @Sendable () -> PlaybackSettings
        public var probe: @Sendable (StreamPipeline, ResolvedInput) async throws -> PlaybackMedia
        public var extractSubtitles: @Sendable (StreamPipeline, PlaybackMedia) async throws -> SubtitleFiles
        /// Plan → transcode → serve.
        public var startStream: @Sendable (StreamPipeline, PlaybackMedia, StreamRequest) async throws -> ServedStream
        /// A JPEG for the artwork.
        public var thumbnail: @Sendable (ToolPaths, URL, Double?) async -> Data?
        /// Bytes free where the sessions are.
        public var freeSpace: @Sendable () -> Int64?
        /// Saves a failure's details for a bug report and says where.
        public var saveLog: @Sendable (String, any Error) -> URL?
        /// Asks yt-dlp for a page's video: the page, the site's cookie, a title until it names one.
        public var resolvePage: @Sendable (URL, String?, String) async throws -> ResolvedPage
        /// Updates yt-dlp now; whether a newer copy was installed.
        public var updateYtDlp: @Sendable () async throws -> Bool
        /// Updates yt-dlp if a day has passed since the last check.
        public var updateYtDlpIfDue: @Sendable () async -> Bool

        public init(
            tools: @escaping @Sendable () -> ToolPaths?, host: @escaping @Sendable () -> String?,
            folders: SessionFolders = .standard,
            settings: @escaping @Sendable () -> PlaybackSettings = { PlaybackSettings() },
            probe: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> PlaybackMedia
                = { try await $0.probe($1) },
            extractSubtitles: @escaping @Sendable (StreamPipeline, PlaybackMedia) async throws -> SubtitleFiles
                = { try await $0.extractSubtitles($1) },
            startStream: @escaping @Sendable (StreamPipeline, PlaybackMedia, StreamRequest) async throws -> ServedStream
                = { pipeline, media, request in
                    try await pipeline.start(media, at: request.start, audio: request.audio, burnIn: request.burnIn,
                                             subtitles: request.subtitles)
                },
            thumbnail: @escaping @Sendable (ToolPaths, URL, Double?) async -> Data? = { tools, url, duration in
                await Thumbnail.jpeg(tools: tools, input: .init(url: url), at: Thumbnail.moment(duration: duration))
            },
            freeSpace: (@Sendable () -> Int64?)? = nil,
            saveLog: @escaping @Sendable (String, any Error) -> URL? = { FailureLog.save(message: $0, error: $1) },
            resolvePage: @escaping @Sendable (URL, String?, String) async throws -> ResolvedPage = { _, _, _ in
                throw YtDlpFailure.missing
            },
            updateYtDlp: @escaping @Sendable () async throws -> Bool = { false },
            updateYtDlpIfDue: @escaping @Sendable () async -> Bool = { false }
        ) {
            self.tools = tools
            self.host = host
            self.folders = folders
            self.settings = settings
            self.probe = probe
            self.extractSubtitles = extractSubtitles
            self.startStream = startStream
            self.thumbnail = thumbnail
            self.freeSpace = freeSpace ?? { DiskSpace.available(at: folders.root) }
            self.saveLog = saveLog
            self.resolvePage = resolvePage
            self.updateYtDlp = updateYtDlp
            self.updateYtDlpIfDue = updateYtDlpIfDue
        }

        /// The app's own: the ffmpeg and yt-dlp in its bundle and the Mac's LAN address. Only a
        /// development build (`fallsBackToInstalledFFmpeg`) may use an ffmpeg or yt-dlp from PATH or
        /// Homebrew instead: a release must never run whatever happens to be installed under that
        /// name. yt-dlp updates itself from GitHub unless `updatesYtDlp` is off.
        public static func live(bundleURL: URL, fallsBackToInstalledFFmpeg: Bool, updatesYtDlp: Bool,
                                settings: @escaping @Sendable () -> PlaybackSettings,
                                copies: YtDlpCopies? = nil) -> Environment {
            let copies = copies ?? .standard(bundle: bundleURL, fallsBackToInstalled: fallsBackToInstalledFFmpeg)
            let updater = YtDlpUpdater.standard(copies: copies)
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Paper Plane/yt-dlp", isDirectory: true)
            let tools: @Sendable () -> ToolPaths? = {
                ToolPaths.inBundle(at: bundleURL) ?? (fallsBackToInstalledFFmpeg ? ToolPaths.locate() : nil)
            }
            return Environment(
                tools: tools,
                host: { LANAddress.current() },
                settings: settings,
                resolvePage: { page, cookie, title in
                    guard let copy = copies.current() else { throw YtDlpFailure.missing }
                    return try await YtDlp.resolve(page: page, cookie: cookie, executable: copy.executable,
                                                   cacheFolder: cache, ffmpeg: tools()?.ffmpeg, fallbackTitle: title)
                },
                updateYtDlp: { updatesYtDlp ? try await updater.updateAfterFailure() : false },
                updateYtDlpIfDue: { updatesYtDlp ? await updater.updateIfDue() : false })
        }
    }

    public enum Phase: Equatable {
        case idle
        case preparing
        /// Loaded but held paused until a TV is chosen. With no TV, AVPlayer would play on the
        /// Mac (docs/sony-test-results.md, rows 8 and 9).
        case waitingForTV
        case onTV
        case failed(String)
    }

    /// Whether to seek to the start once the TV takes over, in case it began at a growing
    /// playlist's live edge (docs/sony-test-results.md, row 7a and the Plan 2 re-test).
    static let seeksToStartOnTV = true

    public let player = AVPlayer()
    public private(set) var phase = Phase.idle {
        didSet { updateSleep() }
    }
    public private(set) var title: String?
    public private(set) var detail = ""
    public private(set) var isPaused = true {
        didSet { updateSleep() }
    }
    public internal(set) var movieTime = 0.0
    public private(set) var duration: Double?
    /// A web stream with no end (spec §5.3): nothing to seek in.
    public var isLive: Bool {
        isWeb && duration == nil
    }
    /// From the browser rather than a file: read through the web proxy, and its conversion never
    /// rested (addendum M3-16).
    var isWeb: Bool {
        media?.input.isWeb ?? false
    }
    /// ffmpeg's only way to the web for the current video (security review, Plan 4).
    @ObservationIgnored var proxy: WebProxy?
    /// Where the current video came from, which says what to do when the site stops it.
    @ObservationIgnored var origin = VideoOrigin.file
    /// How far the conversion has got, in movie time.
    public internal(set) var convertedEnd: Double?
    public private(set) var artwork: NSImage?
    public private(set) var tvWentAway = false
    public private(set) var showsWelcome: Bool
    /// Whether the remote still explains how to choose the TV: until one has been chosen once.
    public private(set) var showsTVHelp: Bool
    /// A passing message, such as "that file isn't a video". Playback carries on underneath.
    public private(set) var notice: String?
    /// The video's audio tracks and its subtitles (tracks and sidecar files).
    public internal(set) var audioTracks: [AudioTrack] = []
    public internal(set) var subtitleOptions: [SubtitleOption] = []
    /// The same, named for the menus once per video (names take locale lookups).
    public internal(set) var audioChoices: [RemoteState.Choice] = []
    public internal(set) var subtitleChoices: [RemoteState.Choice] = []
    /// The chosen audio track; nil until a session has started.
    public internal(set) var audio: TrackRef?
    /// The chosen subtitles' `SubtitleOption.id`; nil when off.
    public internal(set) var subtitle: String?
    /// Set while a new session starts for a seek or a track change: "Moving to 1:02:03…".
    public internal(set) var loading: String?
    /// The saved details of the last failure, for Show Log.
    public private(set) var failureLog: URL?
    public var volume = 1.0 {
        didSet { player.volume = Float(volume) }
    }
    /// How long a notice stays up.
    @ObservationIgnored var noticeDuration = Duration.seconds(6)

    @ObservationIgnored let environment: Environment
    @ObservationIgnored private let welcomeSeen: @MainActor () -> Void
    @ObservationIgnored private let tvChosen: @MainActor () -> Void
    /// Whether the user paused, as opposed to AVPlayer pausing as the TV dropped out.
    @ObservationIgnored var userPaused = false
    @ObservationIgnored var media: PlaybackMedia?
    @ObservationIgnored var stream: ServedStream?
    /// The text subtitles as WebVTT, once converted.
    @ObservationIgnored var subtitleFiles: SubtitleFiles?
    @ObservationIgnored var extracting: Task<SubtitleFiles?, Never>?
    @ObservationIgnored private var starting: Task<PlayReply, Never>?
    /// A new session for a seek or a track change. Work for a playback or session that has
    /// been replaced finds its task cancelled.
    @ObservationIgnored var restarting: Task<Void, Never>?
    /// While a seek's new session starts: where it goes. The old session plays on meanwhile,
    /// so the clock and the converted-video window leave it alone.
    @ObservationIgnored var seekTarget: Double?
    /// Free space as last asked, which takes milliseconds.
    @ObservationIgnored var freeSpaceChecked: (at: ContinuousClock.Instant, bytes: Int64)?
    /// Finishes once every stream stopped and every start cancelled so far has cleaned up.
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored var watchingEvents: Task<Void, Never>?
    /// The current session's segments still on disk, and its conversion state.
    @ObservationIgnored var segments: [SegmentWindow.Segment] = []
    @ObservationIgnored var conversionPaused = false
    @ObservationIgnored var conversionFinished = false
    @ObservationIgnored var warnedAboutSpace = false
    /// Whether the player opens each session's media playlist instead of its master, for the
    /// rest of this video: once the Mac's player has refused the master because the Mac's
    /// display can't show it (HDR, with an SDR monitor as the main display).
    @ObservationIgnored var opensMediaPlaylist = false
    @ObservationIgnored private var hidingNotice: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Watch the current item for the player refusing it or stalling for good.
    @ObservationIgnored private var itemStatus: NSKeyValueObservation?
    @ObservationIgnored private var itemFailure: (any NSObjectProtocol)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let sleep = SleepAssertion()
    @ObservationIgnored let log = Logger(subsystem: "dev.paperplane.app", category: "playback")

    /// `showsWelcome` is whether the one-time explainer is still due; `welcomeSeen` is called
    /// once it has been dismissed, to remember that. Likewise `showsTVHelp` and `tvChosen`, for
    /// the hint on choosing the TV.
    public init(environment: Environment, showsWelcome: Bool, welcomeSeen: @escaping @MainActor () -> Void,
                showsTVHelp: Bool = true, tvChosen: @escaping @MainActor () -> Void = {}) {
        self.environment = environment
        self.showsWelcome = showsWelcome
        self.welcomeSeen = welcomeSeen
        self.showsTVHelp = showsTVHelp
        self.tvChosen = tvChosen
        player.allowsExternalPlayback = true
        // Subtitles are off unless chosen, whatever the Mac's caption settings say.
        player.appliesMediaSelectionCriteriaAutomatically = false
        observations = [
            player.observe(\.isExternalPlaybackActive) { [weak self] _, _ in
                Task { @MainActor in self?.externalPlaybackChanged() }
            },
            player.observe(\.timeControlStatus) { [weak self] player, _ in
                let paused = player.timeControlStatus == .paused
                Task { @MainActor in self?.isPaused = paused }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.timeChanged(time) }
        }
    }

    // MARK: - State for the UI

    public var isActive: Bool {
        switch phase {
        case .preparing, .waitingForTV, .onTV: true
        case .idle, .failed: false
        }
    }

    /// Whether the Mac is being kept awake (spec §6): while the TV plays.
    var preventsSleep: Bool {
        sleep.isHeld
    }

    // MARK: - Commands

    /// Plays the first video among `urls`, else the first web link (dragged from a browser),
    /// replacing whatever is playing. With neither among them, what's playing carries on and a
    /// notice says why nothing happened.
    public func play(_ urls: [URL]) {
        dismissWelcome()
        if let url = VideoFiles.videos(in: urls).first {
            let input = ResolvedInput.file(url)
            begin(title: input.title, from: .file) { await self.start(input, at: 0) }
        } else if let link = urls.lazy.filter({ !$0.isFileURL }).compactMap({ Links.webLink(in: $0.absoluteString) }).first {
            playLink(link.absoluteString)
        } else if let first = urls.first {
            show(notice: "“\(first.lastPathComponent)” isn't a video file.")
        }
    }

    /// Plays a copied link (Milestone 4, decision 11): straight from a playlist or video file, or
    /// a page through yt-dlp. With no link in `text`, what's playing carries on and a notice says so.
    public func playLink(_ text: String?) {
        dismissWelcome()
        guard let url = Links.webLink(in: text) else {
            show(notice: "Copy a link to a video first, then choose Play Copied Link.")
            return
        }
        if let input = Links.direct(url) {
            begin(title: input.title, from: .link) { await self.start(input, at: 0) }
        } else {
            let title = Links.placeholderTitle(for: url)
            begin(title: title, from: .link) { await self.start(page: url, cookie: nil, title: title, at: nil) }
        }
    }

    /// Plays a video sent from the browser (spec §5.3), `startAt` seconds in, and answers once
    /// it's ready for the TV or with why it can't play, so the browser pauses only when Paper
    /// Plane has it. A page goes to yt-dlp first, whatever the site, as a copied link does; one
    /// it can't make a video of fails with why.
    public func play(_ request: PlayRequest) async -> PlayReply {
        if let refusal = Self.refusal(of: request) {
            return .failed(refusal)
        }
        switch request.source {
        case .stream(let url, let format, let headers):
            let input = ResolvedInput(inputs: [.init(url: url, headers: headers, manifest: format.manifest)], title: request.title)
            return await begin(title: input.title, from: .browser) { await self.start(input, at: request.startAt) }.value
        case .page(let url, let headers):
            // Only a YouTube page's cookie reaches yt-dlp. The button can try any site now, so a
            // non-YouTube page's cookie is withheld here (defence in depth).
            let cookie = Links.isYouTubePage(url) ? headers["Cookie"] : nil
            return await begin(title: request.title, from: .browser) {
                await self.start(page: url, cookie: cookie, title: request.title, at: request.startAt)
            }.value
        }
    }

    /// Why Paper Plane won't play what the browser sent, or nil when it will: every stream, and
    /// every page, since the toolbar button can try any site. What can't be played fails when it's
    /// tried.
    public static func refusal(of request: PlayRequest) -> String? {
        switch request.source {
        case .stream, .page: nil
        }
    }

    /// Replaces whatever is playing with what `start` starts, titled `title` until it knows better.
    @discardableResult
    private func begin(title: String, from origin: VideoOrigin,
                       _ start: @escaping @MainActor () async -> PlayReply) -> Task<PlayReply, Never> {
        dismissWelcome()
        dismissNotice()
        // Keep the player's current item until the new video's replaces it (in load()). Clearing it
        // to nil ends external playback and releases the AirPlay route, which AVFoundation doesn't
        // re-acquire for the next item, so the TV already chosen would have to be picked again
        // (docs/sony-test-results.md, row 9). Swapping one item straight for another keeps the route.
        stop(keepingPlayerItem: true)
        self.title = title
        self.origin = origin
        phase = .preparing
        let task = Task { await start() }
        starting = task
        return task
    }

    public func togglePause() {
        guard phase == .onTV else { return }
        userPaused = !isPaused
        if userPaused {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Stops what's playing and returns to idle, releasing the AirPlay route: the next video has
    /// its TV picked again. `begin()` keeps the route instead (`keepingPlayerItem`).
    public func stop() {
        stop(keepingPlayerItem: false)
    }

    /// `keepingPlayerItem` leaves the player's current item in place so external playback — and so
    /// the chosen TV — carries to the next video, which replaces the item directly. It's set only
    /// by `begin()`, where another video is about to take over.
    private func stop(keepingPlayerItem: Bool) {
        // A cancelled start or session change cleans up after itself (stopping ffmpeg, deleting
        // its folder); a stream has to be stopped, and converted subtitles deleted. Either way
        // shutDown() waits for it.
        let (starting, restarting, stream, extracting, proxy) = (starting, restarting, stream, extracting, proxy)
        starting?.cancel()
        restarting?.cancel()
        extracting?.cancel()
        if starting != nil || restarting != nil || stream != nil || extracting != nil || proxy != nil {
            afterwards {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await stream?.stop()
                        proxy?.stop() // once ffmpeg, which reads through it, has stopped
                    }
                    group.addTask { _ = await starting?.value }
                    group.addTask { await restarting?.value }
                    group.addTask { await extracting?.value?.remove() }
                }
            }
        }
        self.starting = nil
        self.restarting = nil
        self.stream = nil
        self.extracting = nil
        self.proxy = nil
        media = nil
        subtitleFiles = nil
        watchingEvents?.cancel()
        watchingEvents = nil
        player.pause()
        observeItem(nil)
        if !keepingPlayerItem {
            player.replaceCurrentItem(with: nil)
        }
        title = nil
        detail = ""
        artwork = nil
        phase = .idle
        movieTime = 0
        duration = nil
        convertedEnd = nil
        tvWentAway = false
        userPaused = false
        audioTracks = []
        subtitleOptions = []
        audioChoices = []
        subtitleChoices = []
        audio = nil
        subtitle = nil
        loading = nil
        seekTarget = nil
        failureLog = nil
        segments = []
        conversionPaused = false
        conversionFinished = false
        warnedAboutSpace = false
        opensMediaPlaylist = false
    }

    public func dismissWelcome() {
        guard showsWelcome else { return }
        showsWelcome = false
        welcomeSeen()
    }

    public func dismissNotice() {
        hidingNotice?.cancel()
        hidingNotice = nil
        notice = nil
    }

    func show(notice message: String) {
        hidingNotice?.cancel()
        notice = message
        let duration = noticeDuration
        hidingNotice = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Stops what's playing and waits, before the app quits, until every ffmpeg this controller
    /// started has exited and every session folder is deleted.
    public func shutDown() async {
        stop()
        await cleanup?.value
    }

    /// Runs `work` after the cleanup already queued; shutDown() waits for all of it.
    func afterwards(_ work: @escaping @Sendable () async -> Void) {
        let earlier = cleanup
        cleanup = Task {
            await work()
            await earlier?.value
        }
    }

    // MARK: - Starting

    /// Probes `input` and starts its first session `startAt` seconds in (at the live edge for a
    /// live stream). Returns the browser's answer: ok once the video waits for the TV.
    private func start(_ input: ResolvedInput, at startAt: Double) async -> PlayReply {
        do {
            let pipeline = try self.pipeline()
            var input = input
            if input.isWeb {
                // ffmpeg reads the site through the proxy, never directly (security review, Plan 4).
                let proxy = try await WebProxy.start(serving: input)
                guard !Task.isCancelled else {
                    proxy.stop()
                    return replaced
                }
                self.proxy = proxy
                input = proxy.input
            }
            let media = try await environment.probe(pipeline, input)
            try Task.checkCancellation()
            self.media = media
            duration = media.info.duration
            detail = Self.detail(for: media.info)
            audioTracks = media.info.audio
            subtitleOptions = media.subtitles
            audioChoices = zip(media.info.audio, TrackNames.unique(media.info.audio.map(\.displayName)))
                .map { RemoteState.Choice(id: $0.ref.id, name: $1) }
            subtitleChoices = media.subtitles.map {
                RemoteState.Choice(id: $0.id, name: media.subtitleNames[$0.id] ?? $0.displayName)
            }
            startExtractingSubtitles(media, with: pipeline)
            // Subtitles are off unless the file marks a track as forced (spec §4, step 2).
            subtitle = media.subtitles.first(where: \.isForced)?.id
            // (A live stream starts at its live edge whatever this says: see request(at:).)
            let stream = try await environment.startStream(pipeline, media, try await request(at: playable(startAt)))
            guard !Task.isCancelled else {
                await stream.stop()
                return replaced
            }
            adopt(stream)
            phase = .waitingForTV
            externalPlaybackChanged()
            networkChanged() // in case the address changed while this started
            // A web stream's artwork would mean fetching more from the site than playing needs.
            if !input.isWeb, let url = input.inputs.first?.url,
               let jpeg = await environment.thumbnail(pipeline.tools, url, duration), self.stream === stream {
                artwork = NSImage(data: jpeg)
            }
            return .ok
        } catch {
            return failedToStart(input.title, error)
        }
    }

    /// The answer, and the remote's message, for a start that ran into `error`.
    private func failedToStart(_ title: String, _ error: any Error) -> PlayReply {
        // stop() or a newer play() took over: whatever this start ran into, it is no longer this
        // controller's business, and acting on it would stop the newer video.
        guard !Task.isCancelled, !(error is CancellationError) else { return replaced }
        log.error("Couldn't play \(title, privacy: .private): \(String(describing: error), privacy: .private)")
        let message = PlaybackError.message(for: error, origin: origin)
        fail(message, error: error)
        return .failed(message)
    }

    /// Asks yt-dlp for `page`'s video, then starts it.
    private func start(page: URL, cookie: String?, title: String, at startAt: Double?) async -> PlayReply {
        let resolved: ResolvedPage
        do {
            // With no network there's nothing to ask (and the TV couldn't reach the Mac anyway).
            guard environment.host() != nil else { throw PlaybackError.offline }
            resolved = try await resolve(page, cookie: cookie, title: title)
            try Task.checkCancellation()
        } catch {
            return failedToStart(title, error)
        }
        self.title = resolved.input.title
        return await start(resolved.input, at: startAt ?? resolved.startTime ?? 0)
    }

    /// yt-dlp, and once more if it failed and an update brought a newer one (spec §6). A newer
    /// yt-dlp won't reach a site that doesn't answer, make a link to something that isn't a video
    /// into one, or bring Deno.
    private func resolve(_ page: URL, cookie: String?, title: String) async throws -> ResolvedPage {
        do {
            return try await environment.resolvePage(page, cookie, title)
        } catch let failure as YtDlpFailure
                    where ![.timedOut, .unreachable, .unsupported, .needsJavaScriptRuntime].contains(failure) {
            guard (try? await environment.updateYtDlp()) == true else { throw failure }
            try Task.checkCancellation()
            return try await environment.resolvePage(page, cookie, title)
        }
    }

    /// Updates yt-dlp if a day has passed since the last check (spec §5.3).
    public func updateYtDlpIfDue() async {
        _ = await environment.updateYtDlpIfDue()
    }

    /// The answer for a start that stop() or a newer video cancelled.
    private var replaced: PlayReply {
        .failed(phase == .idle ? "Stopped in Paper Plane." : "Another video took its place.")
    }

    /// A pipeline with the current tools, address and settings.
    func pipeline() throws -> StreamPipeline {
        guard let tools = environment.tools() else { throw PlaybackError.noFFmpeg }
        guard let host = environment.host() else { throw PlaybackError.offline }
        return StreamPipeline(tools: tools, folders: environment.folders, profile: environment.settings().profile,
                              host: host)
    }

    /// Converts the text subtitles in the background; sessions started afterwards offer them. A
    /// web stream's would mean downloading all of it to read them.
    private func startExtractingSubtitles(_ media: PlaybackMedia, with pipeline: StreamPipeline) {
        guard media.subtitles.contains(where: \.isText), !media.input.isWeb else { return }
        let environment = environment
        extracting = Task { [weak self] in
            let files = try? await environment.extractSubtitles(pipeline, media)
            if !Task.isCancelled { // stop() cancels it along with its playback
                self?.subtitleFiles = files
            }
            return files
        }
    }

    /// Makes `stream` the one playing: its item goes to the player and its events are watched.
    func adopt(_ stream: ServedStream) {
        // What people watch is private: names, paths and URLs never go to the log in the clear.
        log.info("Serving \(stream.title, privacy: .private) at \(stream.url.absoluteString, privacy: .private)")
        self.stream = stream
        audio = stream.plan.audio
        movieTime = stream.session.offset
        convertedEnd = nil
        segments = []
        conversionPaused = false
        conversionFinished = false
        watchingEvents?.cancel()
        watchingEvents = Task { await watch(stream.session) }
        load(stream)
    }

    /// Gives the player `stream`'s master playlist, or its media playlist once the Mac's display
    /// has refused a master.
    private func load(_ stream: ServedStream) {
        let item = AVPlayerItem(url: opensMediaPlaylist ? stream.mediaPlaylistURL : stream.url)
        observeItem(item)
        player.replaceCurrentItem(with: item)
        applySubtitleSelection()
    }

    /// Stops everything, keeping the title, and shows `message`. With the error behind it, its
    /// details are saved for Show Log.
    func fail(_ message: String, error: (any Error)? = nil) {
        let name = title
        stop()
        title = name
        phase = .failed(message)
        if let error, !(error is PlaybackError) {
            failureLog = environment.saveLog(message, error)
        }
    }

    private func watch(_ session: TranscodeSession) async {
        for await event in session.events {
            switch event {
            case .segment(let index, let end):
                let start = segments.last?.end ?? (convertedEnd.map { $0 - session.offset } ?? 0)
                segments.append(SegmentWindow.Segment(index: index, start: start, end: end))
                convertedEnd = session.offset + end
                // Check on each segment too: copying converts minutes in a second, faster than
                // the playback clock ticks.
                manageWindow()
            case .finished:
                conversionFinished = true
                if proxy?.siteRefused == true {
                    // ffmpeg skipped what the site refused and stopped there.
                    show(notice: "The site stopped sending this video part-way through. "
                        + "\(origin.again.capitalizedFirst) for the rest.")
                } else {
                    convertedEnd = duration ?? convertedEnd
                }
            case .failed(let message):
                log.error("ffmpeg failed: \(message, privacy: .private)")
                let stopped = ConversionStopped(message: message)
                fail(PlaybackError.message(for: stopped, origin: origin), error: stopped)
            }
        }
    }

    private static func detail(for media: MediaInfo) -> String {
        let video = media.video.first
        let hdr: String? = switch video?.hdr {
        case .pq: "HDR10"
        case .hlg: "HLG"
        case nil: nil
        }
        return MediaSummary.text(height: video?.height, hdr: hdr, duration: media.duration)
    }

    // MARK: - Player

    /// `active` overrides the player's own `isExternalPlaybackActive`, for tests: nothing but a
    /// real AirPlay TV can set it.
    func externalPlaybackChanged(active: Bool? = nil) {
        let active = active ?? player.isExternalPlaybackActive
        log.info("External playback active: \(active), phase: \(String(describing: self.phase), privacy: .private)")
        if active {
            guard phase == .waitingForTV else { return }
            phase = .onTV
            if showsTVHelp {
                showsTVHelp = false
                tvChosen()
            }
            let resumesPaused = tvWentAway && userPaused
            tvWentAway = false
            guard !resumesPaused else { return } // the user had paused it before the TV dropped out
            player.play()
            if Self.seeksToStartOnTV, movieTime <= (stream?.session.offset ?? 0) + 1 {
                // Don't wait for the completion handler: over AirPlay it reports finished == false
                // even when the TV did seek (docs/sony-test-results.md, row 7b).
                player.seek(to: .zero)
            }
        } else if phase == .onTV {
            // The TV went away. Never carry on playing on the Mac.
            player.pause()
            tvWentAway = true
            phase = .waitingForTV
        }
    }

    /// Fails with a plain message when the player refuses `item` or can't play on, instead of
    /// waiting for a TV forever. nil stops watching.
    private func observeItem(_ item: AVPlayerItem?) {
        itemStatus = nil
        if let itemFailure {
            NotificationCenter.default.removeObserver(itemFailure)
        }
        itemFailure = nil
        guard let item else { return }
        itemStatus = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error
            Task { @MainActor in self?.playerFailed(item, error: error) }
        }
        itemFailure = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
            MainActor.assumeIsolated { self?.playerFailed(item, error: error) }
        }
    }

    /// The player refused `item` or couldn't play on, for `error`. A master playlist the Mac's
    /// display refused gives way to the media playlist; anything else ends the video.
    func playerFailed(_ item: AVPlayerItem, error: (any Error)?) {
        guard player.currentItem === item else { return }
        if (error as? AVError)?.code == .noCompatibleAlternatesForExternalDisplay, !opensMediaPlaylist, let stream {
            // AVFoundation judges the master's variants by the Mac's display, which may not show
            // HDR (-11868), though the TV can. The media playlist leaves it nothing to judge.
            log.info("The Mac's display refused the master playlist; opening the media playlist")
            opensMediaPlaylist = true
            if let shown = subtitle.flatMap(subtitleOption), shown.isText, stream.plan.burnIn == nil {
                restart(at: nil, loading: "Adding subtitles…") // drawn in: see burnsIn(_:)
            } else {
                load(stream)
            }
            return
        }
        let reason = String(describing: error)
        log.error("The player failed: \(reason, privacy: .private)")
        fail("Paper Plane couldn't play this video. Try another file.", error: PlayerFailed(reason: reason))
    }

    private func timeChanged(_ time: CMTime) {
        guard let stream, phase == .onTV, seekTarget == nil, time.isNumeric else { return }
        movieTime = stream.session.offset + time.seconds
        manageWindow()
    }

    private func updateSleep() {
        sleep.hold(phase == .onTV && !isPaused)
    }
}

/// AVFoundation refused the stream or couldn't play on, for Show Log.
struct PlayerFailed: Error, CustomStringConvertible {
    var reason: String
    var description: String { "The player stopped: \(reason)" }
}

/// ffmpeg failed after the video started playing. `message` is its redacted stderr.
struct ConversionStopped: Error, CustomStringConvertible {
    var message: String
    var description: String { "ffmpeg stopped part-way through:\n\(message)" }
}

/// Where a video came from, which says what to do when its site stops it.
enum VideoOrigin {
    case file
    /// Sent from the browser's toolbar button.
    case browser
    /// A copied or dropped link.
    case link

    /// How to get the video again, in a sentence's own words.
    var again: String {
        switch self {
        case .file: "open the video again"
        case .browser: "reload the page, then click Paper Plane again"
        case .link: "choose Play Copied Link again"
        }
    }
}

extension String {
    /// "Reload the page…" from "reload the page…".
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}

enum PlaybackError: Error {
    case noFFmpeg
    case offline

    /// A site refusing a web stream (spec §6): its link has expired, so the page or the link has
    /// to be fetched again.
    static func siteStopped(_ origin: VideoOrigin) -> String {
        "The site stopped the stream — \(origin.again)."
    }

    /// A plain-language message for the remote. A video from the web isn't a file to try again.
    static func message(for error: any Error, origin: VideoOrigin = .file) -> String {
        let fromTheWeb = origin != .file
        return switch error {
        case let stopped as ConversionStopped:
            SiteRefusal.isRefusal(stderr: stopped.message) ? siteStopped(origin) : "Converting the video stopped part-way through."
        case _ where SiteRefusal.isRefusal(error): siteStopped(origin)
        case PlaybackError.noFFmpeg: "Paper Plane's video converter is missing. Reinstall Paper Plane."
        case PlaybackError.offline: "Your Mac isn't on a network, so the TV can't reach it. Connect to your network and try again."
        case YtDlpFailure.missing: "Paper Plane's YouTube helper is missing. Reinstall Paper Plane."
        case YtDlpFailure.unsupported: "Paper Plane didn't find a video at this link."
        case YtDlpFailure.noPlayableFormat: "Paper Plane can't play this site's kind of stream yet."
        case YtDlpFailure.timedOut: "The site took too long to answer. Try again."
        case YtDlpFailure.unreachable: "Paper Plane couldn't reach the site. Check your connection, then try again."
        case YtDlpFailure.needsJavaScriptRuntime:
            "YouTube now needs Deno to give Paper Plane this video. Install it with \"brew install deno\" in Terminal, then try again."
        case YtDlpFailure.failed(let reason?, _): "Paper Plane couldn't get this video: \(reason)"
        case YtDlpFailure.failed: "Paper Plane couldn't get this video from the page."
        case MediaProbeError.protectedContent: "This video is protected, so Paper Plane can't play it."
        case PlanError.noVideoTrack: fromTheWeb ? "This stream has no video." : "This file has no video."
        case is MediaProbeError where fromTheWeb, is TranscodeError where fromTheWeb:
            "Paper Plane couldn't get this video from the site. \(origin.again.capitalizedFirst)."
        case is MediaProbeError: "Paper Plane couldn't read this file. It may be damaged or not a video."
        case is TranscodeError: "Paper Plane couldn't convert this video. Try another file."
        default: "Something went wrong. Try again, or choose another video." // the details are in Show Log
        }
    }
}
