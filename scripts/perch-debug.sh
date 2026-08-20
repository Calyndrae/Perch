{
P=/Applications/Perch.app; S="$HOME/Library/Application Support/Perch"
NOISE='chrome/updater|VERBOSE|crashpad|/RLZ/|gcm/engine|TSM Adjust|garbage_collector|DEPRECATED_ENDPOINT'
echo "===== PERCH DEBUG $(date -u +%FT%TZ) ====="
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))   $(sysctl -n hw.model)"

echo; echo "--- Perch ---"
if [ -d "$P" ]; then
  echo "version    : $(defaults read "$P/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
  echo "quarantine : $(xattr -p com.apple.quarantine "$P" 2>/dev/null || echo none)"
  echo "signature  : $(codesign -dv "$P" 2>&1 | grep -c 'Identifier=com.trixarh.perch') (1 = signed as expected)"
  codesign --verify --deep "$P" 2>&1 | head -3 | sed 's/^/verify     : /'
else
  echo "NOT INSTALLED at $P"; ls -d /Applications/*erch* 2>/dev/null
fi
echo "running    : $(pgrep -f 'Perch.app/Contents/MacOS/Perch' | tr '\n' ' ' || echo NO)"
# sed, not python3: a Mac without Command Line Tools has no python3, and the
# fallback text made a perfectly good extension look like a failed download.
EXTVER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$S/Extension/manifest.json" 2>/dev/null | head -1)
if [ -n "$EXTVER" ]; then echo "extension  : $EXTVER"
elif [ -f "$S/Extension/manifest.json" ]; then echo "extension  : manifest present but no version in it — CORRUPT"
else echo "extension  : not downloaded"; fi
echo "python3    : $(command -v python3 >/dev/null 2>&1 && echo yes || echo 'no (fine — nothing here needs it)')"
echo "chrome up to date? compare the version below against the newest Chrome release"

echo; echo "--- Chrome ---"
echo "version        : $(defaults read '/Applications/Google Chrome.app/Contents/Info.plist' CFBundleShortVersionString 2>/dev/null || echo 'NOT FOUND')"
echo "perch's chrome : $(pgrep -f "user-data-dir=$S" | tr '\n' ' ' || echo 'not running')"
echo "other chrome   : $(pgrep -x 'Google Chrome' | tr '\n' ' ' || echo none)"

echo; echo "--- Files ---"
for f in "$S/ChromeProfile" "$S/chrome.log" "$S/bridge.sock" "$S/Extension/manifest.json" \
         "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.trixarh.perch.bridge.json" \
         "$S/ChromeProfile/NativeMessagingHosts/com.trixarh.perch.bridge.json"; do
  if [ -e "$f" ]; then echo "  ok      ${f#$HOME/}"; else echo "  MISSING ${f#$HOME/}"; fi
done
[ -f "$S/chrome.log" ] && echo "  chrome.log last written: $(date -r "$S/chrome.log" '+%F %T')"

echo; echo "--- Screen Recording ---"
if sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "select 1" >/dev/null 2>&1; then
  sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
    "select client,auth_value from access where service='kTCCServiceScreenCapture';" 2>&1 | sed 's/^/  /'
  echo "  (auth_value 2 = allowed, 0 = denied; Perch absent = never granted)"
else
  echo "  can't read TCC (normal). Check System Settings > Privacy > Screen Recording by eye."
fi

echo; echo "--- Anything fatal in chrome.log ---"
if [ -f "$S/chrome.log" ]; then
  grep -E 'FATAL|Check failed|CHECK failed|SIGTRAP|SIGSEGV|SIGABRT|Aborted' "$S/chrome.log" | tail -5 | sed 's/^/  /'
  [ -z "$(grep -E 'FATAL|Check failed|SIGTRAP|SIGABRT' "$S/chrome.log")" ] && echo "  (nothing fatal logged)"
else echo "  (no chrome.log — Perch may never have launched Chrome)"; fi

echo; echo "--- chrome.log, last 25 real lines ---"
[ -f "$S/chrome.log" ] && grep -v -E "$NOISE" "$S/chrome.log" | tail -25 | sed 's/^/  /' || echo "  (none)"

echo; echo "--- What Perch last asked Chrome to do ---"
if [ -f "$S/perch-cdp.log" ]; then
  echo "  (log written $(date -r "$S/perch-cdp.log" '+%F %T'))"
  tail -30 "$S/perch-cdp.log" | sed 's/^/  /'
else
  echo "  (no perch-cdp.log — needs Perch 0.17.0 or newer, and one launch attempt)"
fi

echo; echo "--- Crash reports, last 3 days ---"
found=0
for pat in "Google Chrome" "Perch"; do
  # -print0 / read -r because these filenames contain a space, which a bare
  # for-loop splits into two nonexistent paths.
  find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports \
       -name "$pat*" -mtime -3 -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -2 | while IFS= read -r r; do
      echo "  ### ${r##*/}"
      grep -E -m 10 '"exceptionType"|"signal"|"termination"|"namespace"|"reason"|"code"|parentProc|"procName"|"app_version"|Exception Type|Termination Reason|Crashed Thread' "$r" 2>/dev/null | cut -c1-200 | sed 's/^/    /'
    done
  find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports \
       -name "$pat*" -mtime -3 -print0 2>/dev/null | grep -qz . && found=1
done
[ "$found" = 0 ] && echo "  (none — so nothing crashed; it was closed or never started)"
echo; echo "===== END ====="
} 2>&1
