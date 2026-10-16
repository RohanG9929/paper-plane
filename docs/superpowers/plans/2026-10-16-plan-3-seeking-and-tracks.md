# Plan 3: Seeking, Tracks and Subtitles (Milestone 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seek anywhere in a film, switch audio and subtitles (embedded, sidecar `.srt`, burned in), see it in Control Center and on the media keys, keep the Mac awake, recover from network changes and low disk, and drop videos on the menu bar icon.

**Architecture:** A playback probes once and converts its text subtitles to WebVTT once; each seek outside what's converted and each audio or burned-in subtitle change starts a new ffmpeg session with its own server, whose master playlist offers the converted subtitles as renditions the player switches on the spot. `PlaybackController` grows a sessions half (seeking, tracks, the converted-video window, network changes) beside its lifecycle half. The app moves from SwiftUI's `MenuBarExtra` to an AppKit `NSStatusItem` so the icon can take drops, and gains a Settings window.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, AVFoundation, MediaPlayer, IOKit power management, Network.framework, SwiftUI with AppKit hosting, the bundled ffmpeg 9 (libass for burn-in).

**Spec:** `docs/superpowers/specs/2026-10-15-paper-plane-design.md` (§4, §4.1, §4.2, §6, Milestone 2), with the decisions in `docs/superpowers/specs/2026-10-16-milestone-2-decisions.md` (Task 1).

## Global Constraints

- macOS 14+, Apple Silicon only; Swift 6 language mode; no new package dependencies.
- Default output profile: surround **off**, HDR **on** (spec §4.1, Sony results).
- Converted-video window: keep 5 min behind the playhead; pause ffmpeg at 20 min ahead, resume below 10; with under 2 GB free in Caches, 5 min ahead (spec §4.2, §6).
- HLS: fMP4 segments of about 6 s; sessions under `~/Library/Caches/Paper Plane/sessions/<id>/`, deleted when they end and all wiped at launch.
- Subtitles are off unless a track is flagged forced (spec §4, step 2).
- `IOPMAssertion` prevents idle system sleep while the TV plays; lid-close sleep is not prevented (spec §6).
- Logs redact `Cookie`, `Authorization` and URL query strings (spec §5.4); log interpolations of user data are `.private`.
- Every commit uses the repo-local identity and ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nothing is pushed.
- Test commands: `scripts/test-core.sh` (Homebrew's ffmpeg); burn-in tests also need the bundled ffmpeg: `PAPERPLANE_FFMPEG="$PWD/vendor/ffmpeg/bin/ffmpeg" PAPERPLANE_FFPROBE="$PWD/vendor/ffmpeg/bin/ffprobe" scripts/test-core.sh`.

## Review Focus

The five inputs the spec implies, no task's happy path covers, and a person would hit first; each is pinned by the test named:

1. **Rapid repeated seeks or track changes** — each replaces the last, one session survives, nothing leaks. `PlaybackControllerMediaTests.rapidSeeksLeaveOneSession`, `quittingDuringASeekLeavesNothing` (Task 10).
2. **Subtitles that can't be read** (garbled sidecar, Windows Latin-1, a track ffmpeg can't convert) — the video carries on, subtitles off, a notice. `SubtitleExtractorTests.aTrackThatCantBeConvertedDoesNotStopTheOthers`, `SubtitleDecodingTests.readsTheUsualEncodings` (Task 5), `PlaybackControllerMediaTests.subtitlesThatCantBeReadTurnOffWithANotice` (Task 10).
3. **Odd file names** for videos and sidecars (colons, quotes, accents, spaces) — found, converted, and never placed in an ffmpeg filter graph. `SidecarSubtitlesTests.awkwardNamesStillMatch` (Task 3), `SubtitleExtractorTests.convertsEmbeddedAndSidecarSubtitlesToWebVTT` (Task 5), `StreamPipelineTests.offersEmbeddedAndSidecarSubtitles` (Task 8), `FFmpegArgumentsTests.textSubtitlesAreDrawnFromTheSessionsWebVTT` (Task 6).
4. **Seek boundaries** — before the start, past the end, into deleted segments. `PlaybackControllerMediaTests.seekingBeforeTheStartGoesToTheStart`, `seekingOutsideTheSessionStartsANewOneThere`, `theWindowRestsFFmpegAndDeletesWhatIsBehind` (Task 10).
5. **Network change and offline** — a new address serves again; offline waits. `PlaybackControllerMediaTests.aNewNetworkAddressServesTheVideoAgain` (Task 10).
6. **A video in Desktop, Documents or Downloads** — looking for sidecars there raises the macOS privacy prompt; quitting or opening another video while it's unanswered must not hang. `SidecarSubtitlesTests.aLookupStuckOnThePrivacyPromptCanBeAbandoned`, `aLookupCancelledBeforeItStartsReturnsAtOnce` (Task 3); `scripts/check-quit-cleanup.sh` copies its clips out of Documents so an unattended run raises no prompt (Task 13).

---

### Task 1: Record the Milestone 2 decisions

**Files:**
- Create: `docs/superpowers/specs/2026-10-16-milestone-2-decisions.md`

