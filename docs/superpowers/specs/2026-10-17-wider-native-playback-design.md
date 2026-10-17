# Paper Plane — Wider native playback (design)

**Date:** 2026-10-17
**Status:** Draft for the owner's review
**Builds on:** the design spec (2026-10-15), Milestone 4's decisions, and the shipped v0.1.0.

## 1. Intent

Paper Plane should play, at **native quality (no re-encode)**, as many of the videos a person has a right to watch as possible — the ones they browse to, the links sent to them, the streaming and adult sites they use. Today it plays HLS and progressive MP4/WebM, and routes any pasted link through yt-dlp (~1,800 sites). This project widens that native path to the formats, auth and entry points that currently miss, so "throw any video at your TV" holds for far more of the real web.

**The owner's words:** "widen the native path and make sure that it works in as many scenarios as possible … adult websites, random streaming sites, videos I've been sent."

**The honest boundary (unchanged):** this widens the path for streams that aren't deliberately locked against playback. Sites that encrypt the stream URL in-page, bind it to a single-use/session token, or use DRM stay out — getting those to a second player means circumventing their access controls, which Paper Plane does not do. Everything in this project is the legitimate native path reaching more of what *doesn't* fight it. For the locked minority, the only non-circumventing option is screen-capture mirroring, which the owner has declined on quality grounds and is out of scope here.

**Success looks like:** a DASH stream (the format much of modern streaming and many adult sites use) plays on the TV at native quality; clicking the extension's toolbar button on a yt-dlp-supported site works as well as pasting its link does; and a legitimately token-authed stream (self-hosted, API-based) plays because its `Authorization` header is carried through.

## 2. Goals, non-goals, anti-goals

