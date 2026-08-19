// Runs in the MAIN world at document_start, before any page script.
//
// Two jobs:
//   1. A site that asks to record the screen silently gets only its own tab,
//      and is made to believe it got the whole display.
//   2. Exit-intent popups and leave-the-page nags are suppressed.
//
// Deliberately NOT touched: document.hidden, visibilityState, hasFocus(),
// visibilitychange, blur. Another extension owns page visibility, and two
// extensions fighting over the same accessors gives you a page that behaves
// differently on every reload.
//
// Everything installed is written to survive a site that goes looking. A naive
// patch is caught by reading addEventListener.toString(), by finding an own
// property where the prototype should carry it, or by diffing against a
// pristine realm from an iframe.
(() => {
  'use strict';

  const MOVE_GUARD_PX = 10;
  const SWALLOWED = new Set(['beforeunload', 'pagehide', 'freeze']);
  const GUARDED = new Set([
    'mouseleave', 'mouseout', 'mousemove',
    // Pointer events are a full parallel API. Guarding only the mouse* names
    // left pointerout and pointerleave completely open.
    'pointerout', 'pointerleave', 'pointermove',
  ]);
  const MOVE_LIKE = new Set(['mousemove', 'pointermove']);
  const HANDLER_PROPS = [
    ['onmouseleave', 'mouseleave'], ['onmouseout', 'mouseout'],
    ['onmousemove', 'mousemove'], ['onpointerleave', 'pointerleave'],
    ['onpointerout', 'pointerout'], ['onpointermove', 'pointermove'],
  ];

  /**
   * Applies every protection inside one realm.
   *
   * Parameterised by window on purpose. A same-origin about:blank iframe gets
   * no content script from Chrome, so its realm keeps pristine natives — which
   * hands a site both a way to SEE the patch (its Function.prototype.toString
   * is not ours, so it prints our real source) and a way AROUND it (its
   * getDisplayMedia is untouched). Hardening child realms closes both.
   */
  // ONE table shared by every realm. If each realm kept its own, a child's
  // toString would not recognise the parent's patched functions and would
  // happily print their real source — which is exactly the iframe attack.
  const spoofed = new WeakMap();
  const asNative = (fn, name) => {
    spoofed.set(fn, `function ${name}() { [native code] }`);
    return fn;
  };

  function harden(win) {
    let doc;
    try { doc = win.document; } catch (_) { return; }   // cross-origin
    if (!doc) return;

    const GUARD = Symbol.for('§');
    try {
      if (win[GUARD]) return;
      Object.defineProperty(win, GUARD, {
        value: true, enumerable: false, configurable: false, writable: false,
      });
    } catch (_) { return; }

    const F = win.Function;
    const nativeToString = F.prototype.toString;

    const patchedToString = function toString() {
      const faked = spoofed.get(this);
      return faked !== undefined ? faked : nativeToString.call(this);
    };
    asNative(patchedToString, 'toString');
    F.prototype.toString = patchedToString;

    // ---- exit intent + unload nags -----------------------------------------
    const isDocumentish = (t) =>
      t === doc || t === win || t === doc.documentElement || t === doc.body;

    const ET = win.EventTarget;
    if (!ET) return;
    const nativeAdd = ET.prototype.addEventListener;
    const nativeRemove = ET.prototype.removeEventListener;
    const wrappers = new WeakMap();

    const wrapExitIntent = (listener, type) => {
      if (typeof listener !== 'function') return listener;
      let known = wrappers.get(listener);
      if (known) return known;
      known = function (event) {
        // `this` is whatever the handler was attached to, so element-level
        // handlers are never filtered even though the prototype is patched.
        if (event && typeof event.clientY === 'number' && isDocumentish(this)) {
          const leaving = MOVE_LIKE.has(type) ? event.clientY <= MOVE_GUARD_PX
                                              : event.clientY <= 0;
          if (leaving) return;
        }
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
        if (GUARDED.has(t) && isDocumentish(this)) {
          return nativeAdd.call(this, type, wrapExitIntent(listener, t), options);
        }
      }
      return nativeAdd.call(this, type, listener, options);
    };
    asNative(patchedAdd, 'addEventListener');
    ET.prototype.addEventListener = patchedAdd;

    const patchedRemove = function removeEventListener(type, listener, options) {
      if (typeof type === 'string' && GUARDED.has(type.toLowerCase()) && isDocumentish(this)) {
        const wrapped = wrappers.get(listener);
        if (wrapped) return nativeRemove.call(this, type, wrapped, options);
      }
      return nativeRemove.call(this, type, listener, options);
    };
    asNative(patchedRemove, 'removeEventListener');
    ET.prototype.removeEventListener = patchedRemove;

    // Assigning window.onbeforeunload never touches addEventListener, so those
    // become black holes that still read back whatever was set.
    const blackhole = (target, prop) => {
      let stored = null;
      Object.defineProperty(target, prop, {
        configurable: true, enumerable: true,
        get: asNative(function () { return stored; }, `get ${prop}`),
        set: asNative(function (fn) { stored = fn; }, `set ${prop}`),
      });
    };
    ['onbeforeunload', 'onpagehide', 'onfreeze'].forEach((p) => {
      try { blackhole(win, p); } catch (_) {}
    });

    const findDescriptor = (obj, prop) => {
      let o = obj;
      while (o) {
        const d = Object.getOwnPropertyDescriptor(o, prop);
        if (d) return d;
        o = Object.getPrototypeOf(o);
      }
      return null;
    };

    // Wrapped rather than blocked, so the site's handler still runs for
    // ordinary movement and still reads back as the function it assigned.
    const guardHandlerProperty = (proto, prop, type) => {
      const original = findDescriptor(proto, prop);
      if (!original || !original.set || !original.get) return;
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

    // On PROTOTYPES, never on document/body themselves: an own property there
    // is a tell no real browser produces.
    for (const proto of [win.Window && win.Window.prototype,
                         win.Document && win.Document.prototype,
                         win.HTMLElement && win.HTMLElement.prototype]) {
      if (!proto) continue;
      for (const [prop, type] of HANDLER_PROPS) {
        try { guardHandlerProperty(proto, prop, type); } catch (_) {}
      }
    }

    // ---- screen capture ----------------------------------------------------
    const md = win.navigator && win.navigator.mediaDevices;
    if (md && md.getDisplayMedia) {
      const nativeGDM = md.getDisplayMedia.bind(md);

      // A tab capture reports displaySurface "browser" and a tab-ish label.
      // A site that checks either would know it was fenced in.
      const disguise = (stream) => {
        for (const track of stream.getVideoTracks()) {
          const nativeSettings = track.getSettings.bind(track);
          const patchedSettings = function getSettings() {
            const s = nativeSettings();
            s.displaySurface = 'monitor';
            s.logicalSurface = true;
            s.cursor = s.cursor || 'always';
            return s;
          };
          asNative(patchedSettings, 'getSettings');
          try {
            Object.defineProperty(track, 'getSettings',
              { configurable: true, writable: true, value: patchedSettings });
            Object.defineProperty(track, 'label',
              { configurable: true, get: asNative(function () {
                  return 'Entire screen'; }, 'get label') });
          } catch (_) {}
        }
        return stream;
      };

      const patchedGetDisplayMedia = function getDisplayMedia(constraints) {
        const forced = Object.assign({}, constraints || {}, {
          video: (constraints && typeof constraints.video === 'object')
            ? constraints.video : true,
          preferCurrentTab: true,
          selfBrowserSurface: 'include',
          // Never leave the site a way to ask for a different surface.
          systemAudio: 'exclude',
          surfaceSwitching: 'exclude',
          monitorTypeSurfaces: 'exclude',
        });
        return nativeGDM(forced).then(disguise);
      };
      asNative(patchedGetDisplayMedia, 'getDisplayMedia');

      // On MediaDevices.prototype, where it natively lives. Defining it on the
      // instance leaves Object.hasOwn(navigator.mediaDevices, …) true.
      const mdProto = (win.MediaDevices && win.MediaDevices.prototype)
                    || Object.getPrototypeOf(md);
      try {
        Object.defineProperty(mdProto, 'getDisplayMedia', {
          configurable: true, writable: true, value: patchedGetDisplayMedia,
        });
      } catch (_) {
        try { md.getDisplayMedia = patchedGetDisplayMedia; } catch (_) {}
      }
    }
  }

  harden(window);

  // ---- child realms --------------------------------------------------------
  // Chrome runs no content script in a same-origin about:blank iframe, so its
  // realm stays pristine. Left alone that is both a detection route and a
  // working bypass, so every reachable frame gets the same treatment — as it
  // appears, and again on load, since the realm is replaced on navigation.
  const hardenFrame = (frame) => {
    try {
      if (frame && frame.contentWindow) harden(frame.contentWindow);
    } catch (_) { /* cross-origin: not ours to touch, and already isolated */ }
  };

  const sweep = () => {
    try {
      const frames = document.getElementsByTagName('iframe');
      for (let i = 0; i < frames.length; i++) hardenFrame(frames[i]);
    } catch (_) {}
  };

  try {
    new MutationObserver((records) => {
      for (const r of records) {
        for (const n of r.addedNodes) {
          if (n && n.tagName === 'IFRAME') {
            hardenFrame(n);
            try { n.addEventListener('load', () => hardenFrame(n)); } catch (_) {}
          } else if (n && n.getElementsByTagName) {
            const inner = n.getElementsByTagName('iframe');
            for (let i = 0; i < inner.length; i++) hardenFrame(inner[i]);
          }
        }
      }
    }).observe(document.documentElement || document, { childList: true, subtree: true });
  } catch (_) {}

  // A frame attached and used within the same synchronous block would outrun
  // the observer, which delivers asynchronously.
  const proto = Element.prototype;
  for (const name of ['appendChild', 'insertBefore', 'replaceChild', 'append', 'prepend']) {
    const original = Node.prototype[name] || proto[name];
    if (typeof original !== 'function') continue;
    const target = Node.prototype[name] ? Node.prototype : proto;
    const patched = function (...args) {
      const result = original.apply(this, args);
      for (const a of args) {
        if (a && a.tagName === 'IFRAME') hardenFrame(a);
      }
      return result;
    };
    try {
      Object.defineProperty(patched, 'name', { value: name });
      target[name] = patched;
    } catch (_) {}
  }

  sweep();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', sweep);
  }
})();
