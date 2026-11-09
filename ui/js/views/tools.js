// Tools for the open tab, on what it shows right now (a search or collection narrows it): Fetch info, FEL/MEL check,
// CSV export and the standalone HTML dashboard. They run in the backend; progress shows in the strip under the bar.
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { h } from '../util.js';
import { overlay } from './settings.js';
import { gridColumns } from './library.js';

// The titles the tab shows now (set by the views); [] = the whole tab.
export const viewRids = { movies: null, tv: null };
const ridsFor = (tab) => (viewRids[tab] && viewRids[tab].length !== S.state.libs[tab].rows.length ? viewRids[tab].map((r) => r.Rid).filter(Boolean) : []);
const scopeText = (tab) => { const n = ridsFor(tab).length; return n ? `the ${n.toLocaleString()} ${tab === 'tv' ? 'episodes' : 'titles'} shown now` : `the whole ${tab === 'tv' ? 'TV Shows' : 'Movies'} tab`; };
const nameFor = (tab) => { const m = /collection:"([^"]+)"/i.exec(S.state.query); return m ? m[1] : S.state.query ? `${tab === 'tv' ? 'TV' : 'Movies'} - ${S.state.query.slice(0, 40)}` : (tab === 'tv' ? 'TV Shows' : 'Movies'); };

async function start(kind, tab, extra = {}) {
  try { await bridge.request('tools.start', { kind, tab, rids: ridsFor(tab), name: nameFor(tab), ...extra }); S.state.tool = { kind, running: true, pct: 0, text: 'Starting...' }; S.notify('tool'); }
  catch (e) { S.toast?.(e.message); }
}

function fetchDialog(tab) {
  overlay((close) => {
    const keys = h('div');
    const over = h('input', { type: 'checkbox' });
    const go = h('button', { class: 'btn primary', type: 'button', onclick: () => { close(); start('fetch', tab, { overwrite: over.checked }); } }, 'Fetch info');
    bridge.request('keys.get').then((k) => {
      keys.replaceChildren(h('p', null, h('small', null, `Keys: TMDB ${k.tmdb ? 'saved' : 'missing'}, OMDb ${k.omdb ? 'saved' : 'missing'}. `,
        h('a', { href: '#', onclick: (e) => { e.preventDefault(); close(); import('./settings.js').then((m) => m.openSettings('data')); } }, 'Change in Settings > Data'))));
      if (!k.tmdb && !k.omdb) go.disabled = true;
    }).catch(() => {});
    return h('div', { class: 'adv' }, h('h2', null, 'Fetch info'),
      h('p', null, `Looks up ratings, Rotten Tomatoes, Metacritic and box office for ${scopeText(tab)}, as the window app's Fetch info does.`),
      h('p', { class: 'warnbox' }, h('b', null, 'This contacts outside services: '), 'TMDB and OMDb (with your own keys) and the IMDb ratings file from datasets.imdbws.com. Use it sparingly; each title is one or two requests. Values you typed in yourself are never replaced.'),
      keys,
      h('p', null, h('label', null, over, ' Also replace values that are already filled in')),
      h('p', { class: 'adv-actions' }, h('button', { class: 'btn', type: 'button', onclick: close }, 'Cancel'), go));
  }, 'adv-host');
}

export function toolsMenu(tab) {
  const wrap = h('div', { class: 'sortbtn' });
  const btn = h('button', { type: 'button', 'aria-haspopup': 'menu', title: 'Fetch info, FEL/MEL check, export' }, 'Tools', h('span', { 'aria-hidden': 'true' }, '▾'));
  wrap.append(btn);
  let menu = null;
  const close = () => { menu?.remove(); menu = null; document.removeEventListener('mousedown', out, true); };
  const out = (e) => { if (!wrap.contains(e.target)) close(); };
  const item = (label, sub, fn, disabled) => h('button', { type: 'button', disabled: disabled ? true : null, onclick: () => { close(); fn(); } }, label, h('small', null, sub));
  btn.onclick = () => {
    if (menu) { close(); return; }
    const busy = S.state.tool && S.state.tool.running;
    const cols = S.state.libs[tab].status === 'ready' ? gridColumns(S.state.libs[tab]) : [];
    menu = h('div', { class: 'sortmenu card', role: 'menu' },
      tab === 'movies' ? item('Fetch info…', 'ratings, Metacritic, box office', () => fetchDialog(tab), busy || S.state.halted) : null,
      item('Check FEL / MEL', 'Dolby Vision dual layer', () => start('fel', tab), busy || S.state.halted),
      item('Export CSV', 'grid columns', () => start('csv', tab, { columns: cols }), busy),
      item('Export HTML dashboard', 'one file, posters inside', () => start('html', tab), busy),
      h('div', { class: 'menu-note' }, `On ${scopeText(tab)}.`));
    wrap.append(menu);
    document.addEventListener('mousedown', out, true);
  };
  return wrap;
}
