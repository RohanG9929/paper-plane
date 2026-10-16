# Paper Plane — Milestone 3 decisions (addendum to the design spec)

**Date:** 2026-10-16 (overnight run; the owner pre-approved Plans 3–5 and is asleep)
**Status:** Decisions taken without the owner, inside the approved spec (§5, §5.1–5.4, §6). Each says what it costs if wrong. Decisions 18–32 were taken while building Plan 4.

Milestone 3 is "Extension (detection, ranking, popup, pause), `paperplane-host`, manifest installation for Chrome and Brave, `BrowserBridge`. A browser HLS site and an MP4 site play on the Sony". YouTube and Paste a link are Milestone 4 (Plan 5).

## The bridge

1. **One Unix-domain socket** at `~/Library/Application Support/Paper Plane/bridge.sock`, served by Network.framework (tried in scratch). The folder is created 0700 and the socket chmodded to 0600 once bound, so only the same user can connect (spec §5.2). A stale socket file from a crash is removed before binding. Paths too long for a socket address (104 bytes) are refused rather than cut short.
2. **Messages** are the spec's v1 JSON (§5.2): `{"type":"play","v":1,"source":{…},"pageUrl","title","startAt"}`, a reply `{"ok":true}` or `{"ok":false,"error":"…"}`. Over the socket each message is length-prefixed exactly like native messaging (4-byte little-endian length, then UTF-8 JSON), so the helper only relays bytes. Messages of 1 MB or more are refused before being read (Chrome's limit to the host is 4 GB, but nothing legitimate here is more than a few KB). A connection that sends nothing within 10 s is closed.
3. **Validation in the app:**
   - `url` and `pageUrl` must be `http` or `https`.
   - Headers keep only `Cookie`, `Referer`, `Origin` and `User-Agent`, with line breaks stripped (Plan 1's `ResolvedInput` already does).
   - `startAt` must be finite and ≥ 0.
   - An unknown `type`, `v`, `kind` or `format` gets `{"ok":false}`, with a short reason that says nothing secret.

   *Cost if wrong:* a site with an unusual required header won't play.
4. **`kind: "page"`** (YouTube) is accepted by the format but answered "YouTube comes in a later version of Paper Plane." until Plan 5 adds yt-dlp. It leaves whatever is playing alone.

## The helper

5. **`paperplane-host`** is a small Swift command-line tool in the app bundle (`Contents/Helpers/paperplane-host`), built by an Xcode target of its own.
   - It reads one message from stdin, connects to the socket, relays the message and the reply, and exits.
   - If nothing is listening, it opens the app it lives in, in the background (`open -g`), and retries for up to 10 s, then replies "Couldn't start Paper Plane." (spec §5.2, §6). It waits up to 2 minutes for the reply, then says "Paper Plane didn't answer."
   - The relay and framing are in `PaperPlaneCore` and tested; the tool is a thin `main`. It uses blocking POSIX sockets, which suit a tool that does nothing else.
   - *Ruling:* it opens the enclosing app by path rather than by bundle ID, so a development build's helper starts that build. Cost if wrong: none.
6. **Manifest installation** (spec §5.2): on every launch the app writes `dev.paperplane.host.json` into Chrome's and Brave's `NativeMessagingHosts` folders.
   - It writes only when that browser's support folder exists, points at the bundled helper, and allows only the Paper Plane extension's ID.
   - It rewrites the file only if it differs.
   - A launch argument `-PaperPlaneInstallsBrowserHosts NO` skips it, for automated checks that shouldn't touch real browser profiles; every check script passes it.

   *Cost if wrong:* none, since the file is inert without the extension.
7. **The extension's ID is pinned** by a public `key` in `manifest.json` (spec §5.2). The key pair was generated once with OpenSSL. Only the public key is committed, and the private key was discarded: it's only needed to publish, which goes through the Chrome Web Store's own key. A test derives the ID from the committed key and checks it against the ID the app allows.

## The extension

8. **Layout:** `extension/`, with TypeScript, esbuild and Vitest (spec §9).
   - Dev tools are pinned to releases at least two weeks old and installed with `--ignore-scripts`.
   - The pure logic lives in plain modules tested by Vitest: request classification, ranking (`StreamDetector`), tab state, message building, the button and popup view, and checking content-script reports.
   - The service worker, content script and popup are thin wiring around them.
9. **Detection** follows §5.1.
   - `webRequest.onSendHeaders` with `extraHeaders` captures each request's `Cookie`, `Referer`, `Origin` and `User-Agent`. They are held in memory by request ID only until the response arrives, and kept only for a stream.
   - `onHeadersReceived` classifies HLS, DASH and video files by content type and extension.
   - Segments count as activity for the stream whose playlist's folder holds them.
   - Candidates are kept per tab in `chrome.storage.session`, at most 20 per tab, and cleared when the tab loads a new page.
10. **DASH** streams are detected and ranked but sent as `format: "dash"`; ffmpeg reads DASH manifests directly. *Cost if wrong:* some DASH sites need per-segment headers ffmpeg doesn't repeat.
11. **Button states** (§5.1):
    - Grey with no candidates, and its popup explains what to do.
    - Coloured with one confident candidate: a click sends it.
    - A count badge and a popup chooser when the choice is ambiguous.
    - "…" while sending, and "!" with the reason in the popup after a failure.

    "Confident" means the top score beats the next by at least one criterion. The weights (16, 8, 4, 2, 1) make each criterion outweigh all those after it together.
12. **The browser's video pauses once the app replies ok** (§5.1); every frame's videos pause.
13. **Icons** are drawn by `scripts/make-icon.swift --extension`, from the same drawing as the app icon: full-bleed for the toolbar, colour, and grey for "nothing found". *Ruling:* not `sips` from the app icon, whose margin would leave a tiny glyph at 16 px.

## The app

14. **Web playback** goes through the same pipeline with `ResolvedInput` carrying the headers (§5.3). Subtitles from web streams aren't converted (Plan 3 rule: local files only). The remote shows the page's title. Web streams get no thumbnail, so nothing more is fetched from the site than playing needs.
15. **Live streams** (§5.3): a web stream with no duration from ffprobe (an HLS playlist without `#EXT-X-ENDLIST`) is live.
    - A "Live" label with a red dot replaces the scrubber, and the skips are off.
    - Now Playing marks it live.
    - It starts at the live edge, ignoring `startAt`.
16. **The window for web streams:** ffmpeg is not paused (`SIGSTOP`) for web inputs, because the site may drop the idle connection (spec §4.2 says stop instead). v1 lets it run and still deletes what's behind; restarting a stopped web session from the converted edge comes later.
    - When disk space is low, the notice says "a long video may stop part-way through", since the window can't keep less ahead.
    - *Cost if wrong:* disk use grows with what's downloaded ahead, bounded by deletion behind.
17. **Errors** (§6): ffmpeg or ffprobe reporting HTTP 401, 403, 404 or another 4xx (410 Gone among them) becomes "The site stopped the stream — click Paper Plane in your browser again". This applies at the start or part-way through. Logs redact cookies, authorization and query strings (Plan 1's `Redaction`).

## Taken while building

18. **The reply waits until the video is ready for the TV:** probed, and its first segments served. The browser pauses only when Paper Plane really has the video, and a failure is the remote's own message. A start that Stop or a newer video replaces answers "Stopped in Paper Plane." or "Another video took its place." *Cost if wrong:* a slow site keeps the button on "…" for a few seconds.
19. **Copied AAC goes through `aac_adtstoasc`.** The live-stream test found that ffmpeg refuses to copy AAC from MPEG-TS (ADTS headers) into fMP4, which most sites' HLS and any local `.ts` file would hit. `AudioAction.copy` now names its codec, like `VideoAction.copy`, so the filter is added only for AAC (it passes AAC from MP4 through unchanged).
20. **Web inputs are limited to web protocols** (`-protocol_whitelist https,http,tls,tcp,crypto,data`).
    - ffmpeg already refuses `file:` under a web playlist (checked); the list also shuts out `udp:` and `rtp:`.
    - A test pins that a web playlist naming local files can't be read.
21. **A video file is a candidate only when a `<video>` element fetches it** (request type `media`). A player's own fetches of `.mp4` pieces are segments of a stream (fMP4 HLS and DASH).
22. **Variant playlists** are HLS playlists fetched within 10 s of a master, from its frame and host. They're credited to the master and not offered separately. *Cost if wrong:* two different videos started within 10 s on one host show as one.
23. **Only a real page load clears a tab.** A single-page site changing its address keeps its candidates, and ranking prefers whichever is active.
24. **A worker's requests** (no frame) count towards whichever frame has a playing video.
25. **A YouTube page's cookie and user agent** come from its page load and are kept only for YouTube video pages, ready for Plan 5.
26. **The remote comes forward for a stream** sent from the browser, to choose the TV, and not for a page it can't play yet.
27. **Ranking fixtures are synthetic.** They are shaped like real sites: an ad before a story, a background loop beside a film, master and variants, DASH, two players. Recording real sites' requests needs the owner's browser session (Sony checklist B4, B5).
28. **End-to-end checks without a TV:**
    - `scripts/check-bridge.sh`: the helper and the app.
    - `scripts/check-extension.sh`: a headless Chrome with a throwaway profile, loading the extension through DevTools, since branded Chrome no longer takes `--load-extension`, then the helper and the app.
    - Neither touches the owner's browser profile.
29. **The popup is plain HTML and CSS**, in the system font with light and dark colours. Everything it shows is inserted as text, never HTML.
30. **Messages are checked on arrival:**
    - Content scripts' video reports are checked for shape and capped at 20 videos and 2,048 characters per source.
    - The popup is recognised by its address, and content scripts take orders only from the extension.
