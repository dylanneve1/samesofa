#!/bin/sh
# Builds the FFmpeg helper that SameSofa uses to turn MKV, AVI, WebM and other
# containers into MP4 on the host's Mac before sharing.
#
# LGPL only: no --enable-gpl, no --enable-nonfree, no external codec libraries.
# Video is encoded with Apple's VideoToolbox (hardware), audio with FFmpeg's
# own AAC encoder. FFmpeg is built as shared libraries plus the ffmpeg and
# ffprobe programs, which the app runs as separate processes, so the LGPL code
# is never linked into the SameSofa binary and can be replaced (see
# THIRD-PARTY-NOTICES.md).
#
# Output: Vendor/FFmpeg/{bin,lib,BUILDINFO.txt}, universal (arm64 + x86_64)
# unless SAMESOFA_ARCHS says otherwise. Skips the build if the same version
# and flags were built before.
#
#   scripts/build-ffmpeg.sh
#   SAMESOFA_ARCHS=arm64 scripts/build-ffmpeg.sh
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)

FFMPEG_VERSION=8.1.3
FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
ARCHS=${SAMESOFA_ARCHS:-"arm64 x86_64"}
MIN_MACOS=14.0
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}

# Everything that decides what goes into the binaries. Decoders, demuxers,
# parsers and bitstream filters are all FFmpeg's own (LGPL) and stay enabled,
# so the helper can read almost anything; only what SameSofa writes is limited.
COMMON_FLAGS="--disable-gpl --disable-nonfree --disable-version3
 --enable-shared --disable-static --install-name-dir=@rpath
 --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib
 --disable-doc --disable-ffplay --disable-avdevice --disable-network --disable-devices --disable-debug
 --disable-encoders --enable-encoder=aac,alac,h264_videotoolbox,hevc_videotoolbox,movtext
 --disable-muxers --enable-muxer=mp4,mov,null,srt,webvtt
 --disable-filters --enable-filter=scale,format,aformat,aresample,null,anull,copy,acopy,setpts,asetpts,fps,pan,yadif
 --disable-protocols --enable-protocol=file,pipe"

OUT="$ROOT/Vendor/FFmpeg"
# Any change to this script means a rebuild.
STAMP_TEXT="ffmpeg $FFMPEG_VERSION archs=$ARCHS script=$(shasum -a 256 "$0" | cut -c1-16)"
if [ -f "$OUT/.stamp" ] && [ "$(cat "$OUT/.stamp")" = "$STAMP_TEXT" ] && [ -x "$OUT/bin/ffmpeg" ]; then
  echo "FFmpeg $FFMPEG_VERSION already built in Vendor/FFmpeg"
  exit 0
fi

# Build outside the checkout: FFmpeg's assert messages keep the source path,
# and a home folder path has no business inside the app.
WORK=${SAMESOFA_FFMPEG_WORK:-/tmp/samesofa-ffmpeg-build}
mkdir -p "$WORK" "$ROOT/Vendor"
TARBALL="$ROOT/Vendor/ffmpeg-$FFMPEG_VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "Downloading FFmpeg $FFMPEG_VERSION..."
  curl -fsSL --retry 3 -o "$TARBALL.part" "$FFMPEG_URL"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || {
  echo "Checksum mismatch for $TARBALL" >&2
  rm -f "$TARBALL"
  exit 1
}

SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
rm -rf "$SRC"
tar -xf "$TARBALL" -C "$WORK"

