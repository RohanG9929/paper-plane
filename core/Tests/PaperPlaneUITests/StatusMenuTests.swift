import Testing
@testable import PaperPlaneUI

struct StatusMenuTests {
    static let always = ["Open Video…", "Show Paper Plane Window", "-", "Settings…", "-", "Quit Paper Plane"]

    @Test func withNothingPlayingItOffersToOpenSomething() {
        #expect(StatusMenu.items(for: RemoteState()).map(\.title) == Self.always)
        #expect(StatusMenu.items(for: RemoteState()).map(\.key) == ["o", "1", "", ",", "", "q"])
    }

    @Test func whatIsPlayingComesFirstWithItsTracks() {
        let state = RemoteState(
            phase: .playing, title: "Movie",
            audioChoices: [.init(id: "a1", name: "English (5.1)"), .init(id: "a2", name: "French (Stereo)")], audio: "a2",
            subtitleChoices: [.init(id: "s1", name: "English")], subtitle: nil)
        let items = StatusMenu.items(for: state)
        #expect(items.map(\.title) == ["Movie", "Pause", "Stop", "Audio", "Subtitles", "-"] + Self.always)
        #expect(items[0].command == nil && !items[0].isEnabled) // a heading
        #expect(items[3].submenu?.map(\.title) == ["English (5.1)", "French (Stereo)"])
        #expect(items[3].submenu?.map(\.isChecked) == [false, true])
        #expect(items[3].submenu?.first?.command == .selectAudio("a1"))
        #expect(items[4].submenu?.map(\.title) == ["Off", "English"])
        #expect(items[4].submenu?.map(\.isChecked) == [true, false])
        #expect(items[4].submenu?.first?.command == .selectSubtitle(nil))
    }

    @Test func oneAudioTrackNeedsNoMenuAndPreparingCantPlayYet() {
        let state = RemoteState(phase: .preparing, title: "Movie", audioChoices: [.init(id: "a1", name: "English")],
                                subtitleChoices: [.init(id: "s1", name: "English")])
        let items = StatusMenu.items(for: state)
        #expect(items.map(\.title) == ["Movie", "Play", "Stop", "-"] + Self.always)
        #expect(!items[1].isEnabled)

        var playing = state
        playing.phase = .playing
        #expect(StatusMenu.items(for: playing).map(\.title) == ["Movie", "Pause", "Stop", "Subtitles", "-"] + Self.always)
    }

    @Test func aFailureOffersToDismissIt() {
        let items = StatusMenu.items(for: RemoteState(phase: .failed("Broken."), title: "Movie"))
        #expect(items.map(\.title) == ["Movie", "Dismiss", "-"] + Self.always)
        #expect(items[1].command == .stop)
    }
}
