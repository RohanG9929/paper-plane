#!/bin/bash
# Fetches the official yt-dlp_macos into vendor/yt-dlp/ for the app to ship (Milestone 4, decision 2):
# the latest release, or YTDLP_VERSION's, checked against that release's SHA2-256SUMS. The build
# copies it into the app with its VERSION; the app keeps it up to date by itself afterwards.
# Usage: scripts/fetch-yt-dlp.sh            (YTDLP_VERSION=2026.10.09 scripts/fetch-yt-dlp.sh to pick one)
# scripts/check-fetch-yt-dlp.sh points YTDLP_RELEASES, YTDLP_API, YTDLP_PROTOCOLS and YTDLP_DEST at a
# stand-in release on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASES="${YTDLP_RELEASES:-https://github.com/yt-dlp/yt-dlp/releases}"
API="${YTDLP_API:-https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest}"
PROTOCOLS="${YTDLP_PROTOCOLS:-=https}"
DEST="${YTDLP_DEST:-vendor/yt-dlp}"
VERSION="${YTDLP_VERSION:-}"
fetch() { curl --fail --silent --show-error --location --proto "$PROTOCOLS" --proto-redir "$PROTOCOLS" \
  --max-time 600 --max-filesize 209715200 -H "User-Agent: Paper Plane" "$@"; }

if [[ -z "$VERSION" ]]; then
  VERSION="$(fetch "$API" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')"
fi
# The tag becomes part of an address: nothing but a version.
if ! [[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]{1,6})?$ ]]; then
  echo "error: \"$VERSION\" isn't a yt-dlp version" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fetch -o "$WORK/SHA2-256SUMS" "$RELEASES/download/$VERSION/SHA2-256SUMS"
fetch -o "$WORK/yt-dlp_macos" "$RELEASES/download/$VERSION/yt-dlp_macos"
EXPECTED="$(awk '$2 == "yt-dlp_macos" || $2 == "*yt-dlp_macos" { print tolower($1) }' "$WORK/SHA2-256SUMS" | sort -u)"
if ! [[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: SHA2-256SUMS of $VERSION has no single digest for yt-dlp_macos" >&2
  exit 1
fi
ACTUAL="$(shasum -a 256 "$WORK/yt-dlp_macos" | awk '{ print $1 }')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "error: yt-dlp_macos doesn't match SHA2-256SUMS of $VERSION" >&2
  exit 1
fi

mkdir -p "$DEST"
install -m 0755 "$WORK/yt-dlp_macos" "$DEST/yt-dlp.new"
mv -f "$DEST/yt-dlp.new" "$DEST/yt-dlp"
echo "$VERSION" > "$DEST/VERSION"
echo "yt-dlp $VERSION is in $DEST (SHA-256 $ACTUAL)"