**Goals** (this project):
- **DASH (`.mpd`) playback**, native quality, via both the extension (a detected DASH stream) and a pasted/sent link or page (yt-dlp) — including **capping representation selection at ≤1080p with a copy-codec preference** so DASH (and HLS) land on the native copy path instead of re-encoding a 4K rep.
- **A toolbar-button fallback to yt-dlp on any site** (via the popup's "try this page" action), so the button reaches everything a pasted link already does — without the button falsely looking "ready" on every site.
- **Carry the `Authorization` header** from the extension (same-site only; redaction already covers it), so a token-authed sniffed stream plays. (The pasted-link case already works.)

**Non-goals** (worthwhile, explicitly deferred to follow-on work, not this project):
- Broadening stream **detection** for odd content-types in the extension's classifier.
- **More Chromium browsers** (Arc, Edge, Vivaldi, Opera) reusing the extension; a Firefox/Safari port.
- **Bundling a JavaScript runtime (Deno)** so YouTube works without `brew install deno`.
- Verifying/hardening **encrypted HLS (AES-128 / SAMPLE-AES) key fetches** end to end.
- Re-encoding avoidance for AV1/VP9 — impossible, since AirPlay only carries H.264/HEVC.

**Anti-goals** (failure even if it technically works):
- Anything that defeats a site's stream lock (single-use tokens, in-page URL decryption, DRM).
- Regressing the security posture: the page-address local-network rule (decisions 12, 22), ffmpeg's protocol whitelist, same-site-only header forwarding, and cookie/query redaction in logs all stay exactly as they are.
- Shipping DASH that silently re-encodes H.264/HEVC content it could have copied.

## 3. Current state (what the recon found)

- **Plays natively:** HLS (`.m3u8`) and progressive MP4/WebM/MOV/M4V. H.264 (8-bit) and HEVC (8/10-bit) are copied; other codecs re-encode (unavoidable for AirPlay).
- **Any pasted/dragged link already goes through yt-dlp** (not just YouTube) via `playLink` → `start(page:)`. The YouTube-only restriction is *only* on the extension bridge path (`PlaybackController.refusal`: "takes only YouTube pages from the browser").
- **DASH is blocked at three layers:** `PlaybackController.refusal` rejects a `.dash` stream; `YtDlpCommand.readable` excludes `[protocol!*=dash]`; and the bundled ffmpeg is built **without libxml2**, so it can't demux `.mpd` (`ffmpeg -buildconf` shows no libxml2; only `webm_dash_manifest` exists, not the general dash demuxer). The **proxy already has DASH manifest handling** (`ProxyRoute`/`ManifestRewriter` rewrite `application/dash+xml` and `.mpd`), and the extension already *detects* DASH (`classify.ts` → `"dash"`) — so the groundwork is half-laid; the blockers are ffmpeg, the refusal, and the yt-dlp exclusion.
- **Forwarded headers:** `PlayRequest.allowedHeaders = [Cookie, Referer, Origin, User-Agent]`. No `Authorization`. The proxy forwards these to **same-site fetches only** (`Site.same`); cross-site gets User-Agent only.

## 4. The work

### 4.1 DASH playback

**Spike result (2026-10-17), which settles the approach.** I added libxml2 to `scripts/build-ffmpeg.sh` and rebuilt: the build succeeds, `ffmpeg -buildconf` shows `--enable-libxml2`, and `-demuxers` now lists the general `dash` demuxer. Probing a real multi-bitrate `.mpd` (`dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd`) showed:
- ffmpeg exposes **every representation as its own stream** in one program — 10 video reps (180p→2160p) plus the audio — and does *not* pre-select one.
- Each rep carries `width`, `height`, `bit_rate`, **and a `variant_bitrate` tag** — the exact tag `FFprobeParser`/`MediaInfo.keepingBestVariant()` already read for HLS. So the variant model transfers; DASH doesn't need a parallel selection system.
- Video and audio live in the **same manifest**, so a DASH input is **one** ffmpeg input, not two.

So the work:

**Make the bundled ffmpeg read DASH** — done in the spike and kept: libxml2 (2.13.5, pinned + SHA-256) as a static dep, `--enable-libxml2` on the ffmpeg configure. This changes the CI ffmpeg **cache key** (`hashFiles('scripts/build-ffmpeg.sh')`), so CI rebuilds ffmpeg once. *My call:* ffmpeg+libxml2, not an in-app DASH→HLS converter — smallest change, one media engine, and the proxy already rewrites DASH manifests so ffmpeg reads them through the same security-checked path as HLS.

**Cap representation selection at 1080p, preferring a copyable codec — the one real code change the spike surfaced, and it fixes HLS too.** `keepingBestVariant()` currently takes `.max { (height, bandwidth) }` with **no resolution cap**, so on the probed stream it would pick the **4K** rep and re-encode it to HEVC — when a pristine **1080p H.264** rep is right there to copy. Change the chooser to pick the best variant **≤1080p by the shorter side**, and among equivalent ones prefer a codec Paper Plane copies (H.264/HEVC) over one that would re-encode. This makes DASH land on the native 1080p copy path, and it closes the same latent 4K-re-encode hole for an HLS master.

**Stop refusing DASH.** Remove the `.dash` case from `PlaybackController.refusal`; a detected DASH stream flows into the pipeline like HLS (proxied, rewritten, probed, planned).

**Let yt-dlp return DASH.** Drop `[protocol!*=dash]` from `YtDlpCommand.readable`, and feed ffmpeg the single **`.mpd` manifest URL** for a DASH result (the probe confirms one manifest exposes both tracks — so one input, deduped by `manifest_url`, not two). Keep the other exclusions (RTMP/RTSP/MMS/ISM/f4m/websocket/mhtml).

**Fail closed, not hung:** an encrypted/DRM `.mpd` (CENC) has no key and must surface a clear "this video is protected" message, like the HLS/DRM case. A DASH remote element (`xlink:href`) or `<Location>` fragment must not let ffmpeg fetch outside the proxy — verify ffmpeg's dash demuxer doesn't follow xlink to external hosts (it fails closed) or make the rewriter recognize the fragment; a test pins this.

### 4.2 Let the toolbar button fall back to yt-dlp on any site

Today (confirmed in `extension/src/view.ts`) the button offers to send a *page* only for a YouTube video page (`isYouTubeVideo`); on any other site with no sniffed stream it goes idle, and the app's `refusal` rejects a non-YouTube page anyway. So a site yt-dlp supports but the extension can't sniff — which a pasted link already plays — can't be cast from the button.

**The change, and its one UX decision.** On the app side: drop the YouTube-only restriction so a `.page` from the extension goes to yt-dlp for any site, exactly as a pasted link does (the page's own address still governs the local-network rule, decision 12). On the extension side, the UX must *not* make the button light up "ready" on every website and then spin-and-fail — that would be worse than idle. *My call:* keep the button's quiet/idle look when nothing is sniffed, but have its **popup** offer a one-click "Try to get this page's video" action on any `http(s)` page. The capability is one click away everywhere, without the button claiming every page is castable. Files: `view.ts` (the plan/button/popup), the popup copy, `message.ts`, and the app-side `refusal`; tests for each.

This is consistent with pasted links and with the simplified no-extension path on the parked `feature/play-from-browser` branch. The parked branch is a *different* mechanism (app-driven AppleScript "browser look") and isn't reused here.

### 4.3 Carry the Authorization header

For a **pasted link this already works** — yt-dlp discovers the stream's `Authorization`/Bearer header itself, `YtDlpOutput` keeps it, and the proxy forwards it same-site (and `Redaction` already masks `authorization`/`proxy-authorization` in logs — so no redaction work is needed). The gap is only the **extension sniffed-stream** path: the extension's header allow-list (`extension/src/tabs.ts`) captures `{cookie, referer, origin, user-agent}` and drops `Authorization`, and the app's `PlayRequest.allowedHeaders` doesn't list it. The change is two lines — add `authorization` to the extension's `pickHeaders` allow-list and to `allowedHeaders` — forwarded under the same same-site rule as Cookie so a token never leaves the stream's own site. A token-authed stream whose segments sit on a *different* host still won't carry the header there (same-site rule, same as cookies, deliberate).

## 5. Constraints

- macOS 14+, Apple Silicon, not sandboxed. The bundled ffmpeg stays GPL-3.0-compatible (libxml2 is MIT — fine).
- **Security posture unchanged:** page-address local-network rule, protocol whitelist (`https,http,tls,tcp,crypto,data`), same-site-only header forwarding, and log redaction (now including `Authorization`) all hold. DASH manifests go through the same proxy and rewriter as HLS, so every hop keeps its checks.
- **Native quality only:** copy H.264/HEVC; re-encode only what AirPlay can't carry. No screen-capture path in this project.
- Repo is public, personal identity on commits, nothing is pushed without the owner; releases via the `v*` tag workflow. yt-dlp and ffmpeg stay bundled.
- CI (Xcode 26.6 pin, the Binding-closure rule, warnings-as-errors in the project settings, scaled timing bounds) is unchanged; only the ffmpeg cache rebuilds once.

## 6. Decisions I made (flagged for the owner's check)

1. **DASH via ffmpeg+libxml2** (spike-validated), not an in-app DASH→HLS converter (§4.1).
2. **Representation selection caps at ≤1080p with a copy-codec preference**, in the shared `keepingBestVariant()` — improving HLS as well as DASH (§4.1).
3. **A DASH input is one ffmpeg input** (the `.mpd`), deduped by `manifest_url` for the yt-dlp path (§4.1, spike-confirmed).
4. **The toolbar button stays quiet when nothing is sniffed; the popup offers "try this page" on any site** — rather than lighting the button "ready" everywhere (§4.2).
5. **`Authorization` added to the extension + app allow-lists**; redaction already exists and the pasted-link case already works (§4.3).
6. **Detection breadth, more browsers, Deno, and AES-128 verification are follow-ons**, not this project (§2).

## 7. Left to the builder

- The precise `keepingBestVariant()` cap logic (shorter-side ≤1080 vs height; tie-break to copyable codec) and its tests across HLS and DASH inputs.
- The exact `YtDlpOutput` change to collapse a DASH result to one `.mpd` input (dedupe by `manifest_url`), confirmed against real yt-dlp `-J`.
- Whether `ResolvedInput.Input` needs a manifest flag beyond `isHLS` for DASH (e.g. a generalized `isManifest`) so `-extension_picky 0` and rewriting apply; name it accordingly.
- Exact user-facing message for an encrypted/DRM `.mpd`, and the xlink/`<Location>` fail-closed check (§4.1).
- The popup copy for the "try this page" action (§4.2).

## 8. Testing

- **Test media:** add a DASH asset to `scripts/make-test-media.sh` (an `.mpd` with fMP4 segments, H.264+AAC so it's copy-path), checked by `scripts/check-test-media.py`.
- **Unit/integration:** DASH plays through the pipeline (copy path and re-encode path); the proxy rewrites a DASH manifest and serves it; `applesPlayerAcceptsTheMasterPlaylist`-style check that AVFoundation accepts the served DASH output; a DASH stream is no longer refused; yt-dlp's format filter admits DASH; the `Authorization` header is forwarded same-site and withheld cross-site and never appears in a saved log; the extension page path reaches yt-dlp for a non-YouTube page.
- **CI:** the ffmpeg cache rebuilds once (new key); confirm `ffmpeg -buildconf` shows libxml2 and `-demuxers` shows `dash`.
- **Sony rows** (`docs/sony-test-results.md`): a DASH site plays; a token-authed self-hosted stream plays; the toolbar button on a non-YouTube yt-dlp site plays.

## 9. Risks

- **ffmpeg + libxml2 build** adds a dependency and a one-time longer CI build; a static libxml2 on the Apple Silicon toolchain is routine but must be verified (`-buildconf`).
- **DASH variety** — multi-period, SegmentTemplate vs SegmentList, trick-play tracks — ffmpeg handles the common cases; exotic manifests may still fail and should fail cleanly.
- **Encrypted DASH (CENC)** must produce a clear "can't play (protected)" message, not a hang — same discipline as the HLS/DRM case.
- Dropping the YouTube-only page restriction means the toolbar button attempts more sites; it attempts nothing the copied-link path didn't already, so the blast radius is just "more pages go to yt-dlp," which is the point.
