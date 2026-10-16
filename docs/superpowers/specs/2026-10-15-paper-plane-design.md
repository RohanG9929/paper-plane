# Paper Plane — Design Spec

**Date:** 2026-10-15
**Status:** Draft for review
**License:** GPL-3.0

## 1. Intent

Paper Plane is an open-source Mac app, in the spirit of Beamer, that sends any video on your Mac to an AirPlay TV.

**Ownership:** this is the owner's personal project, not affiliated with any employer or organization. Commits, the GitHub repo, the Apple Developer account and the Chrome Web Store account all use the owner's personal identity and accounts.

**What the owner asked for**

- Play local video files (MKV, MP4 and anything else ffmpeg can read) on the TV over AirPlay.
- Play the video currently playing in the browser, from any hosting site, not just YouTube.
- Work with AirPlay TVs in general. The owner's test TV is a Sony with AirPlay 2.
- Open source, built from scratch. No reverse engineering of Beamer.
- Browsers for now: Chrome and Brave. Others later.
- App shape: a menu bar icon plus a small "now playing" remote window.

**Success looks like:** drop an MKV on the menu bar icon, or click the extension button on a video page, and within a few seconds it plays on the Sony, with working seek, audio track and subtitle controls.

**Non-goals (v1)**

- DRM-protected services (Netflix, Disney+, Prime Video, Max).
- Safari and Firefox extensions.
- Capturing a browser window as a fallback for undetectable players.
- Playlists or queues.
- Chromecast, DLNA, or any non-AirPlay target.
- Windows or Linux.
- Mac App Store distribution. Its sandbox does not allow installing the browser's native messaging manifest.
- Playing video on the Mac's own screen.

## 2. Key decisions

| Decision | Choice | Why |
|---|---|---|
| Build approach | From scratch, no reverse engineering | Legal safety for an open-source project, and every needed piece is public |
| AirPlay implementation | Apple's own: `AVPlayer` plus `AVRoutePickerView` (its `player` property, on macOS, enables video routes) | macOS handles discovery, pairing (including a TV's PIN prompt) and encryption, and works with third-party AirPlay 2 TVs such as the Sony |
| Platform | macOS 14+, Apple Silicon only | macOS 27 has already dropped Intel. macOS 14 provides `MenuBarExtra` and Observation |
| Format handling | Bundled ffmpeg converts to HLS on the fly. Copy whatever the TV can play, convert only the rest | Fast, no quality loss for the common case (H.264 or HEVC in MKV) |
| Delivery to the TV | Small HTTP server on the Mac's LAN address | In AirPlay video mode the TV fetches the stream itself, so `localhost` cannot work |
| Browser → app channel | Chrome native messaging | Chrome or Brave launches the helper on demand, and no local port is exposed to web pages |
| One pipeline | Local files and web streams share it. The only difference is the ffmpeg input | Seeking, tracks and subtitles are built once |
| License | GPL-3.0 | Keeps all versions and forks open source. Matches IINA. No App Store constraint applies, since the App Store is out anyway |

## 3. Architecture

```
                 ┌───────────────────── Paper Plane.app ─────────────────────┐
 File drop ─────▶│ SourceResolver ─▶ MediaProbe ─▶ ConversionPlanner          │
 Finder Open With│        ▲                              │                    │
                 │        │                              ▼                    │
 Extension ──▶ paperplane-host ──▶ BrowserBridge    Transcoder (ffmpeg)       │
 (Chrome/Brave)  │ (Unix socket)                         │ HLS segments       │
                 │                                       ▼                    │
                 │        SegmentWindow ◀──────── session folder (temp)       │
                 │              │                        │                    │
                 │              ▼                        ▼                    │
                 │     PlaybackController ──▶ AVPlayer   StreamServer ────────┼──▶ Sony TV
                 │              ▲            (AirPlay)    (LAN IP + token)    │   (fetches HLS)
                 │        MenuBar + Remote UI                                 │
                 └────────────────────────────────────────────────────────────┘
```

### 3.1 Units

Each unit has one job and a narrow interface. Everything except the UI and `PlaybackController` lives in a Swift package (`PaperPlaneCore`) so it can be tested without the app.

