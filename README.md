# Perch

**Websites that ask to record your screen only ever get their own page.**
No picker, no chance to grab anything else — and they can't tell.

macOS only.

---

## What it actually does

| Without Perch | With Perch |
|---|---|
| "Share your screen?" → you pick → the site watches **everything**, including when you switch to Discord | The picker appears as normal, you pick anything you like, and the site receives **its own tab** |
| Exit-intent popups when your mouse drifts toward the tab bar | Gone |
| "Are you sure you want to leave?" | Gone |
| — | Optional: float any Chrome window on top while you do other things |

The site isn't told it was fenced in. It's handed `displaySurface: "monitor"` and a
track labelled `Entire screen`, so it believes it got the whole display. Any audio
it receives is that tab's own sound — never your microphone, never system audio.

---

## Install

Download **Perch-x.y.z.dmg** from
[Releases](https://github.com/Calyndrae/Perch/releases), drag **Perch.app** to
Applications, then:

**1. macOS will refuse to open it the first time.** This is a personal build,
signed locally rather than notarized by Apple. Either right-click Perch.app →
**Open** → **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Perch.app
```

**2. Allow Screen Recording.** Perch asks the moment it opens. macOS never lets an
app switch this on for you, so the box just takes you to the right Settings pane
with Perch already listed — flip the switch, then press **Relaunch Perch**.

**3. Press "Set Up Chrome Now".** A second Chrome opens with the extension already
loaded.

That's it. There's no `chrome://extensions`, no Developer Mode, no dragging folders.

---

## The one thing to understand

You end up with **two Chromes**:

- **Your everyday Chrome** — untouched, all your tabs and logins, *no protection*
- **Perch's Chrome** — separate profile, and the only one that's protected

Chrome forbids an app from injecting into your default profile, so this split isn't
a design choice — it's the only arrangement Chrome permits. Sign into Perch's Chrome
once and it sticks.

**Use Perch's Chrome for anything you want protected.**

---

## Using it

Just browse in Perch's Chrome. The protection is always on — there's nothing to
switch on per-site.

To float a window on top while you do something else:

1. In Perch, press **Mirror** next to the window you want
2. Drag and resize the floating window anywhere; it stays on top and follows you
   between Spaces
3. Bury Chrome behind Discord — the mirror keeps playing
4. Click and scroll **in the mirror** to control the page. Chrome never comes to
   the front. Typing isn't forwarded — click into Chrome itself to type.

---

## Checking it works

```bash
cd ~/GIT/Perch && ./TestSite/serve.sh
```

Open these **in Perch's Chrome**:

| Page | What you should see |
|---|---|
| `localhost:8765/TestSite/screengrab.html` | Press the button. No picker appears. It reports `Entire screen` but the frame is your own tab. |
| `localhost:8765/TestSite/exitintent.html` | Title reads **`matrix 8/8 blocked`** — eight real exit-intent techniques, all dead |
| `localhost:8765/TestSite/` | Diagnostics all `OK`, no red "close the app" wall |

Open `exitintent.html` in your **normal** Chrome for contrast — it'll say `0/8`.

---

## If something looks wrong

Perch's status line names which half is unhappy.

**"Extension not connected"** → press **Set Up Chrome Now** again. Especially after
restarting Perch: the connection to Chrome belongs to whichever Perch opened it, so
a fresh Perch needs a fresh Chrome. Same profile, nothing lost.

**Window list looks stale** → it refreshes itself every couple of seconds; the
**Refresh** button is there if you're impatient.

**Chrome opened from the Dock** → that one has no extension. Perch can only use the
Chrome it started.

---

## Updating

Both halves update themselves from GitHub every time Perch opens — the app and
the extension. **Settings → Updates** shows both versions and has a **Check Now**
if you're impatient.

An update is only installed if it carries **the same signature as the copy you're
running**, so a tampered or substituted download is discarded and the working
copy is left alone. The old version goes to the Trash rather than being deleted.

The swap happens on disk; the running copy keeps going until you relaunch, so an
update never pulls the app out from under you mid-session.

One bootstrap note: self-updating only works from a version that already has it,
so anything at **0.9.0 or earlier must be replaced by hand once**.

---

## Can the extension be locked so nobody removes it?

Not with a real *"Installed by your administrator"* lock. Chrome refuses to
force-install an off-store extension on a machine that isn't enterprise-managed —
its own words: *"this computer is not managed by an enterprise, so policy can
only install extensions from the Chrome Web Store."* That would need publishing
to the Web Store, or genuine MDM enrolment.

What happens instead: Perch notices within a few seconds that its extension has
gone and loads it again, and it reloads everything at every launch regardless. So
removing it in `chrome://extensions` lasts until Perch next looks, and never
survives a restart.

Verified by having the extension uninstall itself — workers went 1 → 0 → 1.

---

## Adding your own extensions

Perch's Chrome runs on its own profile, so whatever you have installed in your
everyday Chrome isn't there. **Settings → Your extensions** fixes that: add a
folder, a `.zip` or a `.crx`, and it loads every time Perch starts Chrome.

Each one has a switch, so you can turn one off without removing it, and
**Remove** puts it in the Trash rather than deleting it — you may not have
another copy.

Perch's own extension is loaded first and its failure is fatal, since nothing
works without it. Yours are loaded individually afterwards, so one bad folder
costs you that extension and not the browser.

Worth being plain about: an extension you add can read and change pages in
Perch's Chrome, exactly as it could in any browser. Only add ones you'd install
normally.

---

## Uninstalling

**Settings → Uninstall** lists everything Perch put on your Mac, with sizes, and
moves it all to the **Trash** — nothing is erased, so you can put it back.

Perch's Chrome profile is a **separate, opt-in checkbox, off by default**. It is
the only item that holds anything of yours — the sites you signed into there, your
history and cookies — and it is by far the largest. Leaving it off removes about a
megabyte and keeps the profile ready if you reinstall.

Two things worth knowing:

- If you do include the profile, Perch closes its Chrome first. Trashing a profile
  that Chrome still has open leaves it half-written, which would defeat the point
  of it being recoverable.
- macOS keeps the Screen Recording permission in a database no app may edit, so
  Perch will still be listed under Privacy & Security afterwards. Switch it off
  there yourself — Settings links you straight to the pane.

---

## Building from source

```bash
cd ~/GIT/Perch && ./build.sh && ./make-dmg.sh
```

No Xcode required — `swiftc` and the Command Line Tools are enough. `build.sh`
assembles the `.app` by hand.

The extension is fetched from this repo at launch and verified before loading: its
manifest key is hashed and must derive exactly the extension ID the app was built
against. A mismatch is rejected and the copy inside the app is used instead.

---

## How it works, and what it cost

<details>
<summary><b>Why a site can't refuse to be fenced in</b></summary>

`navigator.mediaDevices.getDisplayMedia` is replaced before any page script runs.
The site's own constraints reach the native call untouched, so Chrome's real
picker appears with every option present.

Whatever gets chosen is stopped immediately — before a frame can be read from it
— and a second capture of the current tab is returned in its place. That second
call is silent because Chrome runs with `--auto-accept-this-tab-capture`, and
both calls fit inside one user gesture (verified).

It **fails closed**: if the tab capture can't be obtained, the site is told
permission was denied rather than handed the screen it picked.

An earlier version suppressed the picker outright. That broke real sites — one
refused entry because it never saw the share flow happen at all.

The returned track is then disguised — `getSettings()` reports
`displaySurface: "monitor"`, and `label` reads `Entire screen`. A site that checks
either would otherwise know, and the whole point is that it must not.

Everything installed reports `[native code]` under `toString`, and nothing is
defined on `document` or `body` themselves. Both are things an anti-spoof scanner
greps for.
</details>

<details>
<summary><b>Why Perch runs its own Chrome profile</b></summary>

Every off-store route for installing an extension is closed on macOS, measured
against Chrome 151:

| Method | Result |
|---|---|
| External-extensions JSON + local `.crx` | Blocked since Chrome 44 |
| `--load-extension` | Removed from branded Chrome in 137 |
| Policy force-install, self-hosted URL | *"not enterprise-managed, so policy can only install from the Web Store"* |
| **CDP `Extensions.loadUnpacked`** | **Works** |

So Perch drives Chrome over the DevTools protocol. Chrome 136+ then refuses
`--remote-debugging-pipe` on the default profile — anti-malware hardening, since
CDP on a logged-in profile can read cookies and passwords. A separate profile is
the only configuration Chrome allows.

The pipe variant is used rather than `--remote-debugging-port` deliberately: the
port opens a localhost listener *any* local process could drive. The pipe talks
over inherited file descriptors, so only Perch can reach it. Verified with `lsof`:
no listener is opened.
</details>

<details>
<summary><b>Clicking through the mirror</b></summary>

Input goes over the same DevTools pipe, via `Input.dispatchMouseEvent`. No
Accessibility permission, no cursor to fight over, and Chrome never comes forward.

The obvious approach doesn't work. Measured against the same window, same
coordinates:

| Delivery | Page received it |
|---|---|
| `CGEvent.postToPid`, Chrome backgrounded | no |
| `CGEvent.postToPid`, Chrome **frontmost** | no |
| `CGEvent.post(tap: .cghidEventTap)` | yes, exact |

Chromium takes mouse input from the window server's stream, not per-process posted
events, so `postToPid` is silently dropped.
</details>

<details>
<summary><b>Two traps worth knowing if you work on this</b></summary>

**Attaching a debugger to a service worker restarts it.** Any probe that attaches
also silently repairs the thing it's measuring. Several readings here were wrong
for that reason before a contradiction — a live port with no host process — gave it
away.

**`posix_spawn` makes the parent TCC-responsible for the child.** Chrome spawned by
Perch was killed by macOS the moment a page asked for the microphone, because TCC
checked *Perch's* Info.plist for a usage string. The spawn disclaims responsibility
so Chrome answers for itself.
</details>

---

## Limits

- **Only Perch's Chrome is protected.** Your everyday Chrome isn't.
- **Restarting Perch** severs its link to Chrome — press *Set Up Chrome Now* again.
- **Keyboard input isn't forwarded** to the mirror, and clicks reach page content
  only, not the tab strip or address bar.
- **Chrome only.** No Firefox or Safari.
- **Not notarized** — it will be blocked outright on anyone else's Mac.
