# Evidence

The first pass of the code was gathered by a subagent from `RemoteView.swift` (RV), `RemoteState.swift` (RS) and
`app/PaperPlane/*.swift` (MC menu, RW window, PA app, RP route picker, PC controller). Line numbers
refer to that pass. Findings marked **fixed** were addressed before scoring (see 03-verdict.md).

## Structural
- Interactive elements per state:
  - Welcome: 1.
  - Idle: 1.
  - Preparing and choosing TV: 7, of which Stop, the AirPlay button and volume were enabled.
  - Playing and paused: 7.
  - Failed: 1, with no way to dismiss it (**fixed**: Dismiss added).
- Deepest nesting in the Now Playing card: 7 levels (RV:175 → 368).
- Repeated patterns:
  - "Choose TV" was said 4 ways (status line, a callout with its own AirPlay glyph, a ring around the button, a tooltip). **Fixed** by dropping the callout's glyph and wording it as an instruction.
  - Play/pause and Stop appear in the window and in the menu. That's deliberate: the menu works with the window closed.
  - Open Video appears 3 times (drop zone, failure, menu), each in a different context.
- Dead code:
  - The `.idle` cases in StatusLine and `status` can't be reached in the card.
  - `seeksToStartOnTV` is a constant until the Sony re-test.

## Copy and honesty
- Overclaims: "Send any video on your Mac" (the spec's tagline; corrupt or audio-only files are refused with a message).
- Dark patterns: none.
- Jargon:
  - "ffmpeg is missing. Run scripts/build-ffmpeg.sh…" **fixed** to "Paper Plane's video converter is missing. Reinstall Paper Plane."
  - A raw error description **fixed** to wrap it in a sentence with a next step.
  - "Converting the video failed." **fixed** to "Paper Plane couldn't convert this video. Try another file."
  - The status line's punctuation was inconsistent: **fixed**.
- Labels that didn't match behaviour:
  - The scrubber could be dragged past what's converted, then jumped back. **Fixed**: the drag stops at the converted edge (`seekableFraction`, tested).
  - The ±10 s skips stop at the converted edge. They're labelled as 10 seconds; Milestone 2 removes the limit.
  - The open panel's button said "Play" though playback waits for a TV. **Fixed**: "Open".
  - Volume was enabled before anything played. **Fixed**: disabled until the TV plays (`canAdjustVolume`, tested).
  - A drop hid the welcome without remembering it. **Fixed**: `play` dismisses it for good.
  - The welcome screen didn't highlight a drop. **Fixed**.

## Accessibility
- Labels: every icon-only control has one, except the AirPlay button. **Fixed**: `setAccessibilityLabel("Choose TV")`.
- The scrubber has a label, a spoken value and ±10 s adjustable actions. It was only dimmed when disabled. **Fixed**: `.disabled`.
- Shortcuts:
  - Space (play/pause), ← → (±10 s) and ⌘. (stop) in the window.
  - Return and Escape on the welcome and failure screens.
  - ⌘O, ⌘1 and ⌘Q in the menu.
- Focus: plain-style buttons, with no custom focus code. Every primary action has a keyboard shortcut.
- Decorative images are hidden from VoiceOver. The thumbnail is too; the title says what's playing.

## States
- Present: empty, loading (status, hourglass, the converted part of the track), error, playing, paused, TV disconnected, disabled (transport, volume, scrubber), drag-hover.
- Rough: focus (system default for plain buttons only).
- Loading has no progress percentage.

## Weight and friction (measured)
- App binary: 0.8 MB. The bundled ffmpeg and ffprobe are 48 MB, needed for conversion.
- No idle animation (0 `animation` modifiers). No network requests except to the TV and the video's own host.
- 0 modals at launch. The welcome shows once.
- Light and dark mode both honoured (renders).

## Visual
See the visual subagent's report, appended below.

### Visual (subagent report, pixel-sampled from the 2x renders; fixes applied after it)
- Spacing:
  - 20 pt margins on the remote, 28 pt on the welcome, 16 pt inset on the drop zone.
  - Vertical gaps of 13–25 pt, not on a strict 4/8 grid.
- Type: about six sizes, all system styles (title2, title3, headline, body, callout, caption).
- Colours:
  - Three slightly different blues came from mixing `.tint` and `Color.accentColor`. **Fixed**: one `.tint` everywhere.
  - Greys are system semantic colours. Orange is used only for the failure.
- Contrast:
  - Primary text: 14.9:1 light, 10.2:1 dark.
  - Secondary text (system `.secondary`): 3.95:1 light, 5.26:1 dark.
  - Disabled play glyph: 1.10:1 light. **Fixed**: tertiary glyph on a quaternary fill.
- States: empty, loading, error, success and disabled are present. Focus, hover and press are not rendered: ImageRenderer has no focus.
- Inconsistencies:
  - Mixed control-row icon colours. **Fixed**: all primary, and the AirPlay button set to `labelColor`.
  - A filled stop square among outline glyphs. **Fixed**: `stop.circle`.
  - The TV-disconnected status truncated. **Fixed**: it wraps, with shorter copy.
  - Remaining: the progress track is 6 pt and the volume track 4 pt (system slider); status symbol fills are mixed (now `.symbolVariant(.none)`); only the thumbnail and the slider knob cast shadows.
- Icon:
  - The plane is legible at 16 pt@2x. The dotted trail disappears below 32 px, which is acceptable.
  - Big Sur-style squircle, blue gradient and soft shadow: the current macOS idiom.
