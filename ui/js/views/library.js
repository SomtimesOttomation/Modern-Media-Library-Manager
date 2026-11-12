// Movies: the poster wall (default) or the grid, with Sort By, Hide duplicates and the search box in the bar.
// Click a poster or a row for its card.
import * as S from '../store.js';
import { h } from '../util.js';
import { esc, num, fmtSize, hdrLabel, posterHtml, tileHtml, searchRows, chipsHtml, dedupe, fillWall, sortMenu } from '../common.js';
import * as dashboard from './stats.js';
import { collectionMenu, cmControls, CM, cmToggle } from './collections.js';
import { toolsMenu, viewRids } from './tools.js';
import { openCard } from './card.js';
import { overlay } from './settings.js';
import { vgrid } from './vgrid.js';
import * as compare from './compare.js';

// Sort By (Movies). Rating = RT critics, as the window app does.
const str = (x) => String(x || '');
const byTitle = (a, b) => a.Title.localeCompare(b.Title, undefined, { numeric: true, sensitivity: 'base' });
const desc = (f) => (a, b) => num(b[f]) - num(a[f]) || byTitle(a, b);
export const MOVIE_SORTS = [
  ['added', 'Date added', (a, b) => str(b.Added).localeCompare(str(a.Added)) || byTitle(a, b)],
  ['release', 'Release date', (a, b) => str(b.ReleaseDate || b.Year).localeCompare(str(a.ReleaseDate || a.Year)) || byTitle(a, b)],
  ['title', 'Title', byTitle],
  ['rating', 'Rating (RT critics)', desc('RTCritic')],
  ['metascore', 'Metacritic', desc('Metascore')],
  ['boxdom', 'Box office, domestic', desc('BoxOfficeDomestic')],
  ['boxww', 'Box office, worldwide', desc('BoxOfficeWorldwide')],
  ['boxdomadj', 'Box office, domestic (inflation-adjusted)', desc('BoxOfficeDomesticAdj')],
  ['boxwwadj', 'Box office, worldwide (inflation-adjusted)', desc('BoxOfficeWorldwideAdj')],
  ['runtime', 'Runtime', desc('RuntimeMin')],
];

// ---- grid columns (shared with the TV grid) ----------------------------------------------------------------
const LABELS = { MPAARating: 'Rated', RuntimeMin: 'Runtime', ResolutionClass: 'Res', VideoBitRateMbps: 'Video Mbps', FileSizeGB: 'Size', HDRType: 'HDR', DVProfile: 'DV', DVLayer: 'DV layer',
  AudioFormat: 'Audio', ObjectAudio: 'Immersive', AudioLayout: 'Channels', AudioLanguages: 'Audio lang.', SubtitleTracks: 'Subs', RTCritic: 'RT critics', RTAudience: 'RT audience',
  Metascore: 'Metacritic', BoxOfficeDomestic: 'Box office (dom.)', BoxOfficeWorldwide: 'Box office (ww)', BoxOfficeDomesticAdj: 'Box office (dom., adj.)', BoxOfficeWorldwideAdj: 'Box office (ww, adj.)', OpeningDomesticAdj: 'Opening (adj.)', FileName: 'File name', BitDepth: 'Bit depth', FrameRate: 'FPS' };
