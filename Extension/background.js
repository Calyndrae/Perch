// Service worker: the mutual-dependency gate.
//
// The extension does nothing at all unless Perch.app is running. It learns that
// by opening a long-lived native-messaging port to PerchBridge — which doubles
// as the signal Perch uses to know the extension exists. One connection proves
// both directions.
//
// No popup, no options page, no toolbar UI. The single notification below is the
// one exception: when the app is missing there is no other surface left to tell
// you why nothing is happening.

const HOST = 'com.trixarh.perch.bridge';
const SCRIPT_ID = 'perch-inject';
const BRIDGE_ID = 'perch-bridge-relay';
const SETUP_URL = 'https://github.com/Calyndrae/Perch';

let port = null;
let injecting = false;
let warned = false;
let retryDelay = 1000;

async function startInjecting() {
  if (injecting) return;
  try {
    await chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] }).catch(() => {});
    await chrome.scripting.unregisterContentScripts({ ids: [BRIDGE_ID] }).catch(() => {});
    await chrome.scripting.registerContentScripts([
      {
        id: SCRIPT_ID,
        js: ['inject.js'],
        matches: ['<all_urls>'],
        runAt: 'document_start',
        world: 'MAIN',
        allFrames: true,
        persistAcrossSessions: false,
      },
      {
        // Same timing, but the isolated world, so it can reach chrome.*.
        id: BRIDGE_ID,
        js: ['bridge.js'],
        matches: ['<all_urls>'],
        runAt: 'document_start',
        world: 'ISOLATED',
        allFrames: true,
        persistAcrossSessions: false,
      },
    ]);
    injecting = true;
    warned = false;
    await injectIntoOpenTabs();
    // Second sweep closes a startup race: Chrome may still be opening restored
    // tabs while we register, and a tab created in that window is covered by
    // neither the first sweep nor registerContentScripts.
    setTimeout(injectIntoOpenTabs, 2500);
    console.log('[Perch] app connected — protection active');
  } catch (err) {
    console.warn('[Perch] could not register content script:', err);
  }
}

// registerContentScripts only affects FUTURE navigations, so every tab that was
// already open when we registered stays unprotected until it reloads. Perch
// starts Chrome and registers a moment later, so that is the normal case, not an
// edge case — inject into what is already there.
//
// Partial by nature: a page that has already run its own scripts may have
// registered its exit-intent listener before ours exists. Those tabs are fully
// covered only after a reload. inject.js is idempotent, so double-covering a tab
// is harmless.
async function injectIntoOpenTabs() {
  let tabs = [];
  try { tabs = await chrome.tabs.query({}); } catch (_) { return; }
  for (const tab of tabs) {
    if (!tab.id) continue;
    try {
      await chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        files: ['inject.js'],
        world: 'MAIN',
        injectImmediately: true,
      });
      await chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        files: ['bridge.js'],
        world: 'ISOLATED',
        injectImmediately: true,
      });
    } catch (_) {
      // chrome:// pages, the Web Store and similar refuse injection by design.
    }
  }
}

async function stopInjecting(reason) {
  if (injecting) {
    await chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] }).catch(() => {});
    await chrome.scripting.unregisterContentScripts({ ids: [BRIDGE_ID] }).catch(() => {});
    injecting = false;
  }
  console.log('[Perch] inert —', reason);
  notifyOnce();
}

// Perch updates itself on disk at every launch and the new copy only takes over
// on a relaunch, so an update you are never told about is one you keep not
// running. Perch cannot post this itself — macOS refuses notifications to a
// locally signed, non-notarized app — but Chrome can.
//
// Announced once per version. chrome.storage rather than a variable, because the
// service worker is reclaimed constantly and would otherwise re-announce the
// same version every time it woke up.
async function announceUpdate(version) {
  try {
    const seen = await chrome.storage.local.get('announcedUpdate');
    if (seen && seen.announcedUpdate === version) return;
    await chrome.storage.local.set({ announcedUpdate: version });
    chrome.notifications.create('perch-updated', {
      type: 'basic',
      iconUrl: 'icon128.png',
      title: `Perch ${version} is ready`,
      message: 'It is installed already and takes over when you relaunch Perch. '
             + 'The copy running now keeps working until then.',
      priority: 1,
    }, () => void chrome.runtime.lastError);
  } catch (_) {
    // storage unavailable: better to stay quiet than to nag on every wake-up.
  }
}

