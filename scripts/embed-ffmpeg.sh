#!/bin/sh
# Xcode build phase for the app: copies the bundled ffmpeg and ffprobe (scripts/build-ffmpeg.sh)
# into Paper Plane.app/Contents/Helpers/. Debug builds without them fall back to Homebrew's
# ffmpeg; Release builds refuse, so a shipped app always carries its own.
set -eu
SOURCE="$SRCROOT/../vendor/ffmpeg/bin"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
if [ ! -x "$SOURCE/ffmpeg" ] || [ ! -x "$SOURCE/ffprobe" ]; then
  if [ "$CONFIGURATION" = Release ]; then
    echo "error: vendor/ffmpeg/bin is missing. Run scripts/build-ffmpeg.sh first."
    exit 1
  fi
  echo "warning: vendor/ffmpeg/bin is missing, so this build uses Homebrew's ffmpeg. Run scripts/build-ffmpeg.sh."
  rm -f "$DEST/ffmpeg" "$DEST/ffprobe" # the browser helper lives there too
  exit 0
fi
mkdir -p "$DEST"
for tool in ffmpeg ffprobe; do
  cp -f "$SOURCE/$tool" "$DEST/$tool"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$DEST/$tool"
done
