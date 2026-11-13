// Settings: the Sample's overlay with tabs. General (theme, updates), Plex (server and token), Data (sources, traffic),
// Artwork (clear logos, background art, TV banners from Plex), Compare (metrics, MediaInfo, Fun mode), Fun (Compare's
// borders and VS; shown only when Fun mode is on).
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { doctorTab } from './doctor.js';
import { h } from '../util.js';
import { openUpdate } from './update.js';
import { openTraffic } from './traffic.js';
import { chosen, openMetrics, MAX_SCORED } from '../metrics.js';
import { BASE_YEAR } from '../inflation.js';
import { ELEMENTS, tune, saveTune, resetTune, vsColors, VS_DEFAULT, startTabGlow, stopTabGlow, tabGlowLeft } from '../fxtune.js';

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
try { const v = localStorage.getItem(TAB_KEY); if (['general', 'plex', 'data', 'artwork', 'compare', 'doctor', 'fun'].includes(v)) settingsTab = v; } catch (e) { /* ignore */ }
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

// Servers: where each library comes from (Plex or Jellyfin), and each server's address and key.
function plexTab(repaint) {
  const p = S.state.plex, jf = p.jellyfin || {}, use = p.use || {};
  const name = (k) => (k === 'jellyfin' ? 'Jellyfin' : 'Plex');
  // which server each library comes from
  const choose = (tab) => {
    const cur = use[tab] || 'plex';
    return h('div', { class: 'seg' }, ['plex', 'jellyfin'].map((k) => h('button', { type: 'button', class: cur === k ? 'active' : '', onclick: async () => {
      if (k === cur) return;
      try { await S.useServer(tab, k); repaint(); S.toast(`${tab === 'tv' ? 'TV Shows' : 'Movies'} now come from ${name(k)}. Scan to read the library from it.`); } catch (e) { S.toast(e.message); }
    } }, name(k))));
  };
  const testLine = (kind) => {
    const out = h('small', { class: 'srv-test' });
    const btn = h('button', { class: 'btn', type: 'button', disabled: S.state.halted ? true : null, onclick: async () => {
      btn.disabled = true; out.textContent = 'Asking the server...';
      const off = bridge.on('servertest', (d) => {
        if (d.kind !== kind) return;
        off?.(); btn.disabled = false;
        out.textContent = d.ok ? `Connected to ${d.info.name}${d.info.version ? ' ' + d.info.version : ''}. Libraries: ${(d.info.libraries || []).map((l) => `${l.name} (${l.type === 'show' ? 'TV' : 'movies'})`).join(', ') || 'none'}.` : d.error;
      });
      try { await bridge.request('server.test', { kind }); } catch (e) { off?.(); btn.disabled = false; out.textContent = e.message; }
    } }, 'Test');
    return h('p', null, btn, ' ', out);
  };
  // Plex
  const url = h('input', { type: 'text', value: p.url || '', placeholder: 'http://plex-server:32400', spellcheck: 'false' });
  const tok = h('input', { type: 'password', value: '', placeholder: p.hasToken ? 'saved (type a new one to replace it)' : 'your Plex token', autocomplete: 'off' });
  const msg = h('small', null, '');
  const save = h('button', { class: 'btn primary', type: 'button', onclick: async () => {
    save.disabled = true; msg.textContent = 'Saving...';
    try { await S.savePlex(url.value.trim(), tok.value.trim()); tok.value = ''; msg.textContent = 'Saved.'; repaint(); }
    catch (e) { msg.textContent = e.message; }
    save.disabled = false;
  } }, 'Save');
  // Jellyfin
  const jurl = h('input', { type: 'text', value: jf.url || '', placeholder: 'http://jellyfin-server:8096', spellcheck: 'false' });
  const jkey = h('input', { type: 'password', value: '', placeholder: jf.hasKey ? 'saved (type a new one to replace it)' : 'an API key from Jellyfin', autocomplete: 'off' });
  const jmsg = h('small', null, '');
  const jsave = h('button', { class: 'btn primary', type: 'button', onclick: async () => {
    jsave.disabled = true; jmsg.textContent = 'Saving...';
    try { await S.saveJellyfin(jurl.value.trim(), jkey.value.trim()); jkey.value = ''; jmsg.textContent = 'Saved.'; repaint(); }
    catch (e) { jmsg.textContent = e.message; }
    jsave.disabled = false;
  } }, 'Save');
  return [
    h('p', null, h('small', null, 'Each library is read from your own server, only when you scan (the circular arrow in the bar, or F5). Tokens and keys are stored encrypted for your Windows account.')),
    h('div', { class: 'form-row' }, h('label', null, 'Movies come from'), choose('movies')),
    h('div', { class: 'form-row' }, h('label', null, 'TV Shows come from'), choose('tv')),
    h('p', null, h('small', null, 'Switching reads the whole library from the other server at the next scan. Collections keep titles by their server id, so titles added from the other server need adding again.')),
    hr(),
    h('p', null, h('b', null, 'Plex')),
    h('div', { class: 'form-row' }, h('label', null, 'Server address'), url),
    h('div', { class: 'form-row' }, h('label', null, 'Token'), tok),
    h('p', null, save, ' ', msg),
    p.url && p.hasToken ? testLine('plex') : null,
    hr(),
    h('p', null, h('b', null, 'Jellyfin '), h('small', null, 'Make an API key in Jellyfin: Dashboard > API Keys > +.')),
    h('div', { class: 'form-row' }, h('label', null, 'Server address'), jurl),
    h('div', { class: 'form-row' }, h('label', null, 'API key'), jkey),
    h('p', null, jsave, ' ', jmsg),
    jf.url && jf.hasKey ? testLine('jellyfin') : null,
    hr(),
    h('p', null, h('b', null, 'Scan '), h('small', null, 'A scan reuses titles the server has not changed. A full rescan reads every title again.')),
    h('p', null, ...S.TABS.map((t) => h('button', { class: 'btn', type: 'button', style: { marginRight: '6px' }, disabled: S.state.scan.running || S.state.halted ? true : null,
      onclick: () => S.startScan(t, true).catch((e) => { msg.textContent = e.message; }) }, `Full rescan of ${t === 'tv' ? 'TV Shows' : 'Movies'}`))),
    timingRow(),
  ];
}

