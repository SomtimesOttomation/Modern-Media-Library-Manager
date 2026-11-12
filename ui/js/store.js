// App state and host calls. Same shape as the Sample's store.js (state, subscribe/notify topics, settings, traffic,
// updates), with the library in place of the Sample's league: state.libs.movies / state.libs.tv.
import * as bridge from './bridge.js';
import { adjust, ADJ_FIELDS } from './inflation.js';

export const TABS = ['movies', 'tv'];
const lib = () => ({ status: 'idle', rows: [], fields: [], byName: new Map(), error: '' });

export const state = {
  ready: false,
  host: bridge.isHost,
  version: '',
  hostMode: 'standalone',
  hostTheme: '',
  showStatus: {},           // TV: show name -> { state: 'Ongoing'|'Ended', tmdb, lastAir } (TV Shows > Fetch info)
  settings: { theme: 'system', updateCheck: false, moviesView: 'posters', tvView: 'posters', moviesSort: 'added', tvSort: 'title', moviesSortRev: false, tvSortRev: false,
    columns: [], hideDupes: false, posterScale: 100, tvScale: 100, clearScale: 100, bannerScale: 100, doctorFreq: 'off', doctorAck: false, doctorDay: 0, doctorTime: '03:00', doctorStyle: 'compact', doctorChecks: ['unreadable', 'unmatched', 'wrongmatch', 'gaps', 'poster', 'dupes', 'av1'], widthPreset: 'full', customWidth: false, contentWidth: 0, artLogo: false, artBackground: false, artBanner: false, cmpInflation: false,
    fxLeft: 'auto', fxRight: 'auto', fxMotion: 'full', vsStyle: 'arcade', cmpTally: true, cmpWalkover: true, cmpImdb: true },
  plex: { url: '', hasToken: false },
  counts: { movies: { count: 0, when: '' }, tv: { count: 0, when: '' } },
  libs: { movies: lib(), tv: lib() },
  scan: { running: false, tab: '', pct: 0, text: '', result: null, finishedAt: 0 },
  update: { phase: 'idle', info: null, pct: 0, text: '', error: '', quiet: false, note: null },
  dropped: null,          // { file, version }: an update zip saved into the updates folder (standalone only)
  halted: false,
  query: '',              // the navigation bar's search box
  collections: [],        // { name, kind, ids:Set, has(r) } (filled from the window app's collections)
  tool: null,             // the running tool (Fetch info, FEL check, export): { kind, running, pct, text } or its result
};
export let toast = null; export function setToast(fn) { toast = fn; }

// ---- change notification (NBADash's) ----------------------------------------------------------------------
const subs = new Set();
let queued = new Set();
let raf = 0;
export function subscribe(fn) { subs.add(fn); return () => subs.delete(fn); }
export function notify(...topics) {
  topics.forEach((t) => queued.add(t));
  if (raf) return;
  raf = requestAnimationFrame(() => {
    const t = queued; queued = new Set(); raf = 0;
    subs.forEach((fn) => { try { fn(t); } catch (e) { console.error(e); } });
  });
}

