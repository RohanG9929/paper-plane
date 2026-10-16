#!/bin/bash
# Checks scripts/fetch-yt-dlp.sh against a stand-in release served on this Mac (no network): a good
# release lands with its VERSION, a pinned one is fetched, and a wrong digest or a tag that isn't a
# version leaves the destination as it was.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
work="$(mktemp -d)"
cleanup() {
  [[ -n "${server:-}" ]] && kill "$server" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

# Two releases: 2026.10.12 is right; 2026.10.13's sums name another file's digest.
release() { # tag, content, digest (empty for the right one)
  local folder="$work/site/download/$1"
  mkdir -p "$folder"
  printf '%s' "$2" > "$folder/yt-dlp_macos"
  local digest="${3:-$(shasum -a 256 "$folder/yt-dlp_macos" | awk '{ print $1 }')}"
  printf '%s  yt-dlp\n%s  yt-dlp_macos\n%s  yt-dlp_macos.zip\n' "$(printf '1%.0s' {1..64})" "$digest" "$(printf '2%.0s' {1..64})" \
    > "$folder/SHA2-256SUMS"
}
release 2026.10.12 '#!/bin/sh
echo good'
release 2026.10.11 '#!/bin/sh
echo pinned'
release 2026.10.13 '#!/bin/sh
echo tampered' "$(printf 'a%.0s' {1..64})"
mkdir -p "$work/site/api"
echo '{"tag_name": "2026.10.12"}' > "$work/site/api/latest"
echo '{"tag_name": "v2026.10.12/../../x"}' > "$work/site/api/bad"
echo '{"tag_name": "2026.10.13"}' > "$work/site/api/tampered"

portfile="$work/port"
python3 scripts/serve-hls.py "$work/site" > "$portfile" &
server=$!
disown "$server"
until [[ -s "$portfile" ]]; do sleep 0.1; done
port="$(cut -d ' ' -f 2 "$portfile")"
base="http://127.0.0.1:$port"

failures=0
check() { # label, condition
  if eval "$2"; then echo "ok: $1"; else echo "FAILED: $1"; failures=$((failures + 1)); fi
}
fetch() { # api name, then env assignments
  env YTDLP_RELEASES="$base" YTDLP_API="$base/api/$1" YTDLP_PROTOCOLS="=http" YTDLP_DEST="$work/dest" "${@:2}" \
    scripts/fetch-yt-dlp.sh > "$work/out" 2>&1
}

fetch latest
check "the latest release lands with its version" \
  '[[ $? -eq 0 && -x "$work/dest/yt-dlp" && "$("$work/dest/yt-dlp")" == good && "$(cat "$work/dest/VERSION")" == 2026.10.12 ]]'
fetch latest YTDLP_VERSION=2026.10.11
check "a pinned release is fetched" '[[ "$("$work/dest/yt-dlp")" == pinned && "$(cat "$work/dest/VERSION")" == 2026.10.11 ]]'
fetch tampered
status=$?
check "a wrong digest is refused and changes nothing" \
  '[[ $status -ne 0 && "$("$work/dest/yt-dlp")" == pinned && "$(cat "$work/dest/VERSION")" == 2026.10.11 ]] && grep -q "doesn.t match" "$work/out"'
fetch bad
status=$?
check "a tag that isn't a version is refused" '[[ $status -ne 0 ]] && grep -q "isn.t a yt-dlp version" "$work/out"'
check "nothing is left beside the copy" '[[ "$(ls "$work/dest" | tr "\n" " ")" == "VERSION yt-dlp " ]]'
exit $((failures > 0))
