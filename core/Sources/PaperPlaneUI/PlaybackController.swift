import AppKit
import AVFoundation
import Observation
import os
import PaperPlaneCore

/// Plays one video at a time on the TV: probe → plan → transcode → serve → AVPlayer → AirPlay
/// (spec §4). Seeking past what's converted, track changes and recovery come with Milestone 2.
@MainActor @Observable
public final class PlaybackController {
    /// What the controller needs from the outside world, so tests can stand in for it.
    public struct Environment: Sendable {
        /// ffmpeg and ffprobe, or nil when missing.
        public var tools: @Sendable () -> ToolPaths?
        /// The address the stream server listens on, or nil when the Mac is offline.
        public var host: @Sendable () -> String?
        public var folders: SessionFolders
        public var profile: OutputProfile
        /// Probe → plan → transcode → serve.
        public var startStream: @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream
        /// A JPEG for the artwork.
        public var thumbnail: @Sendable (ToolPaths, URL, Double?) async -> Data?

        public init(tools: @escaping @Sendable () -> ToolPaths?, host: @escaping @Sendable () -> String?,
                    folders: SessionFolders = .standard, profile: OutputProfile = .default,
                    startStream: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream
                        = { try await $0.start($1) },
                    thumbnail: @escaping @Sendable (ToolPaths, URL, Double?) async -> Data? = { tools, url, duration in
                        await Thumbnail.jpeg(tools: tools, input: .init(url: url), at: Thumbnail.moment(duration: duration))
                    }) {
            self.tools = tools
            self.host = host
            self.folders = folders
            self.profile = profile
            self.startStream = startStream
            self.thumbnail = thumbnail
        }

