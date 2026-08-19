#!/bin/bash
# Finds which part of Perch's Chrome launch makes Chrome quit.
#
# Perch launches Chrome with several unusual things at once: a debugging pipe on
# inherited fds, an auto-accept capture flag, its own profile, and a spawn that
# disclaims TCC responsibility. A crash tells you none of that. This runs the
# same launches one difference at a time and reports which survive.
#
# Run it on the Mac where Chrome quits. It touches nothing but a scratch profile.
set -uo pipefail

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="$HOME/Library/Application Support/Perch/ChromeProfile"
SCRATCH="/tmp/perch-diagnose-$$"
LOG="/tmp/perch-diagnose.log"
: > "$LOG"

[ -x "$CHROME" ] || { echo "Chrome not found at $CHROME"; exit 1; }
echo "macOS $(sw_vers -productVersion)  |  Chrome $("$CHROME" --version 2>/dev/null | awk '{print $3}')"
echo

# Runs Chrome and reports how it ended.
#
# Exiting is not the same as crashing, and conflating them sends you after the
# wrong thing: Chrome given --remote-debugging-pipe with nothing on fds 3 and 4
# exits cleanly and on purpose, which is not the failure being hunted. A crash
# shows up as death by signal — SIGTRAP (133) is the one in the crash report.
try() {
  local name="$1"; shift
  rm -rf "$SCRATCH"
  "$CHROME" "$@" >>"$LOG" 2>&1 &
  local pid=$!
  sleep 6
  if kill -0 "$pid" 2>/dev/null; then
    echo "  ok        still running          $name"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  else
    wait "$pid" 2>/dev/null
    local st=$?
    if [ "$st" -gt 128 ]; then
      local sig=$((st - 128))
      local label="signal $sig"
      [ "$sig" = "5" ] && label="SIGTRAP — this is the crash"
      echo "  CRASHED   $label   $name"
    else
      echo "  exited    status $st (not a crash)   $name"
    fi
  fi
  sleep 1
}

COMMON=(--no-first-run --no-default-browser-check --enable-logging=stderr)

echo "Launching Chrome each way for 6 seconds:"
try "plain Chrome, scratch profile"                 "${COMMON[@]}" --user-data-dir="$SCRATCH"
try "plain Chrome, PERCH's profile"                 "${COMMON[@]}" --user-data-dir="$PROFILE"
try "+ auto-accept-this-tab-capture"                "${COMMON[@]}" --user-data-dir="$SCRATCH" \
      --auto-accept-this-tab-capture
# Expected to exit cleanly everywhere: nothing is reading fds 3 and 4 from a
# shell. Included so a plain exit is visible next to a real crash.
try "+ remote-debugging-pipe (exits by design)"      "${COMMON[@]}" --user-data-dir="$SCRATCH" \
      --remote-debugging-pipe
try "everything Perch passes"                       "${COMMON[@]}" --user-data-dir="$SCRATCH" \
      --remote-debugging-pipe --auto-accept-this-tab-capture

rm -rf "$SCRATCH"
echo
echo "Anything fatal Chrome printed:"
grep -aE "FATAL|CHECK failed|DCHECK|Fatal error" "$LOG" | tail -8 | sed 's/^/  /' \
  || echo "  (nothing fatal in the log)"
echo
echo "Full output: $LOG"
echo
echo "Reading this:"
echo "  CRASHED on any line  -> that flag is the cause, and the line names it."
echo "  no CRASHED lines     -> the flags are fine, and the problem is how Perch"
echo "                          spawns Chrome, not what it passes."
echo
echo "Either way, send this output plus:"
echo "  ~/Library/Application Support/Perch/chrome.log"
