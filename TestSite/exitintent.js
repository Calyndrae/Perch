/* Every way real exit-intent libraries detect the pointer heading for the tab
 * bar. Each technique registers its own handler, then a synthetic gesture is
 * fired. Whatever still reaches its handler is a hole in Perch's coverage.
 *
 * Registration deliberately uses the varied shapes real code uses — property
 * assignment, capture phase, mouseout with relatedTarget, mousemove tracking —
 * rather than the single canonical form the main harness tests.
 */
(() => {
  'use strict';

  const techniques = [
    {
      name: 'document mouseleave (ouibounce)',
      how: "document.addEventListener('mouseleave')",
      arm(hit) { document.addEventListener('mouseleave', e => { if (e.clientY <= 0) hit(); }); },
    },
    {
      name: 'documentElement mouseleave',
      how: "document.documentElement.addEventListener('mouseleave')",
      arm(hit) { document.documentElement.addEventListener('mouseleave', e => { if (e.clientY <= 0) hit(); }); },
    },
    {
      name: 'body mouseout + relatedTarget',
      how: "document.body.addEventListener('mouseout')",
      arm(hit) {
        document.body.addEventListener('mouseout', e => {
          if (!e.relatedTarget && e.clientY <= 0) hit();
        });
      },
    },
    {
      name: 'window mouseout',
      how: "window.addEventListener('mouseout')",
      arm(hit) { window.addEventListener('mouseout', e => { if (e.clientY <= 0) hit(); }); },
    },
    {
      name: 'capture-phase mouseleave',
      how: "addEventListener(..., {capture: true})",
      arm(hit) {
        document.addEventListener('mouseleave', e => { if (e.clientY <= 0) hit(); }, { capture: true });
      },
    },
    {
      name: 'onmouseleave property',
      how: 'document.documentElement.onmouseleave = fn',
      arm(hit) { document.documentElement.onmouseleave = e => { if (e.clientY <= 0) hit(); }; },
    },
    {
      name: 'onmouseout property on body',
      how: 'document.body.onmouseout = fn',
      arm(hit) { document.body.onmouseout = e => { if (e.clientY <= 0) hit(); }; },
    },
    {
      name: 'mousemove toward top edge',
      how: "document.addEventListener('mousemove'), y < 5",
      arm(hit) {
        let lastY = 999;
        document.addEventListener('mousemove', e => {
          if (e.clientY < 5 && e.clientY < lastY) hit();
          lastY = e.clientY;
        });
      },
    },
  ];

  const results = techniques.map(t => ({ ...t, fired: false }));
  results.forEach(t => t.arm(() => { t.fired = true; }));

  // Fire the gestures a real departure would produce.
  function gesture() {
    const opts = { bubbles: true, cancelable: true, clientX: 400, clientY: 0, relatedTarget: null };
    for (const target of [document, document.documentElement, document.body, window]) {
      for (const type of ['mouseleave', 'mouseout']) {
        try { target.dispatchEvent(new MouseEvent(type, opts)); } catch (_) {}
      }
    }
    // Two moves so the "heading upward" check has a direction to see.
    document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 400, clientY: 40 }));
    document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 400, clientY: 2 }));
  }

  function render() {
    document.getElementById('rows').innerHTML = results.map(t => `
      <tr>
        <td>${t.name}</td>
        <td><span class="b ${t.fired ? 'fired' : 'blocked'}">${t.fired ? 'FIRED' : 'BLOCKED'}</span></td>
        <td><code>${t.how}</code></td>
      </tr>`).join('');

    const holes = results.filter(t => t.fired);
    document.getElementById('summary').innerHTML = holes.length
      ? `<b style="color:#ff4d4d">${holes.length} of ${results.length} got through.</b> `
      + holes.map(h => h.name).join('; ')
      : `<b style="color:#2ecc71">All ${results.length} blocked.</b>`;

    // Machine-readable for the automated runs.
    window.__matrix = results.map(t => ({ name: t.name, fired: t.fired }));
    document.title = `matrix ${results.filter(t => !t.fired).length}/${results.length} blocked`;
  }

  setTimeout(() => { gesture(); setTimeout(render, 200); }, 400);
})();
