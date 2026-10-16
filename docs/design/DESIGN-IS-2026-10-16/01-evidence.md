# Evidence

Gathered by four evidence agents (structural; visual; copy and honesty; weight, friction and accessibility) from the source at `3ab9a62` and the renders in `docs/design/`. Line numbers are from that commit. Each finding marked **Fixed** was changed during this audit, test-first where it has behaviour, and the renders were redrawn. The scorecard scores what ships after those fixes.

## Structural

- **Interactive elements.**
  - Now Playing card: 8 (Stop, tracks menu, AirPlay, back 10, play, forward 10, scrubber, volume).
  - Welcome: 1. Drop zone: 1. Failure: 2–3 (Show Log when there is a log, Dismiss, Choose Another Video…). Settings: 3. Menu bar menu: up to 8.
- **Depth.** Deepest view nesting is 11 (`RemoteView` → `NowPlayingCard` → transport overlay → `PlayButton` → style).
- **Repeated affordances: 9 groups.**
  - The same action appears in both the card and the menu bar menu (play/pause, Stop, Audio, Subtitles), with Open Video… in the drop zone, the menu and ⌘O. This is the menu bar idiom.
  - Within the window, the only duplicate was "Dismiss" naming two different things (the notice's ✕ and the failure's button).
- **Dead code.**
  - An unused `import Foundation` in `StatusMenu.swift` (**Fixed**).
  - `StatusLine` had two identical arms for loading and preparing (**Fixed**: one arm).

## Visual

