// App state and host calls. Same shape as the Sample's store.js (state, subscribe/notify topics, settings, traffic,
// updates), with the library in place of the Sample's league: state.libs.movies / state.libs.tv.
import * as bridge from './bridge.js';

export const TABS = ['movies', 'tv'];
const lib = () => ({ status: 'idle', rows: [], fields: [], byName: new Map(), error: '' });

export const state = {
  ready: false,
  host: bridge.isHost,
  version: '',
  hostMode: 'standalone',
  hostTheme: '',
  settings: { theme: 'system', updateCheck: false, moviesView: 'posters', tvView: 'posters', moviesSort: 'added', tvSort: 'title', moviesSortRev: false, tvSortRev: false,
    columns: [], hideDupes: false, posterScale: 100, widthPreset: 'full', customWidth: false, contentWidth: 0 },
  plex: { url: '', hasToken: false },
  counts: { movies: { count: 0, when: '' }, tv: { count: 0, when: '' } },
  libs: { movies: lib(), tv: lib() },
  scan: { running: false, tab: '', pct: 0, text: '', result: null, finishedAt: 0 },
  update: { phase: 'idle', info: null, pct: 0, text: '', error: '', quiet: false, note: null },
  dropped: null,          // { file, version }: an update zip saved into the updates folder (standalone only)
  halted: false,
  query: '',              // the navigation bar's search box
};

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
    if (r.Poster && !/^(https?:|data:|blob:)/.test(r.Poster)) r.Poster = (bridge.isHost ? 'https://mmlm.cache/' : '') + r.Poster;
    return r;
  });
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
  } catch (e) { L.status = 'error'; L.error = e.message; }
  notify('library');
}
function onLibrary(d) {
  if (!d || !TABS.includes(d.tab)) return;
  const L = state.libs[d.tab];
  if (d.ready) { L.status = 'idle'; loadLibrary(d.tab); }
  else { L.status = 'error'; L.error = d.error || 'The library could not be opened.'; notify('library'); }
}

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
export async function savePlex(url, token) {
  state.plex = await bridge.request('plex.set', { url, token });
  notify('plex');
}
// The live status button: same as the launcher's kill switch, started from inside the dash.
export async function stopTraffic() { await bridge.request('traffic.stop'); state.halted = true; notify('traffic'); }
export async function resumeTraffic() { await bridge.request('traffic.resume'); state.halted = false; notify('traffic'); }
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
  bridge.on('update.dropped', (d) => { state.dropped = d; notify('dropped'); });

  state.ready = true;
  notify('counts');
  if (state.host && state.settings.updateCheck && !state.update.note && !inLauncher()) setTimeout(() => checkUpdate({ quiet: true }), 4000);
  return state;
}
