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
const SETUP_URL = 'https://example.invalid/perch/setup';

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
    console.log('[Perch] app connected — protection active');
  } catch (err) {
    console.warn('[Perch] could not register content script:', err);
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

function scheduleRetry() {
  // Back off to a minute so a permanently-absent app costs nothing.
  retryDelay = Math.min(retryDelay * 2, 60000);
  setTimeout(connect, retryDelay);
}

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.notifications.onClicked.addListener((id) => {
  if (id === 'perch-missing') chrome.tabs.create({ url: SETUP_URL });
});

connect();
