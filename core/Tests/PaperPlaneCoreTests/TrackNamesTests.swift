import Foundation
import Testing
@testable import PaperPlaneCore

struct TrackNamesTests {
    @Test func subtitleNames() {
        func option(_ language: String?, _ title: String? = nil, forced: Bool = false) -> SubtitleOption {
            SubtitleOption(source: .embedded(TrackRef(index: 2)), language: language, title: title, isForced: forced,
                           isText: true)
        }
        #expect(option("eng").displayName == "English")
        #expect(option("en", "SDH").displayName == "English — SDH")
        #expect(option("fre", forced: true).displayName == "French (Forced)")
        #expect(option("pt-BR").displayName == "Portuguese (Brazil)")
        #expect(option(nil, "Signs & Songs").displayName == "Signs & Songs")
        #expect(option(nil).displayName == "Subtitles")
        #expect(option("xyz").displayName == "Subtitles") // a code nobody knows
    }

    @Test func audioNames() {
        func track(_ language: String?, _ channels: Int, _ title: String? = nil) -> AudioTrack {
            AudioTrack(ref: TrackRef(index: 1), codec: .aac, channels: channels, language: language, title: title,
                       isDefault: false)
        }
        #expect(track("eng", 6).displayName == "English (5.1)")
        #expect(track("jpn", 2, "Commentary").displayName == "Japanese — Commentary (Stereo)")
        #expect(track(nil, 1).displayName == "Audio (Mono)")
        #expect(track(nil, 8).displayName == "Audio (7.1)")
        #expect(track(nil, 4).displayName == "Audio (4 channels)")
    }

    @Test func languageTagsForHLS() {
        #expect(TrackNames.languageTag("eng") == "en")
        #expect(TrackNames.languageTag("fre") == "fr")
        #expect(TrackNames.languageTag("ger") == "de")
        #expect(TrackNames.languageTag("jpn") == "ja")
        #expect(TrackNames.languageTag("xyz") == "xyz")
        #expect(TrackNames.languageTag("pt-BR") == "pt-BR")
        #expect(TrackNames.languageTag("EN") == "en")
        #expect(TrackNames.languageTag(nil) == nil)
        #expect(TrackNames.languageTag("") == nil)
    }

    @Test func repeatedNamesGetNumbers() {
        #expect(TrackNames.unique(["English", "French", "English", "English"])
                == ["English", "French", "English 2", "English 3"])
        // A number never lands on a name another track already has.
        #expect(TrackNames.unique(["English", "English", "English 2"]) == ["English", "English 3", "English 2"])
    }

    /// Names go into the playlist's quoted NAME, which can't hold a double quote or a line break;
    /// they're matched back by that NAME, so they must already be what the playlist says.
    @Test func namesHaveNoQuotesOrLineBreaks() {
        let option = SubtitleOption(source: .embedded(TrackRef(index: 2)), language: "en",
                                    title: "Commentary \"Director\"\nPart 2", isForced: false, isText: true)
        #expect(option.displayName == "English — Commentary 'Director' Part 2")
    }

    @Test func optionsListEmbeddedTracksThenSidecars() {
        let media = MediaInfo(duration: 10, video: [], audio: [], subtitles: [
            SubtitleTrack(ref: TrackRef(index: 2), codecName: "subrip", kind: .text, language: "eng", title: nil,
                          isDefault: false, isForced: false),
            SubtitleTrack(ref: TrackRef(index: 3), codecName: "hdmv_pgs_subtitle", kind: .picture, language: "fre",
                          title: nil, isDefault: false, isForced: true),
            SubtitleTrack(ref: TrackRef(index: 4), codecName: "eia_608", kind: .unsupported, language: nil,
                          title: nil, isDefault: false, isForced: false),
        ])
        let sidecar = SidecarSubtitles.File(url: URL(fileURLWithPath: "/m/Movie.de.srt"), language: "de",
                                            isForced: false)
        let options = SubtitleOption.all(in: media, sidecars: [sidecar])
        #expect(options.map(\.id) == ["track-0-2", "track-0-3", "file-Movie.de.srt"])
        #expect(options.map(\.isText) == [true, false, true])
        #expect(options.map(\.displayName) == ["English", "French (Forced)", "German — Movie.de.srt"])
    }
}
