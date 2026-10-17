#!/usr/bin/env bash
# Checks the ffmpeg and ffprobe that Paper Plane bundles (scripts/build-ffmpeg.sh): arm64,
# macOS 14+, only system libraries linked, and every feature the app relies on present.
# Usage: scripts/check-ffmpeg.sh [bin directory, default vendor/ffmpeg/bin]
set -uo pipefail
BIN="${1:-$(dirname "$0")/../vendor/ffmpeg/bin}"
FAILURES=0

check() { # check <description> <command...>: runs the command, prints ok/FAIL
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok      $description"
  else
    echo "FAIL    $description"
    FAILURES=$((FAILURES + 1))
  fi
}

# Libraries every Mac since macOS 14 has. Anything else (Homebrew, @rpath, newer system
# libraries) would make the app fail to launch somewhere.
ALLOWED_LIBS='^(/System/Library/Frameworks/[A-Za-z]+\.framework/|/usr/lib/lib(System\.B|z\.1|iconv\.2|bz2\.1\.0|c\+\+\.1)\.dylib$)'

# Outputs are captured first: grep -q exiting early would SIGPIPE the tool and, with
# pipefail, turn a match into a failure.
only_system_libraries() {
  local libs
  libs="$(otool -L "$1" | sed 1d | awk '{print $1}')" || return 1
  ! grep -Ev "$ALLOWED_LIBS" <<<"$libs"
}
minimum_macos_14() {
  local commands
  commands="$(otool -l "$1")" || return 1
  [[ "$(awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}' <<<"$commands")" == 14.0 ]]
}
ENCODERS="$("$BIN/ffmpeg" -hide_banner -encoders 2>/dev/null)"
DECODERS="$("$BIN/ffmpeg" -hide_banner -decoders 2>/dev/null)"
FILTERS="$("$BIN/ffmpeg" -hide_banner -filters 2>/dev/null)"
PROTOCOLS="$("$BIN/ffmpeg" -hide_banner -protocols 2>/dev/null)"
BUILDCONF="$("$BIN/ffmpeg" -hide_banner -buildconf 2>/dev/null)"
DEMUXERS="$("$BIN/ffmpeg" -hide_banner -demuxers 2>/dev/null)"
codec() { grep -Eq "^ [A-Z.]{6} $2 " <<<"$1"; }
filter() { grep -Eq "^ [A-Z.]{2,3} $1 " <<<"$FILTERS"; }
protocol() { grep -Eqx "  $1" <<<"$PROTOCOLS"; }
not() { ! "$@"; }
configured() { grep -Eq -- "$1\$" <<<"$BUILDCONF"; }
demuxer() { grep -Eq "^ *D.* $1 " <<<"$DEMUXERS"; }

for tool in ffmpeg ffprobe; do
  check "$tool exists" test -x "$BIN/$tool"
  check "$tool is arm64 only" test "$(lipo -archs "$BIN/$tool" 2>/dev/null)" = arm64
  check "$tool runs on macOS 14" minimum_macos_14 "$BIN/$tool"
  check "$tool links only system libraries" only_system_libraries "$BIN/$tool"
  check "$tool is signed" codesign --verify "$BIN/$tool"
done
check "GPL v3 build" configured "--enable-version3"
check "H.264 VideoToolbox encoder" codec "$ENCODERS" h264_videotoolbox
check "HEVC VideoToolbox encoder" codec "$ENCODERS" hevc_videotoolbox
check "AAC encoder" codec "$ENCODERS" aac
check "E-AC3 encoder" codec "$ENCODERS" eac3
check "no libx264" not codec "$ENCODERS" libx264
check "no libx265" not codec "$ENCODERS" libx265
check "dav1d AV1 decoder" codec "$DECODERS" libdav1d
check "PGS subtitle decoder" codec "$DECODERS" pgssub
check "subtitles filter (libass)" filter subtitles
check "zscale filter (zimg)" filter zscale
check "tonemap filter" filter tonemap
check "https protocol" protocol https
check "libxml2 (DASH) build" configured "--enable-libxml2"
check "DASH demuxer" demuxer dash

if ((FAILURES)); then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "All checks passed for $BIN"
