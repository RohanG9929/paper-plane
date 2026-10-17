# Paper Plane — Milestone 4 decisions (addendum to the design spec)

**Date:** 2026-10-16 (overnight run; the owner pre-approved Plans 3–5)
**Status:** These decisions were taken without the owner, inside the approved spec (§3.1 `YtDlp`, §5.1, §5.3, §5.4, §6, §8 row 4). Each says what it costs if wrong.

Milestone 4 is "Bundled yt-dlp, the update mechanism, the `kind: "page"` path, the menu item". Plan 5 also does the parts of Milestone 5 (first release) that don't need the owner: the README's install steps, a release script, and the Sony rows. The GitHub release, notarization and the Sony checklist stay with the owner.

## yt-dlp itself

1. **Nothing is downloaded or run tonight.** This session never downloads or runs the real yt-dlp. The owner is asleep, and running a freshly downloaded program is their step.
   - The `-J` output the app reads is pinned by hand-written fixtures built from yt-dlp's documented fields: `title`, `is_live`, `start_time`, `requested_formats`, `url`, `protocol`, `http_headers`, `_type`, `entries`. They are not recordings.
   - The fake yt-dlp in the tests is a shell script.
   - *Cost if wrong:* a field reads differently from what the fixtures expect. The first YouTube row on the Sony finds that.
2. **The bundled copy.** `scripts/fetch-yt-dlp.sh` fetches the official `yt-dlp_macos` from the latest release, or from `YTDLP_VERSION` if set.
   - It checks the file against that release's `SHA2-256SUMS` and writes `vendor/yt-dlp/yt-dlp` and `vendor/yt-dlp/VERSION`.
   - The build phase (`scripts/embed-tools.sh`, formerly `embed-ffmpeg.sh`) copies both into `Contents/Helpers/` as `yt-dlp` and `yt-dlp.version`.
   - Debug and Release builds without it warn. `scripts/make-release.sh` refuses to package without it.
   - *Ruling:* the script follows the latest release instead of pinning a version, because this session can't confirm which tags exist. Cost if wrong: two runs on different days bundle different versions; `VERSION` records which.
3. **Which copy runs.**
   - The app runs the newer of two copies: the one it ships, and the one the updater installed in `~/Library/Application Support/Paper Plane/bin/` (`yt-dlp` and `yt-dlp.version`).
   - A development build may fall back to a `yt-dlp` on `PATH` or in Homebrew's folders, as it does for ffmpeg. A release never runs whatever happens to be installed.
   - Versions are read from the `.version` files and compared as numbers (`2026.10.09` < `2026.10.09.1` < `2026.10.10`). A copy is never run just to learn its version.
4. **Updates** (spec §5.3):
   - **When:** at most once a day, in the background at launch, and right after an extraction fails (§6: update and retry once).
   - **What:** the latest tag comes from `https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest`. It must look like a yt-dlp version (`YYYY.MM.DD`, optionally `.N`). The files come only from `https://github.com/yt-dlp/yt-dlp/releases/download/<tag>/`, never from addresses the API names.
   - **Checks:** `yt-dlp_macos` must match its line in that release's `SHA2-256SUMS` and be at most 200 MB.
   - **Install:** the file is written next to the old copy, made executable (0755) in a 0700 folder, and renamed into place. A failed, oversized or mismatched download leaves the old copy as it was.
   - **Switching off:** the defaults key `PaperPlaneUpdatesYtDlp NO` turns updates off. The check scripts pass it, as they pass `PaperPlaneInstallsBrowserHosts NO`.
   - *Cost if wrong:* GitHub itself serving a bad release would be trusted. Checking the release's GPG signature (`SHA2-256SUMS.sig`) is deferred.

## Running it

5. **Cookies reach yt-dlp in memory** (spec §5.3, §5.4). They go through its standard input as a configuration (`--ignore-config --config-locations -`, then `--add-headers 'Cookie:…'`). They never go on its command line, which other processes can read, and never into a file.
   - yt-dlp scopes a `Cookie` header to the page's own domain.
   - Every value is quoted for yt-dlp's shell-like configuration parser, and line breaks and control characters are removed. A test sends hostile cookies (quotes, `#`, newlines, `--plugin-dirs`) through Python's `shlex` and checks that they come back as one argument.
   - *Cost if wrong:* a signed-in-only video asks for sign-in (Sony row Y4).
6. **Only the cookie goes to yt-dlp**, not the browser's User-Agent. yt-dlp chooses its own YouTube clients, each with its own agent. *Cost if wrong:* none known.
7. **Formats.** The `-f` alternatives, in order:
   1. H.264 up to 1080p with separate AAC;
   2. H.264 up to 1080p, combined;
   3. anything up to 1080p, separate;
   4. anything up to 1080p, combined;
   5. anything at all.

   None may be DASH, since ffmpeg can't read it (Milestone 3, decision 10). Video that isn't H.264 or HEVC is re-encoded, as for files. *Cost if wrong:* a site without such formats plays at another quality or is converted.
