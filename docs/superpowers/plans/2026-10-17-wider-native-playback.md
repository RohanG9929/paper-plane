# Wider Native Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Widen Paper Plane's native (no-re-encode) stream support — add DASH (`.mpd`), cap track selection at 1080p so it copies instead of re-encoding, let the toolbar button fall back to yt-dlp on any site, and carry the `Authorization` header.

**Architecture:** The bundled ffmpeg gains libxml2 so it reads DASH; DASH flows through the same proxy→probe→plan→HLS→AirPlay pipeline as HLS (the proxy already rewrites DASH manifests). A shared representation chooser caps at ≤1080p and prefers a copyable codec. The extension and app grow two small reach-wideners (any-site page fallback; Authorization).

**Tech Stack:** Swift 6 (PaperPlaneCore, PaperPlaneUI, Swift Testing), the static ffmpeg build (bash + meson/autotools), the Manifest V3 TypeScript extension, yt-dlp.

**Spec:** `docs/superpowers/specs/2026-10-17-wider-native-playback-design.md` (read it; this plan argues from it).

## Global Constraints

- **Platform:** macOS 14+, Apple Silicon. Swift 6 strict concurrency; app/helper build with warnings-as-errors (project settings). ffmpeg stays static arm64, GPL-3.0 (`--enable-gpl --enable-version3`); libxml2 is MIT.
- **Native quality:** copy H.264/HEVC; re-encode only what AirPlay can't carry. Never re-encode a stream that has a copyable ≤1080p representation.
- **Security posture unchanged:** ffmpeg reaches the web only through the 127.0.0.1 proxy; protocol whitelist stays `https,http,tls,tcp,crypto,data`; headers (incl. the new `Authorization`) forward **same-site only** (`Site.same`); logs redact cookies, `Authorization`, and URL queries (`Redaction` already covers `authorization`).
- **Fail closed, never hang:** an encrypted/DRM manifest or an unfetchable segment ends with a plain message, not a spinner.
- **Copy:** plain user-facing English; never name any employer.
- **Commits:** repo identity (`rohang9929@gmail.com`); end each message with the `Co-Authored-By:` line the session's attribution reminder gives. Nothing is pushed without the owner.
- **CI:** Xcode 26.6 pin, parallel tests with scaled timing bounds, ffmpeg cache saved right after build — all unchanged; only the ffmpeg cache **key** changes (it hashes `build-ffmpeg.sh`), so CI rebuilds ffmpeg once.

## Review Focus

1. **A DASH manifest offering 4K + 1080p** must land on the 1080p **copy** path, not re-encode the 4K rep. Pinned by `capsAFourKManifestToACopyable1080p` (Task 2).
2. **An encrypted/DRM `.mpd`** (CENC) must surface a clear "protected" message, not hang. Pinned by `anEncryptedManifestFailsClearly` (Task 3).
3. **A DASH manifest's separate video+audio** must play as one input, with sound. Pinned by `aDashStreamPlaysWithAudio` (Task 3).
4. **The "try this page" fallback on a site yt-dlp can't resolve** must fail with a clear message and leave what's playing alone. Pinned by `anUnresolvablePageFromTheButtonSaysWhy` (Task 5).
5. **An `Authorization`-gated stream whose segments sit on another host** must not send the token cross-site. Pinned by `authorizationIsWithheldCrossSite` (Task 6).

---

### Task 1: A DASH-capable bundled ffmpeg (libxml2)

**Files:**
- Modify: `scripts/build-ffmpeg.sh` (the libxml2 source entry, its build block, `--enable-libxml2`) — **already edited and spike-validated in the working tree; this task commits and guards it**.
- Modify: `scripts/check-ffmpeg.sh` (assert the capability).

**Interfaces:**
- Produces: a `vendor/ffmpeg/bin/ffmpeg` whose `-buildconf` contains `--enable-libxml2` and whose `-demuxers` lists `dash`.

