// Settings: the Sample's overlay with tabs. General (theme, updates), Plex (server and token), Data (sources, traffic).
import * as S from '../store.js';
import { h } from '../util.js';
import { openUpdate } from './update.js';
import { openTraffic } from './traffic.js';

// In-page overlay (no alert/confirm/prompt): Escape or a click outside closes it.
function overlay(content, extraClass = '') {
  const root = document.getElementById('overlay-root');
  const close = () => { root.replaceChildren(); document.removeEventListener('keydown', esc); };
  const esc = (e) => { if (e.key === 'Escape') close(); };
  document.addEventListener('keydown', esc);
  const o = h('div', { class: 'overlay', onclick: (e) => { if (e.target === o) close(); } }, h('div', { class: `card modal ${extraClass}` }, content(close)));
  root.replaceChildren(o);
  return close;
}
export { overlay };

const TAB_KEY = 'mmlm.settingsTab';
let settingsTab = 'general';
try { const v = localStorage.getItem(TAB_KEY); if (['general', 'plex', 'data'].includes(v)) settingsTab = v; } catch (e) { /* ignore */ }
const hr = () => h('hr', { style: { border: 0, borderTop: '1px solid var(--line)' } });

function generalTab(close, repaint) {
  const s = S.state.settings;
  return [
    S.inLauncher()
      ? h('p', null, h('b', null, 'Theme '), h('small', null, 'Follows DashLauncher.'))
      : h('p', null, h('b', null, 'Theme '),
        [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']].map(([t, label]) => h('button', { class: `btn ${s.theme === t ? 'primary' : ''}`, type: 'button', style: { marginRight: '6px' }, onclick: () => { S.saveSettings({ theme: t }); repaint(); } }, label))),
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
  return [
    h('p', null, h('b', null, 'Where the data comes from')),
    h('ul', null,
      h('li', null, 'Your Plex server: titles, file details and posters, when you scan.'),
      h('li', null, 'GitHub: the update check, only as set under General.'),
      h('li', null, 'TMDB, OMDb and IMDb ratings and box office: fetched by the window app (Fetch info) for now; they show here after the next scan.')),
    h('p', null, h('small', null, 'Nothing is fetched automatically. The live status button in the bar pauses all data traffic.')),
    h('p', null, h('button', { class: 'btn', type: 'button', onclick: () => openTraffic() }, 'Traffic details')),
  ];
}

export function openSettings(tab) {
  if (tab) settingsTab = tab;
  overlay((close) => {
    const body = h('div', { class: 'settings-body', role: 'tabpanel' });
    const tabs = h('div', { class: 'seg settings-tabs', role: 'tablist', 'aria-label': 'Settings sections' });
    const paint = () => {
      tabs.replaceChildren(...[['general', 'General'], ['plex', 'Plex'], ['data', 'Data']].map(([k, label]) => h('button', {
        type: 'button', role: 'tab', 'aria-selected': settingsTab === k ? 'true' : 'false', class: settingsTab === k ? 'active' : '',
        onclick: () => { settingsTab = k; try { localStorage.setItem(TAB_KEY, k); } catch (e) { /* ignore */ } paint(); } }, label)));
      body.replaceChildren(...(settingsTab === 'plex' ? plexTab(paint) : settingsTab === 'data' ? dataTab() : generalTab(close, paint)));
    };
    paint();
    return h('div', null, h('h2', null, 'Settings'), tabs, body,
      h('p', { style: { textAlign: 'right' } }, h('button', { class: 'btn primary', type: 'button', onclick: close }, 'Done')));
  });
}
