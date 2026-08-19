#!/bin/bash
# One command: identifies which part of Perch's Chrome launch is fatal, and
# gathers the evidence. Reads Perch's own log and the newest Chrome crash
# report; changes nothing. Takes about 40 seconds.
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
LOG="$HOME/Library/Application Support/Perch/chrome.log"
SCRATCH="/tmp/perch-bisect-$$"
OUT="/tmp/perch-bisect.log"; : > "$OUT"

echo "=== versions ==="
echo "macOS   $(sw_vers -productVersion)"
"$CHROME" --version 2>/dev/null | sed 's/^/Chrome  /'
printf 'Perch   '
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /Applications/Perch.app/Contents/Info.plist 2>/dev/null || echo "not installed"

# Which launch is fatal? Death by signal is a crash; a plain exit is not.
# Chrome given --remote-debugging-pipe with nothing on fds 3/4 exits cleanly by
# design, so exit status has to be distinguished from a signal.
try() {
  local name="$1"; shift
  rm -rf "$SCRATCH"
  "$CHROME" "$@" >>"$OUT" 2>&1 &
  local pid=$!
  sleep 6
  if kill -0 "$pid" 2>/dev/null; then
    echo "  ok        running        $name"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  else
    wait "$pid" 2>/dev/null; local st=$?
    if [ "$st" -gt 128 ]; then
      local sig=$((st-128)); local tag="signal $sig"
      [ "$sig" = 5 ] && tag="SIGTRAP <-- the crash"
      echo "  CRASHED   $tag   $name"
    else
      echo "  exited    status $st (clean)   $name"
    fi
  fi
  sleep 1
}

echo
echo "=== which launch is fatal ==="
C=(--no-first-run --no-default-browser-check --enable-logging=stderr)
try "plain, scratch profile"        "${C[@]}" --user-data-dir="$SCRATCH"
try "plain, Perch's profile"        "${C[@]}" --user-data-dir="$HOME/Library/Application Support/Perch/ChromeProfile"
try "+ auto-accept-this-tab-capture" "${C[@]}" --user-data-dir="$SCRATCH" --auto-accept-this-tab-capture
try "+ remote-debugging-pipe"        "${C[@]}" --user-data-dir="$SCRATCH" --remote-debugging-pipe
try "everything Perch passes"        "${C[@]}" --user-data-dir="$SCRATCH" --remote-debugging-pipe --auto-accept-this-tab-capture
rm -rf "$SCRATCH"

echo
echo "=== chrome.log tail ==="
[ -f "$LOG" ] && tail -12 "$LOG" | cut -c1-170 || echo "(no log — install 0.7.3+ and press Set Up Chrome first)"

echo
echo "=== newest Chrome crash report ==="
R=$(ls -t "$HOME/Library/Logs/DiagnosticReports/"Google\ Chrome*.ips 2>/dev/null | head -1)
if [ -n "$R" ]; then
  echo "file: $(basename "$R")"
  # .ips is two concatenated JSON documents, not text — grep finds nothing.
  python3 - "$R" <<'PY'
import json, sys
raw = open(sys.argv[1], errors="replace").read()
try:
    body = json.loads(raw.split("\n", 1)[1])
except Exception:
    print("  (could not parse)"); raise SystemExit
for k in ("parentProc", "responsibleProc", "procLaunch", "captureTime"):
    if body.get(k): print(f"  {k}: {body[k]}")
ex = body.get("exception", {})
print(f"  exception: {ex.get('type')} {ex.get('signal') or ''} {ex.get('codes') or ''}")
t = body.get("termination", {})
if t: print(f"  termination: ns={t.get('namespace')} code={t.get('code')} {t.get('reasons') or ''}")
# Name the frame that trapped, so the crash site is identifiable.
for th in body.get("threads", []):
    if th.get("triggered"):
        f = (th.get("frames") or [{}])[0]
        imgs = body.get("usedImages", [])
        name = imgs[f["imageIndex"]].get("name") if f.get("imageIndex") is not None and f["imageIndex"] < len(imgs) else "?"
        print(f"  crashed in: {name} +{f.get('imageOffset')}")
        break
PY
else
  echo "(no crash report found)"
fi
