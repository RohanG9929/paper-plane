# Scorecard (scored after the fixes in 01-evidence.md)

1. Good design is innovative — Score: 2/3
   Evidence: the Now Playing card is the familiar pattern. What's new is that seeking anywhere, switching audio or adding subtitles each quietly starts a new conversion. The user sees only a status line ("Moving to 1:02:03…"), and the scrubber's lighter band shows what's ready.
   Justification: a clear improvement on a known pattern for files AirPlay can't play, not a new pattern.
2. Good design makes a product useful — Score: 2/3
   Evidence: with a mouse it takes three steps (drop, pick the TV, watch), and seeks, tracks and settings are one action each. With a keyboard, seeking to a point means repeated ±10 s skips, and the tracks menu and AirPlay need Full Keyboard Access (Accessibility).
   Justification: the primary task completes; keyboard users take extra steps for seeking and tracks.
3. Good design is aesthetic — Score: 2/3
   Evidence: system type, the accent plus the system grays, 20 pt margins on every screen, three radii and two washes (Visual 1–8 fixed). What remains: the system Dismiss bezel is faint on the orange failure wash in light mode, and the header moves with the title's line count.
   Justification: one visible system with two minor inconsistencies left.
4. Good design makes a product understandable — Score: 2/3
   Evidence: standard glyphs, every control labelled, and Settings in plain words. The speech-bubble button still needs its tooltip ("Subtitles", "Audio", or "Audio and Subtitles").
   Justification: one control needs a tooltip.
5. Good design is unobtrusive — Score: 2/3
   Evidence: the artwork and title lead, and notices are small and leave on their own. While a TV is being chosen, the callout and ring are deliberately loud, until a TV has been chosen once. The window opens on every launch, since it is the drop target.
   Justification: chrome is visible but quiet.
6. Good design is honest — Score: 2/3
   Evidence: every label now matches its behaviour (Copy and honesty 1–11 fixed, five with tests). One inflation remains: the tagline "Send any video on your Mac", which is the owner's decision.
   Justification: at most one minor inflation.
7. Good design is long-lasting — Score: 2/3
   Evidence: system controls and SF Symbols throughout. The placeholder artwork and the icon use a two-stop blue gradient.
   Justification: one dated marker.
8. Good design is thorough down to the last detail — Score: 2/3
   Evidence: empty, loading, error (with a log where one helps), success, paused, TV disconnected, disabled and drag-over are all drawn. Focus rings are in code but can't be rendered or checked without a person. The scrubber can't take keyboard focus.
   Justification: one state (focus) is unverified and rough at the scrubber.
9. Good design is environmentally friendly — Score: 3/3
   Evidence: a 1.9 MB native executable; the 48 MB ffmpeg is the engine. No idle animation, nothing periodic while idle, dark mode honoured, and the one fade switches off under Reduce Motion.
   Justification: it meets every anchor of the top level that applies to a native app.
10. Good design is as little design as possible — Score: 2/3
    Evidence: each element serves the task. Arguably removable: the in-window Stop (the menu and ⌘. have it), and the welcome's third step (macOS asks anyway).
    Justification: two removable elements.

**Total: 21/30** (the 2026-10-15 audit: 22/30, on a smaller surface: no tracks, Settings, notices or menu bar menu)
