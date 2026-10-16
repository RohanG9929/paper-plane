import Foundation
import Testing
@testable import PaperPlaneCore

struct WebVTTTests {
    static let movie = """
        WEBVTT

        STYLE
        ::cue { color: yellow }

        00:01.000 --> 00:04.000
        One

        intro
        00:00:08.500 --> 00:00:12.000 align:start position:10%
        Two
        spans the start

        01:00:00.000 --> 01:00:02.250
        Three

        """

    @Test func movesCuesToASessionsTimeline() {
        #expect(WebVTT.shifted(Self.movie, by: 10) == """
            WEBVTT

            STYLE
            ::cue { color: yellow }

            intro
            00:00:00.000 --> 00:00:02.000 align:start position:10%
            Two
            spans the start

            00:59:50.000 --> 00:59:52.250
            Three

            """)
    }

    @Test func noOffsetOnlyNormalisesTimestamps() {
        let shifted = WebVTT.shifted(Self.movie, by: 0)
        #expect(shifted.contains("00:00:01.000 --> 00:00:04.000\nOne"))
        #expect(shifted.contains("01:00:00.000 --> 01:00:02.250\nThree"))
    }

    @Test func windowsLineEndingsAndJunk() {
        let text = "WEBVTT\r\n\r\n00:01.000 --> 00:02.000\r\nHi\r\n\r\nnot a cue --> at all\r\nx\r\n\r\n\r\n"
        #expect(WebVTT.shifted(text, by: 0) == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n")
    }

    @Test func aCueEndingExactlyAtTheStartIsDropped() {
        #expect(WebVTT.shifted("WEBVTT\n\n00:01.000 --> 00:05.000\nGone\n", by: 5) == "WEBVTT\n")
    }

    @Test func timestamps() {
        #expect(WebVTT.seconds("01:02:03.456") == 3723.456)
        #expect(WebVTT.seconds("02:03.5") == 123.5)
        #expect(WebVTT.seconds("3.5") == nil)
        #expect(WebVTT.seconds("aa:03.5") == nil)
        #expect(WebVTT.timestamp(3723.456) == "01:02:03.456")
        #expect(WebVTT.timestamp(-1) == "00:00:00.000")
    }
}
