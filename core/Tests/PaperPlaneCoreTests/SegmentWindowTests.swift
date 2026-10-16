import Foundation
import Testing
@testable import PaperPlaneCore

struct SegmentWindowTests {
    /// `count` 6-second segments from session time 0.
    static func segments(_ count: Int, from first: Int = 0) -> [SegmentWindow.Segment] {
        (first..<(first + count)).map { SegmentWindow.Segment(index: $0, start: Double($0) * 6, end: Double($0 + 1) * 6) }
    }

    let window = SegmentWindow()

    /// A web stream's ffmpeg is never paused: the site may drop an idle connection (addendum
    /// M3-16). What's behind is still deleted.
    @Test func aWindowThatDoesntPauseStillDeletesWhatIsBehind() {
        let window = SegmentWindow.forFreeSpace(1_000_000_000)
        #expect(window.actions(playhead: 400, segments: Self.segments(200), conversionPaused: false,
                               conversionFinished: false, restsConversion: false) == [.delete(Self.segments(16))])
    }

    @Test func keepsConvertingWhileLessThanTwentyMinutesAhead() {
        #expect(window.actions(playhead: 0, segments: Self.segments(10), conversionPaused: false,
                               conversionFinished: false) == [])
    }

    @Test func pausesAtTwentyMinutesAhead() {
        // 200 segments = 1,200 s ahead of a playhead at 0.
        #expect(window.actions(playhead: 0, segments: Self.segments(200), conversionPaused: false,
                               conversionFinished: false) == [.pauseConversion])
    }

    @Test func resumesBelowTenMinutesAhead() {
        let segments = Self.segments(200) // converted to 1,200 s
        // 700 s ahead: still paused (old segments are deleted, which is a separate action).
        #expect(!window.actions(playhead: 500, segments: segments, conversionPaused: true,
                                conversionFinished: false).contains(.resumeConversion))
        #expect(window.actions(playhead: 601, segments: segments.filter { $0.end >= 301 }, conversionPaused: true,
                               conversionFinished: false).first == .resumeConversion)
    }

    @Test func deletesWhatIsMoreThanFiveMinutesBehind() {
        let segments = Self.segments(100) // 0–600 s
        let actions = window.actions(playhead: 400, segments: segments, conversionPaused: false, conversionFinished: false)
        // Segments ending before 100 s (400 − 300): indexes 0…15 end at 6…96.
        #expect(actions == [.delete(Array(segments.prefix(16)))])
        #expect(Array(segments.prefix(16)).last?.fileName == "seg_00015.m4s")
    }

    /// "More than 5 minutes behind": a segment ending exactly 300 s back is kept.
    @Test func keepsASegmentEndingExactlyFiveMinutesBehind() {
        let segments = Self.segments(100)
        let actions = window.actions(playhead: 396, segments: segments, conversionPaused: false, conversionFinished: false)
        #expect(actions == [.delete(Array(segments.prefix(15)))]) // segment 15 ends at 96 = 396 − 300
    }

    @Test func aFinishedConversionIsNeitherPausedNorResumed() {
        #expect(window.actions(playhead: 0, segments: Self.segments(300), conversionPaused: false,
                               conversionFinished: true) == [])
        #expect(window.actions(playhead: 1_790, segments: Self.segments(300), conversionPaused: true,
                               conversionFinished: true).allSatisfy { $0 != .resumeConversion })
    }

    @Test func nothingConvertedYetIsFine() {
        #expect(window.actions(playhead: 0, segments: [], conversionPaused: false, conversionFinished: false) == [])
    }

    @Test func lowDiskKeepsOnlyFiveMinutesAhead() {
        let low = SegmentWindow.forFreeSpace(1_500_000_000)
        #expect(low.pauseAhead == 300)
        #expect(low.actions(playhead: 0, segments: Self.segments(50), conversionPaused: false,
                            conversionFinished: false) == [.pauseConversion])
        #expect(SegmentWindow.forFreeSpace(50_000_000_000) == SegmentWindow())
    }
}
