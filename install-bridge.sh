#!/bin/bash
# Registers PerchBridge as a Chrome native-messaging host.
#
# Without this, chrome.runtime.connectNative fails, the extension stays inert,
# and Perch never sees the extension — so nothing works. Run once after building.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"

APP_BINARY="$ROOT/build/Perch.app/Contents/MacOS/PerchBridge"
EXT_ID="$(cat "$ROOT/.extension-id.txt")"
HOST_NAME="com.trixarh.perch.bridge"

if [ ! -x "$APP_BINARY" ]; then
  echo "error: $APP_BINARY not found. Run ./build.sh first." >&2
  exit 1
fi

# Chrome, Chrome Beta/Canary and Chromium each read their own directory.
TARGETS=(
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
  "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
)

for DIR in "${TARGETS[@]}"; do
  PARENT="$(dirname "$DIR")"
  [ -d "$PARENT" ] || continue
  mkdir -p "$DIR"
  cat > "$DIR/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "Perch bridge — lets the Perch app and its extension find each other",
  "path": "$APP_BINARY",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXT_ID/"
  ]
}
JSON
  echo "installed: $DIR/$HOST_NAME.json"
done

echo ""
echo "Extension ID: $EXT_ID"
echo "Next: load $ROOT/Extension as an unpacked extension"
echo "      (chrome://extensions → Developer mode → Load unpacked)"
echo "Then restart Chrome so it picks up the native host."
