// Settings: the Sample's overlay with tabs. General (theme, updates), Plex (server and token), Data (sources, traffic),
// Artwork (clear logos, background art, TV banners from Plex), Fun (Compare's borders and VS).
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { doctorTab } from './doctor.js';
import { h } from '../util.js';
import { openUpdate } from './update.js';
import { openTraffic } from './traffic.js';

// In-page overlay (no alert/confirm/prompt): Escape or a click outside closes it.
function overlay(content, extraClass = '', onClose = null) {
  const root = document.getElementById('overlay-root');
  const close = () => { root.replaceChildren(); document.removeEventListener('keydown', esc); onClose?.(); };
  const esc = (e) => { if (e.key === 'Escape') close(); };
  document.addEventListener('keydown', esc);
  const o = h('div', { class: 'overlay', onclick: (e) => { if (e.target === o) close(); } }, h('div', { class: `card modal ${extraClass}` }, content(close)));
  root.replaceChildren(o);
  return close;
}
export { overlay };

const TAB_KEY = 'mmlm.settingsTab';
let settingsTab = 'general';
try { const v = localStorage.getItem(TAB_KEY); if (['general', 'plex', 'data', 'artwork', 'doctor', 'fun'].includes(v)) settingsTab = v; } catch (e) { /* ignore */ }
const hr = () => h('hr', { style: { border: 0, borderTop: '1px solid var(--line)' } });

