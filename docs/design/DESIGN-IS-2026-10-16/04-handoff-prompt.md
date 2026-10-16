# Handoff

````
/make-plan Refine Paper Plane's remote window, Settings and menu bar menu (macOS menu bar app that plays local videos on an AirPlay TV; SwiftUI views in core/Sources/PaperPlaneUI/, renders via scripts/render-ui.sh into docs/design/) based on a Dieter Rams audit (total 21/30).

Verdict paragraph (quoted from 03-verdict.md):
> Milestone 2 roughly doubled the surface (tracks, notices, Settings, a menu bar menu) and kept the remote's bones. It reaches 21/30 with no zeros once this audit's fixes are in, so it needs polish, not a rethink.

Keep (already strong, do NOT touch in this pass):
- Principle #9 (environmentally friendly) scored 3. Evidence: one 0.2 s notice fade, off under Reduce Motion (RemoteView body, `.animation(reduceMotion ? nil : …)`); no idle timers; 1.9 MB executable. Regression check: grep core/Sources/PaperPlaneUI for `withAnimation`, `.animation(`, `.repeatForever` and `Timer`. The only hit should be the notice fade, gated on `accessibilityReduceMotion`.

Fix in priority order (top moves from the audit, verbatim):
1. #2 useful / #8 thorough — keyboard seeking: make the scrubber focusable, with ← and → by 10 s, Shift-arrows by a minute, and Home/End. Give the tracks menu a shortcut such as ⌘L, as QuickTime's Subtitles menu has. Evidence: `RemoteView.swift` Scrubber has no `.focusable`; space, ←, → and ⌘. are the only transport shortcuts today.
2. #3 aesthetic — the failure card: draw the failure on a neutral wash with an orange icon, or give its buttons a bezel that holds against orange. Evidence: the system Dismiss bezel is 1.19:1 against `Color.orange.opacity(0.08)` in docs/design/remote-failed-light.png.
3. #10 less design — the welcome's third step: macOS shows its own Local Network prompt. Consider folding "If macOS asks, click Allow" into step 2 and dropping the step. Evidence: `RemoteView.swift` WelcomeView, step("network", …).
4. #6 honest — tagline: "Send any video on your Mac to your AirPlay TV" is the one inflation left. Corrupt and audio-only files are refused, so the owner decides whether "any" stays.
5. #7 long-lasting — placeholder artwork: replace the two-stop gradient (`Artwork`, `LinearGradient` RGB 0.38/0.74/1.0 → 0.20/0.27/0.82) with a flat accent tile.

Out of scope for this refine pass: playback and conversion behaviour; the menu bar icon; Settings' three switches and their wording (just rewritten); the 20 pt margins, radii (16/12/6) and washes (0.08/0.18) just unified; copy the audit just fixed ("Ready up to", "Show Paper Plane Window", "Always draw subtitles into the picture").

Deliverables for the plan:
- Per fix: target files, exact change, verification step (a unit test for behaviour such as key handling in RemoteState or the scrubber's step logic; a fresh render via scripts/render-ui.sh for visuals).
- Token/spec changes consolidated in one place (radii, washes and margins are literal values in RemoteView.swift; keep them literal unless a third use appears).
- A regression checklist for the Keep item above.

Anti-patterns to guard against (specific to REFINE):
- Adding new abstractions where a direct change suffices.
- Restyling areas that already scored 3.
- Scope creep into structural redesign (if structure must change, this should be REDESIGN, not REFINE).
- Letting fixes mutate principles outside the priority list.
````