- [ ] **Step 1: Add a capability check to `scripts/check-ffmpeg.sh`** — alongside the existing `configured`/`filter`/`protocol` assertions, assert `configured "--enable-libxml2"` and that `ffmpeg -demuxers` includes a line matching `^ *D.* dash `. Expected message on failure names "dash".
- [ ] **Step 2: Run the check against the already-built ffmpeg** — `scripts/check-ffmpeg.sh`. Expected: PASS (the working-tree ffmpeg was built with libxml2 in the spike).
- [ ] **Step 3: Commit** the `build-ffmpeg.sh` + `check-ffmpeg.sh` changes — `build: ffmpeg with libxml2 for DASH`.

**Built:** f14cecc.

### Task 2: Cap representation selection at ≤1080p, preferring a copyable codec

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Media/MediaInfo.swift` (`keepingBestVariant()`, ~lines 134-140; add a copyable-codec helper).
- Test: `core/Tests/PaperPlaneCoreTests/MediaInfoTests.swift` (create if absent, else add).

**Interfaces:**
- Consumes: `VideoTrack` (`codec`, `width`, `height`, `pixelFormat`, `variant: Int?`), and the copyable rule (codec ∈ {`.h264`,`.hevc`} with a pixel format in `ConversionPlanner`'s `copyablePixelFormats`). Share that set rather than duplicating it (expose it, or a `VideoTrack.isCopyPlayable` helper).
- Produces: `MediaInfo.keepingBestVariant()` with the new selection; same signature.

- [ ] **Step 1: Write the failing tests.**

```swift
// Variants: 2160p h264, 1080p h264 (copyable), 1080p vp9, 720p h264. All with variant bitrates.
@Test func capsAFourKManifestToACopyable1080p() {
    let kept = Self.multiRep.keepingBestVariant()
    #expect(kept.video.count == 1)
    #expect(kept.video.first?.height == 1080)
    #expect(kept.video.first?.codec == .h264)        // the copyable 1080p, not the 2160p, not the 1080p vp9
}
@Test func withNothingUnder1080pItKeepsTheSmallestOverCap() {
    // Only 2160p and 1440p offered → keep 1440p (smallest over the cap), to re-encode the least.
    #expect(Self.allOver1080.keepingBestVariant().video.first?.height == 1440)
}
@Test func aVerticalVideoIsCappedByItsShorterSide() {
    // 1080x1920 (shorter side 1080) is kept; 2160x3840 is not.
    #expect(Self.verticalReps.keepingBestVariant().video.first?.width == 1080)
}
@Test func withNoVariantsItIsUnchanged() {
    #expect(Self.single.keepingBestVariant().video.count == Self.single.video.count)
}
```

- [ ] **Step 2: Run to verify they fail** — `scripts/test-core.sh --filter MediaInfo`. Expected: FAIL (old logic picks the 2160p).
- [ ] **Step 3: Implement the new selection in `keepingBestVariant()`.** Among variant tracks, consider only those with `min(width, height) <= 1080`; if none, consider all. Pick the best by the key, maximized: **(height, isCopyPlayable ? 1 : 0, variant bandwidth)** — tallest within the cap, then prefer a copyable codec among equal heights, then highest bandwidth. Keep that video track (and the shared/ matching audio, as today). Tracks without a `variant` leave `MediaInfo` unchanged.
- [ ] **Step 4: Run to verify they pass.** Also run the existing HLS variant test (`playsTheBestVariantOfAMasterPlaylist` in the media suite) to confirm no regression.
- [ ] **Step 5: Commit** — `feat(core): cap variant selection at 1080p, preferring a copyable codec`.

**Built:** 826b27d. When nothing is within the cap, it keeps the smallest one over it.

### Task 3: Accept DASH end to end

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Media/ResolvedInput.swift` (replace `isHLS: Bool` with `manifest: ManifestKind`), and every caller.
- Modify: `core/Sources/PaperPlaneCore/Bridge/BridgeMessages.swift` (`PlayRequest.input`: map `.hls`→`.hls`, `.dash`→`.dash`), `core/Sources/PaperPlaneUI/PlaybackController.swift` (`refusal`: drop the `.dash` case), `core/Sources/PaperPlaneCore/Pages/Links.swift` (`direct`: `.mpd`→DASH input).
- Modify: `scripts/make-test-media.sh`, `scripts/check-test-media.py` (a DASH asset).
- Test: `core/Tests/PaperPlaneCoreTests/ResolvedInputTests.swift`, `WebProxyTests.swift`, and a media test (`PipelineTests` or `TranscoderMediaTests`).

