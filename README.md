# Perch

Mirror one Chrome window into a floating macOS window, and kill the
leaving-the-page nags.

Two pieces that only work together:

- **Perch.app** — captures a single Chrome window with ScreenCaptureKit and
  shows it in a floating, clickable window. Because the mirror is an ordinary
  app window, you can share *it* to a website instead of your screen, and the
  site only ever sees that one Chrome window.
- **Perch Bridge** (Chrome extension, no UI) — blocks exit-intent popups and
  unload prompts.

## Scope

The extension deliberately does **not** touch `document.hidden`,
`visibilityState`, `hasFocus()`, `visibilitychange` or `blur`. A separate
extension owns page visibility, and two extensions fighting over the same
accessors is how you get a page that behaves differently on every reload.

Perch's half is the nags: the exit-intent popup, and the "are you sure you want
to leave" prompt.

## Setup

```bash
cd ~/GIT/Perch && ./build.sh && open build/Perch.app
```

That's it. On first run Perch:

1. registers its native-messaging host (re-registers on every launch, so moving
   the app fixes itself instead of silently breaking),
2. pulls the newest extension from GitHub,
3. offers **Set Up Chrome Now**, which restarts Chrome with the extension
   already loaded.

## Packaging

```bash
./make-dmg.sh
```

Produces `build/Perch-<version>.dmg` — drag-to-Applications, with a READ ME
covering the Gatekeeper step.

Because this is signed with a local self-signed identity rather than a
Developer ID, and isn't notarized, macOS will refuse it on first open once the
file has picked up a quarantine flag from a download or transfer. Right-click →
Open once, or `xattr -dr com.apple.quarantine /Applications/Perch.app`. On
another person's Mac it will be blocked outright — this is a personal build,
not a distributable one.

## Permissions

Perch asks macOS itself rather than telling you to go hunting in System
Settings. The Screen Recording dialog is raised automatically on first launch,
and Accessibility is raised from the button in Settings.

Two macOS facts shape this, and the UI is written around them rather than
pretending otherwise:

- **TCC prompts once.** The first `CGRequestScreenCaptureAccess()` shows a
  dialog; every call after that returns the stored answer silently with nothing
  on screen. So Perch asks immediately at launch, while asking still does
  something, and once that prompt is spent the button changes to a deep link
  into the exact Settings pane instead of staying there to be clicked uselessly.
- **Screen Recording can't be granted from the dialog.** macOS never offers an
  inline "Allow" for it — the box only has *Open System Settings* and *Deny*.
  Perch's wording says that plainly instead of telling you to press an Allow
  button that doesn't exist.

After switching Perch on in Settings you have to relaunch, because macOS hands a
Screen Recording grant to a process at launch and not after. There's a
**Relaunch Perch** button for exactly that.

The stable signing identity matters here too: TCC keys its record to the code
signature, so an ad-hoc build would burn its one prompt on every rebuild and be
stuck in the deep-link path forever.

## Why Perch runs its own Chrome profile

Chrome has closed every other route on macOS. Measured against Chrome 151:

| Method | Result |
|---|---|
| External-extensions JSON + local `.crx` | Blocked on macOS since Chrome 44 |
| `--load-extension` | Removed from branded Chrome in 137 |
| `ExtensionInstallForcelist` + self-hosted URL | Refused — *"this computer is not enterprise-managed, so policy can only install extensions from the Chrome Web Store"* |
| `ExtensionInstallForcelist` + Web Store | Works, but requires publishing |
| **CDP `Extensions.loadUnpacked`** | **Works** — the Chromium-sanctioned replacement for `--load-extension` |

So Perch spawns Chrome with `--remote-debugging-pipe` and loads the extension
over the DevTools protocol.

**That requires a separate profile.** Chrome 136+ ignores both
`--remote-debugging-pipe` and `--remote-debugging-port` on the default user data
directory — anti-malware hardening, since CDP on a logged-in profile can read
cookies and passwords. Perch therefore runs Chrome on its own profile under
`~/Library/Application Support/Perch/ChromeProfile`. Signing in there is a
one-time cost, and your everyday Chrome is never touched or quit: the two run
side by side.

One consequence worth knowing: Chrome resolves user-level native-messaging
manifests relative to the *user data directory*, so the bridge manifest is
installed into that profile as well as the default one.

**On the pipe, specifically.** The `--remote-debugging-port` variant opens a
localhost listener that *any* local process can connect to and use to read your
cookies and drive your browser. The pipe variant talks over inherited file
descriptors 3 and 4, so only Perch can ever speak to that Chrome. Verified with
`lsof`: no TCP listener is opened.

The cost: the extension lives only in Chrome sessions Perch started. Launch
Chrome from the Dock and Perch will offer to restart it.

## Self-updating

