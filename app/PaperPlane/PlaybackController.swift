import AppKit
import AVFoundation
import Observation
import os
import PaperPlaneCore
import PaperPlaneUI

/// Plays one video at a time on the TV: probe → plan → transcode → serve → AVPlayer → AirPlay
/// (spec §4). Seeking past what's converted, track changes and recovery come with Milestone 2.
@MainActor @Observable
final class PlaybackController {
    enum Phase: Equatable {
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
    private static let welcomeKey = "didShowWelcome"

    let player = AVPlayer()
    private(set) var phase = Phase.idle
    private(set) var title: String?
    private(set) var detail = ""
    private(set) var isPaused = true
    private(set) var movieTime = 0.0
    private(set) var duration: Double?
    /// How far the conversion has got, in movie time.
    private(set) var convertedEnd: Double?
    private(set) var artwork: NSImage?
    private(set) var tvWentAway = false
    private(set) var showsWelcome = !UserDefaults.standard.bool(forKey: welcomeKey)
    var volume = 1.0 {
        didSet { player.volume = Float(volume) }
    }

    @ObservationIgnored private var stream: ServedStream?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var watchingEvents: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let log = Logger(subsystem: "dev.paperplane.app", category: "playback")

    init() {
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

    var isActive: Bool {
        switch phase {
        case .preparing, .waitingForTV, .onTV: true
        case .idle, .failed: false
        }
    }

    /// What the remote window shows.
    var remoteState: RemoteState {
        let remotePhase: RemoteState.Phase = switch phase {
        case .idle: .idle
        case .preparing: .preparing
        case .waitingForTV: .choosingTV(tvWentAway: tvWentAway)
        case .onTV: isPaused ? .paused : .playing
        case .failed(let message): .failed(message)
        }
        return RemoteState(phase: remotePhase, title: title ?? "", detail: detail, elapsed: movieTime,
                           duration: duration, converted: convertedEnd, volume: volume, showsWelcome: showsWelcome)
    }

    // MARK: - Commands

    /// Plays the first video among `urls`, replacing whatever is playing.
    func play(_ urls: [URL]) {
        showsWelcome = false
        guard let url = VideoFiles.videos(in: urls).first else {
            if let first = urls.first {
                stop()
                title = first.lastPathComponent
                phase = .failed("“\(first.lastPathComponent)” isn't a video file.")
            }
            return
        }
        stop()
        title = url.deletingPathExtension().lastPathComponent
        phase = .preparing
        starting = Task { await start(url) }
    }

    func togglePause() {
        guard phase == .onTV else { return }
        if isPaused {
            player.play()
        } else {
            player.pause()
        }
    }

    /// Moves by `seconds` (−10 or +10), within what has been converted so far.
    func skip(by seconds: Double) {
        seek(toMovieTime: movieTime + seconds)
    }

    /// Goes to `time` in the movie. Until Milestone 2 restarts the conversion for a seek, it stays
    /// within what has been converted. The TV seeks whether or not AirPlay reports it finished
    /// (docs/sony-test-results.md, row 7b), so there is nothing to wait for.
    func seek(toMovieTime time: Double) {
        guard phase == .onTV, let stream else { return }
        let offset = stream.session.offset
        let latest = max(offset, (convertedEnd ?? movieTime) - 1)
        let target = min(max(time, offset), latest)
        movieTime = target
        player.seek(to: CMTime(seconds: target - offset, preferredTimescale: 600))
    }

    func stop() {
        starting?.cancel()
        starting = nil
        watchingEvents?.cancel()
        watchingEvents = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let stream {
            Task { await stream.stop() }
        }
        stream = nil
        title = nil
        detail = ""
        artwork = nil
        phase = .idle
        movieTime = 0
        duration = nil
        convertedEnd = nil
        tvWentAway = false
    }

    func dismissWelcome() {
        showsWelcome = false
        UserDefaults.standard.set(true, forKey: Self.welcomeKey)
    }

    /// Stops ffmpeg and waits for it, before the app quits. A start still in progress is
    /// cancelled and awaited too: its cleanup stops ffmpeg and deletes its session folder.
    func shutDown() async {
        let stream = stream
        let starting = starting
        stop()
        await starting?.value
        await stream?.stop()
    }

    // MARK: - Starting

    private func start(_ url: URL) async {
        do {
            guard let tools = ToolPaths.inBundle(at: Bundle.main.bundleURL) ?? ToolPaths.locate() else {
                throw PlaybackError.noFFmpeg
            }
            guard let host = LANAddress.current() else { throw PlaybackError.offline }
            let stream = try await StreamPipeline(tools: tools, host: host).start(.file(url))
            guard !Task.isCancelled else {
                await stream.stop()
                return
            }
            log.info("Serving \(stream.title, privacy: .public) at \(stream.url.absoluteString, privacy: .private)")
            self.stream = stream
            duration = stream.media.duration
            movieTime = stream.session.offset
            detail = Self.detail(for: stream.media)
            watchingEvents = Task { await watch(stream.session) }
            player.replaceCurrentItem(with: AVPlayerItem(url: stream.url))
            phase = .waitingForTV
            externalPlaybackChanged()
            if let jpeg = await Thumbnail.jpeg(tools: tools, input: .init(url: url),
                                                at: Thumbnail.moment(duration: duration)),
               self.stream === stream {
                artwork = NSImage(data: jpeg)
            }
        } catch is CancellationError {
            // stop() or a newer play() took over.
        } catch {
            log.error("Couldn't play \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            let name = title
            stop()
            title = name
            phase = .failed(PlaybackError.message(for: error))
        }
    }

    private func watch(_ session: TranscodeSession) async {
        for await event in session.events {
            switch event {
            case .segment(_, let end):
                convertedEnd = session.offset + end
            case .finished:
                convertedEnd = duration ?? convertedEnd
            case .failed(let message):
                log.error("ffmpeg failed: \(message, privacy: .public)")
                let name = title
                stop()
                title = name
                phase = .failed("Converting the video stopped part-way through.")
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

    private func externalPlaybackChanged() {
        log.info("External playback active: \(self.player.isExternalPlaybackActive), phase: \(String(describing: self.phase), privacy: .public)")
        if player.isExternalPlaybackActive {
            guard phase == .waitingForTV else { return }
            phase = .onTV
            tvWentAway = false
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
        case PlaybackError.noFFmpeg: "ffmpeg is missing. Run scripts/build-ffmpeg.sh, or brew install ffmpeg."
        case PlaybackError.offline: "Your Mac isn't on a network, so the TV can't reach it."
        case PlanError.noVideoTrack: "This file has no video."
        case is MediaProbeError: "Paper Plane couldn't read this file. It may be damaged or not a video."
        case is TranscodeError: "Converting the video failed."
        default: "Something went wrong: \(error.localizedDescription)"
        }
    }
}
