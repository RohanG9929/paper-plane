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
- **DASH (`.mpd`) playback**, native quality, via both the extension (a detected DASH stream) and a pasted/sent link or page (yt-dlp).
- **Unify the extension's page path with the copied-link path:** a page the extension can't sniff a stream on goes to yt-dlp for *any* site, not only YouTube — so the toolbar button covers everything a pasted link already does.
- **Carry the `Authorization` header** (same-site only, never logged), so a legitimately token-authed stream plays.

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

**Make the bundled ffmpeg read DASH.** Add **libxml2** as a static dependency in `scripts/build-ffmpeg.sh` (it has a meson build; pin a version + SHA-256 like the other deps) and add `--enable-libxml2` to the ffmpeg configure. That enables ffmpeg's general `dash` demuxer. *My call:* rebuild ffmpeg with libxml2 rather than converting DASH to HLS in-app — it's the smallest change, keeps ffmpeg as the one media engine, and the proxy already rewrites DASH manifests so ffmpeg reads them through the same proxied, security-checked path as HLS. This changes the CI ffmpeg **cache key** (it's `hashFiles('scripts/build-ffmpeg.sh')`), so CI rebuilds ffmpeg once.

**Stop refusing DASH.** Remove the `.dash` case from `PlaybackController.refusal` so a detected DASH stream flows into the pipeline like HLS. The input is marked as a manifest the proxy rewrites; probing and planning are unchanged (ffmpeg abstracts the container — it reads the `.mpd`, exposes video+audio tracks, and the planner copies H.264/HEVC or re-encodes as always).

**Let yt-dlp return DASH.** Drop `[protocol!*=dash]` from `YtDlpCommand.readable`. *Builder decision, with my lean:* when yt-dlp's chosen format is DASH, prefer feeding ffmpeg the **manifest URL** (`.mpd`) so ffmpeg does the DASH work (consistent with the HLS path and the proxy), rather than yt-dlp's per-segment `http_dash_segments`. Confirm against yt-dlp's `-J` fields (`manifest_url`, `protocol`). Keep the other exclusions (RTMP/RTSP/MMS/ISM/f4m/websocket/mhtml) — ffmpeg still can't use those.

**Behavioral notes:** DASH frequently carries VP9/AV1 (re-encode, unavoidable) and often HEVC/H.264 (copy). Multi-period and encrypted (CENC/DRM) DASH: a DRM `.mpd` simply won't play (no keys) and must fail with a clear message, not hang.

### 4.2 Unify the extension's page path with yt-dlp

Today a page the extension can't sniff a stream on is sent to the app as a `.page`, and the controller refuses any non-YouTube page. Change the bridge/controller so a `.page` from the extension goes to yt-dlp for **any** site, exactly as a pasted link already does. *My call:* this is consistent with the existing copied-link behavior and with the simplified Play-from-Browser work on the parked branch; the extension only ever sends a page the user clicked, so it doesn't widen what the app will attempt beyond what paste already allows. The page's own address still governs the local-network rule (decision 12). The "only YouTube from the browser" message goes away.

### 4.3 Carry the Authorization header

Add `Authorization` to `PlayRequest.allowedHeaders`, forwarded by the proxy under the **same same-site rule** as Cookie (so a token never leaves the stream's own site), **never logged** (it joins Cookie in redaction). This lets a legitimately token-authed stream — a self-hosted server, an API-based service the user is entitled to — play. Signed query-string URLs already work (the URL carries the signature and the proxy reuses it); this covers the header-based case.

## 5. Constraints

- macOS 14+, Apple Silicon, not sandboxed. The bundled ffmpeg stays GPL-3.0-compatible (libxml2 is MIT — fine).
- **Security posture unchanged:** page-address local-network rule, protocol whitelist (`https,http,tls,tcp,crypto,data`), same-site-only header forwarding, and log redaction (now including `Authorization`) all hold. DASH manifests go through the same proxy and rewriter as HLS, so every hop keeps its checks.
- **Native quality only:** copy H.264/HEVC; re-encode only what AirPlay can't carry. No screen-capture path in this project.
- Repo is public, personal identity on commits, nothing is pushed without the owner; releases via the `v*` tag workflow. yt-dlp and ffmpeg stay bundled.
- CI (Xcode 26.6 pin, the Binding-closure rule, warnings-as-errors in the project settings, scaled timing bounds) is unchanged; only the ffmpeg cache rebuilds once.

## 6. Decisions I made (flagged for the owner's check)

1. **DASH via ffmpeg+libxml2**, not an in-app DASH→HLS converter (§4.1).
2. **Feed ffmpeg the `.mpd` manifest** for a DASH yt-dlp result, not per-segment (§4.1), pending confirmation against real yt-dlp output.
3. **The extension's page path goes to yt-dlp for any site** (§4.2), dropping the YouTube-only restriction, matching the copied-link path.
4. **`Authorization` is forwarded same-site and redacted from logs** (§4.3).
5. **Detection breadth, more browsers, Deno, and AES-128 verification are follow-ons**, not this project (§2).

## 7. Left to the builder

- libxml2's exact pinned version + SHA-256 and its meson options in `build-ffmpeg.sh`.
- The precise yt-dlp `-J` handling for a DASH result (manifest URL vs representation URLs), from the real tool.
- Whether DASH needs any `ResolvedInput`/probe flag distinct from HLS (likely the existing `isHLS`-style manifest handling generalizes; name it accordingly).
- Exact user-facing messages for a DASH stream that can't play (DRM/encrypted `.mpd`).

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