8. **The command line:**
   ```
   -J --no-playlist --playlist-items 1 --socket-timeout 20
   --cache-dir ~/Library/Caches/Paper Plane/yt-dlp -f <formats>
   --ignore-config --config-locations - -- <url>
   ```
   - The URL comes after `--`, so it can never be taken for an option.
   - yt-dlp runs with `PATH` including `/opt/homebrew/bin` and `/usr/local/bin`, so it finds a JavaScript runtime installed there (Deno). Recent yt-dlp needs one for full YouTube support.
   - It has 60 seconds, and stopping the playback stops it.
   - *Cost if wrong:* without Deno, YouTube may offer fewer formats or none (Sony row Y1 says what to do).
9. **What a result becomes.**
   - **Inputs:** one or two ffmpeg inputs, from `requested_formats`, or else the top-level format. A playlist gives its first entry. Each format's `http_headers` travel with its input, through the proxy, under its same-site rules.
   - **Refused:** only `http`/`https` URLs with protocol `https`, `http`, `m3u8` or `m3u8_native` are taken. Anything else is refused, and `m3u8` is read as HLS.
   - **Title:** yt-dlp's `title` replaces the tab's.
   - **Start:** the browser's time, else yt-dlp's `start_time` (a link's `t=`), else 0.
   - **Live:** a live stream is HLS and has no duration, so Milestone 3's live handling applies unchanged.

## Where pages come from

10. **From the browser, only YouTube pages** go to yt-dlp *(superseded 2026-10-17: the app now takes a page from any site and fails with why when yt-dlp can't make a video of it; see the wider-native-playback design, §4.2)*: `https` on `youtube.com`, its subdomains or `youtu.be`, as the extension sends them (§5.1). The app refuses any other page from the bridge, as defence in depth: "Paper Plane takes only YouTube pages from the browser." *Cost if wrong:* none. The extension sends nothing else.
11. **Play Copied Link** (the spec's "Paste a link", named for what it does; design audit, 2026-10-16):
    - **Where:** a menu item (⌘V) and a button under the drop zone. A web link dropped on the window or the menu bar icon does the same.
    - **What it takes:** any `http` or `https` link, trimmed. A link whose path ends in `.m3u8` plays directly as HLS, and `.mp4`, `.m4v`, `.mov`, `.webm` or `.mkv` as a file. Anything else goes through yt-dlp. A video file copied in Finder plays as if dropped.
    - **⌘V** in the remote is Edit ▸ Paste reaching the app, since the remote has no text field to take it.
    - **No link on the clipboard:** a notice, "Copy a link to a video first, then choose Play Copied Link." What's playing carries on.
12. **The page's address decides about the local network.** For a page resolved by yt-dlp, the page's own address decides whether the video may come from this Mac or the local network (`ResolvedInput.page`), not the addresses yt-dlp hands back. A public page can't point ffmpeg at a device on your network; a page on your NAS still plays. *Cost if wrong:* none.

## When it fails (spec §6)

13. **An extraction that fails is retried once, after an update that brought a newer yt-dlp.** This covers a missing yt-dlp and a failed extraction. It doesn't cover the time limit or a cancel, and the same yt-dlp isn't run twice for the same answer. Then the messages are:
    - yt-dlp's reason, the first sentence of its last `ERROR:` line: "Paper Plane couldn't get this video: Private video."
    - "Paper Plane didn't find a video at this link." for an unsupported URL or a playlist with nothing in it, and "Paper Plane can't play this site's kind of stream yet." when only formats ffmpeg can't read are offered.
    - "Paper Plane's YouTube helper is missing. Reinstall Paper Plane." when there's no yt-dlp at all.
    - "The site took too long to answer. Try again." at the 60-second limit.

    The failure log keeps yt-dlp's stderr, redacted like ffmpeg's.
14. **What to do next follows where the video came from.** A site that stops a stream from the browser says "reload the page, then click Paper Plane again"; one from a copied link says "choose Play Copied Link again".

## From the reviews

15. **YouTube pages go to yt-dlp as www.youtube.com** (code review). yt-dlp keeps a header cookie to the exact host it's given and asks www.youtube.com for the video, so a page on m.youtube.com, music.youtube.com, bare youtube.com or youtu.be (`youtu.be/ID` becomes `watch?v=ID`) would lose the sign-in.
16. **yt-dlp is told where the app's ffmpeg is** (`--ffmpeg-location`, code review). It uses ffmpeg to judge which formats can be merged, and a Mac without Homebrew's has none on PATH.
17. **A failed page asks GitHub only once an hour** (code review, simplify). The immediate update after a failure (spec §6) is skipped when a check was made within the hour and there's a copy to run. A link to something that isn't a video (yt-dlp's "Unsupported URL") isn't retried at all. A failure-time check counts as the day's.
18. **⌘V plays a copied link only in the remote** (code review, simplify). Edit ▸ Paste reaches the remote's window; in Settings it does nothing.
19. **A release's tag is kept exactly as released** (simplify). It names the download folder, so `2026.10.09.000915` must not come back as `.915`. Versions still compare as numbers.
20. **The proxy's redirect policy is explicit** (simplify). The web proxy hands every redirect back to ffmpeg; only the updater follows them, over HTTPS. Each caller says which, so no default can turn the proxy's checks off.
21. **yt-dlp runs as its own responsible process** (security review, MEDIUM). It's started with posix_spawn and responsibility disclaimed, in the temporary folder. So neither yt-dlp nor a program another process puts in its place in Application Support (with a `.version` claiming it's newer) can use the Desktop, Documents or Downloads access the user gave Paper Plane. This uses a private call in libsystem (`responsibility_spawnattrs_setdisclaim`), as browsers do for their helpers. Without it the spawn fails closed. A test asks macOS which process is responsible for the running stand-in.
22. **Local fetches need every address of the host to be local** (security review). Any local address still refuses a fetch, but only a wholly local stream (or page) lets its fetches be local, so a public name with one extra 127.0.0.1 record lifts nothing.
23. **Up to 1080p by the shorter side** (Opus). `-S res:1080` replaces the `[height<=1080]` filters, which sent a vertical Short (1080×1920) at 480×854.
24. **Only what ffmpeg reads can be chosen** (Opus). The format filters refuse DASH, RTMP, RTSP, MMS, Smooth Streaming, f4m, websockets and storyboards, so yt-dlp falls through to a playable format instead of returning one Paper Plane must refuse.
25. **No network, an unreachable site and a missing Deno get their own words** (Opus). Offline is said before yt-dlp runs. A transport error is "Paper Plane couldn't reach the site. Check your connection, then try again." yt-dlp's JavaScript-runtime warning becomes "YouTube now needs Deno to give Paper Plane this video. Install it with "brew install deno" in Terminal, then try again." None of these is retried after an update, and Python's "(caused by …)" is cut from reasons.
26. **Stopping doesn't wait for a silent site** (Opus). A request waiting for a site's first answer, in the proxy or the updater, ends when its task is cancelled.
27. **Smaller things from Opus.** A download cut short by a quit or crash is removed before the next. A channel link (a playlist of playlists) and a page with several parts (`multi_video`) play their first video.

Skipped from the reviews, with reasons:
- **A hard kill for yt-dlp's Python child.** PyInstaller's bootloader passes SIGTERM on to it, and a process-group kill needs a spawner of our own. Sony row Y11 (quit while a page is being looked at) shows it.
- **One cancelled caller cancels a shared update download.** It only happens when a page is stopped during the launch check's download; the next launch tries again.
- **The onedir `yt-dlp_macos.zip` build** (faster start than onefile) and **trimming yt-dlp's answer with `-O`**. Both need the real yt-dlp to try.
- **One opt-out key for every check-time side effect**, **a `YtDlpResolver` type** and **one origin type for inputs and messages**. Behaviour-neutral refactors, left for a quieter day.
- **Falling back to the shipped yt-dlp when an updated one can't run at all.** It's rare (yt-dlp's releases are tested), and the next release replaces it.
- **`--no-plugin-dirs`.** It would keep the owner's own yt-dlp plugins out. It can't be tried without the real yt-dlp, an unknown option would stop every page, and only someone who can already run code as the owner can add a plugin.
- **Notarization.** It will need yt-dlp signed with the hardened runtime, and likely `disable-library-validation` for its unpacked Python. That's the owner's release step.
- **Header cookies are a deprecated path in yt-dlp.** If a later yt-dlp refuses them, cookies can go to it through `--cookies` on a pipe instead. Sony row Y4 would show the change.

## Deferred, with costs

- **A JavaScript runtime.** Bundling Deno (about 100 MB) is the owner's call. Until then, YouTube may need `brew install deno`.
- **Expired links.** A page isn't resolved again when its video links expire mid-playback. YouTube's last hours, and the remote says "The site stopped the stream".
- **Other sites' cookies.** Cookies yt-dlp collects for other sites' video addresses (a format's `cookies` field) aren't passed on, so such sites fail with a clear message.
- **Chunked requests.** yt-dlp's `http_chunk_size` hint is ignored, in case YouTube throttles one long request. Sony row Y2 shows whether it does.
- **Artwork** for a YouTube video.
- **The GPG signature** of `SHA2-256SUMS`.
