#!/bin/bash
# Packages build/Perch.app into a drag-to-Applications disk image.
#
# This is a LOCAL build signed with a self-signed identity, not a Developer ID,
# and it is not notarized. Gatekeeper will therefore refuse it on any Mac that
# doesn't trust that certificate, and even on this one it will refuse it after
# the file has been through anything that sets the quarantine attribute
# (download, AirDrop, chat). The README inside the image says how to clear that.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/Perch.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"
DMG="$ROOT/build/Perch-$VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found. Run ./build.sh first." >&2
  exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/Perch.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
Perch
=====

Websites that ask to record your screen only ever get their own page.


1. Drag Perch.app onto the Applications folder shown beside it.

2. The first time you open it, macOS will refuse, because this is a locally
   signed build rather than one notarized by Apple. Two ways past that:

     - Right-click Perch.app in Applications and choose Open, then Open again
       in the dialog that appears. You only do this once.

     - Or, in Terminal:
           xattr -dr com.apple.quarantine /Applications/Perch.app

3. Perch asks macOS for Screen Recording as soon as it opens. macOS never lets
   an app turn that one on for you, so the box just takes you to
   Settings > Privacy & Security > Screen Recording with Perch already listed.
   Switch it on, then press "Relaunch Perch" — the grant only reaches an app
   at launch.

4. Press "Set Up Chrome Now". A SECOND Chrome opens, on its own profile, with
   the extension already loaded. Your everyday Chrome is not touched, not
   closed, and loses no tabs.

   Use that second Chrome for anything you want protected. Chrome does not
   allow an app to protect your default profile, which is why there are two.

That is the whole setup. No chrome://extensions, no Developer Mode.

Screen Recording is the only permission needed.

Source and guide: https://github.com/Calyndrae/Perch
TXT

hdiutil create -quiet \
  -volname "Perch $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

rm -rf "$STAGE"

echo "Built: $DMG"
echo "Size:  $(du -h "$DMG" | cut -f1)"
