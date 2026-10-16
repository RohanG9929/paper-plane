# Scope: Paper Plane remote, Settings and menu bar menu, after Milestone 2

**Audited:** the remote window (`core/Sources/PaperPlaneUI/RemoteView.swift`, states from `RemoteState.swift`), the Settings window (`SettingsView.swift`), and the menu bar menu's content (`StatusMenu.swift`, drawn by `app/PaperPlane/StatusItem.swift`). Renders, light and dark: `docs/design/remote-*.png` (14 states) and `docs/design/settings-*.png`.

**Previous audit:** `docs/design/DESIGN-IS-2026-10-15/` scored 22/30, REFINE. Its moves 1–4 were carried into Plan 3: focus rings on the remote's buttons, the choose-TV box only until a TV has been chosen once, an 8-point rhythm with a 4-point track, and explaining the converted part (Milestone 2 replaced the limit with "Moving to…"). Move 5 (the tagline) is the owner's call.

**New since then:** an Audio and Subtitles menu beside the AirPlay button; a status line for new sessions ("Moving to 1:12:40…", "Switching to…", "Adding subtitles…"); Show Log on failures; a notice banner; a Settings window with three switches; a menu bar menu with Audio and Subtitles submenus.

**Primary user:** the owner and people like them: someone with videos on a Mac (often MKV) and an AirPlay 2 TV.
**Primary task:** get a video playing on the TV, then control it (pause, seek, tracks) without touching the Mac much.

**Constraints:** native macOS 14+, SwiftUI hosted in AppKit windows, system type and the accent colour; no network UI; a menu bar app with no Dock icon. Renders come from ImageRenderer (Settings from AppKit's offscreen drawing), so AppKit-backed controls (the AirPlay button, menus) appear as their labels.

**References:** Apple's TV app and QuickTime Player (transport and the audio/subtitle bubble), the previous audit.
