#!/usr/bin/env bash
# Writes a 10-minute live-growing EVENT playlist in real time into spikes/sony-test/streams/live/
# (Sony test 7). Throwaway. Leave it running while testing; Ctrl-C to stop.
set -euo pipefail
cd "$(dirname "$0")"
OUT=streams/live
rm -rf "$OUT"
mkdir -p "$OUT"
echo "Writing $OUT/index.m3u8 in real time for 10 minutes…"
exec ffmpeg -hide_banner -loglevel error \
  -re -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=600" \
  -re -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=600" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 60 -c:a aac -b:a 128k -ac 2 \
  -f hls -hls_time 6 -hls_playlist_type event -hls_segment_type fmp4 \
  -hls_flags independent_segments+temp_file \
  -hls_segment_filename "$OUT/seg_%05d.m4s" "$OUT/index.m3u8"
