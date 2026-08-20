// ISOLATED-world content script.
//
// inject.js runs in the MAIN world so it can replace page APIs, but that world
// has no access to chrome.* — and only chrome.tabCapture can mint a capture
// stream without showing a picker. This file is the only thing that can see
// both sides, so it relays between them.
//
// Messages are matched by nonce and checked for origin, so a page cannot forge
// a reply or read one meant for someone else.
(() => {
  'use strict';

  const REQUEST = 'perch:tab-stream-request';
  const RESPONSE = 'perch:tab-stream-response';
  const FULLSCREEN = 'perch:fullscreen';
  const CAPTURE = 'perch:capture';
  const ALLOWLIST = 'perch:allowlist';

  // Fetched immediately rather than on demand: getDisplayMedia must be reached
  // inside the click that triggered it, so there is no room to go asking then.
  const sendAllowlist = () => {
    try {
      chrome.runtime.sendMessage({ type: 'perch:allowlist-request' }, (reply) => {
        if (chrome.runtime.lastError) return;
        window.postMessage({ type: ALLOWLIST, hosts: (reply && reply.hosts) || [] },
                           window.location.origin === 'null' ? '*' : window.location.origin);
      });
    } catch (_) {}
  };
  sendAllowlist();
  // The service worker may have been asleep and answered with a stale empty
  // list; one retry covers the wake-up.
  setTimeout(sendAllowlist, 1500);

  window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data) return;

    // The capture note is posted to the top window, so in a framed page its
    // source is the frame rather than this window. It carries no payload worth
    // forging — the worst a page can do with it is ask for the fullscreen it
    // could request itself — so origin is not checked for this one.
    if (data.type !== CAPTURE && event.source !== window) return;

    // The page went fullscreen. Worth passing on because Chrome refuses to
    // move the window while the tab is captured, leaving the tab strip and
    // address bar on screen for the whole share; only the service worker can
    // reach chrome.windows and put that right.
    if (data.type === CAPTURE && typeof data.on === 'boolean') {
      try {
        chrome.runtime.sendMessage({ type: CAPTURE, on: data.on },
                                   () => void chrome.runtime.lastError);
      } catch (_) {}
      return;
    }

    if (data.type === FULLSCREEN && typeof data.on === 'boolean') {
      try {
        chrome.runtime.sendMessage({ type: FULLSCREEN, on: data.on },
                                   () => void chrome.runtime.lastError);
      } catch (_) {}
      return;
    }

    if (data.type !== REQUEST || typeof data.nonce !== 'string') return;

    chrome.runtime.sendMessage({ type: REQUEST }, (reply) => {
      const failed = chrome.runtime.lastError
        ? chrome.runtime.lastError.message
        : (reply && reply.error);
      window.postMessage({
        type: RESPONSE,
        nonce: data.nonce,
        streamId: reply && reply.streamId,
        error: failed || null,
      }, window.location.origin === 'null' ? '*' : window.location.origin);
    });
  });
})();
