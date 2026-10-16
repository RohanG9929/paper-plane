import Foundation
import Testing
@testable import PaperPlaneUI

struct TimeTextTests {
    @Test(arguments: [
        (0.0, "0:00"), (7.9, "0:07"), (754, "12:34"), (3_600, "1:00:00"), (3_723.4, "1:02:03"), (-5, "0:00"),
        (.nan, "0:00"), (.infinity, "0:00"),
    ])
    func clock(seconds: Double, text: String) {
        #expect(TimeText.clock(seconds) == text)
    }

    @Test func remainingCountsDownAndNeverGoesNegative() {
        #expect(TimeText.remaining(elapsed: 754, duration: 3_600) == "−47:26")
        #expect(TimeText.remaining(elapsed: 4_000, duration: 3_600) == "−0:00")
    }

    @Test(arguments: [
        (0.0, "0 seconds"), (1, "1 second"), (61, "1 minute 1 second"), (3_723, "1 hour 2 minutes 3 seconds"),
        (7_200, "2 hours"),
    ])
    func spokenTimeIsReadableAloud(seconds: Double, text: String) {
        #expect(TimeText.spoken(seconds) == text)
    }
}

struct MediaSummaryTests {
    @Test func describesSizeRangeAndLength() {
        #expect(MediaSummary.text(height: 2160, hdr: "HDR10", duration: 6_720) == "4K · HDR10 · 1 h 52 min")
        #expect(MediaSummary.text(height: 1080, hdr: nil, duration: 1_290) == "1080p · 21 min")
        #expect(MediaSummary.text(height: 720, hdr: nil, duration: 10) == "720p · 10 s")
        #expect(MediaSummary.text(height: 480, hdr: nil, duration: nil) == "480p")
        #expect(MediaSummary.text(height: nil, hdr: nil, duration: nil) == "")
    }
}

struct RemoteStateTests {
    static func state(_ phase: RemoteState.Phase) -> RemoteState {
        RemoteState(phase: phase, title: "Movie", detail: "1080p", elapsed: 10, duration: 100, converted: 40)
    }

    @Test func onlyAPlayingOrPausedVideoTakesTransportCommands() {
        #expect(Self.state(.playing).canControlPlayback)
        #expect(Self.state(.paused).canControlPlayback)
        for phase in [RemoteState.Phase.idle, .preparing, .choosingTV(tvWentAway: false), .failed("x")] {
            #expect(!Self.state(phase).canControlPlayback, "\(phase)")
        }
    }

    @Test func statusSaysWhatIsHappening() {
        #expect(Self.state(.preparing).status == "Getting your video ready…")
        #expect(Self.state(.choosingTV(tvWentAway: false)).status == "Choose your TV to start")
        #expect(Self.state(.choosingTV(tvWentAway: true)).status == "TV disconnected — choose it again to continue")
        #expect(Self.state(.playing).status == "Playing on your TV")
        #expect(Self.state(.paused).status == "Paused")
        #expect(Self.state(.failed("This file has no video.")).status == "This file has no video.")
    }

    @Test func playButtonNamesTheActionItWillTake() {
        #expect(Self.state(.playing).playButtonLabel == "Pause")
        #expect(Self.state(.paused).playButtonLabel == "Play")
    }

    /// Past what's converted, a seek starts a new session there (spec §4.2), so the whole film
    /// is reachable; a film of unknown length can't be scrubbed.
    @Test func seekingReachesTheWholeFilm() {
        #expect(Self.state(.playing).seekableFraction == 1)
        var unknown = Self.state(.playing)
        unknown.duration = nil
        #expect(unknown.seekableFraction == 0)
    }

    @Test func explainsHowFarYouCanSeek() {
        #expect(Self.state(.playing).convertedNote == "Converted up to 0:40; a jump further on takes a moment")
        var finished = Self.state(.playing)
        finished.converted = 100
        #expect(finished.convertedNote == "")
        var unknown = Self.state(.playing)
        unknown.converted = nil
        #expect(unknown.convertedNote == "")
    }

    @Test func aNewSessionSaysWhatItIsDoing() {
        var moving = Self.state(.playing)
        moving.loading = "Moving to 1:02:03…"
        #expect(moving.status == "Moving to 1:02:03…")
        var failed = Self.state(.failed("Broken."))
        failed.loading = "Moving to 1:02:03…"
        #expect(failed.status == "Broken.")
    }

    /// The remote's menu and the menu bar's show the same choices: audio when there's more than
    /// one track, subtitles when there are any.
    @Test func trackChoicesShowWhenThereIsAChoice() {
        var state = Self.state(.playing)
        state.audioChoices = [.init(id: "a", name: "English")]
        #expect(!state.showsAudioChoices)
        #expect(!state.showsSubtitleChoices)
        state.audioChoices.append(.init(id: "b", name: "French"))
        state.subtitleChoices = [.init(id: "s", name: "English")]
        #expect(state.showsAudioChoices)
        #expect(state.showsSubtitleChoices)
        state.phase = .preparing
        #expect(!state.showsAudioChoices)
        #expect(!state.showsSubtitleChoices)
    }

    @Test func isLoadingOnlyWhileTheVideoIsLoaded() {
        var state = Self.state(.playing)
        #expect(!state.isLoading)
        state.loading = "Moving to 1:00…"
        #expect(state.isLoading)
        state.phase = .failed("x")
        #expect(!state.isLoading)
    }

    /// After a far seek the converted part starts where the new session does, not at 0:00.
    @Test func theConvertedPartStartsWhereTheSessionDoes() {
        var state = Self.state(.playing)
        state.convertedFrom = 30
        #expect(state.convertedNote == "Converted from 0:30 up to 0:40; a jump elsewhere takes a moment")
        state.convertedFrom = 0
        #expect(state.convertedNote == "Converted up to 0:40; a jump further on takes a moment")
    }

    @Test func tracksCanBeChosenOnceTheVideoIsLoaded() {
        for phase in [RemoteState.Phase.choosingTV(tvWentAway: false), .playing, .paused] {
            #expect(Self.state(phase).canChooseTracks, "\(phase)")
        }
        for phase in [RemoteState.Phase.idle, .preparing, .failed("x")] {
            #expect(!Self.state(phase).canChooseTracks, "\(phase)")
        }
    }

    @Test func volumeIsInertUntilTheTVPlays() {
        #expect(Self.state(.playing).canAdjustVolume)
        #expect(Self.state(.paused).canAdjustVolume)
        #expect(!Self.state(.preparing).canAdjustVolume)
        #expect(!Self.state(.choosingTV(tvWentAway: false)).canAdjustVolume)
    }

    @Test func scrubberFractionsAreClamped() {
        #expect(RemoteState.fraction(of: 25, in: 100) == 0.25)
        #expect(RemoteState.fraction(of: 150, in: 100) == 1)
        #expect(RemoteState.fraction(of: -3, in: 100) == 0)
        #expect(RemoteState.fraction(of: 5, in: nil) == 0)
        #expect(RemoteState.fraction(of: 5, in: 0) == 0)
    }
}
