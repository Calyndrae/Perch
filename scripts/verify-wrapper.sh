#!/bin/bash
# Verifies the screen-share wrapper does what it claims, without needing a
# picker, a click, or a focused window.
#
# The page stubs the native getDisplayMedia and watches what inject.js does with
# it: which constraints reach the picker, whether the picked stream is stopped,
# what the site ends up holding, and whether a failed tab capture denies rather
# than leaks.
#
# It runs in a CLEAN Chrome on purpose. In Perch's Chrome the extension has
# already patched the prototype at document_start, so the page's stub would
# overwrite the wrapper and the test would silently measure nothing.
set -uo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT=9455
PROFILE="/tmp/perch-verify-$$"
[ -x "$CHROME" ] || { echo "Chrome not found"; exit 1; }

# The page and inject.js are served from the repo root.
if ! curl -s -o /dev/null http://localhost:8765/TestSite/wrapper-unit.html; then
  ./TestSite/serve.sh >/tmp/perch-verify-serve.log 2>&1 &
  SERVER=$!; sleep 2
fi

rm -rf "$PROFILE"
"$CHROME" --user-data-dir="$PROFILE" --remote-debugging-port=$PORT \
  --no-first-run --no-default-browser-check --headless=new \
  "http://localhost:8765/TestSite/wrapper-unit.html" >/dev/null 2>&1 &
CHROME_PID=$!
sleep 7

python3 - "$PORT" <<'PY'
import base64, json, os, socket, struct, sys, time, urllib.request
port = sys.argv[1]
t = [x for x in json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
     if x.get("type") == "page"][0]
_, rest = t["webSocketDebuggerUrl"].split("://", 1)
hp, path = rest.split("/", 1); host, p = hp.split(":")
s = socket.create_connection((host, int(p)))
k = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET /{path} HTTP/1.1\r\nHost: {hp}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {k}\r\n"
           f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf: buf += s.recv(4096)
buf = buf.split(b"\r\n\r\n", 1)[1]
d = json.dumps({"id":1,"method":"Runtime.evaluate","params":{
    "expression":"window.__unit || document.getElementById('out').textContent",
    "returnByValue":True,"awaitPromise":True}}).encode()
h = bytearray([0x81]); m = os.urandom(4); n = len(d)
if n < 126: h.append(0x80|n)
else: h.append(0x80|126); h += struct.pack(">H", n)
h += m
s.sendall(bytes(h) + bytes(b ^ m[i%4] for i, b in enumerate(d)))
time.sleep(1)
def need(k_):
    global buf
    while len(buf) < k_: buf += s.recv(65536)
need(2); ln = buf[1] & 0x7F; off = 2
if ln == 126: need(4); ln = struct.unpack(">H", buf[2:4])[0]; off = 4
need(off+ln)
print(json.loads(buf[off:off+ln]).get("result",{}).get("result",{}).get("value","(no output)"))
PY

kill $CHROME_PID 2>/dev/null; rm -rf "$PROFILE"
[ -n "${SERVER:-}" ] && kill $SERVER 2>/dev/null
