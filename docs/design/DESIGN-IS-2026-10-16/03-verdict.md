# Verdict: REFINE

Milestone 2 roughly doubled the surface (tracks, notices, Settings, a menu bar menu) and kept the remote's bones. It reaches 21/30 with no zeros once this audit's fixes are in, so it needs polish, not a rethink.

## Applied during this audit (tests in brackets)

- **Honest labels.**
  - The scrubber's ready band starts at the oldest segment still on disk (`theWindowRestsFFmpegAndDeletesWhatIsBehind`).
  - Settings promises only what happens: "Changes apply from the next video you play", and "5.1 surround sound" rather than "Dolby Digital".
  - The choose-TV callout says what the code guarantees.
  - The welcome no longer claims to know what a TV can play.
  - The low-disk notice comes with the smaller window (`theLowSpaceNoticeComesWithTheSmallerWindow`).
- **Errors.**
  - The catch-all message names the button that exists and leaves raw error text to the log (`somethingUnexpectedSaysWhatToDoWithoutTheErrorText`).
  - Player failures get a log (`aStreamThePlayerRefusesEndsInAPlainMessage`).
  - "Connect to your network", not "Wi-Fi".
- **Plain words.**
  - "Always draw subtitles into the picture"; SDR explained; "Show Paper Plane Window"; "Ready up to"; "Choose your TV" in both places.
  - The tracks button is named for what it offers (`theTracksButtonIsNamedForWhatItOffers`).
- **One visual system.**
  - 20 pt margins on every screen; three radii; two washes; icons in the status line of equal width; no scrubber stub at 0:00.
  - Show Log is a button like its neighbours.
  - The next-step status is in the text colour with an accent icon (3.5:1 → body contrast).
- **Reduce Motion:** the notice's fade switches off.

## Highest-leverage moves left, in order

1. **#2 useful / #8 thorough: keyboard seeking.** Make the scrubber focusable, with ← and → by 10 s, Shift-arrows by a minute, and Home/End. Give the tracks menu a shortcut such as ⌘L, as QuickTime's Subtitles menu has. Evidence: `RemoteView.swift` Scrubber has no `.focusable`; Accessibility, "Keyboard".
2. **#3 aesthetic: the failure card.** Draw the failure on a neutral wash with an orange icon, or give its buttons a bezel that holds against orange. Evidence: Visual 12, a 1.19:1 bezel in remote-failed-light.png.
3. **#10 less design: the welcome's third step.** macOS shows its own Local Network prompt. Consider folding "If macOS asks, click Allow" into step 2 and dropping the step. Evidence: `RemoteView.swift:159`.
4. **#6 honest: tagline.** "Send any video on your Mac to your AirPlay TV" is the one inflation left. With Milestone 3 (browser videos) "any" gets closer, but corrupt and audio-only files are still refused. This is the owner's call.
5. **#7 long-lasting: placeholder artwork.** Replace the two-stop gradient with a flat accent tile, or the first frame once the thumbnail arrives (it already does). Evidence: `RemoteView.swift:420`.