function generalTab(close, repaint) {
  const s = S.state.settings;
  return [
    S.inLauncher()
      ? h('p', null, h('b', null, 'Theme '), h('small', null, 'Follows DashLauncher.'))
      : h('p', null, h('b', null, 'Theme '),
        [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']].map(([t, label]) => h('button', { class: `btn ${s.theme === t ? 'primary' : ''}`, type: 'button', style: { marginRight: '6px' }, onclick: () => { S.saveSettings({ theme: t }); repaint(); } }, label))),
    hr(),
    h('p', null, h('b', null, 'Width '), h('small', null, 'How wide the posters and grids spread. A preset uses the width a screen of that shape would have at this window height, centred.')),
    h('p', null, [['full', 'Full width'], ['16:9', '16:9'], ['21:9', '21:9'], ['32:9', '32:9']].map(([k, label]) => h('button', {
      class: `btn ${s.widthPreset === k && !(s.customWidth && s.contentWidth > 0) ? 'primary' : ''}`, type: 'button', style: { marginRight: '6px' },
      onclick: () => { S.saveSettings({ widthPreset: k, contentWidth: 0 }); repaint(); } }, label))),
    h('p', null, h('label', null, h('input', { type: 'checkbox', checked: s.customWidth ? true : null, onchange: (e) => { S.saveSettings({ customWidth: e.target.checked }); repaint(); } }),
      ' Allow a custom width: drag either edge of the posters or grid (both sides move together; double-click an edge to go back to the preset)'),
      s.customWidth && s.contentWidth > 0 ? h('small', null, ` Now ${s.contentWidth} px.`) : null),
    hr(),
    h('p', null, h('b', null, 'Updates')),
    h('p', null, h('label', null, h('input', { type: 'checkbox', checked: s.updateCheck ? true : null, onchange: (e) => S.saveSettings({ updateCheck: e.target.checked }) }),
      ' Also check GitHub when the app starts (off by default: it checks only when you click the version)'), ' ',
      h('button', { class: 'btn', type: 'button', style: { marginLeft: '8px' }, onclick: () => { close(); openUpdate(); } }, `v${S.state.version || '?'} · Check now`)),
    h('p', null, h('small', null, S.inLauncher() ? 'In DashLauncher, updates can also be installed from the launcher.' : 'You can also save an update zip (and its .sha256) into the updates folder next to the app; it is offered here as soon as it appears.')),
  ];
}

function plexTab(repaint) {
  const p = S.state.plex;
  const url = h('input', { type: 'text', value: p.url || '', placeholder: 'http://plex-server:32400', spellcheck: 'false' });
  const tok = h('input', { type: 'password', value: '', placeholder: p.hasToken ? 'saved (type a new one to replace it)' : 'your Plex token', autocomplete: 'off' });
  const msg = h('small', null, '');
  const save = h('button', { class: 'btn primary', type: 'button', onclick: async () => {
    save.disabled = true; msg.textContent = 'Saving...';
    try { await S.savePlex(url.value.trim(), tok.value.trim()); tok.value = ''; msg.textContent = 'Saved.'; repaint(); }
    catch (e) { msg.textContent = e.message; }
    save.disabled = false;
  } }, 'Save');
  return [
    h('p', null, h('small', null, 'The libraries are read from your Plex server, only when you scan (the circular arrow in the bar, or F5). The token is stored encrypted for your Windows account, in the same place the window app keeps it.')),
    h('div', { class: 'form-row' }, h('label', null, 'Server address'), url),
    h('div', { class: 'form-row' }, h('label', null, 'Token'), tok),
    h('p', null, save, ' ', msg),
    hr(),
    h('p', null, h('b', null, 'Scan '), h('small', null, 'A scan reuses titles Plex has not changed. A full rescan reads every title again.')),
    h('p', null, ...S.TABS.map((t) => h('button', { class: 'btn', type: 'button', style: { marginRight: '6px' }, disabled: S.state.scan.running || S.state.halted ? true : null,
      onclick: () => S.startScan(t, true).catch((e) => { msg.textContent = e.message; }) }, `Full rescan of ${t === 'tv' ? 'TV Shows' : 'Movies'}`))),
  ];
}

function dataTab() {
  const tm = h('input', { type: 'password', placeholder: 'TMDB API key or read token', autocomplete: 'off' });
  const om = h('input', { type: 'password', placeholder: 'OMDb API key', autocomplete: 'off' });
  const kmsg = h('small', null, '');
  S.keysInfo().then((k) => { tm.placeholder = k.tmdb ? 'saved (type a new one to replace it)' : tm.placeholder; om.placeholder = k.omdb ? 'saved (type a new one to replace it)' : om.placeholder; }).catch(() => {});
  const saveKeys = async () => {
    try { const k = await S.saveKeys(tm.value.trim() || null, om.value.trim() || null); tm.value = ''; om.value = ''; kmsg.textContent = `Saved. TMDB ${k.tmdb ? 'set' : 'not set'}, OMDb ${k.omdb ? 'set' : 'not set'}.`; }
    catch (e) { kmsg.textContent = e.message; }
  };
  return [
    h('p', null, h('b', null, 'Fetch info keys '), h('small', null, 'Your own free keys from themoviedb.org and omdbapi.com, stored encrypted for your Windows account (shared with the window app). Used only when you run Tools > Fetch info.')),
    h('div', { class: 'form-row' }, h('label', null, 'TMDB'), tm),
    h('div', { class: 'form-row' }, h('label', null, 'OMDb'), om),
    h('p', null, h('button', { class: 'btn primary', type: 'button', onclick: saveKeys }, 'Save keys'), ' ', kmsg),
    hr(),
    h('p', null, h('label', null, h('input', { type: 'checkbox', checked: S.state.settings.detectFel ? true : null, onchange: (e) => S.saveSettings({ detectFel: e.target.checked }) }),
      ' Check FEL / MEL during Plex scans (dual-layer Dolby Vision files this PC can open; needs ffmpeg and dovi_tool in the lib folder; slower)')),
    hr(),
    h('p', null, h('b', null, 'Where the data comes from')),
    h('ul', null,
      h('li', null, 'Your Plex server: titles, file details and posters, when you scan.'),
      h('li', null, 'GitHub: the update check, only as set under General.'),
      h('li', null, 'TMDB, OMDb and the IMDb ratings file: only when you run Tools > Fetch info.')),
    h('p', null, h('small', null, 'Nothing is fetched automatically. The live status button in the bar pauses all data traffic.')),
    h('p', null, h('button', { class: 'btn', type: 'button', onclick: () => openTraffic() }, 'Traffic details')),
  ];
}

// Artwork: extra pictures from your own Plex server, saved like posters. Ticking one fetches it for both tabs now (a
// tool run with progress); later scans keep it up to date. Unticking only hides it.
function artworkTab(repaint) {
  const s = S.state.settings;
  const status = h('p', { class: 'art-status' });
  const anyTicked = () => !!(S.state.settings.artLogo || S.state.settings.artBackground || S.state.settings.artBanner);
  let refreshBtn = null;
  const tick = (key, label, note) => {
    const cb = h('input', { type: 'checkbox', checked: s[key] ? true : null });
    cb.addEventListener('change', async () => {
      try {
        await S.saveSettings({ [key]: cb.checked });
        if (refreshBtn) refreshBtn.disabled = !anyTicked();
        if (cb.checked) {
          await bridge.request('tools.start', { kind: 'artwork', tab: 'movies', rids: [] });
          S.state.tool = { kind: 'artwork', running: true, pct: 0, text: 'Starting...' }; S.notify('tool');
          status.textContent = 'Fetching from Plex now; progress shows under the bar. It appears as each library refreshes.';
        } else status.textContent = 'Hidden. The saved pictures stay in the cache.';
      } catch (e) { status.textContent = e.message; }
    });
    return h('div', { class: 'art-opt' }, h('label', null, cb, ' ', h('b', null, label)), h('small', null, note));
  };
  return [
    h('p', null, h('small', null, 'Pictures from your own Plex server, saved on this PC the same way posters are. Nothing comes from other sites. Plex does not have every picture for every title; those without one keep the usual look.')),
    tick('artLogo', 'Clear logos', 'Movies and TV Shows: the title logo instead of the title text on cards, the series view and Compare.'),
    tick('artBackground', 'Background art', 'Movies and TV Shows: the wide background picture replaces the plain background on cards, the series view and Compare.'),
    tick('artBanner', 'TV banners', 'TV Shows: wide banners for the Banners view (shows without one get their background art and logo instead).'),
    hr(),
    h('div', { class: 'art-opt' },
      h('div', null, h('button', { class: 'btn', type: 'button', onclick: async () => {
        await S.saveSettings({ posterScale: 100, tvScale: 100, clearScale: 100, bannerScale: 100 });
        status.textContent = 'All poster sizes are back to 100%.';
      } }, 'Reset to Defaults')),
      h('small', null, 'Poster size: Movies posters, TV posters, Clear logos and Banners each keep their own size. This puts all of them back to 100%.')),
    h('div', { class: 'art-opt' },
      h('div', null, refreshBtn = h('button', { class: 'btn', type: 'button', disabled: anyTicked() ? null : true, onclick: async () => {
        try {
          await bridge.request('tools.start', { kind: 'artwork', tab: 'movies', rids: [], force: true });
          S.state.tool = { kind: 'artwork', running: true, pct: 0, text: 'Starting...' }; S.notify('tool');
          status.textContent = 'Fetching everything again from Plex; progress shows under the bar.';
        } catch (e) { status.textContent = e.message; }
      } }, 'Refresh artwork')),
      h('small', null, 'Changed a banner, logo or background in Plex (or turned on its local assets)? This fetches every ticked picture again, so MMLM shows what Plex has now. It asks Plex once per picture, so a big library takes a few minutes.')),
    status,
  ];
}

// Fun: the Compare page's poster borders, animation and VS
const FX = [['auto', 'Auto'], ['fire', 'Fire'], ['lightning', 'Lightning'], ['specter', 'Specter'], ['poster', 'Poster colours'], ['off', 'Off']];
function funTab(repaint) {
  const s = S.state.settings;
  const set = (k, v) => S.saveSettings({ [k]: v }).then(repaint);
  const side = (key, label) => h('div', { class: 'fx-row' }, h('span', { class: 'fx-lbl' }, label),
    ...FX.map(([k, t]) => h('button', { type: 'button', class: `fx-opt${(s[key] || 'auto') === k ? ' on' : ''}`, 'aria-pressed': (s[key] || 'auto') === k ? 'true' : 'false', title: t, onclick: () => set(key, k) },
      h('span', { class: `fx-sw fx-${k === 'auto' ? 'poster' : k}`, style: { '--fx1': '#d6408c', '--fx2': '#8c50f0' } }), h('small', null, t))));
  const segBtns = (key, opts, def) => h('div', { class: 'seg' }, opts.map(([k, t]) => h('button', { type: 'button', class: (s[key] || def) === k ? 'active' : '', onclick: () => set(key, k) }, t)));
  const chk = (key, text) => h('p', null, h('label', null, h('input', { type: 'checkbox', checked: s[key] !== false ? true : null, onchange: (e) => set(key, e.target.checked) }), ' ' + text));
  return [
    h('p', null, h('b', null, 'Compare: poster borders '), h('small', null, "Auto picks from the poster's main colours: red or orange is fire, blue is lightning, green is the specter glow, anything else glows in the poster's own colours.")),
    h('div', { class: `fx-grid motion-${s.fxMotion || 'full'}` }, side('fxLeft', 'Left side'), side('fxRight', 'Right side')),
    hr(),
    h('p', null, h('b', null, 'Animation '), segBtns('fxMotion', [['still', 'Still'], ['calm', 'Calm'], ['full', 'Full']], 'full')),
    h('p', null, h('small', null, 'Still is used anyway when Windows is set to reduce animations.')),
    h('p', null, h('b', null, 'VS '), segBtns('vsStyle', [['arcade', 'Arcade'], ['plain', 'Plain'], ['off', 'Off']], 'arcade')),
    hr(),
    chk('cmpTally', 'Show the rounds won and the winner banner'),
    chk('cmpWalkover', 'Collections: a film with no opponent wins its round (walkover)'),
    chk('cmpImdb', 'Count the IMDb rating as a critics round'),
  ];
}

export function openSettings(tab, onClose) {
  if (tab) settingsTab = tab;
  overlay((close) => {
    const body = h('div', { class: 'settings-body', role: 'tabpanel' });
    const tabs = h('div', { class: 'seg settings-tabs', role: 'tablist', 'aria-label': 'Settings sections' });
    const paint = () => {
      tabs.replaceChildren(...[['general', 'General'], ['plex', 'Plex'], ['data', 'Data'], ['artwork', 'Artwork'], ['doctor', 'PlexDoctor'], ['fun', 'Fun']].map(([k, label]) => h('button', {
        type: 'button', role: 'tab', 'aria-selected': settingsTab === k ? 'true' : 'false', class: settingsTab === k ? 'active' : '',
        onclick: () => { settingsTab = k; try { localStorage.setItem(TAB_KEY, k); } catch (e) { /* ignore */ } paint(); } }, label)));
      body.replaceChildren(...(settingsTab === 'plex' ? plexTab(paint) : settingsTab === 'data' ? dataTab() : settingsTab === 'artwork' ? artworkTab(paint) : settingsTab === 'doctor' ? doctorTab(paint) : settingsTab === 'fun' ? funTab(paint) : generalTab(close, paint)));
    };
    paint();
    return h('div', null, h('h2', null, 'Settings'), tabs, body,
      h('p', { style: { textAlign: 'right' } }, h('button', { class: 'btn primary', type: 'button', onclick: close }, 'Done')));
  }, '', onClose);
}
