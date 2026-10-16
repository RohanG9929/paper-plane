#!/bin/sh
# Xcode build phase for the app: copies the bundled ffmpeg and ffprobe (scripts/build-ffmpeg.sh) and
# yt-dlp with its version (scripts/fetch-yt-dlp.sh) into Paper Plane.app/Contents/Helpers/.
# - Debug builds without ffmpeg fall back to Homebrew's; Release builds refuse, so a shipped app
#   always carries its own.
# - Builds without yt-dlp warn: the app then fetches it from GitHub the first time a page needs it
#   (a development build may use Homebrew's), and scripts/make-release.sh refuses to package one.
set -eu
SOURCE="$SRCROOT/../vendor/ffmpeg/bin"
YTDLP="$SRCROOT/../vendor/yt-dlp"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
SIGN="${EXPANDED_CODE_SIGN_IDENTITY:--}"
mkdir -p "$DEST" # the browser helper lives there too

# Copies $1 to $2 and signs it, unless it's unchanged since the last build. Signing changes the
# copy, so it's compared with the source kept from last time, outside the app.
SEEN="${DERIVED_FILE_DIR:-$TARGET_TEMP_DIR}/embedded-tools"
mkdir -p "$SEEN"
embed() {
  name="$(basename "$2")"
  if [ ! -x "$2" ] || ! cmp -s "$1" "$SEEN/$name"; then
    cp -f "$1" "$2"
    codesign --force --sign "$SIGN" "$2"
    cp -f "$1" "$SEEN/$name"
  fi
}

if [ -x "$SOURCE/ffmpeg" ] && [ -x "$SOURCE/ffprobe" ]; then
  for tool in ffmpeg ffprobe; do
    embed "$SOURCE/$tool" "$DEST/$tool"
  done
elif [ "$CONFIGURATION" = Release ]; then
  echo "error: vendor/ffmpeg/bin is missing. Run scripts/build-ffmpeg.sh first."
  exit 1
else
  echo "warning: vendor/ffmpeg/bin is missing, so this build uses Homebrew's ffmpeg. Run scripts/build-ffmpeg.sh."
  rm -f "$DEST/ffmpeg" "$DEST/ffprobe"
fi

if [ -x "$YTDLP/yt-dlp" ] && [ -f "$YTDLP/VERSION" ]; then
  embed "$YTDLP/yt-dlp" "$DEST/yt-dlp"
  cp -f "$YTDLP/VERSION" "$DEST/yt-dlp.version"
else
  echo "warning: vendor/yt-dlp is missing, so this build has no yt-dlp of its own. Run scripts/fetch-yt-dlp.sh."
  rm -f "$DEST/yt-dlp" "$DEST/yt-dlp.version"
fi
