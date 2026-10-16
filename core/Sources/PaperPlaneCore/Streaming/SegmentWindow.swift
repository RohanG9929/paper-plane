import Foundation

/// Which converted segments to keep and when ffmpeg should rest (spec §4.2): keep from 5 minutes
/// behind the playhead to at most 20 minutes ahead; pause ffmpeg when it is 20 minutes ahead and
/// resume it below 10; delete what is more than 5 minutes behind. Pure, so the numbers are tested.
public struct SegmentWindow: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var index: Int
        /// Session time, in seconds.
        public var start: Double
        public var end: Double

        public init(index: Int, start: Double, end: Double) {
            self.index = index
            self.start = start
            self.end = end
        }

        /// ffmpeg's name for it (`-hls_segment_filename seg_%05d.m4s`).
        public var fileName: String {
            String(format: HLSFileNames.segmentPattern, index)
        }
    }

    public enum Action: Equatable, Sendable {
        case pauseConversion
        case resumeConversion
        /// Segments to delete, oldest first.
        case delete([Segment])
    }

    /// Seconds kept behind the playhead.
    public var keepBehind: Double
    /// ffmpeg pauses once it is this far ahead of the playhead.
    public var pauseAhead: Double
    /// …and resumes once it is less than this far ahead.
    public var resumeAhead: Double
    /// False for web streams: the site may drop a connection ffmpeg leaves idle, so their
    /// conversion runs on and only what's behind is deleted (addendum M3-16).
    public var pausesConversion = true

    public init(keepBehind: Double = 300, pauseAhead: Double = 1200, resumeAhead: Double = 600) {
        self.keepBehind = keepBehind
        self.pauseAhead = pauseAhead
        self.resumeAhead = resumeAhead
    }

    /// With less than 2 GB free in Caches, keep at most 5 minutes ahead (spec §6).
    public static func forFreeSpace(_ bytes: Int64) -> SegmentWindow {
        bytes < 2_000_000_000 ? SegmentWindow(pauseAhead: 300, resumeAhead: 150) : SegmentWindow()
    }

    /// What to do now. `segments` are the ones still on disk, in order; `playhead` is session time.
    public func actions(playhead: Double, segments: [Segment], conversionPaused: Bool,
                        conversionFinished: Bool) -> [Action] {
        var actions: [Action] = []
        let ahead = (segments.last?.end ?? 0) - playhead
        if pausesConversion && !conversionFinished {
            if !conversionPaused && ahead >= pauseAhead {
                actions.append(.pauseConversion)
            } else if conversionPaused && ahead < resumeAhead {
                actions.append(.resumeConversion)
            }
        }
        let old = segments.filter { $0.end < playhead - keepBehind }
        if !old.isEmpty {
            actions.append(.delete(old))
        }
        return actions
    }
}
