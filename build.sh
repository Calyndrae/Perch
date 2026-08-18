#!/bin/bash
# Builds Perch.app without Xcode — Command Line Tools only.
#
# There is no xcodebuild on this machine, so we compile with swiftc and
# assemble the bundle by hand. See scripts/sign-macos.sh for why the stable
# signing identity matters: it is what keeps the Screen Recording grant from
# being revoked on every rebuild.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/Perch.app"
TARGET="arm64-apple-macos14.0"

rm -rf "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling Perch"
swiftc \
  -target "$TARGET" \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit \
  -framework AVFoundation -framework CoreMedia -framework CoreGraphics \
  -o "$APP/Contents/MacOS/Perch" \
  Sources/*.swift

echo "==> Compiling BridgeHost"
swiftc \
  -target "$TARGET" \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -framework Foundation \
  -o "$APP/Contents/MacOS/PerchBridge" \
  BridgeHost/*.swift

echo "==> Bundling extension"
# Perch loads this copy into Chrome via Extensions.loadUnpacked, so the
# extension has to travel inside the .app rather than sit loose in the repo.
cp -R Extension "$APP/Contents/Resources/Extension"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>Perch</string>
  <key>CFBundleDisplayName</key>           <string>Perch</string>
  <key>CFBundleIdentifier</key>            <string>com.trixarh.perch</string>
  <key>CFBundleExecutable</key>            <string>Perch</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>0.2.2</string>
  <key>CFBundleVersion</key>               <string>1</string>
  <key>LSMinimumSystemVersion</key>        <string>14.0</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> Signing"
"$ROOT/scripts/sign-macos.sh" "$APP"

echo ""
echo "Built: $APP"
echo "Run:   open '$APP'"
