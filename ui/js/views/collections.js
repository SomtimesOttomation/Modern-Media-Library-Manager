// Collections in the page: the same lists as the window app (collections.json). Pick one to show only its titles,
// add titles from their cards, or make a rule collection from the current search.
import * as S from '../store.js';
import { h } from '../util.js';
import { overlay } from './settings.js';

const q = (name) => `collection:"${name.replace(/"/g, '')}"`;
const countIn = (c, tab) => {
  const L = S.state.libs[tab]; if (L.status !== 'ready') return 0;
  if (tab === 'tv') return new Set(L.rows.filter((r) => c.has(r)).map((r) => r.Show || r.Title)).size;
  return L.rows.filter((r) => c.has(r)).length;
};
// Movies and TV Shows keep separate lists. A collection saved before that (no tab) shows where its titles are;
// an old rule collection shows on both.
export function inTab(c, tab) {
  if (c.tab) return c.tab === tab;
  if (c.type === 'rule' || !c.items.length) return true;
  const L = S.state.libs[tab];
  return L.status === 'ready' && L.rows.some((r) => c.has(r));
}
const sameName = (a, b) => a.trim().toLowerCase() === b.trim().toLowerCase();
const activeName = () => { const m = /collection:"([^"]+)"/i.exec(S.state.query); return m ? m[1] : ''; };

