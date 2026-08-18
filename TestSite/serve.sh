#!/bin/bash
# Serves the hostile test page on http://localhost:8765
#
# Serves from the PROJECT ROOT, not TestSite/, so the page can load the real
# Extension/inject.js in simulate mode — the test then exercises the actual
# shipped file rather than a copy that could drift.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-8765}"
echo "VidTube test harness"
echo "  real (needs extension):  http://localhost:$PORT/TestSite/"
echo "  simulate injection:      http://localhost:$PORT/TestSite/?simulate=1"
echo "Ctrl-C to stop."
exec python3 -m http.server "$PORT" --bind 127.0.0.1