// How long each stage of the last scan took, to copy into a message when a scan feels slow.
function timingRow() {
  const out = h('pre', { class: 'scan-times', hidden: true });
  const note = h('small', null, '');
  const btn = h('button', { class: 'btn', type: 'button', onclick: async () => {
    let text = '';
    try { const r = await bridge.request('scan.timing'); text = [r.movies, r.tv].filter(Boolean).join('\n').trim(); } catch (e) { note.textContent = e.message; return; }
    if (!text) { note.textContent = 'No scan has finished yet.'; return; }
    out.textContent = text; out.hidden = false;
    try { await navigator.clipboard.writeText(text); note.textContent = 'Copied.'; }
    catch { const r = document.createRange(); r.selectNodeContents(out); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); note.textContent = 'Press Ctrl+C to copy.'; }
  } }, 'Copy timings');
  return h('div', null, h('p', null, h('b', null, 'Last scan timings '), h('small', null, 'How long each stage of the last scan took.')), h('p', null, btn, ' ', note), out);
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

// Compare (Movies > Compare): what is compared, MediaInfo for brightness, and Fun mode
function compareTab(repaint) {
  const s = S.state.settings;
  const set = (k, v) => S.saveSettings({ [k]: v }).then(repaint);
  const chk = (key, text, def = true) => h('p', null, h('label', null, h('input', { type: 'checkbox', checked: (def ? s[key] !== false : !!s[key]) ? true : null, onchange: (e) => set(key, e.target.checked) }), ' ' + text));
  const field = (key, label, ph) => h('label', { class: 'mi-field' }, h('small', null, label),
    h('input', { type: 'text', value: s[key] || '', placeholder: ph, spellcheck: 'false', onchange: (e) => S.saveSettings({ [key]: e.target.value.trim() }).then(paintStatus).catch((x) => S.toast(x.message)) }));
  const status = h('div', { class: 'mi-status' }, h('small', null, 'Looking for MediaInfo...'));
  const run = h('div', { class: 'mi-run' });
  const paintRun = () => {
    const d = S.state.miRun;
    run.replaceChildren(d && d.running ? h('p', null, h('small', null, `${d.text} (${d.pct}%) `), h('button', { class: 'btn', type: 'button', onclick: () => S.cancelMediaInfo() }, 'Stop')) : '');
  };
  async function paintStatus() {
    try {
      const st = await S.mediaInfoStatus();
      const last = st.lastRun ? `Last library read ${st.lastRun}: ` : 'The library has not been read yet. So far: ';
      status.replaceChildren(
        h('p', null, h('b', null, st.found ? `Found${st.version ? ` · v${st.version}` : ''}` : 'Not found')),
        h('p', null, h('small', null, st.found
          ? `${last}${st.read.toLocaleString('en-US')} movie${st.read === 1 ? '' : 's'} read${st.unreachable ? `, ${st.unreachable.toLocaleString('en-US')} not reachable from this PC` : ''}${st.failed ? `, ${st.failed} could not be read` : ''}.`
          : 'MMLM uses the MediaInfo command-line program already on this PC; it never downloads it. Install it (for example: winget install MediaArea.MediaInfo), put MediaInfo.exe in the lib folder beside the app, or give its location below.')),
        st.found ? h('p', null,
          h('button', { class: 'btn', type: 'button', disabled: st.running || S.state.miRun?.running ? true : null, onclick: () => S.readMediaInfo([], false).then(() => S.toast('MediaInfo is reading your movies. New and changed files only.')).catch((e) => S.toast(e.message)) }, 'Read all movies with MediaInfo'), ' ',
          h('button', { class: 'btn', type: 'button', disabled: st.running || S.state.miRun?.running ? true : null, onclick: () => S.readMediaInfo([], true).then(() => S.toast('MediaInfo is reading every movie again.')).catch((e) => S.toast(e.message)) }, 'Read every file again')) : null);
    } catch (e) { status.replaceChildren(h('small', null, e.message)); }
  }
  paintStatus(); paintRun();
  const off = S.subscribe((t) => { if (!status.isConnected) { off?.(); return; } if (t.has('mediainfo')) { paintRun(); if (!S.state.miRun?.running) paintStatus(); } });
  const { scored, info } = chosen();
  return [
    h('p', null, h('small', null, 'Movies > Compare puts two movies (or two collections) side by side. The default look is plain, for sharing; Fun mode adds the effects.')),
    h('p', null, h('b', null, 'Metrics '), h('button', { class: 'btn', type: 'button', onclick: () => openMetrics(repaint) }, 'Choose metrics...'),
      h('small', null, ` ${scored.length} of ${MAX_SCORED} scored: ${scored.map((d) => d.k).join(', ') || 'none'}${info.length ? `. For information: ${info.map((d) => d.k).join(', ')}` : ''}.`)),
    chk('cmpInflation', `Box office in ${BASE_YEAR} dollars (adjusted for inflation)`, false),
    chk('cmpTally', 'Show the score and the winner line'),
    chk('cmpWalkover', 'Collections: a film with no opponent wins its round (walkover)'),
    hr(),
    h('p', null, h('b', null, 'MediaInfo '), h('small', null, 'Brightness (MaxCLL and MaxFALL) is not in Plex; MediaInfo reads it from the file. Comparing two movies reads just those two; reading the library fills in every movie ahead of time, in the background. Only files this PC can reach, and nothing goes online.')),
    status, run,
    h('div', { class: 'mi-grid' },
      field('miPath', 'MediaInfo location (optional)', 'C:\\Tools\\MediaInfo\\MediaInfo.exe'),
      field('miFrom', 'Path on the server', '/data/movies'),
      field('miTo', 'Same folder on this PC', '\\\\NAS\\movies')),
    h('p', null, h('small', null, 'Plex on another computer? Give the start of its movie paths and where this PC finds the same folder, so MediaInfo can open the files.')),
    hr(),
    h('p', null, h('label', { class: 'fun-chk' }, h('input', { type: 'checkbox', checked: s.cmpFun ? true : null, onchange: (e) => { if (e.target.checked) startTabGlow(); else stopTabGlow(); set('cmpFun', e.target.checked); } }), h('b', null, ' Fun mode')),
      h('small', null, ' Compare becomes Versus: the fiery VS, glowing posters and the skull bar. Their settings are in the Versus tab, which appears while this is on.')),
  ];
}