// The "Collection" button in a tab's toolbar.
export function collectionMenu(tab) {
  const wrap = h('div', { class: 'sortbtn' });
  const act = activeName();
  const btn = h('button', { type: 'button', 'aria-haspopup': 'menu', title: 'Show one collection' }, act ? `Collection: ${act}` : 'Collections', h('span', { 'aria-hidden': 'true' }, '▾'));
  wrap.append(btn);
  let menu = null;
  const close = () => { menu?.remove(); menu = null; document.removeEventListener('mousedown', out, true); };
  const out = (e) => { if (!wrap.contains(e.target)) close(); };
  btn.onclick = () => {
    if (menu) { close(); return; }
    const list = S.state.collections.filter((c) => inTab(c, tab)).map((c) => [c, countIn(c, tab)]);
    menu = h('div', { class: 'sortmenu card', role: 'menu' },
      h('button', { type: 'button', class: act ? '' : 'on', onclick: () => { close(); if (act) S.setQuery(S.state.query.replace(/collection:"[^"]+"\s*/i, '')); } }, 'All titles', h('small', null, '')),
      ...list.map(([c, n]) => h('button', { type: 'button', class: c.name === act ? 'on' : '', onclick: () => { close(); S.setQuery(q(c.name)); } }, c.name, h('small', null, `${n}${c.type === 'rule' ? ' · rule' : ''}`))),
      h('button', { type: 'button', onclick: () => { close(); manageCollections(tab); } }, 'Manage collections…', h('small', null, '')));
    wrap.append(menu);
    document.addEventListener('mousedown', out, true);
  };
  return wrap;
}

// "Add to collection" on a card: tick the hand-picked collections this title belongs in; or start a new one.
export function addToCollection(anchor, r, eps) {
  const item = S.itemFor(r, eps);
  if (!item.ids.length) return;
  const tab = eps ? 'tv' : (r._tab || 'movies');
  const pop = h('div', { class: 'sortmenu card colpop', role: 'menu' });
  const paint = () => {
    const manual = S.state.collections.filter((c) => c.type !== 'rule' && inTab(c, tab));
    const inIt = (c) => (eps ? eps.some((e) => c.has(e)) : c.has(r));
    const name = h('input', { type: 'text', placeholder: 'New collection name', maxlength: '80' });
    pop.replaceChildren(
      ...manual.map((c) => h('label', { class: 'colrow' }, h('input', { type: 'checkbox', checked: inIt(c) ? true : null, onchange: (e) => toggle(c, e.target.checked) }), c.name)),
      manual.length ? h('hr') : null,
      h('div', { class: 'colnew' }, name, h('button', { class: 'btn primary', type: 'button', onclick: () => create(name.value) }, 'Add')));
  };
  const toggle = async (c, on) => {
    const list = S.state.collections.map((x) => (x !== c ? x : { ...x, items: on ? [...x.items, item] : x.items.filter((it) => !it.ids.some((id) => item.ids.includes(id) || (eps && eps.some((e) => e.Rid === id)))) }));
    await S.saveCollections(list); paint();
  };
  const create = async (n) => {
    n = n.trim(); if (!n) return;
    const c = S.state.collections.find((x) => inTab(x, tab) && sameName(x.name, n));
    if (c) { if (c.type !== 'rule') await toggle(c, true); return; }
    await S.saveCollections([...S.state.collections, { name: n, tab, type: 'manual', query: '', items: [item] }]); paint();
  };
  paint();
  anchor.after(pop);
  const out = (e) => { if (!pop.contains(e.target) && e.target !== anchor) { pop.remove(); document.removeEventListener('mousedown', out, true); } };
  setTimeout(() => document.addEventListener('mousedown', out, true));
}

// Manage: rename, delete, edit a rule's search, make a rule from the current search.
export function manageCollections(tab) {
  overlay((close) => {
    const body = h('div');
    const paint = () => {
      const rows = S.state.collections.filter((c) => inTab(c, tab)).map((c) => {
        const name = h('input', { type: 'text', value: c.name, maxlength: '80', 'aria-label': 'Name' });
        const query = c.type === 'rule' ? h('input', { type: 'text', value: c.query, 'aria-label': 'Search', placeholder: 'genre:Horror year:1980-1989' }) : null;
        const save = async () => {
          const n = name.value.trim(); if (!n) return;
          await S.saveCollections(S.state.collections.map((x) => (x !== c ? x : { ...x, name: n, tab: x.tab || tab, query: query ? query.value.trim() : x.query })));
          paint();
        };
        name.onchange = save; if (query) query.onchange = save;
        return h('div', { class: 'colmgr-row' }, name, query || h('small', null, `${c.items.length} title${c.items.length === 1 ? '' : 's'}, hand-picked`),
          h('small', null, `${countIn(c, tab)} here`),
          h('button', { class: 'btn', type: 'button', onclick: () => { close(); S.setQuery(q(c.name)); } }, 'Show'),
          h('button', { class: 'btn', type: 'button', title: 'Delete (click twice)', onclick: async (e) => {
            if (!e.currentTarget.dataset.sure) { e.currentTarget.dataset.sure = '1'; e.currentTarget.textContent = 'Sure?'; return; }
            await S.saveCollections(S.state.collections.filter((x) => x !== c)); paint();
          } }, 'Delete'));
      });
      const nn = h('input', { type: 'text', placeholder: 'Name', maxlength: '80' });
      const nq = h('input', { type: 'text', value: S.state.query.replace(/collection:"[^"]+"\s*/i, ''), placeholder: 'Search, e.g. genre:Horror year:1980-1989' });
      body.replaceChildren(
        rows.length ? h('div', { class: 'colmgr' }, ...rows) : h('p', null, h('small', null, 'No collections yet. Add titles from their cards, or make a rule below.')),
        h('hr'),
        h('p', null, h('b', null, 'New rule collection '), h('small', null, 'A saved search: it updates itself after every scan. Separate alternatives with commas.')),
        h('div', { class: 'colmgr-row' }, nn, nq, h('button', { class: 'btn primary', type: 'button', onclick: async () => {
          const n = nn.value.trim(); if (!n || !nq.value.trim()) return;
          if (S.state.collections.some((c) => inTab(c, tab) && sameName(c.name, n))) { nn.select(); return; }
          await S.saveCollections([...S.state.collections, { name: n, tab, type: 'rule', query: nq.value.trim(), items: [] }]); paint();
        } }, 'Create')));
    };
    paint();
    return h('div', { class: 'adv' }, h('h2', null, `Collections \u00b7 ${tab === 'tv' ? 'TV Shows' : 'Movies'}`),
      h('p', null, h('small', null, 'Shared with the window app. Nothing is written to Plex or to your files.')), body,
      h('p', { class: 'adv-actions' }, h('button', { class: 'btn primary', type: 'button', onclick: close }, 'Done')));
  }, 'adv-host');
}

/* ---- Collection mode: tick titles with the + on each poster (or the first grid column), name it, Done. ----------
   The picks are kept per tab while the page is open, so changing search, sort or view does not lose them. */
export const CM = { movies: { on: false, name: '', picked: new Map() }, tv: { on: false, name: '', picked: new Map() } };
export function cmToggle(tab, key, item) {
  const m = CM[tab];
  if (m.picked.has(key)) m.picked.delete(key); else m.picked.set(key, item);
  return m.picked.has(key);
}
async function cmDone(tab, nameBox, redraw) {
  const m = CM[tab];
  m.name = nameBox.value.trim();
  if (!m.picked.size) { S.toast?.('Tick some titles with the + first.'); return; }
  if (!m.name) { nameBox.focus(); nameBox.classList.add('need'); S.toast?.('Give the collection a name.'); return; }
  const items = [...m.picked.values()];
  const have = S.state.collections.find((c) => c.type !== 'rule' && inTab(c, tab) && sameName(c.name, m.name));
  let added = items.length;
  if (have) {
    const known = new Set(have.items.flatMap((it) => it.ids));
    const fresh = items.filter((it) => !it.ids.some((id) => known.has(id)));
    added = fresh.length;
    await S.saveCollections(S.state.collections.map((x) => (x !== have ? x : { ...x, tab: x.tab || tab, items: [...x.items, ...fresh] })));
  } else {
    await S.saveCollections([...S.state.collections, { name: m.name, tab, type: 'manual', query: '', items }]);
  }
  S.toast?.(`${added} ${added === 1 ? 'title' : 'titles'} added to \u201c${m.name}\u201d.`);
  Object.assign(m, { on: false, name: '', picked: new Map() });
  redraw();
}
// The Collection mode box next to Hide duplicates: the tick box with Done to its right, the name underneath.
export function cmControls(tab, redraw) {
  const m = CM[tab];
  const names = S.state.collections.filter((c) => c.type !== 'rule' && inTab(c, tab)).map((c) => c.name);
  const box = h('input', { type: 'text', class: 'cm-name', value: m.name, placeholder: 'Collection name (new or existing)', maxlength: '80', list: `cm-names-${tab}`,
    oninput: (e) => { m.name = e.target.value; e.target.classList.remove('need'); },
    onkeydown: (e) => { if (e.key === 'Enter') cmDone(tab, box, redraw); } });
  return h('div', { class: `cmode${m.on ? ' on' : ''}` },
    h('div', { class: 'cmode-top' },
      h('label', { class: 'chk' }, h('input', { type: 'checkbox', checked: m.on ? true : null, onchange: (e) => { m.on = e.target.checked; if (!m.on) m.picked = new Map(); redraw(); } }), 'Collection mode'),
      m.on ? h('button', { class: 'btn primary cm-done', type: 'button', onclick: () => cmDone(tab, box, redraw) }, `Done${m.picked.size ? ` (${m.picked.size})` : ''}`) : null),
    m.on ? box : null,
    m.on ? h('datalist', { id: `cm-names-${tab}` }, ...names.map((n) => h('option', { value: n }))) : null);
}
