import Foundation
import os

public enum TranscodeEvent: Equatable, Sendable {
    /// Segment `index` (counting from 0) is complete. The stream now runs to `end` seconds.
    case segment(index: Int, end: Double)
    /// ffmpeg converted everything and exited.
    case finished
    /// ffmpeg failed part-way through. The message is redacted.
    case failed(String)
}

public enum TranscodeError: Error, Equatable {
    /// ffmpeg stopped before the stream was ready. `message` is its redacted stderr.
    case ffmpegFailed(status: Int32, message: String)
    /// The master playlist couldn't be written into the session folder.
    case cannotWriteMasterPlaylist
}

/// Runs ffmpeg for a conversion plan (spec §3.1).
public struct Transcoder: Sendable {
    public var tools: ToolPaths
    /// How many segments must exist before a session counts as started (spec §4: the first 2).
    public var segmentsBeforeReady: Int

    public init(tools: ToolPaths, segmentsBeforeReady: Int = 2) {
        self.tools = tools
        self.segmentsBeforeReady = segmentsBeforeReady
    }

    /// Starts converting `input` from `start` seconds into `folder` (an empty folder from
    /// `SessionFolders`), and returns once the first segments and `master.m3u8` are ready.
    ///
    /// Cancelling the calling task stops ffmpeg and throws `CancellationError`. If ffmpeg fails
    /// first, this throws `TranscodeError.ffmpegFailed`. Either way the folder is deleted.
    public func start(_ plan: ConversionPlan, input: ResolvedInput, from start: Double = 0,
                      in folder: URL) async throws -> TranscodeSession {
        let session: TranscodeSession
        do {
            let offset = try await sessionOffset(plan, input: input, start: start)
            let process = try BackgroundProcess(
                tools.ffmpeg, arguments: plan.ffmpegArguments(input: input, start: start, output: folder))
            session = TranscodeSession(
                folder: folder, requestedStart: start, offset: offset, process: process,
                segmentsBeforeReady: segmentsBeforeReady, frameRate: plan.frameRate, videoRange: plan.videoRange)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        do {
            try await withTaskCancellationHandler {
                try await session.waitUntilReady()
            } onCancel: {
                session.cancelStart()
            }
            return session
        } catch {
            await session.stop()
            throw error
        }
    }

    /// The movie time at which the session's stream begins. Copying video can only start on a
    /// keyframe, so ffmpeg goes back to the keyframe before `start`; a one-packet run with the
    /// same seek reports where that is. Re-encoded video starts exactly at `start`.
    func sessionOffset(_ plan: ConversionPlan, input: ResolvedInput, start: Double) async throws -> Double {
        guard start > 0, case .copy = plan.videoAction, input.inputs.indices.contains(plan.video.input) else {
            return start
        }
        let video = input.inputs[plan.video.input]
        let arguments = ["-hide_banner", "-nostdin", "-loglevel", "error"] + video.ffmpegOptions + [
            "-ss", String(format: "%.3f", start), "-i", video.ffmpegLocation,
            "-map", "0:\(plan.video.index)", "-c", "copy", "-frames:v", "1", "-f", "framecrc", "-",
        ]
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: arguments)
        guard result.status == 0,
              let firstPacket = Self.firstPacketTime(framecrc: String(decoding: result.stdout, as: UTF8.self))
        else { return start }
        return max(0, start + firstPacket)
    }

    /// The first packet's presentation time, in seconds relative to the seek point, from
    /// ffmpeg's framecrc output (`#tb 0: 1/1000`, then `0, dts, pts, duration, size, crc`).
    static func firstPacketTime(framecrc: String) -> Double? {
        var timeBase: Double?
        for line in framecrc.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#tb 0:") {
                let parts = line.dropFirst("#tb 0:".count).split(separator: "/")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]),
                   denominator != 0 {
                    timeBase = numerator / denominator
                }
            } else if !line.hasPrefix("#") {
                let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let timeBase, fields.count >= 3, let pts = Double(fields[2]) else { return nil }
                return pts * timeBase
            }
        }
        return nil
    }
}

/// One ffmpeg run writing HLS into a session folder (a "session", spec §4.2).
public final class TranscodeSession: Sendable {
    public let folder: URL
    /// Where the user asked to start, in seconds of movie time.
    public let requestedStart: Double
    /// The movie time at the start of this session's stream: movie time = offset + player time.
    /// Earlier than `requestedStart` when copied video had to start at a keyframe.
    public let offset: Double
    /// Segment progress, then `.finished` or `.failed`. One consumer at a time.
    public let events: AsyncStream<TranscodeEvent>

    private struct State {
        var isReady = false
        var startFailure: (any Error)?
        var readyWaiter: CheckedContinuation<Void, any Error>?
        var isStopping = false
    }

    private let process: BackgroundProcess
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let monitor: Task<Void, Never>

