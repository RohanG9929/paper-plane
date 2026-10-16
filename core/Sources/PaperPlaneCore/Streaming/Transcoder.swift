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
    /// `SessionFolders`), and returns once the first segments and `master.m3u8` are ready. The
    /// session offers `subtitles`' tracks and burns in its `burnIn`, moved to the session's start.
    ///
    /// Cancelling the calling task stops ffmpeg and throws `CancellationError`. If ffmpeg fails
    /// first, this throws `TranscodeError.ffmpegFailed`. Either way the folder is deleted.
    public func start(_ plan: ConversionPlan, input: ResolvedInput, from start: Double = 0,
                      in folder: URL, subtitles: SessionSubtitles = SessionSubtitles()) async throws -> TranscodeSession {
        let session: TranscodeSession
        do {
            let begin = try await sessionStart(plan, input: input, start: start)
            let renditions = subtitles.write(into: folder, offset: begin.offset)
            // ffmpeg runs in the session folder, so the burn-in subtitles need no escaped path.
            let arguments = plan.ffmpegArguments(input: input, start: begin.seek, output: folder, trim: begin.trim)
            let process = try BackgroundProcess(tools.ffmpeg, arguments: arguments, in: folder)
            session = TranscodeSession(folder: folder, requestedStart: start, offset: begin.offset, process: process,
                                       plan: plan, subtitles: renditions, segmentsBeforeReady: segmentsBeforeReady)
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

    /// How a session starts: where ffmpeg seeks the input (`seek`), where its stream begins
    /// (`offset`, in movie time) and, for copied video whose file hides a lead-in, where ffmpeg
    /// must trim (`trim`).
    struct SessionStart: Equatable {
        var seek: Double
        var offset: Double
        var trim: Double?
    }

    /// The first keyframe a TV can show after a hidden lead-in, and its decode time.
    struct LeadInStart: Equatable {
        var keyframe: Double
        var decodeTime: Double
    }

    /// How far before a keyframe's decode time the trim goes, so rounding never drops it.
    static let trimMargin = 0.0005
    /// How many video packets to read looking for the end of a lead-in (about a long GOP).
    static let leadInPacketLimit = 1000

    /// Re-encoded video starts exactly at `start`. Copied video can only start on a keyframe:
    /// - From a seek, ffmpeg goes back to the keyframe before `start` for both tracks.
    /// - From the start of a losslessly trimmed file, an edit list hides the frames before the
    ///   cut. Copying keeps them and the audio starts seconds later; a TV plays both from their
    ///   first packet, so the sound runs early. Trimming at the first shown keyframe's decode
    ///   time drops the lead-in from both tracks. A start before that keyframe (a seek or a
    ///   track switch in the first seconds) begins there too: seeking would land in the lead-in.
    func sessionStart(_ plan: ConversionPlan, input: ResolvedInput, start: Double) async throws -> SessionStart {
        guard case .copy = plan.videoAction, input.inputs.indices.contains(plan.video.input) else {
            return SessionStart(seek: start, offset: start, trim: nil)
        }
        if let leadIn = try await leadInStart(plan, input: input), start < leadIn.keyframe {
            return SessionStart(seek: 0, offset: leadIn.keyframe, trim: leadIn.decodeTime - Self.trimMargin)
        }
        guard start > 0 else { return SessionStart(seek: 0, offset: 0, trim: nil) }
        return SessionStart(seek: start, offset: try await keyframeBefore(start, plan: plan, input: input), trim: nil)
    }

    /// The lead-in of the video input, if its first packet is hidden. Reading one packet first
    /// keeps the common case (no edit list hiding frames) to a single tiny ffprobe run.
    private func leadInStart(_ plan: ConversionPlan, input: ResolvedInput) async throws -> LeadInStart? {
        let video = input.inputs[plan.video.input]
        func packets(_ count: Int) async throws -> String? {
            let result = try await ProcessRunner.run(tools.ffprobe, arguments: [
                "-v", "error", "-select_streams", String(plan.video.index),
                "-show_entries", "packet=pts_time,dts_time,flags", "-read_intervals", "%+#\(count)", "-of", "csv=p=0",
            ] + video.ffmpegOptions + [video.ffmpegLocation])
            return result.status == 0 ? String(decoding: result.stdout, as: UTF8.self) : nil
        }
        guard let first = try await packets(1),
              first.split(separator: ",", omittingEmptySubsequences: false).dropFirst(2).first?.contains("D") == true,
              let window = try await packets(Self.leadInPacketLimit)
        else { return nil }
        return Self.leadInStart(packets: window)
    }

    /// From ffprobe packet lines (`pts_time,dts_time,flags`) at the start of the video: nil
    /// unless an edit list hides frames (flag D) before the first shown keyframe. That keyframe
    /// must also decode after the trim margin, or trimming at its decode time would drop it.
    static func leadInStart(packets: String) -> LeadInStart? {
        var hidden = false
        for line in packets.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let pts = Double(fields[0]), let dts = Double(fields[1]) else { continue }
            if fields[2].contains("D") {
                hidden = true
            } else if hidden, fields[2].contains("K"), pts >= 0, dts > trimMargin {
                return LeadInStart(keyframe: pts, decodeTime: dts)
            }
        }
        return nil
    }

    /// The keyframe before `start` that copying begins at: a one-packet run with the same seek
    /// reports where that is.
    private func keyframeBefore(_ start: Double, plan: ConversionPlan, input: ResolvedInput) async throws -> Double {
        let video = input.inputs[plan.video.input]
        let arguments = ffmpegQuietArguments + video.ffmpegInputArguments(seek: start) + [
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
                timeBase = Fraction.value(line.dropFirst("#tb 0:".count)) ?? timeBase
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
    /// Earlier than `requestedStart` when copied video had to start at a keyframe; later when
    /// the file hides a lead-in and the first keyframe a TV can show comes after it.
    public let offset: Double
    /// Segment progress, then `.finished` or `.failed`. One consumer at a time.
    public let events: AsyncStream<TranscodeEvent>
    /// The names of the subtitle tracks the master playlist offers.
    public let subtitleNames: [String]

    private struct State {
        /// nil until the session is ready or has failed to start.
        var startResult: Result<Void, any Error>?
        var readyWaiter: CheckedContinuation<Void, any Error>?
        var isStopping = false
    }

    private let process: BackgroundProcess
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let monitor: Task<Void, Never>

    init(folder: URL, requestedStart: Double, offset: Double, process: BackgroundProcess, plan: ConversionPlan,
         subtitles: [MasterPlaylist.Subtitle] = [], segmentsBeforeReady: Int) {
        self.folder = folder
        self.requestedStart = requestedStart
        self.offset = offset
        self.process = process
        subtitleNames = subtitles.map(\.name)
        let (events, continuation) = AsyncStream.makeStream(of: TranscodeEvent.self)
        self.events = events
        let state = state
        monitor = Task.detached {
            await Self.watch(folder: folder, process: process, state: state, continuation: continuation, plan: plan,
                             subtitles: subtitles, segmentsBeforeReady: segmentsBeforeReady)
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

    /// Deletes segments the player has left behind (spec §4.2).
    public func delete(_ segments: [SegmentWindow.Segment]) {
        for segment in segments {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(segment.fileName))
        }
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
        let escalation = Task { [process] in
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
            let result = state.withLock { state in
                if state.startResult == nil {
                    state.readyWaiter = continuation
                }
                return state.startResult
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

    /// Settles the start once; later calls do nothing.
    private static func finishStart(_ state: OSAllocatedUnfairLock<State>, with result: Result<Void, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard state.startResult == nil else { return nil }
            state.startResult = result
            defer { state.readyWaiter = nil }
            return state.readyWaiter
        }
        waiter?.resume(with: result)
    }

    // MARK: - Watching ffmpeg

    /// Polls ffmpeg's playlist until ffmpeg exits, reporting each new segment, and writes the
    /// master playlist once enough segments exist. Polls every 200 ms until then, and every
    /// second after: only the remote's "converted so far" depends on it.
    private static func watch(folder: URL, process: BackgroundProcess, state: OSAllocatedUnfairLock<State>,
                              continuation: AsyncStream<TranscodeEvent>.Continuation, plan: ConversionPlan,
                              subtitles: [MasterPlaylist.Subtitle], segmentsBeforeReady: Int) async {
        let playlistURL = folder.appendingPathComponent(HLSFileNames.mediaPlaylist)
        var reported = 0
        var end = 0.0
        var sizes: [(bytes: Int, duration: Double)] = []
        var wroteMaster = false
        while true {
            // Read the exit status before the playlist, so the last segments are never missed.
            let exitStatus = process.exitStatus
            let playlist = MediaPlaylist(parsing: (try? String(contentsOf: playlistURL, encoding: .utf8)) ?? "")
            for segment in playlist.segments.dropFirst(reported) {
                end += segment.duration
                if !wroteMaster {
                    sizes.append((fileSize(folder.appendingPathComponent(segment.uri)), segment.duration))
                }
                continuation.yield(.segment(index: reported, end: end))
                reported += 1
            }

            if !wroteMaster, reported >= segmentsBeforeReady || (exitStatus == 0 && reported > 0) {
                wroteMaster = true
                let initSegment = folder.appendingPathComponent(HLSFileNames.initSegment)
                let master = MasterPlaylist.text(
                    bandwidth: MasterPlaylist.bandwidth(segmentSizes: sizes),
                    initSegment: InitSegment((try? Data(contentsOf: initSegment)) ?? Data()),
                    frameRate: plan.frameRate,
                    videoRange: plan.videoRange,
                    subtitles: subtitles)
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
                    if wroteMaster {
                        continuation.yield(.failed(message))
                    } else {
                        finishStart(state, with: .failure(TranscodeError.ffmpegFailed(status: exitStatus, message: message)))
                    }
                }
                finishStart(state, with: .failure(CancellationError())) // no-op unless stopped before ready
                break
            }
            try? await Task.sleep(for: .milliseconds(wroteMaster ? 1_000 : 200))
        }
        continuation.finish()
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }
}