# Neither the SDK path nor the build folder may end up in the binaries
# (ffmpeg -buildconf prints its configure line), so the SDK comes from the
# environment and the install goes through DESTDIR with a neutral prefix.
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export SDKROOT
for arch in $ARCHS; do
  echo "Configuring FFmpeg for $arch..."
  BUILD="$WORK/build-$arch"
  PREFIX="$WORK/install-$arch"  # files land in $PREFIX/ffmpeg/{bin,lib}
  rm -rf "$BUILD" "$PREFIX"
  mkdir -p "$BUILD"
  case "$arch" in
    arm64) FFARCH=aarch64 ;;
    x86_64) FFARCH=x86_64 ;;
    *) echo "unknown arch $arch" >&2; exit 1 ;;
  esac
  ASM_FLAGS=""
  if [ "$arch" = x86_64 ] && ! command -v nasm >/dev/null 2>&1; then
    echo "warning: nasm not found, building x86_64 without assembly (slower on Intel Macs; brew install nasm)" >&2
    ASM_FLAGS="--disable-x86asm"
  fi
  CROSS=""
  [ "$arch" != "$(uname -m)" ] && CROSS="--enable-cross-compile"
  # shellcheck disable=SC2086
  # A relative path to the sources keeps the build folder out of __FILE__ strings.
  (cd "$BUILD" && "../ffmpeg-$FFMPEG_VERSION/configure" \
    --prefix=/ffmpeg --arch="$FFARCH" --target-os=darwin $CROSS $ASM_FLAGS \
    --cc="clang -arch $arch" \
    --extra-cflags="-mmacosx-version-min=$MIN_MACOS" \
    --extra-ldflags="-mmacosx-version-min=$MIN_MACOS" \
    --extra-ldexeflags="-Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,@executable_path/../lib" \
    $COMMON_FLAGS >"$BUILD/configure.log" 2>&1) || { tail -30 "$BUILD/configure.log"; exit 1; }
  echo "Building FFmpeg for $arch ($JOBS jobs)..."
  (cd "$BUILD" && make -j"$JOBS" >"$BUILD/make.log" 2>&1 && make install DESTDIR="$PREFIX" >>"$BUILD/make.log" 2>&1) || { tail -30 "$BUILD/make.log"; exit 1; }
done

# Merge the architectures.
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/lib"
FIRST=$(echo $ARCHS | cut -d' ' -f1)
for tool in ffmpeg ffprobe; do
  set --
  for arch in $ARCHS; do set -- "$@" "$WORK/install-$arch/ffmpeg/bin/$tool"; done
  lipo -create "$@" -output "$OUT/bin/$tool"
done
for lib in "$WORK/install-$FIRST/ffmpeg/lib/"lib*.*.dylib; do
  name=$(basename "$lib")
  # Only the real files (libavcodec.62.dylib), not the version symlinks.
  [ -L "$lib" ] && continue
  set --
  for arch in $ARCHS; do set -- "$@" "$WORK/install-$arch/ffmpeg/lib/$name"; done
  lipo -create "$@" -output "$OUT/lib/$name"
done
# The programs ask for @rpath/libavcodec.62.dylib etc.; keep only those names.
for lib in "$OUT/lib/"*.dylib; do
  name=$(basename "$lib")
  short=$(echo "$name" | sed -E 's/^(lib[a-z]+\.[0-9]+)\..*\.dylib$/\1.dylib/')
  [ "$short" != "$name" ] && mv "$lib" "$OUT/lib/$short"
done

# Record exactly what was built.
{
  echo "FFmpeg $FFMPEG_VERSION"
  echo "Source: $FFMPEG_URL"
  echo "SHA-256: $FFMPEG_SHA256"
  echo "Architectures: $ARCHS (macOS $MIN_MACOS+)"
  echo "Licence: LGPL-2.1-or-later (no GPL or nonfree components)"
  echo
  DYLD_LIBRARY_PATH="$OUT/lib" "$OUT/bin/ffmpeg" -hide_banner -buildconf 2>&1 || true
} >"$OUT/BUILDINFO.txt"
if grep -E -- '--enable-(gpl|nonfree|version3)' "$OUT/BUILDINFO.txt"; then
  echo "error: the FFmpeg build is not LGPL-2.1" >&2
  exit 1
fi
if grep -q "$HOME" "$OUT/BUILDINFO.txt" || strings "$OUT/bin/ffmpeg" "$OUT/lib/"*.dylib | grep -q "$HOME"; then
  echo "error: a local path leaked into the FFmpeg binaries" >&2
  exit 1
fi
cp "$SRC/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
echo "$STAMP_TEXT" >"$OUT/.stamp"
echo "FFmpeg $FFMPEG_VERSION ready in Vendor/FFmpeg:"
ls -la "$OUT/bin" "$OUT/lib" | sed 's/^/  /'