The extension is fetched from `Calyndrae/Perch` on GitHub, so a fix ships
without rebuilding the app. Because this downloads code that Chrome then runs on
every page:

- **HTTPS only** — any other scheme is refused outright.
- **Identity is verified.** The downloaded manifest's `key` is SHA-256'd and must
  derive exactly the extension ID Perch was built against
  (`bgcnjnfhpcimijankdloldghafhjaami`). A different key is a different extension
  and is rejected, not loaded. This is also what keeps the native-messaging
  `allowed_origins` entry valid.
- **Perch never executes any of it**; it only hands Chrome a directory.
- **The copy inside Perch.app is kept as a fallback**, so a failed download, an
  offline machine or a tampered payload degrades to the known-good version
  rather than to nothing. Tested against a 404.

> The repo must be **public** for this to work — `codeload.github.com` requires
> authentication for private repos, and embedding a GitHub token in the app
> would be worse than the problem it solves.

## Clicking through the mirror

Input travels over the same DevTools pipe Perch already holds, via
`Input.dispatchMouseEvent`. That means no Accessibility permission, no cursor to
fight over, and Chrome never comes to the front.

The obvious approach — synthesising a `CGEvent` and posting it to Chrome's pid —
does not work, and it is worth recording why. Measured three ways against the
same window at the same coordinates:

| Delivery | Page received it |
|---|---|
| `CGEvent.postToPid`, Chrome in background | no |
| `CGEvent.postToPid`, Chrome **frontmost** | no |
| `CGEvent.post(tap: .cghidEventTap)` | yes, exact coordinates |

Chromium takes mouse input from the window server's event stream, not from
per-process posted events, so `postToPid` is silently dropped. The global tap
works but goes wherever the pointer is, which defeats the point of a mirror you
use while doing something else.

Picking the right tab matters too: Perch matches the page to the mirrored window
with `Browser.getWindowForTarget`, then picks the active tab among that window's
by checking `document.visibilityState`. That second step works precisely because
the extension no longer spoofs visibility.

## Testing

```bash
./TestSite/serve.sh
```

- `http://localhost:8765/TestSite/` — needs the extension actually loaded
- `?simulate=1` — loads the real `Extension/inject.js` directly, so you can
  exercise the payload without installing anything

`VidTube` is a deliberately hostile video page: exit-intent popup, unload
prompt, pause-on-leave, "are you still watching?", **and an active anti-spoof
scan** that throws an adblock-style "close the app to continue" wall when it
catches you patching. Probes are grouped by whose job they are, so a CAUGHT in
*Not Perch's job* is expected rather than a failure.

Current state: **10/10 clean** on Perch's own probes and the anti-spoof scan.

## The mutual gate

Neither half runs alone, by design.

- The extension opens a long-lived native-messaging port to `PerchBridge`. No
  app → it never registers its content script and goes completely inert.
- That same port is how Perch knows the extension exists. No connection → Perch
  shows a setup screen instead of mirroring.

The extension has no popup and no options page. Its one visible surface is a
single notification when the app is missing, because at that point there is
nothing else left to tell you why nothing is happening.

## Signing

`scripts/sign-macos.sh` is taken unchanged from RemielleDesktopAgent, and its
reasoning applies exactly here. Ad-hoc signatures change every build, and TCC
keys its grants to the signature — so every rebuild would revoke Screen
Recording. The stable self-signed identity gives every build the same designated
requirement (`identifier "com.trixarh.perch" and certificate leaf = H"fe409f80…"`)
— the *certificate* hash, not the build hash. Grant Screen Recording once and
rebuilds keep it.

## Build notes

No Xcode on this machine, only Command Line Tools. `build.sh` compiles with
`swiftc` and assembles the `.app` by hand. Nothing needs `xcodebuild`.

Two fd traps are handled in `ChromeLauncher.spawnChrome`, both of which silently
break the pipe if you get them wrong: `pipe()` hands out low fds so a plain
`close()` can kill an fd a previous `dup2` just installed, and `dup2(fd, fd)` is
a no-op that does *not* clear `FD_CLOEXEC`.

## Known limits

- **Keyboard input is not forwarded.** Clicks and scrolling are.
- Input reaches **page content only** — not the tab strip or address bar.
- **Chrome only.** Firefox and Safari are not supported.
- Chrome started outside Perch won't have the extension.
- Not sandboxed, not notarized; local-only build.

## Measured, for the record

Covering a Chrome window does **not** throttle it on macOS — it stays at 60fps,
so the mirror stays live behind Discord with no configuration at all. Switching
to a different **tab** drops the page to 0fps. That distinction matters if you
run a visibility-spoofing extension: a site can check "claims visible but isn't
animating", and a background tab gives that away. Give the page you're mirroring
its own Chrome window and leave that window's tab alone.
