#!/bin/bash
# Builds a release of Paper Plane into build/release/: the app, with its own ffmpeg and yt-dlp, and
# the extension, each zipped, with their SHA-256s. It checks first that the extension's tests pass
# and that everything the app needs is inside it. Signing with a Developer ID, notarizing and
# publishing are the owner's steps (spec §10); until then the app is signed only for this Mac.
# Needs: scripts/build-ffmpeg.sh, scripts/fetch-yt-dlp.sh, and npm ci --ignore-scripts in extension/.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x vendor/ffmpeg/bin/ffmpeg && -x vendor/ffmpeg/bin/ffprobe ]] || { echo "error: run scripts/build-ffmpeg.sh first" >&2; exit 1; }
[[ -x vendor/yt-dlp/yt-dlp && -f vendor/yt-dlp/VERSION ]] || { echo "error: run scripts/fetch-yt-dlp.sh first" >&2; exit 1; }
[[ -d extension/node_modules ]] || { echo "error: run npm ci --ignore-scripts in extension/ first" >&2; exit 1; }

(cd extension && npm test --silent && npm run --silent typecheck && npm run --silent build)
mkdir -p build
xcodebuild -project app/PaperPlane.xcodeproj -scheme PaperPlane -configuration Release -derivedDataPath build/DerivedData \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build > build/release-build.log 2>&1 \
  || { tail -20 build/release-build.log >&2; echo "error: the Release build failed (build/release-build.log)" >&2; exit 1; }

APP="build/DerivedData/Build/Products/Release/Paper Plane.app"
for tool in ffmpeg ffprobe yt-dlp paperplane-host; do
  [[ -x "$APP/Contents/Helpers/$tool" ]] || { echo "error: $tool is missing from the app" >&2; exit 1; }
done
[[ "$(cat "$APP/Contents/Resources/yt-dlp.version")" == "$(cat vendor/yt-dlp/VERSION)" ]] \
  || { echo "error: the app's yt-dlp.version doesn't match vendor/yt-dlp" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT/Paper Plane Extension"
ditto -c -k --keepParent "$APP" "$OUT/Paper-Plane-$VERSION.zip"
ditto extension/dist "$OUT/Paper Plane Extension"
ditto -c -k --keepParent "$OUT/Paper Plane Extension" "$OUT/Paper-Plane-Extension-$VERSION.zip"
rm -rf "$OUT/Paper Plane Extension"

# A disk image as well, the usual way a Mac app is handed out: the app beside a shortcut to
# Applications, so it's dragged across. The zip stays for anyone who'd rather have that.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Paper Plane.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Paper Plane" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Paper-Plane-$VERSION.dmg"
rm -rf "$STAGE"

(cd "$OUT" && shasum -a 256 ./*.dmg ./*.zip | tee SHA256SUMS)
echo "Paper Plane $VERSION (yt-dlp $(cat vendor/yt-dlp/VERSION)) is in $OUT"
