import AVFoundation
import Foundation
import PaperPlaneCore

/// Seeking anywhere in the movie, changing tracks, keeping the converted-video window and
/// following network changes: each either moves within the current session or starts a new one
/// (spec §4.2, §6).
extension PlaybackController {
    // MARK: - State for the UI

    /// What the remote window shows.
    public var remoteState: RemoteState {
        let remotePhase: RemoteState.Phase = switch phase {
        case .idle: .idle
        case .preparing: .preparing
        case .waitingForTV: .choosingTV(tvWentAway: tvWentAway)
        case .onTV: isPaused ? .paused : .playing
        case .failed(let message): .failed(message)
        }
        let audioNames = TrackNames.unique(audioTracks.map(\.displayName))
        let subtitleNames = TrackNames.unique(subtitleOptions.map(\.displayName))
        return RemoteState(
            phase: remotePhase, title: title ?? "", detail: detail, elapsed: movieTime, duration: duration,
            converted: convertedEnd, volume: volume, showsWelcome: showsWelcome, notice: notice,
            audioChoices: zip(audioTracks, audioNames).map { RemoteState.Choice(id: Self.id(of: $0.ref), name: $1) },
            audio: audio.map(Self.id(of:)),
            subtitleChoices: zip(subtitleOptions, subtitleNames).map { RemoteState.Choice(id: $0.id, name: $1) },
            subtitle: subtitle, loading: loading, canShowLog: failureLog != nil, showsTVHelp: showsTVHelp)
    }

    static func id(of track: TrackRef) -> String {
        "track-\(track.input)-\(track.index)"
    }

    // MARK: - Seeking

    /// Moves by `seconds` (−10 or +10).
    public func skip(by seconds: Double) {
        seek(toMovieTime: movieTime + seconds)
    }

    /// Goes to `time` in the movie. Within what the current session has on disk this is a plain
    /// seek; anywhere else a new session starts there (spec §4.2). The TV seeks whether or not
    /// AirPlay reports it finished (docs/sony-test-results.md, row 7b), so there is nothing to
    /// wait for.
    public func seek(toMovieTime time: Double) {
        guard phase == .onTV, stream != nil else { return }
        // Not past the last second: the end of a file is where conversion would find nothing.
        let target = max(0, duration.map { min(time, max($0 - 1, 0)) } ?? time)
        if let sessionTime = sessionTime(forMovieTime: target) {
            movieTime = target
            player.seek(to: CMTime(seconds: sessionTime, preferredTimescale: 600))
        } else {
            restart(at: target, loading: "Moving to \(TimeText.clock(target))…")
        }
    }

    /// Where `time` is in the current session, if it can be played without a new session: from
    /// the oldest segment still on disk to a second short of what's converted (so the TV never
    /// waits on a segment ffmpeg is still writing), or to the end once conversion has finished.
    func sessionTime(forMovieTime time: Double) -> Double? {
        guard let stream, loading == nil else { return nil }
        let offset = stream.session.offset
        let earliest = offset + (segments.first?.start ?? 0)
        let converted = convertedEnd ?? offset
        let latest = conversionFinished ? converted : converted - 1
        guard time >= earliest, time <= latest else { return nil }
        return time - offset
    }

    // MARK: - Tracks

    /// Switches the audio: a new session at the current time (spec §4.2).
    public func selectAudio(_ id: String) {
        guard stream != nil, let track = audioTracks.first(where: { Self.id(of: $0.ref) == id }),
              track.ref != audio
        else { return }
        audio = track.ref
        restart(at: movieTime, loading: "Switching to \(track.displayName)…")
    }

    /// Shows the subtitles with `SubtitleOption.id` `id`, or none. Text subtitles the session
    /// already offers switch on the spot; anything burned in, or not yet converted when the
    /// session started, takes a new session at the current time.
    public func selectSubtitle(_ id: String?) {
        guard let stream, id != subtitle else { return }
        let option = id.flatMap { id in subtitleOptions.first { $0.id == id } }
        guard id == nil || option != nil else { return }
        subtitle = option?.id
        let burnsIn = option.map { !$0.isText || environment.settings().alwaysBurnInSubtitles } ?? false
        if burnsIn || stream.plan.burnIn != nil {
            restart(at: movieTime, loading: option == nil ? "Turning subtitles off…" : "Adding subtitles…")
        } else if let option, stream.subtitleNames[option.id] == nil {
            restart(at: movieTime, loading: "Adding subtitles…")
        } else {
            applySubtitleSelection()
        }
    }

