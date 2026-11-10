#!/bin/sh
# Downloads the prebuilt WebRTC.xcframework (Google WebRTC M157, BSD-3-Clause,
# packaged by github.com/stasel/WebRTC) into Vendor/ and verifies its checksum.
set -eu
cd "$(dirname "$0")/.."
VERSION=157.0.0
URL="https://github.com/stasel/WebRTC/releases/download/$VERSION/WebRTC-M157.xcframework.zip"
SHA256=ffb1221be2138ecc6bc92300ae4f0157e18694d652db9921e4251992ea91a328
if [ -d Vendor/WebRTC.xcframework ] && [ -f Vendor/.webrtc-$VERSION ]; then exit 0; fi
mkdir -p Vendor
echo "Downloading WebRTC $VERSION..."
curl -fsSL -o Vendor/WebRTC.zip "$URL"
echo "$SHA256  Vendor/WebRTC.zip" | shasum -a 256 -c -
rm -rf Vendor/WebRTC.xcframework
(cd Vendor && unzip -q WebRTC.zip && rm WebRTC.zip)
touch Vendor/.webrtc-$VERSION
