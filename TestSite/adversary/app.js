/* Nimbus — a test fixture that behaves like a hostile streaming site.
 *
 * Local only. Its job is to try, using the techniques production sites actually
 * use, to (a) capture more than its own tab, (b) detect the user leaving, and
 * (c) notice that any of those APIs have been tampered with.
 *
 * Deliberately no visible harness: results live in window.__adversary and the
 * title. Press "d" for a readout.
 *
 * Out of scope by design: visibilityState / hidden / hasFocus / blur.
 */
(() => {
  'use strict';

  const R = { capture: {}, exitIntent: {}, unload: {}, tamper: {} };
  window.__adversary = R;

  const note = (group, name, won, why) => {
    R[group][name] = { won: !!won, verdict: won ? 'SITE WON' : 'BLOCKED', why: String(why) };
    summarise();
  };

  function summarise() {
    const all = Object.values(R).flatMap(g => Object.values(g));
    const won = all.filter(x => x.won).length;
    R.summary = { techniques: all.length, siteWon: won, blocked: all.length - won };
    document.title = won
      ? `Nimbus — ${won}/${all.length} got through`
      : `Nimbus — 0/${all.length} got through`;
    const d = document.getElementById('diag');
    if (d && d.classList.contains('on')) d.textContent = JSON.stringify(R, null, 1);
  }

  addEventListener('keydown', e => {
    if (e.key === 'd') {
      const d = document.getElementById('diag');
      d.classList.toggle('on');
      d.textContent = JSON.stringify(R, null, 1);
    }
  });

  // ---------------------------------------------------------------- player ---
  // A real playing <video> with no asset file, so the page works offline.
  const canvas = document.createElement('canvas');
  canvas.width = 1280; canvas.height = 720;
  const ctx = canvas.getContext('2d');
  let hue = 210;
  (function draw() {
    hue = (hue + 0.25) % 360;
    const g = ctx.createLinearGradient(0, 0, 1280, 720);
    g.addColorStop(0, `hsl(${hue} 45% 14%)`);
    g.addColorStop(1, `hsl(${(hue + 60) % 360} 50% 22%)`);
    ctx.fillStyle = g; ctx.fillRect(0, 0, 1280, 720);
    const t = performance.now() / 1000;
    ctx.fillStyle = `hsl(${(hue + 150) % 360} 70% 62%)`;
    for (let i = 0; i < 5; i++) {
      ctx.beginPath();
      ctx.arc(640 + Math.cos(t * .6 + i) * 380, 360 + Math.sin(t * .8 + i * 1.3) * 180, 46, 0, 7);
      ctx.fill();
    }
    ctx.fillStyle = 'rgba(255,255,255,.92)';
    ctx.font = '600 34px system-ui';
    ctx.fillText("The Cartographer's Dilemma", 60, 90);
    requestAnimationFrame(draw);
  })();

  const vid = document.getElementById('vid');
  vid.srcObject = canvas.captureStream(30);
  vid.play().catch(() => {});
  document.getElementById('play').onclick = () => {
    vid.paused ? vid.play() : vid.pause();
    document.getElementById('play').textContent = vid.paused ? '▶' : '❚❚';
  };

  // Real Fullscreen API on the player, as a streaming site would have.
  document.getElementById('fs').onclick = () => {
    const p = document.getElementById('player');
    if (document.fullscreenElement) document.exitFullscreen();
    else p.requestFullscreen && p.requestFullscreen();
  };

  // ------------------------------------------------------------ A: capture ---
  // Pattern: "anti-piracy / environment check" gates seen on streaming sites.
  async function attemptCapture(context) {
    const key = 'getDisplayMedia' + (context ? ':' + context : '');
    let stream;
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({
        video: { frameRate: 30 },
        audio: true,
        // A hostile site asks for the widest surface it can and hopes.
        monitorTypeSurfaces: 'include',
        surfaceSwitching: 'include',
        systemAudio: 'include',
      });
    } catch (err) {
      note('capture', key, false, 'refused: ' + err.name);
      return;
    }

    const track = stream.getVideoTracks()[0];
    const s = track.getSettings();
    const claimedScreen = s.displaySurface === 'monitor';

    // Does the frame size match the real display, or just this tab?
    const dpr = window.devicePixelRatio || 1;
    const screenPx = { w: Math.round(screen.width * dpr), h: Math.round(screen.height * dpr) };
    const innerPx = { w: Math.round(innerWidth * dpr), h: Math.round(innerHeight * dpr) };
    const matchesScreen = Math.abs(s.width - screenPx.w) <= 8 && Math.abs(s.height - screenPx.h) <= 8;
    const matchesViewport = Math.abs(s.width - innerPx.w) <= 40 && Math.abs(s.height - innerPx.h) <= 120;

    // Sample a real frame: a genuine screen grab contains the desktop, so the
    // page's own colours filling the frame is a strong tell it is only the tab.
    let sample = 'n/a';
    try {
      const v = document.createElement('video');
      v.srcObject = stream; v.muted = true;
      await v.play();
      await new Promise(r => setTimeout(r, 500));
      const c = document.createElement('canvas');
      c.width = 200; c.height = 120;
      c.getContext('2d').drawImage(v, 0, 0, 200, 120);
      const px = c.getContext('2d').getImageData(0, 0, 200, 120).data;
      let dark = 0;
      for (let i = 0; i < px.length; i += 4) {
        if (px[i] < 40 && px[i + 1] < 45 && px[i + 2] < 55) dark++;
      }
      sample = Math.round(100 * dark / (px.length / 4)) + '% page-dark pixels';
      v.pause();
    } catch (e) { sample = 'sample failed: ' + e.name; }

    const audio = stream.getAudioTracks().map(a => a.label);
    stream.getTracks().forEach(t => t.stop());

    // The site "wins" only if it genuinely obtained more than its own tab.
    const gotMoreThanTab = claimedScreen && matchesScreen && !matchesViewport;
    note('capture', key, gotMoreThanTab,
      `label="${track.label}" surface=${s.displaySurface} ${s.width}x${s.height} ` +
      `screen=${screenPx.w}x${screenPx.h} viewport=${innerPx.w}x${innerPx.h} ` +
      `matchesScreen=${matchesScreen} matchesViewport=${matchesViewport} ` +
      `audio=[${audio}] frame=${sample}`);

    return { s, matchesScreen, matchesViewport };
  }

  document.getElementById('verify').onclick = async () => {
    document.getElementById('gate').classList.remove('on');
    await attemptCapture('');
  };
  document.getElementById('skip').onclick = () =>
    document.getElementById('gate').classList.remove('on');

  // Fullscreen is the interesting case: the tab then fills the display, so a
  // tab capture and a screen capture report the SAME dimensions. If the size
  // check is all that distinguishes them, fullscreen defeats it.
  window.__adversaryFullscreenProbe = async () => {
    const p = document.getElementById('player');
    try { await p.requestFullscreen(); } catch (e) {}
    await new Promise(r => setTimeout(r, 700));
    const res = await attemptCapture('fullscreen');
    try { await document.exitFullscreen(); } catch (e) {}
    return res;
  };

  // -------------------------------------------------------- B: exit intent ---
  const armExit = (name, arm) => {
    let fired = false;
    arm(() => { if (!fired) { fired = true; note('exitIntent', name, true, 'handler ran'); } });
    setTimeout(() => { if (!fired) note('exitIntent', name, false, 'never ran'); }, 2500);
  };

  // ouibounce and its many clones
  armExit('document mouseleave', hit =>
    document.addEventListener('mouseleave', e => { if (e.clientY <= 0) hit(); }));
  // Older libraries watch mouseout and check relatedTarget
  armExit('body mouseout relatedTarget', hit =>
    document.body.addEventListener('mouseout', e => { if (!e.relatedTarget && e.clientY <= 0) hit(); }));
  // Capture phase, to beat page-level handlers
  armExit('capture-phase mouseleave', hit =>
    document.addEventListener('mouseleave', e => { if (e.clientY <= 0) hit(); }, { capture: true }));
  // Property assignment — never touches addEventListener
  armExit('documentElement.onmouseleave', hit =>
    document.documentElement.onmouseleave = e => { if (e.clientY <= 0) hit(); });
  armExit('body.onmouseout', hit =>
    document.body.onmouseout = e => { if (e.clientY <= 0) hit(); });
  // Velocity-based: upward movement near the top edge
  armExit('mousemove velocity', hit => {
    let last = 999, lastT = 0;
    document.addEventListener('mousemove', e => {
      const dt = e.timeStamp - lastT;
      if (e.clientY < 60 && e.clientY < last && dt > 0 && (last - e.clientY) / dt > .2) hit();
      last = e.clientY; lastT = e.timeStamp;
    });
  });
  // Pointer events rather than mouse events
  armExit('pointerout', hit =>
    document.addEventListener('pointerout', e => { if (e.clientY <= 0) hit(); }));
  armExit('window pointerleave', hit =>
    window.addEventListener('pointerleave', e => { if (e.clientY <= 0) hit(); }));

  // Fire the gestures a real departure produces.
  setTimeout(() => {
    const o = { bubbles: true, cancelable: true, clientX: 500, clientY: 0, relatedTarget: null };
    for (const t of [document, document.documentElement, document.body, window]) {
      for (const type of ['mouseleave', 'mouseout', 'pointerout', 'pointerleave']) {
        try { t.dispatchEvent(new MouseEvent(type, o)); } catch (_) {}
      }
    }
    let y = 300;
    const step = () => {
      y -= 60;
      document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 500, clientY: Math.max(0, y) }));
      if (y > 0) setTimeout(step, 8);
    };
    step();
  }, 500);

  // ------------------------------------------------------------- C: unload ---
  (() => {
    let viaListener = false, viaProp = false, viaPagehide = false;
    const l = e => { viaListener = true; e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', l);
    window.onbeforeunload = () => { viaProp = true; return 'stay?'; };
    window.addEventListener('pagehide', () => { viaPagehide = true; });

    setTimeout(() => {
      window.dispatchEvent(new Event('beforeunload'));
      window.dispatchEvent(new Event('pagehide'));
      setTimeout(() => {
        note('unload', 'beforeunload addEventListener', viaListener, viaListener ? 'ran' : 'swallowed');
        note('unload', 'window.onbeforeunload', viaProp, viaProp ? 'ran' : 'swallowed');
        note('unload', 'pagehide', viaPagehide, viaPagehide ? 'ran' : 'swallowed');
      }, 120);
    }, 700);
  })();

  // ------------------------------------------------------------- D: tamper ---
  const NATIVE = '[native code]';
  const looksNative = fn => { try { return Function.prototype.toString.call(fn).includes(NATIVE); }
                             catch (e) { return false; } };

  note('tamper', 'addEventListener toString', !looksNative(EventTarget.prototype.addEventListener),
       looksNative(EventTarget.prototype.addEventListener) ? 'reports native' : 'reports JS source');
  note('tamper', 'getDisplayMedia toString',
       !looksNative(navigator.mediaDevices.getDisplayMedia),
       looksNative(navigator.mediaDevices.getDisplayMedia) ? 'reports native' : 'reports JS source');
  note('tamper', 'own-property shadowing',
       ['onmouseleave', 'onmouseout', 'onbeforeunload'].some(p => Object.hasOwn(document, p)),
       'checked document for own handler props');
  note('tamper', 'mediaDevices own getDisplayMedia',
       Object.hasOwn(navigator.mediaDevices, 'getDisplayMedia'),
       'MediaDevices.prototype is where it normally lives');

  // The strong one: a same-origin about:blank iframe. Chrome does not run
  // content scripts in those, so its realm may hold pristine natives — which
  // both exposes a patch and offers a way around it.
  (() => {
    let f;
    try {
      f = document.createElement('iframe');
      f.style.display = 'none';
      document.body.appendChild(f);
      const w = f.contentWindow;
      if (!w) throw new Error('no contentWindow');

      // Its Function.prototype.toString is not ours, so it reports the truth.
      const pristineToString = w.Function.prototype.toString;
      const realSource = pristineToString.call(EventTarget.prototype.addEventListener);
      const exposed = !realSource.includes(NATIVE);
      note('tamper', 'iframe pristine toString', exposed,
           exposed ? 'pristine realm reveals patched source: ' + realSource.slice(0, 70)
                   : 'still reports native through a clean realm');

      // Whether it is REACHABLE proves nothing — a clean browser exposes it in
      // a child frame too, and string-matching the source is useless once
      // toString is patched. The only honest test is to call it and look at
      // what comes back.
      window.__adversaryIframe = w;
      window.__adversaryIframeCapture = async () => {
        const gdm = w.navigator && w.navigator.mediaDevices &&
                    w.navigator.mediaDevices.getDisplayMedia;
        if (!gdm) { note('tamper', 'iframe capture bypass', false, 'not reachable'); return; }
        let stream;
        try {
          stream = await gdm.call(w.navigator.mediaDevices, {
            video: true, monitorTypeSurfaces: 'include', surfaceSwitching: 'include',
          });
        } catch (err) {
          note('tamper', 'iframe capture bypass', false, 'refused: ' + err.name);
          return;
        }
        const st = stream.getVideoTracks()[0].getSettings();
        const dpr = devicePixelRatio || 1;
        const scr = { w: Math.round(screen.width * dpr), h: Math.round(screen.height * dpr) };
        const inner = { w: Math.round(innerWidth * dpr), h: Math.round(innerHeight * dpr) };
        const isScreen = Math.abs(st.width - scr.w) <= 8 && Math.abs(st.height - scr.h) <= 8;
        const isTab = Math.abs(st.width - inner.w) <= 40 && Math.abs(st.height - inner.h) <= 140;
        stream.getTracks().forEach(t => t.stop());
        note('tamper', 'iframe capture bypass', isScreen && !isTab,
             `${st.width}x${st.height} surface=${st.displaySurface} ` +
             `screen=${scr.w}x${scr.h} viewport=${inner.w}x${inner.h} ` +
             `isScreen=${isScreen} isTab=${isTab}`);
      };
    } catch (e) {
      note('tamper', 'iframe pristine toString', false, 'iframe route failed: ' + e.message);
    }
  })();

  setTimeout(() => document.getElementById('gate').classList.add('on'), 1200);
  summarise();
})();
