# Paper Plane

Send any video on your Mac to your AirPlay TV: MKV and other local files, or the video playing in Chrome or Brave.

> Early development. There's nothing to install yet.

## How it works

Paper Plane converts on the fly whatever your TV can't play, copying everything it can, using ffmpeg. It serves the stream from your Mac and hands it to the TV with macOS's own AirPlay. The full design is in [docs/superpowers/specs/2026-10-15-paper-plane-design.md](docs/superpowers/specs/2026-10-15-paper-plane-design.md), with later decisions in [docs/superpowers/specs/](docs/superpowers/specs/).

## Using it

- Drop a video on the paper plane in the menu bar or on the remote window, or use Open With → Paper Plane in Finder. Then pick your TV with the AirPlay button.
- Seek anywhere. Past what's converted so far, Paper Plane starts converting from there, which takes a few seconds.
- The speech-bubble button switches the audio track and the subtitles, including `Movie.srt` and `Movie.en.srt` files beside the video.
- Settings (in the menu bar menu) has three switches for TVs that differ from the one Paper Plane was tested with: surround sound, HDR to SDR, and burning in subtitles.
- If something goes wrong, Show Log reveals a log in `~/Library/Logs/Paper Plane/` for a bug report. It leaves out cookies, passwords and your home folder's path.

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
```

Debug builds made before `scripts/build-ffmpeg.sh` use Homebrew's ffmpeg. Release builds need the bundled one. The subtitle burn-in tests run only with the bundled ffmpeg, since Homebrew's has no libass:

```bash
PAPERPLANE_FFMPEG="$PWD/vendor/ffmpeg/bin/ffmpeg" PAPERPLANE_FFPROBE="$PWD/vendor/ffmpeg/bin/ffprobe" scripts/test-core.sh
```

## License

GPL-3.0. See [LICENSE](LICENSE).
