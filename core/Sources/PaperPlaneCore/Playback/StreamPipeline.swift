import Foundation

/// Probe → plan → transcode → serve: turns a video into a URL the TV can play (spec §4, steps
/// 2, 4 and 5). A playback probes once, converts its text subtitles once, and starts a new
/// session for each seek outside what's converted and each track change (spec §4.2).
public struct StreamPipeline: Sendable {
    public var tools: ToolPaths
    public var folders: SessionFolders
    public var profile: OutputProfile
    /// The IPv4 address the stream server listens on: `LANAddress.current()` in the app,
    /// `127.0.0.1` in tests.
    public var host: String

    public init(tools: ToolPaths, folders: SessionFolders = .standard, profile: OutputProfile = .default,
                host: String) {
        self.tools = tools
        self.folders = folders
        self.profile = profile
        self.host = host
    }

    /// What the video contains, and the subtitles beside it (looked for while ffprobe runs).
    public func probe(_ input: ResolvedInput) async throws -> PlaybackMedia {
        async let sidecars = Self.sidecars(beside: input)
        let info = try await MediaProbe(tools: tools).probe(input)
        return PlaybackMedia(input: input, info: info, subtitles: SubtitleOption.all(in: info, sidecars: await sidecars))
    }

    /// Only a local file has a folder to look in.
    private static func sidecars(beside input: ResolvedInput) async -> [SidecarSubtitles.File] {
        guard input.inputs.count == 1, input.inputs[0].url.isFileURL else { return [] }
        return await SidecarSubtitles.find(for: input.inputs[0].url)
    }

    /// Converts the text subtitles to WebVTT, in a folder of their own.
    public func extractSubtitles(_ media: PlaybackMedia) async throws -> SubtitleFiles {
        let folder = try folders.create()
        let files = await SubtitleExtractor(tools: tools).extract(media.subtitles, from: media.input, into: folder)
        return SubtitleFiles(folder: folder, files: files)
    }

    /// Starts a session `start` seconds into the movie with the chosen tracks, and returns once
    /// its first segments are ready and served. It offers every text subtitle in `subtitles`
    /// and burns in `burnIn` (a picture track, or a text one in `subtitles`). Cancelling the
    /// calling task stops everything and deletes the session folder.
    public func start(_ media: PlaybackMedia, at start: Double = 0, audio: TrackRef? = nil,
                      burnIn: SubtitleOption? = nil, subtitles: SubtitleFiles? = nil) async throws -> ServedStream {
        let choice = TrackChoice(audio: audio, burnIn: try burnIn.map { try Self.burnIn($0, subtitles: subtitles) })
        let plan = try ConversionPlanner.plan(media.info, choice: choice, profile: profile)
        let names = media.subtitleNames
        let sessionSubtitles = SessionSubtitles(
            tracks: media.subtitles.compactMap { option in
                guard let file = subtitles?.files[option.id], let name = names[option.id] else { return nil }
                return SessionSubtitles.Track(name: name, language: option.language, isForced: option.isForced,
                                              file: file)
            },
            burnIn: choice.burnIn == .text ? burnIn.flatMap { subtitles?.files[$0.id] } : nil,
            duration: media.info.duration)
        let session = try await Transcoder(tools: tools).start(plan, input: media.input, from: start,
                                                               in: try folders.create(), subtitles: sessionSubtitles)
        do {
            try Task.checkCancellation()
            let server = try await StreamServer.start(serving: session.folder, on: host)
            let offeredNames = names.filter { session.subtitleNames.contains($0.value) }
            return ServedStream(title: media.title, media: media.info, plan: plan, session: session, server: server,
                                subtitleNames: offeredNames)
        } catch {
            await session.stop()
            throw error
        }
    }

    /// Probes `input` and starts it from the beginning with its default tracks.
    public func start(_ input: ResolvedInput) async throws -> ServedStream {
        try await start(try await probe(input))
    }

    private static func burnIn(_ option: SubtitleOption, subtitles: SubtitleFiles?) throws -> BurnIn {
        switch option.source {
        case .embedded(let ref) where !option.isText:
            return .picture(ref)
        default:
            guard subtitles?.files[option.id] != nil else { throw SubtitleError.notConverted }
            return .text
        }
    }
}

public enum SubtitleError: Error, Equatable {
    /// The text subtitles to burn in couldn't be converted.
    case notConverted
}

/// A video to play: what it contains and the subtitles it offers.
public struct PlaybackMedia: Sendable {
    public var input: ResolvedInput
    public var info: MediaInfo
    /// The file's subtitle tracks, then sidecar `.srt` files.
    public var subtitles: [SubtitleOption]

    public init(input: ResolvedInput, info: MediaInfo, subtitles: [SubtitleOption]) {
        self.input = input
        self.info = info
        self.subtitles = subtitles
    }

    public var title: String { input.title }

    /// Each subtitle option's name in the master playlist, by option id: its display name,
    /// numbered where two would be the same.
    public var subtitleNames: [String: String] {
        Dictionary(uniqueKeysWithValues: zip(subtitles.map(\.id), TrackNames.unique(subtitles.map(\.displayName))))
    }
}

/// Text subtitles converted to WebVTT for one playback, by `SubtitleOption.id`.
public struct SubtitleFiles: Sendable {
    public var folder: URL
    public var files: [String: URL]

    public init(folder: URL, files: [String: URL]) {
        self.folder = folder
        self.files = files
    }

    /// Deletes the files, when the playback ends.
    public func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A video being converted and served. Call `stop()` when playback ends.
public final class ServedStream: Sendable {
    public let title: String
    public let media: MediaInfo
    public let plan: ConversionPlan
    public let session: TranscodeSession
    public let server: StreamServer
    /// The subtitle tracks this stream offers: their names in the master playlist, which the
    /// player's options show, by `SubtitleOption.id`.
    public let subtitleNames: [String: String]

    init(title: String, media: MediaInfo, plan: ConversionPlan, session: TranscodeSession, server: StreamServer,
         subtitleNames: [String: String] = [:]) {
        self.title = title
        self.media = media
        self.plan = plan
        self.session = session
        self.server = server
        self.subtitleNames = subtitleNames
    }

    /// What the player opens: the master playlist.
    public var url: URL {
        server.url(for: MasterPlaylist.fileName)
    }

    /// Stops serving and converting, and deletes the session folder.
    public func stop() async {
        server.stop()
        await session.stop()
    }
}
