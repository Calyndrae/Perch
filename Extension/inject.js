// Runs in the MAIN world at document_start, before any page script.
//
// SCOPE: this file deliberately does NOT touch `document.hidden`,
// `visibilityState`, `hasFocus()`, `visibilitychange` or `blur`. Another
// extension owns that job, and two extensions fighting over the same accessors
// is how you get a page that behaves differently on every reload.
//
// What's left is the leaving-the-page nags: the exit-intent popup and the
// unload prompt.
//
// Everything installed here is still written to survive a site that looks for
// the lie — a naive patch is caught by reading `addEventListener.toString()`.
// Every function we install is registered in a spoof table that a patched
// Function.prototype.toString consults, and that patched toString reports
// itself as native too.
(() => {
  'use strict';

  // Idempotency guard. A string property on window would show up in
  // Object.getOwnPropertyNames(window) and is exactly the tell an anti-spoof
  // scanner greps for, so the marker is a symbol instead.
  const GUARD = Symbol.for('§');
  if (window[GUARD]) return;
  Object.defineProperty(window, GUARD, {
    value: true, enumerable: false, configurable: false, writable: false,
  });

  const nativeToString = Function.prototype.toString;
  const spoofed = new WeakMap();

  /** Make fn report itself as native code under the given name. */
  const asNative = (fn, name) => {
    spoofed.set(fn, `function ${name}() { [native code] }`);
    return fn;
  };

  const patchedToString = function toString() {
    const faked = spoofed.get(this);
    return faked !== undefined ? faked : nativeToString.call(this);
  };
  asNative(patchedToString, 'toString');
  Function.prototype.toString = patchedToString;

  // ---- Leaving-the-page nags ----------------------------------------------
  // Only unload-time events. Visibility and focus are intentionally absent.
  const SWALLOWED = new Set(['beforeunload', 'pagehide', 'freeze']);

  const isDocumentish = (t) =>
    t === document || t === window || t === document.documentElement || t === document.body;

  const nativeAdd = EventTarget.prototype.addEventListener;
  const nativeRemove = EventTarget.prototype.removeEventListener;

  // Wrapped listeners are remembered so removeEventListener still works. A site
  // that adds then removes a listener would otherwise leak one, and a leak is
  // itself detectable.
  const wrappers = new WeakMap();

  // Some libraries watch mousemove and fire when the pointer nears the top
  // edge, so blocking mouseleave alone is not enough. This band is deliberately
  // narrow and only applies to document-level listeners: hover handlers on real
  // elements never see it, so menus and toolbars behave normally.
  const MOVE_GUARD_PX = 10;

  const wrapExitIntent = (listener, type) => {
    if (typeof listener !== 'function') return listener;
    let known = wrappers.get(listener);
    if (known) return known;
    known = function (event) {
      // `this` is the element the handler is attached to, so element-level
      // handlers are never filtered even when the prototype is patched.
      if (event && typeof event.clientY === 'number' && isDocumentish(this)) {
        const leaving = type === 'mousemove' ? event.clientY <= MOVE_GUARD_PX
                                             : event.clientY <= 0;
        if (leaving) return;
      }
      return listener.apply(this, arguments);
    };
    asNative(known, 'handleEvent');
    wrappers.set(listener, known);
    return known;
  };

  const GUARDED = new Set(['mouseleave', 'mouseout', 'mousemove']);

  const patchedAdd = function addEventListener(type, listener, options) {
    if (typeof type === 'string') {
      const t = type.toLowerCase();
      if (SWALLOWED.has(t) && isDocumentish(this)) return undefined;
      if (GUARDED.has(t) && isDocumentish(this)) {
        return nativeAdd.call(this, type, wrapExitIntent(listener, t), options);
      }
    }
    return nativeAdd.call(this, type, listener, options);
  };
  asNative(patchedAdd, 'addEventListener');
  EventTarget.prototype.addEventListener = patchedAdd;

  const patchedRemove = function removeEventListener(type, listener, options) {
    if (typeof type === 'string') {
      const t = type.toLowerCase();
      if (GUARDED.has(t) && isDocumentish(this)) {
        const wrapped = wrappers.get(listener);
        if (wrapped) return nativeRemove.call(this, type, wrapped, options);
      }
    }
    return nativeRemove.call(this, type, listener, options);
  };
  asNative(patchedRemove, 'removeEventListener');
  EventTarget.prototype.removeEventListener = patchedRemove;

  // ---- on* handler properties ---------------------------------------------
  // Assigning window.onbeforeunload = fn bypasses addEventListener entirely, so
  // those properties become black holes that still read back what was set.
  const blackhole = (target, prop) => {
    let stored = null;
    Object.defineProperty(target, prop, {
      configurable: true,
      enumerable: true,
      get: asNative(function () { return stored; }, `get ${prop}`),
      set: asNative(function (fn) { stored = fn; }, `set ${prop}`),
    });
  };
  ['onbeforeunload', 'onpagehide', 'onfreeze'].forEach((p) => {
    try { blackhole(window, p); } catch (_) {}
  });

  // Assigning documentElement.onmouseleave = fn never touches addEventListener,
  // so the patch above misses it entirely — and property assignment is how a
  // good share of exit-intent code registers. Wrap on the way in instead of
  // blocking outright, so the handler still runs for ordinary movement.
  const findDescriptor = (obj, prop) => {
    let o = obj;
    while (o) {
      const d = Object.getOwnPropertyDescriptor(o, prop);
      if (d) return d;
      o = Object.getPrototypeOf(o);
    }
    return null;
  };

  const guardHandlerProperty = (proto, prop, type) => {
    const original = findDescriptor(proto, prop);
    if (!original || !original.set || !original.get) return;
    // One shared accessor serves every instance, so what the page set has to be
    // remembered per instance rather than in a single closure variable.
    const perInstance = new WeakMap();
    Object.defineProperty(proto, prop, {
      configurable: true,
      enumerable: original.enumerable !== false,
      get: asNative(function () {
        return perInstance.has(this) ? perInstance.get(this) : original.get.call(this);
      }, `get ${prop}`),
      set: asNative(function (fn) {
        perInstance.set(this, fn);
        original.set.call(this, typeof fn === 'function' ? wrapExitIntent(fn, type) : fn);
      }, `set ${prop}`),
    });
  };

  // Patched on the PROTOTYPES, not on document/body themselves. Defining
  // onmouseleave directly on an instance leaves Object.hasOwn(document,
  // 'onmouseleave') true, which no real browser does — the same instance-
  // shadowing tell the visibility patch was careful to avoid. Going through the
  // prototype also means document.body needs no special handling, since it does
  // not exist yet at document_start.
  //
  // Wrapping every element is harmless: wrapExitIntent only filters when the
  // handler's `this` is document-level, so element hover handlers are untouched.
  for (const proto of [window.Window && Window.prototype, Document.prototype, HTMLElement.prototype]) {
    if (!proto) continue;
    try { guardHandlerProperty(proto, 'onmouseleave', 'mouseleave'); } catch (_) {}
    try { guardHandlerProperty(proto, 'onmouseout', 'mouseout'); } catch (_) {}
    try { guardHandlerProperty(proto, 'onmousemove', 'mousemove'); } catch (_) {}
  }

  // ---- Screen sharing --------------------------------------------------
  // A site asking to record your screen gets ITS OWN TAB back, always.
  //
  // Chrome's picker is what lets a site end up with your whole display, and
  // once granted it keeps seeing whatever you switch to. Replacing
  // getDisplayMedia means the picker never appears and the answer is never
  // negotiable: the site receives a live stream of the page that asked, and
  // nothing else on screen is capturable by it.
  //
  // The stream itself comes from chrome.tabCapture via bridge.js, because only
  // an extension can mint a capture stream without a picker.
  if (navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia) {
    const REQUEST = 'perch:tab-stream-request';
    const RESPONSE = 'perch:tab-stream-response';
    const nativeGetUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);

    const requestTabStreamID = () => new Promise((resolve, reject) => {
      const nonce = String(Math.random()) + String(Date.now());
      const timer = setTimeout(() => {
        window.removeEventListener('message', onReply);
        reject(new Error('timeout'));
      }, 5000);

      function onReply(event) {
        const d = event.data;
        if (event.source !== window || !d || d.type !== RESPONSE || d.nonce !== nonce) return;
        clearTimeout(timer);
        window.removeEventListener('message', onReply);
        d.streamId ? resolve(d.streamId) : reject(new Error(d.error || 'no stream'));
      }
      window.addEventListener('message', onReply);
      window.postMessage({ type: REQUEST, nonce }, '*');
    });

    const patchedGetDisplayMedia = function getDisplayMedia(constraints) {
      return requestTabStreamID().then((streamId) => nativeGetUserMedia({
        // The legacy constraint form is the only one that accepts a tab
        // capture stream id.
        video: {
          mandatory: {
            chromeMediaSource: 'tab',
            chromeMediaSourceId: streamId,
            // Keep it sharp; tab capture otherwise defaults low.
            maxWidth: window.screen.width,
            maxHeight: window.screen.height,
            maxFrameRate: 60,
          },
        },
        // Audio is left to whatever the site asked for. Requesting tab audio
        // here would silence the tab for the user, which is worse than the
        // site simply not getting sound.
        audio: false,
      })).catch((err) => {
        // Fail closed. Falling back to the real picker would hand the site the
        // screen-grab we exist to prevent.
        throw new DOMException(
          'Permission denied by system', 'NotAllowedError');
      });
    };
    asNative(patchedGetDisplayMedia, 'getDisplayMedia');
    try {
      Object.defineProperty(navigator.mediaDevices, 'getDisplayMedia', {
        configurable: true,
        writable: true,
        value: patchedGetDisplayMedia,
      });
    } catch (_) {
      try { navigator.mediaDevices.getDisplayMedia = patchedGetDisplayMedia; } catch (_) {}
    }
  }

  // Nothing is defined on `document` itself: patching the instance rather than
  // the prototype leaves Object.hasOwn(document, …) true, which no real browser
  // does. Not applicable to the properties above, but the rule holds generally.
})();
