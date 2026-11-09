// The hidden traffic counter: NBADash's panel (open for, requests, data, by kind), plus requests per server and the
// last 40 requests. Opened by clicking the brand five times within 3 seconds, as in NBADash, or from Settings > Data.
import * as bridge from '../bridge.js';
import { h, fmtBytes, fmtDuration } from '../util.js';
import { overlay } from './settings.js';

export function openTraffic() {
  let timer = 0;
  const body = h('div', null);
  const draw = async () => {
    // NBADash checks only isConnected, but its first draw runs before the panel is on screen, so the timer stopped at
    // once and the panel stayed empty. Stop only once the panel has been shown and then closed.
    if (!body.isConnected) { if (body.dataset.mounted) clearInterval(timer); return; }
    body.dataset.mounted = '1';
    let t;
    try { t = await bridge.request('traffic.get'); } catch (e) { body.replaceChildren(h('p', null, e.message)); return; }
    const rows = Object.entries(t.byKind || {}).sort((a, b) => b[1].bytes - a[1].bytes);
    const hosts = Object.entries(t.byHost || {}).sort((a, b) => b[1].requests - a[1].requests);
    const last = t.lastList || [];
    body.replaceChildren(
      h('dl', { class: 'kv' },
        h('dt', null, 'Open for'), h('dd', null, fmtDuration(t.uptimeSec)),
        h('dt', null, 'Requests'), h('dd', null, `${t.requests} (${t.errors || 0} failed)`),
        h('dt', null, 'Downloaded'), h('dd', null, fmtBytes(t.bytes)),
        h('dt', null, 'Last request'), h('dd', null, t.last || '—')),
      h('table', { class: 'tbl', style: { marginTop: '12px' } },
        h('thead', null, h('tr', null, ['Kind', 'Requests', 'Data'].map((c) => h('th', null, c)))),
        h('tbody', null, rows.map(([k, v]) => h('tr', null, h('td', null, k), h('td', null, v.requests), h('td', null, fmtBytes(v.bytes)))))),
      h('table', { class: 'tbl', style: { marginTop: '12px' } },
        h('thead', null, h('tr', null, ['Server', 'Requests', 'Data', 'Failed'].map((c) => h('th', null, c)))),
        h('tbody', null, hosts.map(([k, v]) => h('tr', null, h('td', null, k), h('td', null, v.requests), h('td', null, fmtBytes(v.bytes)), h('td', null, v.errors))))),
      h('details', { style: { marginTop: '12px' } }, h('summary', null, `Last ${last.length} requests`),
        h('table', { class: 'tbl', style: { marginTop: '8px' } },
          h('thead', null, h('tr', null, ['Time', 'What', 'Size', 'Took', 'Result'].map((c) => h('th', null, c)))),
          h('tbody', null, last.map((r) => h('tr', null, h('td', null, new Date(r.at).toLocaleTimeString()), h('td', null, r.key), h('td', null, fmtBytes(r.bytes)), h('td', null, `${r.ms} ms`), h('td', null, r.ok ? 'OK' : 'failed')))))),
      h('p', null, h('small', null, 'Counted by the dash itself, the same numbers DashLauncher shows. Update checks to GitHub are not counted.')));
  };
  overlay((close) => {
    const stop = () => clearInterval(timer);
    timer = setInterval(draw, 2000); setTimeout(draw, 0);
    return h('div', { onclick: null }, h('h2', null, '🕵 Traffic counter'), body,
      h('p', { style: { textAlign: 'right' } }, h('button', { class: 'btn primary', type: 'button', onclick: () => { stop(); close(); } }, 'Close')));
  });
  document.getElementById('overlay-root').firstChild.addEventListener('click', (e) => { if (e.target.classList.contains('overlay')) clearInterval(timer); });
}
