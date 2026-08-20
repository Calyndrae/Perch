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

  // Exit-intent detectors that watch mousemove typically fire well below the
  // very top edge — around 60px — and key on the pointer heading UPWARD. A flat
  // 10px band sat underneath that entirely.
  //
  // So the band is wide, but only upward movement inside it is dropped.
  // Downward and lateral movement passes untouched at every coordinate, which
  // is what top navigation bars and hover menus actually rely on.
  const MOVE_GUARD_PX = 70;
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

    // Fullscreen removes the very thing exit-intent aims at. There is no tab
    // strip, no address bar and no window chrome to head toward, so an upward
    // flick can no longer mean "leaving" — but it is exactly how every video
    // player is told to reveal its controls. Measured: 3 of 8 upward moves
    // reached the page in fullscreen, same as windowed, so a player's control
    // bar simply would not appear. The guard stands down while fullscreen.
    const isFullscreen = () => {
      try { return !!(doc.fullscreenElement || doc.webkitFullscreenElement); }
      catch (_) { return false; }
    };

    const wrapExitIntent = (listener, type) => {
      if (typeof listener !== 'function') return listener;
      let known = wrappers.get(listener);
      if (known) return known;
      let lastY = Infinity;
      known = function (event) {
        // `this` is whatever the handler was attached to, so element-level
        // handlers are never filtered even though the prototype is patched.
        if (event && typeof event.clientY === 'number'
            && isDocumentish(this) && !isFullscreen()) {
          if (MOVE_LIKE.has(type)) {
            const headingUp = event.clientY < lastY;
            lastY = event.clientY;
            if (headingUp && event.clientY <= MOVE_GUARD_PX) return;
          } else if (event.clientY <= 0) {
            return;
          }
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

    // ---- fullscreen --------------------------------------------------------
    // Chrome will not take the WINDOW fullscreen while the tab is being
    // captured. Measured, and identical in a clean Chrome with no extension at
    // all: document.fullscreenElement is set, the window stays put, and the tab
    // strip and address bar sit there through the whole share. Nothing the page
    // can do fixes that — but the extension can promote the window itself, so
    // the announcement goes out to the isolated world.
    //
    // Only from the top document. A fullscreened iframe raises the event here
    // too, with fullscreenElement pointing at the frame, so frames would only
    // duplicate it.
    if (win === win.top) {
      const announce = () => {
        try {
          win.postMessage({
            type: 'perch:fullscreen',
            on: !!(doc.fullscreenElement || doc.webkitFullscreenElement),
          }, win.location.origin === 'null' ? '*' : win.location.origin);
        } catch (_) {}
      };
      try {
        doc.addEventListener('fullscreenchange', announce);
        doc.addEventListener('webkitfullscreenchange', announce);
      } catch (_) {}
    }

    // ---- screen capture ----------------------------------------------------
    // A genuine displaySurface:"monitor" stream is screen-sized. Ours is the
    // tab, so a site comparing getSettings().width against screen.width would
    // catch the disguise — not a leak, but enough to refuse service.
    //
    // So screen.* is made to agree, and ONLY while a capture is live. Reporting
    // a fake display size permanently would follow the user into every page,
    // breaking responsive layouts and window placement for no benefit. Outside
    // an active capture these getters return the truth.
    let activeCaptures = 0;
    let fakeScreen = null;

    // The spoof is sized from the capture, which is the tab — so on a small
    // window it can come out SMALLER than the window reporting it. Measured:
    // screen 800x592 inside a 1200-wide window. No real display is smaller
    // than the window drawn on it, so that is both a tell and a trap for any
    // player that decides "am I fullscreen?" by comparing the viewport with
    // screen.*.
    //
    // Fullscreen drops the spoof altogether: there the tab genuinely is the
    // whole display, so the truth is already the consistent answer.
    const effectiveFake = () => {
      if (!fakeScreen || isFullscreen()) return null;
      return {
        w: Math.max(fakeScreen.w, win.outerWidth || 0, win.innerWidth || 0),
        h: Math.max(fakeScreen.h, win.outerHeight || 0, win.innerHeight || 0),
      };
    };

    const screenProto = win.Screen && win.Screen.prototype;
    if (screenProto) {
      // Grab every original getter BEFORE replacing any of them — otherwise the
      // avail* getters would read back our own replacement for width/height.
      const originals = {};
      for (const prop of ['width', 'height', 'availWidth', 'availHeight']) {
        const d = Object.getOwnPropertyDescriptor(screenProto, prop);
        if (d && d.get) originals[prop] = d;
      }
      for (const prop of Object.keys(originals)) {
        const original = originals[prop];
        const getter = asNative(function () {
          const real = original.get.call(this);
          const fake = effectiveFake();
          if (!fake) return real;
          if (prop === 'width') return fake.w;
          if (prop === 'height') return fake.h;
          // avail* keeps its real proportion of the display, so the pair stays
          // plausible rather than suspiciously identical to width/height.
          const isW = prop === 'availWidth';
          const full = originals[isW ? 'width' : 'height'];
          const realFull = full ? full.get.call(this) : 0;
          const base = isW ? fake.w : fake.h;
          return realFull ? Math.round(base * (real / realFull)) : base;
        }, `get ${prop}`);
        try {
          Object.defineProperty(screenProto, prop, {
            configurable: true, enumerable: original.enumerable !== false, get: getter,
          });
        } catch (_) {}
      }
    }

    const beginScreenSpoof = (settings) => {
      const dpr = win.devicePixelRatio || 1;
      if (!settings || !settings.width || !settings.height) return;
      fakeScreen = {
        w: Math.round(settings.width / dpr),
        h: Math.round(settings.height / dpr),
      };
      activeCaptures++;
    };
    const endScreenSpoof = () => {
      activeCaptures = Math.max(0, activeCaptures - 1);
      if (activeCaptures === 0) fakeScreen = null;
    };

    const md = win.navigator && win.navigator.mediaDevices;
    if (md && md.getDisplayMedia) {
      const nativeGDM = md.getDisplayMedia.bind(md);

      // A tab capture reports displaySurface "browser" and a tab-ish label.
      // A site that checks either would know it was fenced in.
      const disguise = (stream) => {
        const first = stream.getVideoTracks()[0];
        if (first) {
          beginScreenSpoof(first.getSettings());
          // The spoof must last exactly as long as the capture does.
          let finished = false;
          const finish = () => { if (!finished) { finished = true; endScreenSpoof(); } };
          try { first.addEventListener('ended', finish); } catch (_) {}
          for (const t of stream.getTracks()) {
            const nativeStop = t.stop.bind(t);
            const patchedStop = function stop() { finish(); return nativeStop(); };
            asNative(patchedStop, 'stop');
            try {
              Object.defineProperty(t, 'stop',
                { configurable: true, writable: true, value: patchedStop });
            } catch (_) {}
          }
        }
        for (const track of stream.getVideoTracks()) {
          // getCapabilities and getConstraints carry the surface as well;
          // patching only getSettings and label leaves an easy way to check.
          for (const [fn, fix] of [
            ['getCapabilities', (c) => { if (c && 'displaySurface' in c) c.displaySurface = ['monitor']; }],
            ['getConstraints',  (c) => { if (c && c.displaySurface) c.displaySurface = 'monitor'; }],
          ]) {
            const orig = track[fn] && track[fn].bind(track);
            if (!orig) continue;
            const patched = function () { const v = orig(); try { fix(v); } catch (_) {} return v; };
            asNative(patched, fn);
            try {
              Object.defineProperty(track, fn, { configurable: true, writable: true, value: patched });
            } catch (_) {}
          }
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

      // The picker is shown for real, and this tab is substituted underneath.
      //
      // Suppressing the picker outright broke sites: one refused entry because
      // it never saw the share flow happen the way it expects. So the site's own
      // constraints go to the native call unchanged, the genuine chooser
      // appears, and whatever gets picked is dropped and replaced with this tab.
      //
      // Fails CLOSED: if the tab capture cannot be obtained, the site is told
      // permission was denied rather than being handed the screen it picked.
      const patchedGetDisplayMedia = function getDisplayMedia(constraints) {
        const wanted = constraints || { video: true };

        return nativeGDM(wanted).then((chosen) => {
          // Whatever it really captured is stopped at once, before a single
          // frame can be read out of it.
          try { chosen.getTracks().forEach((t) => t.stop()); } catch (_) {}

          return nativeGDM({
            video: (wanted && typeof wanted.video === 'object') ? wanted.video : true,
            audio: wanted && wanted.audio ? wanted.audio : false,
            preferCurrentTab: true,
            selfBrowserSurface: 'include',
            systemAudio: 'exclude',
          }).then(disguise).catch(() => {
            throw new DOMException('Permission denied by system', 'NotAllowedError');
          });
        });
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