// ---- the library ------------------------------------------------------------------------------------------
const num = (x) => { const n = +x; return Number.isFinite(n) ? n : 0; };
export const splitList = (s) => String(s || '').split(/\s*[;,]\s*/).filter(Boolean);
function prepare(raw, tab) {
  const names = raw.fields.map((f) => f.n);
  const rows = raw.rows.map((a, i) => {
    const r = { _i: i, _tab: tab };
    for (let k = 0; k < names.length; k++) if (a[k] !== null) r[names[k]] = a[k];
    r.Title = r.Title || r.FileName || 'Untitled';
    r.Year = num(r.Year);
    r._genres = splitList(r.Genre);
    r._search = [r.Title, r.Show, r.Genre, r.Cast, r.Studio, r.Director, r.Year || '', r.Collection].join(' ').toLowerCase();
    for (const k of ['Poster', 'Art', 'Logo', 'Banner']) if (r[k] && !/^(https?:|data:|blob:)/.test(r[k])) r[k] = (bridge.isHost ? 'https://mmlm.cache/' : '') + r[k];
    for (const [f, a] of ADJ_FIELDS) if (r[f] > 0) { const v = adjust(r[f], r.Year); if (v > 0) r[a] = Math.round(v); }   // inflation.js
    return r;
  });
  // the inflation-adjusted box office joins the field list (Grid columns, search), next to the real figures
  if (raw.fields.some((f) => f.n === 'BoxOfficeWorldwide')) for (const [f, a] of ADJ_FIELDS) if (!raw.fields.some((x) => x.n === a)) raw.fields.push({ n: a, t: 'double', g: 'Box office', s: false });
  return { rows, fields: raw.fields, byName: new Map(raw.fields.map((f) => [f.n, f])) };
}
// The failed-request rule: a library that failed to load is not asked for again when the page redraws, only when the
// person asks (Retry or Refresh).
export async function loadLibrary(tab, { force = false } = {}) {
  const L = state.libs[tab];
  if (!force && L.status !== 'idle') return;
  L.status = 'loading'; L.error = ''; notify('library');
  try {
    const raw = await bridge.request('library.get', { tab }, 120000);
    if (raw.empty) { Object.assign(L, lib(), { status: 'empty' }); }
    else if (raw.pending) { L.status = 'pending'; }                  // being built from the last scan; a 'library' event follows
    else { Object.assign(L, prepare(raw, tab), { status: 'ready' }); }
    if (tab === 'tv' && L.status === 'ready') { try { state.showStatus = (await bridge.request('shows.status')) || {}; } catch (e) { state.showStatus = {}; } }
  } catch (e) { L.status = 'error'; L.error = e.message; }
  notify('library');
}
function onLibrary(d) {
  if (!d || !TABS.includes(d.tab)) return;
  const L = state.libs[d.tab];
  if (d.ready) { L.status = 'idle'; loadLibrary(d.tab); }
  else { L.status = 'error'; L.error = d.error || 'The library could not be opened.'; notify('library'); }
}

// ---- collections (shared with the window app's collections.json) -------------------------------------------------------
// Hand-picked: a list of title ids ("p:<Plex key>", "h:<hashed local file>"; a TV show counts when any of its episodes
// is listed, which is how the window app stores shows). Rule: a saved search, read with the same syntax as the search box.
import { parse as parseQuery, filterRows } from './search.js';
function buildCollections(list) {
  return (list || []).map((c) => {
    const ids = new Set((c.items || []).flatMap((it) => it.ids || []));
    const shows = { rows: null, set: null };
    const rule = { tab: {}, };
    const has = c.type === 'rule'
      ? (r) => {
        const L = state.libs[r._tab];
        let t = rule.tab[r._tab];
        if (!t || t.rows !== L.rows) {
          // comma = either part (as in the window app)
          const parts = String(c.query || '').split(',').map((x) => x.trim()).filter(Boolean).map((q) => parseQuery(q, L, []));
          t = rule.tab[r._tab] = { rows: L.rows, set: new Set(parts.length ? parts.flatMap((p) => filterRows(L.rows, p)) : []) };
        }
        return t.set.has(r);
      }
      : (r) => {
        if (ids.has(r.Rid)) return true;
        if (!r.Show) return false;
        const L = state.libs.tv;
        if (shows.rows !== L.rows) { shows.rows = L.rows; shows.set = new Set(L.rows.filter((e) => ids.has(e.Rid)).map((e) => e.Show)); }
        return shows.set.has(r.Show) || ids.has('s:' + r.Show);
      };
    return { ...c, ids, has };
  });
}
export async function loadCollections() {
  try { state.collections = buildCollections(await bridge.request('collections.get')); } catch (e) { console.warn(e.message); }
  notify('collections');
}
export async function saveCollections(list) {
  const plain = list.map(({ name, type, query, sortBy, sortDesc, byDate, limit, items, created }) => ({ name, type, query, sortBy, sortDesc, byDate, limit, items, created }));
  state.collections = buildCollections(await bridge.request('collections.save', { collections: plain }));
  notify('collections', 'query');
}
// The id a title is saved under in a collection (a show: its first episode, as the window app does).
export function itemFor(r, eps) {
  const first = eps ? eps.slice().sort((a, b) => (+a.Season || 99) - (+b.Season || 99) || (+a.Episode || 0) - (+b.Episode || 0))[0] : r;
  return { ids: [first.Rid].filter(Boolean), title: eps ? r.Show || r.Title : r.Title, year: r.Year || 0 };
}
// rows of a library matching a search (dashboards' per-chart filters)
export const filterByQuery = (L, q) => filterRows(L.rows, parseQuery(q, L, state.collections));
export function setQuery(q) { state.query = String(q || '').trim(); notify('query', 'queryset'); }