    init(folder: URL, requestedStart: Double, offset: Double, process: BackgroundProcess,
         segmentsBeforeReady: Int, frameRate: Double?, videoRange: VideoRange) {
        self.folder = folder
        self.requestedStart = requestedStart
        self.offset = offset
        self.process = process
        let (events, continuation) = AsyncStream.makeStream(of: TranscodeEvent.self)
        self.events = events
        let state = state
        monitor = Task.detached {
            await Self.watch(folder: folder, process: process, state: state, continuation: continuation,
                             segmentsBeforeReady: segmentsBeforeReady, frameRate: frameRate, videoRange: videoRange)
        }
    }

    /// Pauses ffmpeg (SIGSTOP), for when it is far enough ahead of the player (spec §4.2).
    public func pause() {
        process.send(SIGSTOP)
    }

    /// Resumes a paused ffmpeg (SIGCONT).
    public func resume() {
        process.send(SIGCONT)
    }

    /// Stops ffmpeg, waits for it to exit and deletes the session folder. Safe to call twice.
    public func stop() async {
        let alreadyStopping = state.withLock { state in
            defer { state.isStopping = true }
            return state.isStopping
        }
        if !alreadyStopping {
            process.send(SIGTERM)
            process.send(SIGCONT) // a paused ffmpeg only acts on SIGTERM once it runs again
        }
        let process = process
        let escalation = Task {
            try await Task.sleep(for: .seconds(5))
            process.send(SIGKILL)
        }
        _ = await process.waitForExit()
        escalation.cancel()
        await monitor.value
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Start

    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let result: Result<Void, any Error>? = state.withLock { state in
                if state.isReady { return .success(()) }
                if let failure = state.startFailure { return .failure(failure) }
                state.readyWaiter = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    /// Called when the task starting this session is cancelled. `Transcoder.start` then stops
    /// the session, which ends ffmpeg.
    func cancelStart() {
        Self.finishStart(state, with: .failure(CancellationError()))
    }

    private static func finishStart(_ state: OSAllocatedUnfairLock<State>, with result: Result<Void, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard !state.isReady, state.startFailure == nil else { return nil }
            switch result {
            case .success: state.isReady = true
            case .failure(let error): state.startFailure = error
            }
            defer { state.readyWaiter = nil }
            return state.readyWaiter
        }
        waiter?.resume(with: result)
    }

    // MARK: - Watching ffmpeg

    /// Polls ffmpeg's playlist until ffmpeg exits, reporting each new segment, and writes the
    /// master playlist once enough segments exist.
    private static func watch(folder: URL, process: BackgroundProcess, state: OSAllocatedUnfairLock<State>,
                              continuation: AsyncStream<TranscodeEvent>.Continuation,
                              segmentsBeforeReady: Int, frameRate: Double?, videoRange: VideoRange) async {
        let playlistURL = folder.appendingPathComponent(MasterPlaylist.mediaPlaylistName)
        var reported = 0
        var end = 0.0
        var sizes: [(bytes: Int, duration: Double)] = []
        var isReady = false
        while true {
            // Read the exit status before the playlist, so the last segments are never missed.
            let exitStatus = process.exitStatus
            let playlist = MediaPlaylist(parsing: (try? String(contentsOf: playlistURL, encoding: .utf8)) ?? "")
            for segment in playlist.segments.dropFirst(reported) {
                end += segment.duration
                sizes.append((fileSize(folder.appendingPathComponent(segment.uri)), segment.duration))
                continuation.yield(.segment(index: reported, end: end))
                reported += 1
            }

            if !isReady, reported >= segmentsBeforeReady || (exitStatus == 0 && reported > 0) {
                isReady = true
                let master = MasterPlaylist.text(
                    bandwidth: MasterPlaylist.bandwidth(segmentSizes: sizes),
                    initSegment: InitSegment((try? Data(contentsOf: folder.appendingPathComponent("init.mp4"))) ?? Data()),
                    frameRate: frameRate,
                    videoRange: videoRange)
                do {
                    try master.write(to: folder.appendingPathComponent(MasterPlaylist.fileName),
                                     atomically: true, encoding: .utf8)
                    finishStart(state, with: .success(()))
                } catch {
                    finishStart(state, with: .failure(TranscodeError.cannotWriteMasterPlaylist))
                }
            }

            if let exitStatus {
                let stopping = state.withLock { $0.isStopping }
                if exitStatus == 0 && reported > 0 {
                    continuation.yield(.finished)
                } else if !stopping {
                    let message = Redaction.summary(of: process.stderr)
                    if isReady {
                        continuation.yield(.failed(message))
                    } else {
                        finishStart(state, with: .failure(TranscodeError.ffmpegFailed(status: exitStatus, message: message)))
                    }
                }
                finishStart(state, with: .failure(CancellationError())) // no-op unless stopped before ready
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        continuation.finish()
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }
}
