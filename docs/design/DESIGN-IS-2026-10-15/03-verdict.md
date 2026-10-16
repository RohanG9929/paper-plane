# Verdict: REFINE

The remote's bones are right: one task per state, system type and colour, every control labelled and keyboard-reachable. With 22/30 and no zeros it needs polish, not a rethink.

Highest-leverage moves, in order:
1. **#8 thorough: focus.** Give the plain transport buttons visible focus rings under Full Keyboard Access, and check the tab order: play, skip, AirPlay, volume (`RemoteView.swift` TransportButton and PlayButton).
2. **#10 less design: choosing a TV.** Show the instruction box only the first time; afterwards the status line and the ringed AirPlay button are enough (NowPlayingCard.chooseTVCallout).
3. **#3 aesthetic: grid.** Snap the card's vertical rhythm to 8 pt (18 → 16, 22 → 24) and match the progress track to the slider's thickness.
4. **#4 understandable: seeking past the converted part.** When a skip or drag stops at the converted edge, say so briefly. Milestone 2 removes the limit by restarting the conversion.
5. **#6 honest: tagline.** "Send almost any video…" or keep "any" once Milestone 2's subtitles and tracks land; decide with the owner.

Applied during this audit already: one accent colour; visible disabled play; consistent control row; lighter stop glyph; the TV-disconnected status wraps; volume and scrubber inert until playing; scrubber stops at the converted edge, with a "Ready up to" tooltip; Dismiss on failures; a drop on the welcome screen highlights and is remembered; the AirPlay button has a VoiceOver label; plainer error copy.