// Versus (Fun mode): the Compare page's poster borders, animation, the VS and its colours, and every effect's size and intensity
const FX = [['auto', 'Auto'], ['fire', 'Fire'], ['water', 'Water'], ['specter', 'Spectral'], ['lightning', 'Lightning'], ['nature', 'Nature'], ['poster', 'Poster colours'], ['off', 'Off']];
function funTab(repaint) {
  const s = S.state.settings;
  const set = (k, v) => S.saveSettings({ [k]: v }).then(repaint);
  const side = (key, label) => h('div', { class: 'fx-row' }, h('span', { class: 'fx-lbl' }, label),
    ...FX.map(([k, t]) => h('button', { type: 'button', class: `fx-opt${(s[key] || 'auto') === k ? ' on' : ''}`, 'aria-pressed': (s[key] || 'auto') === k ? 'true' : 'false', title: t, onclick: () => set(key, k) },
      h('span', { class: `fx-sw fx-${k === 'auto' ? 'poster' : k}`, style: { '--fx1': '#d6408c', '--fx2': '#8c50f0' } }), h('small', null, t))));
  const segBtns = (key, opts, def) => h('div', { class: 'seg' }, opts.map(([k, t]) => h('button', { type: 'button', class: (s[key] || def) === k ? 'active' : '', onclick: () => set(key, k) }, t)));
  return [
    h('p', null, h('b', null, 'Compare: poster borders '), h('small', null, "Auto picks from the poster's main colours: red or orange is fire, deep blue is water, pale blue or white is lightning, green is spectral, brown or olive is nature; anything else glows in the poster's own colours. The skulls and the bar take the same theme.")),
    h('div', { class: `fx-grid motion-${s.fxMotion || 'full'}` }, side('fxLeft', 'Left side'), side('fxRight', 'Right side')),
    hr(),
    h('p', null, h('b', null, 'Animation '), segBtns('fxMotion', [['still', 'Still'], ['calm', 'Calm'], ['full', 'Full']], 'full')),
    h('p', null, h('small', null, 'Still is used anyway when Windows is set to reduce animations.')),
    h('p', null, h('b', null, 'VS '), segBtns('vsStyle', [['arcade', 'Arcade'], ['plain', 'Plain'], ['off', 'Off']], 'arcade')),
    h('p', null, h('b', null, 'VS colours '), h('small', null, 'Top, middle and base of the burning VS: pick a colour or type its hex code.')),
    h('div', { class: 'vs-cols' }, vsColors().map((c, i) => {
      const save = (v) => { if (!/^#[0-9a-f]{6}$/i.test(v)) return; const cols = vsColors().slice(); cols[i] = v.toLowerCase(); S.saveSettings({ vsColors: cols }).then(repaint); };
      const name = ['Top', 'Middle', 'Base'][i];
      return h('label', { class: 'vs-col' }, h('input', { type: 'color', value: c, 'aria-label': `${name} colour`, onchange: (e) => save(e.target.value) }),
        h('input', { type: 'text', value: c, maxlength: '7', spellcheck: 'false', 'aria-label': `${name} colour hex code`, onchange: (e) => { const v = e.target.value.trim(); save(v.startsWith('#') ? v : '#' + v); } }), h('small', null, name));
    }), h('button', { class: 'btn', type: 'button', onclick: () => S.saveSettings({ vsColors: VS_DEFAULT.slice() }).then(repaint) }, 'Fire colours')),
    hr(),
    h('p', null, h('b', null, 'Effects '), h('small', null, 'Size is how big or far it reaches; intensity is how bright and busy it is. 50 is the normal look.')),
    tuneTable(repaint),
    h('p', null, h('button', { class: 'btn', type: 'button', onclick: () => resetTune().then(repaint) }, 'Reset effects to defaults'),
      h('small', null, ' Puts every effect, and the VS colours, back to how they started.')),
  ];
}

function tuneTable(repaint) {
  const t = tune();
  const slider = (k, f, label) => h('div', { class: 'sl' },
    h('input', { type: 'range', min: '0', max: '100', step: '5', value: String(t[k][f]), disabled: t[k].on ? null : true, 'aria-label': `${label} ${f === 'size' ? 'size' : 'intensity'}`,
      oninput: (e) => { e.target.nextSibling.textContent = e.target.value; }, onchange: (e) => saveTune(k, f, +e.target.value).then(repaint) }),
    h('small', null, String(t[k][f])));
  return h('div', { class: 'fx-tune' }, h('span', { class: 'hd' }, 'Element'), h('span', { class: 'hd' }, 'On'), h('span', { class: 'hd' }, 'Size'), h('span', { class: 'hd' }, 'Intensity'),
    ...ELEMENTS.flatMap(([k, label, tip]) => [
      h('span', { title: tip }, label),
      h('input', { type: 'checkbox', checked: t[k].on ? true : null, 'aria-label': `${label} on`, onchange: (e) => saveTune(k, 'on', e.target.checked).then(repaint) }),
      slider(k, 'size', label), slider(k, 'int', label)]));
}

let glowTimer = 0;
export function openSettings(tab, onClose) {
  if (tab) settingsTab = tab;
  overlay((close) => {
    const body = h('div', { class: 'settings-body', role: 'tabpanel' });
    const tabs = h('div', { class: 'seg settings-tabs', role: 'tablist', 'aria-label': 'Settings sections' });
    const paint = () => {
      if (settingsTab === 'fun' && !S.state.settings.cmpFun) settingsTab = 'compare';
      const list = [['general', 'General'], ['plex', 'Servers'], ['data', 'Data'], ['artwork', 'Artwork'], ['compare', 'Compare'], ['doctor', 'PlexDoctor']];
      if (S.state.settings.cmpFun) list.push(['fun', 'Versus']);
      if (settingsTab === 'fun') stopTabGlow();                  // seen: the Versus tab goes back to white
      const hot = tabGlowLeft();
      clearTimeout(glowTimer); if (hot > 0) glowTimer = setTimeout(() => { if (tabs.isConnected) paint(); }, hot + 50);
      tabs.replaceChildren(...list.map(([k, label]) => h('button', {
        type: 'button', role: 'tab', 'aria-selected': settingsTab === k ? 'true' : 'false', class: `${settingsTab === k ? 'active' : ''}${k === 'fun' && hot > 0 ? ' tab-hot' : ''}`,
        onclick: () => { settingsTab = k; try { localStorage.setItem(TAB_KEY, k); } catch (e) { /* ignore */ } paint(); } }, label)));
      body.replaceChildren(...(settingsTab === 'plex' ? plexTab(paint) : settingsTab === 'data' ? dataTab() : settingsTab === 'artwork' ? artworkTab(paint) : settingsTab === 'doctor' ? doctorTab(paint) : settingsTab === 'fun' ? funTab(paint) : settingsTab === 'compare' ? compareTab(paint) : generalTab(close, paint)));
    };
    paint();
    return h('div', null, h('h2', null, 'Settings'), tabs, body,
      h('p', { style: { textAlign: 'right' } }, h('button', { class: 'btn primary', type: 'button', onclick: close }, 'Done')));
  }, '', onClose);
}
