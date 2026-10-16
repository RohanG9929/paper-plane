# Scope

**Audited:** Paper Plane's remote window in every state (welcome, idle drop zone, preparing,
choosing TV, playing, paused, TV went away, long title with HDR, failed), light and dark; the
menu bar menu (code only: it is an NSMenu and can't be rendered offscreen); the app icon.

**Materials:**
- Renders: `docs/design/remote-*.png` (SwiftUI `ImageRenderer`, 2x). The AirPlay button is a
  stand-in glyph in the renders; the real one is `AVRoutePickerView`.
- Views: `core/Sources/PaperPlaneUI/RemoteView.swift`, `RemoteState.swift`.
- App wiring: `app/PaperPlane/*.swift`.
- Icon: `app/PaperPlane/Assets.xcassets/AppIcon.appiconset/` (drawn by `scripts/make-icon.swift`).

**Primary user:** the owner, at home, with a Mac and an AirPlay TV (a Sony), wanting a local video
or a browser video on the TV with as little fuss as possible.

**Primary task:** drop a video, pick the TV, watch it there; pause or skip from the Mac.

**Constraints:** native macOS 14+ SwiftUI, system font and colours, light and dark mode, Apple
HIG, VoiceOver and keyboard operability. Plays only on the TV, never on the Mac
(docs/sony-test-results.md). Milestone 2 adds seeking beyond the converted part, audio and
subtitle pickers and error recovery, so those are out of scope here.

**References:** the macOS Music / TV mini player and Control Center's Now Playing module.
