# Paper Plane

Send any video on your Mac to your AirPlay TV: MKV and other local files, or the video playing in Chrome or Brave.

> Early development. There's nothing to install yet.

## How it works

Paper Plane converts on the fly whatever your TV can't play, copying everything it can, using ffmpeg. It serves the stream from your Mac and hands it to the TV with macOS's own AirPlay. The full design is in [docs/superpowers/specs/2026-10-15-paper-plane-design.md](docs/superpowers/specs/2026-10-15-paper-plane-design.md).

## Development

You need macOS 14 or later on Apple Silicon, Xcode 26 or later, and Homebrew.

```bash
brew install ffmpeg            # development and tests only
scripts/make-test-media.sh     # generates test clips into testdata/media/
scripts/test-core.sh           # runs the PaperPlaneCore tests

brew install meson ninja autoconf automake libtool pkgconf
scripts/build-ffmpeg.sh        # builds the ffmpeg the app ships into vendor/ffmpeg/ (a few minutes)
scripts/check-ffmpeg.sh        # checks that build

open app/PaperPlane.xcodeproj  # the app; run the PaperPlane scheme
scripts/check-quit-cleanup.sh  # checks quitting never leaves ffmpeg or session files behind
```

Debug builds made before `scripts/build-ffmpeg.sh` use Homebrew's ffmpeg. Release builds need the bundled one.

## License

GPL-3.0. See [LICENSE](LICENSE).
