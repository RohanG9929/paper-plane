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
        return RemoteState(
            phase: remotePhase, title: title ?? "", detail: detail, elapsed: movieTime, duration: duration,
            converted: convertedEnd, volume: volume, showsWelcome: showsWelcome, notice: notice,
            audioChoices: audioChoices, audio: audio?.id, subtitleChoices: subtitleChoices, subtitle: subtitle,
            loading: loading, canShowLog: failureLog != nil, showsTVHelp: showsTVHelp,
            // From the oldest segment still on disk, as seeking measures it.
            convertedFrom: stream.map { $0.session.offset + (segments.first?.start ?? 0) })
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
        guard stream != nil, let track = audioTracks.first(where: { $0.ref.id == id }), track.ref != audio else { return }
        audio = track.ref
        let name = audioChoices.first { $0.id == id }?.name ?? track.displayName // as the menus name it
        restart(at: nil, loading: "Switching to \(name)…")
    }

    /// Shows the subtitles with `SubtitleOption.id` `id`, or none. Text subtitles the session
    /// already offers switch on the spot; anything burned in, or not yet converted when the
    /// session started, takes a new session at the current time.
    public func selectSubtitle(_ id: String?) {
        guard let stream, id != subtitle else { return }
        let option = id.flatMap(subtitleOption)
        guard id == nil || option != nil else { return }
        subtitle = option?.id
        // Burned-in subtitles, and text the session doesn't offer yet, need a new session.
        let needsSession = option.map { burnsIn($0) || stream.subtitleNames[$0.id] == nil } ?? false
        if needsSession || stream.plan.burnIn != nil {
            restart(at: nil, loading: option == nil ? "Turning subtitles off…" : "Adding subtitles…")
        } else {
            applySubtitleSelection()
        }
    }

    func subtitleOption(_ id: String) -> SubtitleOption? {
        subtitleOptions.first { $0.id == id }
    }

    /// Pictures are always drawn into the video; text is with "Always draw subtitles into the picture".
    func burnsIn(_ option: SubtitleOption) -> Bool {
        !option.isText || environment.settings().alwaysBurnInSubtitles
    }

    /// What a session should show: the chosen audio, and the chosen subtitles, waiting for them
    /// to be converted if need be. It starts at `start`, or, for a track change, wherever
    /// playback has got to by then. Text subtitles that couldn't be converted are turned off,
    /// with a notice, rather than stopping the video. Throws if the playback or session it was
    /// for has been replaced meanwhile.
    func request(at start: Double?) async throws -> StreamRequest {
        var option = subtitle.flatMap(subtitleOption)
        if option?.isText == true, subtitleFiles == nil, let extracting {
            let files = await extracting.value
            try Task.checkCancellation()
            subtitleFiles = files
        }
        if let chosen = option, chosen.isText, subtitleFiles?.files[chosen.id] == nil {
            subtitle = nil
            option = nil
            show(notice: "Paper Plane couldn't read the subtitles “\(chosen.displayName)”.")
        }
        return StreamRequest(start: start ?? movieTime, audio: audio, burnIn: option.flatMap { burnsIn($0) ? $0 : nil },
                             subtitles: subtitleFiles)
    }

    /// Selects the chosen subtitles among the current item's options, matched by their name in
    /// the master playlist (AVFoundation names options by language, so the NAME is the title).
    /// The choice is read once the options have loaded, so quick changes end on the last one.
    func applySubtitleSelection() {
        guard let item = player.currentItem else { return }
        Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            var titled: [(title: String, option: AVMediaSelectionOption)] = []
            for option in group.options {
                let titles = AVMetadataItem.metadataItems(from: option.commonMetadata,
                                                          filteredByIdentifier: .commonIdentifierTitle)
                if let title = try? await titles.first?.load(.stringValue) {
                    titled.append((title, option))
                }
            }
            guard let self, self.player.currentItem === item, let stream = self.stream else { return }
            let name = stream.plan.burnIn == nil ? self.subtitle.flatMap { stream.subtitleNames[$0] } : nil
            item.select(titled.first { $0.title == name }?.option, in: group) // nil turns subtitles off
        }
    }

    // MARK: - New sessions

    /// Starts a new session with the current choices, replacing the playing one when it's ready:
    /// at movie time `time` for a seek, or for a track change (nil) wherever playback has got to
    /// by then. A newer seek or track change replaces this one.
    func restart(at time: Double?, loading text: String) {
        guard let media else { return }
        if let earlier = restarting {
            earlier.cancel()
            afterwards { await earlier.value }
        }
        loading = text
        seekTarget = time
        if let time {
            movieTime = time
        }
        restarting = Task {
            do {
                let pipeline = try self.pipeline()
                let request = try await self.request(at: time)
                let stream = try await environment.startStream(pipeline, media, request)
                guard !Task.isCancelled else {
                    await stream.stop()
                    return
                }
                let old = self.stream
                adopt(stream)
                afterwards { await old?.stop() }
                loading = nil
                seekTarget = nil
                restarting = nil
                if phase == .onTV {
                    if !userPaused {
                        player.play()
                    }
                    // In case the TV starts the new, still-growing playlist at its live edge. Don't
                    // wait: over AirPlay the completion reports false even when the TV seeks.
                    player.seek(to: .zero) { _ in }
                }
                // The address may have changed while this session started on the old one.
                networkChanged()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                log.error("Couldn't start a new session: \(String(describing: error), privacy: .private)")
                fail(PlaybackError.message(for: error), error: error)
            }
        }
    }

    /// The Mac's network changed. If its address moved, the TV can no longer reach the stream,
    /// so serve it again from the new address at the current time (spec §6). While a new
    /// session is starting this waits: that session checks again once it's ready.
    public func networkChanged() {
        guard let stream, loading == nil, let host = environment.host(),
              host != stream.server.baseURL.host()
        else { return }
        restart(at: nil, loading: "Reconnecting…")
    }

    // MARK: - The converted-video window

    /// Keeps converting ahead of the player, rests ffmpeg when it's far enough ahead, and deletes
    /// what the player has left behind (spec §4.2). With little disk space, keeps less ahead and
    /// says so once.
    func manageWindow() {
        // During a seek the old session still plays on the TV: its segments aren't behind.
        guard let stream, seekTarget == nil else { return }
        let free = freeSpace()
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
        if window != SegmentWindow(), !warnedAboutSpace { // keeping less ahead than usual
            warnedAboutSpace = true
            show(notice: "Your Mac is low on disk space, so Paper Plane converts only a few minutes ahead.")
        }
    }

    /// Free space, asked for at most every 10 seconds: the query takes milliseconds of the main
    /// thread, and the window is checked on every tick and segment.
    private func freeSpace() -> Int64 {
        let now = ContinuousClock.now
        if let checked = freeSpaceChecked, now - checked.at < .seconds(10) {
            return checked.bytes
        }
        let bytes = environment.freeSpace() ?? .max
        freeSpaceChecked = (now, bytes)
        return bytes
    }
}
