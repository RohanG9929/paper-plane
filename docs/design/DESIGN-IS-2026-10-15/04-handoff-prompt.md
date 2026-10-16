# Handoff

Carried into Plan 3 as its UI-refine task, rather than run as a separate `/make-plan`.

````
/make-plan Refine Paper Plane's remote window (core/Sources/PaperPlaneUI/RemoteView.swift) based on a Dieter Rams audit (total 22/30).

Verdict paragraph (quoted from 03-verdict.md):
> The remote's bones are right: one task per state, system type and colour, every control labelled and keyboard-reachable. With 22/30 and no zeros it needs polish, not a rethink.

Keep (already strong, do NOT touch in this pass):
- Principle #2 (useful) scored 3. Evidence: welcome → drop zone → choose TV → transport, one action each (RemoteView body switch). Regression check: scripts/render-ui.sh; each state still shows exactly one primary action, and RemoteStateTests pass.
- Principle #9 (environmentally friendly) scored 3. Evidence: no animation modifiers in RemoteView.swift, dark mode renders. Regression check: grep -c 'animation' RemoteView.swift stays 0 for idle states; remote-*-dark.png renders correctly.

Fix in priority order (top moves from the audit, verbatim):
1. #8 thorough, focus: give the plain transport buttons visible focus rings under Full Keyboard Access, and check the tab order: play, skip, AirPlay, volume. Evidence: RemoteView.swift TransportButton and PlayButton (.buttonStyle(.plain)).
2. #10 less design, choosing a TV: show the instruction box only the first time; afterwards the status line and the ringed AirPlay button are enough. Evidence: NowPlayingCard.chooseTVCallout.
3. #3 aesthetic, grid: snap the card's vertical rhythm to 8 pt (18 → 16, 22 → 24) and match the progress track to the slider's thickness. Evidence: visual report spacing 13–25 pt; track 6 pt vs 4 pt.
4. #4 understandable, seeking past the converted part: when a skip or drag stops at the converted edge, say so briefly (Milestone 2 removes the limit). Evidence: Scrubber drag clamp; PlaybackController.seek clamp.
5. #6 honest, tagline: decide "any video" vs "almost any video" with the owner once subtitles and tracks land. Evidence: WelcomeView "Send any video on your Mac to your AirPlay TV."

Out of scope for this refine pass: the menu bar menu, the app icon, the PlaybackController's behaviour, new features.

Deliverables for the plan:
- Per fix: target files, exact change, verification step (render PNG, RemoteStateTests)
- Token or spec changes in one place (spacing constants at the top of RemoteView.swift)
- Regression checklist for the Keep items above

Anti-patterns to guard against (specific to REFINE):
- Adding new abstractions where a direct change suffices
- Restyling areas that already scored 3
- Scope creep into structural redesign
- Letting fixes change principles outside the priority list
````
