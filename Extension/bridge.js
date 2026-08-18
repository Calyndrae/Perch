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

  window.addEventListener('message', (event) => {
    // Only this page may ask; ignore anything relayed in from a frame.
    if (event.source !== window) return;
    const data = event.data;
    if (!data || data.type !== REQUEST || typeof data.nonce !== 'string') return;

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
