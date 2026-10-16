#!/usr/bin/env bash
# Plan 2 re-test (optional, about 5 minutes at the TV): master playlists for streams that
# make-streams.sh and start-live.sh already build, to see whether CODECS lets the Sony play
# Dolby audio, whether VIDEO-RANGE=PQ brings up its HDR indicator, and whether
# EXT-X-START:TIME-OFFSET=0 makes it start a growing playlist at the beginning.
# Throwaway. The codec strings come from the init segments make-streams.sh writes. FRAME-RATE
# matters: AVFoundation refuses a VIDEO-RANGE=PQ variant without it.
set -euo pipefail
cd "$(dirname "$0")"
OUT=streams
for name in ac3 eac3 hdr10; do
  [[ -f "$OUT/$name/index.m3u8" ]] || { echo "Run make-streams.sh first ($OUT/$name is missing)." >&2; exit 1; }
done

master() { # master <file> <EXT-X-STREAM-INF attributes> <media playlist URI> [extra tag]
  {
    echo "#EXTM3U"
    echo "#EXT-X-VERSION:7"
    echo "#EXT-X-INDEPENDENT-SEGMENTS"
    [[ -n ${4:-} ]] && echo "$4"
    echo "#EXT-X-STREAM-INF:$2"
    echo "$3"
  } > "$1"
  echo "wrote $1"
}

master "$OUT/ac3/master.m3u8" 'BANDWIDTH=6000000,CODECS="avc1.640028,ac-3",RESOLUTION=1920x1080,FRAME-RATE=30.000,VIDEO-RANGE=SDR' index.m3u8
master "$OUT/eac3/master.m3u8" 'BANDWIDTH=6000000,CODECS="avc1.640028,ec-3",RESOLUTION=1920x1080,FRAME-RATE=30.000,VIDEO-RANGE=SDR' index.m3u8
master "$OUT/hdr10/master.m3u8" 'BANDWIDTH=20000000,CODECS="hvc1.2.4.L150.90,mp4a.40.2",RESOLUTION=3840x2160,FRAME-RATE=30.000,VIDEO-RANGE=PQ' index.m3u8
# start-live.sh deletes streams/live/ when it starts, so this one lives next to it.
mkdir -p "$OUT/livestart"
master "$OUT/livestart/master.m3u8" 'BANDWIDTH=6000000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=30.000,VIDEO-RANGE=SDR' \
  ../live/index.m3u8 '#EXT-X-START:TIME-OFFSET=0'