| Unit | Does | Interface (sketch) | Depends on |
|---|---|---|---|
| `SourceResolver` | Turns any input into ffmpeg input(s) | `resolve(Source) async throws -> ResolvedInput` (1–2 URLs + per-input HTTP headers + title) | `YtDlp` for page URLs |
| `MediaProbe` | Reads tracks, codecs, duration, HDR flags | `probe(ResolvedInput) async throws -> MediaInfo` | bundled `ffprobe` |
| `ConversionPlanner` | Pure decision logic: what to copy, convert, burn in | `plan(MediaInfo, TrackChoice, OutputProfile) -> ConversionPlan`, `ConversionPlan.ffmpegArguments(start:output:)` | nothing |
| `Transcoder` | Runs one ffmpeg process for a plan from a start offset, reports progress | `start(plan, from:) -> TranscodeSession` (segment-ready events, `pause()`, `resume()`, `stop()`) | bundled `ffmpeg` |
| `SegmentWindow` | Decides which segments to keep or delete, and when to pause or resume ffmpeg | `update(playhead:, produced:) -> [WindowAction]` (pure) | nothing |
| `StreamServer` | Serves the session folder over HTTP to the TV | `serve(folder) -> URL` (`http://<lan-ip>:<port>/<token>/index.m3u8`), `stop()` | Network.framework |
| `YtDlp` | Runs bundled yt-dlp, keeps it updated | `resolve(pageURL, cookies:) async throws -> ResolvedInput`, `updateIfNeeded()` | bundled `yt-dlp` |
| `BrowserBridge` | Unix socket listener receiving play requests from the helper | `AsyncStream<PlayRequest>` | nothing |
| `paperplane-host` | Native messaging host executable inside the app bundle | stdin/stdout length-prefixed JSON ⇄ Unix socket. Launches the app if it is not running | nothing |
| `PlaybackController` | Orchestrates a playback: sessions, seeking, track switches, Now Playing, sleep, network changes | `play(Source)`, `seek(to:)`, `select(audio:subtitle:)`, `stop()` | all of the above, AVFoundation |
| UI | `MenuBarExtra` menu + remote window (SwiftUI), route picker | observes `PlaybackController` | AVKit |
| Extension | Finds streams in tabs, sends play requests | `StreamDetector` (pure ranking logic) + service worker + content script + popup | Chrome APIs |

## 4. Playing a local file

