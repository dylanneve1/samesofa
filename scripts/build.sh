#!/bin/sh
# Builds SameSofa.app (universal arm64 + x86_64) and packages it as a .zip and .dmg in dist/.
#
#   scripts/build.sh                         # placeholder server address
#   SAMESOFA_SERVER_URL=wss://sofa.example.org scripts/build.sh   # bake in your server
#
# Signing: uses SAMESOFA_SIGN_IDENTITY if set (e.g. "Developer ID Application: ..."),
# with the hardened runtime. Otherwise the app is ad-hoc signed. Never notarizes.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=${SAMESOFA_VERSION:-1.0.0}
BUILD_NUMBER=${SAMESOFA_BUILD_NUMBER:-1}
SERVER_URL=${SAMESOFA_SERVER_URL:-}
ARCHS=${SAMESOFA_ARCHS:-"arm64 x86_64"}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}

scripts/fetch-webrtc.sh

ARCH_FLAGS=""
for a in $ARCHS; do ARCH_FLAGS="$ARCH_FLAGS --arch $a"; done
echo "Building ($ARCHS)..."
# shellcheck disable=SC2086
swift build -c release --product SameSofa $ARCH_FLAGS \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks
BIN_DIR=$(swift build -c release --product SameSofa $ARCH_FLAGS --show-bin-path)

APP="$ROOT/build/SameSofa.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/SameSofa" "$APP/Contents/MacOS/SameSofa"
ditto Vendor/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework "$APP/Contents/Frameworks/WebRTC.framework"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>SameSofa</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>app.samesofa.mac</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>SameSofa</string>
	<key>CFBundleDisplayName</key><string>SameSofa</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSCameraUsageDescription</key><string>SameSofa shows your face to your partner in a little bubble while you watch.</string>
	<key>NSMicrophoneUsageDescription</key><string>SameSofa lets you talk to your partner while you watch.</string>
	<key>SameSofaDefaultServerURL</key><string>$SERVER_URL</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY=${SAMESOFA_SIGN_IDENTITY:-}
if [ -n "$IDENTITY" ]; then
  echo "Signing with $IDENTITY (hardened runtime, not notarized)"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/WebRTC.framework"
  codesign --force --timestamp --options runtime --entitlements Resources/SameSofa.entitlements --sign "$IDENTITY" "$APP"
else
  echo "No signing identity: ad-hoc signing"
  codesign --force --sign - "$APP/Contents/Frameworks/WebRTC.framework"
  codesign --force --entitlements Resources/SameSofa.entitlements --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

mkdir -p dist
ZIP="dist/SameSofa-$VERSION.zip"
DMG="dist/SameSofa-$VERSION.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/SameSofa.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname SameSofa -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Built:"
ls -la "$APP" "$ZIP" "$DMG" | sed 's/^/  /'
shasum -a 256 "$ZIP" "$DMG"
