#!/usr/bin/env bash
# Builds the ffmpeg and ffprobe that ship inside Paper Plane: static, arm64, macOS 14+.
#
# Enabled: VideoToolbox and AudioToolbox, libass (with freetype, fribidi and harfbuzz) for
# subtitle burn-in, libdav1d for AV1, zimg for zscale (HDR → SDR), Secure Transport for https.
# No x264/x265: Paper Plane encodes with VideoToolbox. Licensed GPL-3.0 (--enable-gpl
# --enable-version3), matching the app.
#
# Needs: brew install meson ninja autoconf automake libtool pkgconf
# Output: vendor/ffmpeg/bin/{ffmpeg,ffprobe} and vendor/ffmpeg/BUILDINFO
# Work files (downloads, build trees) go to ~/Library/Caches/dev.paperplane.ffmpeg-build, or
# $PAPERPLANE_FFMPEG_WORK; delete it to start clean. Not inside the repo: libtool and
# pkg-config break on paths with spaces, and the repo may live in one ("Other Code").
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${PAPERPLANE_FFMPEG_WORK:-$HOME/Library/Caches/dev.paperplane.ffmpeg-build}"
if [[ "$WORK" == *[[:space:]]* ]]; then
  echo "The build directory can't contain spaces: $WORK. Set PAPERPLANE_FFMPEG_WORK to another path." >&2
  exit 1
fi
DEPS="$WORK/deps"
OUT="$ROOT/vendor/ffmpeg"
JOBS="$(sysctl -n hw.ncpu)"

# name version url sha256
SOURCES=(
  "ffmpeg 9.0.2 https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
  "dav1d 1.5.4 https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz 686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
  "zimg 3.0.6 https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.6.tar.gz be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577"
  "freetype 2.15.0 https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz 93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5"
  "fribidi 1.0.17 https://github.com/fribidi/fribidi/releases/download/v1.0.17/fribidi-1.0.17.tar.xz 6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2"
  "harfbuzz 14.6.0 https://github.com/harfbuzz/harfbuzz/releases/download/14.6.0/harfbuzz-14.6.0.tar.xz d07a007327277708a2a73ae437887cdbaf282937f6d03ca5467723e9099af586"
  "libass 0.17.5 https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz 2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"
)

for tool in meson ninja autoreconf glibtoolize pkg-config; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. Run: brew install meson ninja autoconf automake libtool pkgconf" >&2; exit 1; }
done

# A clean environment: Apple's clang and libtool first, Homebrew only for build tools, and
# pkg-config limited to the static libraries built here, so nothing from Homebrew is linked.
BREW_BIN="$(dirname "$(command -v meson)")"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$BREW_BIN"
export LIBTOOLIZE=glibtoolize
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export PKG_CONFIG_PATH=""
export MACOSX_DEPLOYMENT_TARGET=14.0
export CC=clang CXX=clang++
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0 -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"
unset CPATH LIBRARY_PATH

mkdir -p "$WORK/downloads" "$WORK/src" "$DEPS"

source_dir() { # source_dir <name> → prints the unpacked source directory, downloading if needed
  local entry name version url sha file dir
  for entry in "${SOURCES[@]}"; do
    read -r name version url sha <<<"$entry"
    [[ $name == "$1" ]] || continue
    file="$WORK/downloads/$name-$version.tar.${url##*.}"
    if [[ ! -f $file ]]; then
      echo "== downloading $name $version" >&2
      curl -fsSL --retry 3 -o "$file.part" "$url"
      mv "$file.part" "$file"
    fi
    if ! echo "$sha  $file" | shasum -a 256 -c --status; then
      echo "Checksum mismatch for $file" >&2
      exit 1
    fi
    dir="$WORK/src/$name-$version"
    if [[ ! -d $dir ]]; then
      mkdir -p "$dir"
      tar -xf "$file" -C "$dir" --strip-components 1
    fi
    echo "$dir"
    return
  done
  echo "Unknown source $1" >&2
  exit 1
}

meson_build() { # meson_build <name> <meson options...>
  local name=$1 dir
  shift
  dir="$(source_dir "$name")"
  echo "== building $name" >&2
  rm -rf "$dir/build"
  meson setup "$dir/build" "$dir" --prefix="$DEPS" --libdir=lib --buildtype=release \
    -Ddefault_library=static "$@" >"$dir/build.log" 2>&1 || { tail -40 "$dir/build.log" >&2; exit 1; }
  ninja -C "$dir/build" install >>"$dir/build.log" 2>&1 || { tail -40 "$dir/build.log" >&2; exit 1; }
}

meson_build dav1d -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false
meson_build freetype -Dzlib=system -Dbzip2=disabled -Dpng=disabled -Dharfbuzz=disabled -Dbrotli=disabled -Dhvf=disabled \
  -Dtests=disabled
meson_build fribidi -Ddocs=false -Dbin=false -Dtests=false
meson_build harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
  -Dpng=disabled -Dzlib=disabled -Dicu=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled \
  -Dsubset=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled
meson_build libass -Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled -Dlibunibreak=disabled \
  -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled

ZIMG="$(source_dir zimg)"
echo "== building zimg" >&2
(
  cd "$ZIMG"
  { ./autogen.sh && ./configure --prefix="$DEPS" --disable-shared --enable-static && make -j"$JOBS" install; } \
    >build.log 2>&1 || { tail -40 build.log >&2; exit 1; }
)

FFMPEG="$(source_dir ffmpeg)"
echo "== building ffmpeg" >&2
FFMPEG_CONFIGURE=(
  --prefix="$WORK/ffmpeg-install"
  --arch=arm64 --target-os=darwin --cc=clang --cxx=clang++
  --enable-gpl --enable-version3
  --disable-shared --enable-static --pkg-config-flags=--static
  --disable-autodetect --enable-pthreads --enable-zlib --enable-bzlib --enable-iconv
  --enable-videotoolbox --enable-audiotoolbox --enable-securetransport
  --enable-libass --enable-libdav1d --enable-libzimg
  --disable-ffplay --disable-doc --disable-debug
  --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" --extra-libs=-lc++
)
(
  cd "$FFMPEG"
  { make distclean >/dev/null 2>&1 || true; } # stale state from an earlier run
  { ./configure "${FFMPEG_CONFIGURE[@]}" && make -j"$JOBS" && make install; } \
    >build.log 2>&1 || { tail -40 ffbuild/config.log build.log >&2; exit 1; }
)

rm -rf "$OUT"
mkdir -p "$OUT/bin"
for tool in ffmpeg ffprobe; do
  cp "$WORK/ffmpeg-install/bin/$tool" "$OUT/bin/$tool"
  strip -x "$OUT/bin/$tool"
  codesign --force --sign - "$OUT/bin/$tool" # strip removes the linker's ad-hoc signature
done
{
  echo "Built $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/build-ffmpeg.sh"
  printf '%s\n' "${SOURCES[@]}" | awk '{print $1, $2, $3}'
  echo "configure ${FFMPEG_CONFIGURE[*]}"
} >"$OUT/BUILDINFO"
echo "Built $OUT/bin/ffmpeg and $OUT/bin/ffprobe"
