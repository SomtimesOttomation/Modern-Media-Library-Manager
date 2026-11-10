// TV Shows: a poster wall with one tile per show (default), or the grid: Show > Season > Episode, collapsed, with an
// expand / collapse-all column to the right of Title. Click a show for its seasons and episodes, an episode for its card.
import * as S from '../store.js';
import { h } from '../util.js';
import { esc, num, fmtSize, posterHtml, tileHtml, searchRows, chipsHtml, fillWall, sortMenu } from '../common.js';
import * as dashboard from './stats.js';
import { collectionMenu, cmControls, CM, cmToggle } from './collections.js';
import { toolsMenu, viewRids } from './tools.js';
import * as series from './series.js';
import { openCard, openShow, showSummary } from './card.js';
import { vgrid } from './vgrid.js';
import { stateBox, gridColumns, cellHtml, colLabel, chooseColumns, viewSeg, viewMode } from './library.js';

const byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' });
const firstGenre = (s) => (s.eps[0]._genres[0] || '￿').toLowerCase();
export const TV_SORTS = [
  ['title', 'Title', byName],
  ['aired', 'First aired', (a, b) => (a.sum.firstAired === b.sum.firstAired ? byName(a, b) : !a.sum.firstAired ? 1 : !b.sum.firstAired ? -1 : b.sum.firstAired.localeCompare(a.sum.firstAired))],
  ['added', 'Date added', (a, b) => b.sum.added.localeCompare(a.sum.added) || byName(a, b)],
  ['genre', 'Genre', (a, b) => firstGenre(a).localeCompare(firstGenre(b)) || byName(a, b)],
  ['seasons', 'Seasons', (a, b) => b.nSeasons - a.nSeasons || byName(a, b)],
];

// Shows built once per loaded library (not on every redraw).
let cache = { rows: null, shows: [] };
function shows(L) {
  if (cache.rows === L.rows) return cache.shows;
  const m = new Map();
  for (const r of L.rows) { const k = r.Show || r.Title; if (!m.has(k)) m.set(k, []); m.get(k).push(r); }
  const list = [...m.entries()].map(([name, eps]) => {
    const sum = showSummary(eps);
    return { name, eps, sum, nSeasons: sum.seasons.filter((x) => x[0] > 0).length || sum.seasons.length, poster: eps.find((e) => e.Poster) || eps[0] };
  });
  cache = { rows: L.rows, shows: list };
  return list;
}

