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
