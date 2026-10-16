import AppKit
import Foundation
import MediaPlayer
import PaperPlaneCore
import Testing
@testable import PaperPlaneUI

@MainActor
struct NowPlayingTests {
    static func state(elapsed: Double = 10, playing: Bool = true, at seconds: Double = 0) -> NowPlaying.Published {
        NowPlaying.Published(title: "Movie", duration: 100, elapsed: elapsed, isPlaying: playing, hasArtwork: false,
                             at: Date(timeIntervalSince1970: seconds))
    }

    @Test func aLiveStreamIsLiveInControlCenter() {
        var live = Self.state()
        live.duration = nil
        live.isLive = true
        #expect(NowPlaying.info(live, artwork: nil)[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
        #expect(NowPlaying.info(Self.state(), artwork: nil)[MPNowPlayingInfoPropertyIsLiveStream] == nil)
        // Found to be live after it was first published: published again.
        var preparing = Self.state(playing: false)
        preparing.duration = nil
        var found = preparing
        found.isLive = true
        #expect(preparing.differs(from: found))
    }

    @Test func describesTheVideoForControlCenter() {
        let info = NowPlaying.info(Self.state(), artwork: NSImage(size: NSSize(width: 64, height: 36)))
        #expect(info[MPMediaItemPropertyTitle] as? String == "Movie")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 100)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 10)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        let paused = NowPlaying.info(Self.state(playing: false), artwork: nil)
        #expect(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(paused[MPMediaItemPropertyArtwork] == nil)
    }

    /// MediaPlayer asks for the artwork on a queue of its own; the image must come back without
    /// touching the main actor (this crashed the app once a thumbnail was published).
    @Test func artworkCanBeDrawnOffTheMainThread() async throws {
        let info = NowPlaying.info(Self.state(), artwork: NSImage(size: NSSize(width: 64, height: 36)))
        let artwork = try #require(info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        nonisolated(unsafe) let unsafeArtwork = artwork
        let size = await Task.detached { unsafeArtwork.image(at: CGSize(width: 32, height: 18))?.size }.value
        #expect(size != nil)
    }

    /// Control Center runs the clock itself; it only needs telling when playback jumps.
    @Test func onlyAJumpOrAChangeIsPublished() {
        let published = Self.state(elapsed: 10, at: 0)
        #expect(!published.differs(from: Self.state(elapsed: 15, at: 5))) // 5 s later, 5 s further
        #expect(!published.differs(from: Self.state(elapsed: 15.4, at: 5))) // a little drift is no jump
        #expect(published.differs(from: Self.state(elapsed: 60, at: 5))) // a seek
        #expect(published.differs(from: Self.state(elapsed: 15, playing: false, at: 5)))
        let paused = Self.state(elapsed: 10, playing: false, at: 0)
        #expect(!paused.differs(from: Self.state(elapsed: 10, playing: false, at: 30)))
    }

    @Test func mediaKeysOnlyActOnAVideoOnTheTV() {
        let controller = PlaybackController(
            environment: PlaybackControllerTests.environment(probe: PlaybackControllerTests.preparesForever),
            showsWelcome: false, welcomeSeen: {})
        let nowPlaying = NowPlaying(controller: controller)
        #expect(!nowPlaying.handle(.togglePlayPause))
        controller.play([URL(fileURLWithPath: "/Movies/a.mkv")])
        #expect(!nowPlaying.handle(.skip(10))) // still preparing
        controller.stop()
    }
}
