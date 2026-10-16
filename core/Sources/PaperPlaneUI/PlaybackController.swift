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
            saveLog: @escaping @Sendable (String, any Error) -> URL? = { FailureLog.save(message: $0, error: $1) }
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
        }

        /// The app's own: the ffmpeg in its bundle and the Mac's LAN address. Only a development
        /// build (`fallsBackToInstalledFFmpeg`) may use an ffmpeg from PATH or Homebrew instead:
        /// a release must never run whatever happens to be installed under that name.
        public static func live(bundleURL: URL, fallsBackToInstalledFFmpeg: Bool,
                                settings: @escaping @Sendable () -> PlaybackSettings) -> Environment {
            Environment(tools: {
                            ToolPaths.inBundle(at: bundleURL) ?? (fallsBackToInstalledFFmpeg ? ToolPaths.locate() : nil)
                        },
                        host: { LANAddress.current() },
                        settings: settings)
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
    /// Counts playbacks, so work for an earlier one can tell it has been replaced.
    @ObservationIgnored var generation = 0
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// A new session for a seek or a track change.
    @ObservationIgnored var restarting: Task<Void, Never>?
    /// Finishes once every stream stopped and every start cancelled so far has cleaned up.
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored var watchingEvents: Task<Void, Never>?
    /// The current session's segments still on disk, and its conversion state.
    @ObservationIgnored var segments: [SegmentWindow.Segment] = []
    @ObservationIgnored var conversionPaused = false
    @ObservationIgnored var conversionFinished = false
    @ObservationIgnored var warnedAboutSpace = false
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

    /// Plays the first video among `urls`, replacing whatever is playing. With no video among
    /// them, what's playing carries on and a notice says why nothing happened.
    public func play(_ urls: [URL]) {
        if showsWelcome {
            dismissWelcome()
        }
        guard let url = VideoFiles.videos(in: urls).first else {
            if let first = urls.first {
                show(notice: "“\(first.lastPathComponent)” isn't a video file.")
            }
            return
        }
        dismissNotice()
        stop()
        title = ResolvedInput.file(url).title
        phase = .preparing
        starting = Task { await start(url) }
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

    public func stop() {
        // A cancelled start or session change cleans up after itself (stopping ffmpeg, deleting
        // its folder); a stream has to be stopped, and converted subtitles deleted. Either way
        // shutDown() waits for it.
        let (starting, restarting, stream, extracting) = (starting, restarting, stream, extracting)
        starting?.cancel()
        restarting?.cancel()
        extracting?.cancel()
        if starting != nil || restarting != nil || stream != nil || extracting != nil {
            afterwards {
                await stream?.stop()
                await starting?.value
                await restarting?.value
                await extracting?.value?.remove()
            }
        }
        generation += 1
        self.starting = nil
        self.restarting = nil
        self.stream = nil
        self.extracting = nil
        media = nil
        subtitleFiles = nil
        watchingEvents?.cancel()
        watchingEvents = nil
        player.pause()
        observeItem(nil)
        player.replaceCurrentItem(with: nil)
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
        audio = nil
        subtitle = nil
        loading = nil
        failureLog = nil
        segments = []
        conversionPaused = false
        conversionFinished = false
        warnedAboutSpace = false
    }

    public func dismissWelcome() {
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

    private func start(_ url: URL) async {
        do {
            let pipeline = try self.pipeline()
            let media = try await environment.probe(pipeline, .file(url))
            try Task.checkCancellation()
            self.media = media
            duration = media.info.duration
            detail = Self.detail(for: media.info)
            audioTracks = media.info.audio
            subtitleOptions = media.subtitles
            startExtractingSubtitles(media, with: pipeline)
            // Subtitles are off unless the file marks a track as forced (spec §4, step 2).
            subtitle = media.subtitles.first(where: \.isForced)?.id
            let stream = try await environment.startStream(pipeline, media, await request(at: 0))
            guard !Task.isCancelled else {
                await stream.stop()
                return
            }
            adopt(stream)
            phase = .waitingForTV
            externalPlaybackChanged()
            if let jpeg = await environment.thumbnail(pipeline.tools, url, duration), self.stream === stream {
                artwork = NSImage(data: jpeg)
            }
        } catch {
            // stop() or a newer play() took over: whatever this start ran into, it is no longer
            // this controller's business, and acting on it would stop the newer video.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            log.error("Couldn't play \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .private)")
            fail(PlaybackError.message(for: error), error: error)
        }
    }

    /// A pipeline with the current tools, address and settings.
    func pipeline() throws -> StreamPipeline {
        guard let tools = environment.tools() else { throw PlaybackError.noFFmpeg }
        guard let host = environment.host() else { throw PlaybackError.offline }
        return StreamPipeline(tools: tools, folders: environment.folders, profile: environment.settings().profile,
                              host: host)
    }

    /// Converts the text subtitles in the background; sessions started afterwards offer them.
    private func startExtractingSubtitles(_ media: PlaybackMedia, with pipeline: StreamPipeline) {
        guard media.subtitles.contains(where: \.isText) else { return }
        let generation = generation
        let environment = environment
        extracting = Task { [weak self] in
            let files = try? await environment.extractSubtitles(pipeline, media)
            if let self, self.generation == generation {
                self.subtitleFiles = files
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
        let item = AVPlayerItem(url: stream.url)
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
                convertedEnd = duration ?? convertedEnd
            case .failed(let message):
                log.error("ffmpeg failed: \(message, privacy: .private)")
                fail("Converting the video stopped part-way through.", error: ConversionStopped(message: message))
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
            let reason = String(describing: item.error)
            Task { @MainActor in self?.playerFailed(item, reason: reason) }
        }
        itemFailure = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] notification in
            let reason = String(describing: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey])
            MainActor.assumeIsolated { self?.playerFailed(item, reason: reason) }
        }
    }

    private func playerFailed(_ item: AVPlayerItem, reason: String) {
        guard player.currentItem === item else { return }
        log.error("The player failed: \(reason, privacy: .private)")
        fail("Paper Plane couldn't play this video. Try another file.")
    }

    private func timeChanged(_ time: CMTime) {
        guard let stream, phase == .onTV, loading == nil, time.isNumeric else { return }
        movieTime = stream.session.offset + time.seconds
        manageWindow()
    }

    private func updateSleep() {
        sleep.hold(phase == .onTV && !isPaused)
    }
}

/// ffmpeg failed after the video started playing. `message` is its redacted stderr.
struct ConversionStopped: Error, CustomStringConvertible {
    var message: String
    var description: String { "ffmpeg stopped part-way through:\n\(message)" }
}

enum PlaybackError: Error {
    case noFFmpeg
    case offline

    /// A plain-language message for the remote.
    static func message(for error: any Error) -> String {
        switch error {
        case PlaybackError.noFFmpeg: "Paper Plane's video converter is missing. Reinstall Paper Plane."
        case PlaybackError.offline: "Your Mac isn't on a network, so the TV can't reach it. Connect to Wi-Fi and try again."
        case PlanError.noVideoTrack: "This file has no video."
        case is MediaProbeError: "Paper Plane couldn't read this file. It may be damaged or not a video."
        case is TranscodeError: "Paper Plane couldn't convert this video. Try another file."
        default: "Something went wrong (\(error.localizedDescription)). Try again."
        }
    }
}
