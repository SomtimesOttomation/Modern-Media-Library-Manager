// Your own dashboards: charts over any field, per tab, saved in dashboards.json. Each chart groups the titles the tab
// shows (the search box and collections narrow it) by one field and measures them: how many, total, average, highest.
// Click a slice or bar to add it to the search.
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { h } from '../util.js';
import { esc, num, fmtInt, fmtSize, fmtRun, fmtMoney } from '../common.js';
import { overlay } from './settings.js';
import { colLabel } from './library.js';
import { donut, bars, cols } from './stats.js';
import { openCard } from './card.js';

export const TYPES = [['bar', 'Bars'], ['column', 'Columns'], ['donut', 'Donut'], ['number', 'Big number'], ['list', 'Top titles']];
const OPS = [['count', 'How many'], ['sum', 'Total of'], ['avg', 'Average of'], ['max', 'Highest'], ['min', 'Lowest']];
// fields whose values are lists ("Drama; Comedy"): each part counts on its own
const LISTS = new Set(['Genre', 'Cast', 'Director', 'Studio', 'Country', 'AudioLanguages', 'SubtitleLanguages', 'SubtitleFormats', 'Writer', 'Collection']);
const SKIP = new Set(['Poster', 'Rid', 'PlexKey', 'PlexThumb', 'MetaSources', 'Plot', 'Tagline', 'FileName']);

// Ready-made charts: a quick way in, and a hint of what is possible.
export const SUGGESTED = {
  movies: [
    { title: 'Genres', type: 'bar', field: 'Genre', op: 'count', top: 12 },
    { title: 'Size by resolution', type: 'donut', field: 'ResolutionClass', op: 'sum', of: 'FileSizeGB' },
    { title: 'Titles by decade', type: 'column', field: 'Year', op: 'count' },
    { title: 'Average IMDb rating by genre', type: 'bar', field: 'Genre', op: 'avg', of: 'Rating', top: 12 },
    { title: 'Top studios', type: 'bar', field: 'Studio', op: 'count', top: 15 },
    { title: 'Most-cast actors', type: 'bar', field: 'Cast', op: 'count', top: 15 },
    { title: 'Audio formats', type: 'donut', field: 'AudioFormat', op: 'count' },
    { title: 'Highest box office', type: 'list', field: 'BoxOfficeWorldwide', op: 'max', top: 10 },
    { title: 'Best Metacritic', type: 'list', field: 'Metascore', op: 'max', top: 10 },
    { title: 'Average video bitrate', type: 'number', field: '', op: 'avg', of: 'VideoBitRateMbps' },
    { title: 'Added per year', type: 'column', field: 'Added', op: 'count' },
    { title: 'Unwatched', type: 'number', field: '', op: 'count', filter: 'unwatched' },
  ],
  tv: [
    { title: 'Episodes per show', type: 'bar', field: 'Show', op: 'count', top: 15 },
    { title: 'Size per show', type: 'bar', field: 'Show', op: 'sum', of: 'FileSizeGB', top: 15 },
    { title: 'Genres', type: 'donut', field: 'Genre', op: 'count' },
    { title: 'Resolution', type: 'donut', field: 'ResolutionClass', op: 'count' },
    { title: 'Episodes by decade', type: 'column', field: 'Year', op: 'count' },
    { title: 'Unwatched episodes per show', type: 'bar', field: 'Show', op: 'count', top: 15, filter: 'unwatched' },
    { title: 'Total runtime', type: 'number', field: '', op: 'sum', of: 'RuntimeMin' },
    { title: 'Codecs', type: 'donut', field: 'VideoCodec', op: 'count' },
  ],
};

// ---- data ------------------------------------------------------------------------------------------------------
let saved = null;          // { movies: [dashboards], tv: [...] }
export async function loadDashboards() {
  if (saved) return saved;
  try { saved = await bridge.request('dashboards.get'); } catch { saved = null; }
  saved = { movies: (saved && saved.movies) || [], tv: (saved && saved.tv) || [] };
  return saved;
}
export async function saveDashboards() {
  try { await bridge.request('dashboards.save', { data: saved }); } catch (e) { S.toast?.(`Could not save the dashboards: ${e.message}`); }
}
export const dashboards = (tab) => (saved ? saved[tab] : []);
const uid = () => Math.random().toString(36).slice(2, 9);

