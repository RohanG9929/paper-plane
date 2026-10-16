# Paper Plane

Send any video on your Mac to your AirPlay TV: MKV and other local files, the video playing in Chrome or Brave, YouTube, or a link you've copied.

> Early development. There's nothing to install yet.

## How it works

Paper Plane converts on the fly whatever your TV can't play, copying everything it can, using ffmpeg. It serves the stream from your Mac and hands it to the TV with macOS's own AirPlay. The full design is in [docs/superpowers/specs/2026-10-15-paper-plane-design.md](docs/superpowers/specs/2026-10-15-paper-plane-design.md), with later decisions in [docs/superpowers/specs/](docs/superpowers/specs/).

## Using it

- Drop a video on the paper plane in the menu bar or on the remote window, or use Open With → Paper Plane in Finder. Then pick your TV with the AirPlay button.
- Or copy a link to a video, on YouTube or most other video sites, and choose Play Copied Link: in the menu bar menu, under the remote's drop zone, or with ⌘V in the remote. A link dragged from the browser's address bar onto the remote or the menu bar icon plays too.
- Seek anywhere. Past what's converted so far, Paper Plane starts converting from there, which takes a few seconds.
- The speech-bubble button switches the audio track and the subtitles, including `Movie.srt` and `Movie.en.srt` files beside the video.
- Settings (in the menu bar menu) has three switches for TVs that differ from the one Paper Plane was tested with: surround sound, HDR to SDR, and drawing subtitles into the picture.
- If something goes wrong, Show Log reveals a log in `~/Library/Logs/Paper Plane/` for a bug report. It leaves out cookies, passwords and your home folder's path.
- Your Mac stays awake while the TV plays, but closing a laptop's lid still puts it to sleep and stops the video.

### Videos in Chrome or Brave

1. Build the extension: `cd extension && npm ci --ignore-scripts && npm run build`.
2. In Chrome or Brave, open `chrome://extensions`, turn on Developer mode, click Load unpacked and choose `extension/dist`.
3. Open Paper Plane once, so the browser can reach it.

Then play a video on a site and click the paper plane in the toolbar. It's grey until it finds a video; when it's sure which one you're watching, a click sends it, and when it isn't, it shows a count and lets you choose. Paper Plane comes forward to choose your TV, starts where the browser was, and the browser's video pauses. Live streams play live. On YouTube, Paper Plane gets the video from the page itself, signed in as you are in the browser. Sites that only offer DASH streams come in a later version.

The extension passes the site's cookies for the video along to Paper Plane, which sends them only to that site, only to fetch that video, and never saves them.

### YouTube and other sites' pages

Paper Plane finds the video on a page with [yt-dlp](https://github.com/yt-dlp/yt-dlp). It ships a copy and keeps it up to date from yt-dlp's GitHub releases, at most once a day and whenever a page fails, checking each download against the release's SHA-256 sums. Updates go in `~/Library/Application Support/Paper Plane/bin/`. YouTube's cookie reaches yt-dlp in memory, never on its command line or in a file.

Recent versions of yt-dlp need a JavaScript runtime for YouTube. If YouTube videos fail or play at low quality, install Deno: `brew install deno`.

## Installing a release

None has been published yet. Once one is:

1. Download `Paper-Plane-<version>.zip` and `Paper-Plane-Extension-<version>.zip` from the Releases page.
2. Unzip the app, move it to Applications and open it. It isn't notarized yet, so macOS says it can't check it: open System Settings → Privacy & Security and click Open Anyway.
3. Unzip the extension, then in Chrome or Brave open `chrome://extensions`, turn on Developer mode, click Load unpacked and choose the `Paper Plane Extension` folder.
4. The first time you play a video, allow Paper Plane to find devices on your local network.

## Development

You need macOS 14 or later on Apple Silicon, Xcode 26 or later, and Homebrew.

```bash
brew install ffmpeg            # development and tests only
scripts/make-test-media.sh     # generates test clips into testdata/media/
scripts/test-core.sh           # runs the core and UI tests

brew install meson ninja autoconf automake libtool pkgconf
scripts/build-ffmpeg.sh        # builds the ffmpeg the app ships into vendor/ffmpeg/ (a few minutes)
scripts/check-ffmpeg.sh        # checks that build

open app/PaperPlane.xcodeproj  # the app; run the PaperPlane scheme
scripts/check-quit-cleanup.sh  # checks quitting never leaves ffmpeg or session files behind
scripts/check-bridge.sh        # sends requests through the browser helper to the app

cd extension && npm ci --ignore-scripts
npm test && npm run typecheck  # the extension's tests
npm run build && cd ..
scripts/check-extension.sh     # the extension in a headless Chrome with a throwaway profile, through to the app

scripts/fetch-yt-dlp.sh        # fetches the yt-dlp the app ships into vendor/yt-dlp/, checked against its release's sums
scripts/check-fetch-yt-dlp.sh  # checks that script against a stand-in release on this Mac
scripts/make-release.sh        # builds, checks and zips the app and the extension into build/release/
```

The app installs the browser helper's manifest for Chrome and Brave each time it starts, and checks for a newer yt-dlp once a day. Pass `-PaperPlaneInstallsBrowserHosts NO` and `-PaperPlaneUpdatesYtDlp NO` when launching it to leave the browsers' folders and GitHub alone; the check scripts do. A build without `vendor/yt-dlp/` fetches yt-dlp the first time a page needs it, and a development build uses Homebrew's (`brew install yt-dlp`) if there is one.

Debug builds made before `scripts/build-ffmpeg.sh` use Homebrew's ffmpeg. Release builds need the bundled one. The subtitle burn-in tests run only with the bundled ffmpeg, since Homebrew's has no libass:

```bash
PAPERPLANE_FFMPEG="$PWD/vendor/ffmpeg/bin/ffmpeg" PAPERPLANE_FFPROBE="$PWD/vendor/ffmpeg/bin/ffprobe" scripts/test-core.sh
```

## License

GPL-3.0. See [LICENSE](LICENSE).
