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

    /// Until Milestone 2 restarts the conversion for a seek, the scrubber can't promise to reach
    /// past what has been converted.
    @Test func seekingReachesOnlyWhatIsConverted() {
        #expect(Self.state(.playing).seekableFraction == 0.4)
        var finished = Self.state(.playing)
        finished.converted = 100
        #expect(finished.seekableFraction == 1)
        var unknown = Self.state(.playing)
        unknown.converted = nil
        #expect(unknown.seekableFraction == 0.1) // only up to where it is now
    }

    @Test func explainsHowFarYouCanSeek() {
        #expect(Self.state(.playing).convertedNote == "Ready up to 0:40")
        var finished = Self.state(.playing)
        finished.converted = 100
        #expect(finished.convertedNote == "")
        var unknown = Self.state(.playing)
        unknown.converted = nil
        #expect(unknown.convertedNote == "")
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