// ---- scanning (Plex) ----------------------------------------------------------------------------------------
export async function startScan(tab, rebuild = false) {
  if (state.halted) throw new Error('Data traffic is paused. Resume it first.');
  await bridge.request('scan.start', { tab, rebuild });
  state.scan = { ...state.scan, running: true, tab, pct: 0, text: 'Starting...', result: null };
  notify('scan');
}
export const cancelScan = () => bridge.request('scan.cancel');
function onScan(d) {
  const was = state.scan.running;
  if (d.running) state.scan = { ...state.scan, running: true, tab: d.tab, pct: d.pct || 0, text: d.text || '' };
  else {
    state.scan = { ...state.scan, running: false, tab: d.tab, result: d, finishedAt: Date.now() };
    if (!d.cancelled && !d.error) state.counts[d.tab] = { count: d.count, when: new Date().toISOString().slice(0, 16).replace('T', ' ') };
  }
  notify('scan');
  if (was && !d.running) notify('counts');
}

// ---- app updates (NBADash's) --------------------------------------------------------------------------------
function onUpdate(d) {
  const u = state.update;
  if (d.running) {
    u.phase = d.action === 'Check' ? 'checking' : 'downloading';
    u.pct = d.pct || 0; u.text = d.text || '';
  } else {
    const r = d.result || {};
    u.pct = 0; u.text = ''; u.error = '';
    if (r.status === 'error') { u.phase = 'error'; u.error = r.error || 'The update did not finish.'; }
    else { u.phase = r.status || 'idle'; u.info = r; }
  }
  notify('update');
}
export async function checkUpdate({ quiet = false } = {}) {
  const u = state.update;
  if (u.phase === 'checking' || u.phase === 'downloading') return;
  u.quiet = quiet; u.phase = 'checking'; u.error = ''; u.pct = 0; u.text = 'Asking GitHub for the latest release...';
  notify('update');
  try {
    const started = await bridge.request('update.check');
    if (started === false) { u.phase = u.info?.status === 'available' ? 'available' : 'idle'; notify('update'); }
  } catch (e) { u.phase = 'error'; u.error = e.message; notify('update'); }
}
export async function downloadUpdate() {
  const u = state.update;
  u.quiet = false; u.phase = 'downloading'; u.pct = 0; u.text = 'Starting...'; notify('update');
  try { await bridge.request('update.stage'); } catch (e) { u.phase = 'error'; u.error = e.message; notify('update'); }
}
export async function stageDropped() {
  const d = state.dropped; if (!d) return;
  const u = state.update;
  state.dropped = null;
  u.quiet = false; u.phase = 'downloading'; u.pct = 0; u.text = 'Checking the package...'; u.info = { latest: d.version };
  notify('update', 'dropped');
  try { await bridge.request('update.stagezip', { file: d.file }); } catch (e) { u.phase = 'error'; u.error = e.message; notify('update'); }
}
export function dismissDropped() { state.dropped = null; notify('dropped'); }
export async function cancelUpdate() {
  try { await bridge.request('update.cancel'); } catch { /* ignore */ }
  state.update.phase = state.update.info?.status === 'available' ? 'available' : 'idle';
  notify('update');
}
export async function installUpdate() {
  try { await bridge.request('update.apply'); } catch (e) { state.update.phase = 'error'; state.update.error = e.message; notify('update'); }
}
export const updateReady = () => state.update.phase === 'available' || state.update.phase === 'staged';