const isNum = (L, f) => { const d = L.byName.get(f); return d && (d.t === 'int' || d.t === 'double' || d.t === 'long'); };
const fmtFor = (field, op) => {
  if (op === 'count') return (n) => fmtInt(n);
  if (field === 'FileSizeGB') return (n) => fmtSize(n);
  if (field === 'RuntimeMin') return (n) => (op === 'sum' ? fmtRun(n) : `${Math.round(n)} min`);
  if (/^BoxOffice|^Opening/.test(field)) return (n) => fmtMoney(n) || '$0';
  if (field === 'RTCritic' || field === 'RTAudience') return (n) => `${Math.round(n)}%`;
  return (n) => (Math.abs(n) >= 100 || Number.isInteger(n) ? fmtInt(n) : (Math.round(n * 10) / 10).toLocaleString());
};
// nice bins for a number field (about 10), Year as decades when it spans more than 30 years
function numKey(L, field, rows) {
  const vals = rows.map((r) => num(r[field])).filter((x) => x > 0).sort((a, b) => a - b);
  if (!vals.length) return () => null;
  const lo = vals[0], hi = vals[vals.length - 1];
  if (field === 'Year') return hi - lo > 30 ? (r) => (r.Year > 0 ? `${Math.floor(r.Year / 10) * 10}s` : null) : (r) => (r.Year > 0 ? String(r.Year) : null);
  const d = L.byName.get(field);
  if (d && d.t === 'int' && hi - lo <= 12) return (r) => (num(r[field]) > 0 ? String(num(r[field])) : null);
  const raw = (hi - lo) / 10 || 1, p = 10 ** Math.floor(Math.log10(raw)), step = [1, 2, 2.5, 5, 10].map((m) => m * p).find((x) => x >= raw);
  const f = fmtFor(field, 'max');
  return (r) => { const x = num(r[field]); if (!(x > 0)) return null; const a = Math.floor(x / step) * step; return `${f(a)}–${f(a + step)}`; };
}
function keyFn(L, field, rows) {
  if (field === 'Added' || field === 'ReleaseDate' || field === 'LastViewed') return (r) => (r[field] ? String(r[field]).slice(0, 4) : null);
  if (isNum(L, field)) return numKey(L, field, rows);
  const d = L.byName.get(field);
  if (d && d.t === 'bool') return (r) => (r[field] ? 'Yes' : 'No');
  if (LISTS.has(field)) return (r) => String(r[field] ?? '').split(/\s*[;,]\s*/).filter(Boolean);
  return (r) => (r[field] === undefined || r[field] === null || r[field] === '' ? null : String(r[field]));
}
function aggregate(rows, w, L) {
  const of = w.of, op = w.op || 'count';
  const val = (list) => {
    if (op === 'count') return list.length;
    const xs = list.map((r) => num(r[of])).filter((x) => x > 0 || op === 'sum');
    if (!xs.length) return 0;
    if (op === 'sum') return xs.reduce((a, b) => a + b, 0);
    if (op === 'avg') return xs.reduce((a, b) => a + b, 0) / xs.length;
    return op === 'max' ? Math.max(...xs) : Math.min(...xs);
  };
  if (!w.field) return [['', val(rows)]];
  const kf = keyFn(L, w.field, rows), groups = new Map();
  for (const r of rows) {
    let k = kf(r); if (k === null || k === undefined) continue;
    for (const one of Array.isArray(k) ? k : [k]) { if (!groups.has(one)) groups.set(one, []); groups.get(one).push(r); }
  }
  return [...groups.entries()].map(([k, list]) => [k, val(list)]);
}

function widgetBody(w, rows, L) {
  const fmt = fmtFor(w.of || w.field, w.op);
  const cfg = { id: w.id, fmt, measure: w.op };
  // the donut's centre: a total only makes sense for counts and sums
  if (w.op === 'count') cfg.sub = S.state.libs.tv.rows === L.rows ? 'episodes' : 'titles';
  else if (w.op === 'sum') cfg.sub = 'total';
  else { cfg.sub = 'groups'; }
  if (w.type === 'number') {
    const v = aggregate(rows, { ...w, field: '' }, L)[0][1];
    return `<div class="bignum">${esc(fmt(v))}</div><div class="bignum-sub">${esc(describe(w, L))}</div>`;
  }
  if (w.type === 'list') {
    const f = w.of || w.field, list = rows.filter((r) => num(r[f]) > 0).sort((a, b) => (w.op === 'min' ? num(a[f]) - num(b[f]) : num(b[f]) - num(a[f]))).slice(0, w.top || 10);
    const ff = fmtFor(f, 'max');
    return list.length ? `<ul class="rank">${list.map((r) => `<li data-open="${r._i}"><span>${esc(r.Show ? r.Show + ' · ' : '')}${esc(r.Title)}${r.Year > 0 ? ' (' + r.Year + ')' : ''}</span><b>${esc(ff(num(r[f])))}</b></li>`).join('')}</ul>` : '<div class="empty-s">No data for this field yet</div>';
  }
  let e = aggregate(rows, w, L).filter((x) => x[1] > 0);
  const ordered = w.type === 'column' && (isNum(L, w.field) || /^(Added|ReleaseDate|LastViewed)$/.test(w.field));
  e.sort(ordered ? (a, b) => String(a[0]).localeCompare(String(b[0]), undefined, { numeric: true }) : (a, b) => b[1] - a[1]);
  const top = w.top || (w.type === 'donut' ? 8 : w.type === 'column' ? 24 : 12);
  if (!ordered && e.length > top) {
    const rest = e.slice(top);
    e = e.slice(0, top);
    if (w.type === 'donut' && (w.op === 'count' || w.op === 'sum')) e.push(['Other', rest.reduce((a, x) => a + x[1], 0)]);
  }
  if (!e.length) return '<div class="empty-s">No data for this field yet</div>';
  if (w.type === 'donut' && cfg.sub === 'groups') cfg.center = String(e.length);
  return w.type === 'donut' ? donut(cfg, e) : w.type === 'column' ? cols(cfg, e) : bars({ ...cfg, wide: true }, e);
}
function describe(w, L) {
  const op = OPS.find((o) => o[0] === w.op)?.[1] || 'How many';
  return `${op}${w.op !== 'count' && w.of ? ' ' + colLabel(w.of).toLowerCase() : ''}${w.field && w.type !== 'number' && w.type !== 'list' ? ' by ' + colLabel(w.field).toLowerCase() : ''}${w.filter ? ` · ${w.filter}` : ''}`;
}

