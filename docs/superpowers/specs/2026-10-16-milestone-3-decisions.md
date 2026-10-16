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
10. **DASH is not offered yet** (revised after review). The bundled ffmpeg is built without libxml2, so it has no DASH reader. The extension still recognises DASH manifests but doesn't offer them, and the app answers a `dash` request with "Paper Plane can't play this site's kind of stream (DASH) yet." Building ffmpeg with libxml2 (`--enable-libxml2`) would turn it on; that's for a later plan, with a Sony check. *Cost:* DASH-only sites show "No video found yet".
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
17. **Errors** (§6): ffmpeg or ffprobe reporting HTTP 400, 401, 403, 404 or another 4xx (410 Gone among them) becomes "The site stopped the stream — reload the page, then click Paper Plane again". This applies at the start, or when ffmpeg fails part-way through.
    - *Ruling:* the wording differs from the spec's "click Paper Plane in your browser again", because a page that hasn't reloaded sends the same expired link.
    - When a site refuses the rest of an HLS stream, ffmpeg skips what it can't get and finishes without an error. The proxy notices the refusal (decision 31), and the remote says "The site stopped sending this video part-way through. Reload the page, then click Paper Plane again for the rest." The video plays on to where it got.
    - Other failures of a web stream say "Paper Plane couldn't get this video from the site", not "this file".
    - Logs redact cookies, authorization and query strings (Plan 1's `Redaction`).

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
    - Titles are cut to 200 characters.

## From the reviews

31. **ffmpeg reads web streams through a proxy in the app** (security review, two MEDIUM findings). ffmpeg sends a site's `-headers` to every host the playlist names, and fetches any address it names (checked in the source and by experiment). That leaked the site's cookie to other hosts, and let a page's playlist send requests into the local network. Now:
    - ffmpeg is given `http://127.0.0.1:<port>/<token>/<input>/<scheme>/<host>/<path>` and no headers. The proxy fetches each request itself, with no cookie store or cache.
    - The cookie, Referer and Origin go only to the stream's own site: the same host, or the same registrable domain (the last two labels, three under a two-part suffix such as co.uk).
    - Loopback, private, link-local, shared and multicast addresses are refused, after name lookup, unless the stream itself is on one.
    - Playlists (known by type, name or content) have their absolute, root-relative and protocol-relative addresses pointed back at the proxy. Relative ones resolve there by themselves.
    - Redirects go back to ffmpeg, rewritten, so each hop passes the same checks.
    - ffmpeg's `-cookies` with a domain was tried and dropped: it sent the cookie to every host or to none.
    - *Cost if wrong:* a site whose segments need its cookie on a different registrable domain won't play. The log says the site refused.
32. **An HLS master plays its best variant:** the tallest video, then the highest bandwidth, with that variant's own audio and any shared renditions. ffprobe lists every variant's streams, and the first was often the smallest. Only that variant is fetched.
33. **HLS segments may be named anything** (`-extension_picky 0`, for HLS inputs only; ffmpeg rejects the option elsewhere). The protocol list and the proxy cover what the check was for.
34. **A silent site is given up on**: 20 seconds in the proxy, 30 in ffmpeg (`-rw_timeout`). The helper waits up to 5 minutes for the app's answer, since a slow site can take a while to be ready for the TV.
35. **Live streams restart at their live edge.** A network change or another audio track starts the new session there, not as far in as the clock has run. Control Center's and the media keys' skips and seeks do nothing for them.
36. **Variants found later are still variants**: an HLS playlist in a subfolder of a master's folder, fetched from the master's frame and host, is linked to it whenever it comes, so a change of quality mid-film doesn't add a second "master". Candidates are dropped by how recently they were active, not first seen.
37. **The bridge leaves another copy's socket alone.** A second copy of the app (a development build beside the installed one) doesn't take over a socket that answers. On quit, the app removes only its own socket file. Requests arriving while the app quits are answered "Paper Plane is quitting".
38. **No manifests from a translocated app.** An app opened where it was downloaded runs from a temporary path that goes away. It writes no manifests until moved to Applications.
39. **The extension does no work for nothing.** Unchanged state isn't saved, and an unchanged button isn't redrawn. Activity is noted at most every 5 seconds. Frames report only `<video>` events, say when they leave, and send at most 20 videos. Prerendered pages don't clear the tab.
40. **The toolbar button opens the popup by default** (`default_popup`). It sends at a click only once one video is the clear choice, so a page the extension hasn't seen yet still explains itself.

Deferred, with costs:
- **Resting web streams.** Through the proxy, an HLS session could be rested safely, since each segment is its own request. A progressive file would need backpressure on its download. Until then a long web video is converted ahead as fast as the site allows, bounded by deleting what's behind.
- **Playlists' variants by parsing the master** in the extension, instead of folder and timing heuristics.
- **`<video>` inside shadow roots** is invisible to the content script, so for such players there's no pause and the start time is 0.
