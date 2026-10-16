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

if [ -x "$SOURCE/ffmpeg" ] && [ -x "$SOURCE/ffprobe" ]; then
  for tool in ffmpeg ffprobe; do
    cp -f "$SOURCE/$tool" "$DEST/$tool"
    codesign --force --sign "$SIGN" "$DEST/$tool"
  done
elif [ "$CONFIGURATION" = Release ]; then
  echo "error: vendor/ffmpeg/bin is missing. Run scripts/build-ffmpeg.sh first."
  exit 1
else
  echo "warning: vendor/ffmpeg/bin is missing, so this build uses Homebrew's ffmpeg. Run scripts/build-ffmpeg.sh."
  rm -f "$DEST/ffmpeg" "$DEST/ffprobe"
fi

if [ -x "$YTDLP/yt-dlp" ] && [ -f "$YTDLP/VERSION" ]; then
  cp -f "$YTDLP/yt-dlp" "$DEST/yt-dlp"
  cp -f "$YTDLP/VERSION" "$DEST/yt-dlp.version"
  codesign --force --sign "$SIGN" "$DEST/yt-dlp"
else
  echo "warning: vendor/yt-dlp is missing, so this build has no yt-dlp of its own. Run scripts/fetch-yt-dlp.sh."
  rm -f "$DEST/yt-dlp" "$DEST/yt-dlp.version"
fi
