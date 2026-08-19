#!/bin/bash
# Gathers everything needed to diagnose Chrome quitting on Set Up Chrome Now.
# Reads only Perch's own log and the newest Chrome crash report. Copy the whole
# output and send it back.
echo "=== versions ==="
echo "macOS   $(sw_vers -productVersion)"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version 2>/dev/null | sed 's/^/Chrome  /'
printf 'Perch   '
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /Applications/Perch.app/Contents/Info.plist 2>/dev/null || echo "not installed"

LOG="$HOME/Library/Application Support/Perch/chrome.log"
echo
echo "=== chrome.log: fatal lines (this is the one that matters) ==="
if [ -f "$LOG" ]; then
  grep -aE "FATAL|CHECK failed|DCHECK|Fatal error" "$LOG" | tail -10 || true
  grep -aqE "FATAL|CHECK failed|DCHECK|Fatal error" "$LOG" || echo "(none found)"
else
  echo "(no chrome.log — is Perch 0.7.3 or newer, and was Set Up Chrome pressed?)"
fi

echo
echo "=== chrome.log: last 20 lines ==="
[ -f "$LOG" ] && tail -20 "$LOG" | cut -c1-200 || echo "(no log)"

echo
echo "=== newest Chrome crash report ==="
R=$(ls -t "$HOME/Library/Logs/DiagnosticReports/"Google\ Chrome*.ips 2>/dev/null | head -1)
if [ -n "$R" ]; then
  echo "file: $(basename "$R")"
  grep -aE "Parent Process|Responsible Process|OS Version|Exception Type|Termination Reason|Crashed Thread" "$R" | head -8
else
  echo "(no Chrome crash report found)"
fi
