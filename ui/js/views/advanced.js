// Advanced search: build filters row by row (field, test, value) plus free words. "Search" writes them into the search
// box in its own syntax, so what you built stays visible and editable there.
import * as S from '../store.js';
import { h } from '../util.js';
import { overlay } from './settings.js';
import { colLabel } from './library.js';

const NUM_OPS = [['=', 'is'], ['>=', 'at least'], ['<=', 'at most'], ['>', 'more than'], ['<', 'less than'], ['range', 'between']];
const TEXT_OPS = [[':', 'contains'], ['-', 'does not contain']];
const HIDE = new Set(['Poster', 'PlexKey', 'PlexThumb', 'MetaSources', 'Library', 'Rid']);
const quote = (v) => (/[\s"]/.test(v) ? `"${v.replace(/"/g, '')}"` : v);

// Distinct values of a text field (lists split on , and ;), most common first, for the value suggestions.
function values(L, name) {
  const m = new Map();
  for (const r of L.rows) for (const p of String(r[name] ?? '').split(/\s*[;,]\s*/)) if (p) m.set(p, (m.get(p) || 0) + 1);
  return [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 200).map((x) => x[0]);
}

export function openAdvanced(tab, apply) {
  const L = S.state.libs[tab];
  if (L.status !== 'ready') return;
  const fields = L.fields.filter((f) => !HIDE.has(f.n));
  const groups = [...new Set(fields.map((f) => f.g))];
  const rows = [];
  overlay((close) => {
    const list = h('div', { class: 'adv-rows' });
    const words = h('input', { type: 'text', placeholder: 'Words or phrases, e.g. 90s, atmos, highly rated, or a title', class: 'adv-words' });
    const dl = h('datalist', { id: 'adv-values' });
    const addRow = (field = 'Genre', op = ':', value = '') => {
      const fsel = h('select', { 'aria-label': 'Field' }, groups.map((g) => h('optgroup', { label: g }, fields.filter((f) => f.g === g).map((f) => h('option', { value: f.n, selected: f.n === field ? true : null }, colLabel(f.n))))));
      const osel = h('select', { 'aria-label': 'Test' });
      const val = h('input', { type: 'text', value, placeholder: 'value', list: 'adv-values', 'aria-label': 'Value' });
      const val2 = h('input', { type: 'text', placeholder: 'and', 'aria-label': 'Second value', hidden: true });
      const sync = () => {
        const f = L.byName.get(fsel.value), isNum = f && f.t !== 'string';
        const keep = osel.value;
        osel.replaceChildren(...(isNum ? NUM_OPS : TEXT_OPS).map(([k, label]) => h('option', { value: k }, label)));
        if ([...osel.options].some((o) => o.value === keep)) osel.value = keep; else if (op && [...osel.options].some((o) => o.value === op)) osel.value = op;
        val2.hidden = osel.value !== 'range';
        val.onfocus = () => { dl.replaceChildren(...(isNum ? [] : values(L, fsel.value)).map((v) => h('option', { value: v }))); };
      };
      fsel.onchange = sync; osel.onchange = () => { val2.hidden = osel.value !== 'range'; };
      const row = h('div', { class: 'adv-row' }, fsel, osel, val, val2, h('button', { class: 'btn', type: 'button', title: 'Remove', onclick: () => { row.remove(); rows.splice(rows.indexOf(item), 1); } }, '✕'));
      const item = { fsel, osel, val, val2 };
      rows.push(item); list.append(row); sync();
    };
    // start from the field terms already in the search box
    const rest = [];
    for (const t of (S.state.query.match(/(-?[A-Za-z_]+\s*(?::|>=|<=|>|<|=)\s*"[^"]*")|("[^"]*")|(\S+)/g) || [])) {
      const m = /^(-?)([A-Za-z]+)\s*(:|>=|<=|>|<|=)\s*"?([^"]*)"?$/.exec(t);
      const f = m && fields.find((x) => x.n.toLowerCase() === m[2].toLowerCase());
      if (f) {
        const range = /^(-?\d+(?:\.\d+)?)\s*-\s*(-?\d+(?:\.\d+)?)$/.exec(m[4]);
        addRow(f.n, m[1] ? '-' : range ? 'range' : (m[3] === ':' ? (f.t === 'string' ? ':' : '=') : m[3]), range ? range[1] : m[4]);
        if (range) rows[rows.length - 1].val2.value = range[2];
      } else rest.push(t);
    }
    words.value = rest.join(' ');
    if (!rows.length) addRow();
    const build = () => {
      const parts = [];
      for (const r of rows) {
        const f = r.fsel.value, op = r.osel.value, v = r.val.value.trim();
        if (!v) continue;
        if (op === 'range') parts.push(`${f}:${v}-${r.val2.value.trim() || v}`);
        else if (op === '-') parts.push(`-${f}:${quote(v)}`);
        else if (op === ':' || op === '=') parts.push(`${f}:${quote(v)}`);
        else parts.push(`${f}${op}${v}`);
      }
      if (words.value.trim()) parts.push(words.value.trim());
      return parts.join(' ');
    };
    return h('div', { class: 'adv' },
      h('h2', null, `Advanced search · ${tab === 'tv' ? 'TV Shows' : 'Movies'}`),
      h('p', null, h('small', null, 'Every row must match. For text, separate alternatives with | (Action|Comedy). Numbers take a value or a range. In the search box, separate several filters with ; (4k; genre:action; 90s).')),
      list, dl,
      h('p', null, h('button', { class: 'btn', type: 'button', onclick: () => addRow() }, '+ Add a filter')),
      h('label', { class: 'adv-label' }, 'Words', words),
      h('p', { class: 'adv-actions' },
        h('button', { class: 'btn', type: 'button', onclick: () => { apply(''); close(); } }, 'Clear search'),
        h('button', { class: 'btn primary', type: 'button', onclick: () => { apply(build()); close(); } }, 'Search')));
  }, 'adv-host');
}
