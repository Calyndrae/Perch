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
const SETUP_URL = 'https://github.com/Calyndrae/Perch';

let port = null;
let injecting = false;
let warned = false;
let retryDelay = 1000;

async function startInjecting() {
  if (injecting) return;
  try {
    await chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] }).catch(() => {});
    await chrome.scripting.registerContentScripts([{
      id: SCRIPT_ID,
      js: ['inject.js'],
      matches: ['<all_urls>'],
      runAt: 'document_start',
      world: 'MAIN',
      allFrames: true,
      persistAcrossSessions: false,
    }]);
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
    } catch (_) {
      // chrome:// pages, the Web Store and similar refuse injection by design.
    }
  }
}

async function stopInjecting(reason) {
  if (injecting) {
    await chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] }).catch(() => {});
    injecting = false;
  }
  console.log('[Perch] inert —', reason);
  notifyOnce();
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
  if (!port) connect();
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.notifications.onClicked.addListener((id) => {
  if (id === 'perch-missing') chrome.tabs.create({ url: SETUP_URL });
});

connect();
