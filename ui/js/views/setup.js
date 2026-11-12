// First-run setup: shown when no media server is set up yet. Screen 1 picks Jellyfin or Plex, screen 2 asks for that
// server's address and key, saves it, points both libraries at it and checks the connection. Nothing is fetched until
// the person clicks Connect (dash contract: no third-party traffic by default; this is their own server).
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { h } from '../util.js';
import { overlay } from './settings.js';

const KINDS = {
  jellyfin: { name: 'Jellyfin', label: 'Jellyfin Media System', keyName: 'API key', keyHint: 'In Jellyfin: Dashboard > API Keys > +, then copy the key.', placeholder: 'http://jellyfin-server:8096' },
  plex: { name: 'Plex', label: 'Plex Media Server', keyName: 'Token', keyHint: 'Your Plex token (X-Plex-Token).', placeholder: 'http://plex-server:32400',
          help: 'https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/' },
};

// True when neither server has an address and key saved: the first launch, or settings that were cleared.
export function needsSetup() {
  const p = S.state.plex || {}, jf = p.jellyfin || {};
  return !(p.url && p.hasToken) && !(jf.url && jf.hasKey);
}

export function openSetup() {
  let pick = '';
  overlay((close) => {
    const box = h('div', { class: 'setup' });
    const later = () => h('button', { class: 'setup-later', type: 'button', onclick: close }, 'Set up later');

    function chooser() {
      const go = h('button', { class: 'setup-go', type: 'button', disabled: pick ? null : true, onclick: () => details() }, 'GO');
      const tile = (k) => {
        const t = h('button', { type: 'button', class: `setup-tile ${pick === k ? 'on' : ''}`, role: 'radio', 'aria-checked': String(pick === k), 'data-kind': k,
          onclick: () => { pick = k; box.querySelectorAll('.setup-tile').forEach((x) => { const on = x.dataset.kind === k; x.classList.toggle('on', on); x.setAttribute('aria-checked', String(on)); }); go.disabled = false; } },
          h('span', { class: `setup-art ${k}` }, h('span', null, KINDS[k].name)),
          h('span', { class: 'setup-name' }, KINDS[k].label),
          h('span', { class: 'setup-dot' }));
        return t;
      };
      box.replaceChildren(
        h('h2', null, 'Select your preference'),
        h('p', { class: 'setup-sub' }, 'Which media server holds your movies and TV shows? You can change this later in Settings > Servers.'),
        h('div', { class: 'setup-tiles', role: 'radiogroup' }, tile('jellyfin'), tile('plex')),
        h('div', { class: 'setup-foot' }, go),
        later());
    }

    function details() {
      const k = KINDS[pick];
      const url = h('input', { type: 'text', placeholder: k.placeholder, spellcheck: 'false' });
      const key = h('input', { type: 'password', placeholder: k.keyName, autocomplete: 'off' });
      const out = h('p', { class: 'setup-msg' });
      const done = h('div', { class: 'setup-foot' });
      const connect = h('button', { class: 'setup-go', type: 'button', onclick: async () => {
        connect.disabled = true; out.className = 'setup-msg'; out.textContent = 'Saving...';
        try {
          if (pick === 'jellyfin') await S.saveJellyfin(url.value.trim(), key.value.trim());
          else await S.savePlex(url.value.trim(), key.value.trim());
          for (const tab of S.TABS) await S.useServer(tab, pick);
        } catch (e) { out.className = 'setup-msg bad'; out.textContent = e.message; connect.disabled = false; return; }
        out.textContent = `Asking ${k.name}...`;
        const off = bridge.on('servertest', (d) => {
          if (d.kind !== pick) return;
          off?.(); connect.disabled = false;
          if (!d.ok) { out.className = 'setup-msg bad'; out.textContent = `Saved, but ${k.name} did not answer: ${d.error}`; return; }
          const libs = (d.info.libraries || []).map((l) => `${l.name} (${l.type === 'show' ? 'TV' : 'movies'})`).join(', ') || 'none';
          out.className = 'setup-msg good'; out.textContent = `Connected to ${d.info.name}${d.info.version ? ' ' + d.info.version : ''}. Libraries: ${libs}.`;
          done.replaceChildren(h('button', { class: 'setup-go', type: 'button', onclick: () => { close(); scanBoth(); } }, 'Scan my library'));
        });
        try { await bridge.request('server.test', { kind: pick }); } catch (e) { off?.(); connect.disabled = false; out.className = 'setup-msg bad'; out.textContent = e.message; }
      } }, 'Connect');
      done.append(connect);
      box.replaceChildren(
        h('h2', null, `Connect to ${k.name}`),
        h('div', { class: 'setup-form' },
          h('label', null, 'Server address', url),
          h('label', null, k.keyName, key),
          h('small', null, k.keyHint, k.help ? ' ' : '', k.help ? h('a', { href: '#', onclick: (e) => { e.preventDefault(); S.openUrl(k.help); } }, 'How to find it') : ''),
          h('small', null, 'Stored encrypted for your Windows account. MMLM only talks to this server when you scan.')),
        out, done,
        h('div', { class: 'setup-row' }, h('button', { class: 'setup-later', type: 'button', onclick: chooser }, 'Back'), later()));
      url.focus();
    }

    chooser();
    return box;
  }, 'setup-host');
}

// Movies first, then TV Shows once the first scan finishes.
function scanBoth() {
  const queue = [...S.TABS];
  const next = () => { const tab = queue.shift(); if (tab) S.startScan(tab).catch((e) => S.toast(e.message)); };
  let was = false;
  const unsub = S.subscribe((t) => {
    if (!t.has('scan')) return;
    const run = S.state.scan.running;
    if (was && !run) { if (queue.length) next(); else unsub(); }
    was = run;
  });
  next();
}
