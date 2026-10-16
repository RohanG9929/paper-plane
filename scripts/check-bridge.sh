#!/bin/bash
# Checks the browser bridge end to end, without a browser or a TV: it sends play requests through
# the app's own paperplane-host, as Chrome would, and checks the replies.
#   1. With the app running: a stream that plays, and one the site refuses.
#   2. With the app quit: the helper starts it, then relays the request.
#   3. After quitting: no socket, no ffmpeg and no session folder left behind.
# The app shows its window while this runs. It leaves Chrome's and Brave's folders alone.
# Usage: scripts/check-bridge.sh [path to Paper Plane.app]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
APP="${1:-$PWD/build/DerivedData/Build/Products/Debug/Paper Plane.app}"
HOST="$APP/Contents/Helpers/paperplane-host"
SOCKET="$HOME/Library/Application Support/Paper Plane/bridge.sock"
SESSIONS="$HOME/Library/Caches/Paper Plane/sessions"
[[ -x "$HOST" ]] || { echo "No helper at $HOST. Build the app first (see README)." >&2; exit 2; }

# The helper starts the app without arguments, so the setting goes in its defaults for the run.
had_setting="$(defaults read dev.paperplane.app PaperPlaneInstallsBrowserHosts 2>/dev/null || true)"
defaults write dev.paperplane.app PaperPlaneInstallsBrowserHosts -bool NO
restore() {
  if [[ -z "$had_setting" ]]; then
    defaults delete dev.paperplane.app PaperPlaneInstallsBrowserHosts 2>/dev/null
  else
    defaults write dev.paperplane.app PaperPlaneInstallsBrowserHosts -bool "$had_setting"
  fi
  [[ -n "${server:-}" ]] && kill "$server" 2>/dev/null
  rm -f "$portfile"
}
trap restore EXIT

# A local "site": testdata/media over HTTP (see serve-hls.py for its /cookie/ and /status/ paths).
portfile="$(mktemp "${TMPDIR%/}/paperplane-bridge-check.XXXXXX")"
python3 scripts/serve-hls.py testdata/media > "$portfile" &
server=$!
disown "$server" # stopped at the end without a "Terminated" line
until [[ -s "$portfile" ]]; do sleep 0.1; done
port="$(cut -d ' ' -f 2 "$portfile")"

# Sends one request through the helper and prints the reply's JSON.
send() {
  python3 - "$HOST" "$1" <<'PY'
import json, struct, subprocess, sys
host, url = sys.argv[1], sys.argv[2]
message = json.dumps({"type": "play", "v": 1, "title": "Bridge check", "startAt": 2,
                      "source": {"kind": "stream", "url": url, "format": "progressive",
                                 "headers": {"Cookie": "pp=1"}}}).encode()
out = subprocess.run([host, "chrome-extension://napcmmglefncoieikecpjmdopmagllcg/"],
                     input=struct.pack("<I", len(message)) + message, capture_output=True, timeout=60).stdout
length = struct.unpack("<I", out[:4])[0] if len(out) >= 4 else 0
print(out[4:4 + length].decode() or "(no reply)")
PY
}
quit_app() {
  osascript -e 'tell application id "dev.paperplane.app" to quit' >/dev/null 2>&1
  while pgrep -f "Paper Plane.app/Contents/MacOS" >/dev/null; do sleep 0.1; done
}

failures=0
expect() { # name, expected, actual
  if [[ "$3" == "$2" ]]; then echo "ok: $1"; else echo "FAIL: $1 — expected $2, got $3"; failures=1; fi
}

quit_app
open "$APP" --args -PaperPlaneInstallsBrowserHosts NO
until [[ -S "$SOCKET" ]]; do sleep 0.1; done
expect "a stream plays" '{"ok":true}' "$(send "http://127.0.0.1:$port/cookie/pp=1/h264_aac.mp4")"
expect "a refused stream says so" \
  '{"error":"The site stopped the stream — reload the page, then click Paper Plane again.","ok":false}' \
  "$(send "http://127.0.0.1:$port/status/403/h264_aac.mp4")"

quit_app
expect "quitting removes the socket" "gone" "$([[ -e "$SOCKET" ]] && echo there || echo gone)"
expect "the helper starts the app" '{"ok":true}' "$(send "http://127.0.0.1:$port/cookie/pp=1/h264_aac.mp4")"

quit_app
sleep 0.5
expect "no ffmpeg left" "0" "$(pgrep -f 'Helpers/ffmpeg' | wc -l | tr -d ' ')"
expect "no session folder left" "0" "$(find "$SESSIONS" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
exit $failures
