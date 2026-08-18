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

  const wrapExitIntent = (listener) => {
    if (typeof listener !== 'function') return listener;
    let known = wrappers.get(listener);
    if (known) return known;
    known = function (event) {
      // The exit-intent gesture: pointer leaving through the top edge, toward
      // the tab bar. Ordinary mouseleave inside the page is left alone, so
      // menus and hover effects keep working.
      if (event && typeof event.clientY === 'number' && event.clientY <= 0) return;
      return listener.apply(this, arguments);
    };
    asNative(known, 'handleEvent');
    wrappers.set(listener, known);
    return known;
  };

  const patchedAdd = function addEventListener(type, listener, options) {
    if (typeof type === 'string') {
      const t = type.toLowerCase();
      if (SWALLOWED.has(t) && isDocumentish(this)) return undefined;
      if ((t === 'mouseleave' || t === 'mouseout') && isDocumentish(this)) {
        return nativeAdd.call(this, type, wrapExitIntent(listener), options);
      }
    }
    return nativeAdd.call(this, type, listener, options);
  };
  asNative(patchedAdd, 'addEventListener');
  EventTarget.prototype.addEventListener = patchedAdd;

  const patchedRemove = function removeEventListener(type, listener, options) {
    if (typeof type === 'string') {
      const t = type.toLowerCase();
      if ((t === 'mouseleave' || t === 'mouseout') && isDocumentish(this)) {
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

  // Nothing is defined on `document` itself: patching the instance rather than
  // the prototype leaves Object.hasOwn(document, …) true, which no real browser
  // does. Not applicable to the properties above, but the rule holds generally.
})();
