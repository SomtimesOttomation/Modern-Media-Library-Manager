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
    const list = S.state.collections.map((c) => [c, countIn(c, tab)]).filter(([, n]) => n > 0 || S.state.collections.length < 30);
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
  const pop = h('div', { class: 'sortmenu card colpop', role: 'menu' });
  const paint = () => {
    const manual = S.state.collections.filter((c) => c.type !== 'rule');
    const inIt = (c) => (eps ? eps.some((e) => c.has(e)) : c.has(r));
    const name = h('input', { type: 'text', placeholder: 'New collection name', maxlength: '80' });
    pop.replaceChildren(
      ...manual.map((c) => h('label', { class: 'colrow' }, h('input', { type: 'checkbox', checked: inIt(c) ? true : null, onchange: (e) => toggle(c, e.target.checked) }), c.name)),
      manual.length ? h('hr') : null,
      h('div', { class: 'colnew' }, name, h('button', { class: 'btn primary', type: 'button', onclick: () => create(name.value) }, 'Add')));
  };
  const toggle = async (c, on) => {
    const list = S.state.collections.map((x) => (x.name !== c.name ? x : { ...x, items: on ? [...x.items, item] : x.items.filter((it) => !it.ids.some((id) => item.ids.includes(id) || (eps && eps.some((e) => e.Rid === id)))) }));
    await S.saveCollections(list); paint();
  };
  const create = async (n) => {
    n = n.trim(); if (!n) return;
    if (S.state.collections.some((c) => c.name.toLowerCase() === n.toLowerCase())) { const c = S.state.collections.find((x) => x.name.toLowerCase() === n.toLowerCase()); if (c.type !== 'rule') await toggle(c, true); return; }
    await S.saveCollections([...S.state.collections, { name: n, type: 'manual', query: '', items: [item] }]); paint();
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
      const rows = S.state.collections.map((c) => {
        const name = h('input', { type: 'text', value: c.name, maxlength: '80', 'aria-label': 'Name' });
        const query = c.type === 'rule' ? h('input', { type: 'text', value: c.query, 'aria-label': 'Search', placeholder: 'genre:Horror year:1980-1989' }) : null;
        const save = async () => {
          const n = name.value.trim(); if (!n) return;
          await S.saveCollections(S.state.collections.map((x) => (x.name !== c.name ? x : { ...x, name: n, query: query ? query.value.trim() : x.query })));
          paint();
        };
        name.onchange = save; if (query) query.onchange = save;
        return h('div', { class: 'colmgr-row' }, name, query || h('small', null, `${c.items.length} title${c.items.length === 1 ? '' : 's'}, hand-picked`),
          h('small', null, `${countIn(c, tab)} here`),
          h('button', { class: 'btn', type: 'button', onclick: () => { close(); S.setQuery(q(c.name)); } }, 'Show'),
          h('button', { class: 'btn', type: 'button', title: 'Delete (click twice)', onclick: async (e) => {
            if (!e.currentTarget.dataset.sure) { e.currentTarget.dataset.sure = '1'; e.currentTarget.textContent = 'Sure?'; return; }
            await S.saveCollections(S.state.collections.filter((x) => x.name !== c.name)); paint();
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
          if (S.state.collections.some((c) => c.name.toLowerCase() === n.toLowerCase())) { nn.select(); return; }
          await S.saveCollections([...S.state.collections, { name: n, type: 'rule', query: nq.value.trim(), items: [] }]); paint();
        } }, 'Create')));
    };
    paint();
    return h('div', { class: 'adv' }, h('h2', null, 'Collections'),
      h('p', null, h('small', null, 'Shared with the window app. Nothing is written to Plex or to your files.')), body,
      h('p', { class: 'adv-actions' }, h('button', { class: 'btn primary', type: 'button', onclick: close }, 'Done')));
  }, 'adv-host');
}
