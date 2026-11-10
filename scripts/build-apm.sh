#!/bin/sh
# Builds the echo canceller SameSofa links: WebRTC's audio processing module
# (AEC3, noise suppression, gain control) as packaged by the PulseAudio
# project ("webrtc-audio-processing", BSD-3-Clause), with the Abseil parts it
# needs (Apache-2.0). SameSofa feeds it the film's sound and the other
# person's voice as the echo reference, so the film can play through the
# normal, unprocessed audio output.
#
# Output: Vendor/APM/{lib/libsamesofa-apm.a,include,BUILDINFO.txt,LICENSE.*},
# universal (arm64 + x86_64) unless SAMESOFA_ARCHS says otherwise. Skips the
# build if the same version was built before. Needs meson and ninja
# (brew install meson ninja).
#
#   scripts/build-apm.sh
#   SAMESOFA_ARCHS=arm64 scripts/build-apm.sh
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)

APM_VERSION=2.1
APM_SHA256=ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
APM_URL="https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-$APM_VERSION.tar.xz"
ARCHS=${SAMESOFA_ARCHS:-"arm64 x86_64"}
MIN_MACOS=14.0
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

OUT="$ROOT/Vendor/APM"
STAMP_TEXT="apm $APM_VERSION archs=$ARCHS script=$(shasum -a 256 "$0" | cut -c1-16)"
if [ -f "$OUT/.stamp" ] && [ "$(cat "$OUT/.stamp")" = "$STAMP_TEXT" ] && [ -f "$OUT/lib/libsamesofa-apm.a" ]; then
  echo "webrtc-audio-processing $APM_VERSION already built in Vendor/APM"
  exit 0
fi
command -v meson >/dev/null || { echo "meson not found (brew install meson ninja)" >&2; exit 1; }
command -v ninja >/dev/null || { echo "ninja not found (brew install meson ninja)" >&2; exit 1; }

# Build outside the checkout so no home folder path ends up in the library.
WORK=${SAMESOFA_APM_WORK:-/tmp/samesofa-apm-build}
mkdir -p "$WORK" "$ROOT/Vendor"
TARBALL="$ROOT/Vendor/webrtc-audio-processing-$APM_VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "Downloading $(basename "$TARBALL")..."
  curl -fL --retry 3 -o "$TARBALL.part" "$APM_URL"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$APM_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $TARBALL" >&2; exit 1; }

SRC="$WORK/webrtc-audio-processing-$APM_VERSION"
rm -rf "$SRC"
tar -xf "$TARBALL" -C "$WORK"

LIBS=""
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64) FAMILY=aarch64 ;;
    x86_64) FAMILY=x86_64 ;;
    *) echo "unknown architecture $ARCH" >&2; exit 1 ;;
  esac
  B="$WORK/build-$ARCH"
  rm -rf "$B"
  cat > "$WORK/cross-$ARCH.ini" <<EOF
[binaries]
c = ['clang', '-arch', '$ARCH']
cpp = ['clang++', '-arch', '$ARCH']
ar = 'ar'
strip = 'strip'

[built-in options]
c_args = ['-mmacosx-version-min=$MIN_MACOS']
cpp_args = ['-mmacosx-version-min=$MIN_MACOS']
c_link_args = ['-mmacosx-version-min=$MIN_MACOS']
cpp_link_args = ['-mmacosx-version-min=$MIN_MACOS']

[host_machine]
system = 'darwin'
cpu_family = '$FAMILY'
cpu = '$FAMILY'
endian = 'little'
EOF
  echo "Building webrtc-audio-processing $APM_VERSION ($ARCH)..."
  # Abseil comes from the meson wrap inside the tarball (pinned version and hash).
  meson setup "$B" "$SRC" --cross-file "$WORK/cross-$ARCH.ini" \
    --default-library=static --wrap-mode=forcefallback --buildtype=release -Db_ndebug=true \
    --prefix="$WORK/install-$ARCH" > "$WORK/meson-$ARCH.log" 2>&1 || { tail -30 "$WORK/meson-$ARCH.log" >&2; exit 1; }
  ninja -C "$B" install > "$WORK/ninja-$ARCH.log" 2>&1 || { tail -30 "$WORK/ninja-$ARCH.log" >&2; exit 1; }
  # One archive: the module plus the Abseil pieces it uses.
  find "$B" -name '*.a' > "$WORK/archives-$ARCH.txt"
  # shellcheck disable=SC2046
  libtool -static -o "$WORK/libsamesofa-apm-$ARCH.a" $(cat "$WORK/archives-$ARCH.txt") 2>/dev/null
  LIBS="$LIBS $WORK/libsamesofa-apm-$ARCH.a"
  FIRST_ARCH=${FIRST_ARCH:-$ARCH}
done

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
# shellcheck disable=SC2086
lipo -create $LIBS -output "$OUT/lib/libsamesofa-apm.a"
cp -R "$WORK/install-$FIRST_ARCH/include/webrtc-audio-processing-2/." "$OUT/include/"
cp -R "$WORK/install-$FIRST_ARCH/include/absl" "$OUT/include/absl"
cp "$SRC/COPYING" "$OUT/LICENSE.webrtc-audio-processing"
ABSL=$(find "$SRC/subprojects" -maxdepth 1 -type d -name 'abseil-cpp-*' | head -1)
cp "$ABSL/LICENSE" "$OUT/LICENSE.abseil"
cat > "$OUT/BUILDINFO.txt" <<EOF
webrtc-audio-processing $APM_VERSION (WebRTC audio processing module: AEC3, noise suppression, gain control)
Source: $APM_URL
SHA-256: $APM_SHA256
Licence: BSD-3-Clause (LICENSE.webrtc-audio-processing)
With $(basename "$ABSL") (Apache-2.0, LICENSE.abseil), fetched by the meson wrap in the tarball
Architectures: $ARCHS (macOS $MIN_MACOS+), static, linked into SameSofa
EOF
echo "$STAMP_TEXT" > "$OUT/.stamp"
echo "Built Vendor/APM:"
lipo -info "$OUT/lib/libsamesofa-apm.a"