    /// What a session starting at `start` should show: the chosen audio, and the chosen
    /// subtitles, waiting for them to be converted if need be. Text subtitles that couldn't be
    /// converted are turned off, with a notice, rather than stopping the video.
    func request(at start: Double) async -> StreamRequest {
        var option = subtitle.flatMap { id in subtitleOptions.first { $0.id == id } }
        if option?.isText == true, subtitleFiles == nil, let extracting {
            subtitleFiles = await extracting.value
        }
        if let chosen = option, chosen.isText, subtitleFiles?.files[chosen.id] == nil {
            subtitle = nil
            option = nil
            show(notice: "Paper Plane couldn't read the subtitles “\(chosen.displayName)”.")
        }
        let burnIn = option.flatMap { !$0.isText || environment.settings().alwaysBurnInSubtitles ? $0 : nil }
        return StreamRequest(start: start, audio: audio, burnIn: burnIn, subtitles: subtitleFiles)
    }

    /// Selects the chosen subtitles among the current item's options, matched by their name in
    /// the master playlist (AVFoundation names options by language, so the NAME is the title).
    func applySubtitleSelection() {
        guard let stream, let item = player.currentItem else { return }
        let name = stream.plan.burnIn == nil ? subtitle.flatMap { stream.subtitleNames[$0] } : nil
        Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            var chosen: AVMediaSelectionOption?
            if let name {
                for option in group.options {
                    let titles = AVMetadataItem.metadataItems(from: option.commonMetadata,
                                                              filteredByIdentifier: .commonIdentifierTitle)
                    if let title = try? await titles.first?.load(.stringValue), title == name {
                        chosen = option
                        break
                    }
                }
            }
            guard let self, self.player.currentItem === item else { return }
            item.select(chosen, in: group) // nil turns subtitles off
        }
    }

    // MARK: - New sessions

    /// Starts a new session at movie time `time` with the current choices, replacing the playing
    /// one when it's ready. A newer seek or track change replaces this one.
    func restart(at time: Double, loading text: String) {
        guard let media else { return }
        if let earlier = restarting {
            earlier.cancel()
            afterwards { await earlier.value }
        }
        loading = text
        movieTime = time
        let generation = generation
        restarting = Task {
            do {
                let pipeline = try self.pipeline()
                let request = await self.request(at: time)
                let stream = try await environment.startStream(pipeline, media, request)
                guard !Task.isCancelled, self.generation == generation else {
                    await stream.stop()
                    return
                }
                let old = self.stream
                adopt(stream)
                afterwards { await old?.stop() }
                loading = nil
                restarting = nil
                if phase == .onTV {
                    if !userPaused {
                        player.play()
                    }
                    // In case the TV starts the new, still-growing playlist at its live edge. Don't
                    // wait: over AirPlay the completion reports false even when the TV seeks.
                    player.seek(to: .zero) { _ in }
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self.generation == generation else { return }
                log.error("Couldn't start a new session: \(String(describing: error), privacy: .private)")
                fail(PlaybackError.message(for: error), error: error)
            }
        }
    }

    /// The Mac's network changed. If its address moved, the TV can no longer reach the stream,
    /// so serve it again from the new address at the current time (spec §6).
    public func networkChanged() {
        guard let stream, loading == nil, let host = environment.host(),
              host != stream.server.baseURL.host()
        else { return }
        restart(at: movieTime, loading: "Reconnecting…")
    }

    // MARK: - The converted-video window

    /// Keeps converting ahead of the player, rests ffmpeg when it's far enough ahead, and deletes
    /// what the player has left behind (spec §4.2). With little disk space, keeps less ahead and
    /// says so once.
    func manageWindow() {
        guard let stream else { return }
        let free = environment.freeSpace() ?? .max
        let window = SegmentWindow.forFreeSpace(free)
        let actions = window.actions(playhead: movieTime - stream.session.offset, segments: segments,
                                     conversionPaused: conversionPaused, conversionFinished: conversionFinished)
        for action in actions {
            switch action {
            case .pauseConversion:
                stream.session.pause()
                conversionPaused = true
            case .resumeConversion:
                stream.session.resume()
                conversionPaused = false
            case .delete(let old):
                stream.session.delete(old)
                segments.removeFirst(old.count)
            }
        }
        if free < 1_000_000_000, !warnedAboutSpace {
            warnedAboutSpace = true
            show(notice: "Your Mac is low on disk space, so Paper Plane converts only a few minutes ahead.")
        }
    }
}
