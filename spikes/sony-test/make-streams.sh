#!/usr/bin/env bash
# Builds the HLS test streams for the Sony test (Milestone 0) into spikes/sony-test/streams/.
# Throwaway. The 4K HDR stream takes a few minutes to encode.
set -euo pipefail
cd "$(dirname "$0")"
OUT=streams
DUR=120
rm -rf "$OUT/baseline" "$OUT/hevc" "$OUT/ac3" "$OUT/eac3" "$OUT/webvtt" "$OUT/hdr10"
mkdir -p "$OUT"

VIDEO=(-f lavfi -i "testsrc=size=1920x1080:rate=30:duration=$DUR")
STEREO=(-f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$DUR")
TONES="0.3*sin(330*2*PI*t)|0.3*sin(440*2*PI*t)|0.3*sin(550*2*PI*t)|0.3*sin(60*2*PI*t)|0.3*sin(660*2*PI*t)|0.3*sin(770*2*PI*t)"
SURROUND=(-f lavfi -i "aevalsrc=$TONES:s=48000:d=$DUR:c=5.1")
X264=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -g 60)
AAC=(-c:a aac -b:a 128k -ac 2)
HDR10_PARAMS="log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
HDR10_PARAMS+=":master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"

hls() { # hls <name> <ffmpeg input and codec arguments...> → streams/<name>/index.m3u8 (fMP4, VOD)
  local name=$1
  shift
  mkdir -p "$OUT/$name"
  echo "== $name"
  ffmpeg -hide_banner -loglevel error -y "$@" \
    -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_type fmp4 -hls_flags independent_segments \
    -hls_segment_filename "$OUT/$name/seg_%05d.m4s" "$OUT/$name/index.m3u8"
}

hls baseline "${VIDEO[@]}" "${STEREO[@]}" "${X264[@]}" "${AAC[@]}"
hls hevc "${VIDEO[@]}" "${STEREO[@]}" -c:v libx265 -preset ultrafast -x265-params log-level=error \
  -tag:v hvc1 -pix_fmt yuv420p -g 60 "${AAC[@]}"
hls ac3 "${VIDEO[@]}" "${SURROUND[@]}" "${X264[@]}" -c:a ac3 -b:a 448k
hls eac3 "${VIDEO[@]}" "${SURROUND[@]}" "${X264[@]}" -c:a eac3 -b:a 640k
# Tag the frames with setparams: ffmpeg 9's -color_* output options override x265's HDR tags with "unknown".
hls hdr10 -f lavfi -i "testsrc2=size=3840x2160:rate=30:duration=$DUR" "${STEREO[@]}" \
  -vf "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc" \
  -c:v libx265 -preset ultrafast -tag:v hvc1 -pix_fmt yuv420p10le -g 60 -x265-params "$HDR10_PARAMS" "${AAC[@]}"

# WebVTT: H.264/AAC in MPEG-TS segments plus a hand-written subtitle playlist and master playlist.
# This checks whether the TV draws subtitles at all; exact cue timing isn't what's being tested.
echo "== webvtt"
mkdir -p "$OUT/webvtt"
ffmpeg -hide_banner -loglevel error -y "${VIDEO[@]}" "${STEREO[@]}" "${X264[@]}" "${AAC[@]}" \
  -muxdelay 0 -muxpreload 0 \
  -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_type mpegts \
  -hls_segment_filename "$OUT/webvtt/seg_%05d.ts" "$OUT/webvtt/av.m3u8"
{
  echo "WEBVTT"
  echo "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000"
  echo
  for ((s = 0; s < DUR; s += 5)); do
    printf '00:%02d:%02d.000 --> 00:%02d:%02d.000\nSubtitle at %d seconds\n\n' \
      $((s / 60)) $((s % 60)) $(((s + 4) / 60)) $(((s + 4) % 60)) "$s"
  done
} > "$OUT/webvtt/subs.vtt"
cat > "$OUT/webvtt/subs.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:$DUR
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:$DUR.0,
subs.vtt
#EXT-X-ENDLIST
EOF
cat > "$OUT/webvtt/master.m3u8" <<'EOF'
#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="subs.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",SUBTITLES="subs"
av.m3u8
EOF

echo "Streams ready in spikes/sony-test/$OUT"