export const colLabel = (n) => LABELS[n] || n.replace(/([a-z])([A-Z])/g, '$1 $2');
const NEVER = new Set(['Title', 'Poster', 'Library', 'PlexKey', 'PlexThumb', 'MetaSources', 'Show', 'Season', 'Episode']);
export function gridColumns(L) {
  const chosen = (S.state.settings.columns || []).filter((n) => L.byName.has(n) && !NEVER.has(n));
  if (chosen.length) return chosen;
  return L.fields.filter((f) => f.s && !NEVER.has(f.n)).map((f) => f.n);
}
export function cellHtml(r, n, L) {
  const f = L.byName.get(n), x = r[n];
  if (x === undefined || x === '' || x === null) return '<td></td>';
  const isNum = f && (f.t === 'int' || f.t === 'double');
  let t = x;
  if (n === 'FileSizeGB') t = fmtSize(x);
  else if (n === 'RuntimeMin') t = `${Math.floor(num(x) / 60)}h ${String(Math.round(num(x) % 60)).padStart(2, '0')}m`;
  else if (/^BoxOffice|^Opening/.test(n)) t = num(x) > 0 ? '$' + Math.round(num(x)).toLocaleString() : '';
  else if (n === 'RTCritic' || n === 'RTAudience') t = num(x) > 0 ? Math.round(num(x)) + '%' : '';
  else if (f && f.t === 'bool') t = x ? 'Yes' : '';
  else if (f && f.t === 'double') t = num(x) === 0 ? '' : String(Math.round(num(x) * 100) / 100);
  else if (isNum && num(x) === 0) t = '';
  return `<td class="${isNum ? 'num' : ''}" title="${esc(t)}">${esc(t)}</td>`;
}
export function headHtml(cols, sort, extraAfterTitle = '') {
  const arr = (c) => (sort.col === c ? `<span class="arr">${sort.dir > 0 ? '▲' : '▼'}</span>` : '');
  return { html: `<tr><th data-c="Title">Title${arr('Title')}</th>${extraAfterTitle}${cols.map((c) => `<th data-c="${c}">${esc(colLabel(c))}${arr(c)}</th>`).join('')}</tr>`, count: cols.length + 1 + (extraAfterTitle ? 1 : 0) };
}
export function sortByColumn(list, col, dir, L) {
  const f = L.byName.get(col), isNum = f && (f.t === 'int' || f.t === 'double' || f.t === 'bool');
  return list.sort((a, b) => {
    const x = a[col], y = b[col];
    if (isNum) return (num(x) - num(y)) * dir || byTitle(a, b);
    return String(x ?? '').localeCompare(String(y ?? ''), undefined, { numeric: true, sensitivity: 'base' }) * dir || byTitle(a, b);
  });
}
// Column chooser: grouped as in the window app.
export function chooseColumns(L, onDone) {
  overlay((close) => {
    const chosen = new Set(gridColumns(L));
    const groups = new Map();
    for (const f of L.fields) { if (NEVER.has(f.n)) continue; if (!groups.has(f.g)) groups.set(f.g, []); groups.get(f.g).push(f); }
    const list = h('div', { class: 'colpick' });
    for (const [g, fs] of groups) {
      list.append(h('h4', null, g));
      for (const f of fs) list.append(h('label', null, h('input', { type: 'checkbox', checked: chosen.has(f.n) ? true : null, onchange: (e) => { if (e.target.checked) chosen.add(f.n); else chosen.delete(f.n); } }), colLabel(f.n)));
    }
    const apply = (cols) => { S.saveSettings({ columns: cols }); close(); onDone(); };
    return h('div', null, h('h2', null, 'Grid columns'), h('p', null, h('small', null, 'File locations are never shown.')), list,
      h('p', { style: { display: 'flex', gap: '8px', justifyContent: 'flex-end' } },
        h('button', { class: 'btn', type: 'button', onclick: () => apply([]) }, 'Defaults'),
        h('button', { class: 'btn primary', type: 'button', onclick: () => apply(L.fields.filter((f) => chosen.has(f.n)).map((f) => f.n)) }, 'Apply')));
  });
}

// Loading, empty and error states, shared with the TV view.
export function stateBox(tab, L, toast) {
  const name = tab === 'tv' ? 'TV Shows' : 'Movies';
  const scan = () => S.startScan(tab).catch((e) => toast(e.message));
  if (L.status === 'loading' || L.status === 'idle') return h('div', { class: 'state' }, h('h2', null, `Opening ${name}...`));
  if (L.status === 'pending') return h('div', { class: 'state' }, h('h2', null, `Opening ${name}...`), h('p', null, 'Preparing the library from the last scan. This takes a moment the first time.'));
  if (L.status === 'error') return h('div', { class: 'state' }, h('h2', null, `${name} could not be opened`), h('p', null, L.error), h('button', { class: 'btn primary', type: 'button', onclick: () => S.loadLibrary(tab, { force: true }) }, 'Try again'));
  if (L.status === 'empty') {
    const srv = S.serverFor(tab), ready = srv.ready;
    return h('div', { class: 'state' }, h('h2', null, `No ${name} yet`),
      h('p', null, ready ? `Scan your ${srv.name} ${name} library to fill this page. Only you start a scan; it never runs on its own.` : `Add your ${srv.name} server in Settings > Servers, then scan.`),
      ready ? h('button', { class: 'btn primary', type: 'button', disabled: S.state.halted || S.state.scan.running ? true : null, onclick: scan }, `Scan ${name} from ${srv.name}`)
        : h('button', { class: 'btn primary', type: 'button', onclick: () => import('./settings.js').then((m) => m.openSettings('plex')) }, 'Open Settings'));
  }
  return null;
}