// ---- page -----------------------------------------------------------------------------------------------------
export function renderDashboard(el, tab, dash, rows, L, redraw, filterRows) {
  const html = dash.widgets.map((w, i) => {
    const wr = w.filter ? filterRows(rows, w.filter) : rows;
    return `<div class="st-card mydash${w.wide ? ' span2' : ''}" data-w="${w.id}"><h3><span>${esc(w.title || describe(w, L))}</span>
      <span class="wtools"><button type="button" data-act="edit" title="Edit">✎</button><button type="button" data-act="left" title="Move earlier" ${i === 0 ? 'disabled' : ''}>←</button><button type="button" data-act="right" title="Move later" ${i === dash.widgets.length - 1 ? 'disabled' : ''}>→</button><button type="button" data-act="wide" title="${w.wide ? 'Narrow' : 'Wide'}">↔</button><button type="button" data-act="del" title="Remove">✕</button></span></h3>
      ${widgetBody(w, wr, L)}</div>`;
  }).join('');
  el.innerHTML = `<div class="st-grid">${html}<button class="st-card addw" type="button" data-act="add"><b>+ Add a chart</b><small>Any field: bars, columns, donut, a big number or top titles</small></button></div>`;
  el.onclick = (e) => {
    const t = e.target.closest('[data-act],[data-key],[data-open]');
    if (!t) return;
    if (t.dataset.open !== undefined) { openCard(L.rows[+t.dataset.open], S.toast); return; }
    const card = t.closest('[data-w]'), w = card && dash.widgets.find((x) => x.id === card.dataset.w);
    if (t.dataset.key !== undefined && w) {
      // a slice or bar: add it to the search
      const k = t.dataset.key;
      if (!w.field || k === 'Other') return;
      let term;
      if (/^\d{4}s$/.test(k) && w.field === 'Year') term = `Year:${k.slice(0, 4)}-${+k.slice(0, 4) + 9}`;
      else if (/^\d+(\.\d+)?$/.test(k) && isNum(L, w.field)) term = `${w.field}:${k}`;
      else if (/^(Added|ReleaseDate)$/.test(w.field)) term = `${w.field}:${k}`;
      else if (isNum(L, w.field)) return;
      else term = `${w.field}:"${k}"`;
      S.setQuery(`${S.state.query} ${term}`.trim());
      return;
    }
    const act = t.dataset.act, i = w ? dash.widgets.indexOf(w) : -1;
    if (act === 'add') { editWidget(tab, L, null, (nw) => { dash.widgets.push(nw); saveDashboards(); redraw(); }); return; }
    if (!w) return;
    if (act === 'edit') editWidget(tab, L, w, (nw) => { dash.widgets[i] = nw; saveDashboards(); redraw(); });
    else if (act === 'del') { dash.widgets.splice(i, 1); saveDashboards(); redraw(); }
    else if (act === 'left' && i > 0) { [dash.widgets[i - 1], dash.widgets[i]] = [dash.widgets[i], dash.widgets[i - 1]]; saveDashboards(); redraw(); }
    else if (act === 'right' && i < dash.widgets.length - 1) { [dash.widgets[i + 1], dash.widgets[i]] = [dash.widgets[i], dash.widgets[i + 1]]; saveDashboards(); redraw(); }
    else if (act === 'wide') { w.wide = !w.wide; saveDashboards(); redraw(); }
  };
}