- **Spacing in source (pt):** 2, 3, 4, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 40.
  - The card keeps an 8-point rhythm (16/24) with a 4-point track (the 2026-10-15 audit's move 3).
- **Type:** system text styles only (title2, title3, headline, body, callout, caption), plus fixed symbol sizes 17–38.
- **Colours:** the accent (`.tint`) and the system hierarchy (primary to quaternary). Orange is reserved for failures. One custom gradient, for the placeholder artwork.
- **Lowest contrast, primary text:** 8.7:1 (notice text, dark). Everything below 4.5:1 is listed under Accessibility.
- **States:**
  - Empty, loading, error, success, disabled and paused are drawn.
  - Focus and the drop-target highlight are in source but are not in the renders (ImageRenderer can't show focus).
  - Loading is a static hourglass with words ("Getting your video ready…", "Moving to 1:02:03…").
- **Inconsistencies found:**
  1. Left edges: welcome 28 pt, card 20 pt, drop zone 16 pt. **Fixed**: 20 pt everywhere.
  2. Welcome step icons sat 3 pt right of the heading. **Fixed**: leading-aligned.
  3. Corner radii 6, 10, 12, 14, 16. **Fixed**: 16 for the window and drop zone, 12 for panels and artwork, 6 for focus rings.
  4. Accent washes 0.08, 0.10, 0.18. **Fixed**: 0.08 for washes, 0.18 for the AirPlay highlight.
  5. Status text started 6.5 pt further left beside the hourglass than beside the TV icon. **Fixed**: icons get a fixed width.
  6. The notice had 8 pt above and 20 pt below. **Fixed**: 20 pt, the card's margin.
  7. A grey stub at 0:00 on an unplayed scrubber. **Fixed**: no fill until something has played.
  8. Show Log was a tinted link beside bordered buttons. **Fixed**: a bordered button like its neighbours.
  9. Left as is: the header's text block is centred on the artwork, so it sits higher or lower with one, two or three lines (intended).
  10. Left as is: Stop stays full-strength while preparing (it works then; the others don't).
  11. Left as is: two blues in the renders. The prominent buttons are drawn by AppKit's accent, the rest by SwiftUI's `.tint` (INFERRED to be a render difference; both are the user's accent colour in the app).
  12. Left as is: the system Dismiss bezel is faint on the orange failure wash in light mode.

## Copy and honesty

- **Inflations:**
  - "Send any video on your Mac to your AirPlay TV" (welcome, `RemoteView.swift:151`). Left as is: the owner's tagline decision (the 2026-10-15 audit's move 5).
  - "Paper Plane converts whatever your TV can't play" (`:156`). It converts against a fixed AirPlay profile and never asks the TV. **Fixed**: "Paper Plane converts them for AirPlay as they play."
- **Dark patterns:** none.
- **Label and behaviour mismatches:**
  1. "Paper Plane never plays on this Mac" (`:276`). Play is guarded on the TV route, but after the TV drops, the pause is a main-actor hop later; this is unverified on hardware. **Fixed**: "The video starts once the TV is connected", which the code guarantees.
  2. The scrubber drew deleted segments (more than 5 minutes behind) as ready. **Fixed**: the ready band starts at the oldest segment on disk, as seeking measures it (test: `theWindowRestsFFmpegAndDeletesWhatIsBehind`).
  3. The Settings footer said changes apply from the next "seek or track change". Seeks inside the converted part don't apply them. **Fixed**: "Changes apply from the next video you play."
  4. "Sends Dolby Digital 5.1": other surround codecs become Dolby Digital Plus, and AAC surround is copied. **Fixed**: "Sends 5.1 surround sound when the video has it."
  5. "Something went wrong (…). Try again." showed raw error text and named no button. **Fixed**: "Something went wrong. Try again, or choose another video." The details go to the log (test: `somethingUnexpectedSaysWhatToDoWithoutTheErrorText`).
  6. "Connect to Wi-Fi": Ethernet counts too. **Fixed**: "Connect to your network".
  7. Show Log never appeared for player failures. **Fixed**: the player's reason is saved (test: `aStreamThePlayerRefusesEndsInAPlainMessage`).
  8. "Audio and Subtitles" named a menu that might hold only one of them. **Fixed**: named for what it offers (test: `theTracksButtonIsNamedForWhatItOffers`).
  9. The AirPlay button was labelled "Choose TV" but its tooltip said "Choose your TV". **Fixed**: "Choose your TV".
  10. The low-disk notice showed below 1 GB, but the smaller window starts below 2 GB. **Fixed**: the notice comes with the smaller window (test: `theLowSpaceNoticeComesWithTheSmallerWindow`).
  11. "Switching to…" named audio tracks differently from the menus when two tracks share a name. **Fixed**: the menu's name.
- **Jargon:**
  - "burn in". **Fixed**: "Always draw subtitles into the picture".
  - "SDR". **Fixed**: explained in the switch's detail.
  - "Show Remote", where the window is titled Paper Plane. **Fixed**: "Show Paper Plane Window".
  - "Converted up to". **Fixed**: "Ready up to".
  - Left as is: "Forced" in subtitle names, the standard term in Apple's players.

## Weight and friction

- **Release app:** 51 MB, of which ffmpeg and ffprobe are 48 MB (the product's engine). Main executable 1.9 MB.
- **Launch work:** cleans leftover session folders, builds the menus, and registers 7 media-key handlers and a network monitor. Then it shows the window (a drop target, so it is the first thing a user needs).
- **Animation:** one 0.2 s fade on the notice; nothing idle. **Fixed**: off under Reduce Motion.
- **Timers:**
  - A 0.5 s player time observer that does work only while the TV plays.
  - ffmpeg polling only while a conversion runs.
  - Free space cached for 10 s. Nothing periodic while idle.
- **First launch:** the welcome, then possibly the Local Network prompt, a folder-access prompt for subtitle files beside a video, and the TV's AirPlay code.

## Accessibility

- **Contrast below 4.5:1:**
  - System `.secondary` text in light mode (3.95:1) and the system's white-on-accent prominent buttons (3.2–3.5:1). Both are platform colours, and both adapt under Increase Contrast.
  - Accent-coloured status text (3.5:1). **Fixed**: the words are in the text colour, the icon in the accent.
  - Show Log as a tinted link (3.3:1). **Fixed**: a bordered button.
  - The scrubber track (1.25:1) and the drop-zone border (1.25:1) are below 3:1. Left as is: they match the system slider beside them.
- **Focus order** (source order): notice ✕ → Stop → tracks → AirPlay → back 10 → play → forward 10 → volume. Skip and play are declared in an overlay, so their visual position differs from source order.
- **Keyboard:**
  - Space plays and pauses; ← and → skip; ⌘. stops; ⌘O opens; Return and Esc work on the failure; Return on the welcome.
  - Volume, AirPlay, tracks and Show Log need Full Keyboard Access.
  - The scrubber isn't focusable: seeking to a point by keyboard means repeated skips, or VoiceOver's adjust action.
- **Labels:**
  - Every icon-only control has one. VoiceOver hears notices as announcements.
  - The scrubber's value is spoken as "20 minutes 34 seconds of 1 hour 39 minutes".
- **Reduce Motion:** **Fixed** (see above).