export function mount(ctx) {
  if (ctx.arg) { ctx.series = true; return series.mount(ctx); }        // #/tv/<show>: the series view
  const L = S.state.libs.tv;
  let grid = null, stopWall = null, stopDash = null;
  const open = new Set();                 // expanded shows ('s:name') and seasons ('s:name|n')
  const pick = (sh, el) => {
    const on = cmToggle('tv', sh.name, S.itemFor(sh.eps[0], sh.eps));
    const b = el.querySelector('[data-cm]'); if (b) { b.classList.toggle('on', on); b.textContent = on ? '\u2713' : '+'; }
    el.classList.toggle('picked', on);
    const d = ctx.el.querySelector('.cm-done'); if (d) d.textContent = `Done${CM.tv.picked.size ? ` (${CM.tv.picked.size})` : ''}`;
  };
  const draw = () => {
    stopWall?.(); stopWall = null; grid?.destroy(); grid = null; stopDash?.(); stopDash = null;
    const st = stateBox('tv', L, ctx.toast);
    if (st) { ctx.el.replaceChildren(st); return; }
    const s = S.state.settings, mode = viewMode(s.tvView, 'tv');
    if (mode === 'dashboard') {
      const body = h('div');
      ctx.el.replaceChildren(h('div', { class: 'lib-head' }, h('div', { class: 'lib-title' }, h('h1', null, 'TV Shows'), h('small', null, 'Dashboard (episodes)')),
        h('div', { class: 'lib-tools' }, viewSeg(mode, 'tvView', draw))), body);
      stopDash = dashboard.mount({ el: body, arg: 'tv', toast: ctx.toast, embedded: true });
      return;
    }
    const all = shows(L);
    const q = S.state.query;
    let list = all;
    let epFilter = null, chipList = [];
    if (q) { const f = searchRows(L.rows, q, L, S.state.collections); chipList = f.chips; const hit = new Set(f.rows); epFilter = hit; list = all.filter((sh) => sh.eps.some((e) => hit.has(e))); }
    viewRids.tv = epFilter ? [...epFilter] : null;
    const sortDef = TV_SORTS.find((x) => x[0] === s.tvSort) || TV_SORTS[0];
    list = list.slice().sort(sortDef[2]);
    if (s.tvSortRev) list.reverse();
    const head = h('div', { class: 'lib-head' },
      h('div', { class: 'lib-title' }, h('h1', null, 'TV Shows'),
        h('small', null, `${list.length.toLocaleString()}${list.length !== all.length ? ' of ' + all.length.toLocaleString() : ''} shows · ${L.rows.length.toLocaleString()} episodes · ${fmtSize(L.rows.reduce((a, r) => a + num(r.FileSizeGB), 0))}`)),
      h('div', { class: 'lib-tools' },
        cmControls('tv', draw),
        collectionMenu('tv'),
        toolsMenu('tv'),
        sortMenu(TV_SORTS, sortDef[0], !!s.tvSortRev, (k, rev) => S.saveSettings({ tvSort: k, tvSortRev: rev }).then(draw)),
        mode === 'grid' ? h('button', { class: 'btn', type: 'button', onclick: () => chooseColumns(L, draw) }, 'Columns') : null,
        viewSeg(mode, 'tvView', draw)));
    const body = h('div');
    const chips = h('div'); chips.innerHTML = chipsHtml(chipList);
    ctx.el.replaceChildren(head, chips, body);
    if (!list.length) { body.append(h('div', { class: 'state' }, h('p', null, q ? `Nothing matches “${q}”.` : 'Nothing to show.'))); return; }
    const byKey = new Map(list.map((sh) => [sh.name, sh]));
    if (mode === 'posters') {
      const wall = h('div', { class: 'wall' });
      body.append(wall);
      const years = (sh) => (!sh.sum.y0 ? '' : sh.sum.y0 === sh.sum.y1 ? String(sh.sum.y0) : `${sh.sum.y0}–${sh.sum.y1}`);
      stopWall = fillWall(wall, list, (sh) => tileHtml({ key: sh.name, poster: posterHtml(sh.poster, sh.name), title: sh.name,
        sub: [years(sh), `${sh.nSeasons} season${sh.nSeasons === 1 ? '' : 's'}`, `${sh.eps.length} ep.`].filter(Boolean).join(' · '), res: '', hdr: '', rating: 0, cm: CM.tv.on ? CM.tv.picked.has(sh.name) : undefined }));
      wall.addEventListener('click', (e) => {
        const t = e.target.closest('.pc'); if (!t) return;
        if (e.target.closest('[data-cm]')) { const sh = byKey.get(t.dataset.k); if (sh) pick(sh, t); return; }
        location.hash = `#/tv/${encodeURIComponent(t.dataset.k)}`;
      });
      return;
    }
    // grid: flatten the open parts of the tree
    const cols = gridColumns(L);
    const flat = () => {
      const out = [];
      for (const sh of list) {
        out.push({ k: 'show', sh });
        if (!open.has('s:' + sh.name)) continue;
        for (const [n, eps] of sh.sum.seasons) {
          const vis = epFilter ? eps.filter((e) => epFilter.has(e)) : eps;
          if (!vis.length) continue;
          out.push({ k: 'season', sh, n, eps: vis });
          if (open.has(`s:${sh.name}|${n}`)) for (const e of vis) out.push({ k: 'ep', sh, e });
        }
      }
      return out;
    };
    const anyOpen = () => open.size > 0;
    const xHead = () => `<th><button class="xall" type="button" data-x="all" title="${anyOpen() ? 'Collapse every show' : 'Expand every show and season'}">${anyOpen() ? 'Collapse all' : 'Expand all'}</button></th>`;
    const agg = (eps, c) => {
      // show and season rows: totals where they make sense, the common value otherwise
      if (c === 'FileSizeGB') return `<td class="num">${fmtSize(eps.reduce((a, e) => a + num(e.FileSizeGB), 0))}</td>`;
      if (c === 'RuntimeMin') { const m = eps.reduce((a, e) => a + num(e.RuntimeMin), 0); return `<td class="num">${Math.floor(m / 60)}h ${String(Math.round(m % 60)).padStart(2, '0')}m</td>`; }
      const vals = new Set(eps.map((e) => e[c]).filter((x) => x !== undefined && x !== '' && x !== null));
      return vals.size === 1 ? cellHtml(eps[0], c, L) : vals.size > 1 ? '<td class="muted">mixed</td>' : '<td></td>';
    };
    grid = vgrid(body, {
      // no sorting by column here: the tree keeps the Sort By order
      head: () => ({ html: `<tr>${CM.tv.on ? '<th class="cm-col">+</th>' : ''}<th>Title</th>${xHead()}${cols.map((c) => `<th>${esc(colLabel(c))}</th>`).join('')}</tr>`, count: cols.length + 2 + (CM.tv.on ? 1 : 0) }),
      rowHtml: (it, i) => {
        if (it.k === 'show') {
          const o = open.has('s:' + it.sh.name);
          const cmc = CM.tv.on ? `<td class="cm-col"><span class="cm-add${CM.tv.picked.has(it.sh.name) ? ' on' : ''}" role="button" data-cm="1">${CM.tv.picked.has(it.sh.name) ? '\u2713' : '+'}</span></td>` : '';
          return `<tr class="show" data-i="${i}">${cmc}<td class="ttl" title="${esc(it.sh.name)}"><span class="tw">${o ? '▾' : '▸'}</span>${esc(it.sh.name)}</td><td class="muted">${it.sh.nSeasons} season${it.sh.nSeasons === 1 ? '' : 's'} · ${it.sh.eps.length} ep.</td>${cols.map((c) => agg(it.sh.eps, c)).join('')}</tr>`;
        }
        if (it.k === 'season') {
          const o = open.has(`s:${it.sh.name}|${it.n}`);
          return `<tr class="season" data-i="${i}">${CM.tv.on ? '<td class="cm-col"></td>' : ''}<td class="ttl"><span class="tw">${o ? '▾' : '▸'}</span>${it.n === 0 ? 'Specials' : 'Season ' + it.n}</td><td class="muted">${it.eps.length} episode${it.eps.length === 1 ? '' : 's'}</td>${cols.map((c) => agg(it.eps, c)).join('')}</tr>`;
        }
        const e = it.e, t = String(e.Title).replace(/^.* - S\d+E\d+ - /, '');
        return `<tr class="ep" data-i="${i}">${CM.tv.on ? '<td class="cm-col"></td>' : ''}<td class="ttl" title="${esc(t)}">E${String(num(e.Episode)).padStart(2, '0')} · ${esc(t)}</td><td></td>${cols.map((c) => cellHtml(e, c, L)).join('')}</tr>`;
      },
      onRow: (it, e) => {
        if (e && e.target.closest('[data-open]')) return;
        if (e && e.target.closest('[data-cm]') && it.k === 'show') { pick(it.sh, e.target.closest('tr')); return; }
        if (it.k === 'ep') { openCard(it.e, ctx.toast); return; }
        const key = it.k === 'show' ? 's:' + it.sh.name : `s:${it.sh.name}|${it.n}`;
        if (open.has(key)) { open.delete(key); if (it.k === 'show') for (const k of [...open]) if (k.startsWith(key + '|')) open.delete(k); } else open.add(key);
        grid.set(flat());
      },
      onHead: (c, e) => {
        if (!e.target.closest('[data-x]')) return;
        if (anyOpen()) open.clear(); else for (const sh of list) { open.add('s:' + sh.name); for (const [n] of sh.sum.seasons) open.add(`s:${sh.name}|${n}`); }
        grid.set(flat());
      },
    });
    grid.set(flat());
  };
  draw();
  ctx.redraw = draw;
  ctx.seen = { status: L.status, rows: L.rows };
  return () => { stopWall?.(); grid?.destroy(); stopDash?.(); };
}
export function update(topics, ctx) {
  if (ctx.series) { if (topics.has('library') || topics.has('traffic')) ctx.redraw?.(); return; }
  const L = S.state.libs.tv, changed = ctx.seen && (ctx.seen.status !== L.status || ctx.seen.rows !== L.rows);
  if (changed) ctx.seen = { status: L.status, rows: L.rows };
  if (changed || topics.has('query') || topics.has('collections') || (L.status !== 'ready' && (topics.has('plex') || topics.has('traffic') || topics.has('scan')))) ctx.redraw?.();
}