// The chart editor: every field, grouped as the data is, with a live preview.
export function editWidget(tab, L, w, done) {
  const cur = { id: uid(), type: 'bar', field: 'Genre', op: 'count', of: '', top: 0, filter: '', title: '', ...(w || {}) };
  overlay((close) => {
    const fields = L.fields.filter((f) => !SKIP.has(f.n));
    const numFields = fields.filter((f) => f.t === 'int' || f.t === 'double' || f.t === 'long');
    const groups = [...new Set(fields.map((f) => f.g))];
    const preview = h('div', { class: 'st-card wprev' });
    const type = h('div', { class: 'seg', role: 'tablist' });
    const field = h('select', { 'aria-label': 'Group by' }, h('option', { value: '' }, '(nothing: one number)'),
      ...groups.map((g) => h('optgroup', { label: g }, fields.filter((f) => f.g === g).map((f) => h('option', { value: f.n }, colLabel(f.n))))));
    const find = h('input', { type: 'search', placeholder: 'Find a field...', class: 'wfind' });
    const op = h('select', { 'aria-label': 'Measure' }, OPS.map(([k, label]) => h('option', { value: k }, label)));
    const of = h('select', { 'aria-label': 'Of' }, numFields.map((f) => h('option', { value: f.n }, colLabel(f.n))));
    const top = h('input', { type: 'number', min: '0', max: '100', placeholder: 'auto', 'aria-label': 'How many to show' });
    const filter = h('input', { type: 'text', placeholder: 'Only titles matching, e.g. 4k, genre:horror, unwatched' });
    const title = h('input', { type: 'text', placeholder: 'Title (optional)' });
    field.value = cur.field; op.value = cur.op; of.value = cur.of || 'FileSizeGB'; top.value = cur.top || ''; filter.value = cur.filter || ''; title.value = cur.title || '';
    const sync = () => {
      cur.field = field.value; cur.op = op.value; cur.of = op.value === 'count' ? '' : of.value; cur.top = +top.value || 0; cur.filter = filter.value.trim(); cur.title = title.value.trim();
      if (cur.type === 'number') cur.field = '';
      type.replaceChildren(...TYPES.map(([k, label]) => h('button', { type: 'button', class: cur.type === k ? 'active' : '', onclick: () => { cur.type = k; if (k === 'list' && cur.op === 'count') { op.value = 'max'; } sync(); } }, label)));
      of.disabled = op.value === 'count'; field.disabled = cur.type === 'number';
      const rows = cur.filter ? S.filterByQuery(L, cur.filter) : L.rows;
      preview.innerHTML = `<h3>${esc(cur.title || describe(cur, L))}</h3>${widgetBody(cur, rows, L)}`;
    };
    [field, op, of, top, filter, title].forEach((x) => { x.oninput = sync; x.onchange = sync; });
    find.oninput = () => {
      const q = find.value.toLowerCase();
      for (const o of field.querySelectorAll('option')) o.hidden = !!q && !colLabel(o.value).toLowerCase().includes(q) && !o.value.toLowerCase().includes(q) && o.value !== '';
      const first = [...field.querySelectorAll('option')].find((o) => !o.hidden && o.value);
      if (first && q) { field.value = first.value; sync(); }
    };
    const sugg = h('div', { class: 'wsugg' }, ...SUGGESTED[tab].map((s) => h('button', { class: 'btn', type: 'button', onclick: () => { Object.assign(cur, { top: 0, of: '', filter: '', ...s }); field.value = cur.field; op.value = cur.op; of.value = cur.of || 'FileSizeGB'; top.value = cur.top || ''; filter.value = cur.filter || ''; title.value = cur.title; sync(); } }, s.title)));
    sync();
    return h('div', { class: 'adv wedit' }, h('h2', null, w ? 'Edit chart' : 'Add a chart'),
      h('p', null, h('small', null, 'Start from a suggestion or build your own.')), sugg,
      h('div', { class: 'wgrid' },
        h('div', { class: 'wform' },
          h('label', null, 'Chart', type),
          h('label', null, 'Group by', find, field),
          h('label', null, 'Measure', h('div', { class: 'wrow' }, op, of)),
          h('label', null, 'Show at most', top),
          h('label', null, 'Only titles matching', filter),
          h('label', null, 'Title', title)),
        preview),
      h('p', { class: 'adv-actions' }, h('button', { class: 'btn', type: 'button', onclick: close }, 'Cancel'),
        h('button', { class: 'btn primary', type: 'button', onclick: () => { sync(); close(); done({ ...cur }); } }, w ? 'Save' : 'Add')));
  }, 'adv-host wide');
}

export function newDashboard(tab, name, starter) {
  const d = { id: uid(), name: name || 'My dashboard', widgets: starter ? SUGGESTED[tab].slice(0, 6).map((s) => ({ id: uid(), top: 0, of: '', filter: '', ...s })) : [] };
  saved[tab].push(d);
  saveDashboards();
  return d;
}