**Interfaces:**
- Consumes: Task 2's selection; the existing `WebProxy`/`ManifestRewriter` DASH handling.
- Produces: `enum ManifestKind: Sendable { case none, hls, dash }`; `ResolvedInput.Input(url:headers:manifest:)` (default `.none`). `ffmpegOptions` applies `-extension_picky 0` only for `.hls`. `PlayRequest.input` and `Links.direct` build `.dash` inputs for DASH.

- [ ] **Step 1: Write the failing tests.**
  - `ResolvedInputTests.aDashInputIsAWebManifestWithoutExtensionPicky` — a `.dash` input's `ffmpegOptions` contain the web protocol whitelist and its headers, but **not** `-extension_picky` (that's HLS-only); an `.hls` input still has it.
  - `LinksTests.aDotMpdLinkPlaysAsDash` — `Links.direct(.../x.mpd)` returns a `.dash` `ResolvedInput`.
  - `PlaybackControllerTests.aDashStreamIsNoLongerRefused` — `PlaybackController.refusal(of: .stream(url, .dash, headers:))` is `nil`.
  - Media test `aDashStreamPlaysWithAudio` (needs ffmpeg + the new DASH asset): the pipeline plays the local DASH asset, producing video **and** audio output AVFoundation accepts.
  - Media test `anEncryptedManifestFailsClearly` — a CENC/encrypted `.mpd` ends in the protected-content message (reuse the HLS/DRM message path), not a hang.
