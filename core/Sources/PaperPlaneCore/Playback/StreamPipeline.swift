import Foundation

/// Probe → plan → transcode → serve: turns a video into a URL the TV can play
/// (spec §4, steps 2, 4 and 5).
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

    /// Returns once the first segments are ready and served. Cancelling the calling task stops
    /// everything and deletes the session folder.
    public func start(_ input: ResolvedInput) async throws -> ServedStream {
        let media = try await MediaProbe(tools: tools).probe(input)
        let plan = try ConversionPlanner.plan(media, profile: profile)
        let session = try await Transcoder(tools: tools).start(plan, input: input, in: try folders.create())
        do {
            try Task.checkCancellation()
            let server = try await StreamServer.start(serving: session.folder, on: host)
            return ServedStream(title: input.title, media: media, plan: plan, session: session, server: server)
        } catch {
            await session.stop()
            throw error
        }
    }
}

/// A video being converted and served. Call `stop()` when playback ends.
public final class ServedStream: Sendable {
    public let title: String
    public let media: MediaInfo
    public let plan: ConversionPlan
    public let session: TranscodeSession
    public let server: StreamServer

    init(title: String, media: MediaInfo, plan: ConversionPlan, session: TranscodeSession, server: StreamServer) {
        self.title = title
        self.media = media
        self.plan = plan
        self.session = session
        self.server = server
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