1. The user drops a file on the menu bar icon or the remote window, or uses **Open With → Paper Plane**. Paper Plane also auto-detects `<name>.srt` / `<name>.<lang>.srt` next to the file.
2. `MediaProbe` reads the file. `PlaybackController` picks the default audio track (the file's default flag, otherwise the first) and turns subtitles off unless a track is flagged forced.
3. If no AirPlay TV is selected, the remote window opens with the route picker highlighted.
4. `Transcoder` starts writing HLS (fMP4 segments, ~6 s target) into a per-playback temp folder under `~/Library/Caches/Paper Plane/sessions/<id>/`.
5. Once the first 2 segments exist, `StreamServer` publishes the folder and `AVPlayer` starts playing its URL. AirPlay hands that URL to the TV.
6. The remote shows play/pause, a full-length seek bar, ±10 s skip, volume, audio and subtitle pickers, and the route picker. Media keys and macOS Now Playing work via `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`.

### 4.1 Conversion rules (`ConversionPlanner`)

| Input | Action |
|---|---|
| H.264 video | Copy |
| HEVC video | Copy, tagged `hvc1` |
| Other video (AV1, VP9, MPEG-2, VC-1, …) | Re-encode with VideoToolbox: H.264 for ≤1080p sources, HEVC for larger or HDR sources |
| AAC, AC3, E-AC3 audio | Copy |
| Other audio, surround (DTS, TrueHD, multichannel FLAC/Opus/PCM) | Convert to E-AC3 5.1 |
| Other audio, stereo or mono | Convert to AAC |
| Text subtitles (SRT, ASS/SSA, mov_text, WebVTT; embedded or sidecar) | Default: WebVTT subtitle track in the HLS output. Fallback: burn in (re-encodes video) |
| Picture-based subtitles (PGS, VobSub, DVB) | Burn in (re-encodes video) |

The **output profile** captures what the TV accepts: subtitle tracks yes/no, surround yes/no, HDR yes/no. v1's default profile, from the Sony test, is surround **off** and HDR **off** (docs/sony-test-results.md), with user overrides in Settings: "Always burn in subtitles", "Allow surround (AC3/E-AC3)", "Allow HDR". Receivers can't be queried for capabilities, so overrides are the escape hatch for other TVs.

### 4.2 Seeking and the converted-video window

- **Sessions.** Each ffmpeg run is a *session* with a start offset. The remote shows *movie time = session offset + player time*. The seek bar always spans the full duration from `MediaProbe`.
- **Window.** `SegmentWindow` keeps segments from 5 minutes behind the playhead to at most 20 minutes ahead (both tunable). ffmpeg is paused (`SIGSTOP`) when the lead reaches 20 minutes and resumed (`SIGCONT`) below 10. Segments more than 5 minutes behind are deleted. For web streams, ffmpeg is stopped instead of paused, so idle connections don't time out, and restarted when needed.
- **Seek inside the window:** plain `AVPlayer` seek. Instant.
- **Seek outside the window:** stop the session, start a new one at the target time (ffmpeg `-ss` before the input, so it lands on the nearest keyframe), and replace the player item. Target: playing again within ~3 s for copy mode.
- **Audio or subtitle change:** same as a seek outside the window, at the current position.
- **Cleanup:** a session's folder is deleted when it ends. All of `sessions/` is wiped at launch.

*Considered and rejected for v1:* a full on-demand VOD playlist with segments generated per TV request (the Jellyfin approach). Seeking is better, but copy mode then needs keyframe indexing and per-segment ffmpeg runs. Revisit if restart latency proves annoying.

## 5. Playing a browser video

### 5.1 Extension (Manifest V3, TypeScript)

**Permissions:** `webRequest`, `nativeMessaging`, `storage`, `scripting`, `tabs`; host permissions `<all_urls>`.

**Detection (service worker):**
- `webRequest.onSendHeaders` with `extraHeaders` captures the URL plus `Cookie`, `Referer`, `Origin` and `User-Agent` for each request.
- `webRequest.onHeadersReceived` classifies the response:
  - **HLS:** `.m3u8`, `application/vnd.apple.mpegurl`, `application/x-mpegurl`
  - **DASH:** `.mpd`, `application/dash+xml`
  - **Progressive:** `video/mp4`, `video/webm`, `.mp4`, `.m4v`, `.webm`, `.mov`
- Segment requests (`.ts`, `.m4s`, byte ranges) are not candidates. They count as "activity" for the stream they belong to (same host and path prefix).
- Per-tab, per-frame candidate lists are kept in `chrome.storage.session`, so they survive service-worker suspension. They are cleared on navigation.

**Content script (all frames):** reports each `<video>` element's playing state, `currentTime`, `duration` and `src` (`blob:` or http). On request it pauses the video.

**Ranking (`StreamDetector`, pure and unit-tested):** the score favours, in order:
1. Belongs to a frame with a playing `<video>`.
2. Ongoing segment activity.
3. Is an HLS master playlist (first `.m3u8` in a burst).
4. Matches a direct http `<video src>`.
5. Duration ≥ 60 s (tiebreaker against ads).

**Toolbar button:**
- Grey when there are no candidates.
- Coloured when there is one confident candidate. Clicking sends it immediately.
- Badge plus a popup chooser when the choice is ambiguous (via `chrome.action.setPopup` per tab).

**YouTube:** on `youtube.com` / `youtu.be` pages, the extension sends `{kind: "page"}` with the page URL, current time and the site's cookies, instead of a sniffed stream.

**After the app acknowledges playback has started,** the extension pauses the browser video.

### 5.2 Native messaging and the helper

- Host name: `dev.paperplane.host`. This is an identifier only, no domain is needed. The host manifest is installed by the app on first launch, and re-checked on every launch, to:
  - `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`
  - `~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/`
- `allowed_origins` lists only the Paper Plane extension ID. During development, the unpacked extension's ID is pinned with a `key` in `manifest.json`.
- `paperplane-host` reads one length-prefixed JSON message, connects to the app's Unix socket at `~/Library/Application Support/Paper Plane/bridge.sock` (mode `0600`), and relays the message and the reply. If the socket is missing, it launches the app via its bundle ID and retries for up to 10 s.
- Message (v1):
  ```json
  {"type":"play","v":1,
   "source":{"kind":"stream","url":"…","format":"hls|dash|progressive",
             "headers":{"Cookie":"…","Referer":"…","User-Agent":"…"}},
   "pageUrl":"…","title":"…","startAt":1234.5}
  ```
  `kind: "page"` replaces `url` and `format` with the page URL (YouTube).
  Reply: `{"ok":true}`, or `{"ok":false,"error":"…"}`.

### 5.3 App side

- `SourceResolver` passes stream URLs and headers straight to ffmpeg (`-headers`, `-user_agent`, `-referer`).
- For `kind: "page"`, it runs `yt-dlp -J`, preferring formats that can be copied (H.264/HEVC + AAC, up to 1080p). Video and audio arrive as two inputs and are mapped together. Cookies are handed over in memory, never via a cookies file.
- **Paste a link** in the menu sends the clipboard URL through the same `kind: "page"` path.
- **Live streams:** detected from the HLS playlist (no `#EXT-X-ENDLIST`). The seek bar is replaced by a "Live" indicator.
- **yt-dlp updates:** the official standalone `yt-dlp_macos` build ships in the app. Updates are downloaded only from `github.com/yt-dlp/yt-dlp` releases, verified against the release's `SHA2-256SUMS`, and stored in `~/Library/Application Support/Paper Plane/bin/`, never inside the signed bundle. Paper Plane checks at most once a day, and immediately when an extraction fails.

### 5.4 Privacy

- Cookies and auth headers live only in memory for the duration of one playback.
- Logs redact `Cookie`, `Authorization` and URL query strings.
- Nothing leaves the Mac except requests to the video's own host and to the TV.

## 6. Error handling

| Situation | Behaviour |
|---|---|
| First launch | A one-screen explainer for the macOS "accept incoming connections?" prompt, which the TV needs to reach the stream |
| No TV selected | Remote opens with the route picker highlighted. Nothing plays locally |
| AirPlay drops or TV turns off | Pause, show **Reconnect**, resume at the same movie time |
| Mac would idle-sleep | `IOPMAssertion` prevents idle system sleep during playback (the display may sleep). Lid-close sleep is not prevented, and the docs say so |
| File cannot be probed or converted | Plain-language message naming the problem. ffmpeg's log is saved (redacted) and linked from the message for bug reports |
| HTTP 401/403/410 or link expiry on a web stream | "The site stopped the stream — click Paper Plane in your browser again" |
| yt-dlp extraction fails | Update yt-dlp and retry once, then show the error |
| Network/IP change (`NWPathMonitor`) | Restart `StreamServer` on the new address and restart the session at the current movie time |
| Helper can't reach the app within 10 s | The extension shows an error badge, and the popup says "Couldn't start Paper Plane" |
| Low disk (< 2 GB free in Caches) | Shrink the window ahead to 5 minutes, and warn if it still can't keep up |

## 7. Testing

| Layer | What | How |
|---|---|---|
| Unit | `ConversionPlanner` (every row of §4.1 × output profiles), `SegmentWindow`, native messaging framing, message decoding, header redaction | Swift Testing in `PaperPlaneCore`, recorded `ffprobe` JSON fixtures |
| Unit | `StreamDetector` ranking | Vitest with recorded request sequences from real sites (ads + main video, iframes, master + variant playlists) |
| Integration | Full pipeline on generated media | `scripts/make-test-media.sh` uses ffmpeg to create ~10 s clips covering each input row of §4.1. Each runs through probe → plan → transcode, and `AVURLAsset` must report the HLS output playable with the expected tracks. Also: seek-outside-window restart and window cleanup |
| Integration | `StreamServer` | Token required (404 otherwise), correct MIME types, serves while files grow |
| Manual | Real TV | A checklist on the Sony before each release: local MKV (copy), MKV needing re-encode, PGS burn-in, SRT, audio switch, seek far ahead, TV off/on, browser HLS site, browser MP4 site, YouTube, paste link |

The unit and integration layers run in CI on GitHub's macOS runners. No TV is needed.

## 8. Build order

| # | Milestone | Done when |
|---|---|---|
| 0 | **Sony test** (throwaway, `spikes/` folder, not shipped) | A minimal `swiftc`-built app serves pre-made HLS test streams over the LAN and plays them on the Sony through `AVRoutePickerView`. Results recorded in `docs/sony-test-results.md` for: H.264+AAC baseline; HEVC fMP4; AC3 and E-AC3 5.1; WebVTT subtitle track; HDR10 HEVC; a live-growing EVENT playlist, including seeking within it; whether the app can tell a TV is selected before playback starts (`isExternalPlaybackActive`); whether the last-used TV can be reselected without the picker. The answers set the default output profile (§4.1) |
| 1 | **Local files** | Repo scaffold (Xcode project, `PaperPlaneCore` package, GPL-3.0 `LICENSE`, README), ffmpeg build script, `MenuBarExtra` + remote window, probe → plan → transcode → serve → AirPlay. Dropping a copy-mode MKV plays on the Sony |
| 2 | **Seeking and tracks** | `SegmentWindow`, restart-on-seek, audio switching, text and picture subtitles, sidecar `.srt`, Now Playing and media keys, sleep assertion, error handling for local playback |
| 3 | **Browser videos** | Extension (detection, ranking, popup, pause), `paperplane-host`, manifest installation for Chrome and Brave, `BrowserBridge`. A browser HLS site and an MP4 site play on the Sony |
| 4 | **YouTube and Paste a link** | Bundled yt-dlp, the update mechanism, the `kind: "page"` path, the menu item |
| 5 | **First release** | Manual checklist passes, README with install steps (including loading the unpacked extension), GitHub release with a zipped app |

## 9. Tooling and repo layout

- **App:** Swift 6, SwiftUI, AVFoundation/AVKit, Network.framework, MediaPlayer. Built with Xcode, which is not yet installed (only the Command Line Tools are) and is required from Milestone 1. Milestone 0 builds with `swiftc` from the Command Line Tools.
- **ffmpeg:** built from source by `scripts/build-ffmpeg.sh` (arm64, static):
  - Enabled: VideoToolbox, AudioToolbox, libass (subtitle burn-in), libdav1d (AV1 decode).
  - No x264/x265: encoding uses VideoToolbox.
  - GPL-compatible with the project license.
  - Milestone 0 uses Homebrew's ffmpeg to make test media.
- **Extension:** TypeScript, built with esbuild, tests with Vitest. Node is already installed.

```
paper-plane/
├── app/
│   ├── PaperPlane.xcodeproj
│   ├── PaperPlane/            # SwiftUI app, PlaybackController, UI
│   └── PaperPlaneHost/        # native messaging helper
├── core/                      # PaperPlaneCore Swift package + tests
├── extension/                 # Chrome/Brave MV3 extension + tests
├── scripts/                   # build-ffmpeg.sh, fetch-yt-dlp.sh, make-test-media.sh
├── spikes/                    # throwaway experiments (Milestone 0)
├── docs/
├── LICENSE                    # GPL-3.0
└── README.md
```

## 10. Risks and open items

| Risk / item | Mitigation / when decided |
|---|---|
| The Sony's AirPlay receiver may reject or mishandle live-growing HLS, WebVTT, surround or HDR | Milestone 0 tests each one before any product code. Output profile and overrides absorb the differences. **Resolved:** surround off (the Sony rejects AC3/E-AC3 in fMP4 and MPEG-TS); HDR off (no HDR indicator); WebVTT subtitle tracks work; growing EVENT playlists work but start at the live edge, so Paper Plane seeks to 0 after load |
| macOS may not allow choosing the AirPlay TV programmatically, so the user picks it each time | Milestone 0 checks. If not possible, the remote opens with the picker ready. **Resolved:** not possible. macOS doesn't remember the TV for the app or switch to it before something is loaded, so the remote opens with the picker each time and starts paused until `isExternalPlaybackActive` |
| Sites change their players, breaking detection | Ranking logic is isolated and fixture-tested. New fixtures can be added per bug report |
| YouTube changes break yt-dlp | Automatic yt-dlp updates and retry |
| Lid-closed laptops sleep and stop the stream | Documented limitation for v1 |
| Signing and notarization (Apple Developer account, $99/yr) | Deferred until a public release. Personal account only |
| Chrome Web Store listing ($5 one-time) | Deferred. v1 installs the unpacked extension. Personal account only |
| GitHub hosting | The owner's personal GitHub account, not any organization's. Decided before the first push |