// ---- settings, theme, traffic -----------------------------------------------------------------------------------
export const inLauncher = () => state.hostMode === 'launcher';
export function applyTheme() {
  document.documentElement.dataset.theme = (inLauncher() && state.hostTheme) ? state.hostTheme : (state.settings.theme || 'system');
  notify('theme');
}
export async function saveSettings(patch) {
  Object.assign(state.settings, patch);
  if ('theme' in patch) applyTheme();
  notify('settings');
  for (const [key, value] of Object.entries(patch)) {
    try { state.settings = { ...state.settings, ...(await bridge.request('settings.set', { key, value })) }; } catch (e) { console.warn(e.message); }
  }
}
// Which server a library comes from (Settings > Servers), and whether it is set up enough to scan.
export function serverFor(tab) {
  const p = state.plex || {}, kind = (p.use && p.use[tab]) || 'plex';
  if (kind === 'jellyfin') return { kind, name: 'Jellyfin', ready: !!(p.jellyfin && p.jellyfin.url && p.jellyfin.hasKey) };
  return { kind: 'plex', name: 'Plex', ready: !!(p.url && p.hasToken) };
}
export async function useServer(tab, kind) { state.plex = await bridge.request('server.use', { tab, kind }); notify('plex'); }
export async function saveJellyfin(url, key) { state.plex = await bridge.request('jellyfin.set', { url, key }); notify('plex'); }
export async function savePlex(url, token) {
  state.plex = await bridge.request('plex.set', { url, token });
  notify('plex');
}
// The live status button: same as the launcher's kill switch, started from inside the dash.
export async function stopTraffic() { await bridge.request('traffic.stop'); state.halted = true; notify('traffic'); }
export async function resumeTraffic() { await bridge.request('traffic.resume'); state.halted = false; notify('traffic'); }
export const keysInfo = () => bridge.request('keys.get');
export const saveKeys = (tmdb, omdb) => bridge.request('keys.set', { tmdb, omdb });
export const openUrl = (url) => bridge.request('open.url', { url });
export const savePicture = (name, png) => bridge.request('picture.save', { name, png }, 60000);

export async function init() {
  await bridge.ready();
  const info = await bridge.request('init');
  state.version = info.version || '';
  state.hostMode = info.mode || 'standalone';
  state.hostTheme = info.theme || '';
  state.settings = { ...state.settings, ...(info.settings || {}) };
  state.plex = info.plex || state.plex;
  state.halted = !!info.halted;
  state.counts = { movies: info.movies || state.counts.movies, tv: info.tv || state.counts.tv };
  state.update.note = info.updateNote || null;
  if (info.scanning) state.scan = { ...state.scan, running: true, tab: info.scanTab, text: 'Scanning...' };
  applyTheme();

  // host events (dash contract): launcher theme, tab shown again, kill switch
  bridge.on('host.theme', (d) => { state.hostTheme = (d && d.theme) || ''; applyTheme(); });
  bridge.on('host.visible', () => notify('visible'));
  bridge.on('host.hidden', () => notify('hidden'));
  bridge.on('traffic', (d) => { state.halted = !!(d && d.stopped); notify('traffic'); });
  bridge.on('scan', onScan);
  bridge.on('library', onLibrary);
  bridge.on('update', onUpdate);
  bridge.on('tool', (d) => { state.tool = d; notify('tool'); });
  bridge.on('update.dropped', (d) => { state.dropped = d; notify('dropped'); });

  state.ready = true;
  loadCollections();
  notify('counts');
  if (state.host && state.settings.updateCheck && !state.update.note && !inLauncher()) setTimeout(() => checkUpdate({ quiet: true }), 4000);
  return state;
}
