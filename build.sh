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
  <key>CFBundleShortVersionString</key>    <string>0.16.0</string>
  <key>CFBundleVersion</key>               <string>1</string>
  <key>LSMinimumSystemVersion</key>        <string>14.0</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
  <key>NSSupportsAutomaticTermination</key><false/>

  <!-- Perch itself uses none of these. They are here because macOS makes the
       spawning process TCC-responsible for its child: when Chrome touches a
       protected resource, macOS looks for a usage string in PERCH's Info.plist
       and kills Chrome outright if it finds none. Perch normally disclaims that
       responsibility, but that call is a private symbol and is not guaranteed
       on every macOS — so these are the fallback that keeps Chrome alive when
       it isn't. Chrome still shows its own permission prompts either way. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>A site in the Chrome window Perch opened is asking to use your microphone. Chrome will ask you before it does.</string>
  <key>NSCameraUsageDescription</key>
  <string>A site in the Chrome window Perch opened is asking to use your camera. Chrome will ask you before it does.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>A site in the Chrome window Perch opened is asking for your location. Chrome will ask you before it does.</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>A site in the Chrome window Perch opened is asking to reach a Bluetooth device. Chrome will ask you before it does.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>A site in the Chrome window Perch opened is asking to use speech recognition. Chrome will ask you before it does.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Chrome, opened by Perch, is reading or saving a file on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Chrome, opened by Perch, is reading or saving a file in your Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Chrome, opened by Perch, is saving a download.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>Chrome, opened by Perch, is reading or saving a file on a removable disk.</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>Chrome, opened by Perch, is reading or saving a file on a network volume.</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>A site in the Chrome window Perch opened is asking for a photo from your library.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Perch asks Chrome to quit and reopen when you set it up.</string>
</dict>
</plist>
PLIST

echo "==> Signing"
"$ROOT/scripts/sign-macos.sh" "$APP"

echo ""
echo "Built: $APP"
echo "Run:   open '$APP'"
