import AVFoundation
import Observation
import os
import PaperPlaneCore

/// Plays one video at a time on the TV: probe → plan → transcode → serve → AVPlayer → AirPlay
/// (spec §4). Basic for now; seeking, track changes and recovery come with Milestone 2.
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

    let player = AVPlayer()
    private(set) var phase = Phase.idle
    private(set) var title: String?
    private(set) var isPaused = true
    private(set) var movieTime = 0.0
    private(set) var duration: Double?

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

    var isOnTV: Bool { phase == .onTV }
    var needsTV: Bool { phase == .waitingForTV }

    var status: String {
        switch phase {
        case .idle: "Drop a video here, or use Open Video… in the menu bar."
        case .preparing: "Getting the video ready…"
        case .waitingForTV: "Choose your TV with the AirPlay button."
        case .onTV: isPaused ? "Paused on the TV" : "Playing on the TV"
        case .failed(let message): message
        }
    }

    var timeText: String {
        guard isActive else { return "" }
        let elapsed = Self.clock(movieTime)
        return duration.map { "\(elapsed) / \(Self.clock($0))" } ?? elapsed
    }

    // MARK: - Commands

    /// Plays the first video among `urls`, replacing whatever is playing.
    func play(_ urls: [URL]) {
        guard let url = VideoFiles.videos(in: urls).first else {
            if let first = urls.first {
                stop()
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
        phase = .idle
        movieTime = 0
        duration = nil
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
            watchingEvents = Task { await watch(stream.session) }
            player.replaceCurrentItem(with: AVPlayerItem(url: stream.url))
            phase = .waitingForTV
            externalPlaybackChanged()
        } catch is CancellationError {
            // stop() or a newer play() took over.
        } catch {
            log.error("Couldn't play \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            stop()
            phase = .failed(PlaybackError.message(for: error))
        }
    }

    private func watch(_ session: TranscodeSession) async {
        for await event in session.events {
            if case .failed(let message) = event {
                log.error("ffmpeg failed: \(message, privacy: .public)")
                stop()
                phase = .failed("Converting the video stopped part-way through.")
            }
        }
    }

    // MARK: - Player

    private func externalPlaybackChanged() {
        log.info("External playback active: \(self.player.isExternalPlaybackActive), phase: \(String(describing: self.phase), privacy: .public)")
        if player.isExternalPlaybackActive {
            guard phase == .waitingForTV else { return }
            phase = .onTV
            player.play()
            if Self.seeksToStartOnTV {
                // Don't wait for the completion handler: over AirPlay it reports finished == false
                // even when the TV did seek (docs/sony-test-results.md, row 7b).
                player.seek(to: .zero)
            }
        } else if phase == .onTV {
            // The TV went away. Never carry on playing on the Mac.
            player.pause()
            phase = .waitingForTV
        }
    }

    private func timeChanged(_ time: CMTime) {
        guard let stream, time.isNumeric else { return }
        movieTime = stream.session.offset + time.seconds
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
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
        case is MediaProbeError: "Paper Plane couldn't read this file."
        case is TranscodeError: "Converting the video failed."
        default: "Something went wrong: \(error.localizedDescription)"
        }
    }
}
