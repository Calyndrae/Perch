/* VidTube — a deliberately hostile video page, used to test Perch.
 *
 * Two independent jobs:
 *
 *  1. BEHAVIOUR probes: act like a bad video site (pause on blur, "are you still
 *     watching", exit-intent popup, unload prompt) and report whether each one
 *     ever fired. With Perch working, none of them should.
 *
 *  2. ANTI-SPOOF scan: actively try to catch the extension lying. A real site
 *     does this to force you to turn the blocker off. If any check trips, the
 *     "close the app to continue" wall appears — which is the failure mode Perch
 *     has to avoid, not just the popups.
 *
 * IMPORTANT: this file captures native references before anything else runs, so
 * that its own bookkeeping can't be silenced by the very overrides it measures.
 */
(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const now = () => performance.now();

  // ---------------------------------------------------------------- probes ---
  // state: 'wait' (not yet exercised), 'ok' (defeated), 'bad' (site won)
  // Perch's own remit: the leaving-the-page nags. A CAUGHT here is a Perch bug.
  const behaviour = {
    exitIntent:   { label: 'exit-intent popup shown',   state: 'ok', detail: 'never shown' },
    beforeUnload: { label: 'unload prompt armed',       state: 'ok', detail: 'no handler took' },
  };

  // Deliberately NOT Perch's remit — a separate extension owns page visibility.
  // These are shown for completeness; CAUGHT here means only that nothing is
  // spoofing visibility right now, which is the expected state with Perch alone.
  const elsewhere = {
    visibility:   { label: 'visibilitychange fired',         state: 'ok',   detail: 'never fired', count: 0 },
    hiddenProp:   { label: 'document.hidden went true',      state: 'ok',   detail: 'stayed false' },
    blur:         { label: 'window blur fired',              state: 'ok',   detail: 'never fired', count: 0 },
    hasFocus:     { label: 'document.hasFocus() went false', state: 'ok',   detail: 'stayed true' },
    stillWatching:{ label: '“Are you still watching?”',       state: 'ok',   detail: 'never shown' },
    videoPaused:  { label: 'video force-paused',             state: 'ok',   detail: 'still playing' },
    rafThrottle:  { label: 'animation throttled',            state: 'wait', detail: 'measuring…' },
    timerThrottle:{ label: 'timers throttled',               state: 'wait', detail: 'measuring…' },
  };

  const spoof = {
    hiddenNative:   { label: 'document.hidden is native',        state: 'wait', detail: '' },
    visStateNative: { label: 'visibilityState is native',        state: 'wait', detail: '' },
    addListener:    { label: 'addEventListener is native',       state: 'wait', detail: '' },
    toStringNative: { label: 'Function.toString is native',      state: 'wait', detail: '' },
    hasFocusNative: { label: 'document.hasFocus is native',      state: 'wait', detail: '' },
    ownProps:       { label: 'no injected globals',              state: 'wait', detail: '' },
    instanceShadow: { label: 'no own props shadowing Document',  state: 'wait', detail: '' },
    coherence:      { label: 'visible page actually animates',   state: 'wait', detail: 'measuring…' },
  };

  // --------------------------------------------------------------- render ---
  const BADGE = { ok: 'OK', bad: 'CAUGHT', wait: '…', warn: 'WARN' };

  function renderTable(el, probes) {
    el.innerHTML = Object.values(probes).map((p) => `
      <tr>
        <td class="name">${p.label}</td>
        <td style="width:110px"><span class="badge ${p.state}">${BADGE[p.state]}</span></td>
        <td class="detail">${p.detail}</td>
      </tr>`).join('');
  }

  function render() {
    renderTable($('behaviourTable'), behaviour);
    renderTable($('elsewhereTable'), elsewhere);
    renderTable($('spoofTable'), spoof);

    // Only Perch's own probes and the anti-spoof scan count toward the score.
    const all = [...Object.values(behaviour), ...Object.values(spoof)];
    const bad = all.filter((p) => p.state === 'bad').length;
    const waiting = all.filter((p) => p.state === 'wait').length;
    const good = all.filter((p) => p.state === 'ok').length;

    $('score').textContent = `${good}/${all.length} clean` + (waiting ? ` · ${waiting} measuring` : '');

    // Mirrored into the title so an automated run can read the result over
    // Chrome's /json endpoint without scraping pixels or scrolling the page.
    document.title = `VidTube [fps=${lastFps}|worst=${worstFps}|vis=${document.visibilityState}`
      + `|hidden=${document.hidden}|caught=${bad}|wall=${wallShown ? 1 : 0}]`;
    $('score').style.color = bad ? 'var(--bad)' : (waiting ? 'var(--dim)' : 'var(--ok)');

    $('hint').innerHTML = bad
      ? `<b style="color:var(--bad)">${bad} check(s) caught you.</b> The site knows. `
      + `Rows marked CAUGHT are what a real site would use to force the wall.`
      : waiting
      ? 'Measuring… switch to another app for ~10 seconds, then come back and read the results.'
      : '<b style="color:var(--ok)">Clean.</b> The page never noticed you left, and its '
      + 'anti-spoof scan found nothing.';
  }

  function fail(probes, key, detail) {
    if (probes[key].state === 'bad') return;
    probes[key].state = 'bad';
    probes[key].detail = detail;
    render();
    if (probes === spoof) showWall(probes[key].label);
  }

  function pass(probes, key, detail) {
    if (probes[key].state === 'bad') return;
    probes[key].state = 'ok';
    probes[key].detail = detail;
    render();
  }

  // ------------------------------------------------------ hostile behaviour ---
  const video = $('player');
  let wallShown = false;

  window.Hostile = {
    dismiss(id) { $(id).classList.remove('show'); },
    resume() { $('stillWatching').classList.remove('show'); video.play().catch(() => {}); },
    recheck() { $('adblockWall').classList.remove('show'); wallShown = false; runSpoofScan(); },
  };

  function showWall(reason) {
    if (wallShown) return;
    wallShown = true;
    $('wallReason').textContent =
      `We've detected software interfering with this page (${reason}). `
      + `Close it to keep watching VidTube.`;
    $('adblockWall').classList.add('show');
  }

  // A real playing <video> with no asset file: a canvas animation piped through
  // captureStream. This also gives the rAF meter something honest to measure.
  const canvas = document.createElement('canvas');
  canvas.width = 640; canvas.height = 360;
  const ctx = canvas.getContext('2d');

  let rafCount = 0, hue = 0;
  (function draw() {
    hue = (hue + 0.7) % 360;
    ctx.fillStyle = `hsl(${hue} 45% 12%)`;
    ctx.fillRect(0, 0, 640, 360);
    ctx.fillStyle = `hsl(${(hue + 140) % 360} 70% 55%)`;
    const t = now() / 1000;
    for (let i = 0; i < 7; i++) {
      const x = 320 + Math.cos(t + i * 0.9) * 210;
      const y = 180 + Math.sin(t * 1.3 + i * 0.7) * 110;
      ctx.beginPath(); ctx.arc(x, y, 26, 0, Math.PI * 2); ctx.fill();
    }
    ctx.fillStyle = '#fff'; ctx.font = '600 20px system-ui';
    ctx.fillText('VidTube live test stream', 24, 40);
    rafCount++;
    requestAnimationFrame(draw);
  })();

  video.srcObject = canvas.captureStream(60);
  video.play().catch(() => {});

  // Pause-on-leave, the classic.
  function pauseBecauseGone(why) {
    if (video.paused) return;
    video.pause();
    $('playerState').textContent = '❚❚ paused — ' + why;
    fail(elsewhere, 'videoPaused', 'paused by: ' + why);
  }

  document.addEventListener('visibilitychange', () => {
    elsewhere.visibility.count++;
    fail(elsewhere, 'visibility', `fired ${elsewhere.visibility.count}×, state=${document.visibilityState}`);
    if (document.hidden) { pauseBecauseGone('tab hidden'); showStillWatching(); }
  });

  window.addEventListener('blur', () => {
    elsewhere.blur.count++;
    fail(elsewhere, 'blur', `fired ${elsewhere.blur.count}×`);
    pauseBecauseGone('window blurred');
    showStillWatching();
  });

  // If the listener registers at all, Perch failed to swallow it.
  (() => {
    let armed = false;
    const probe = (e) => { armed = true; e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', probe);
    setTimeout(() => {
      // Perch removes the listener outright, so the handler slot stays empty.
      if (window.onbeforeunload === probe) fail(behaviour, 'beforeUnload', 'handler stuck');
    }, 1200);
  })();

  function showStillWatching() {
    if ($('stillWatching').classList.contains('show')) return;
    $('stillWatching').classList.add('show');
    fail(elsewhere, 'stillWatching', 'shown');
  }

  // Exit intent: pointer leaving through the top edge, toward the tab bar.
  document.addEventListener('mouseleave', (e) => {
    if (e.clientY <= 0) {
      $('exitPopup').classList.add('show');
      fail(behaviour, 'exitIntent', 'triggered at clientY=' + e.clientY);
    }
  });

  // Polled properties — these catch a page that lies via events but not values.
  setInterval(() => {
    if (document.hidden) fail(elsewhere, 'hiddenProp', 'document.hidden === true');
    if (!document.hasFocus()) fail(elsewhere, 'hasFocus', 'hasFocus() === false');
    $('playerState').textContent = video.paused
      ? $('playerState').textContent
      : '● playing';
  }, 500);

  // ------------------------------------------------------------- throttling ---
  // If the page is genuinely being drawn, rAF runs near display rate. Chrome
  // drops it to ~1fps for a backgrounded/occluded window — which is exactly what
  // the "keep Chrome drawing when covered" setting in Perch prevents.
  let lastRafCount = 0, lastSample = now(), samples = [];
  let lastFps = 0, worstFps = 0;
  setInterval(() => {
    const t = now();
    const fps = (rafCount - lastRafCount) / ((t - lastSample) / 1000);
    lastRafCount = rafCount; lastSample = t;
    samples.push(fps);
    if (samples.length > 6) samples.shift();

    const worst = Math.min(...samples);
    lastFps = fps.toFixed(0); worstFps = worst.toFixed(0);
    const text = `${fps.toFixed(0)} fps now, ${worst.toFixed(0)} fps worst`;

    if (worst < 10) fail(elsewhere, 'rafThrottle', text + ' — throttled');
    else pass(elsewhere, 'rafThrottle', text);

    // Coherence: claiming "visible" while animation is throttled is a
    // contradiction only a spoofer produces.
    if (document.visibilityState === 'visible' && worst < 5) {
      fail(spoof, 'coherence', `claims visible but ran at ${worst.toFixed(0)} fps`);
    } else if (samples.length >= 3) {
      pass(spoof, 'coherence', text);
    }
  }, 1000);

  let timerLast = Date.now(), timerWorst = 0;
  setInterval(() => {
    const drift = Date.now() - timerLast - 1000;
    timerLast = Date.now();
    timerWorst = Math.max(timerWorst, drift);
    if (timerWorst > 2000) fail(elsewhere, 'timerThrottle', `${timerWorst}ms worst drift`);
    else pass(elsewhere, 'timerThrottle', `${timerWorst}ms worst drift`);
  }, 1000);

  // ------------------------------------------------------------ spoof scan ---
  const NATIVE = '[native code]';

  function checkNative(key, fn, what) {
    if (typeof fn !== 'function') { fail(spoof, key, `${what} is not a function`); return; }
    let src;
    try { src = Function.prototype.toString.call(fn); }
    catch (err) { fail(spoof, key, `toString threw: ${err.message}`); return; }
    if (src.includes(NATIVE)) pass(spoof, key, src.trim().slice(0, 52));
    else fail(spoof, key, 'source is JS, not native: ' + src.trim().slice(0, 46).replace(/\s+/g, ' '));
  }

  function runSpoofScan() {
    const hidden = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden');
    const visState = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');

    checkNative('hiddenNative', hidden && hidden.get, 'Document.prototype.hidden getter');
    checkNative('visStateNative', visState && visState.get, 'visibilityState getter');
    checkNative('addListener', EventTarget.prototype.addEventListener, 'addEventListener');
    checkNative('hasFocusNative', Document.prototype.hasFocus, 'hasFocus');

    // Meta: a spoofer must patch toString itself, so check that it still claims
    // to be native — and that it hasn't been replaced by a plain JS function.
    checkNative('toStringNative', Function.prototype.toString, 'Function.prototype.toString');

    // Known blocker fingerprints on the global object.
    const suspects = Object.getOwnPropertyNames(window)
      .filter((n) => /^(__)?(perch|spoof|fake|block|stealth|antidetect)/i.test(n));
    if (suspects.length) fail(spoof, 'ownProps', 'found: ' + suspects.join(', '));
    else pass(spoof, 'ownProps', 'none found');

    // A lazy override often lands on the document instance rather than the
    // prototype, which is trivially visible.
    const shadowed = ['hidden', 'visibilityState', 'hasFocus']
      .filter((p) => Object.prototype.hasOwnProperty.call(document, p));
    if (shadowed.length) fail(spoof, 'instanceShadow', 'shadowed: ' + shadowed.join(', '));
    else pass(spoof, 'instanceShadow', 'clean');
  }

  runSpoofScan();
  setInterval(runSpoofScan, 5000);
  render();
})();