// The view switch shared by both tabs: Posters | Grid | Dashboard
// (Compare is Movies only: it is about box office.)
export function viewSeg(mode, key, redraw) {
  // Dashboard is always last. TV: Posters - Clear - Banners - Grid - Dashboard; Movies: Posters - Grid - Compare - Dashboard
  const views = key === 'moviesView'
    ? [['posters', 'Posters'], ['grid', 'Grid'], ['compare', 'Compare'], ['dashboard', 'Dashboard']]
    : [['posters', 'Posters'], ['clear', 'Clear'], ['banners', 'Banners'], ['grid', 'Grid'], ['dashboard', 'Dashboard']];
  return h('div', { class: 'seg', role: 'tablist', 'aria-label': 'View' }, views.map(([k, label]) =>
    h('button', { type: 'button', class: mode === k ? 'active' : '', 'aria-selected': mode === k ? 'true' : 'false', onclick: () => S.saveSettings({ [key]: k }).then(redraw) }, label)));
}
export const viewMode = (v, tab) => (v === 'grid' || v === 'dashboard' || (v === 'compare' && tab !== 'tv') || ((v === 'banners' || v === 'clear') && tab === 'tv') ? v : 'posters');

export function mount(ctx) {
  const L = S.state.libs.movies;
  let grid = null, stopWall = null, stopDash = null, sort = { col: '', dir: 1 };
  // Collection mode: the + toggles a title in or out of the picks; the tick and the Done count update in place
  const pick = (r, el) => {
    const on = cmToggle('movies', r.Rid, S.itemFor(r));
    const b = el.querySelector('[data-cm]'); if (b) { b.classList.toggle('on', on); b.textContent = on ? '\u2713' : '+'; }
    el.classList.toggle('picked', on);
    const d = ctx.el.querySelector('.cm-done'); if (d) d.textContent = `Done${CM.movies.picked.size ? ` (${CM.movies.picked.size})` : ''}`;
  };
  const draw = () => {
    stopWall?.(); stopWall = null; grid?.destroy(); grid = null; stopDash?.(); stopDash = null;
    const st = stateBox('movies', L, ctx.toast);
    if (st) { ctx.el.replaceChildren(st); return; }
    const s = S.state.settings, mode = viewMode(s.moviesView);
    if (mode === 'dashboard') {
      const body = h('div');
      ctx.el.replaceChildren(h('div', { class: 'lib-head' }, h('div', { class: 'lib-title' }, h('h1', null, 'Movies'), h('small', null, 'Dashboard')),
        h('div', { class: 'lib-tools' }, viewSeg(mode, 'moviesView', draw))), body);
      stopDash = dashboard.mount({ el: body, arg: 'movies', toast: ctx.toast, embedded: true });
      return;
    }
    if (mode === 'compare') {
      const body = h('div');
      ctx.el.replaceChildren(h('div', { class: 'lib-head' }, h('div', { class: 'lib-title' }, h('h1', null, 'Movies'), h('small', null, 'Compare')),
        h('div', { class: 'lib-tools' }, viewSeg(mode, 'moviesView', draw))), body);
      compare.render(body, draw, ctx.toast);
      return;
    }
    const found = searchRows(L.rows, S.state.query, L, S.state.collections);
    let rows = found.rows;
    const before = rows.length;
    if (s.hideDupes) rows = dedupe(rows);
    const sortDef = MOVIE_SORTS.find((x) => x[0] === s.moviesSort) || MOVIE_SORTS[0];
    rows = rows.slice().sort(sortDef[2]);
    if (s.moviesSortRev) rows.reverse();
    if (mode === 'grid' && sort.col) sortByColumn(rows, sort.col, sort.dir, L);
    const hidden = before - rows.length;
    viewRids.movies = rows;
    const total = L.rows.reduce((a, r) => a + num(r.FileSizeGB), 0);
    const head = h('div', { class: 'lib-head' },
      h('div', { class: 'lib-title' }, h('h1', null, 'Movies'),
        h('small', null, `${rows.length.toLocaleString()}${rows.length !== L.rows.length ? ' of ' + L.rows.length.toLocaleString() : ''} titles${hidden > 0 ? ` · ${hidden} duplicate${hidden === 1 ? '' : 's'} hidden` : ''} · ${fmtSize(total)}`)),
      h('div', { class: 'lib-tools' },
        h('label', { class: 'chk' }, h('input', { type: 'checkbox', checked: s.hideDupes ? true : null, onchange: (e) => S.saveSettings({ hideDupes: e.target.checked }).then(draw) }), 'Hide duplicates'),
        cmControls('movies', draw),
        collectionMenu('movies'),
        toolsMenu('movies'),
        sortMenu(MOVIE_SORTS, sortDef[0], !!s.moviesSortRev, (k, rev) => { sort = { col: '', dir: 1 }; S.saveSettings({ moviesSort: k, moviesSortRev: rev }).then(draw); }),
        mode === 'grid' ? h('button', { class: 'btn', type: 'button', onclick: () => chooseColumns(L, draw) }, 'Columns') : null,
        viewSeg(mode, 'moviesView', draw)));
    const body = h('div');
    const chips = h('div'); chips.innerHTML = chipsHtml(found.chips);
    ctx.el.replaceChildren(head, chips, body);
    if (!rows.length) { body.append(h('div', { class: 'state' }, h('p', null, S.state.query ? `Nothing matches “${S.state.query}”.` : 'Nothing to show.'))); return; }
    if (mode === 'posters') {
      const wall = h('div', { class: 'wall' });
      body.append(wall);
      stopWall = fillWall(wall, rows, (r) => tileHtml({ key: r._i, poster: posterHtml(r), title: r.Title, sub: [r.Year > 0 ? r.Year : '', fmtSize(r.FileSizeGB)].filter(Boolean).join(' · '), res: r.ResolutionClass, hdr: hdrLabel(r), rating: r.Rating, rt: r.RTCritic, mcScore: r.Metascore, cm: CM.movies.on ? CM.movies.picked.has(r.Rid) : undefined }));
      wall.addEventListener('click', (e) => {
        const t = e.target.closest('.pc'); if (!t) return;
        const r = L.rows[+t.dataset.k];
        if (e.target.closest('[data-cm]')) { pick(r, t); return; }
        openCard(r, ctx.toast);
      });
    } else {
      const cols = gridColumns(L);
      const cmOn = CM.movies.on;
      grid = vgrid(body, {
        head: () => { const hd = headHtml(cols, sort); return cmOn ? { html: hd.html.replace('<tr>', '<tr><th class="cm-col" title="Collection mode">+</th>'), count: hd.count + 1 } : hd; },
        rowHtml: (r, i) => `<tr data-i="${i}">${cmOn ? `<td class="cm-col"><span class="cm-add${CM.movies.picked.has(r.Rid) ? ' on' : ''}" role="button" data-cm="1">${CM.movies.picked.has(r.Rid) ? '\u2713' : '+'}</span></td>` : ''}<td class="ttl" title="${esc(r.Title)}">${esc(r.Title)}</td>${cols.map((c) => cellHtml(r, c, L)).join('')}</tr>`,
        onRow: (r, e) => { if (e && e.target.closest('[data-cm]')) { pick(r, e.target.closest('tr')); return; } openCard(r, ctx.toast); },
        onHead: (c) => { if (!c) return; sort = { col: c, dir: sort.col === c ? -sort.dir : (L.byName.get(c)?.t === 'string' || c === 'Title' ? 1 : -1) }; draw(); },
      });
      grid.set(rows);
    }
  };
  draw();
  ctx.redraw = draw;
  ctx.seen = { status: L.status, rows: L.rows };
  return () => { stopWall?.(); grid?.destroy(); stopDash?.(); };
}
// Redraw only when this library changed (the other tab loading must not reset the scroll position).
export function update(topics, ctx) {
  const L = S.state.libs.movies, changed = ctx.seen && (ctx.seen.status !== L.status || ctx.seen.rows !== L.rows);
  if (changed) ctx.seen = { status: L.status, rows: L.rows };
  if (changed || topics.has('query') || topics.has('collections') || (L.status !== 'ready' && (topics.has('plex') || topics.has('traffic') || topics.has('scan')))) ctx.redraw?.();
}