function notifyOnce() {
  if (warned) return;
  warned = true;
  chrome.notifications.create('perch-missing', {
    type: 'basic',
    iconUrl: 'icon128.png',
    title: 'Perch isn’t running',
    message: 'The Perch app and this extension only work as a pair. '
           + 'Open Perch to turn protection back on.',
    priority: 1,
  }, () => void chrome.runtime.lastError);
}

// Domains Perch says may have a genuine screen share. Empty until the host
// answers, which is the safe direction: an unknown list means everything keeps
// getting its own tab.
let allowlist = [];

let pendingStatus = null;

/// Latest answer from Perch, asked for fresh. Falls back to "yes" if the host
/// doesn't answer, since that is the shipped default and a missed reply should
/// not silently disable a feature.
function askPerch(timeoutMs = 1200) {
  if (!port) return Promise.resolve({ autoFullscreen: true });
  return new Promise((resolve) => {
    let settled = false;
    const finish = (v) => { if (!settled) { settled = true; pendingStatus = null; resolve(v); } };
    pendingStatus = finish;
    try { port.postMessage({ type: 'status' }); }
    catch (_) { finish({ autoFullscreen: true }); return; }
    setTimeout(() => finish({ autoFullscreen: true }), timeoutMs);
  });
}

function connect() {
  // onStartup, onInstalled and the top-level call can all land in one session;
  // without this guard each spawns its own native host process.
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (err) {
    scheduleRetry();
    return;
  }

  port.onMessage.addListener((msg) => {
    retryDelay = 1000;
    if (pendingStatus) pendingStatus(msg || {});
    if (msg && msg.updateInstalled) announceUpdate(msg.updateInstalled);
    if (msg && Array.isArray(msg.allowlist)) allowlist = msg.allowlist;
    if (msg && msg.appRunning) startInjecting();
    else stopInjecting('app reported not running');
  });

  port.onDisconnect.addListener(() => {
    port = null;
    stopInjecting('native host disconnected');
    scheduleRetry();
  });

  // Prompt an immediate status reply.
  try { port.postMessage({ type: 'ping' }); } catch (_) {}
}

// Reconnecting needs BOTH of these, and neither is sufficient alone.
//
// setTimeout is fast but dies with the service worker — and the native port is
// what was keeping the worker alive, so losing the port is exactly when the
// worker gets terminated and the pending timer vanishes. Observed: after Perch
// restarted, the extension never reconnected at all, not even after a minute.
//
// chrome.alarms survives termination and wakes the worker back up, but its
// floor is 30 seconds, which is far too slow to be the only mechanism.
function scheduleRetry() {
  retryDelay = Math.min(retryDelay * 2, 5000);
  setTimeout(connect, retryDelay);
}

const RECONNECT_ALARM = 'perch-reconnect';

// Registered from three places on purpose. A single top-level create() was
// observed not to stick (chrome.alarms.getAll() came back empty), and if the
// alarm is missing there is nothing left to revive a terminated worker at all.
// create() is idempotent, so repeating it is free.
//
// The period is 1 minute rather than 0.5: Chrome clamps sub-minute periods, and
// a clamped-away alarm is worse than a slower one.
function ensureReconnectAlarm() {
  try {
    chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 1, delayInMinutes: 1 });
  } catch (err) {
    console.warn('[Perch] could not create reconnect alarm:', err);
  }
}
ensureReconnectAlarm();
chrome.runtime.onStartup.addListener(ensureReconnectAlarm);
chrome.runtime.onInstalled.addListener(ensureReconnectAlarm);

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== RECONNECT_ALARM) return;
  ensureReconnectAlarm();
  if (!port) { connect(); return; }
  // Already connected: use the tick to ask whether anything changed, which is
  // how a staged update gets noticed inside a minute.
  try { port.postMessage({ type: 'status' }); } catch (_) {}
});

// Putting the window fullscreen when the page goes fullscreen.
//
// Chrome declines to move the window while the tab is being captured, so a page
// that goes fullscreen mid-share ends up "fullscreen" with the tab strip and
// the address bar still on screen. Measured on a clean Chrome with no extension
// loaded, so this is Chrome's own behaviour rather than something Perch broke —
// and chrome.windows is the one lever that still works from here.
//
// Deliberately conservative: it never touches a window Chrome already
// fullscreened itself, and on the way out it restores the state the window
// actually had rather than assuming "normal".
const priorWindowState = new Map();
const fullscreenReasons = new Map();
let lastWindowChange = 0;