        /// The app's own: the ffmpeg in its bundle (or Homebrew's in a development build) and the
        /// Mac's LAN address.
        public static func live(bundleURL: URL) -> Environment {
            Environment(tools: { ToolPaths.inBundle(at: bundleURL) ?? ToolPaths.locate() },
                        host: { LANAddress.current() })
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
    public private(set) var phase = Phase.idle
    public private(set) var title: String?
    public private(set) var detail = ""
    public private(set) var isPaused = true
    public private(set) var movieTime = 0.0
    public private(set) var duration: Double?
    /// How far the conversion has got, in movie time.
    public private(set) var convertedEnd: Double?
    public private(set) var artwork: NSImage?
    public private(set) var tvWentAway = false
    public private(set) var showsWelcome: Bool
    /// A passing message, such as "that file isn't a video". Playback carries on underneath.
    public private(set) var notice: String?
    /// How long a notice stays up.
    @ObservationIgnored var noticeDuration = Duration.seconds(6)
    public var volume = 1.0 {
        didSet { player.volume = Float(volume) }
    }

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private let welcomeSeen: @MainActor () -> Void
    @ObservationIgnored private var pausedWhenTVWentAway = false
    @ObservationIgnored private var stream: ServedStream?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// Finishes once every stream stopped and every start cancelled so far has cleaned up.
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var watchingEvents: Task<Void, Never>?
    @ObservationIgnored private var hidingNotice: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Watch the current item for the player refusing it or stalling for good.
    @ObservationIgnored private var itemStatus: NSKeyValueObservation?
    @ObservationIgnored private var itemFailure: (any NSObjectProtocol)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let log = Logger(subsystem: "dev.paperplane.app", category: "playback")

    /// `showsWelcome` is whether the one-time explainer is still due; `welcomeSeen` is called
    /// once it has been dismissed, to remember that.
    public init(environment: Environment, showsWelcome: Bool, welcomeSeen: @escaping @MainActor () -> Void) {
        self.environment = environment
        self.showsWelcome = showsWelcome
        self.welcomeSeen = welcomeSeen
        player.allowsExternalPlayback = true
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

    /// What the remote window shows.
    public var remoteState: RemoteState {
        let remotePhase: RemoteState.Phase = switch phase {
        case .idle: .idle
        case .preparing: .preparing
        case .waitingForTV: .choosingTV(tvWentAway: tvWentAway)
        case .onTV: isPaused ? .paused : .playing
        case .failed(let message): .failed(message)
        }
        return RemoteState(phase: remotePhase, title: title ?? "", detail: detail, elapsed: movieTime,
                           duration: duration, converted: convertedEnd, volume: volume, showsWelcome: showsWelcome,
                           notice: notice)
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
        title = url.deletingPathExtension().lastPathComponent
        phase = .preparing
        starting = Task { await start(url) }
    }

    public func togglePause() {
        guard phase == .onTV else { return }
        if isPaused {
            player.play()
        } else {
            player.pause()
        }
    }

    /// Moves by `seconds` (−10 or +10), within what has been converted so far.
    public func skip(by seconds: Double) {
        seek(toMovieTime: movieTime + seconds)
    }

    /// Goes to `time` in the movie. Until Milestone 2 restarts the conversion for a seek, it stays
    /// within what has been converted. The TV seeks whether or not AirPlay reports it finished
    /// (docs/sony-test-results.md, row 7b), so there is nothing to wait for.
    public func seek(toMovieTime time: Double) {
        guard phase == .onTV, let stream else { return }
        let offset = stream.session.offset
        let latest = max(offset, (convertedEnd ?? movieTime) - 1)
        let target = min(max(time, offset), latest)
        movieTime = target
        player.seek(to: CMTime(seconds: target - offset, preferredTimescale: 600))
    }

    public func stop() {
        // A cancelled start cleans up after itself (stopping ffmpeg, deleting its folder); a
        // stream has to be stopped. Either way shutDown() waits for it.
        let starting = starting
        let stream = stream
        starting?.cancel()
        if starting != nil || stream != nil {
            let earlier = cleanup
            cleanup = Task {
                await stream?.stop()
                await starting?.value
                await earlier?.value
            }
        }
        self.starting = nil
        self.stream = nil
        watchingEvents?.cancel()
        watchingEvents = nil
        player.pause()
        itemStatus = nil
        if let itemFailure {
            NotificationCenter.default.removeObserver(itemFailure)
        }
        itemFailure = nil
        player.replaceCurrentItem(with: nil)
        title = nil
        detail = ""
        artwork = nil
        phase = .idle
        movieTime = 0
        duration = nil
        convertedEnd = nil
        tvWentAway = false
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

    private func show(notice message: String) {
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

    // MARK: - Starting

    private func start(_ url: URL) async {
        do {
            guard let tools = environment.tools() else { throw PlaybackError.noFFmpeg }
            guard let host = environment.host() else { throw PlaybackError.offline }
            let pipeline = StreamPipeline(tools: tools, folders: environment.folders, profile: environment.profile,
                                          host: host)
            let stream = try await environment.startStream(pipeline, .file(url))
            guard !Task.isCancelled else {
                await stream.stop()
                return
            }
            // What people watch is private: names, paths and URLs never go to the log in the clear.
            log.info("Serving \(stream.title, privacy: .private) at \(stream.url.absoluteString, privacy: .private)")
            self.stream = stream
            duration = stream.media.duration
            movieTime = stream.session.offset
            detail = Self.detail(for: stream.media)
            watchingEvents = Task { await watch(stream.session) }
            let item = AVPlayerItem(url: stream.url)
            watchForFailure(of: item)
            player.replaceCurrentItem(with: item)
            phase = .waitingForTV
            externalPlaybackChanged()
            if let jpeg = await environment.thumbnail(tools, url, duration), self.stream === stream {
                artwork = NSImage(data: jpeg)
            }
        } catch {
            // stop() or a newer play() took over: whatever this start ran into, it is no longer
            // this controller's business, and acting on it would stop the newer video.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            log.error("Couldn't play \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .private)")
            fail(PlaybackError.message(for: error))
        }
    }

    /// Stops everything, keeping the title, and shows `message`.
    private func fail(_ message: String) {
        let name = title
        stop()
        title = name
        phase = .failed(message)
    }

    private func watch(_ session: TranscodeSession) async {
        for await event in session.events {
            switch event {
            case .segment(_, let end):
                convertedEnd = session.offset + end
            case .finished:
                convertedEnd = duration ?? convertedEnd
            case .failed(let message):
                log.error("ffmpeg failed: \(message, privacy: .private)")
                fail("Converting the video stopped part-way through.")
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
            let resumesPaused = tvWentAway && pausedWhenTVWentAway
            tvWentAway = false
            guard !resumesPaused else { return } // it was paused before the TV dropped out
            player.play()
            if Self.seeksToStartOnTV, movieTime <= (stream?.session.offset ?? 0) + 1 {
                // Don't wait for the completion handler: over AirPlay it reports finished == false
                // even when the TV did seek (docs/sony-test-results.md, row 7b).
                player.seek(to: .zero)
            }
        } else if phase == .onTV {
            // The TV went away. Never carry on playing on the Mac.
            pausedWhenTVWentAway = isPaused
            player.pause()
            tvWentAway = true
            phase = .waitingForTV
        }
    }

    /// Fails with a plain message when the player refuses `item` or can't play on, instead of
    /// waiting for a TV forever.
    private func watchForFailure(of item: AVPlayerItem) {
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
        guard let stream, phase == .onTV, time.isNumeric else { return }
        movieTime = stream.session.offset + time.seconds
    }
}

enum PlaybackError: Error {
    case noFFmpeg
    case offline

    /// A plain-language message for the remote. Full error handling is Milestone 2.
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