**Interfaces:**
- Produces: the decisions every later task follows (one server per session, subtitles as renditions matched by NAME, burn-in from the session's WebVTT, AppKit status item).

- [ ] **Step 1: Write the addendum**

```markdown
# Paper Plane — Milestone 2 decisions (addendum to the design spec)

**Date:** 2026-10-16 (overnight run; the owner pre-approved Plans 3–5 and is asleep)
**Status:** Decisions taken without the owner, inside the approved spec. Each says what it costs if wrong.

The design spec (`2026-10-15-paper-plane-design.md`) stays binding. Its Milestone 2 is "SegmentWindow, restart-on-seek, audio switching, text and picture subtitles, sidecar `.srt`, Now Playing and media keys, sleep assertion, error handling for local playback". The spec check found the gaps below; each was settled by trying it in a scratch copy first.

## Sessions

1. **A new server for each session.** Restart-on-seek and track changes start a new ffmpeg session in a new folder, served by a new `StreamServer` (new port, new token); the player gets the new master playlist's URL and the old session is stopped. Plan 2's server stays as it is. *Cost if wrong:* none at the TV; one listener per session either way.
2. **Seeking.** Within what the current session still has on disk (from its oldest kept segment to a second short of what's converted, or to the end once conversion has finished) a seek is a plain `AVPlayer` seek. Anywhere else starts a session at the target (spec §4.2). The seek bar spans the whole film; a seek past the end goes to the last second, one before the start goes to 0. While a new session starts, the remote says "Moving to 1:02:03…".
3. **The converted-video window** uses the spec's numbers (5 minutes behind; pause at 20 ahead, resume below 10; 5 ahead when Caches has under 2 GB free). It is checked on every new segment as well as on the playback clock: copying converts minutes of video per second, faster than the clock ticks. Seeking back into deleted segments starts a new session.
4. **Audio changes** start a session at the current time with the chosen track (spec §4.2).

## Subtitles

5. **Text subtitles are offered as tracks the player switches on the spot.** A playback converts every text track (embedded, and sidecar `.srt` in any of the usual encodings) to WebVTT once, in the background, on the movie's timeline. Each session copies them moved to its own start and lists them as `EXT-X-MEDIA:TYPE=SUBTITLES` renditions (the shape Sony test row 5 played). Switching uses AVFoundation's media selection. This replaces the spec's "restart on subtitle change" for text. *Cost if wrong:* a TV that ignores subtitle tracks; Settings → "Always burn in subtitles" is the fallback.
6. **Matching renditions to tracks by NAME.** AVFoundation names subtitle options after their language ("English", "Unknown"), not the playlist's NAME; the NAME arrives as the option's title metadata. Paper Plane gives each rendition a unique NAME (its display name, numbered when two match) and selects by that title.
7. **Converted in the background.** A session offers the subtitles converted by the time it starts. Choosing one it doesn't offer yet waits for the conversion and starts a session at the current time. A forced text track (on from the start, spec §4 step 2) waits for its conversion before the first session.
8. **Burning in.** Picture subtitles (PGS, VobSub, DVB) are overlaid from the file with ffmpeg's `overlay` (spec §4.1). With "Always burn in subtitles", text subtitles are drawn by libass from the session's own WebVTT copy (`burn-in.vtt`), so ffmpeg runs inside the session folder and the filter graph never holds a path that needs escaping. Text styling (ASS positions and fonts) is lost when burned in this way. *Cost if wrong:* plainer burned-in text; the subtitle-track path keeps styling the TV supports.
9. **Subtitles that can't be read** are turned off with a notice; the video carries on.
10. **Looking for sidecar files can raise a macOS privacy prompt.** Opening a video grants access to that file only; listing its folder in Desktop, Documents, Downloads or on another volume asks "Paper Plane would like to access files in your … folder" (Info.plist says why: to find subtitle files). The start waits for the answer, but a start that's cancelled — by quitting or opening another video — stops waiting at once, so quitting never hangs on an unanswered prompt. Denying it just means no sidecar subtitles. *Cost if wrong:* one prompt per protected folder, the first time.
11. **Picture-subtitle burn-in has no automated test with real media:** ffmpeg can't create PGS or VobSub test files. Its command line is unit-tested, and the Sony checklist covers it.

## Errors (spec §6)

12. **Logs.** A failure's details (the message shown, and ffmpeg's or ffprobe's own words) are saved, redacted and with the home folder shown as `~`, to `~/Library/Logs/Paper Plane/`; the last 10 are kept. The failure offers **Show Log**, which reveals the file in Finder. Missing ffmpeg and being offline explain themselves and save nothing.
13. **Network changes.** On a path change, if the Mac's LAN address differs from the one being served, Paper Plane serves again from the new address at the current time. While offline it waits; the next change brings it back.
14. **Low disk.** Under 2 GB free the window keeps 5 minutes ahead (spec); under 1 GB the remote also says once that Paper Plane converts only a few minutes ahead.

## App

15. **Dropping on the menu bar icon** (spec §4 step 1, deferred from Plan 2). SwiftUI's `MenuBarExtra` can't take drops, so the app moves to AppKit's lifecycle with its own `NSStatusItem`; the status bar window passes drags to its delegate. The menu is built from a tested model each time it opens: what's playing, Play/Pause, Stop, Audio and Subtitles submenus, then Open Video…, Show Remote, Settings…, Quit. *Cost if wrong:* drops on the icon may not register; the remote window and Open With still work. The owner checks it in the morning.
16. **Settings** (spec §4.1 overrides) is a small window with three switches — "Allow surround sound", "Convert HDR to SDR", "Always burn in subtitles" — kept in UserDefaults and read at each session's start.
17. **Now Playing and media keys** through `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`: play, pause, toggle, stop, ±10 s skips and scrubbing. Commands act only while a video is on the TV.
18. **Sleep.** An `IOPMAssertion` (prevent idle system sleep) is held while the TV plays and released when it pauses or stops.

## Remote window

19. **Audio and subtitles** share one menu beside the AirPlay button, as Apple's TV app has them. The status line shows what a new session is doing.
20. **The design audit's refine moves** (docs/design/DESIGN-IS-2026-10-15): the remote's buttons draw their own focus rings for Full Keyboard Access; the "choose your TV" box shows until a TV has been chosen once; the card's rhythm snaps to 8 pt; the track is as thick as the volume slider's. Move 5 (the tagline, "any video" or "almost any video") is the owner's call and is listed in the morning summary.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-10-16-milestone-2-decisions.md
git commit -m "docs: Milestone 2 decisions (addendum to the spec)"
```

### Task 2: SegmentWindow — what to keep and when ffmpeg rests

**Files:**
- Create: `core/Sources/PaperPlaneCore/Streaming/SegmentWindow.swift`
- Test: `core/Tests/PaperPlaneCoreTests/SegmentWindowTests.swift`

**Interfaces:**
- Produces: `SegmentWindow(keepBehind:pauseAhead:resumeAhead:)`, `SegmentWindow.forFreeSpace(_ bytes: Int64) -> SegmentWindow`, `actions(playhead:segments:conversionPaused:conversionFinished:) -> [SegmentWindow.Action]`; `SegmentWindow.Segment(index:start:end:)` with `fileName`; `Action.pauseConversion / .resumeConversion / .delete([Segment])`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct SegmentWindowTests {
    /// `count` 6-second segments from session time 0.
    static func segments(_ count: Int, from first: Int = 0) -> [SegmentWindow.Segment] {
        (first..<(first + count)).map { SegmentWindow.Segment(index: $0, start: Double($0) * 6, end: Double($0 + 1) * 6) }
    }

    let window = SegmentWindow()

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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `scripts/test-core.sh --filter SegmentWindowTests`
Expected: FAIL — `cannot find 'SegmentWindow' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
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
            String(format: "seg_%05d.m4s", index)
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
        if !conversionFinished {
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
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter SegmentWindowTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Streaming/SegmentWindow.swift core/Tests/PaperPlaneCoreTests/SegmentWindowTests.swift
git commit -m "feat(core): SegmentWindow keeps 5 minutes behind and rests ffmpeg 20 minutes ahead"
```

### Task 3: Sidecar subtitles and track names

**Files:**
- Create: `core/Sources/PaperPlaneCore/Media/SidecarSubtitles.swift`, `core/Sources/PaperPlaneCore/Media/TrackNames.swift`
- Test: `core/Tests/PaperPlaneCoreTests/SidecarSubtitlesTests.swift`, `core/Tests/PaperPlaneCoreTests/TrackNamesTests.swift`

**Interfaces:**
- Consumes: `MediaInfo`, `SubtitleTrack`, `AudioTrack`, `TrackRef` (Plan 1).
- Produces: `SidecarSubtitles.find(for: URL, listing:) async -> [SidecarSubtitles.File]` (`url`, `language`, `isForced`), which stops waiting on the folder listing as soon as the calling task is cancelled; `SubtitleOption(source:language:title:isForced:isText:)` with `Source.embedded(TrackRef) / .sidecar(URL)`, `id`, `displayName`, `SubtitleOption.all(in:sidecars:)`; `AudioTrack.displayName`; `TrackNames.languageName(_:)`, `languageTag(_:)`, `unique(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct SidecarSubtitlesTests {
    @Test func findsPlainLanguageAndForcedFiles() {
        let names = ["Movie.mkv", "Movie.srt", "Movie.en.srt", "Movie.pt-BR.srt", "movie.FR.SRT", "Movie.en.forced.srt",
                     "Movie.forced.srt", "Movie Extras.srt", "Movie.Extras.Part.srt", "Other.en.srt", "Movie.mkv.srt",
                     "Movie.Commentary.srt", "Movie.nfo"] // Movie.Commentary.srt belongs to Movie.Commentary.mkv
        let found = SidecarSubtitles.files(forVideoNamed: "Movie.mkv", among: names)
        #expect(found.map(\.name) == ["Movie.en.forced.srt", "Movie.en.srt", "Movie.forced.srt", "Movie.mkv.srt",
                                      "Movie.pt-BR.srt", "Movie.srt", "movie.FR.SRT"])
        #expect(found.map(\.language) == ["en", "en", nil, nil, "pt-BR", nil, "FR"])
        #expect(found.map(\.isForced) == [true, false, true, false, false, false, false])
    }

    @Test func awkwardNamesStillMatch() {
        let found = SidecarSubtitles.files(forVideoNamed: "Movie: Part 1 (Director's Cut) é.mp4",
                                           among: ["Movie: Part 1 (Director's Cut) é.en.srt", "Movie: Part 1.srt"])
        #expect(found.map(\.name) == ["Movie: Part 1 (Director's Cut) é.en.srt"])
    }

    @Test func findsFilesOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Show.mkv", "Show.en.srt", "Show.srt"] {
            try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8).write(to: folder.appendingPathComponent(name))
        }
        let found = await SidecarSubtitles.find(for: folder.appendingPathComponent("Show.mkv"))
        #expect(found.map(\.url.lastPathComponent) == ["Show.en.srt", "Show.srt"])
        #expect(await SidecarSubtitles.find(for: URL(fileURLWithPath: "/nonexistent/x.mkv")).isEmpty)
    }

    /// Listing a folder in Desktop, Documents or Downloads waits on the macOS privacy prompt until
    /// it's answered. A start that's cancelled (by quitting, or a newer video) must not wait too.
    @Test func aLookupStuckOnThePrivacyPromptCanBeAbandoned() async {
        let started = ContinuousClock.now
        let lookup = Task {
            await SidecarSubtitles.find(for: URL(fileURLWithPath: "/Movies/a.mkv")) { _ in
                Thread.sleep(forTimeInterval: 5) // blocked, as on the prompt
                return ["a.srt"]
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        lookup.cancel()
        #expect(await lookup.value.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aLookupCancelledBeforeItStartsReturnsAtOnce() async {
        let lookup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SidecarSubtitles.find(for: URL(fileURLWithPath: "/Movies/a.mkv")) { _ in
                Thread.sleep(forTimeInterval: 5)
                return ["a.srt"]
            }
        }
        let started = ContinuousClock.now
        #expect(await lookup.value.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
```

```swift
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
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter "SidecarSubtitlesTests|TrackNamesTests"`
Expected: FAIL — `cannot find 'SidecarSubtitles' in scope`, `cannot find 'SubtitleOption' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import os

/// Subtitle files next to a video: `Movie.srt` and `Movie.<language>.srt` for `Movie.mkv`
/// (spec §4, step 1).
public enum SidecarSubtitles {
    public struct File: Equatable, Sendable {
        public var url: URL
        /// From the name, e.g. `en` in `Movie.en.srt`. nil for `Movie.srt`.
        public var language: String?
        /// `Movie.en.forced.srt`.
        public var isForced: Bool
    }

    /// The `.srt` files beside `video`, sorted by name. Names are matched without regard to case.
    ///
    /// Listing a folder in Desktop, Documents or Downloads waits on the macOS privacy prompt
    /// until it's answered, so the folder is listed on another thread: if the calling task is
    /// cancelled meanwhile (the app quits, or a newer video replaces this one), this returns no
    /// files at once instead of waiting with it. `listing` stands in for the file system in tests.
    public static func find(for video: URL, listing: @escaping @Sendable (URL) -> [String] = Self.contents)
        async -> [File] {
        let folder = video.deletingLastPathComponent()
        let names = await abandonable { listing(folder) } ?? []
        return files(forVideoNamed: video.lastPathComponent, among: names)
            .map { File(url: folder.appendingPathComponent($0.name), language: $0.language, isForced: $0.isForced) }
    }

    @Sendable public static func contents(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    /// `work`'s result, or nil as soon as the calling task is cancelled, without waiting for
    /// `work`, which may be blocked in the kernel.
    static func abandonable<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.withLock { $0 = continuation }
                if Task.isCancelled { // cancelled before the handler had anything to resume
                    pending.withLock { $0.take() }?.resume(returning: nil)
                    return
                }
                DispatchQueue.global().async {
                    let result = work()
                    pending.withLock { $0.take() }?.resume(returning: result)
                }
            }
        } onCancel: {
            pending.withLock { $0.take() }?.resume(returning: nil)
        }
    }

    /// The matching names among `names`, for the video file `videoName` (e.g. `Movie.mkv`).
    static func files(forVideoNamed videoName: String,
                      among names: [String]) -> [(name: String, language: String?, isForced: Bool)] {
        let base = (videoName as NSString).deletingPathExtension
        let videoExtension = (videoName as NSString).pathExtension.lowercased()
        let prefix = base.lowercased() + "."
        return names.sorted().compactMap { name in
            let lower = name.lowercased()
            // "Movie.srt", and "Movie.mkv.srt" as some tools name it.
            if lower == prefix + "srt" || (!videoExtension.isEmpty && lower == prefix + videoExtension + ".srt") {
                return (name, nil, false)
            }
            // What's between "Movie." and ".srt": a language, "forced", or language.forced.
            guard lower.hasPrefix(prefix), lower.hasSuffix(".srt"), lower.count > prefix.count + 4 else { return nil }
            let middle = String(name.dropFirst(prefix.count).dropLast(4))
            var parts = middle.split(separator: ".").map(String.init)
            let isForced = parts.last?.lowercased() == "forced"
            if isForced {
                parts.removeLast()
            }
            switch parts.count {
            case 0:
                return (name, nil, true)
            case 1 where isLanguageTag(parts[0]):
                return (name, parts[0], isForced)
            default:
                return nil // e.g. "Movie.Extras.Part.srt" belongs to another video
            }
        }
    }

    /// `en`, `eng`, `pt-BR`, `zh-Hant`: 2–3 letters, optionally a dash and 2–4 letters or digits.
    static func isLanguageTag(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,4})?/) != nil
    }
}
```

```swift
import Foundation

/// A subtitle the user can pick: a track in the file, or a sidecar `.srt` beside it (spec §4).
public struct SubtitleOption: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable {
        case embedded(TrackRef)
        case sidecar(URL)
    }

    public var source: Source
    /// As the file gives it: `eng`, `en`, `pt-BR`. nil when unknown.
    public var language: String?
    public var title: String?
    public var isForced: Bool
    /// Text (SRT, ASS, WebVTT, mov_text) becomes a subtitle track the TV shows; pictures (PGS,
    /// VobSub, DVB) are burned into the video.
    public var isText: Bool

    public init(source: Source, language: String?, title: String?, isForced: Bool, isText: Bool) {
        self.source = source
        self.language = language
        self.title = title
        self.isForced = isForced
        self.isText = isText
    }

    /// Stable within one playback.
    public var id: String {
        switch source {
        case .embedded(let ref): "track-\(ref.input)-\(ref.index)"
        case .sidecar(let url): "file-\(url.lastPathComponent)"
        }
    }

    /// The file's tracks Paper Plane can show, then the sidecar files, in that order.
    public static func all(in media: MediaInfo, sidecars: [SidecarSubtitles.File]) -> [SubtitleOption] {
        media.subtitles.filter { $0.kind != .unsupported }.map {
            SubtitleOption(source: .embedded($0.ref), language: $0.language, title: $0.title, isForced: $0.isForced,
                           isText: $0.kind == .text)
        } + sidecars.map {
            SubtitleOption(source: .sidecar($0.url), language: $0.language, title: $0.url.lastPathComponent,
                           isForced: $0.isForced, isText: true)
        }
    }

    /// "English", "English (SDH)", "French (Forced)", or "Subtitles" when nothing is known.
    public var displayName: String {
        TrackNames.name(language: language, title: title, fallback: "Subtitles", extra: isForced ? "Forced" : nil)
    }
}

extension AudioTrack {
    /// "English (5.1)", "Japanese — Commentary (Stereo)", "Audio" when nothing is known.
    public var displayName: String {
        let layout = switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) channels"
        }
        return TrackNames.name(language: language, title: title, fallback: "Audio", extra: layout)
    }
}

public enum TrackNames {
    /// "English", from `eng`, `en` or `EN`; "Portuguese (Brazil)" from `pt-BR`. nil for codes
    /// Foundation doesn't know.
    public static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Locale(identifier: "en").localizedString(forIdentifier: code)
    }

    /// The tag HLS's `LANGUAGE` wants (RFC 5646): the two-letter code where one exists (`eng` →
    /// `en`), otherwise the code as given.
    public static func languageTag(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let language = Locale.Language(identifier: bibliographicCodes[code.lowercased()] ?? code)
        guard let base = language.languageCode?.identifier(.alpha2) else { return code }
        return [base, language.region?.identifier].compactMap { $0 }.joined(separator: "-")
    }

    /// ISO 639-2's bibliographic codes, which Matroska files often use, and their two-letter
    /// equivalents. Foundation only knows the terminological ones (`fra`, not `fre`).
    private static let bibliographicCodes = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr",
        "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms", "per": "fa",
        "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
    ]

    static func name(language: String?, title: String?, fallback: String, extra: String?) -> String {
        let languageName = languageName(language)
        var name = languageName ?? title ?? fallback
        if languageName != nil, let title, !title.isEmpty {
            name += " — \(title)"
        }
        if let extra {
            name += " (\(extra))"
        }
        return name
    }

    /// `names` made unique, so each can identify one track: a repeat gets " 2", " 3", ….
    public static func unique(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            return count == 1 ? name : "\(name) \(count)"
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter "SidecarSubtitlesTests|TrackNamesTests"`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Media/SidecarSubtitles.swift core/Sources/PaperPlaneCore/Media/TrackNames.swift core/Tests/PaperPlaneCoreTests/SidecarSubtitlesTests.swift core/Tests/PaperPlaneCoreTests/TrackNamesTests.swift
git commit -m "feat(core): find sidecar .srt files and name audio and subtitle tracks"
```

### Task 4: WebVTT moved to a session's start, and subtitle renditions

**Files:**
- Create: `core/Sources/PaperPlaneCore/Streaming/WebVTT.swift`
- Modify: `core/Sources/PaperPlaneCore/Streaming/MasterPlaylist.swift`
- Test: `core/Tests/PaperPlaneCoreTests/WebVTTTests.swift`, `core/Tests/PaperPlaneCoreTests/HLSFilesTests.swift`

**Interfaces:**
- Produces: `WebVTT.shifted(_ text: String, by offset: Double) -> String`; `MasterPlaylist.Subtitle(name:language:isForced:uri:)`; `MasterPlaylist.text(bandwidth:initSegment:frameRate:videoRange:subtitles:)`; `MasterPlaylist.subtitlePlaylist(file:duration:) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

```diff
--- a/core/Tests/PaperPlaneCoreTests/HLSFilesTests.swift
+++ b/core/Tests/PaperPlaneCoreTests/HLSFilesTests.swift
@@ -109,6 +109,40 @@
         #expect(text.contains("#EXT-X-STREAM-INF:BANDWIDTH=800000,VIDEO-RANGE=SDR\nindex.m3u8\n"))
     }
 
+    @Test func offersSubtitleTracks() {
+        let text = MasterPlaylist.text(
+            bandwidth: 800_000, initSegment: InitSegment(codecs: nil, width: nil, height: nil), frameRate: nil,
+            videoRange: .sdr,
+            subtitles: [
+                MasterPlaylist.Subtitle(name: "English", language: "en", isForced: false, uri: "sub_0.m3u8"),
+                MasterPlaylist.Subtitle(name: #"Signs "and" songs"#, language: nil, isForced: true, uri: "sub_1.m3u8"),
+            ])
+        #expect(text == """
+            #EXTM3U
+            #EXT-X-VERSION:7
+            #EXT-X-INDEPENDENT-SEGMENTS
+            #EXT-X-START:TIME-OFFSET=0
+            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI="sub_0.m3u8"
+            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Signs 'and' songs",DEFAULT=NO,AUTOSELECT=YES,FORCED=YES,URI="sub_1.m3u8"
+            #EXT-X-STREAM-INF:BANDWIDTH=800000,VIDEO-RANGE=SDR,SUBTITLES="subs"
+            index.m3u8
+
+            """)
+    }
+
+    @Test func aSubtitlePlaylistIsOneFileForTheWholeSession() {
+        #expect(MasterPlaylist.subtitlePlaylist(file: "sub_0.vtt", duration: 5_400.2) == """
+            #EXTM3U
+            #EXT-X-VERSION:3
+            #EXT-X-TARGETDURATION:5401
+            #EXT-X-PLAYLIST-TYPE:VOD
+            #EXTINF:5400.200,
+            sub_0.vtt
+            #EXT-X-ENDLIST
+
+            """)
+    }
+
     @Test func bandwidthIsThePeakSegmentRateWithHeadroom() {
         // 6 s of 3 MB is 4 Mb/s; 2 s of 2 MB is 8 Mb/s, the peak.
         #expect(MasterPlaylist.bandwidth(segmentSizes: [(3_000_000, 6), (2_000_000, 2)]) == 8_800_000)
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter "WebVTTTests|MasterPlaylistTests"`
Expected: FAIL — `cannot find 'WebVTT' in scope`, `type 'MasterPlaylist' has no member 'Subtitle'`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Reading and moving WebVTT cues. Subtitles are converted once per playback, on the movie's
/// timeline; each session starts `offset` seconds into the movie, so its copy moves every cue
/// that much earlier.
enum WebVTT {
    /// `text` with every cue `offset` seconds earlier. Cues that end before the new start are
    /// dropped, and one that spans it starts at 0. The header, styles and notes are kept.
    static func shifted(_ text: String, by offset: Double) -> String {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let kept = blocks.compactMap { block -> String? in
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else {
                return block // WEBVTT header, STYLE, REGION or NOTE
            }
            let sides = lines[timing].components(separatedBy: "-->")
            let endAndSettings = sides[1].trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard sides.count == 2, let start = seconds(sides[0].trimmingCharacters(in: .whitespaces)),
                  let endText = endAndSettings.first, let end = seconds(String(endText))
            else { return nil } // a malformed cue
            guard end - offset > 0 else { return nil }
            let settings = endAndSettings.count > 1 ? " " + endAndSettings[1] : ""
            // timestamp() starts a cue that spans the session's start at 0.
            lines[timing] = "\(timestamp(start - offset)) --> \(timestamp(end - offset))\(settings)"
            return lines.joined(separator: "\n")
        }
        return kept.joined(separator: "\n\n") + "\n"
    }

    /// "01:02:03.456" or "02:03.456" → seconds.
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count), let last = Double(parts[parts.count - 1]) else { return nil }
        var total = last
        var multiplier = 60.0
        for part in parts.dropLast().reversed() {
            guard let value = Int(part) else { return nil }
            total += Double(value) * multiplier
            multiplier *= 60
        }
        return total
    }

    /// Seconds → "01:02:03.456".
    static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
```

```diff
--- a/core/Sources/PaperPlaneCore/Streaming/MasterPlaylist.swift
+++ b/core/Sources/PaperPlaneCore/Streaming/MasterPlaylist.swift
@@ -7,10 +7,23 @@
 /// - `CODECS`, `RESOLUTION`, `FRAME-RATE` and `VIDEO-RANGE`, which Apple's HLS authoring spec
 ///   asks for and which tell the TV up front that a stream is HDR. AVFoundation refuses a
 ///   `VIDEO-RANGE=PQ` variant that has no `FRAME-RATE`, and refuses HDR video declared as SDR.
+/// - The text subtitles, as WebVTT renditions the player can switch between without a restart
+///   (docs/sony-test-results.md, row 5).
 enum MasterPlaylist {
     static let fileName = "master.m3u8"
 
-    static func text(bandwidth: Int, initSegment: InitSegment, frameRate: Double?, videoRange: VideoRange) -> String {
+    /// One subtitle rendition. `name` must be unique in the playlist: the player's subtitle
+    /// options are matched to tracks by it.
+    struct Subtitle: Equatable, Sendable {
+        var name: String
+        /// An RFC 5646 tag (`TrackNames.languageTag`), or nil.
+        var language: String?
+        var isForced: Bool
+        var uri: String
+    }
+
+    static func text(bandwidth: Int, initSegment: InitSegment, frameRate: Double?, videoRange: VideoRange,
+                     subtitles: [Subtitle] = []) -> String {
         var attributes = ["BANDWIDTH=\(bandwidth)"]
         if let codecs = initSegment.codecs {
             attributes.append("CODECS=\"\(codecs.joined(separator: ","))\"")
@@ -22,13 +35,43 @@
             attributes.append(String(format: "FRAME-RATE=%.3f", frameRate))
         }
         attributes.append("VIDEO-RANGE=\(videoRange.rawValue)")
-        return [
+        if !subtitles.isEmpty {
+            attributes.append("SUBTITLES=\"subs\"")
+        }
+        let media = subtitles.map { subtitle in
+            var fields = ["TYPE=SUBTITLES", "GROUP-ID=\"subs\"", "NAME=\"\(quoted(subtitle.name))\""]
+            if let language = subtitle.language {
+                fields.append("LANGUAGE=\"\(quoted(language))\"")
+            }
+            // Nothing is on by default: the controller picks, so a forced track still needs
+            // AUTOSELECT (which FORCED=YES requires) but not DEFAULT.
+            fields += ["DEFAULT=NO", "AUTOSELECT=YES", "FORCED=\(subtitle.isForced ? "YES" : "NO")",
+                       "URI=\"\(quoted(subtitle.uri))\""]
+            return "#EXT-X-MEDIA:" + fields.joined(separator: ",")
+        }
+        return ([
             "#EXTM3U",
             "#EXT-X-VERSION:7",
             "#EXT-X-INDEPENDENT-SEGMENTS",
             "#EXT-X-START:TIME-OFFSET=0",
+        ] + media + [
             "#EXT-X-STREAM-INF:" + attributes.joined(separator: ","),
             HLSFileNames.mediaPlaylist,
+            "",
+        ]).joined(separator: "\n")
+    }
+
+    /// The playlist for one subtitle rendition: a single WebVTT file covering the session
+    /// (the shape the Sony test played, row 5).
+    static func subtitlePlaylist(file: String, duration: Double) -> String {
+        [
+            "#EXTM3U",
+            "#EXT-X-VERSION:3",
+            "#EXT-X-TARGETDURATION:\(Int(duration.rounded(.up)))",
+            "#EXT-X-PLAYLIST-TYPE:VOD",
+            String(format: "#EXTINF:%.3f,", duration),
+            file,
+            "#EXT-X-ENDLIST",
             "",
         ].joined(separator: "\n")
     }
@@ -41,4 +84,9 @@
             .max() ?? 0
         return max(Int((peak * 1.1).rounded(.up)), 100_000)
     }
+
+    /// A quoted-string attribute value can't hold a double quote or a line break.
+    private static func quoted(_ text: String) -> String {
+        String(text.map { $0 == "\"" ? "'" : $0.isNewline ? " " : $0 })
+    }
 }
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter "WebVTTTests|MasterPlaylistTests"`
Expected: PASS (5 WebVTT tests, 5 master playlist tests).

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Streaming/WebVTT.swift core/Sources/PaperPlaneCore/Streaming/MasterPlaylist.swift core/Tests/PaperPlaneCoreTests/WebVTTTests.swift core/Tests/PaperPlaneCoreTests/HLSFilesTests.swift
git commit -m "feat(core): move WebVTT cues to a session's start and offer subtitle renditions"
```

### Task 5: Convert text subtitles to WebVTT once per playback

**Files:**
- Create: `core/Sources/PaperPlaneCore/Streaming/SubtitleExtractor.swift`
- Test: `core/Tests/PaperPlaneCoreTests/SubtitleExtractorTests.swift`

**Interfaces:**
- Consumes: `SubtitleOption` (Task 3), `ResolvedInput.Input.ffmpegInputArguments(seek:)`, `ffmpegQuietArguments`, `ProcessRunner` (Plan 2).
- Produces: `SubtitleExtractor(tools:).extract(_ options: [SubtitleOption], from: ResolvedInput, into: URL) async -> [String: URL]` (files by option id, `<n>.vtt`); `SubtitleExtractor.decode(_ data: Data) -> String?`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct SubtitleDecodingTests {
    @Test func readsTheUsualEncodings() {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nCafé\n"
        #expect(SubtitleExtractor.decode(Data(text.utf8)) == text)
        #expect(SubtitleExtractor.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == text)
        #expect(SubtitleExtractor.decode(text.data(using: .utf16)!) == text) // with a byte order mark
        #expect(SubtitleExtractor.decode(text.data(using: .windowsCP1252)!) == text)
    }
}

@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct SubtitleExtractorTests {
    @Test func convertsEmbeddedAndSidecarSubtitlesToWebVTT() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // An old-style sidecar in Windows Latin-1, beside a link to the clip with an embedded SRT.
        let sidecar = folder.appendingPathComponent("Clip: Été.fr.srt")
        try "1\n00:00:02,000 --> 00:00:03,500\nÉté\n".data(using: .windowsCP1252)!.write(to: sidecar)
        let input = ResolvedInput.file(TestSupport.media("h264_ac3_51.mkv"))
        let options = [
            SubtitleOption(source: .embedded(TrackRef(index: 2)), language: nil, title: nil, isForced: false,
                           isText: true),
            SubtitleOption(source: .embedded(TrackRef(index: 9)), language: nil, title: nil, isForced: false,
                           isText: false), // a picture track is burned in, not converted
            SubtitleOption(source: .sidecar(sidecar), language: "fr", title: nil, isForced: false, isText: true),
        ]
        let output = folder.appendingPathComponent("vtt")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let files = await SubtitleExtractor(tools: try #require(TestSupport.tools))
            .extract(options, from: input, into: output)

        #expect(Set(files.keys) == ["track-0-2", "file-Clip: Été.fr.srt"])
        let embedded = try String(contentsOf: try #require(files["track-0-2"]), encoding: .utf8)
        #expect(embedded.hasPrefix("WEBVTT"))
        #expect(embedded.contains("00:01.000 --> 00:04.000\nPaper Plane test subtitle one"))
        let french = try String(contentsOf: try #require(files["file-Clip: Été.fr.srt"]), encoding: .utf8)
        #expect(french.contains("00:02.000 --> 00:03.500\nÉté"))
        // The UTF-8 copy made for ffmpeg is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["0.vtt", "2.vtt"])
    }

    @Test func aTrackThatCantBeConvertedDoesNotStopTheOthers() async throws {
        let output = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let input = ResolvedInput.file(TestSupport.media("h264_ac3_51.mkv"))
        let options = [
            SubtitleOption(source: .embedded(TrackRef(index: 1)), language: nil, title: nil, isForced: false,
                           isText: true), // really the audio track: ffmpeg can't make WebVTT of it
            SubtitleOption(source: .embedded(TrackRef(index: 2)), language: nil, title: nil, isForced: false,
                           isText: true),
            SubtitleOption(source: .sidecar(output.appendingPathComponent("missing.srt")), language: nil, title: nil,
                           isForced: false, isText: true),
        ]
        let files = await SubtitleExtractor(tools: try #require(TestSupport.tools))
            .extract(options, from: input, into: output)
        #expect(Array(files.keys) == ["track-0-2"])
    }
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `scripts/test-core.sh --filter "SubtitleExtractorTests|SubtitleDecodingTests"`
Expected: FAIL — `cannot find 'SubtitleExtractor' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Converts a playback's text subtitles to WebVTT once, on the movie's timeline. Each session
/// then serves a copy moved to its own start (`WebVTT.shifted`).
public struct SubtitleExtractor: Sendable {
    public var tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    /// Writes `<n>.vtt` into `folder` for each text option (`n` is its position in `options`)
    /// and returns the files by option id. A track that can't be converted is left out.
    /// Cancelling stops ffmpeg.
    public func extract(_ options: [SubtitleOption], from input: ResolvedInput,
                        into folder: URL) async -> [String: URL] {
        var files: [String: URL] = [:]
        let numbered = options.enumerated().filter { $0.element.isText }
        let embedded = numbered.compactMap { item -> (Int, TrackRef)? in
            if case .embedded(let ref) = item.element.source { (item.offset, ref) } else { nil }
        }
        if !embedded.isEmpty {
            // One pass over the file for all tracks; if a track breaks it, one pass each.
            let all = await convert(embedded, from: input, into: folder)
            let made = all ? embedded : await embedded.asyncFilter { await convert([$0], from: input, into: folder) }
            for (number, _) in made {
                files[options[number].id] = Self.file(number, in: folder)
            }
        }
        for (number, option) in numbered {
            guard case .sidecar(let url) = option.source, !Task.isCancelled else { continue }
            if await convertSidecar(url, to: Self.file(number, in: folder)) {
                files[option.id] = Self.file(number, in: folder)
            }
        }
        return files
    }

    static func file(_ number: Int, in folder: URL) -> URL {
        folder.appendingPathComponent("\(number).vtt")
    }

    /// One ffmpeg run writing each track to its own WebVTT file. True if every file was made.
    private func convert(_ tracks: [(Int, TrackRef)], from input: ResolvedInput, into folder: URL) async -> Bool {
        var arguments = ffmpegQuietArguments + ["-y"]
        for item in input.inputs {
            arguments += item.ffmpegInputArguments(seek: 0)
        }
        for (number, ref) in tracks {
            arguments += ["-map", ref.mapSpecifier, "-c:s", "webvtt", "-f", "webvtt", Self.file(number, in: folder).path]
        }
        guard let result = try? await ProcessRunner.run(tools.ffmpeg, arguments: arguments), result.status == 0
        else { return false }
        return tracks.allSatisfy { FileManager.default.fileExists(atPath: Self.file($0.0, in: folder).path) }
    }

    /// A sidecar `.srt`, whatever its text encoding, to WebVTT.
    private func convertSidecar(_ url: URL, to output: URL) async -> Bool {
        guard let data = try? Data(contentsOf: url), let text = Self.decode(data) else { return false }
        // ffmpeg reads subtitles as UTF-8, so hand it a UTF-8 copy.
        let utf8 = output.deletingPathExtension().appendingPathExtension("srt")
        defer { try? FileManager.default.removeItem(at: utf8) }
        guard (try? Data(text.utf8).write(to: utf8)) != nil else { return false }
        let arguments = ffmpegQuietArguments + ["-y", "-i", utf8.path, "-c:s", "webvtt", "-f", "webvtt", output.path]
        guard let result = try? await ProcessRunner.run(tools.ffmpeg, arguments: arguments) else { return false }
        return result.status == 0
    }

    /// Subtitle files come in UTF-8 (with or without a byte order mark), UTF-16 with one, or,
    /// from older tools, Windows Latin-1.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .windowsCP1252)
    }
}

extension Sequence {
    func asyncFilter(_ isIncluded: (Element) async -> Bool) async -> [Element] {
        var kept: [Element] = []
        for element in self where await isIncluded(element) {
            kept.append(element)
        }
        return kept
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter "SubtitleExtractorTests|SubtitleDecodingTests"`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Streaming/SubtitleExtractor.swift core/Tests/PaperPlaneCoreTests/SubtitleExtractorTests.swift
git commit -m "feat(core): convert embedded and sidecar text subtitles to WebVTT"
```

### Task 6: Burning subtitles into the picture

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift`, `core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift`, `core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift`
- Test: `core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift`, `core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift`

**Interfaces:**
- Produces: `TrackChoice(audio:burnIn:)`; `BurnIn.picture(TrackRef) / .text`; `ConversionPlan.burnIn`; `HLSFileNames.burnInSubtitles` (`burn-in.vtt`). Picture subtitles go through `-filter_complex "[v](tone map)[base];[base][s]overlay=eof_action=pass[video]"`; text through `-vf (tone map,)subtitles=f=burn-in.vtt` with ffmpeg running in the session folder (Task 7). Tone mapping always comes first, so subtitles keep their own colours.

- [ ] **Step 1: Write the failing tests**

```diff
--- a/core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift
+++ b/core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift
@@ -160,4 +160,28 @@
         #expect(plan.audio == nil)
         #expect(plan.audioAction == nil)
     }
+
+    // MARK: - Burning in subtitles (spec §4.1)
+
+    @Test func burningInReencodesVideoThatWouldBeCopied() throws {
+        let pgs = TrackRef(index: 3)
+        let plan = try ConversionPlanner.plan(Self.media([Self.video(.h264, height: 720)], []),
+                                              choice: TrackChoice(burnIn: .picture(pgs)))
+        #expect(plan.burnIn == .picture(pgs))
+        #expect(plan.videoAction == .encode(VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false,
+                                                        bitrate: 5_000_000)))
+
+        let hdr = try ConversionPlanner.plan(Self.media([Self.video(.hevc, height: 2160, pixelFormat: "yuv420p10le",
+                                                                    hdr: .pq)], []),
+                                             choice: TrackChoice(burnIn: .text), profile: Self.surroundAndHDR)
+        #expect(hdr.videoAction == .encode(VideoEncode(encoder: .hevc, keepHDR: .pq, toneMapToSDR: false,
+                                                       bitrate: 16_000_000)))
+        #expect(hdr.videoRange == .pq)
+    }
+
+    @Test func noBurnInLeavesTheVideoAlone() throws {
+        let plan = try ConversionPlanner.plan(Self.media([Self.video(.h264)], []))
+        #expect(plan.burnIn == nil)
+        #expect(plan.videoAction == .copy(.h264))
+    }
 }
```

```diff
--- a/core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift
+++ b/core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift
@@ -85,6 +85,43 @@
         #expect(stereo.contains(subsequence: ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]))
     }
 
+    @Test func pictureSubtitlesAreOverlaid() {
+        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: true, bitrate: 8_000_000)
+        var plan = Self.plan(.encode(encode))
+        plan.burnIn = .picture(TrackRef(index: 4))
+        let args = plan.ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
+        // The video is tone-mapped first, so the subtitles keep their own colours.
+        #expect(args.contains(subsequence: [
+            "-filter_complex", "[0:0]" + ConversionPlan.toneMapFilter + "[base];[base][0:4]overlay=eof_action=pass[video]",
+            "-map", "[video]", "-map", "0:2",
+        ]))
+        #expect(!args.contains("-vf"))
+        #expect(!args.contains("0:0"))
+
+        plan.videoAction = .encode(VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false, bitrate: 8_000_000))
+        #expect(plan.ffmpegArguments(input: Self.movie, start: 0, output: Self.output).contains(subsequence: [
+            "-filter_complex", "[0:0][0:4]overlay=eof_action=pass[video]",
+        ]))
+    }
+
+    @Test func textSubtitlesAreDrawnAfterToneMapping() {
+        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: true, bitrate: 8_000_000)
+        var plan = Self.plan(.encode(encode))
+        plan.burnIn = .text
+        let args = plan.ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
+        #expect(args.contains(subsequence: ["-vf", ConversionPlan.toneMapFilter + ",subtitles=f=burn-in.vtt"]))
+    }
+
+    @Test func textSubtitlesAreDrawnFromTheSessionsWebVTT() {
+        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false, bitrate: 8_000_000)
+        var plan = Self.plan(.encode(encode))
+        plan.burnIn = .text
+        let args = plan.ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
+        // A plain relative name: ffmpeg runs in the session folder, so no path needs escaping.
+        #expect(args.contains(subsequence: ["-vf", "subtitles=f=burn-in.vtt"]))
+        #expect(args.contains(subsequence: ["-map", "0:0"]))
+    }
+
     @Test func noAudioDisablesAudio() {
         let args = Self.plan(.copy(.h264), audio: nil).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
         #expect(args.contains("-an"))
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter "ConversionPlannerTests|FFmpegArgumentsTests"`
Expected: FAIL — `extra argument 'burnIn' in call`, `value of type 'ConversionPlan' has no member 'burnIn'`.

- [ ] **Step 3: Write the implementation**

```diff
--- a/core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift
+++ b/core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift
@@ -19,10 +19,22 @@
 /// The user's track picks. nil means "use the default".
 public struct TrackChoice: Equatable, Sendable {
     public var audio: TrackRef?
+    /// Subtitles drawn into the picture, which means converting the video.
+    public var burnIn: BurnIn?
 
-    public init(audio: TrackRef? = nil) {
+    public init(audio: TrackRef? = nil, burnIn: BurnIn? = nil) {
         self.audio = audio
+        self.burnIn = burnIn
     }
+}
+
+/// Subtitles burned into the video (spec §4.1).
+public enum BurnIn: Equatable, Sendable {
+    /// A picture track (PGS, VobSub, DVB), overlaid straight from the file.
+    case picture(TrackRef)
+    /// A text track, drawn by libass from the session's `burn-in.vtt` (the "Always burn in
+    /// subtitles" setting, for TVs that don't show subtitle tracks).
+    case text
 }
 
 public enum VideoEncoder: Equatable, Sendable {
@@ -78,6 +90,8 @@
     public var videoRange: VideoRange = .sdr
     /// The video's frames per second, which conversion keeps. nil when unknown.
     public var frameRate: Double? = nil
+    /// Subtitles drawn into the picture. Only with `.encode`.
+    public var burnIn: BurnIn? = nil
 }
 
 public enum PlanError: Error, Equatable {
```

```diff
--- a/core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift
+++ b/core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift
@@ -9,14 +9,15 @@
     ) throws -> ConversionPlan {
         guard let video = media.video.first else { throw PlanError.noVideoTrack }
         let audio = try pickAudio(media.audio, choice: choice.audio)
-        let action = videoAction(for: video, profile: profile)
+        let action = videoAction(for: video, profile: profile, burningIn: choice.burnIn != nil)
         return ConversionPlan(
             video: video.ref,
             videoAction: action,
             audio: audio?.ref,
             audioAction: audio.map { audioAction(for: $0, profile: profile) },
             videoRange: videoRange(of: video, after: action),
-            frameRate: video.frameRate)
+            frameRate: video.frameRate,
+            burnIn: choice.burnIn)
     }
 
     // MARK: - Video
@@ -27,9 +28,10 @@
         .hevc: ["yuv420p", "yuvj420p", "yuv420p10le"],
     ]
 
-    static func videoAction(for track: VideoTrack, profile: OutputProfile) -> VideoAction {
+    /// Copy what Apple can decode, unless subtitles are drawn into it; otherwise convert.
+    static func videoAction(for track: VideoTrack, profile: OutputProfile, burningIn: Bool = false) -> VideoAction {
         let needsToneMap = track.hdr != nil && !profile.hdr
-        if let formats = copyablePixelFormats[track.codec],
+        if !burningIn, let formats = copyablePixelFormats[track.codec],
            formats.contains(track.pixelFormat ?? "yuv420p"),
            !needsToneMap {
             return .copy(track.codec)
```

```diff
--- a/core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift
+++ b/core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift
@@ -8,6 +8,8 @@
     static let mediaPlaylist = "index.m3u8"
     static let initSegment = "init.mp4"
     static let segmentPattern = "seg_%05d.m4s"
+    /// The text subtitles to burn in, as WebVTT on the session's timeline.
+    static let burnInSubtitles = "burn-in.vtt"
 }
 
 extension ResolvedInput.Input {
@@ -36,7 +38,24 @@
             args += item.ffmpegInputArguments(seek: start)
         }
 
-        args += ["-map", video.mapSpecifier]
+        var filters = burnIn == .text ? ["subtitles=f=\(HLSFileNames.burnInSubtitles)"] : []
+        if case .encode(let encode) = videoAction, encode.toneMapToSDR {
+            // Tone-map before drawing subtitles, so they keep their own colours.
+            filters.insert(Self.toneMapFilter, at: 0)
+        }
+        if case .picture(let subtitles) = burnIn {
+            // The video's own filters first, then the subtitles on top.
+            let base = filters.isEmpty
+                ? "[\(video.mapSpecifier)]"
+                : "[\(video.mapSpecifier)]" + filters.joined(separator: ",") + "[base];[base]"
+            args += ["-filter_complex", base + "[\(subtitles.mapSpecifier)]overlay=eof_action=pass[video]",
+                     "-map", "[video]"]
+        } else {
+            args += ["-map", video.mapSpecifier]
+            if !filters.isEmpty {
+                args += ["-vf", filters.joined(separator: ",")]
+            }
+        }
         if let audio {
             args += ["-map", audio.mapSpecifier]
         } else {
@@ -83,9 +102,6 @@
                 "-b:v", String(encode.bitrate),
                 "-force_key_frames", "expr:gte(t,n_forced*\(Self.segmentSeconds))",
             ]
-            if encode.toneMapToSDR {
-                args += ["-vf", Self.toneMapFilter]
-            }
             return args
         }
     }
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter "ConversionPlannerTests|FFmpegArgumentsTests"`
Expected: PASS, 30 tests.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Conversion core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift
git commit -m "feat(core): plan burned-in picture and text subtitles"
```

### Task 7: Sessions write their own subtitles; ffmpeg runs in the session folder

**Files:**
- Create: `core/Sources/PaperPlaneCore/Streaming/SessionSubtitles.swift`
- Modify: `core/Sources/PaperPlaneCore/Streaming/Transcoder.swift`, `core/Sources/PaperPlaneCore/Support/BackgroundProcess.swift`
- Test: `core/Tests/PaperPlaneCoreTests/SessionSubtitlesTests.swift`

**Interfaces:**
- Consumes: `WebVTT.shifted`, `MasterPlaylist.Subtitle`, `subtitlePlaylist` (Task 4), `TrackNames.languageTag` (Task 3), `HLSFileNames.burnInSubtitles`, `BurnIn` (Task 6), `SegmentWindow.Segment` (Task 2).
- Produces: `SessionSubtitles(tracks:burnIn:duration:)` with `SessionSubtitles.Track(name:language:isForced:file:)`; `Transcoder.start(_:input:from:in:subtitles:)`; `TranscodeSession.subtitleNames: [String]`; `TranscodeSession.delete(_ segments: [SegmentWindow.Segment])`; `BackgroundProcess(_:arguments:in:)`.

- [ ] **Step 1: Write the failing test**

```swift
import AVFoundation
import Foundation
import Testing
@testable import PaperPlaneCore

/// Subtitles in real sessions, with the real ffmpeg.
@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct SessionSubtitlesTests {
    static let profile = OutputProfile(surround: false, hdr: true)

    /// A WebVTT file on the movie's timeline, as SubtitleExtractor makes them.
    private static func movieSubtitles(_ cues: String) throws -> URL {
        let file = try TestSupport.makeTemporaryDirectory().appendingPathComponent("movie.vtt")
        try ("WEBVTT\n\n" + cues).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func start(_ file: String, from start: Double = 0, burnIn: BurnIn? = nil,
                              subtitles: SessionSubtitles) async throws -> TranscodeSession {
        let tools = try #require(TestSupport.tools)
        let input = ResolvedInput.file(TestSupport.media(file))
        let plan = try ConversionPlanner.plan(try await MediaProbe(tools: tools).probe(input),
                                              choice: TrackChoice(burnIn: burnIn), profile: profile)
        let folder = try SessionFolders(root: TestSupport.makeTemporaryDirectory()).create()
        return try await Transcoder(tools: tools).start(plan, input: input, from: start, in: folder,
                                                        subtitles: subtitles)
    }

    @Test func offersSubtitlesMovedToTheSessionsStart() async throws {
        let movie = try Self.movieSubtitles("00:01.000 --> 00:04.000\nOne\n\n00:05.000 --> 00:08.000\nTwo\n")
        let subtitles = SessionSubtitles(
            tracks: [SessionSubtitles.Track(name: "English", language: "eng", isForced: false, file: movie)],
            duration: 10)
        // Copied video with a keyframe every second: the session starts at exactly 3 s.
        let session = try await Self.start("h264_aac.mp4", from: 3, subtitles: subtitles)
        let folder = session.folder
        let master = try String(contentsOf: folder.appendingPathComponent("master.m3u8"), encoding: .utf8)

        #expect(session.subtitleNames == ["English"])
        #expect(master.contains(#"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en","#))
        #expect(master.contains(#",SUBTITLES="subs""#))
        #expect(try String(contentsOf: folder.appendingPathComponent("sub_0.vtt"), encoding: .utf8) == """
            WEBVTT

            00:00:00.000 --> 00:00:01.000
            One

            00:00:02.000 --> 00:00:05.000
            Two

            """)
        #expect(try String(contentsOf: folder.appendingPathComponent("sub_0.m3u8"), encoding: .utf8)
            .contains("#EXTINF:7.000,\nsub_0.vtt"))

        _ = await session.events.first { $0 == .finished }
        let server = try await HLSServer(directory: folder)
        let asset = AVURLAsset(url: server.url("master.m3u8"))
        let group = try await asset.loadMediaSelectionGroup(for: .legible)
        let status = await TestSupport.playerItemStatus(server.url("master.m3u8"))
        server.stop()
        await session.stop()
        #expect(group?.options.map(\.displayName) == ["English"])
        #expect(status == .readyToPlay)
    }

    @Test func aMissingSubtitleFileIsLeftOut() async throws {
        let subtitles = SessionSubtitles(tracks: [
            SessionSubtitles.Track(name: "Gone", language: nil, isForced: false,
                                   file: URL(fileURLWithPath: "/nonexistent/x.vtt")),
        ])
        let session = try await Self.start("h264_aac.mp4", subtitles: subtitles)
        let master = try String(contentsOf: session.folder.appendingPathComponent("master.m3u8"), encoding: .utf8)
        await session.stop()
        #expect(session.subtitleNames.isEmpty)
        #expect(!master.contains("SUBTITLES"))
    }

    /// The same re-encoded clip with and without burned-in text: only the bottom of the picture,
    /// where the text goes, differs.
    @Test(.enabled("Needs an ffmpeg built with libass, like the bundled one") {
        await TestSupport.ffmpegHasFilter("subtitles")
    })
    func burnsInTextSubtitles() async throws {
        let movie = try Self.movieSubtitles("00:00.000 --> 00:10.000\nPAPER PLANE PAPER PLANE\n")
        let plain = try await Self.start("vp9_opus.webm", subtitles: SessionSubtitles())
        let burned = try await Self.start("vp9_opus.webm", burnIn: .text, subtitles: SessionSubtitles(burnIn: movie))
        _ = await plain.events.first { $0 == .finished }
        _ = await burned.events.first { $0 == .finished }
        let plainFrame = try await Self.grayFrame(at: 2, in: plain.folder)
        let burnedFrame = try await Self.grayFrame(at: 2, in: burned.folder)
        await plain.stop()
        await burned.stop()

        let rows = 36, width = 64
        func difference(_ range: Range<Int>) -> Int {
            range.flatMap { row in (0..<width).map { row * width + $0 } }
                .reduce(0) { $0 + abs(Int(plainFrame[$1]) - Int(burnedFrame[$1])) }
        }
        let top = difference(0..<(rows / 3))
        let bottom = difference((rows * 2 / 3)..<rows)
        #expect(bottom > top * 5 + 500, "bottom \(bottom), top \(top)")
    }

    @Test func deletesTheSegmentsItIsTold() async throws {
        let session = try await Self.start("h264_aac.mp4", subtitles: SessionSubtitles())
        _ = await session.events.first { $0 == .finished }
        let first = SegmentWindow.Segment(index: 0, start: 0, end: 6)
        session.delete([first])
        #expect(!FileManager.default.fileExists(atPath: session.folder.appendingPathComponent("seg_00000.m4s").path))
        #expect(FileManager.default.fileExists(atPath: session.folder.appendingPathComponent("seg_00001.m4s").path))
        await session.stop()
    }

    /// A 64×36 greyscale frame `seconds` into a session's output.
    private static func grayFrame(at seconds: Double, in folder: URL) async throws -> [UInt8] {
        let tools = try #require(TestSupport.tools)
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-i", folder.appendingPathComponent("index.m3u8").path,
            "-ss", String(seconds), "-frames:v", "1", "-vf", "scale=64:36,format=gray", "-f", "rawvideo", "-",
        ])
        try #require(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        try #require(result.stdout.count == 64 * 36)
        return Array(result.stdout)
    }
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `scripts/test-core.sh --filter SessionSubtitlesTests`
Expected: FAIL — `cannot find 'SessionSubtitles' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The text subtitles one session offers, and the one it burns in, as WebVTT files on the
/// movie's timeline (from `SubtitleExtractor`). The session writes its own copies, moved to
/// its start.
public struct SessionSubtitles: Sendable {
    public struct Track: Equatable, Sendable {
        /// Unique among the tracks: the player's options are matched to tracks by it.
        public var name: String
        /// As the file gives it (`eng`, `pt-BR`); the playlist gets the RFC 5646 tag.
        public var language: String?
        public var isForced: Bool
        public var file: URL

        public init(name: String, language: String?, isForced: Bool, file: URL) {
            self.name = name
            self.language = language
            self.isForced = isForced
            self.file = file
        }
    }

    public var tracks: [Track]
    /// With `BurnIn.text`: the subtitles to draw into the picture.
    public var burnIn: URL?
    /// The movie's length, which the subtitle playlists cover. nil when unknown.
    public var duration: Double?

    public init(tracks: [Track] = [], burnIn: URL? = nil, duration: Double? = nil) {
        self.tracks = tracks
        self.burnIn = burnIn
        self.duration = duration
    }

    /// Writes `sub_<n>.vtt` and `sub_<n>.m3u8` for each track and `burn-in.vtt`, all moved
    /// `offset` seconds earlier, into `folder`. Returns the renditions for the master playlist.
    /// A track whose file can't be read is left out.
    func write(into folder: URL, offset: Double) -> [MasterPlaylist.Subtitle] {
        if let burnIn {
            Self.writeShifted(burnIn, by: offset, to: folder.appendingPathComponent(HLSFileNames.burnInSubtitles))
        }
        // A day when the length is unknown: the playlist must say something.
        let length = max((duration ?? offset + 86_400) - offset, 1)
        return tracks.enumerated().compactMap { number, track in
            let vtt = "sub_\(number).vtt"
            let playlist = "sub_\(number).m3u8"
            guard Self.writeShifted(track.file, by: offset, to: folder.appendingPathComponent(vtt)),
                  (try? MasterPlaylist.subtitlePlaylist(file: vtt, duration: length)
                      .write(to: folder.appendingPathComponent(playlist), atomically: true, encoding: .utf8)) != nil
            else { return nil }
            return MasterPlaylist.Subtitle(name: track.name, language: TrackNames.languageTag(track.language),
                                           isForced: track.isForced, uri: playlist)
        }
    }

    @discardableResult
    private static func writeShifted(_ source: URL, by offset: Double, to destination: URL) -> Bool {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return false }
        return (try? WebVTT.shifted(text, by: offset).write(to: destination, atomically: true, encoding: .utf8)) != nil
    }
}
```

```diff
--- a/core/Sources/PaperPlaneCore/Streaming/Transcoder.swift
+++ b/core/Sources/PaperPlaneCore/Streaming/Transcoder.swift
@@ -29,19 +29,22 @@
     }
 
     /// Starts converting `input` from `start` seconds into `folder` (an empty folder from
-    /// `SessionFolders`), and returns once the first segments and `master.m3u8` are ready.
+    /// `SessionFolders`), and returns once the first segments and `master.m3u8` are ready. The
+    /// session offers `subtitles`' tracks and burns in its `burnIn`, moved to the session's start.
     ///
     /// Cancelling the calling task stops ffmpeg and throws `CancellationError`. If ffmpeg fails
     /// first, this throws `TranscodeError.ffmpegFailed`. Either way the folder is deleted.
     public func start(_ plan: ConversionPlan, input: ResolvedInput, from start: Double = 0,
-                      in folder: URL) async throws -> TranscodeSession {
+                      in folder: URL, subtitles: SessionSubtitles = SessionSubtitles()) async throws -> TranscodeSession {
         let session: TranscodeSession
         do {
             let offset = try await sessionOffset(plan, input: input, start: start)
+            let renditions = subtitles.write(into: folder, offset: offset)
+            // ffmpeg runs in the session folder, so the burn-in subtitles need no escaped path.
             let process = try BackgroundProcess(
-                tools.ffmpeg, arguments: plan.ffmpegArguments(input: input, start: start, output: folder))
+                tools.ffmpeg, arguments: plan.ffmpegArguments(input: input, start: start, output: folder), in: folder)
             session = TranscodeSession(folder: folder, requestedStart: start, offset: offset, process: process,
-                                       plan: plan, segmentsBeforeReady: segmentsBeforeReady)
+                                       plan: plan, subtitles: renditions, segmentsBeforeReady: segmentsBeforeReady)
         } catch {
             try? FileManager.default.removeItem(at: folder)
             throw error
@@ -105,6 +108,8 @@
     public let offset: Double
     /// Segment progress, then `.finished` or `.failed`. One consumer at a time.
     public let events: AsyncStream<TranscodeEvent>
+    /// The names of the subtitle tracks the master playlist offers.
+    public let subtitleNames: [String]
 
     private struct State {
         /// nil until the session is ready or has failed to start.
@@ -118,17 +123,18 @@
     private let monitor: Task<Void, Never>
 
     init(folder: URL, requestedStart: Double, offset: Double, process: BackgroundProcess, plan: ConversionPlan,
-         segmentsBeforeReady: Int) {
+         subtitles: [MasterPlaylist.Subtitle] = [], segmentsBeforeReady: Int) {
         self.folder = folder
         self.requestedStart = requestedStart
         self.offset = offset
         self.process = process
+        subtitleNames = subtitles.map(\.name)
         let (events, continuation) = AsyncStream.makeStream(of: TranscodeEvent.self)
         self.events = events
         let state = state
         monitor = Task.detached {
             await Self.watch(folder: folder, process: process, state: state, continuation: continuation, plan: plan,
-                             segmentsBeforeReady: segmentsBeforeReady)
+                             subtitles: subtitles, segmentsBeforeReady: segmentsBeforeReady)
         }
     }
 
@@ -140,6 +146,13 @@
     /// Resumes a paused ffmpeg (SIGCONT).
     public func resume() {
         process.send(SIGCONT)
+    }
+
+    /// Deletes segments the player has left behind (spec §4.2).
+    public func delete(_ segments: [SegmentWindow.Segment]) {
+        for segment in segments {
+            try? FileManager.default.removeItem(at: folder.appendingPathComponent(segment.fileName))
+        }
     }
 
     /// Stops ffmpeg, waits for it to exit and deletes the session folder. Safe to call twice.
@@ -202,7 +215,7 @@
     /// second after: only the remote's "converted so far" depends on it.
     private static func watch(folder: URL, process: BackgroundProcess, state: OSAllocatedUnfairLock<State>,
                               continuation: AsyncStream<TranscodeEvent>.Continuation, plan: ConversionPlan,
-                              segmentsBeforeReady: Int) async {
+                              subtitles: [MasterPlaylist.Subtitle], segmentsBeforeReady: Int) async {
         let playlistURL = folder.appendingPathComponent(HLSFileNames.mediaPlaylist)
         var reported = 0
         var end = 0.0
@@ -228,7 +241,8 @@
                     bandwidth: MasterPlaylist.bandwidth(segmentSizes: sizes),
                     initSegment: InitSegment((try? Data(contentsOf: initSegment)) ?? Data()),
                     frameRate: plan.frameRate,
-                    videoRange: plan.videoRange)
+                    videoRange: plan.videoRange,
+                    subtitles: subtitles)
                 do {
                     try master.write(to: folder.appendingPathComponent(MasterPlaylist.fileName),
                                      atomically: true, encoding: .utf8)
```

```diff
--- a/core/Sources/PaperPlaneCore/Support/BackgroundProcess.swift
+++ b/core/Sources/PaperPlaneCore/Support/BackgroundProcess.swift
@@ -23,9 +23,11 @@
     private let process = Process()
     private let state = OSAllocatedUnfairLock(initialState: State())
 
-    init(_ executable: URL, arguments: [String]) throws {
+    /// Runs `executable` in `directory` (the current directory when nil).
+    init(_ executable: URL, arguments: [String], in directory: URL? = nil) throws {
         process.executableURL = executable
         process.arguments = arguments
+        process.currentDirectoryURL = directory
         process.standardInput = FileHandle.nullDevice
         process.standardOutput = FileHandle.nullDevice
         let stderr = Pipe()
```

- [ ] **Step 4: Run the tests, with both ffmpegs**

Run: `scripts/test-core.sh --filter "SessionSubtitlesTests|TranscoderTests"` then the same with the bundled ffmpeg (Global Constraints).
Expected: PASS. With Homebrew's ffmpeg `burnsInTextSubtitles` is skipped (no libass); with the bundled one it runs and passes.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Streaming/SessionSubtitles.swift core/Sources/PaperPlaneCore/Streaming/Transcoder.swift core/Sources/PaperPlaneCore/Support/BackgroundProcess.swift core/Tests/PaperPlaneCoreTests/SessionSubtitlesTests.swift
git commit -m "feat(core): sessions offer subtitles moved to their start, burn in text, and delete old segments"
```

### Task 8: A playback probes once and starts sessions anywhere

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Playback/StreamPipeline.swift`
- Test: `core/Tests/PaperPlaneCoreTests/StreamPipelineTests.swift`

**Interfaces:**
- Consumes: Tasks 3–7.
- Produces: `StreamPipeline.probe(_:) async throws -> PlaybackMedia`; `extractSubtitles(_:) async throws -> SubtitleFiles`; `start(_ media: PlaybackMedia, at: Double = 0, audio: TrackRef? = nil, burnIn: SubtitleOption? = nil, subtitles: SubtitleFiles? = nil) async throws -> ServedStream`; `PlaybackMedia(input:info:subtitles:)` with `title`, `subtitleNames: [String: String]`; `SubtitleFiles(folder:files:)` with `remove()`; `ServedStream.subtitleNames`; `SubtitleError.notConverted`. `start(_ input: ResolvedInput)` stays for one-shot use.

- [ ] **Step 1: Write the failing tests**

```diff
--- a/core/Tests/PaperPlaneCoreTests/StreamPipelineTests.swift
+++ b/core/Tests/PaperPlaneCoreTests/StreamPipelineTests.swift
@@ -40,6 +40,89 @@
         }
         await #expect(throws: PlanError.noVideoTrack) {
             try await pipeline(root).start(.file(TestSupport.media("audio_only.m4a")))
+        }
+        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
+    }
+
+    /// A seek outside what's converted starts a new session there (spec §4.2).
+    @Test func startsLaterInTheMovie() async throws {
+        let root = try TestSupport.makeTemporaryDirectory()
+        defer { try? FileManager.default.removeItem(at: root) }
+        let pipeline = try pipeline(root)
+        let media = try await pipeline.probe(.file(TestSupport.media("h264_aac.mp4")))
+        let stream = try await pipeline.start(media, at: 6)
+        let duration = try await AVURLAsset(url: stream.url).load(.duration).seconds
+        await stream.stop()
+        #expect(abs(stream.session.offset - 6) < 0.05)
+        #expect(abs(duration - 4) < 1)
+    }
+
+    @Test func switchesTheAudioTrack() async throws {
+        let root = try TestSupport.makeTemporaryDirectory()
+        defer { try? FileManager.default.removeItem(at: root) }
+        let pipeline = try pipeline(root)
+        let media = try await pipeline.probe(.file(TestSupport.media("h264_multiaudio.mkv")))
+        #expect(media.info.audio.map(\.displayName) == ["English (Stereo)", "Japanese (5.1)"])
+        let byDefault = try await pipeline.start(media)
+        await byDefault.stop()
+        let english = try await pipeline.start(media, audio: media.info.audio[0].ref)
+        await english.stop()
+        #expect(byDefault.plan.audio == media.info.audio[1].ref) // the file's default
+        #expect(english.plan.audio == media.info.audio[0].ref)
+    }
+
+    /// The file's own subtitles and a sidecar `.srt`, all offered at once.
+    @Test func offersEmbeddedAndSidecarSubtitles() async throws {
+        let root = try TestSupport.makeTemporaryDirectory()
+        defer { try? FileManager.default.removeItem(at: root) }
+        let movies = root.appendingPathComponent("Movies")
+        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
+        let movie = movies.appendingPathComponent("Movie: Part 1.mkv")
+        try FileManager.default.createSymbolicLink(at: movie, withDestinationURL: TestSupport.media("h264_ac3_51.mkv"))
+        try FileManager.default.copyItem(at: TestSupport.media("sample.srt"),
+                                         to: movies.appendingPathComponent("Movie: Part 1.en.srt"))
+        let pipeline = try pipeline(root.appendingPathComponent("sessions"))
+
+        let media = try await pipeline.probe(.file(movie))
+        #expect(media.subtitles.map(\.id) == ["track-0-2", "file-Movie: Part 1.en.srt"])
+        let subtitles = try await pipeline.extractSubtitles(media)
+        #expect(subtitles.files.count == 2)
+        let stream = try await pipeline.start(media, subtitles: subtitles)
+        let group = try #require(try await AVURLAsset(url: stream.url).loadMediaSelectionGroup(for: .legible))
+        // AVFoundation names options by language; the playlist's NAME is their title.
+        var titles: [String?] = []
+        for option in group.options {
+            let title = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
+            titles.append(try await title.first?.load(.stringValue))
+        }
+        await stream.stop()
+        subtitles.remove()
+
+        #expect(stream.subtitleNames == ["track-0-2": "Subtitles", "file-Movie: Part 1.en.srt": "English — Movie: Part 1.en.srt"])
+        #expect(titles == ["Subtitles", "English — Movie: Part 1.en.srt"])
+        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path).isEmpty)
+    }
+
+    /// Subtitles not converted yet (or that couldn't be) aren't offered: the player would show
+    /// an option that plays nothing.
+    @Test func offersOnlyConvertedSubtitles() async throws {
+        let root = try TestSupport.makeTemporaryDirectory()
+        defer { try? FileManager.default.removeItem(at: root) }
+        let pipeline = try pipeline(root)
+        let media = try await pipeline.probe(.file(TestSupport.media("h264_ac3_51.mkv")))
+        let stream = try await pipeline.start(media, subtitles: SubtitleFiles(folder: root, files: [:]))
+        await stream.stop()
+        #expect(media.subtitles.count == 1)
+        #expect(stream.subtitleNames.isEmpty)
+    }
+
+    @Test func burningInTextNeedsItsSubtitlesConverted() async throws {
+        let root = try TestSupport.makeTemporaryDirectory()
+        defer { try? FileManager.default.removeItem(at: root) }
+        let pipeline = try pipeline(root)
+        let media = try await pipeline.probe(.file(TestSupport.media("h264_ac3_51.mkv")))
+        await #expect(throws: SubtitleError.notConverted) {
+            try await pipeline.start(media, burnIn: media.subtitles[0], subtitles: nil)
         }
         #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
     }
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter StreamPipelineTests`
Expected: FAIL — `value of type 'StreamPipeline' has no member 'probe'`.

- [ ] **Step 3: Write the implementation**

```diff
--- a/core/Sources/PaperPlaneCore/Playback/StreamPipeline.swift
+++ b/core/Sources/PaperPlaneCore/Playback/StreamPipeline.swift
@@ -1,7 +1,8 @@
 import Foundation
 
-/// Probe → plan → transcode → serve: turns a video into a URL the TV can play
-/// (spec §4, steps 2, 4 and 5).
+/// Probe → plan → transcode → serve: turns a video into a URL the TV can play (spec §4, steps
+/// 2, 4 and 5). A playback probes once, converts its text subtitles once, and starts a new
+/// session for each seek outside what's converted and each track change (spec §4.2).
 public struct StreamPipeline: Sendable {
     public var tools: ToolPaths
     public var folders: SessionFolders
@@ -18,20 +19,113 @@
         self.host = host
     }
 
-    /// Returns once the first segments are ready and served. Cancelling the calling task stops
-    /// everything and deletes the session folder.
-    public func start(_ input: ResolvedInput) async throws -> ServedStream {
-        let media = try await MediaProbe(tools: tools).probe(input)
-        let plan = try ConversionPlanner.plan(media, profile: profile)
-        let session = try await Transcoder(tools: tools).start(plan, input: input, in: try folders.create())
+    /// What the video contains, and the subtitles beside it (looked for while ffprobe runs).
+    public func probe(_ input: ResolvedInput) async throws -> PlaybackMedia {
+        async let sidecars = Self.sidecars(beside: input)
+        let info = try await MediaProbe(tools: tools).probe(input)
+        return PlaybackMedia(input: input, info: info, subtitles: SubtitleOption.all(in: info, sidecars: await sidecars))
+    }
+
+    /// Only a local file has a folder to look in.
+    private static func sidecars(beside input: ResolvedInput) async -> [SidecarSubtitles.File] {
+        guard input.inputs.count == 1, input.inputs[0].url.isFileURL else { return [] }
+        return await SidecarSubtitles.find(for: input.inputs[0].url)
+    }
+
+    /// Converts the text subtitles to WebVTT, in a folder of their own.
+    public func extractSubtitles(_ media: PlaybackMedia) async throws -> SubtitleFiles {
+        let folder = try folders.create()
+        let files = await SubtitleExtractor(tools: tools).extract(media.subtitles, from: media.input, into: folder)
+        return SubtitleFiles(folder: folder, files: files)
+    }
+
+    /// Starts a session `start` seconds into the movie with the chosen tracks, and returns once
+    /// its first segments are ready and served. It offers every text subtitle in `subtitles`
+    /// and burns in `burnIn` (a picture track, or a text one in `subtitles`). Cancelling the
+    /// calling task stops everything and deletes the session folder.
+    public func start(_ media: PlaybackMedia, at start: Double = 0, audio: TrackRef? = nil,
+                      burnIn: SubtitleOption? = nil, subtitles: SubtitleFiles? = nil) async throws -> ServedStream {
+        let choice = TrackChoice(audio: audio, burnIn: try burnIn.map { try Self.burnIn($0, subtitles: subtitles) })
+        let plan = try ConversionPlanner.plan(media.info, choice: choice, profile: profile)
+        let names = media.subtitleNames
+        let sessionSubtitles = SessionSubtitles(
+            tracks: media.subtitles.compactMap { option in
+                guard let file = subtitles?.files[option.id], let name = names[option.id] else { return nil }
+                return SessionSubtitles.Track(name: name, language: option.language, isForced: option.isForced,
+                                              file: file)
+            },
+            burnIn: choice.burnIn == .text ? burnIn.flatMap { subtitles?.files[$0.id] } : nil,
+            duration: media.info.duration)
+        let session = try await Transcoder(tools: tools).start(plan, input: media.input, from: start,
+                                                               in: try folders.create(), subtitles: sessionSubtitles)
         do {
             try Task.checkCancellation()
             let server = try await StreamServer.start(serving: session.folder, on: host)
-            return ServedStream(title: input.title, media: media, plan: plan, session: session, server: server)
+            let offeredNames = names.filter { session.subtitleNames.contains($0.value) }
+            return ServedStream(title: media.title, media: media.info, plan: plan, session: session, server: server,
+                                subtitleNames: offeredNames)
         } catch {
             await session.stop()
             throw error
         }
+    }
+
+    /// Probes `input` and starts it from the beginning with its default tracks.
+    public func start(_ input: ResolvedInput) async throws -> ServedStream {
+        try await start(try await probe(input))
+    }
+
+    private static func burnIn(_ option: SubtitleOption, subtitles: SubtitleFiles?) throws -> BurnIn {
+        switch option.source {
+        case .embedded(let ref) where !option.isText:
+            return .picture(ref)
+        default:
+            guard subtitles?.files[option.id] != nil else { throw SubtitleError.notConverted }
+            return .text
+        }
+    }
+}
+
+public enum SubtitleError: Error, Equatable {
+    /// The text subtitles to burn in couldn't be converted.
+    case notConverted
+}
+
+/// A video to play: what it contains and the subtitles it offers.
+public struct PlaybackMedia: Sendable {
+    public var input: ResolvedInput
+    public var info: MediaInfo
+    /// The file's subtitle tracks, then sidecar `.srt` files.
+    public var subtitles: [SubtitleOption]
+
+    public init(input: ResolvedInput, info: MediaInfo, subtitles: [SubtitleOption]) {
+        self.input = input
+        self.info = info
+        self.subtitles = subtitles
+    }
+
+    public var title: String { input.title }
+
+    /// Each subtitle option's name in the master playlist, by option id: its display name,
+    /// numbered where two would be the same.
+    public var subtitleNames: [String: String] {
+        Dictionary(uniqueKeysWithValues: zip(subtitles.map(\.id), TrackNames.unique(subtitles.map(\.displayName))))
+    }
+}
+
+/// Text subtitles converted to WebVTT for one playback, by `SubtitleOption.id`.
+public struct SubtitleFiles: Sendable {
+    public var folder: URL
+    public var files: [String: URL]
+
+    public init(folder: URL, files: [String: URL]) {
+        self.folder = folder
+        self.files = files
+    }
+
+    /// Deletes the files, when the playback ends.
+    public func remove() {
+        try? FileManager.default.removeItem(at: folder)
     }
 }
 
@@ -42,13 +136,18 @@
     public let plan: ConversionPlan
     public let session: TranscodeSession
     public let server: StreamServer
+    /// The subtitle tracks this stream offers: their names in the master playlist, which the
+    /// player's options show, by `SubtitleOption.id`.
+    public let subtitleNames: [String: String]
 
-    init(title: String, media: MediaInfo, plan: ConversionPlan, session: TranscodeSession, server: StreamServer) {
+    init(title: String, media: MediaInfo, plan: ConversionPlan, session: TranscodeSession, server: StreamServer,
+         subtitleNames: [String: String] = [:]) {
         self.title = title
         self.media = media
         self.plan = plan
         self.session = session
         self.server = server
+        self.subtitleNames = subtitleNames
     }
 
     /// What the player opens: the master playlist.
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter StreamPipelineTests`
Expected: PASS, 8 pipeline tests (and the VideoFiles tests in the same file).

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Playback/StreamPipeline.swift core/Tests/PaperPlaneCoreTests/StreamPipelineTests.swift
git commit -m "feat(core): probe once, convert subtitles once, start a session anywhere with any tracks"
```

### Task 9: Keeping the Mac awake, failure logs and free space

**Files:**
- Create: `core/Sources/PaperPlaneCore/Support/SleepAssertion.swift`, `core/Sources/PaperPlaneCore/Support/FailureLog.swift`
- Test: `core/Tests/PaperPlaneCoreTests/SleepAssertionTests.swift`, `core/Tests/PaperPlaneCoreTests/FailureLogTests.swift`

**Interfaces:**
- Produces: `SleepAssertion(name:)` with `hold(_ on: Bool)`, `isHeld`; `FailureLog.save(message:error:in:date:) -> URL?`, `FailureLog.standardFolder`; `DiskSpace.available(at:) -> Int64?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import PaperPlaneCore

struct SleepAssertionTests {
    /// How many of this process's power assertions are called `name`, as the system reports them.
    static func count(named name: String) -> Int {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return 0 }
        let mine = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return mine.filter { $0[kIOPMAssertionNameKey as String] as? String == name }.count
    }

    /// Each test names its own assertion: tests run in parallel in one process.
    let name = "Paper Plane test \(UUID().uuidString)"

    @Test func holdsAndReleasesAnIdleSleepAssertion() {
        let assertion = SleepAssertion(name: name)
        assertion.hold(true)
        #expect(assertion.isHeld)
        #expect(Self.count(named: name) == 1)
        assertion.hold(true) // a second hold doesn't stack
        #expect(Self.count(named: name) == 1)

        assertion.hold(false)
        #expect(!assertion.isHeld)
        #expect(Self.count(named: name) == 0)
        assertion.hold(false) // nor does a second release
    }

    @Test func releasesWhenGone() {
        var assertion: SleepAssertion? = SleepAssertion(name: name)
        assertion?.hold(true)
        #expect(Self.count(named: name) == 1)
        assertion = nil
        #expect(Self.count(named: name) == 0)
    }
}
```

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct FailureLogTests {
    @Test func savesARedactedLog() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let error = TranscodeError.ffmpegFailed(
            status: 1, message: "\(NSHomeDirectory())/Movies/a.mkv: Invalid data\nCookie: secret=1\nhttps://x.test/v?token=abc")
        let file = try #require(FailureLog.save(message: "Paper Plane couldn't convert this video.", error: error,
                                                in: folder, date: Date(timeIntervalSince1970: 0)))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(file.lastPathComponent == "Paper Plane 1970-01-01T000000Z.log")
        #expect(text.contains("Shown: Paper Plane couldn't convert this video."))
        #expect(text.contains("ffmpeg stopped (status 1):\n~/Movies/a.mkv: Invalid data"))
        #expect(!text.contains("secret"))
        #expect(!text.contains("token=abc"))
        #expect(!text.contains(NSHomeDirectory()))
    }

    @Test func keepsTheLastTen() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for hour in 0..<12 {
            _ = FailureLog.save(message: "x", error: CancellationError(), in: folder,
                                date: Date(timeIntervalSince1970: Double(hour) * 3600))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names.count == 10)
        #expect(names.first == "Paper Plane 1970-01-01T020000Z.log")
    }

    @Test func aFolderThatCantBeMadeGivesNoLog() throws {
        let file = try TestSupport.makeTemporaryDirectory().appendingPathComponent("file")
        try Data().write(to: file)
        #expect(FailureLog.save(message: "x", error: CancellationError(), in: file.appendingPathComponent("logs")) == nil)
    }

    @Test func diskSpaceIsKnownEvenForAFolderNotMadeYet() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("not-yet-\(UUID())/sessions")
        #expect((DiskSpace.available(at: missing) ?? 0) > 0)
    }
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter "SleepAssertionTests|FailureLogTests"`
Expected: FAIL — `cannot find 'SleepAssertion' in scope`, `cannot find 'FailureLog' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import IOKit.pwr_mgt
import os

/// Keeps the Mac from idle-sleeping while a video plays on the TV (spec §6). The display may
/// still sleep, and closing a laptop's lid still sleeps it (a documented v1 limitation).
public final class SleepAssertion: Sendable {
    public static let defaultName = "Paper Plane is playing a video on your TV"
    /// What Activity Monitor and `pmset -g assertions` show.
    public let name: String
    /// The assertion's ID while held.
    private let held = OSAllocatedUnfairLock<IOPMAssertionID?>(initialState: nil)

    public init(name: String = SleepAssertion.defaultName) {
        self.name = name
    }

    deinit {
        hold(false)
    }

    /// Takes or releases the assertion. Calling it twice with the same value does nothing.
    public func hold(_ on: Bool) {
        held.withLock { held in
            if on, held == nil {
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                         IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                         name as CFString, &id)
                if result == kIOReturnSuccess {
                    held = id
                }
            } else if !on, let id = held {
                IOPMAssertionRelease(id)
                held = nil
            }
        }
    }

    public var isHeld: Bool {
        held.withLock { $0 != nil }
    }
}
```

```swift
import Foundation

/// Saves what went wrong, for bug reports (spec §6): the plain message the user saw and the
/// converter's last output, redacted.
public enum FailureLog {
    /// `~/Library/Logs/Paper Plane/`.
    public static var standardFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Paper Plane", isDirectory: true)
    }

    /// How many logs to keep; older ones are deleted.
    static let kept = 10

    /// Writes a log and returns where, or nil if it couldn't be written.
    public static func save(message: String, error: any Error, in folder: URL = standardFolder,
                            date: Date = .now) -> URL? {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).timeZone(separator: .omitted))
        let file = folder.appendingPathComponent("Paper Plane \(stamp).log")
        let text = """
            Paper Plane failure log, \(date.formatted(.iso8601))
            Shown: \(message)

            \(details(for: error))

            """
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        removeOld(in: folder)
        return file
    }

    /// The tool's own words where there are any, with secrets and the home folder taken out.
    static func details(for error: any Error) -> String {
        let text = switch error {
        case TranscodeError.ffmpegFailed(let status, let message): "ffmpeg stopped (status \(status)):\n\(message)"
        case MediaProbeError.ffprobeFailed(let status, let message): "ffprobe stopped (status \(status)):\n\(message)"
        default: String(describing: error)
        }
        return Redaction.redact(text).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func removeOld(in folder: URL) {
        let logs = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("Paper Plane ") && $0.hasSuffix(".log") }
            .sorted()
        for name in logs.dropLast(kept) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

/// Free space where the sessions live, for the converted-video window (spec §6).
public enum DiskSpace {
    /// Bytes available on the volume holding `url` (or its nearest existing parent). nil when
    /// the system can't say.
    public static func available(at url: URL) -> Int64? {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter "SleepAssertionTests|FailureLogTests"`
Expected: PASS, 6 tests. (Each sleep test names its own assertion: tests run in parallel in one process.)

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Support/SleepAssertion.swift core/Sources/PaperPlaneCore/Support/FailureLog.swift core/Tests/PaperPlaneCoreTests/SleepAssertionTests.swift core/Tests/PaperPlaneCoreTests/FailureLogTests.swift
git commit -m "feat(core): idle-sleep assertion, redacted failure logs and free disk space"
```

### Task 10: The controller seeks anywhere, switches tracks and keeps the window

**Files:**
- Create: `core/Sources/PaperPlaneUI/PlaybackController+Sessions.swift`
- Modify: `core/Sources/PaperPlaneUI/PlaybackController.swift`, `core/Sources/PaperPlaneUI/RemoteState.swift`, `app/PaperPlane/PaperPlaneApp.swift` (one line, until Task 13 replaces it)
- Test: `core/Tests/PaperPlaneUITests/PlaybackControllerTests.swift`, `core/Tests/PaperPlaneUITests/RemoteStateTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3, 8, 9.
- Produces: `PlaybackSettings(profile:alwaysBurnInSubtitles:)`; `StreamRequest(start:audio:burnIn:subtitles:)`; `PlaybackController.Environment(tools:host:folders:settings:probe:extractSubtitles:startStream:thumbnail:freeSpace:saveLog:)` and `.live(bundleURL:fallsBackToInstalledFFmpeg:settings:)`; `PlaybackController(environment:showsWelcome:welcomeSeen:showsTVHelp:tvChosen:)`; `audioTracks`, `subtitleOptions`, `audio`, `subtitle`, `loading`, `failureLog`, `showsTVHelp`; `selectAudio(_ id: String)`, `selectSubtitle(_ id: String?)`, `networkChanged()`; `RemoteState.Choice(id:name:)`, `RemoteState.audioChoices/audio/subtitleChoices/subtitle/loading/canShowLog/showsTVHelp`, `canChooseTracks`; `seekableFraction` now spans the film.

- [ ] **Step 1: Write the failing tests**

```diff
--- a/core/Tests/PaperPlaneUITests/PlaybackControllerTests.swift
+++ b/core/Tests/PaperPlaneUITests/PlaybackControllerTests.swift
@@ -1,5 +1,6 @@
 import AVFoundation
 import Foundation
+import os
 import PaperPlaneCore
 import Testing
 @testable import PaperPlaneUI
@@ -12,23 +13,27 @@
 
     static func environment(
         tools: ToolPaths? = fakeTools, host: String? = "127.0.0.1",
-        start: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream
+        saveLog: @escaping @Sendable (String, any Error) -> URL? = { _, _ in nil },
+        probe: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> PlaybackMedia
     ) -> PlaybackController.Environment {
         PlaybackController.Environment(
             tools: { tools }, host: { host },
             folders: SessionFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID())")),
-            startStream: start, thumbnail: { _, _, _ in nil })
+            probe: probe, thumbnail: { _, _, _ in nil }, saveLog: saveLog)
     }
 
     /// Waits for a condition the controller reaches asynchronously.
-    static func eventually(_ condition: @MainActor () -> Bool) async {
-        for _ in 0..<100 where !condition() {
+    static func eventually(_ condition: @MainActor () async -> Bool) async {
+        for _ in 0..<100 {
+            if await condition() {
+                return
+            }
             try? await Task.sleep(for: .milliseconds(50))
         }
     }
 
     /// Never finishes on its own: the video stays "preparing" until stopped.
-    static let preparesForever: @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream = { _, _ in
+    static let preparesForever: @Sendable (StreamPipeline, ResolvedInput) async throws -> PlaybackMedia = { _, _ in
         try await Task.sleep(for: .seconds(600))
         throw CancellationError()
     }
@@ -54,7 +59,7 @@
 
     /// Dropping a song on the remote by mistake must not stop the video on the TV.
     @Test func aFileThatIsNotAVideoLeavesPlaybackAloneWithANotice() {
-        let controller = PlaybackController(environment: Self.environment(start: Self.preparesForever),
+        let controller = PlaybackController(environment: Self.environment(probe: Self.preparesForever),
                                             showsWelcome: false, welcomeSeen: {})
         controller.play([URL(fileURLWithPath: "/Movies/a.mkv")])
         controller.play([URL(fileURLWithPath: "/Music/song.mp3")])
@@ -69,7 +74,7 @@
     }
 
     @Test func aNoticeCanBeDismissedAndGoesAwayOnItsOwn() async {
-        let controller = PlaybackController(environment: Self.environment(start: Self.preparesForever),
+        let controller = PlaybackController(environment: Self.environment(probe: Self.preparesForever),
                                             showsWelcome: false, welcomeSeen: {})
         controller.play([URL(fileURLWithPath: "/Music/song.mp3")])
         #expect(controller.phase == .idle)
@@ -85,44 +90,67 @@
         #expect(controller.notice == nil)
     }
 
-    @Test func explainsMissingFFmpegAndNoNetwork() async {
-        let noTools = PlaybackController(environment: Self.environment(tools: nil, start: Self.preparesForever),
-                                         showsWelcome: false, welcomeSeen: {})
+    @Test func explainsMissingFFmpegAndNoNetworkWithoutALog() async {
+        let logged = OSAllocatedUnfairLock(initialState: 0)
+        let saveLog: @Sendable (String, any Error) -> URL? = { _, _ in
+            logged.withLock { $0 += 1 }
+            return nil
+        }
+        let noTools = PlaybackController(
+            environment: Self.environment(tools: nil, saveLog: saveLog, probe: Self.preparesForever),
+            showsWelcome: false, welcomeSeen: {})
         noTools.play([URL(fileURLWithPath: "/Movies/a.mkv")])
         await Self.eventually { noTools.phase != .preparing }
         #expect(noTools.phase == .failed("Paper Plane's video converter is missing. Reinstall Paper Plane."))
 
-        let offline = PlaybackController(environment: Self.environment(host: nil, start: Self.preparesForever),
-                                         showsWelcome: false, welcomeSeen: {})
+        let offline = PlaybackController(
+            environment: Self.environment(host: nil, saveLog: saveLog, probe: Self.preparesForever),
+            showsWelcome: false, welcomeSeen: {})
         offline.play([URL(fileURLWithPath: "/Movies/a.mkv")])
         await Self.eventually { offline.phase != .preparing }
         #expect(offline.phase == .failed(
             "Your Mac isn't on a network, so the TV can't reach it. Connect to Wi-Fi and try again."))
-    }
-
-    @Test func unreadableFilesGetAPlainMessage() async {
+        #expect(logged.withLock { $0 } == 0) // nothing for a bug report: these explain themselves
+        #expect(!offline.remoteState.canShowLog)
+    }
+
+    @Test func unreadableFilesGetAPlainMessageAndALog() async {
+        let log = URL(fileURLWithPath: "/tmp/Paper Plane test.log")
+        let saved = OSAllocatedUnfairLock<String?>(initialState: nil)
         let controller = PlaybackController(
-            environment: Self.environment { _, _ in throw MediaProbeError.ffprobeFailed(status: 1, message: "x") },
+            environment: Self.environment(saveLog: { message, _ in
+                saved.withLock { $0 = message }
+                return log
+            }) { _, _ in throw MediaProbeError.ffprobeFailed(status: 1, message: "x") },
             showsWelcome: false, welcomeSeen: {})
         controller.play([URL(fileURLWithPath: "/Movies/a.mkv")])
         await Self.eventually { controller.phase != .preparing }
         #expect(controller.phase == .failed("Paper Plane couldn't read this file. It may be damaged or not a video."))
         #expect(controller.title == "a")
+        #expect(controller.failureLog == log)
+        #expect(controller.remoteState.canShowLog)
+        #expect(saved.withLock { $0 } == "Paper Plane couldn't read this file. It may be damaged or not a video.")
+
+        controller.stop()
+        #expect(!controller.remoteState.canShowLog)
     }
 
     /// A release build uses only the ffmpeg it ships, never whatever is on PATH; a development
     /// build without one falls back to Homebrew's.
     @Test func onlyADevelopmentBuildFallsBackToAnInstalledFFmpeg() {
         let bundleWithoutFFmpeg = FileManager.default.temporaryDirectory.appendingPathComponent("NoHelpers-\(UUID()).app")
-        let release = PlaybackController.Environment.live(bundleURL: bundleWithoutFFmpeg, fallsBackToInstalledFFmpeg: false)
+        let release = PlaybackController.Environment.live(bundleURL: bundleWithoutFFmpeg, fallsBackToInstalledFFmpeg: false,
+                                                          settings: { PlaybackSettings() })
         #expect(release.tools() == nil)
-        let development = PlaybackController.Environment.live(bundleURL: bundleWithoutFFmpeg, fallsBackToInstalledFFmpeg: true)
+        let development = PlaybackController.Environment.live(bundleURL: bundleWithoutFFmpeg,
+                                                              fallsBackToInstalledFFmpeg: true,
+                                                              settings: { PlaybackSettings() })
         #expect(development.tools() == ToolPaths.locate())
     }
 
     @Test func openingAVideoRemembersTheWelcomeWasSeen() {
         var seen = 0
-        let controller = PlaybackController(environment: Self.environment(start: Self.preparesForever),
+        let controller = PlaybackController(environment: Self.environment(probe: Self.preparesForever),
                                             showsWelcome: true, welcomeSeen: { seen += 1 })
         controller.play([URL(fileURLWithPath: "/Movies/a.mkv")])
         #expect(!controller.showsWelcome)
@@ -136,36 +164,79 @@
 @MainActor
 @Suite(.enabled(if: UITestMedia.available, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
 struct PlaybackControllerMediaTests {
-    private static func environment(
-        startStream: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream
-            = { try await $0.start($1) }
+    static func environment(
+        host: @escaping @Sendable () -> String? = { "127.0.0.1" },
+        settings: PlaybackSettings = PlaybackSettings(),
+        freeSpace: @escaping @Sendable () -> Int64? = { 100_000_000_000 },
+        startStream: @escaping @Sendable (StreamPipeline, PlaybackMedia, StreamRequest) async throws -> ServedStream
+            = { pipeline, media, request in
+                try await pipeline.start(media, at: request.start, audio: request.audio, burnIn: request.burnIn,
+                                         subtitles: request.subtitles)
+            }
     ) throws -> PlaybackController.Environment {
         let tools = try #require(ToolPaths.locate())
         return PlaybackController.Environment(
-            tools: { tools }, host: { "127.0.0.1" },
+            tools: { tools }, host: host,
             folders: SessionFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID())")),
-            startStream: startStream)
-    }
-
-    private func readyController() async throws -> PlaybackController {
-        let controller = PlaybackController(environment: try Self.environment(), showsWelcome: false, welcomeSeen: {})
+            settings: { settings }, startStream: startStream, freeSpace: freeSpace, saveLog: { _, _ in nil })
+    }
+
+    /// A controller holding `file` ready for a TV.
+    private func readyController(_ file: URL = UITestMedia.file("h264_aac.mp4"),
+                                 environment: PlaybackController.Environment? = nil) async throws -> PlaybackController {
+        let controller = PlaybackController(environment: try environment ?? Self.environment(), showsWelcome: false,
+                                            welcomeSeen: {})
         controller.player.isMuted = true
-        controller.play([UITestMedia.file("h264_aac.mp4")])
+        controller.play([file])
         await PlaybackControllerTests.eventually { controller.phase != .preparing }
         try #require(controller.phase == .waitingForTV)
         return controller
     }
 
-    @Test func holdsTheVideoUntilATVTakesOver() async throws {
+    /// A controller playing `file` "on the TV", with all of it converted.
+    private func playingController(_ file: URL = UITestMedia.file("h264_aac.mp4"),
+                                   environment: PlaybackController.Environment? = nil) async throws
+        -> PlaybackController {
+        let controller = try await readyController(file, environment: environment)
+        controller.externalPlaybackChanged(active: true)
+        await PlaybackControllerTests.eventually { controller.conversionFinished && !controller.isPaused }
+        try #require(controller.conversionFinished)
+        return controller
+    }
+
+    @Test func holdsTheVideoUntilATVTakesOverAndKeepsTheMacAwakeWhileItPlays() async throws {
         let controller = try await readyController()
         try await Task.sleep(for: .milliseconds(300))
         #expect(controller.player.rate == 0) // nothing plays on the Mac
         #expect(controller.duration.map { abs($0 - 10) < 0.5 } == true)
         #expect(controller.detail == "720p · 10 s")
+        #expect(!controller.preventsSleep)
 
         controller.externalPlaybackChanged(active: true)
         #expect(controller.phase == .onTV)
         #expect(controller.player.rate > 0)
+        await PlaybackControllerTests.eventually { controller.preventsSleep }
+        #expect(controller.preventsSleep)
+        controller.togglePause()
+        await PlaybackControllerTests.eventually { !controller.preventsSleep }
+        #expect(!controller.preventsSleep)
+        await controller.shutDown()
+    }
+
+    /// The "choose your TV" box shows until a TV has been chosen once (design audit, move 2).
+    @Test func theTVHintGoesOnceATVHasBeenChosen() async throws {
+        var chosen = 0
+        let controller = PlaybackController(environment: try Self.environment(), showsWelcome: false, welcomeSeen: {},
+                                            showsTVHelp: true, tvChosen: { chosen += 1 })
+        controller.player.isMuted = true
+        controller.play([UITestMedia.file("h264_aac.mp4")])
+        await PlaybackControllerTests.eventually { controller.phase == .waitingForTV }
+        #expect(controller.remoteState.showsTVHelp)
+        controller.externalPlaybackChanged(active: true)
+        #expect(!controller.remoteState.showsTVHelp)
+        controller.externalPlaybackChanged(active: false)
+        controller.externalPlaybackChanged(active: true)
+        #expect(chosen == 1)
         await controller.shutDown()
     }
 
@@ -207,15 +278,15 @@
     /// A stream the Mac's player refuses (here an HDR master playlist with no FRAME-RATE, which
     /// AVFoundation rejects) ends in a plain message instead of waiting for a TV forever.
     @Test func aStreamThePlayerRefusesEndsInAPlainMessage() async throws {
-        let environment = try Self.environment { pipeline, input in
-            let stream = try await pipeline.start(input)
+        let environment = try Self.environment(startStream: { pipeline, media, request in
+            let stream = try await pipeline.start(media, at: request.start)
             let master = stream.session.folder.appendingPathComponent("master.m3u8")
             let refused = try String(contentsOf: master, encoding: .utf8)
                 .replacingOccurrences(of: "FRAME-RATE=30.000,", with: "")
                 .replacingOccurrences(of: "VIDEO-RANGE=SDR", with: "VIDEO-RANGE=PQ")
             try refused.write(to: master, atomically: true, encoding: .utf8)
             return stream
-        }
+        })
         let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
         controller.player.isMuted = true
         controller.play([UITestMedia.file("h264_aac.mp4")])
@@ -240,14 +311,14 @@
     }
 
     /// Quitting straight after opening a second video over one still being prepared must clean
-    /// up after both.
+    /// up after both, including converted subtitles.
     @Test func shutDownWaitsForAReplacedStart() async throws {
         let environment = try Self.environment()
         let controller = PlaybackController(environment: environment, showsWelcome: false, welcomeSeen: {})
-        controller.play([UITestMedia.file("h264_aac.mp4")])
+        controller.play([UITestMedia.file("h264_ac3_51.mkv")])
         await PlaybackControllerTests.eventually { !Self.sessionFolders(in: environment).isEmpty }
         try #require(!Self.sessionFolders(in: environment).isEmpty)
-        controller.play([UITestMedia.file("h264_ac3_51.mkv")])
+        controller.play([UITestMedia.file("h264_aac.mp4")])
         await controller.shutDown()
         #expect(Self.sessionFolders(in: environment).isEmpty)
     }
@@ -256,31 +327,253 @@
         (try? FileManager.default.contentsOfDirectory(atPath: environment.folders.root.path)) ?? []
     }
 
-    /// Playing within the last second of what's converted, "forward 10 seconds" must not jump
-    /// back to the seek limit.
-    @Test func skippingForwardNeverGoesBack() async throws {
-        let controller = try await readyController()
-        controller.externalPlaybackChanged(active: true)
-        await PlaybackControllerTests.eventually { controller.convertedEnd.map { $0 > 9 } == true }
-        let converted = try #require(controller.convertedEnd)
-        controller.seek(toMovieTime: converted) // lands a second short of the converted end
-        await PlaybackControllerTests.eventually { controller.movieTime > converted - 0.9 }
-        let before = controller.movieTime
-        try #require(before > converted - 1)
-        controller.skip(by: 10)
-        #expect(controller.movieTime >= before)
-        await controller.shutDown()
-    }
-
-    @Test func seeksStayWithinWhatIsConverted() async throws {
-        let controller = try await readyController()
-        controller.externalPlaybackChanged(active: true)
-        await PlaybackControllerTests.eventually { controller.convertedEnd.map { $0 > 9 } == true }
-        controller.seek(toMovieTime: 500)
-        #expect(controller.movieTime <= (controller.convertedEnd ?? 0))
+    // MARK: - Milestone 2: sessions
+
+    /// Inside what's converted a seek is a plain player seek; outside it, a new session starts
+    /// there (spec §4.2).
+    @Test func seekingOutsideTheSessionStartsANewOneThere() async throws {
+        let controller = try await playingController()
+        let first = try #require(controller.stream)
+        controller.seek(toMovieTime: 4)
+        #expect(controller.stream === first)
+        #expect(controller.loading == nil)
+
+        controller.restart(at: 6, loading: "Moving to 0:06…")
+        #expect(controller.remoteState.status == "Moving to 0:06…")
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        #expect(abs((controller.stream?.session.offset ?? 0) - 6) < 0.05)
+        #expect(controller.player.rate > 0, "it carries on playing")
+
+        controller.seek(toMovieTime: 2) // before the new session's start
+        await PlaybackControllerTests.eventually { controller.loading == nil && controller.stream?.session.offset != 6 }
+        #expect(abs((controller.stream?.session.offset ?? 0) - 2) < 0.05)
+        controller.seek(toMovieTime: 500) // past the end: the last second
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        #expect(controller.movieTime <= 10)
+        await controller.shutDown()
+    }
+
+    @Test func seekingBeforeTheStartGoesToTheStart() async throws {
+        let controller = try await playingController()
+        let first = try #require(controller.stream)
         controller.seek(toMovieTime: -20)
         #expect(controller.movieTime == 0)
-        await controller.shutDown()
+        #expect(controller.stream === first) // the start is in the session: no new one
+        await controller.shutDown()
+    }
+
+    /// Quitting while a seek's new session is starting leaves no ffmpeg or folder behind.
+    @Test func quittingDuringASeekLeavesNothing() async throws {
+        let environment = try Self.environment()
+        let controller = try await playingController(environment: environment)
+        controller.restart(at: 5, loading: "Moving…")
+        await controller.shutDown()
+        #expect(Self.sessionFolders(in: environment).isEmpty)
+    }
+
+    /// Quitting straight after several quick seeks waits for every replaced session to clean up.
+    @Test func quittingDuringRapidSeeksLeavesNothing() async throws {
+        let environment = try Self.environment()
+        let controller = try await playingController(environment: environment)
+        for target in [7.0, 2, 8, 3, 6] {
+            controller.restart(at: target, loading: "Moving…")
+            try await Task.sleep(for: .milliseconds(40))
+        }
+        await controller.shutDown()
+        #expect(Self.sessionFolders(in: environment).isEmpty)
+    }
+
+    /// A replaced seek whose cleanup is slow (ffmpeg can take seconds to stop) is still waited
+    /// for when quitting, not just the latest one.
+    @Test func quittingWaitsForASlowCleanupOfAReplacedSeek() async throws {
+        let calls = OSAllocatedUnfairLock(initialState: 0)
+        let cleaning = OSAllocatedUnfairLock(initialState: 0)
+        let environment = try Self.environment(startStream: { pipeline, media, request in
+            let call = calls.withLock { $0 += 1; return $0 }
+            do {
+                return try await pipeline.start(media, at: request.start, audio: request.audio,
+                                                burnIn: request.burnIn, subtitles: request.subtitles)
+            } catch {
+                // The replaced seek (call 2) takes a second to clean up; the last one (call 3) a moment.
+                cleaning.withLock { $0 += 1 }
+                await withCheckedContinuation { continuation in
+                    DispatchQueue.global().asyncAfter(deadline: .now() + (call == 2 ? 1.0 : 0.1)) { continuation.resume() }
+                }
+                cleaning.withLock { $0 -= 1 }
+                throw error
+            }
+        })
+        let controller = try await playingController(environment: environment)
+        controller.restart(at: 7, loading: "Moving…")
+        try await Task.sleep(for: .milliseconds(20))
+        controller.restart(at: 3, loading: "Moving…")
+        try await Task.sleep(for: .milliseconds(20))
+        await controller.shutDown()
+        #expect(calls.withLock { $0 } == 3)
+        #expect(cleaning.withLock { $0 } == 0)
+    }
+
+    /// Subtitles ffmpeg can't read don't stop the video: they turn off and a notice says so.
+    @Test func subtitlesThatCantBeReadTurnOffWithANotice() async throws {
+        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pp-badsubs-\(UUID())")
+        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
+        defer { try? FileManager.default.removeItem(at: folder) }
+        let movie = folder.appendingPathComponent("Film.mp4")
+        try FileManager.default.createSymbolicLink(at: movie, withDestinationURL: UITestMedia.file("h264_aac.mp4"))
+        try Data([0xFF, 0x00, 0xFE, 0x01]).write(to: folder.appendingPathComponent("Film.en.srt"))
+        let controller = try await playingController(movie)
+        controller.selectSubtitle("file-Film.en.srt")
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        #expect(controller.subtitle == nil)
+        #expect(controller.notice == "Paper Plane couldn't read the subtitles “English — Film.en.srt”.")
+        #expect(controller.phase == .onTV)
+        #expect(controller.player.rate > 0)
+        await controller.shutDown()
+    }
+
+    /// Five quick skips past what's converted: each replaces the last, and only the last
+    /// session survives.
+    @Test func rapidSeeksLeaveOneSession() async throws {
+        let environment = try Self.environment()
+        let controller = try await playingController(environment: environment)
+        for target in [7.0, 2, 8, 3, 6] {
+            controller.restart(at: target, loading: "Moving…")
+        }
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        #expect(abs((controller.stream?.session.offset ?? 0) - 6) < 0.05)
+        try await Task.sleep(for: .milliseconds(500))
+        #expect(Self.sessionFolders(in: environment).count == 1)
+        await controller.shutDown()
+        #expect(Self.sessionFolders(in: environment).isEmpty)
+    }
+
+    @Test func switchingAudioStartsANewSessionWithIt() async throws {
+        let controller = try await playingController(UITestMedia.file("h264_multiaudio.mkv"))
+        let state = controller.remoteState
+        #expect(state.audioChoices.map(\.name) == ["English (Stereo)", "Japanese (5.1)"])
+        #expect(state.audio == state.audioChoices[1].id) // the file's default
+        controller.selectAudio(state.audioChoices[0].id)
+        #expect(controller.remoteState.status == "Switching to English (Stereo)…")
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        #expect(controller.stream?.plan.audio == controller.audioTracks[0].ref)
+        #expect(controller.remoteState.audio == state.audioChoices[0].id)
+        await controller.shutDown()
+    }
+
+    @Test func textSubtitlesSwitchOnAndOff() async throws {
+        let controller = try await playingController(UITestMedia.file("h264_ac3_51.mkv"))
+        #expect(controller.remoteState.subtitleChoices.map(\.name) == ["Subtitles"])
+        #expect(controller.subtitle == nil) // off unless forced
+        controller.selectSubtitle("track-0-2")
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        await PlaybackControllerTests.eventually { await Self.selectedSubtitleTitle(controller) == "Subtitles" }
+        #expect(await Self.selectedSubtitleTitle(controller) == "Subtitles")
+
+        controller.selectSubtitle(nil)
+        await PlaybackControllerTests.eventually { await Self.selectedSubtitleTitle(controller) == nil }
+        #expect(await Self.selectedSubtitleTitle(controller) == nil)
+        #expect(controller.subtitle == nil)
+        await controller.shutDown()
+    }
+
+    /// A sidecar marked forced is on from the start (spec §4, step 2).
+    @Test func forcedSubtitlesAreOnFromTheStart() async throws {
+        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pp-forced-\(UUID())")
+        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
+        defer { try? FileManager.default.removeItem(at: folder) }
+        let movie = folder.appendingPathComponent("Film.mp4")
+        try FileManager.default.createSymbolicLink(at: movie, withDestinationURL: UITestMedia.file("h264_aac.mp4"))
+        try FileManager.default.copyItem(at: UITestMedia.file("sample.srt"),
+                                         to: folder.appendingPathComponent("Film.en.forced.srt"))
+        let controller = try await readyController(movie)
+        #expect(controller.subtitle == "file-Film.en.forced.srt")
+        await PlaybackControllerTests.eventually { await Self.selectedSubtitleTitle(controller) != nil }
+        #expect(await Self.selectedSubtitleTitle(controller) == "English — Film.en.forced.srt (Forced)")
+        await controller.shutDown()
+    }
+
+    @Test(.enabled("Needs an ffmpeg built with libass, like the bundled one") {
+        await UITestMedia.ffmpegHasFilter("subtitles")
+    })
+    func alwaysBurnInDrawsTextSubtitlesIntoThePicture() async throws {
+        let environment = try Self.environment(settings: PlaybackSettings(alwaysBurnInSubtitles: true))
+        let controller = try await playingController(UITestMedia.file("h264_ac3_51.mkv"), environment: environment)
+        controller.selectSubtitle("track-0-2")
+        #expect(controller.remoteState.status == "Adding subtitles…")
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        #expect(controller.stream?.plan.burnIn == .text)
+        controller.selectSubtitle(nil)
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        #expect(controller.stream?.plan.burnIn == nil)
+        await controller.shutDown()
+    }
+
+    /// When the Mac's address changes, the TV can't reach the old one: serve again from the new
+    /// address at the current time (spec §6).
+    @Test func aNewNetworkAddressServesTheVideoAgain() async throws {
+        let host = OSAllocatedUnfairLock<String?>(initialState: "127.0.0.1")
+        let controller = try await playingController(environment: try Self.environment(host: { host.withLock { $0 } }))
+        let first = try #require(controller.stream)
+        controller.networkChanged() // same address: nothing to do
+        #expect(controller.loading == nil) // a new session would have started loading
+        #expect(controller.stream === first)
+        host.withLock { $0 = nil }
+        controller.networkChanged() // offline for now: carry on, and serve again once back
+        #expect(controller.loading == nil)
+        #expect(controller.stream === first)
+
+        host.withLock { $0 = "localhost" }
+        controller.networkChanged()
+        #expect(controller.remoteState.status == "Reconnecting…")
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        #expect(controller.stream?.server.baseURL.host() == "localhost")
+        await controller.shutDown()
+    }
+
+    /// The converted-video window applied to a real session (its numbers are SegmentWindow's
+    /// tests): with little disk space ffmpeg rests once 5 minutes ahead and the user is told
+    /// once; what the player has left more than 5 minutes behind is deleted, and seeking back
+    /// there starts a new session (spec §4.2, §6). A test clip converts in a blink, so the
+    /// conversion's progress is set by hand.
+    @Test func theWindowRestsFFmpegAndDeletesWhatIsBehind() async throws {
+        let controller = try await playingController(environment: try Self.environment(freeSpace: { 900_000_000 }))
+        let folder = try #require(controller.stream?.session.folder)
+        let real = controller.segments // seg_00000 and seg_00001
+        try #require(real.count == 2)
+        controller.togglePause()
+        controller.conversionFinished = false
+        controller.segments = real + (2..<61).map { SegmentWindow.Segment(index: $0, start: Double($0) * 6, end: Double($0 + 1) * 6) }
+        controller.convertedEnd = 366
+
+        controller.manageWindow()
+        #expect(controller.conversionPaused) // 366 s ahead of 0: past 5 minutes
+        #expect(controller.notice == "Your Mac is low on disk space, so Paper Plane converts only a few minutes ahead.")
+
+        controller.movieTime = 360
+        controller.manageWindow()
+        #expect(!controller.conversionPaused) // 6 s ahead: converting again
+        #expect(controller.segments.first?.index == 9) // 0–8 ended more than 300 s before 360
+        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("seg_00000.m4s").path))
+        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("seg_00001.m4s").path))
+
+        controller.dismissNotice()
+        controller.manageWindow()
+        #expect(controller.notice == nil) // said once
+
+        controller.seek(toMovieTime: 1) // deleted: a new session
+        await PlaybackControllerTests.eventually { controller.loading == nil }
+        #expect(abs((controller.stream?.session.offset ?? 0) - 1) < 0.05)
+        await controller.shutDown()
+    }
+
+    /// The title of the subtitle option the player shows, or nil.
+    private static func selectedSubtitleTitle(_ controller: PlaybackController) async -> String? {
+        guard let item = controller.player.currentItem,
+              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
+              let option = item.currentMediaSelection.selectedMediaOption(in: group)
+        else { return nil }
+        let titles = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
+        return try? await titles.first?.load(.stringValue)
     }
 }
 
@@ -296,4 +589,19 @@
     static var available: Bool {
         ToolPaths.locate() != nil && FileManager.default.fileExists(atPath: file("h264_aac.mp4").path)
     }
+
+    /// Whether the ffmpeg under test has a filter, e.g. `subtitles` (libass).
+    static func ffmpegHasFilter(_ name: String) async -> Bool {
+        guard let tools = ToolPaths.locate() else { return false }
+        let process = Process()
+        process.executableURL = tools.ffmpeg
+        process.arguments = ["-hide_banner", "-filters"]
+        let pipe = Pipe()
+        process.standardOutput = pipe
+        process.standardError = FileHandle.nullDevice
+        guard (try? process.run()) != nil else { return false }
+        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
+        process.waitUntilExit()
+        return output.split(separator: "\n").contains { $0.split(separator: " ").dropFirst().first == Substring(name) }
+    }
 }
```

```diff
--- a/core/Tests/PaperPlaneUITests/RemoteStateTests.swift
+++ b/core/Tests/PaperPlaneUITests/RemoteStateTests.swift
@@ -62,26 +62,41 @@
         #expect(Self.state(.paused).playButtonLabel == "Play")
     }
 
-    /// Until Milestone 2 restarts the conversion for a seek, the scrubber can't promise to reach
-    /// past what has been converted.
-    @Test func seekingReachesOnlyWhatIsConverted() {
-        #expect(Self.state(.playing).seekableFraction == 0.4)
-        var finished = Self.state(.playing)
-        finished.converted = 100
-        #expect(finished.seekableFraction == 1)
+    /// Past what's converted, a seek starts a new session there (spec §4.2), so the whole film
+    /// is reachable; a film of unknown length can't be scrubbed.
+    @Test func seekingReachesTheWholeFilm() {
+        #expect(Self.state(.playing).seekableFraction == 1)
         var unknown = Self.state(.playing)
-        unknown.converted = nil
-        #expect(unknown.seekableFraction == 0.1) // only up to where it is now
+        unknown.duration = nil
+        #expect(unknown.seekableFraction == 0)
     }
 
     @Test func explainsHowFarYouCanSeek() {
-        #expect(Self.state(.playing).convertedNote == "Ready up to 0:40")
+        #expect(Self.state(.playing).convertedNote == "Converted up to 0:40; a jump further on takes a moment")
         var finished = Self.state(.playing)
         finished.converted = 100
         #expect(finished.convertedNote == "")
         var unknown = Self.state(.playing)
         unknown.converted = nil
         #expect(unknown.convertedNote == "")
+    }
+
+    @Test func aNewSessionSaysWhatItIsDoing() {
+        var moving = Self.state(.playing)
+        moving.loading = "Moving to 1:02:03…"
+        #expect(moving.status == "Moving to 1:02:03…")
+        var failed = Self.state(.failed("Broken."))
+        failed.loading = "Moving to 1:02:03…"
+        #expect(failed.status == "Broken.")
+    }
+
+    @Test func tracksCanBeChosenOnceTheVideoIsLoaded() {
+        for phase in [RemoteState.Phase.choosingTV(tvWentAway: false), .playing, .paused] {
+            #expect(Self.state(phase).canChooseTracks, "\(phase)")
+        }
+        for phase in [RemoteState.Phase.idle, .preparing, .failed("x")] {
+            #expect(!Self.state(phase).canChooseTracks, "\(phase)")
+        }
     }
 
     @Test func volumeIsInertUntilTheTVPlays() {
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter PaperPlaneUITests`
Expected: FAIL to compile — `extra arguments 'showsTVHelp', 'tvChosen' in call`, `value of type 'PlaybackController' has no member 'restart'`, `value of type 'RemoteState' has no member 'loading'`.

- [ ] **Step 3: Write the implementation**

```diff
--- a/core/Sources/PaperPlaneUI/RemoteState.swift
+++ b/core/Sources/PaperPlaneUI/RemoteState.swift
@@ -16,6 +16,17 @@
         case failed(String)
     }
 
+    /// One entry in the audio or subtitle picker.
+    public struct Choice: Equatable, Sendable, Identifiable {
+        public var id: String
+        public var name: String
+
+        public init(id: String, name: String) {
+            self.id = id
+            self.name = name
+        }
+    }
+
     public var phase: Phase
     public var title: String
     /// Size, range and length, e.g. "4K · HDR10 · 1 h 52 min".
@@ -24,7 +35,7 @@
     public var elapsed: Double
     /// nil while unknown.
     public var duration: Double?
-    /// How far the conversion has got, in movie time. Seeking works up to here.
+    /// How far the conversion has got, in movie time. Seeking further starts a new session.
     public var converted: Double?
     /// 0…1.
     public var volume: Double
@@ -32,10 +43,24 @@
     public var showsWelcome: Bool
     /// A passing message over whatever is showing, e.g. "“song.mp3” isn't a video file."
     public var notice: String?
+    public var audioChoices: [Choice]
+    /// The chosen audio's id.
+    public var audio: String?
+    public var subtitleChoices: [Choice]
+    /// The chosen subtitles' id; nil when off.
+    public var subtitle: String?
+    /// While a seek or track change starts a new session: "Moving to 1:02:03…".
+    public var loading: String?
+    /// A failure's details were saved, so the remote offers Show Log.
+    public var canShowLog: Bool
+    /// Explain how to choose the TV, until it has been done once (design audit, move 2).
+    public var showsTVHelp: Bool
 
     public init(phase: Phase = .idle, title: String = "", detail: String = "", elapsed: Double = 0,
                 duration: Double? = nil, converted: Double? = nil, volume: Double = 1, showsWelcome: Bool = false,
-                notice: String? = nil) {
+                notice: String? = nil, audioChoices: [Choice] = [], audio: String? = nil,
+                subtitleChoices: [Choice] = [], subtitle: String? = nil, loading: String? = nil,
+                canShowLog: Bool = false, showsTVHelp: Bool = true) {
         self.phase = phase
         self.title = title
         self.detail = detail
@@ -45,6 +70,13 @@
         self.volume = volume
         self.showsWelcome = showsWelcome
         self.notice = notice
+        self.audioChoices = audioChoices
+        self.audio = audio
+        self.subtitleChoices = subtitleChoices
+        self.subtitle = subtitle
+        self.loading = loading
+        self.canShowLog = canShowLog
+        self.showsTVHelp = showsTVHelp
     }
 
     /// Play/pause, skip and seek only mean something once the TV is playing the video.
@@ -57,21 +89,33 @@
         canControlPlayback
     }
 
-    /// How far along the track a seek can go, from 0 to 1: up to what has been converted, or
-    /// only to where playback is when that's unknown. Milestone 2 lifts this.
+    /// How far along the track a seek can go, from 0 to 1: anywhere in a film of known length
+    /// (past what's converted, a new session starts there), nowhere in one of unknown length.
     public var seekableFraction: Double {
-        max(Self.fraction(of: converted ?? elapsed, in: duration), Self.fraction(of: elapsed, in: duration))
+        (duration ?? 0) > 0 ? 1 : 0
     }
 
-    /// "Ready up to 0:40" while the conversion is behind the end, so the lighter part of the track
-    /// explains itself. Empty once everything is converted or when unknown.
+    /// Audio and subtitles can be changed once the video is loaded.
+    public var canChooseTracks: Bool {
+        switch phase {
+        case .choosingTV, .playing, .paused: true
+        case .idle, .preparing, .failed: false
+        }
+    }
+
+    /// "Ready to play from here up to 0:40" while the conversion is behind the end, so the
+    /// lighter part of the track explains itself. Empty once everything is converted or when
+    /// unknown.
     public var convertedNote: String {
         guard let converted, let duration, converted < duration else { return "" }
-        return "Ready up to \(TimeText.clock(converted))"
+        return "Converted up to \(TimeText.clock(converted)); a jump further on takes a moment"
     }
 
     public var status: String {
-        switch phase {
+        if let loading, canChooseTracks {
+            return loading
+        }
+        return switch phase {
         case .idle: ""
         case .preparing: "Getting your video ready…"
         case .choosingTV(let tvWentAway):
```

```diff
--- a/core/Sources/PaperPlaneUI/PlaybackController.swift
+++ b/core/Sources/PaperPlaneUI/PlaybackController.swift
@@ -4,8 +4,30 @@
 import os
 import PaperPlaneCore
 
+/// Choices that apply to every playback, from Settings (spec §4.1).
+public struct PlaybackSettings: Equatable, Sendable {
+    public var profile: OutputProfile
+    /// Draw text subtitles into the picture instead of offering them as tracks, for TVs that
+    /// don't show subtitle tracks.
+    public var alwaysBurnInSubtitles: Bool
+
+    public init(profile: OutputProfile = .default, alwaysBurnInSubtitles: Bool = false) {
+        self.profile = profile
+        self.alwaysBurnInSubtitles = alwaysBurnInSubtitles
+    }
+}
+
+/// Where a session starts and what it shows.
+public struct StreamRequest: Sendable {
+    public var start: Double
+    public var audio: TrackRef?
+    public var burnIn: SubtitleOption?
+    public var subtitles: SubtitleFiles?
+}
+
 /// Plays one video at a time on the TV: probe → plan → transcode → serve → AVPlayer → AirPlay
-/// (spec §4). Seeking past what's converted, track changes and recovery come with Milestone 2.
+/// (spec §4). Seeking outside what's converted and changing tracks start a new session
+/// (spec §4.2); see PlaybackController+Sessions.swift.
 @MainActor @Observable
 public final class PlaybackController {
     /// What the controller needs from the outside world, so tests can stand in for it.
@@ -15,35 +37,59 @@
         /// The address the stream server listens on, or nil when the Mac is offline.
         public var host: @Sendable () -> String?
         public var folders: SessionFolders
-        public var profile: OutputProfile
-        /// Probe → plan → transcode → serve.
-        public var startStream: @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream
+        public var settings: @Sendable () -> PlaybackSettings
+        public var probe: @Sendable (StreamPipeline, ResolvedInput) async throws -> PlaybackMedia
+        public var extractSubtitles: @Sendable (StreamPipeline, PlaybackMedia) async throws -> SubtitleFiles
+        /// Plan → transcode → serve.
+        public var startStream: @Sendable (StreamPipeline, PlaybackMedia, StreamRequest) async throws -> ServedStream
         /// A JPEG for the artwork.
         public var thumbnail: @Sendable (ToolPaths, URL, Double?) async -> Data?
-
-        public init(tools: @escaping @Sendable () -> ToolPaths?, host: @escaping @Sendable () -> String?,
-                    folders: SessionFolders = .standard, profile: OutputProfile = .default,
-                    startStream: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> ServedStream
-                        = { try await $0.start($1) },
-                    thumbnail: @escaping @Sendable (ToolPaths, URL, Double?) async -> Data? = { tools, url, duration in
-                        await Thumbnail.jpeg(tools: tools, input: .init(url: url), at: Thumbnail.moment(duration: duration))
-                    }) {
+        /// Bytes free where the sessions are.
+        public var freeSpace: @Sendable () -> Int64?
+        /// Saves a failure's details for a bug report and says where.
+        public var saveLog: @Sendable (String, any Error) -> URL?
+
+        public init(
+            tools: @escaping @Sendable () -> ToolPaths?, host: @escaping @Sendable () -> String?,
+            folders: SessionFolders = .standard,
+            settings: @escaping @Sendable () -> PlaybackSettings = { PlaybackSettings() },
+            probe: @escaping @Sendable (StreamPipeline, ResolvedInput) async throws -> PlaybackMedia
+                = { try await $0.probe($1) },
+            extractSubtitles: @escaping @Sendable (StreamPipeline, PlaybackMedia) async throws -> SubtitleFiles
+                = { try await $0.extractSubtitles($1) },
+            startStream: @escaping @Sendable (StreamPipeline, PlaybackMedia, StreamRequest) async throws -> ServedStream
+                = { pipeline, media, request in
+                    try await pipeline.start(media, at: request.start, audio: request.audio, burnIn: request.burnIn,
+                                             subtitles: request.subtitles)
+                },
+            thumbnail: @escaping @Sendable (ToolPaths, URL, Double?) async -> Data? = { tools, url, duration in
+                await Thumbnail.jpeg(tools: tools, input: .init(url: url), at: Thumbnail.moment(duration: duration))
+            },
+            freeSpace: (@Sendable () -> Int64?)? = nil,
+            saveLog: @escaping @Sendable (String, any Error) -> URL? = { FailureLog.save(message: $0, error: $1) }
+        ) {
             self.tools = tools
             self.host = host
             self.folders = folders
-            self.profile = profile
+            self.settings = settings
+            self.probe = probe
+            self.extractSubtitles = extractSubtitles
             self.startStream = startStream
             self.thumbnail = thumbnail
+            self.freeSpace = freeSpace ?? { DiskSpace.available(at: folders.root) }
+            self.saveLog = saveLog
         }
 
         /// The app's own: the ffmpeg in its bundle and the Mac's LAN address. Only a development
         /// build (`fallsBackToInstalledFFmpeg`) may use an ffmpeg from PATH or Homebrew instead:
         /// a release must never run whatever happens to be installed under that name.
-        public static func live(bundleURL: URL, fallsBackToInstalledFFmpeg: Bool) -> Environment {
+        public static func live(bundleURL: URL, fallsBackToInstalledFFmpeg: Bool,
+                                settings: @escaping @Sendable () -> PlaybackSettings) -> Environment {
             Environment(tools: {
                             ToolPaths.inBundle(at: bundleURL) ?? (fallsBackToInstalledFFmpeg ? ToolPaths.locate() : nil)
                         },
-                        host: { LANAddress.current() })
+                        host: { LANAddress.current() },
+                        settings: settings)
         }
     }
 
@@ -62,49 +108,87 @@
     static let seeksToStartOnTV = true
 
     public let player = AVPlayer()
-    public private(set) var phase = Phase.idle
+    public private(set) var phase = Phase.idle {
+        didSet { updateSleep() }
+    }
     public private(set) var title: String?
     public private(set) var detail = ""
-    public private(set) var isPaused = true
-    public private(set) var movieTime = 0.0
+    public private(set) var isPaused = true {
+        didSet { updateSleep() }
+    }
+    public internal(set) var movieTime = 0.0
     public private(set) var duration: Double?
     /// How far the conversion has got, in movie time.
-    public private(set) var convertedEnd: Double?
+    public internal(set) var convertedEnd: Double?
     public private(set) var artwork: NSImage?
     public private(set) var tvWentAway = false
     public private(set) var showsWelcome: Bool
+    /// Whether the remote still explains how to choose the TV: until one has been chosen once.
+    public private(set) var showsTVHelp: Bool
     /// A passing message, such as "that file isn't a video". Playback carries on underneath.
     public private(set) var notice: String?
+    /// The video's audio tracks and its subtitles (tracks and sidecar files).
+    public internal(set) var audioTracks: [AudioTrack] = []
+    public internal(set) var subtitleOptions: [SubtitleOption] = []
+    /// The chosen audio track; nil until a session has started.
+    public internal(set) var audio: TrackRef?
+    /// The chosen subtitles' `SubtitleOption.id`; nil when off.
+    public internal(set) var subtitle: String?
+    /// Set while a new session starts for a seek or a track change: "Moving to 1:02:03…".
+    public internal(set) var loading: String?
+    /// The saved details of the last failure, for Show Log.
+    public private(set) var failureLog: URL?
+    public var volume = 1.0 {
+        didSet { player.volume = Float(volume) }
+    }
     /// How long a notice stays up.
     @ObservationIgnored var noticeDuration = Duration.seconds(6)
-    public var volume = 1.0 {
-        didSet { player.volume = Float(volume) }
-    }
-
-    @ObservationIgnored private let environment: Environment
+
+    @ObservationIgnored let environment: Environment
     @ObservationIgnored private let welcomeSeen: @MainActor () -> Void
+    @ObservationIgnored private let tvChosen: @MainActor () -> Void
     /// Whether the user paused, as opposed to AVPlayer pausing as the TV dropped out.
-    @ObservationIgnored private var userPaused = false
-    @ObservationIgnored private var stream: ServedStream?
+    @ObservationIgnored var userPaused = false
+    @ObservationIgnored var media: PlaybackMedia?
+    @ObservationIgnored var stream: ServedStream?
+    /// The text subtitles as WebVTT, once converted.
+    @ObservationIgnored var subtitleFiles: SubtitleFiles?
+    @ObservationIgnored var extracting: Task<SubtitleFiles?, Never>?
+    /// Counts playbacks, so work for an earlier one can tell it has been replaced.
+    @ObservationIgnored var generation = 0
     @ObservationIgnored private var starting: Task<Void, Never>?
+    /// A new session for a seek or a track change.
+    @ObservationIgnored var restarting: Task<Void, Never>?
     /// Finishes once every stream stopped and every start cancelled so far has cleaned up.
     @ObservationIgnored private var cleanup: Task<Void, Never>?
-    @ObservationIgnored private var watchingEvents: Task<Void, Never>?
+    @ObservationIgnored var watchingEvents: Task<Void, Never>?
+    /// The current session's segments still on disk, and its conversion state.
+    @ObservationIgnored var segments: [SegmentWindow.Segment] = []
+    @ObservationIgnored var conversionPaused = false
+    @ObservationIgnored var conversionFinished = false
+    @ObservationIgnored var warnedAboutSpace = false
     @ObservationIgnored private var hidingNotice: Task<Void, Never>?
     @ObservationIgnored private var observations: [NSKeyValueObservation] = []
     /// Watch the current item for the player refusing it or stalling for good.
     @ObservationIgnored private var itemStatus: NSKeyValueObservation?
     @ObservationIgnored private var itemFailure: (any NSObjectProtocol)?
     @ObservationIgnored private var timeObserver: Any?
-    @ObservationIgnored private let log = Logger(subsystem: "dev.paperplane.app", category: "playback")
+    @ObservationIgnored private let sleep = SleepAssertion()
+    @ObservationIgnored let log = Logger(subsystem: "dev.paperplane.app", category: "playback")
 
     /// `showsWelcome` is whether the one-time explainer is still due; `welcomeSeen` is called
-    /// once it has been dismissed, to remember that.
-    public init(environment: Environment, showsWelcome: Bool, welcomeSeen: @escaping @MainActor () -> Void) {
+    /// once it has been dismissed, to remember that. Likewise `showsTVHelp` and `tvChosen`, for
+    /// the hint on choosing the TV.
+    public init(environment: Environment, showsWelcome: Bool, welcomeSeen: @escaping @MainActor () -> Void,
+                showsTVHelp: Bool = true, tvChosen: @escaping @MainActor () -> Void = {}) {
         self.environment = environment
         self.showsWelcome = showsWelcome
         self.welcomeSeen = welcomeSeen
+        self.showsTVHelp = showsTVHelp
+        self.tvChosen = tvChosen
         player.allowsExternalPlayback = true
+        // Subtitles are off unless chosen, whatever the Mac's caption settings say.
+        player.appliesMediaSelectionCriteriaAutomatically = false
         observations = [
             player.observe(\.isExternalPlaybackActive) { [weak self] _, _ in
                 Task { @MainActor in self?.externalPlaybackChanged() }
@@ -129,18 +213,9 @@
         }
     }
 
-    /// What the remote window shows.
-    public var remoteState: RemoteState {
-        let remotePhase: RemoteState.Phase = switch phase {
-        case .idle: .idle
-        case .preparing: .preparing
-        case .waitingForTV: .choosingTV(tvWentAway: tvWentAway)
-        case .onTV: isPaused ? .paused : .playing
-        case .failed(let message): .failed(message)
-        }
-        return RemoteState(phase: remotePhase, title: title ?? "", detail: detail, elapsed: movieTime,
-                           duration: duration, converted: convertedEnd, volume: volume, showsWelcome: showsWelcome,
-                           notice: notice)
+    /// Whether the Mac is being kept awake (spec §6): while the TV plays.
+    var preventsSleep: Bool {
+        sleep.isHeld
     }
 
     // MARK: - Commands
@@ -174,49 +249,33 @@
         }
     }
 
-    /// Moves by `seconds` (−10 or +10), within what has been converted so far.
-    public func skip(by seconds: Double) {
-        seek(toMovieTime: movieTime + seconds)
-    }
-
-    /// Goes to `time` in the movie. Until Milestone 2 restarts the conversion for a seek, it stays
-    /// within what has been converted. The TV seeks whether or not AirPlay reports it finished
-    /// (docs/sony-test-results.md, row 7b), so there is nothing to wait for.
-    public func seek(toMovieTime time: Double) {
-        guard phase == .onTV, let stream else { return }
-        let offset = stream.session.offset
-        // A second short of what's converted, so the TV never waits on a segment ffmpeg is still
-        // writing; but never behind where it's playing, so a seek forward never goes back.
-        let latest = max(offset, movieTime, (convertedEnd ?? movieTime) - 1)
-        let target = min(max(time, offset), latest)
-        movieTime = target
-        player.seek(to: CMTime(seconds: target - offset, preferredTimescale: 600))
-    }
-
     public func stop() {
-        // A cancelled start cleans up after itself (stopping ffmpeg, deleting its folder); a
-        // stream has to be stopped. Either way shutDown() waits for it.
-        let starting = starting
-        let stream = stream
+        // A cancelled start or session change cleans up after itself (stopping ffmpeg, deleting
+        // its folder); a stream has to be stopped, and converted subtitles deleted. Either way
+        // shutDown() waits for it.
+        let (starting, restarting, stream, extracting) = (starting, restarting, stream, extracting)
         starting?.cancel()
-        if starting != nil || stream != nil {
-            let earlier = cleanup
-            cleanup = Task {
+        restarting?.cancel()
+        extracting?.cancel()
+        if starting != nil || restarting != nil || stream != nil || extracting != nil {
+            afterwards {
                 await stream?.stop()
                 await starting?.value
-                await earlier?.value
-            }
-        }
+                await restarting?.value
+                await extracting?.value?.remove()
+            }
+        }
+        generation += 1
         self.starting = nil
+        self.restarting = nil
         self.stream = nil
+        self.extracting = nil
+        media = nil
+        subtitleFiles = nil
         watchingEvents?.cancel()
         watchingEvents = nil
         player.pause()
-        itemStatus = nil
-        if let itemFailure {
-            NotificationCenter.default.removeObserver(itemFailure)
-        }
-        itemFailure = nil
+        observeItem(nil)
         player.replaceCurrentItem(with: nil)
         title = nil
         detail = ""
@@ -227,6 +286,16 @@
         convertedEnd = nil
         tvWentAway = false
         userPaused = false
+        audioTracks = []
+        subtitleOptions = []
+        audio = nil
+        subtitle = nil
+        loading = nil
+        failureLog = nil
+        segments = []
+        conversionPaused = false
+        conversionFinished = false
+        warnedAboutSpace = false
     }
 
     public func dismissWelcome() {
@@ -240,7 +309,7 @@
         notice = nil
     }
 
-    private func show(notice message: String) {
+    func show(notice message: String) {
         hidingNotice?.cancel()
         notice = message
         let duration = noticeDuration
@@ -258,32 +327,39 @@
         await cleanup?.value
     }
 
+    /// Runs `work` after the cleanup already queued; shutDown() waits for all of it.
+    func afterwards(_ work: @escaping @Sendable () async -> Void) {
+        let earlier = cleanup
+        cleanup = Task {
+            await work()
+            await earlier?.value
+        }
+    }
+
     // MARK: - Starting
 
     private func start(_ url: URL) async {
         do {
-            guard let tools = environment.tools() else { throw PlaybackError.noFFmpeg }
-            guard let host = environment.host() else { throw PlaybackError.offline }
-            let pipeline = StreamPipeline(tools: tools, folders: environment.folders, profile: environment.profile,
-                                          host: host)
-            let stream = try await environment.startStream(pipeline, .file(url))
+            let pipeline = try self.pipeline()
+            let media = try await environment.probe(pipeline, .file(url))
+            try Task.checkCancellation()
+            self.media = media
+            duration = media.info.duration
+            detail = Self.detail(for: media.info)
+            audioTracks = media.info.audio
+            subtitleOptions = media.subtitles
+            startExtractingSubtitles(media, with: pipeline)
+            // Subtitles are off unless the file marks a track as forced (spec §4, step 2).
+            subtitle = media.subtitles.first(where: \.isForced)?.id
+            let stream = try await environment.startStream(pipeline, media, await request(at: 0))
             guard !Task.isCancelled else {
                 await stream.stop()
                 return
             }
-            // What people watch is private: names, paths and URLs never go to the log in the clear.
-            log.info("Serving \(stream.title, privacy: .private) at \(stream.url.absoluteString, privacy: .private)")
-            self.stream = stream
-            duration = stream.media.duration
-            movieTime = stream.session.offset
-            detail = Self.detail(for: stream.media)
-            watchingEvents = Task { await watch(stream.session) }
-            let item = AVPlayerItem(url: stream.url)
-            watchForFailure(of: item)
-            player.replaceCurrentItem(with: item)
+            adopt(stream)
             phase = .waitingForTV
             externalPlaybackChanged()
-            if let jpeg = await environment.thumbnail(tools, url, duration), self.stream === stream {
+            if let jpeg = await environment.thumbnail(pipeline.tools, url, duration), self.stream === stream {
                 artwork = NSImage(data: jpeg)
             }
         } catch {
@@ -291,28 +367,79 @@
             // this controller's business, and acting on it would stop the newer video.
             guard !Task.isCancelled, !(error is CancellationError) else { return }
             log.error("Couldn't play \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .private)")
-            fail(PlaybackError.message(for: error))
-        }
-    }
-
-    /// Stops everything, keeping the title, and shows `message`.
-    private func fail(_ message: String) {
+            fail(PlaybackError.message(for: error), error: error)
+        }
+    }
+
+    /// A pipeline with the current tools, address and settings.
+    func pipeline() throws -> StreamPipeline {
+        guard let tools = environment.tools() else { throw PlaybackError.noFFmpeg }
+        guard let host = environment.host() else { throw PlaybackError.offline }
+        return StreamPipeline(tools: tools, folders: environment.folders, profile: environment.settings().profile,
+                              host: host)
+    }
+
+    /// Converts the text subtitles in the background; sessions started afterwards offer them.
+    private func startExtractingSubtitles(_ media: PlaybackMedia, with pipeline: StreamPipeline) {
+        guard media.subtitles.contains(where: \.isText) else { return }
+        let generation = generation
+        let environment = environment
+        extracting = Task { [weak self] in
+            let files = try? await environment.extractSubtitles(pipeline, media)
+            if let self, self.generation == generation {
+                self.subtitleFiles = files
+            }
+            return files
+        }
+    }
+
+    /// Makes `stream` the one playing: its item goes to the player and its events are watched.
+    func adopt(_ stream: ServedStream) {
+        // What people watch is private: names, paths and URLs never go to the log in the clear.
+        log.info("Serving \(stream.title, privacy: .private) at \(stream.url.absoluteString, privacy: .private)")
+        self.stream = stream
+        audio = stream.plan.audio
+        movieTime = stream.session.offset
+        convertedEnd = nil
+        segments = []
+        conversionPaused = false
+        conversionFinished = false
+        watchingEvents?.cancel()
+        watchingEvents = Task { await watch(stream.session) }
+        let item = AVPlayerItem(url: stream.url)
+        observeItem(item)
+        player.replaceCurrentItem(with: item)
+        applySubtitleSelection()
+    }
+
+    /// Stops everything, keeping the title, and shows `message`. With the error behind it, its
+    /// details are saved for Show Log.
+    func fail(_ message: String, error: (any Error)? = nil) {
         let name = title
         stop()
         title = name
         phase = .failed(message)
+        if let error, !(error is PlaybackError) {
+            failureLog = environment.saveLog(message, error)
+        }
     }
 
     private func watch(_ session: TranscodeSession) async {
         for await event in session.events {
             switch event {
-            case .segment(_, let end):
+            case .segment(let index, let end):
+                let start = segments.last?.end ?? (convertedEnd.map { $0 - session.offset } ?? 0)
+                segments.append(SegmentWindow.Segment(index: index, start: start, end: end))
                 convertedEnd = session.offset + end
+                // Check on each segment too: copying converts minutes in a second, faster than
+                // the playback clock ticks.
+                manageWindow()
             case .finished:
+                conversionFinished = true
                 convertedEnd = duration ?? convertedEnd
             case .failed(let message):
                 log.error("ffmpeg failed: \(message, privacy: .private)")
-                fail("Converting the video stopped part-way through.")
+                fail("Converting the video stopped part-way through.", error: ConversionStopped(message: message))
             }
         }
     }
@@ -337,6 +464,10 @@
         if active {
             guard phase == .waitingForTV else { return }
             phase = .onTV
+            if showsTVHelp {
+                showsTVHelp = false
+                tvChosen()
+            }
             let resumesPaused = tvWentAway && userPaused
             tvWentAway = false
             guard !resumesPaused else { return } // the user had paused it before the TV dropped out
@@ -355,8 +486,14 @@
     }
 
     /// Fails with a plain message when the player refuses `item` or can't play on, instead of
-    /// waiting for a TV forever.
-    private func watchForFailure(of item: AVPlayerItem) {
+    /// waiting for a TV forever. nil stops watching.
+    private func observeItem(_ item: AVPlayerItem?) {
+        itemStatus = nil
+        if let itemFailure {
+            NotificationCenter.default.removeObserver(itemFailure)
+        }
+        itemFailure = nil
+        guard let item else { return }
         itemStatus = item.observe(\.status) { [weak self] item, _ in
             guard item.status == .failed else { return }
             let reason = String(describing: item.error)
@@ -377,16 +514,27 @@
     }
 
     private func timeChanged(_ time: CMTime) {
-        guard let stream, phase == .onTV, time.isNumeric else { return }
+        guard let stream, phase == .onTV, loading == nil, time.isNumeric else { return }
         movieTime = stream.session.offset + time.seconds
-    }
+        manageWindow()
+    }
+
+    private func updateSleep() {
+        sleep.hold(phase == .onTV && !isPaused)
+    }
+}
+
+/// ffmpeg failed after the video started playing. `message` is its redacted stderr.
+struct ConversionStopped: Error, CustomStringConvertible {
+    var message: String
+    var description: String { "ffmpeg stopped part-way through:\n\(message)" }
 }
 
 enum PlaybackError: Error {
     case noFFmpeg
     case offline
 
-    /// A plain-language message for the remote. Full error handling is Milestone 2.
+    /// A plain-language message for the remote.
     static func message(for error: any Error) -> String {
         switch error {
         case PlaybackError.noFFmpeg: "Paper Plane's video converter is missing. Reinstall Paper Plane."
```

```swift
import AVFoundation
import Foundation
import PaperPlaneCore

/// Seeking anywhere in the movie, changing tracks, keeping the converted-video window and
/// following network changes: each either moves within the current session or starts a new one
/// (spec §4.2, §6).
extension PlaybackController {
    // MARK: - State for the UI

    /// What the remote window shows.
    public var remoteState: RemoteState {
        let remotePhase: RemoteState.Phase = switch phase {
        case .idle: .idle
        case .preparing: .preparing
        case .waitingForTV: .choosingTV(tvWentAway: tvWentAway)
        case .onTV: isPaused ? .paused : .playing
        case .failed(let message): .failed(message)
        }
        let audioNames = TrackNames.unique(audioTracks.map(\.displayName))
        let subtitleNames = TrackNames.unique(subtitleOptions.map(\.displayName))
        return RemoteState(
            phase: remotePhase, title: title ?? "", detail: detail, elapsed: movieTime, duration: duration,
            converted: convertedEnd, volume: volume, showsWelcome: showsWelcome, notice: notice,
            audioChoices: zip(audioTracks, audioNames).map { RemoteState.Choice(id: Self.id(of: $0.ref), name: $1) },
            audio: audio.map(Self.id(of:)),
            subtitleChoices: zip(subtitleOptions, subtitleNames).map { RemoteState.Choice(id: $0.id, name: $1) },
            subtitle: subtitle, loading: loading, canShowLog: failureLog != nil, showsTVHelp: showsTVHelp)
    }

    static func id(of track: TrackRef) -> String {
        "track-\(track.input)-\(track.index)"
    }

    // MARK: - Seeking

    /// Moves by `seconds` (−10 or +10).
    public func skip(by seconds: Double) {
        seek(toMovieTime: movieTime + seconds)
    }

    /// Goes to `time` in the movie. Within what the current session has on disk this is a plain
    /// seek; anywhere else a new session starts there (spec §4.2). The TV seeks whether or not
    /// AirPlay reports it finished (docs/sony-test-results.md, row 7b), so there is nothing to
    /// wait for.
    public func seek(toMovieTime time: Double) {
        guard phase == .onTV, stream != nil else { return }
        // Not past the last second: the end of a file is where conversion would find nothing.
        let target = max(0, duration.map { min(time, max($0 - 1, 0)) } ?? time)
        if let sessionTime = sessionTime(forMovieTime: target) {
            movieTime = target
            player.seek(to: CMTime(seconds: sessionTime, preferredTimescale: 600))
        } else {
            restart(at: target, loading: "Moving to \(TimeText.clock(target))…")
        }
    }

    /// Where `time` is in the current session, if it can be played without a new session: from
    /// the oldest segment still on disk to a second short of what's converted (so the TV never
    /// waits on a segment ffmpeg is still writing), or to the end once conversion has finished.
    func sessionTime(forMovieTime time: Double) -> Double? {
        guard let stream, loading == nil else { return nil }
        let offset = stream.session.offset
        let earliest = offset + (segments.first?.start ?? 0)
        let converted = convertedEnd ?? offset
        let latest = conversionFinished ? converted : converted - 1
        guard time >= earliest, time <= latest else { return nil }
        return time - offset
    }

    // MARK: - Tracks

    /// Switches the audio: a new session at the current time (spec §4.2).
    public func selectAudio(_ id: String) {
        guard stream != nil, let track = audioTracks.first(where: { Self.id(of: $0.ref) == id }),
              track.ref != audio
        else { return }
        audio = track.ref
        restart(at: movieTime, loading: "Switching to \(track.displayName)…")
    }

    /// Shows the subtitles with `SubtitleOption.id` `id`, or none. Text subtitles the session
    /// already offers switch on the spot; anything burned in, or not yet converted when the
    /// session started, takes a new session at the current time.
    public func selectSubtitle(_ id: String?) {
        guard let stream, id != subtitle else { return }
        let option = id.flatMap { id in subtitleOptions.first { $0.id == id } }
        guard id == nil || option != nil else { return }
        subtitle = option?.id
        let burnsIn = option.map { !$0.isText || environment.settings().alwaysBurnInSubtitles } ?? false
        if burnsIn || stream.plan.burnIn != nil {
            restart(at: movieTime, loading: option == nil ? "Turning subtitles off…" : "Adding subtitles…")
        } else if let option, stream.subtitleNames[option.id] == nil {
            restart(at: movieTime, loading: "Adding subtitles…")
        } else {
            applySubtitleSelection()
        }
    }

    /// What a session starting at `start` should show: the chosen audio, and the chosen
    /// subtitles, waiting for them to be converted if need be. Text subtitles that couldn't be
    /// converted are turned off, with a notice, rather than stopping the video.
    func request(at start: Double) async -> StreamRequest {
        var option = subtitle.flatMap { id in subtitleOptions.first { $0.id == id } }
        if option?.isText == true, subtitleFiles == nil, let extracting {
            subtitleFiles = await extracting.value
        }
        if let chosen = option, chosen.isText, subtitleFiles?.files[chosen.id] == nil {
            subtitle = nil
            option = nil
            show(notice: "Paper Plane couldn't read the subtitles “\(chosen.displayName)”.")
        }
        let burnIn = option.flatMap { !$0.isText || environment.settings().alwaysBurnInSubtitles ? $0 : nil }
        return StreamRequest(start: start, audio: audio, burnIn: burnIn, subtitles: subtitleFiles)
    }

    /// Selects the chosen subtitles among the current item's options, matched by their name in
    /// the master playlist (AVFoundation names options by language, so the NAME is the title).
    func applySubtitleSelection() {
        guard let stream, let item = player.currentItem else { return }
        let name = stream.plan.burnIn == nil ? subtitle.flatMap { stream.subtitleNames[$0] } : nil
        Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            var chosen: AVMediaSelectionOption?
            if let name {
                for option in group.options {
                    let titles = AVMetadataItem.metadataItems(from: option.commonMetadata,
                                                              filteredByIdentifier: .commonIdentifierTitle)
                    if let title = try? await titles.first?.load(.stringValue), title == name {
                        chosen = option
                        break
                    }
                }
            }
            guard let self, self.player.currentItem === item else { return }
            item.select(chosen, in: group) // nil turns subtitles off
        }
    }

    // MARK: - New sessions

    /// Starts a new session at movie time `time` with the current choices, replacing the playing
    /// one when it's ready. A newer seek or track change replaces this one.
    func restart(at time: Double, loading text: String) {
        guard let media else { return }
        if let earlier = restarting {
            earlier.cancel()
            afterwards { await earlier.value }
        }
        loading = text
        movieTime = time
        let generation = generation
        restarting = Task {
            do {
                let pipeline = try self.pipeline()
                let request = await self.request(at: time)
                let stream = try await environment.startStream(pipeline, media, request)
                guard !Task.isCancelled, self.generation == generation else {
                    await stream.stop()
                    return
                }
                let old = self.stream
                adopt(stream)
                afterwards { await old?.stop() }
                loading = nil
                restarting = nil
                if phase == .onTV {
                    if !userPaused {
                        player.play()
                    }
                    // In case the TV starts the new, still-growing playlist at its live edge. Don't
                    // wait: over AirPlay the completion reports false even when the TV seeks.
                    player.seek(to: .zero) { _ in }
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self.generation == generation else { return }
                log.error("Couldn't start a new session: \(String(describing: error), privacy: .private)")
                fail(PlaybackError.message(for: error), error: error)
            }
        }
    }

    /// The Mac's network changed. If its address moved, the TV can no longer reach the stream,
    /// so serve it again from the new address at the current time (spec §6).
    public func networkChanged() {
        guard let stream, loading == nil, let host = environment.host(),
              host != stream.server.baseURL.host()
        else { return }
        restart(at: movieTime, loading: "Reconnecting…")
    }

    // MARK: - The converted-video window

    /// Keeps converting ahead of the player, rests ffmpeg when it's far enough ahead, and deletes
    /// what the player has left behind (spec §4.2). With little disk space, keeps less ahead and
    /// says so once.
    func manageWindow() {
        guard let stream else { return }
        let free = environment.freeSpace() ?? .max
        let window = SegmentWindow.forFreeSpace(free)
        let actions = window.actions(playhead: movieTime - stream.session.offset, segments: segments,
                                     conversionPaused: conversionPaused, conversionFinished: conversionFinished)
        for action in actions {
            switch action {
            case .pauseConversion:
                stream.session.pause()
                conversionPaused = true
            case .resumeConversion:
                stream.session.resume()
                conversionPaused = false
            case .delete(let old):
                stream.session.delete(old)
                segments.removeFirst(old.count)
            }
        }
        if free < 1_000_000_000, !warnedAboutSpace {
            warnedAboutSpace = true
            show(notice: "Your Mac is low on disk space, so Paper Plane converts only a few minutes ahead.")
        }
    }
}
```

Until Task 13 rewrites the app, keep it building with the new `live` signature. In `app/PaperPlane/PaperPlaneApp.swift`:

```swift
        environment: .live(bundleURL: Bundle.main.bundleURL, fallsBackToInstalledFFmpeg: isDevelopmentBuild,
                           settings: { PlaybackSettings() }),
```

- [ ] **Step 4: Run the tests, with both ffmpegs**

Run: `scripts/test-core.sh --filter PaperPlaneUITests` then the same with the bundled ffmpeg.
Expected: PASS. `alwaysBurnInDrawsTextSubtitlesIntoThePicture` is skipped with Homebrew's ffmpeg and passes with the bundled one.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneUI core/Tests/PaperPlaneUITests/PlaybackControllerTests.swift core/Tests/PaperPlaneUITests/RemoteStateTests.swift app/PaperPlane/PaperPlaneApp.swift
git commit -m "feat(ui): seek anywhere, switch audio and subtitles, keep the converted window, follow network changes"
```

### Task 11: Now Playing and the media keys

**Files:**
- Create: `core/Sources/PaperPlaneUI/NowPlaying.swift`
- Test: `core/Tests/PaperPlaneUITests/NowPlayingTests.swift`

**Interfaces:**
- Consumes: `PlaybackController` (Task 10).
- Produces: `NowPlaying(controller:)` with `start()`; `NowPlaying.Command`; `handle(_:) -> Bool`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `scripts/test-core.sh --filter NowPlayingTests`
Expected: FAIL — `cannot find 'NowPlaying' in scope`.

- [ ] **Step 3: Write the implementation**

MediaPlayer calls the artwork handler and the command handlers on queues of its own, so neither closure may be isolated to the main actor (Swift traps); both are made in `nonisolated` helpers.

```swift
import AppKit
import MediaPlayer
import Observation

/// Shows what's playing in Control Center and answers the media keys and headphone buttons
/// (spec §4, step 6).
@MainActor
public final class NowPlaying {
    /// What a media key or Control Center asks for.
    public enum Command: Equatable, Sendable {
        case togglePlayPause, play, pause, stop
        case skip(Double)
        case seek(to: Double)
    }

    private let controller: PlaybackController
    private var published: Published?
    private var targets: [(MPRemoteCommand, Any)] = []

    /// What was last handed to Control Center, which works out the elapsed time itself from the
    /// rate; a new value only goes out when something else changes or playback jumps.
    struct Published: Equatable {
        var title: String
        var duration: Double?
        var elapsed: Double
        var isPlaying: Bool
        var hasArtwork: Bool
        var at: Date

        func differs(from next: Published) -> Bool {
            let expected = elapsed + (isPlaying ? next.at.timeIntervalSince(at) : 0)
            return title != next.title || duration != next.duration || isPlaying != next.isPlaying
                || hasArtwork != next.hasArtwork || abs(next.elapsed - expected) > 1.5
        }
    }

    public init(controller: PlaybackController) {
        self.controller = controller
    }

    /// Starts answering commands and following the controller.
    public func start() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        let handlers: [(MPRemoteCommand, @Sendable (MPRemoteCommandEvent) -> Command?)] = [
            (center.togglePlayPauseCommand, { _ in .togglePlayPause }),
            (center.playCommand, { _ in .play }),
            (center.pauseCommand, { _ in .pause }),
            (center.stopCommand, { _ in .stop }),
            (center.skipForwardCommand, { _ in .skip(10) }),
            (center.skipBackwardCommand, { _ in .skip(-10) }),
            (center.changePlaybackPositionCommand, { event in
                (event as? MPChangePlaybackPositionCommandEvent).map { .seek(to: $0.positionTime) }
            }),
        ]
        for (command, makeCommand) in handlers {
            let target = command.addTarget(handler: Self.handler(makeCommand) { [weak self] in
                self?.handle($0) == true
            })
            targets.append((command, target))
        }
        follow()
    }

    /// MediaPlayer doesn't promise which thread runs a command's handler, so the handler isn't
    /// isolated to the main actor: on the main thread it acts at once and says whether it did;
    /// elsewhere it hands the command over.
    private nonisolated static func handler(
        _ makeCommand: @escaping @Sendable (MPRemoteCommandEvent) -> Command?,
        perform: @escaping @MainActor @Sendable (Command) -> Bool
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let command = makeCommand(event) else { return .commandFailed }
            guard Thread.isMainThread else {
                Task { @MainActor in _ = perform(command) }
                return .success
            }
            return MainActor.assumeIsolated { perform(command) } ? .success : .noActionableNowPlayingItem
        }
    }

    /// Does what `command` asks, if a video is on the TV. Returns whether it did.
    @discardableResult
    func handle(_ command: Command) -> Bool {
        guard controller.phase == .onTV else {
            return false
        }
        switch command {
        case .togglePlayPause: controller.togglePause()
        case .play: if controller.isPaused { controller.togglePause() }
        case .pause: if !controller.isPaused { controller.togglePause() }
        case .stop: controller.stop()
        case .skip(let seconds): controller.skip(by: seconds)
        case .seek(let time): controller.seek(toMovieTime: time)
        }
        return true
    }

    /// Re-publishes whenever what Control Center shows would change.
    private func follow() {
        withObservationTracking {
            publish()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        guard controller.isActive, let title = controller.title else {
            if published != nil {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
                published = nil
            }
            return
        }
        let next = Published(title: title, duration: controller.duration, elapsed: controller.movieTime,
                             isPlaying: controller.phase == .onTV && !controller.isPaused,
                             hasArtwork: controller.artwork != nil, at: .now)
        guard published.map({ $0.differs(from: next) }) ?? true else { return }
        published = next
        center.nowPlayingInfo = Self.info(next, artwork: controller.artwork)
        center.playbackState = next.isPlaying ? .playing : .paused
    }

    static func info(_ state: Published, artwork: NSImage?) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyMediaType: MPMediaType.movie.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
        ]
        if let duration = state.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.artwork(artwork)
        }
        return info
    }

    /// MediaPlayer calls the image handler on a queue of its own, so it must not be isolated to
    /// the main actor, as a closure written inside this class would be.
    private nonisolated static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter NowPlayingTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneUI/NowPlaying.swift core/Tests/PaperPlaneUITests/NowPlayingTests.swift
git commit -m "feat(ui): Now Playing in Control Center and the media keys"
```

### Task 12: The remote's track menu, Show Log, Settings and the audit's refine moves

**Files:**
- Create: `core/Sources/PaperPlaneUI/SettingsView.swift`, `core/Sources/PaperPlaneUI/StatusMenu.swift`
- Modify: `core/Sources/PaperPlaneUI/RemoteView.swift`
- Test: `core/Tests/PaperPlaneUITests/RemoteSnapshotTests.swift`, `core/Tests/PaperPlaneUITests/SettingsStoreTests.swift`, `core/Tests/PaperPlaneUITests/StatusMenuTests.swift`

**Interfaces:**
- Consumes: `RemoteState` (Task 10), `PlaybackSettings`.
- Produces: `RemoteActions(…, selectAudio:, selectSubtitle:, showLog:)`; `TracksMenu`; `RemoteButtonStyle`; `EnvironmentValues.drawsMenusAsLabels`; `SettingsStore(defaults:)` with `allowSurround`, `convertHDRToSDR`, `alwaysBurnInSubtitles`, `SettingsStore.settings(from:)`; `SettingsView(store:)`; `StatusMenu.items(for: RemoteState) -> [StatusMenu.Item]`, `StatusMenu.Item.Command`.

The audit's moves: buttons draw their own focus ring (an AppKit-backed `.borderless` style can't be drawn by ImageRenderer, so `RemoteButtonStyle` does it in SwiftUI); the choose-TV box shows until a TV has been chosen once; the card's spacing is 16 and the welcome's 24; the track is 4 pt like the volume slider. Settings is all AppKit switches, so its render uses AppKit's offscreen `cacheDisplay` (not a screen capture).

- [ ] **Step 1: Write the failing tests**

```diff
--- a/core/Tests/PaperPlaneUITests/RemoteSnapshotTests.swift
+++ b/core/Tests/PaperPlaneUITests/RemoteSnapshotTests.swift
@@ -30,6 +30,18 @@
         failed.phase = .failed("Paper Plane couldn't read this file. It may be damaged or not a video.")
         var notice = movie
         notice.notice = "“Holiday photos.zip” isn't a video file."
+        var tracks = movie
+        tracks.audioChoices = [.init(id: "a1", name: "English (5.1)"), .init(id: "a2", name: "French (Stereo)")]
+        tracks.audio = "a1"
+        tracks.subtitleChoices = [.init(id: "s1", name: "English"), .init(id: "s2", name: "English — SDH")]
+        tracks.subtitle = "s1"
+        var moving = tracks
+        moving.loading = "Moving to 1:12:40…"
+        var failedWithLog = failed
+        failedWithLog.phase = .failed("Paper Plane couldn't convert this video. Try another file.")
+        failedWithLog.canShowLog = true
+        var choosingAgain = choosing
+        choosingAgain.showsTVHelp = false
         return [
             ("welcome", RemoteState(showsWelcome: true)),
             ("idle", RemoteState()),
@@ -41,6 +53,10 @@
             ("long-title-hdr", hdr),
             ("failed", failed),
             ("notice", notice),
+            ("tracks", tracks),
+            ("moving", moving),
+            ("failed-with-log", failedWithLog),
+            ("choosing-tv-again", choosingAgain),
         ]
     }()
 
@@ -57,6 +73,7 @@
                     Image(systemName: "airplayvideo").font(.system(size: 17)).foregroundStyle(.primary)
                 }
                 .environment(\.colorScheme, scheme)
+                .environment(\.drawsMenusAsLabels, true)
                 let renderer = ImageRenderer(content: view)
                 renderer.scale = 2
                 let image = try #require(renderer.cgImage, "\(name) didn't render")
@@ -65,6 +82,28 @@
                 let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                 try png.write(to: folder.appendingPathComponent("remote-\(name)-\(scheme == .dark ? "dark" : "light").png"))
             }
+        }
+    }
+
+    /// Settings is all AppKit-backed switches, which ImageRenderer can't draw, so AppKit draws
+    /// it offscreen instead (still no window on screen, no screen recording).
+    @Test func rendersSettingsInLightAndDark() throws {
+        let folder = ProcessInfo.processInfo.environment["PAPERPLANE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
+            ?? FileManager.default.temporaryDirectory.appendingPathComponent("paperplane-snapshots-\(UUID().uuidString)")
+        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
+        let defaults = try #require(UserDefaults(suiteName: "dev.paperplane.snapshots.\(UUID().uuidString)"))
+        let store = SettingsStore(defaults: defaults)
+        store.allowSurround = true
+        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
+            let view = NSHostingView(rootView: SettingsView(store: store))
+            view.appearance = NSAppearance(named: appearance)
+            view.frame = NSRect(origin: .zero, size: view.fittingSize)
+            view.layoutSubtreeIfNeeded()
+            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
+            view.cacheDisplay(in: view.bounds, to: bitmap)
+            #expect(bitmap.pixelsWide > 400, "\(name)")
+            let png = try #require(bitmap.representation(using: .png, properties: [:]))
+            try png.write(to: folder.appendingPathComponent("settings-\(name).png"))
         }
     }
 
```

```swift
import Foundation
import PaperPlaneCore
import Testing
@testable import PaperPlaneUI

@MainActor
struct SettingsStoreTests {
    let defaults = UserDefaults(suiteName: "dev.paperplane.tests.\(UUID().uuidString)")!

    @Test func startsWithTheProfileTheSonyNeeds() {
        let store = SettingsStore(defaults: defaults)
        #expect(!store.allowSurround)
        #expect(!store.convertHDRToSDR)
        #expect(!store.alwaysBurnInSubtitles)
        #expect(SettingsStore.settings(from: defaults) == PlaybackSettings(profile: .default, alwaysBurnInSubtitles: false))
    }

    @Test func changesAreKeptAndBecomeThePlaybackSettings() {
        let store = SettingsStore(defaults: defaults)
        store.allowSurround = true
        store.convertHDRToSDR = true
        store.alwaysBurnInSubtitles = true
        #expect(SettingsStore.settings(from: defaults) == PlaybackSettings(
            profile: OutputProfile(surround: true, hdr: false), alwaysBurnInSubtitles: true))

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.allowSurround && reopened.convertHDRToSDR && reopened.alwaysBurnInSubtitles)
    }
}
```

```swift
import Testing
@testable import PaperPlaneUI

struct StatusMenuTests {
    static let always = ["Open Video…", "Show Remote", "-", "Settings…", "-", "Quit Paper Plane"]

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
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter "RemoteSnapshotTests|SettingsStoreTests|StatusMenuTests"`
Expected: FAIL — `cannot find 'SettingsStore' in scope`, `cannot find 'StatusMenu' in scope`, `drawsMenusAsLabels` unknown.

- [ ] **Step 3: Write the implementation**

```diff
--- a/core/Sources/PaperPlaneUI/RemoteView.swift
+++ b/core/Sources/PaperPlaneUI/RemoteView.swift
@@ -14,6 +14,12 @@
     public var setVolume: @MainActor @Sendable (Double) -> Void
     public var dismissWelcome: @MainActor @Sendable () -> Void
     public var dismissNotice: @MainActor @Sendable () -> Void
+    /// An audio track's `RemoteState.Choice.id`.
+    public var selectAudio: @MainActor @Sendable (String) -> Void
+    /// A subtitle's `RemoteState.Choice.id`, or nil for off.
+    public var selectSubtitle: @MainActor @Sendable (String?) -> Void
+    /// Reveals the saved log of the last failure.
+    public var showLog: @MainActor @Sendable () -> Void
 
     public init(openVideo: @escaping @MainActor @Sendable () -> Void = {},
                 drop: @escaping @MainActor @Sendable ([URL]) -> Bool = { _ in false },
@@ -23,7 +29,10 @@
                 stop: @escaping @MainActor @Sendable () -> Void = {},
                 setVolume: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
                 dismissWelcome: @escaping @MainActor @Sendable () -> Void = {},
-                dismissNotice: @escaping @MainActor @Sendable () -> Void = {}) {
+                dismissNotice: @escaping @MainActor @Sendable () -> Void = {},
+                selectAudio: @escaping @MainActor @Sendable (String) -> Void = { _ in },
+                selectSubtitle: @escaping @MainActor @Sendable (String?) -> Void = { _ in },
+                showLog: @escaping @MainActor @Sendable () -> Void = {}) {
         self.openVideo = openVideo
         self.drop = drop
         self.togglePlay = togglePlay
@@ -33,6 +42,9 @@
         self.setVolume = setVolume
         self.dismissWelcome = dismissWelcome
         self.dismissNotice = dismissNotice
+        self.selectAudio = selectAudio
+        self.selectSubtitle = selectSubtitle
+        self.showLog = showLog
     }
 }
 
@@ -132,7 +144,7 @@
     var done: () -> Void
 
     var body: some View {
-        VStack(alignment: .leading, spacing: 22) {
+        VStack(alignment: .leading, spacing: 24) {
             VStack(alignment: .leading, spacing: 6) {
                 Text("Welcome to Paper Plane")
                     .font(.title2.weight(.semibold))
@@ -221,13 +233,13 @@
     var routePicker: RoutePicker
 
     var body: some View {
-        VStack(alignment: .leading, spacing: 18) {
+        VStack(alignment: .leading, spacing: 16) {
             header
             switch state.phase {
             case .failed:
                 failure
             default:
-                if case .choosingTV = state.phase {
+                if case .choosingTV = state.phase, state.showsTVHelp {
                     chooseTVCallout
                 }
                 Scrubber(state: state, seek: actions.seek, skip: actions.skip)
@@ -270,19 +282,39 @@
         .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
     }
 
+    /// Stop on the left, the AirPlay button (and the audio and subtitle menu) on the right, and
+    /// play with its skips centred between them whatever their widths. Borderless buttons, so
+    /// Full Keyboard Access draws focus rings.
     private var transport: some View {
         HStack {
             Button(action: actions.stop) {
                 Image(systemName: "stop.circle").font(.system(size: 20, weight: .regular))
                     .frame(width: 32, height: 32)
             }
-            .buttonStyle(.plain)
+            .buttonStyle(RemoteButtonStyle())
             .foregroundStyle(.primary)
             .keyboardShortcut(".", modifiers: .command)
             .accessibilityLabel("Stop")
             .help("Stop")
 
             Spacer()
+
+            HStack(spacing: 4) {
+                if state.canChooseTracks, state.audioChoices.count > 1 || !state.subtitleChoices.isEmpty {
+                    TracksMenu(state: state, selectAudio: actions.selectAudio, selectSubtitle: actions.selectSubtitle)
+                }
+                routePicker
+                    .frame(width: 32, height: 32)
+                    .background {
+                        if case .choosingTV = state.phase {
+                            Circle().fill(.tint.opacity(0.18))
+                            Circle().strokeBorder(.tint, lineWidth: 1.5)
+                        }
+                    }
+                    .help("Choose your TV")
+            }
+        }
+        .overlay {
             HStack(spacing: 20) {
                 TransportButton(symbol: "gobackward.10", label: "Back 10 seconds", enabled: state.canControlPlayback) {
                     actions.skip(-10)
@@ -296,17 +328,6 @@
                 }
                 .keyboardShortcut(.rightArrow, modifiers: [])
             }
-            Spacer()
-
-            routePicker
-                .frame(width: 32, height: 32)
-                .background {
-                    if case .choosingTV = state.phase {
-                        Circle().fill(.tint.opacity(0.18))
-                        Circle().strokeBorder(.tint, lineWidth: 1.5)
-                    }
-                }
-                .help("Choose your TV")
         }
     }
 
@@ -338,6 +359,12 @@
                     .fixedSize(horizontal: false, vertical: true)
             }
             HStack {
+                if state.canShowLog {
+                    Button("Show Log", action: actions.showLog)
+                        .buttonStyle(RemoteButtonStyle())
+                        .foregroundStyle(.tint)
+                        .help("Show the details in Finder, for a bug report")
+                }
                 Spacer()
                 Button("Dismiss", action: actions.stop)
                     .controlSize(.large)
@@ -357,6 +384,8 @@
 
     var body: some View {
         switch state.phase {
+        case _ where state.loading != nil && state.canChooseTracks:
+            label("hourglass", color: .secondary)
         case .preparing:
             label("hourglass", color: .secondary)
         case .choosingTV:
@@ -420,7 +449,7 @@
                 .frame(width: 56, height: 56)
                 .background(Circle().fill(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
         }
-        .buttonStyle(.plain)
+        .buttonStyle(RemoteButtonStyle(circle: true))
         .disabled(!enabled)
         .accessibilityLabel(label)
         .help(label)
@@ -439,12 +468,102 @@
                 .font(.system(size: 20, weight: .medium))
                 .frame(width: 40, height: 40)
         }
-        .buttonStyle(.plain)
+        .buttonStyle(RemoteButtonStyle(circle: true))
         .foregroundStyle(enabled ? .primary : .tertiary)
         .disabled(!enabled)
         .accessibilityLabel(label)
         .help(label)
     }
+}
+
+/// Audio and subtitles in one menu, as the TV app has them. Picking audio, or subtitles that
+/// are drawn into the picture, takes a moment while a new session starts.
+struct TracksMenu: View {
+    var state: RemoteState
+    var selectAudio: @MainActor @Sendable (String) -> Void
+    var selectSubtitle: @MainActor @Sendable (String?) -> Void
+
+    @Environment(\.drawsMenusAsLabels) private var drawsMenusAsLabels
+
+    var body: some View {
+        if drawsMenusAsLabels {
+            label
+        } else {
+            menu
+        }
+    }
+
+    private var label: some View {
+        Image(systemName: state.subtitle == nil ? "captions.bubble" : "captions.bubble.fill")
+            .font(.system(size: 18, weight: .regular))
+            .frame(width: 32, height: 32)
+    }
+
+    private var menu: some View {
+        Menu {
+            if state.audioChoices.count > 1 {
+                Picker("Audio", selection: Binding(get: { state.audio ?? "" }, set: selectAudio)) {
+                    ForEach(state.audioChoices) { Text($0.name).tag($0.id) }
+                }
+                .pickerStyle(.inline)
+            }
+            if !state.subtitleChoices.isEmpty {
+                Picker("Subtitles", selection: Binding(get: { state.subtitle ?? "" },
+                                                       set: { selectSubtitle($0.isEmpty ? nil : $0) })) {
+                    Text("Off").tag("")
+                    ForEach(state.subtitleChoices) { Text($0.name).tag($0.id) }
+                }
+                .pickerStyle(.inline)
+            }
+        } label: {
+            label
+        }
+        .menuStyle(.borderlessButton)
+        .menuIndicator(.hidden)
+        .fixedSize()
+        .accessibilityLabel("Audio and Subtitles")
+        .help("Audio and Subtitles")
+    }
+}
+
+/// The remote's own buttons: no bezel, dimmed while pressed, and a focus ring of their own so
+/// Full Keyboard Access shows where it is (design audit, move 1). Drawn entirely by SwiftUI, so
+/// the snapshots show them as they are.
+struct RemoteButtonStyle: ButtonStyle {
+    var circle = false
+
+    func makeBody(configuration: Configuration) -> some View {
+        Styled(configuration: configuration, circle: circle)
+    }
+
+    private struct Styled: View {
+        let configuration: Configuration
+        let circle: Bool
+        @Environment(\.isFocused) private var isFocused
+        @Environment(\.isEnabled) private var isEnabled
+
+        var body: some View {
+            configuration.label
+                .contentShape(Rectangle())
+                .opacity(configuration.isPressed ? 0.6 : 1)
+                .overlay {
+                    if isFocused && isEnabled {
+                        if circle {
+                            Circle().strokeBorder(.tint.opacity(0.7), lineWidth: 3).padding(-4)
+                        } else {
+                            RoundedRectangle(cornerRadius: 6, style: .continuous)
+                                .strokeBorder(.tint.opacity(0.7), lineWidth: 3).padding(-4)
+                        }
+                    }
+                }
+        }
+    }
+}
+
+extension EnvironmentValues {
+    /// Menus draw only their label: ImageRenderer can't draw AppKit's pop-up buttons, so the
+    /// snapshots set this.
+    @Entry var drawsMenusAsLabels = false
 }
 
 // MARK: - Scrubber
@@ -471,7 +590,7 @@
                     Capsule().fill(state.canControlPlayback ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                         .frame(width: max(6, width * played))
                 }
-                .frame(height: dragFraction == nil ? 6 : 8)
+                .frame(height: dragFraction == nil ? 4 : 6)
                 .frame(maxHeight: .infinity)
                 .contentShape(Rectangle())
                 .gesture(
```

```swift
import Foundation
import Observation
import PaperPlaneCore
import SwiftUI

/// The overrides for TVs that differ from the Sony Paper Plane was tested on (spec §4.1),
/// kept in UserDefaults.
@MainActor @Observable
public final class SettingsStore {
    enum Key {
        static let allowSurround = "allowSurround"
        static let convertHDRToSDR = "convertHDRToSDR"
        static let alwaysBurnInSubtitles = "alwaysBurnInSubtitles"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var allowSurround: Bool {
        didSet { defaults.set(allowSurround, forKey: Key.allowSurround) }
    }
    public var convertHDRToSDR: Bool {
        didSet { defaults.set(convertHDRToSDR, forKey: Key.convertHDRToSDR) }
    }
    public var alwaysBurnInSubtitles: Bool {
        didSet { defaults.set(alwaysBurnInSubtitles, forKey: Key.alwaysBurnInSubtitles) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = Self.settings(from: defaults)
        allowSurround = settings.profile.surround
        convertHDRToSDR = !settings.profile.hdr
        alwaysBurnInSubtitles = settings.alwaysBurnInSubtitles
    }

    /// The settings as playback uses them. Reads UserDefaults directly, so any thread may ask.
    public nonisolated static func settings(from defaults: UserDefaults) -> PlaybackSettings {
        PlaybackSettings(
            profile: OutputProfile(
                surround: defaults.object(forKey: Key.allowSurround) as? Bool ?? OutputProfile.default.surround,
                hdr: !(defaults.object(forKey: Key.convertHDRToSDR) as? Bool ?? !OutputProfile.default.hdr)),
            alwaysBurnInSubtitles: defaults.bool(forKey: Key.alwaysBurnInSubtitles))
    }
}

/// Settings: three switches, each saying what it's for. They apply from the next video or
/// track change.
public struct SettingsView: View {
    @Bindable var store: SettingsStore

    public init(store: SettingsStore) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section {
                setting("Allow surround sound", isOn: $store.allowSurround,
                        "Sends Dolby Digital 5.1 when the video has it. Many TVs play only stereo over AirPlay.")
                setting("Convert HDR to SDR", isOn: $store.convertHDRToSDR,
                        "For TVs that show HDR video too dark or washed out. Your Mac does more work.")
                setting("Always burn in subtitles", isOn: $store.alwaysBurnInSubtitles,
                        "Draws subtitles into the picture, for TVs that don't show subtitle tracks. Your Mac does more work.")
            } footer: {
                Text("Changes apply from the next video, seek or track change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setting(_ title: String, isOn: Binding<Bool>, _ detail: String) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(detail)
        }
    }
}
```

```swift
import Foundation

/// The menu bar icon's menu, as plain values the app turns into an NSMenu: what's playing and
/// its tracks first, then opening things, then Settings and Quit.
public enum StatusMenu {
    public struct Item: Equatable, Sendable {
        public enum Command: Equatable, Sendable {
            case togglePlay, stop, openVideo, showRemote, settings, quit
            case selectAudio(String)
            /// nil turns subtitles off.
            case selectSubtitle(String?)
        }

        public var title: String
        /// nil for a heading or a separator.
        public var command: Command?
        /// The key used with ⌘, if any.
        public var key: String
        public var isEnabled: Bool
        public var isChecked: Bool
        public var submenu: [Item]?

        public init(_ title: String, _ command: Command? = nil, key: String = "", isEnabled: Bool = true,
                    isChecked: Bool = false, submenu: [Item]? = nil) {
            self.title = title
            self.command = command
            self.key = key
            self.isEnabled = isEnabled
            self.isChecked = isChecked
            self.submenu = submenu
        }

        public static let separator = Item("-")
        public var isSeparator: Bool { title == "-" && command == nil }
    }

    public static func items(for state: RemoteState) -> [Item] {
        var items: [Item] = []
        if state.phase != .idle, !state.title.isEmpty {
            items.append(Item(state.title, isEnabled: false))
            if case .failed = state.phase {
                items.append(Item("Dismiss", .stop))
            } else {
                items.append(Item(state.playButtonLabel, .togglePlay, isEnabled: state.canControlPlayback))
                items.append(Item("Stop", .stop, key: "."))
            }
            if state.canChooseTracks, state.audioChoices.count > 1 {
                items.append(Item("Audio", submenu: state.audioChoices.map {
                    Item($0.name, .selectAudio($0.id), isChecked: $0.id == state.audio)
                }))
            }
            if state.canChooseTracks, !state.subtitleChoices.isEmpty {
                items.append(Item("Subtitles", submenu: [Item("Off", .selectSubtitle(nil), isChecked: state.subtitle == nil)]
                    + state.subtitleChoices.map {
                        Item($0.name, .selectSubtitle($0.id), isChecked: $0.id == state.subtitle)
                    }))
            }
            items.append(.separator)
        }
        items += [
            Item("Open Video…", .openVideo, key: "o"),
            Item("Show Remote", .showRemote, key: "1"),
            .separator,
            Item("Settings…", .settings, key: ","),
            .separator,
            Item("Quit Paper Plane", .quit, key: "q"),
        ]
        return items
    }
}
```

- [ ] **Step 4: Run the tests and render**

Run: `scripts/test-core.sh --filter "RemoteSnapshotTests|SettingsStoreTests|StatusMenuTests"`, then `scripts/render-ui.sh`.
Expected: PASS, 8 tests; `docs/design/` gains `remote-tracks-*`, `remote-moving-*`, `remote-failed-with-log-*`, `remote-choosing-tv-again-*` and `settings-*` PNGs, and the existing ones change only where the spacing did. Look at every new PNG.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneUI core/Tests/PaperPlaneUITests docs/design
git commit -m "feat(ui): audio and subtitle menu, Show Log, Settings, and the design audit's refine moves"
```

### Task 13: The app — a status item that takes drops, Settings and Now Playing

**Files:**
- Create: `app/PaperPlane/StatusItem.swift`, `app/PaperPlane/SettingsWindow.swift`
- Modify: `app/PaperPlane/PaperPlaneApp.swift` (rewritten), `app/PaperPlane/RemoteWindow.swift`, `app/PaperPlane-Info.plist`, `scripts/check-quit-cleanup.sh`
- Delete: `app/PaperPlane/MenuContent.swift`

**Interfaces:**
- Consumes: everything in PaperPlaneUI.
- Produces: the app on AppKit's lifecycle (`@main` `AppDelegate`), `StatusItem(controller:perform:open:)`, `SettingsWindow(store:)`, a main menu for ⌘O, ⌘1, ⌘, , ⌘W, ⌘Q and editing, `NWPathMonitor` → `networkChanged()`, `NowPlaying.start()`, the `didChooseTV` default.

There is no unit test for AppKit wiring; the checks are the warnings-as-errors build and the quit-cleanup script. Drops on the icon need a person (the morning checklist, row M12).

- [ ] **Step 1: Replace the app delegate**

```swift
import AppKit
import Network
import PaperPlaneCore
import PaperPlaneUI
import UniformTypeIdentifiers

/// A menu bar app (`LSUIElement`) on AppKit's own lifecycle: a status item that takes drops, the
/// remote and Settings windows, and a main menu for their keyboard shortcuts.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private enum Key {
        static let welcomeShown = "didShowWelcome"
        static let tvChosen = "didChooseTV"
    }

    #if DEBUG
    private static let isDevelopmentBuild = true
    #else
    private static let isDevelopmentBuild = false
    #endif

    private let settings = SettingsStore()
    let controller = PlaybackController(
        environment: .live(bundleURL: Bundle.main.bundleURL, fallsBackToInstalledFFmpeg: isDevelopmentBuild,
                           settings: { SettingsStore.settings(from: .standard) }),
        showsWelcome: !UserDefaults.standard.bool(forKey: Key.welcomeShown),
        welcomeSeen: { UserDefaults.standard.set(true, forKey: Key.welcomeShown) },
        showsTVHelp: !UserDefaults.standard.bool(forKey: Key.tvChosen),
        tvChosen: { UserDefaults.standard.set(true, forKey: Key.tvChosen) })
    private lazy var remote = RemoteWindow(
        controller: controller,
        openVideo: { [weak self] in self?.chooseVideo() },
        open: { [weak self] urls in self?.open(urls) })
    private lazy var settingsWindow = SettingsWindow(store: settings)
    private var statusItem: StatusItem?
    private var nowPlaying: NowPlaying?
    private let network = NWPathMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Whatever a crash left behind (spec §4.2).
        try? SessionFolders.standard.removeAll()
        NSApp.mainMenu = mainMenu()
        statusItem = StatusItem(controller: controller,
                                perform: { [weak self] in self?.perform($0) },
                                open: { [weak self] in self?.open($0) })
        let nowPlaying = NowPlaying(controller: controller)
        nowPlaying.start()
        self.nowPlaying = nowPlaying
        // A new Wi-Fi network or address means the TV can't reach the old one (spec §6).
        network.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.controller.networkChanged() }
        }
        network.start(queue: .main)
        remote.show()
    }

    /// Finder's Open With, and files dropped on the app's icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ffmpeg must not outlive the app.
        network.cancel()
        Task {
            await controller.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Plays the first video among `urls`. The remote opens each time, because the TV has to be
    /// picked again for every playback (docs/sony-test-results.md, row 9).
    func open(_ urls: [URL]) {
        remote.show()
        controller.play(urls)
    }

    private func perform(_ command: StatusMenu.Item.Command) {
        switch command {
        case .togglePlay: controller.togglePause()
        case .stop: controller.stop()
        case .openVideo: chooseVideo()
        case .showRemote: remote.show()
        case .settings: settingsWindow.show()
        case .quit: NSApp.terminate(nil)
        case .selectAudio(let id): controller.selectAudio(id)
        case .selectSubtitle(let id): controller.selectSubtitle(id)
        }
    }

    func chooseVideo() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.message = "Choose a video to play on your TV"
        panel.prompt = "Open"
        panel.allowedContentTypes = VideoFiles.contentTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            open([url])
        }
    }

    // MARK: - Main menu

    /// Never shown (the app lives in the menu bar), but it's where ⌘O, ⌘, , ⌘W and ⌘Q come from
    /// while one of the app's windows is in front, and editing shortcuts for text fields.
    private func mainMenu() -> NSMenu {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu?.addItem($0) }
            return item
        }
        func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
        let main = NSMenu()
        main.addItem(menu("Paper Plane", [
            item("About Paper Plane", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(showSettings), ",", target: self),
            .separator(),
            item("Quit Paper Plane", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("File", [
            item("Open Video…", #selector(openVideo), "o", target: self),
            item("Show Remote", #selector(showRemote), "1", target: self),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(menu("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        return main
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func openVideo() {
        chooseVideo()
    }

    @objc private func showRemote() {
        remote.show()
    }
}
```

- [ ] **Step 2: Add the status item and the Settings window; remove MenuContent.swift**

```swift
import AppKit
import Observation
import PaperPlaneUI

/// The menu bar icon (spec §1): its menu, built fresh each time it opens, and videos dropped on
/// it (spec §4, step 1). The icon fills in while something is open.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: PlaybackController
    private let perform: @MainActor (StatusMenu.Item.Command) -> Void
    private let open: @MainActor ([URL]) -> Void

    init(controller: PlaybackController, perform: @escaping @MainActor (StatusMenu.Item.Command) -> Void,
         open: @escaping @MainActor ([URL]) -> Void) {
        self.controller = controller
        self.perform = perform
        self.open = open
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        // The status bar window passes drags on to its delegate.
        item.button?.window?.registerForDraggedTypes([.fileURL])
        item.button?.window?.delegate = self
        followIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in StatusMenu.items(for: controller.remoteState) {
            menu.addItem(menuItem(for: entry))
        }
    }

    private func menuItem(for entry: StatusMenu.Item) -> NSMenuItem {
        if entry.isSeparator {
            return .separator()
        }
        let built = NSMenuItem(title: entry.title, action: nil, keyEquivalent: entry.key)
        built.isEnabled = entry.isEnabled
        built.state = entry.isChecked ? .on : .off
        if let command = entry.command {
            built.action = #selector(choose(_:))
            built.target = self
            built.representedObject = command
        }
        if let submenu = entry.submenu {
            let menu = NSMenu(title: entry.title)
            menu.autoenablesItems = false
            submenu.forEach { menu.addItem(menuItem(for: $0)) }
            built.submenu = menu
        }
        return built
    }

    @objc private func choose(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? StatusMenu.Item.Command {
            perform(command)
        }
    }

    // MARK: - Drops on the icon

    @objc func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(in: sender).isEmpty ? [] : .copy
    }

    @objc func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(in: sender)
        guard !urls.isEmpty else { return false }
        open(urls)
        return true
    }

    private static func fileURLs(in info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: - Icon

    private func followIcon() {
        withObservationTracking {
            item.button?.image = NSImage(systemSymbolName: controller.isActive ? "paperplane.fill" : "paperplane",
                                         accessibilityDescription: "Paper Plane")
        } onChange: { [weak self] in
            Task { @MainActor in self?.followIcon() }
        }
    }
}
```

```swift
import AppKit
import PaperPlaneUI
import SwiftUI

/// Settings (spec §4.1 overrides), in a small window of its own.
@MainActor
final class SettingsWindow {
    private let window: NSWindow

    init(store: SettingsStore) {
        window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
        window.title = "Paper Plane Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
```

```bash
git rm app/PaperPlane/MenuContent.swift
```

- [ ] **Step 3: Wire the remote's new actions**

```diff
--- a/app/PaperPlane/RemoteWindow.swift
+++ b/app/PaperPlane/RemoteWindow.swift
@@ -51,7 +51,14 @@
                 stop: { controller.stop() },
                 setVolume: { controller.volume = $0 },
                 dismissWelcome: { controller.dismissWelcome() },
-                dismissNotice: { controller.dismissNotice() })
+                dismissNotice: { controller.dismissNotice() },
+                selectAudio: { controller.selectAudio($0) },
+                selectSubtitle: { controller.selectSubtitle($0) },
+                showLog: {
+                    if let log = controller.failureLog {
+                        NSWorkspace.shared.activateFileViewerSelecting([log])
+                    }
+                })
         ) {
             RoutePicker(player: controller.player)
         }
```

- [ ] **Step 4: Say why the privacy prompt asks, and keep the quit check away from it**

```diff
--- a/app/PaperPlane-Info.plist
+++ b/app/PaperPlane-Info.plist
@@ -30,6 +30,16 @@
 	<string>GPL-3.0</string>
 	<key>NSLocalNetworkUsageDescription</key>
 	<string>Paper Plane streams video from this Mac to your TV over your local network.</string>
+	<key>NSDesktopFolderUsageDescription</key>
+	<string>Paper Plane looks for subtitle files (.srt) next to the videos you play.</string>
+	<key>NSDocumentsFolderUsageDescription</key>
+	<string>Paper Plane looks for subtitle files (.srt) next to the videos you play.</string>
+	<key>NSDownloadsFolderUsageDescription</key>
+	<string>Paper Plane looks for subtitle files (.srt) next to the videos you play.</string>
+	<key>NSNetworkVolumesUsageDescription</key>
+	<string>Paper Plane looks for subtitle files (.srt) next to the videos you play.</string>
+	<key>NSRemovableVolumesUsageDescription</key>
+	<string>Paper Plane looks for subtitle files (.srt) next to the videos you play.</string>
 	<key>NSAppTransportSecurity</key>
 	<dict>
 		<key>NSAllowsLocalNetworking</key>
```

```diff
--- a/scripts/check-quit-cleanup.sh
+++ b/scripts/check-quit-cleanup.sh
@@ -47,7 +47,10 @@
   state="$(find "$SESSIONS" -name master.m3u8 2>/dev/null | grep -q . && echo ready || echo preparing)"
   quit_and_check "quit after ${delay}s (${state})"
 done
-SECOND="$PWD/testdata/media/h264_ac3_51.mkv"
+# A copy in the temporary folder: from Documents, Desktop or Downloads, looking for subtitles
+# beside it would raise the macOS privacy prompt, which an unattended run can't answer.
+SECOND="${TMPDIR%/}/paperplane-quit-check-second.mkv"
+cp "$PWD/testdata/media/h264_ac3_51.mkv" "$SECOND" 2>/dev/null
 if [[ -f "$SECOND" ]]; then
   # Opening a second video while the first is still being prepared must leave only the second.
   launch
@@ -55,10 +58,11 @@
   sleep 0.4
   open -a "$APP" "$SECOND"
   sleep 4
-  folders="$(find "$SESSIONS" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
-  converting="$(pgrep -f 'ffmpeg .*paperplane-quit-check' | wc -l | tr -d ' ')"
-  echo "open twice quickly: session folders ${folders}, ffmpeg still on the first video ${converting}"
-  [[ "$folders" == 1 && "$converting" == 0 ]] || leftovers=1
+  # Sessions have a master playlist; the second video's converted subtitles have a folder too.
+  sessions="$(find "$SESSIONS" -name master.m3u8 2>/dev/null | wc -l | tr -d ' ')"
+  converting="$(pgrep -f 'ffmpeg .*paperplane-quit-check.mkv' | wc -l | tr -d ' ')"
+  echo "open twice quickly: sessions ${sessions}, ffmpeg still on the first video ${converting}"
+  [[ "$sessions" == 1 && "$converting" == 0 ]] || leftovers=1
   quit_app
 
   # Quitting straight after the second open must clean up after both.
```

- [ ] **Step 5: Build with warnings as errors, then check quitting**

Run: `xcodebuild -project app/PaperPlane.xcodeproj -scheme PaperPlane -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build` then `scripts/check-quit-cleanup.sh`.
Expected: `** BUILD SUCCEEDED **`; "Clean: nothing outlived the app".

- [ ] **Step 6: Commit**

```bash
git add app/PaperPlane app/PaperPlane-Info.plist scripts/check-quit-cleanup.sh
git commit -m "feat(app): menu bar icon that takes drops, Settings, Now Playing and network changes"
```

### Task 14: The Sony checklist for Milestone 2, and the README

**Files:**
- Modify: `docs/sony-test-results.md`, `README.md`

- [ ] **Step 1: Add the Milestone 2 rows**

````diff
--- a/docs/sony-test-results.md
+++ b/docs/sony-test-results.md
@@ -94,3 +94,35 @@
 | P10 | In Finder, Open With → Paper Plane on the five-minute MKV | The remote comes forward; then as P2 and P3 | Needs the owner at the TV |
 | P11 | During playback, turn the TV off, or end AirPlay from Control Center | The remote says "Your TV disconnected. Choose it again to continue". The Mac stays silent. Picking the TV again resumes where it was | Needs the owner at the TV |
 | P12 | Quit from the menu during playback | `pgrep -fl ffmpeg` prints nothing; `ls ~/Library/Caches/Paper\ Plane/sessions/` is empty | Checked on the Mac (no TV needed): clean |
+
+## Plan 3: seeking, tracks and subtitles on the Sony
+
+For these, a 30-minute film with two audio tracks (English 440 Hz, French 660 Hz), an English subtitle track, and a sidecar `.srt` with a line every 30 seconds:
+
+```bash
+ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=1800" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1800" -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=1800" -i testdata/media/sample.srt -map 0:v -map 1:a -map 2:a -map 3:s -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 48 -c:a aac -b:a 128k -ac 2 -c:s srt -metadata:s:a:0 language=eng -metadata:s:a:1 language=fra -metadata:s:s:0 language=eng ~/Desktop/paperplane-thirty-minutes.mkv
+```
+
+```bash
+python3 -c 'for i in range(60): s = i * 30; print(f"{i + 1}\n00:{s // 60:02}:{s % 60:02},000 --> 00:{s // 60:02}:{s % 60 + 20:02},000\nLine {i + 1}, at {s // 60}:{s % 60:02}\n")' > ~/Desktop/paperplane-thirty-minutes.en.srt
+```
+
+Everything up to the TV was checked on the Mac on 2026-10-16 (the controller's tests play each case through the real pipeline on this Mac). These rows need the owner at the TV.
+
+| # | Check | Expected | Result |
+|---|---|---|---|
+| M1 | Play the 30-minute film on the Sony; drag the scrubber to about 20:00 | The status says "Moving to 20:00…", and within about 3 s the TV plays from there | Needs the owner at the TV |
+| M2 | Then drag back to 0:30 | "Moving to 0:30…", and the TV plays from there | Needs the owner at the TV |
+| M3 | Skip back and forward 10 s a few times | Instant jumps, no "Moving to" | Needs the owner at the TV |
+| M4 | Captions menu (speech bubble beside AirPlay) → Audio → French | "Switching to French (Stereo)…"; the tone goes higher, at the same place in the film | Needs the owner at the TV |
+| M5 | Captions menu → Subtitles → English, then Off | "Paper Plane test subtitle one/two" show at 0:01–0:08 (seek back to 0:00 to see them); Off removes them without "Moving to" | Needs the owner at the TV |
+| M6 | With the sidecar `.srt` beside the film, play it again; choose "English — paperplane-thirty-minutes.en.srt" | "Line N, at m:ss" shows on the TV at the matching time, also after a far seek | Needs the owner at the TV |
+| M7 | Settings… → Always burn in subtitles; choose English subtitles | "Adding subtitles…"; the text is part of the picture (the TV's own subtitle setting can't hide it). Turn the setting off afterwards | Needs the owner at the TV |
+| M8 | A film of your own with Blu-ray (PGS) subtitles: choose them | "Adding subtitles…"; the subtitles are burned in. (No PGS test file can be generated, so this is the only check) | Needs the owner at the TV |
+| M9 | Media keys and Control Center | The play/pause key pauses the TV; Control Center shows the title and artwork and its scrubber seeks | Needs the owner at the TV |
+| M10 | Leave the Mac idle past its sleep time while the TV plays; then pause and wait again | Keeps playing (`pmset -g assertions` lists "Paper Plane is playing a video on your TV"); once paused the Mac may sleep | Needs the owner at the TV |
+| M11 | During playback turn Wi-Fi off and on (or switch networks, with the TV on the same one) | "Reconnecting…", then the TV plays on from where it was | Needs the owner at the TV |
+| M12 | Drag the film onto the paper plane in the menu bar | The remote opens and prepares it | Needs the owner at the Mac |
+| M13 | The menu bar menu during playback | The film's name, Pause, Stop, Audio and Subtitles submenus that switch tracks; Settings… opens Settings | Needs the owner at the Mac |
+| M14 | Drop `testdata/media/corrupt.mkv` | "Paper Plane couldn't read this file…" with Show Log; Show Log reveals a log in `~/Library/Logs/Paper Plane/` without your home folder's path in it | Needs the owner at the Mac |
+| M15 | After the first time the Sony was chosen, play another film | "Choose your TV to start" and the ringed AirPlay button, without the blue explanation box | Needs the owner at the TV |
````

- [ ] **Step 2: Say how to use it**

````diff
--- a/README.md
+++ b/README.md
@@ -6,7 +6,15 @@
 
 ## How it works
 
-Paper Plane converts on the fly whatever your TV can't play, copying everything it can, using ffmpeg. It serves the stream from your Mac and hands it to the TV with macOS's own AirPlay. The full design is in [docs/superpowers/specs/2026-10-15-paper-plane-design.md](docs/superpowers/specs/2026-10-15-paper-plane-design.md).
+Paper Plane converts on the fly whatever your TV can't play, copying everything it can, using ffmpeg. It serves the stream from your Mac and hands it to the TV with macOS's own AirPlay. The full design is in [docs/superpowers/specs/2026-10-15-paper-plane-design.md](docs/superpowers/specs/2026-10-15-paper-plane-design.md), with later decisions in [docs/superpowers/specs/](docs/superpowers/specs/).
+
+## Using it
+
+- Drop a video on the paper plane in the menu bar or on the remote window, or use Open With → Paper Plane in Finder. Then pick your TV with the AirPlay button.
+- Seek anywhere. Past what's converted so far, Paper Plane starts converting from there, which takes a few seconds.
+- The speech-bubble button switches the audio track and the subtitles, including `Movie.srt` and `Movie.en.srt` files beside the video.
+- Settings (in the menu bar menu) has three switches for TVs that differ from the one Paper Plane was tested with: surround sound, HDR to SDR, and burning in subtitles.
+- If something goes wrong, Show Log reveals a log in `~/Library/Logs/Paper Plane/` for a bug report. It leaves out cookies, passwords and your home folder's path.
 
 ## Development
 
@@ -15,7 +23,7 @@
 ```bash
 brew install ffmpeg            # development and tests only
 scripts/make-test-media.sh     # generates test clips into testdata/media/
-scripts/test-core.sh           # runs the PaperPlaneCore tests
+scripts/test-core.sh           # runs the core and UI tests
 
 brew install meson ninja autoconf automake libtool pkgconf
 scripts/build-ffmpeg.sh        # builds the ffmpeg the app ships into vendor/ffmpeg/ (a few minutes)
@@ -25,7 +33,11 @@
 scripts/check-quit-cleanup.sh  # checks quitting never leaves ffmpeg or session files behind
 ```
 
-Debug builds made before `scripts/build-ffmpeg.sh` use Homebrew's ffmpeg. Release builds need the bundled one.
+Debug builds made before `scripts/build-ffmpeg.sh` use Homebrew's ffmpeg. Release builds need the bundled one. The subtitle burn-in tests run only with the bundled ffmpeg, since Homebrew's has no libass:
+
+```bash
+PAPERPLANE_FFMPEG="$PWD/vendor/ffmpeg/bin/ffmpeg" PAPERPLANE_FFPROBE="$PWD/vendor/ffmpeg/bin/ffprobe" scripts/test-core.sh
+```
 
 ## License
 
````

- [ ] **Step 3: Commit**

```bash
git add docs/sony-test-results.md README.md
git commit -m "docs: Milestone 2 checklist for the Sony, and how to use seeking, tracks and Settings"
```