// Two separate things want the window fullscreen — a page that went fullscreen,
// and a share that just started — and either can end while the other is still
// going. Tracking them by name stops the first one to finish from dragging the
// window back out from under the other.
async function wantFullscreen(windowId, reason, on) {
  if (typeof windowId !== 'number') return;
  let reasons = fullscreenReasons.get(windowId);
  if (!reasons) { reasons = new Set(); fullscreenReasons.set(windowId, reasons); }
  if (on) reasons.add(reason); else reasons.delete(reason);
  await followFullscreen(windowId, reasons.size > 0);
}

async function followFullscreen(windowId, on) {
  if (typeof windowId !== 'number') return;
  // A page can post this message as often as it likes. Rate limiting keeps a
  // hostile or buggy one from turning it into a window-state loop.
  const now = Date.now();
  if (now - lastWindowChange < 400) return;
  lastWindowChange = now;
  try {
    const win = await chrome.windows.get(windowId);
    if (on) {
      if (win.state === 'fullscreen') return;   // Chrome managed it unaided
      priorWindowState.set(windowId, win.state);
      await chrome.windows.update(windowId, { state: 'fullscreen' });
      // macOS declines to fullscreen a window belonging to an app that isn't
      // frontmost, and the call resolves as though it worked. Confirm it, or
      // the restore at the end of the share would move a window we never moved.
      const after = await chrome.windows.get(windowId);
      if (after.state !== 'fullscreen') priorWindowState.delete(windowId);
    } else {
      const prior = priorWindowState.get(windowId);
      if (prior === undefined) return;          // we did not put it there
      priorWindowState.delete(windowId);
      await chrome.windows.update(windowId, { state: prior });
    }
  } catch (_) {
    // Window closed mid-transition, or Chrome refused. Nothing to recover.
  }
}

chrome.windows.onRemoved.addListener((id) => {
  priorWindowState.delete(id);
  fullscreenReasons.delete(id);
});

// A site asking to record the screen gets its own tab back instead.
//
// chrome.tabCapture.getMediaStreamId is the only way to produce a capture
// stream with no picker, and it is only callable from here. targetTabId and
// consumerTabId are both the asking tab, so the id captures that tab and is
// usable only by that tab — it cannot be passed elsewhere to grab something
// else. The id also expires within seconds if unused.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return;
  // The page's content script asks for this at document_start, so the answer
  // is already in hand by the time anyone clicks a share button.
  if (msg.type === 'perch:allowlist-request') {
    sendResponse({ hosts: allowlist });
    return;
  }
  if (msg.type === 'perch:fullscreen') {
    if (injecting) wantFullscreen(sender.tab && sender.tab.windowId, 'page', msg.on);
    return;
  }
  // A share just started or stopped. Going fullscreen is what collapses the tab
  // strip and the address bar; Chrome's sharing bar itself cannot be hidden, so
  // this is as close to a clean window as the browser allows.
  if (msg.type === 'perch:capture') {
    const windowId = sender.tab && sender.tab.windowId;
    if (injecting) {
      if (!msg.on) {
        wantFullscreen(windowId, 'capture', false);
      } else {
        askPerch().then((status) => {
          if (status && status.autoFullscreen === false) return;
          wantFullscreen(windowId, 'capture', true);
        });
      }
    }
    return;
  }
  if (msg.type !== 'perch:tab-stream-request') return;
  const tabId = sender.tab && sender.tab.id;
  if (!tabId) { sendResponse({ error: 'no tab' }); return; }
  if (!injecting) { sendResponse({ error: 'perch inactive' }); return; }

  try {
    chrome.tabCapture.getMediaStreamId(
      { targetTabId: tabId, consumerTabId: tabId },
      (streamId) => {
        if (chrome.runtime.lastError) {
          sendResponse({ error: chrome.runtime.lastError.message });
        } else {
          sendResponse({ streamId });
        }
      });
  } catch (err) {
    sendResponse({ error: String(err) });
  }
  return true;   // reply is async
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.notifications.onClicked.addListener((id) => {
  if (id === 'perch-missing') chrome.tabs.create({ url: SETUP_URL });
});

connect();
