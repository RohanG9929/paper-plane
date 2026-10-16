#!/usr/bin/env bash
# Generates ~10-second test clips covering every input row of the spec's conversion table
# (§4.1) into testdata/media/. Development only: uses Homebrew's ffmpeg (brew install ffmpeg).
# A clip whose encoder is missing is skipped with a warning; tests needing it then fail
# loudly in scripts/check-test-media.py rather than silently.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=testdata/media
mkdir -p "$OUT"
DUR=10
SKIPPED=()

VIDEO="testsrc=size=1280x720:rate=30:duration=$DUR"
STEREO="sine=frequency=440:sample_rate=48000:duration=$DUR"
TONES51="0.2*sin(330*2*PI*t)|0.2*sin(440*2*PI*t)|0.2*sin(550*2*PI*t)|0.2*sin(60*2*PI*t)|0.2*sin(660*2*PI*t)|0.2*sin(770*2*PI*t)"
SURROUND51="aevalsrc=$TONES51:s=48000:d=$DUR:c=5.1"
SURROUND71="aevalsrc=$TONES51|0.2*sin(880*2*PI*t)|0.2*sin(990*2*PI*t):s=48000:d=$DUR:c=7.1"
X264=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -g 30)
HDR10_PARAMS="log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
HDR10_PARAMS+=":master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"

clip() { # clip <output file> <ffmpeg arguments...>
  local file=$1
  shift
  if ffmpeg -hide_banner -loglevel error -y "$@" "$OUT/$file"; then
    echo "made    $file"
  else
    echo "SKIPPED $file (ffmpeg failed; see the error above)" >&2
    rm -f "$OUT/$file"
    SKIPPED+=("$file")
  fi
}

cat > "$OUT/sample.srt" <<'EOF'
1
00:00:01,000 --> 00:00:04,000
Paper Plane test subtitle one

2
00:00:05,000 --> 00:00:08,000
Paper Plane test subtitle two
EOF
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=red:s=300x300" -frames:v 1 "$OUT/cover.png"

clip h264_aac.mp4 -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" "${X264[@]}" -c:a aac -b:a 128k -ac 2
clip h264_ac3_51.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND51" -i "$OUT/sample.srt" \
  -map 0:v -map 1:a -map 2:s "${X264[@]}" -c:a ac3 -b:a 448k -c:s srt
clip hevc_eac3_51.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND51" \
  -c:v libx265 -preset ultrafast -x265-params log-level=error -pix_fmt yuv420p -g 30 -c:a eac3 -b:a 640k
# Tag the frames with setparams: ffmpeg 9's -color_* output options override x265's HDR tags with "unknown".
clip hevc_hdr10_aac.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" \
  -vf "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc" \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -g 30 -x265-params "$HDR10_PARAMS" \
  -c:a aac -b:a 128k -ac 2
clip vp9_opus.webm -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 1M -c:a libopus -b:a 96k -ac 2
clip av1_flac_51.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND51" \
  -c:v libsvtav1 -preset 12 -crf 45 -pix_fmt yuv420p -c:a flac
clip mpeg2_dts_51.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND51" \
  -c:v mpeg2video -q:v 5 -af "aformat=channel_layouts=5.1(side)" -c:a dca -strict -2
clip h264_flac_71.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND71" "${X264[@]}" -c:a flac
clip h264_10bit_aac.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p10le -profile:v high10 -g 30 -c:a aac -b:a 128k -ac 2
clip h264_noaudio.mkv -f lavfi -i "$VIDEO" "${X264[@]}"
clip h264_coverart.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" "${X264[@]}" -c:a aac -b:a 128k -ac 2 \
  -attach "$OUT/cover.png" -metadata:s:t mimetype=image/png
clip h264_multiaudio.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" -f lavfi -i "$SURROUND51" \
  -map 0:v -map 1:a -map 2:a "${X264[@]}" \
  -c:a:0 aac -b:a:0 128k -ac:a:0 2 -c:a:1 ac3 -b:a:1 448k \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn -disposition:a:0 0 -disposition:a:1 default
clip audio_only.m4a -f lavfi -i "$STEREO" -c:a aac -b:a 128k -ac 2

printf 'This is not a video file.\n' > "$OUT/corrupt.mkv"
echo "made    corrupt.mkv"
if [[ -f "$OUT/h264_aac.mp4" ]]; then
  cp "$OUT/h264_aac.mp4" "$OUT/Movie: Part 1 (Director's Cut) é.mp4"
  echo "made    Movie: Part 1 (Director's Cut) é.mp4"
fi

if ((${#SKIPPED[@]})); then
  echo "Skipped ${#SKIPPED[@]} clip(s): ${SKIPPED[*]}" >&2
  exit 1
fi
echo "All test media in $OUT"
