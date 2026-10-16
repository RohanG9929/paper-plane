import AppKit
import MediaPlayer
import Observation

/// Shows what's playing in Control Center and answers the media keys and headphone buttons
/// (spec §4, step 6).
@MainActor
public final class NowPlaying {
    /// What a media key or Control Center asks for.
    public enum Command: Equatable, Sendable {
        case togglePlayPause, play, pause, stop
        case skip(Double)
        case seek(to: Double)
    }

    private let controller: PlaybackController
    private var published: Published?
    private var targets: [(MPRemoteCommand, Any)] = []

    /// What was last handed to Control Center, which works out the elapsed time itself from the
    /// rate; a new value only goes out when something else changes or playback jumps.
    struct Published: Equatable {
        var title: String
        var duration: Double?
        var elapsed: Double
        var isPlaying: Bool
        var hasArtwork: Bool
        var at: Date

        func differs(from next: Published) -> Bool {
            let expected = elapsed + (isPlaying ? next.at.timeIntervalSince(at) : 0)
            return title != next.title || duration != next.duration || isPlaying != next.isPlaying
                || hasArtwork != next.hasArtwork || abs(next.elapsed - expected) > 1.5
        }
    }

    public init(controller: PlaybackController) {
        self.controller = controller
    }

    /// Starts answering commands and following the controller.
    public func start() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        let handlers: [(MPRemoteCommand, @Sendable (MPRemoteCommandEvent) -> Command?)] = [
            (center.togglePlayPauseCommand, { _ in .togglePlayPause }),
            (center.playCommand, { _ in .play }),
            (center.pauseCommand, { _ in .pause }),
            (center.stopCommand, { _ in .stop }),
            (center.skipForwardCommand, { _ in .skip(10) }),
            (center.skipBackwardCommand, { _ in .skip(-10) }),
            (center.changePlaybackPositionCommand, { event in
                (event as? MPChangePlaybackPositionCommandEvent).map { .seek(to: $0.positionTime) }
            }),
        ]
        for (command, makeCommand) in handlers {
            let target = command.addTarget(handler: Self.handler(makeCommand) { [weak self] in
                self?.handle($0) == true
            })
            targets.append((command, target))
        }
        follow()
    }

    /// MediaPlayer doesn't promise which thread runs a command's handler, so the handler isn't
    /// isolated to the main actor: on the main thread it acts at once and says whether it did;
    /// elsewhere it hands the command over.
    private nonisolated static func handler(
        _ makeCommand: @escaping @Sendable (MPRemoteCommandEvent) -> Command?,
        perform: @escaping @MainActor @Sendable (Command) -> Bool
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let command = makeCommand(event) else { return .commandFailed }
            guard Thread.isMainThread else {
                Task { @MainActor in _ = perform(command) }
                return .success
            }
            return MainActor.assumeIsolated { perform(command) } ? .success : .noActionableNowPlayingItem
        }
    }

    /// Does what `command` asks, if a video is on the TV. Returns whether it did.
    @discardableResult
    func handle(_ command: Command) -> Bool {
        guard controller.phase == .onTV else {
            return false
        }
        switch command {
        case .togglePlayPause: controller.togglePause()
        case .play: if controller.isPaused { controller.togglePause() }
        case .pause: if !controller.isPaused { controller.togglePause() }
        case .stop: controller.stop()
        case .skip(let seconds): controller.skip(by: seconds)
        case .seek(let time): controller.seek(toMovieTime: time)
        }
        return true
    }

    /// Re-publishes whenever what Control Center shows would change.
    private func follow() {
        observeContinuously { [weak self] in self?.publish() }
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        guard controller.isActive, let title = controller.title else {
            if published != nil {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
                published = nil
            }
            return
        }
        let next = Published(title: title, duration: controller.duration, elapsed: controller.movieTime,
                             isPlaying: controller.phase == .onTV && !controller.isPaused,
                             hasArtwork: controller.artwork != nil, at: .now)
        guard published.map({ $0.differs(from: next) }) ?? true else { return }
        published = next
        center.nowPlayingInfo = Self.info(next, artwork: controller.artwork)
        center.playbackState = next.isPlaying ? .playing : .paused
    }

    static func info(_ state: Published, artwork: NSImage?) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyMediaType: MPMediaType.movie.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
        ]
        if let duration = state.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.artwork(artwork)
        }
        return info
    }

    /// MediaPlayer calls the image handler on a queue of its own, so it must not be isolated to
    /// the main actor, as a closure written inside this class would be.
    private nonisolated static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
