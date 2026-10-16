#!/bin/bash
# Checks the extension end to end without a TV: a headless Chrome with a throwaway profile loads
# extension/dist, opens a local page whose <video> plays, and sends it through paperplane-host to
# the app, which must take it, and the page's video must pause. Your own Chrome profile and its
# folders are left alone: the throwaway profile holds its own copy of the helper's manifest.
# Needs Google Chrome, the built app (see README) and the built extension (npm run build).
# Usage: scripts/check-extension.sh [path to Paper Plane.app]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
APP="${1:-$PWD/build/DerivedData/Build/Products/Debug/Paper Plane.app}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
HOST="$APP/Contents/Helpers/paperplane-host"
SOCKET="$HOME/Library/Application Support/Paper Plane/bridge.sock"
[[ -x "$HOST" ]] || { echo "No helper at $HOST. Build the app first (see README)." >&2; exit 2; }
[[ -x "$CHROME" ]] || { echo "No Chrome at $CHROME (set CHROME to another one)." >&2; exit 2; }
[[ -f extension/dist/manifest.json ]] || { echo "Build the extension first: cd extension && npm run build" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR%/}/paperplane-extension-check.XXXXXX")"
mkdir -p "$work/profile/NativeMessagingHosts" "$work/site"
cat > "$work/profile/NativeMessagingHosts/dev.paperplane.host.json" <<JSON
{"name": "dev.paperplane.host", "description": "Paper Plane", "path": "$HOST", "type": "stdio",
 "allowed_origins": ["chrome-extension://napcmmglefncoieikecpjmdopmagllcg/"]}
JSON
cp testdata/media/h264_aac.mp4 "$work/site/film.mp4"
cat > "$work/site/player.html" <<HTML
<!doctype html><title>A film</title><video src="film.mp4" autoplay muted playsinline loop></video>
HTML

python3 scripts/serve-hls.py "$work/site" > "$work/port" &
server=$!
disown "$server" # stopped at the end without a "Terminated" line
until [[ -s "$work/port" ]]; do sleep 0.1; done
port="$(cut -d ' ' -f 2 "$work/port")"
cleanup() {
  kill "$server" 2>/dev/null
  osascript -e 'tell application id "dev.paperplane.app" to quit' >/dev/null 2>&1
  while pgrep -f "Paper Plane.app/Contents/MacOS" >/dev/null; do sleep 0.1; done
  rm -rf "$work"
}
trap cleanup EXIT

open "$APP" --args -PaperPlaneInstallsBrowserHosts NO
until [[ -S "$SOCKET" ]]; do sleep 0.1; done
cd extension && node check-in-chrome.mjs "$CHROME" "$work/profile" "http://127.0.0.1:$port/player.html"