- [ ] **Step 2: Run to verify they fail** — `scripts/test-core.sh --filter ResolvedInput --filter Links --filter PlaybackController`.
- [ ] **Step 3: Implement.** Add `ManifestKind`; migrate `isHLS`→`manifest` across callers and tests; `ffmpegOptions` gates `-extension_picky 0` on `.hls`; `PlayRequest.input` and `Links.direct` produce `.dash`; remove the `.dash` refusal. Add a DASH asset to `make-test-media.sh` (`ffmpeg -f dash`, H.264+AAC, ≥2 reps so Task 2's cap is exercised) and its check to `check-test-media.py`. For the encrypted case, confirm ffmpeg's failure maps to the existing protected-content message; if the manifest uses `xlink:href`/`<Location>` to an external host, verify ffmpeg does not fetch it outside the proxy (fails closed) — add an assertion or a note in the test.
- [ ] **Step 4: Run to verify they pass**, then the full `scripts/test-core.sh`.
- [ ] **Step 5: Commit** — `feat: play DASH streams natively`.

**Built:** 1dbad8e, then 256e5b6 for scheme-relative `xlink:href` in manifests. An encrypted `.mpd` is refused when it's probed, before ffmpeg copies anything.

### Task 4: yt-dlp returns DASH as one manifest input

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Pages/YtDlpCommand.swift` (`readable`: drop the dash exclusion), `core/Sources/PaperPlaneCore/Pages/YtDlpOutput.swift` (collapse a DASH result to one `.mpd` input).
- Test: `core/Tests/PaperPlaneCoreTests/YtDlpCommandTests.swift`, `YtDlpOutputTests.swift` (+ a DASH fixture under `Fixtures/yt-dlp/`).

**Interfaces:**
- Consumes: `ManifestKind.dash` (Task 3).
- Produces: a DASH `-J` answer → one `ResolvedInput.Input(url: manifestURL, headers:, manifest: .dash)`.

- [ ] **Step 1: Write the failing tests.**
  - `YtDlpCommandTests.dashIsNoLongerExcluded` — `readable` no longer contains `protocol!*=dash`; still contains the rtmp/rtsp/mms/ism/f4m/websocket/mhtml exclusions.
  - `YtDlpOutputTests.aDashResultIsOneManifestInput` — a `-J` fixture whose `requested_formats` are DASH (shared `manifest_url`, `protocol: http_dash_segments`) yields a single `.dash` input at the `manifest_url` (deduped), with the format's `http_headers`.
  - Keep `YtDlpOutputTests` green for the existing non-DASH (separate video+audio, progressive) cases.
- [ ] **Step 2: Run to verify they fail** — `scripts/test-core.sh --filter YtDlp`.
- [ ] **Step 3: Implement.** Drop `[protocol!*=dash]` from `readable`. In `YtDlpOutput`, when the chosen formats are DASH, emit one input from the common `manifest_url` (dedupe by it) marked `.dash`, rather than one input per representation. Add the DASH fixture (hand-written from yt-dlp's documented fields, as the others are — no network).
- [ ] **Step 4: Run to verify they pass**, then the full suite.
- [ ] **Step 5: Commit** — `feat: let yt-dlp return DASH, fed to ffmpeg as one manifest`.

**Built:** c67c252.

### Task 5: Toolbar button falls back to yt-dlp on any site

**Files:**
- Modify (app): `core/Sources/PaperPlaneUI/PlaybackController.swift` (`refusal`: drop the "only YouTube pages from the browser" case so any `.page` is accepted).
- Modify (extension): `extension/src/view.ts` (`plan`/`popupState`/`button`), the popup copy, `extension/src/message.ts` if needed.
- Test: `core/Tests/PaperPlaneUITests/PagePlaybackTests.swift` (or `BrowserPlaybackTests`), `extension/test/view.test.ts`.

**Interfaces:**
- Consumes: the existing `.page` → yt-dlp path (`start(page:)`).
- Produces: a non-YouTube `.page` from the bridge resolves via yt-dlp; the extension popup offers "try this page" on any `http(s)` page while the button stays quiet when nothing is sniffed.

- [ ] **Step 1: Write the failing tests.**
  - App: `aNonYouTubePageFromTheButtonResolvesViaYtDlp` — `PlaybackController.refusal(of: .page(nonYouTubeURL, headers:))` is `nil`, and playing it calls `resolvePage`.
  - App: `anUnresolvablePageFromTheButtonSaysWhy` — when yt-dlp can't resolve such a page, the remote shows the page-origin "couldn't find a video" message and what was playing is unaffected.
  - Extension (`view.test.ts`): on a non-YouTube page with no sniffed stream, `plan` keeps the button quiet (`kind: "none"`, icon idle) but `popupState` offers a "try this page" row/action; on a YouTube video page the existing one-click send is unchanged.
- [ ] **Step 2: Run to verify they fail** — `scripts/test-core.sh --filter PagePlayback`; `cd extension && npm test`.
- [ ] **Step 3: Implement.** Drop the YouTube-only `.page` refusal (the page's own address still governs the local-network rule). In `view.ts`, add the popup "try this page" action for any `http(s)` page, keeping the button idle-looking when nothing is sniffed; wire it to send a `.page` message. Plain popup copy (e.g. "Try to get this page's video").
- [ ] **Step 4: Run to verify they pass** (both suites); regenerate any snapshot the popup change touches.
- [ ] **Step 5: Commit** — `feat: the toolbar button can try any page through yt-dlp`.

**Built:** 7302313. A page that yt-dlp can't make a video of fails with why, but it replaces what was playing first, as a copied link does (Review Focus 4 assumed otherwise).

### Task 6: Carry the Authorization header

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Bridge/BridgeMessages.swift` (`PlayRequest.allowedHeaders`: add `Authorization`), `extension/src/tabs.ts` (`pickHeaders` allow-list: add `authorization`).
- Test: `core/Tests/PaperPlaneCoreTests/BridgeMessageTests.swift`, `WebProxyTests.swift`, `extension/test/tabs.test.ts`.

**Interfaces:**
- Consumes: the proxy's same-site forwarding (`Site.same`) and existing redaction of `authorization`.
- Produces: `Authorization` captured by the extension and forwarded by the app to same-site fetches only.

- [ ] **Step 1: Write the failing tests.**
  - `BridgeMessageTests.authorizationIsKept` — a `PlayRequest` with an `Authorization` header keeps it (case-insensitive), alongside Cookie/Referer/Origin/User-Agent.
  - `WebProxyTests.authorizationIsWithheldCrossSite` — the proxy sends `Authorization` to a same-site segment fetch and **not** to a cross-site one (mirrors the existing cookie test `passesTheCookieOnlyToTheStreamsOwnSite`).
  - `tabs.test.ts` — `pickHeaders` keeps `authorization` and still drops unlisted headers.
- [ ] **Step 2: Run to verify they fail** — `scripts/test-core.sh --filter BridgeMessage --filter WebProxy`; `cd extension && npm test`.
- [ ] **Step 3: Implement** the two allow-list additions.
- [ ] **Step 4: Run to verify they pass** (both suites); confirm no new logging of the header (redaction already covers it).
- [ ] **Step 5: Commit** — `feat: carry the Authorization header to same-site stream fetches`.

**Built:** 8b371a5.

### Task 7: Docs and Sony rows

**Files:**
- Modify: `README.md` (DASH now plays; the toolbar button can try any page; token-authed streams), `docs/sony-test-results.md` (new rows), this plan (a short "Built" note per task).

- [ ] **Step 1:** README — add DASH to what plays natively; note the toolbar button offers "try this page" on any site; note `Authorization`-authed streams. Keep the honest boundary (locked streams stay out). No employer named.
- [ ] **Step 2:** Sony rows — a DASH site plays on the Sony; a token-authed self-hosted stream plays; the toolbar button on a non-YouTube yt-dlp site plays; an encrypted `.mpd` shows the protected message. Each Result "Needs the owner …".
- [ ] **Step 3: Commit** — `docs: DASH, the any-site button, and Authorization`.

## Self-Review

**Spec coverage.** §4.1 DASH → Tasks 1 (ffmpeg), 3 (accept), 4 (yt-dlp); the 1080p-cap selection → Task 2; §4.2 toolbar fallback → Task 5; §4.3 Authorization → Task 6; §8 testing + Sony → folded into each task + Task 7. Non-goals (detection breadth, more browsers, Deno, AES-128) are correctly absent. §6 decisions all realized: libxml2 build (1), 1080p+copy cap (2), one `.mpd` input (4), popup-not-button UX (5), two-line auth (6).

**Step scan.** Each step writes one thing: a named test with assertions, a signature + the pinned rule (the selection key in Task 2; the `ManifestKind` gate in Task 3), or a command with its expected result. No bare "handle edge cases." The only code block is Task 2's test and the selection key, which the signature doesn't determine.

**Type consistency.** `ManifestKind{none,hls,dash}` is defined in Task 3 and consumed in Tasks 3/4; `keepingBestVariant()` keeps its signature (Task 2); `allowedHeaders`/`pickHeaders` names match across Task 6; `refusal` is edited in Tasks 3 (DASH) and 5 (page) without collision.

**Review Focus.** All five have an owning test: 4K→1080p (T2), encrypted `.mpd` (T3), DASH audio (T3), unresolvable page (T5), cross-site Authorization (T6).

**Proportion.** The plan is interfaces, test names and the two pinned rules — not code bodies. It's close to the spec's length, longer only where the spec deferred specifics (the selection key, the `ManifestKind` migration) that the implementer couldn't otherwise guess.
