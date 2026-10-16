#!/bin/bash
# Checks that quitting Paper Plane never leaves ffmpeg running or a session folder behind, at
# any moment: while a video is still being prepared and once it's ready. It launches the app,
# opens a long clip that needs converting, quits after a delay, and looks for leftovers.
# The app shows its window on screen while this runs (about a minute).
# Usage: scripts/check-quit-cleanup.sh [path to Paper Plane.app]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
APP="${1:-$PWD/build/DerivedData/Build/Products/Debug/Paper Plane.app}"
SESSIONS="$HOME/Library/Caches/Paper Plane/sessions"
CLIP="${TMPDIR%/}/paperplane-quit-check.mkv"
[[ -d "$APP" ]] || { echo "No app at $APP. Build it first (see README)." >&2; exit 2; }
if [[ ! -f "$CLIP" ]]; then
  echo "Making a 10-minute MPEG-2 clip (needs re-encoding, so ffmpeg runs for a while)…"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=600" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=600" -c:v mpeg2video -q:v 8 -c:a mp2 "$CLIP" || exit 2
fi

leftovers=0
launch() {
  # Leave Chrome's and Brave's folders alone, and GitHub: no yt-dlp update check.
  open "$APP" --args -PaperPlaneInstallsBrowserHosts NO -PaperPlaneUpdatesYtDlp NO
  until pgrep -f "Paper Plane.app/Contents/MacOS" >/dev/null; do sleep 0.1; done
  sleep 1
}
quit_app() {
  osascript -e 'tell application id "dev.paperplane.app" to quit' >/dev/null
  while pgrep -f "Paper Plane.app/Contents/MacOS" >/dev/null; do sleep 0.1; done
}
# Quits, then reports (and clears up) any ffmpeg or session folder left behind.
quit_and_check() {
  quit_app
  sleep 0.5
  ffmpeg_left="$(pgrep -f 'Helpers/ffmpeg|ffmpeg .*paperplane-quit-check' | wc -l | tr -d ' ')"
  folders_left="$(find "$SESSIONS" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  echo "$1: ffmpeg left ${ffmpeg_left}, folders left ${folders_left}"
  if [[ "$ffmpeg_left" != 0 || "$folders_left" != 0 ]]; then
    leftovers=1
    pkill -f 'Helpers/ffmpeg|ffmpeg .*paperplane-quit-check'
    rm -rf "$SESSIONS"
  fi
}

for delay in 0.3 0.6 0.9 1.2 1.6 2.0 3.0; do
  launch
  open -a "$APP" "$CLIP"
  sleep "$delay"
  state="$(find "$SESSIONS" -name master.m3u8 2>/dev/null | grep -q . && echo ready || echo preparing)"
  quit_and_check "quit after ${delay}s (${state})"
done
# A copy in the temporary folder: from Documents, Desktop or Downloads, looking for subtitles
# beside it would raise the macOS privacy prompt, which an unattended run can't answer.
SECOND="${TMPDIR%/}/paperplane-quit-check-second.mkv"
cp "$PWD/testdata/media/h264_ac3_51.mkv" "$SECOND" 2>/dev/null
if [[ -f "$SECOND" ]]; then
  # Opening a second video while the first is still being prepared must leave only the second.
  launch
  open -a "$APP" "$CLIP"
  sleep 0.4
  open -a "$APP" "$SECOND"
  sleep 4
  # Sessions have a master playlist; the second video's converted subtitles have a folder too.
  sessions="$(find "$SESSIONS" -name master.m3u8 2>/dev/null | wc -l | tr -d ' ')"
  converting="$(pgrep -f 'ffmpeg .*paperplane-quit-check.mkv' | wc -l | tr -d ' ')"
  echo "open twice quickly: sessions ${sessions}, ffmpeg still on the first video ${converting}"
  [[ "$sessions" == 1 && "$converting" == 0 ]] || leftovers=1
  quit_app

  # Quitting straight after the second open must clean up after both.
  for delay in 0.1 1.0; do
    launch
    open -a "$APP" "$CLIP"
    sleep 1.5
    open -a "$APP" "$SECOND"
    sleep "$delay"
    quit_and_check "open twice, quit after ${delay}s"
  done
fi

if ((leftovers)); then
  echo "LEFTOVERS: ffmpeg or a session folder outlived what it belonged to" >&2
  exit 1
fi
echo "Clean: nothing outlived the app"
