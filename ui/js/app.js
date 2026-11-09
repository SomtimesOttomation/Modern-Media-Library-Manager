// Modern Media Library Manager page shell. From the Sample's app.js (NBADash's): routing, the scan progress strip,
// the live status pause switch, the kill-switch bar, the version button, the hidden traffic counter and the
// navigation bar. Routes: #/movies, #/tv, #/stats (Home is the Movies library).
import * as S from './store.js';
import * as bridge from './bridge.js';
import { h, ago } from './util.js';
import * as library from './views/library.js';
import * as tv from './views/tv.js';
import * as stats from './views/stats.js';
import { openSettings } from './views/settings.js';
import { openTraffic } from './views/traffic.js';
import { openUpdate } from './views/update.js';

const $ = (s) => document.querySelector(s);
const view = $('#view');
let current = null; // { mod, ctx, cleanup }

export function toast(msg) {
  const t = h('div', { class: 'toast' }, msg);
  $('#toasts').append(t);
  setTimeout(() => t.remove(), 4000);
}

export function currentTab() {
  const name = location.hash.replace(/^#\/?/, '').split('/')[0];
  if (name === 'tv') return 'tv';
  if (name === 'stats') return location.hash.split('/')[2] === 'tv' ? 'tv' : 'movies';
  return 'movies';
}

function route() {
  const hash = location.hash.replace(/^#\/?/, '');
  const [name, arg] = hash.split('/');
  const map = { '': library, movies: library, tv, stats };
  const mod = map[name] || library;
  const routeName = map[name] ? (name || 'movies') : 'movies';
  document.querySelectorAll('#nav a').forEach((a) => a.classList.toggle('active', a.dataset.route === routeName));
  $('#btn-home').classList.toggle('active', routeName === 'movies');
  current?.cleanup?.();
  view.replaceChildren();
  const ctx = { el: view, arg: arg ? decodeURIComponent(arg) : '', toast };
  current = { mod, ctx, cleanup: mod.mount(ctx) };
  $('#psearch').value = S.state.query;
  liveStatus();
  window.scrollTo(0, 0);
}

function themeIcon() {
  const t = S.state.settings.theme;
  $('#btn-theme').textContent = t === 'dark' ? '☾' : t === 'light' ? '☀' : '◐';
  $('#btn-theme').title = `Theme: ${t} (click to change)`;
}

// ---- updates: one quiet nudge when the startup check finds something; the version chip carries the rest
let nudged = '';
function updateToast() {
  const u = S.state.update;
  if (u.phase === 'available' && u.quiet && nudged !== u.info?.latest) { nudged = u.info.latest; toast(`Version ${u.info.latest} is available. Click the version number to update.`); }
}

// ---- scan progress strip --------------------------------------------------------------------------------------
let lastRunning = false;
const tabName = (t) => (t === 'tv' ? 'TV Shows' : 'Movies');
function syncBar() {
  const bar = $('#syncbar'), sc = S.state.scan;
  const fill = bar.querySelector('.syncbar-fill'), txt = bar.querySelector('.syncbar-text');
  if (sc.running) {
    bar.hidden = false; bar.classList.remove('fail');
    bar.classList.toggle('indeterminate', !sc.pct);
    fill.style.width = `${sc.pct || 0}%`;
    txt.textContent = `Scanning ${tabName(sc.tab)} from Plex · ${sc.pct ? sc.pct + '% · ' : ''}${sc.text || ''}`;
  } else if (lastRunning) {
    const r = sc.result || {};
    bar.classList.remove('indeterminate'); bar.classList.toggle('fail', !!r.error);
    fill.style.width = '100%';
    txt.textContent = r.cancelled ? 'Scan stopped' : r.error ? `Scan failed · ${r.error}` : `Scan finished · ${r.count} ${r.tab === 'tv' ? 'episodes' : 'titles'}${r.new ? ` · ${r.new} new` : ''}`;
    toast(txt.textContent);
    setTimeout(() => { if (!S.state.scan.running) bar.hidden = true; }, 6000);
  }
  lastRunning = !!sc.running;
}

// Live status: a library has nothing live, so it says what the open library is doing; it is still the pause switch.
function liveStatus() {
  const el = $('#live-status');
  const tab = currentTab(), sc = S.state.scan, c = S.state.counts[tab];
  const halted = !!S.state.halted;
  const err = S.state.libs[tab].status === 'error' ? S.state.libs[tab].error : '';
  el.className = `live-status np-live ${err && !halted ? 'err' : ''} ${halted ? 'halted' : ''}`;
  el.setAttribute('aria-pressed', halted ? 'true' : 'false');
  const when = c && c.when ? Date.parse(c.when.replace(' ', 'T')) : 0;
  el.textContent = halted ? 'Paused' : sc.running ? `Scanning${sc.pct ? ' ' + sc.pct + '%' : '...'}` : err ? 'Problem' : when ? `Scanned ${ago(when)}` : 'Not scanned yet';
  el.title = halted ? 'All data traffic is paused. Click to resume.' : `${err ? `${err}\n` : ''}Click to pause all data traffic`;
}
function navCounts() {
  for (const t of S.TABS) {
    const L = S.state.libs[t], n = L.status === 'ready' ? (t === 'tv' ? new Set(L.rows.map((r) => r.Show || r.Title)).size : L.rows.length) : 0;
    $(`#count-${t}`).textContent = n ? n.toLocaleString() : '';
  }
}

// secret: five clicks on the brand within 3 seconds opens the traffic panel; otherwise it goes home
let clicks = [];
$('#brand').addEventListener('click', () => {
  const now = Date.now();
  clicks = clicks.filter((t) => now - t < 3000).concat(now);
  if (clicks.length >= 5) { clicks = []; openTraffic(); } else if (clicks.length === 1) location.hash = '#/';
});

$('#btn-theme').addEventListener('click', () => {
  const order = ['system', 'light', 'dark'];
  const next = order[(order.indexOf(S.state.settings.theme) + 1) % 3];
  S.saveSettings({ theme: next });
});
// Back: the page's own history (every view is a #/ route). Also Alt+Left and the mouse's back button.
let navDepth = 0;
window.addEventListener('hashchange', () => { navDepth++; });
const goBack = () => { if (navDepth > 0) { navDepth -= 2; history.back(); } else location.hash = '#/'; };
$('#btn-fwd').addEventListener('click', () => history.forward());
document.addEventListener('keydown', (e) => { if (e.altKey && e.key === 'ArrowRight') { e.preventDefault(); history.forward(); } });
window.addEventListener('mouseup', (e) => { if (e.button === 4) { e.preventDefault(); history.forward(); } });
$('#btn-back').addEventListener('click', goBack);
document.addEventListener('keydown', (e) => { if (e.altKey && e.key === 'ArrowLeft') { e.preventDefault(); goBack(); } });
window.addEventListener('mouseup', (e) => { if (e.button === 3) { e.preventDefault(); goBack(); } });
$('#btn-settings').addEventListener('click', () => openSettings());
// Live status doubles as a pause switch: one click stops every data request until clicked again.
$('#live-status').addEventListener('click', () => (S.state.halted ? S.resumeTraffic() : S.stopTraffic()).catch((e) => toast(e.message)));
$('#btn-version').addEventListener('click', openUpdate);

// Kill switch (DashLauncher): a bar until the person resumes.
function haltBar() {
  const b = $('#haltbar');
  b.hidden = !S.state.halted;
  if (!S.state.halted) { b.replaceChildren(); return; }
  b.replaceChildren(h('span', null, 'Data traffic stopped. Nothing is fetched from Plex or the internet until you resume.'),
    h('button', { class: 'btn primary', type: 'button', onclick: () => S.resumeTraffic().catch((e) => toast(e.message)) }, 'Resume'));
}
// Drop-in update (standalone): a zip saved into the updates folder.
function dropBar() {
  const b = $('#dropbar'), d = S.state.dropped;
  b.hidden = !d;
  if (!d) { b.replaceChildren(); return; }
  b.replaceChildren(h('span', null, `${d.file} (v${d.version}) is in the updates folder.`),
    h('button', { class: 'btn primary', type: 'button', onclick: () => { S.stageDropped(); openUpdate(); } }, 'Install'),
    h('button', { class: 'btn', type: 'button', onclick: () => S.dismissDropped() }, 'Not now'));
}

function versionChip() {
  const b = $('#btn-version'), u = S.state.update;
  b.textContent = S.state.version ? `v${S.state.version}` : '';
  b.hidden = !S.state.version;
  b.classList.toggle('has-update', S.updateReady());
  b.title = u.phase === 'available' ? `Version ${u.info?.latest} is available` : u.phase === 'staged' ? 'Update downloaded: click to install' : 'Check for updates';
}
// Refresh = scan the open library from Plex (what "refresh" means for a library). Only when asked.
async function scanNow() {
  const b = $('#btn-refresh');
  if (S.state.scan.running) { toast('A scan is already running.'); return; }
  if (!S.state.plex.url || !S.state.plex.hasToken) { toast('Add your Plex server and token in Settings first.'); openSettings('plex'); return; }
  b.classList.add('spin');
  try { await S.startScan(currentTab()); } catch (e) { toast(e.message); b.classList.remove('spin'); }
}
$('#btn-refresh').addEventListener('click', scanNow);
document.addEventListener('keydown', (e) => { if (e.key === 'F5') { e.preventDefault(); scanNow(); } });

// Search: filters the open library (title, show, genre, cast, studio, director, year, collection).
let qTimer = 0;
$('#psearch').addEventListener('input', (e) => {
  clearTimeout(qTimer);
  qTimer = setTimeout(() => { S.state.query = e.target.value.trim(); S.notify('query'); }, 120);
});
document.addEventListener('keydown', (e) => {
  if (e.key === '/' && !e.target.closest('input,textarea,select')) { e.preventDefault(); $('#psearch').focus(); }
});

S.subscribe((topics) => {
  if (topics.has('theme') || topics.has('settings')) themeIcon();
  if (topics.has('traffic')) { haltBar(); liveStatus(); }
  if (topics.has('dropped')) dropBar();
  if (topics.has('scan')) { syncBar(); liveStatus(); if (!S.state.scan.running) $('#btn-refresh').classList.remove('spin'); else $('#btn-refresh').classList.add('spin'); }
  if (topics.has('counts') || topics.has('library')) { liveStatus(); navCounts(); }
  if (topics.has('update')) { versionChip(); updateToast(); }
  current?.mod.update?.(topics, current.ctx);
});
setInterval(liveStatus, 30000);

window.addEventListener('hashchange', route);
S.init().then(() => {
  if (S.inLauncher()) $('#btn-theme').hidden = true;      // the launcher owns the theme
  haltBar(); dropBar();
  themeIcon(); route(); versionChip(); syncBar();
  for (const t of S.TABS) S.loadLibrary(t);               // both libraries load once, from the saved scan (no network)
  const n = S.state.update.note;
  if (n) toast(n.ok ? `Updated to v${n.to}.` : `The update to v${n.to} did not work (${n.reason || 'unknown reason'}). v${n.from} was restored.`);
}).catch((e) => {
  view.replaceChildren(h('div', { class: 'state' }, h('h2', null, 'Could not start'), h('p', null, e.message)));
});
void bridge;
