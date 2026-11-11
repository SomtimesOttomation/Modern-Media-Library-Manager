// Formatting and small pieces shared by the library, TV, stats and card views (from the old dashboard page).
export const num = (x) => { const n = +x; return Number.isFinite(n) ? n : 0; };
export const v = (x, d) => (x === undefined || x === null || x === '' ? d : x);
export const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const fmtInt = (n) => Math.round(n).toLocaleString();
export const fmtMoney = (n) => { n = +n || 0; if (n <= 0) return ''; if (n >= 1e9) return '$' + (n / 1e9).toFixed(2) + 'B'; if (n >= 1e6) return '$' + (n / 1e6).toFixed(n >= 1e8 ? 0 : 1) + 'M'; return '$' + Math.round(n).toLocaleString(); };
export const fmtSize = (gb) => { gb = num(gb); return gb >= 1000 ? (gb / 1000).toFixed(2) + ' TB' : gb.toFixed(gb >= 100 ? 0 : 1) + ' GB'; };
export const fmtHMS = (min) => { const t = Math.round(num(min) * 60); return Math.floor(t / 3600) + ':' + String(Math.floor(t % 3600 / 60)).padStart(2, '0') + ':' + String(t % 60).padStart(2, '0'); };
// Library-scale runtime: "1y 28d 7h 53m" (leading zero units dropped; a year is 365 days)
export const fmtRun = (min) => {
  let t = Math.round(num(min) * 60);
  const y = Math.floor(t / 31536000); t -= y * 31536000;
  const d = Math.floor(t / 86400); t -= d * 86400;
  const hr = Math.floor(t / 3600); t -= hr * 3600;
  const m = Math.floor(t / 60);
  const parts = [[y, 'y'], [d, 'd'], [hr, 'h'], [m, 'm']];
  const first = parts.findIndex((p) => p[0] > 0);
  return (first < 0 ? [[0, 'm']] : parts.slice(first)).map((p) => p[0] + p[1]).join(' ');
};
export function hdrLabel(r) {
  const t = v(r.HDRType, 'SDR');
  if (t === 'Dolby Vision' && r.DVProfile) return 'DV P' + r.DVProfile + (r.DVLayer === 'FEL' || r.DVLayer === 'MEL' ? ' ' + r.DVLayer : '');
  return t;
}
export function posterHtml(r, title) {
  return r.Poster ? `<img loading="lazy" decoding="async" src="${esc(r.Poster)}" alt="">` : `<div class="ph">${esc(title || r.Title)}</div>`;
}
// One poster tile. data-k is the row index (movies) or the show name (TV).
// Poster scores: the Rotten Tomatoes critics score (tomato or splat) and the Metacritic square; the IMDb star only when
// neither is known.
const TOM = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="9.2" r="6.4" fill="#E63428"/><path d="M8 5 4.8 2.2 8 3.2 11.4 1.4 10 5z" fill="#46AA46"/></svg>';
const SPL = '<svg viewBox="0 0 16 16" aria-hidden="true"><g fill="#70A82C"><ellipse cx="8" cy="10" rx="6.6" ry="4.4"/><circle cx="8" cy="6" r="4"/><circle cx="2.4" cy="12.6" r="2.2"/><circle cx="13.6" cy="12" r="2.2"/></g></svg>';
function scoreBadges(rt, mcScore, rating) {
  const out = [];
  if (num(rt) > 0) out.push(`<span class="sb-rt" title="Rotten Tomatoes critics">${num(rt) >= 60 ? TOM : SPL}${Math.round(num(rt))}%</span>`);
  if (num(mcScore) > 0) { const n = Math.round(num(mcScore)), c = n >= 61 ? 'g' : n >= 40 ? 'y' : 'r'; out.push(`<span class="sb-mc ${c}" title="Metacritic">${n}</span>`); }
  if (!out.length && num(rating) > 0) out.push(`<span class="sb-im" title="IMDb rating">\u2605 ${num(rating).toFixed(1)}</span>`);
  return out.length ? `<div class="scores">${out.join('')}</div>` : '';
}
// cm: undefined = no Collection mode; false = a + to pick it; true = picked (a tick)
export function tileHtml({ key, poster, title, sub, res, hdr, rating, rt, mcScore, cm }) {
  const plus = cm === undefined ? '' : `<span class="cm-add${cm ? ' on' : ''}" role="button" tabindex="0" data-cm="1" title="${cm ? 'Picked: click to drop it' : 'Add to the collection'}">${cm ? '\u2713' : '+'}</span>`;
  return `<button class="pc${cm ? ' picked' : ''}" type="button" data-k="${esc(key)}"><div class="pimg">${poster}${plus}`
    + `<div class="badges">${res ? `<span class="b">${esc(res)}</span>` : ''}${hdr && hdr !== 'SDR' ? `<span class="b b-hdr">${esc(hdr)}</span>` : ''}</div>`
    + scoreBadges(rt, mcScore, rating) + `</div>`
    + `<div class="pt" title="${esc(title)}">${esc(title)}</div><div class="ps">${esc(sub)}</div></button>`;
}
// Search (see search.js): returns the matching rows and the chips that say what the query was read as.
import { parse, filterRows } from './search.js';
export function searchRows(rows, q, L, collections) {
  const p = parse(q, L, collections);
  return { rows: filterRows(rows, p), chips: p.chips, tab: p.tab };
}
// "Showing: 1990s - Comedy series" under the title, so a smart search never surprises
export function chipsHtml(chips) {
  return chips.length ? `<div class="qchips" title="How the search was read"><span>Showing:</span>${chips.map((c) => `<b>${esc(c)}</b>`).join('')}</div>` : '';
}
/* One title can be in the library several times (a 4K and a 1080p copy). The key is the IMDb id, else the TMDB id, else
   title + year; the copy kept is the biggest file, so the best-quality one stands in for the rest. */
export function dupKey(r) {
  if (r.IMDBID) return 'i' + r.IMDBID;
  if (r.TMDBID) return 't' + r.TMDBID;
  return 'n' + String(r.Title).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim() + '|' + (r.Year || '');
}
export function dedupe(rows) {
  const best = new Map();
  rows.forEach((r) => { const k = dupKey(r), o = best.get(k); if (!o || num(r.FileSizeGB) > num(o.FileSizeGB)) best.set(k, r); });
  return rows.filter((r) => best.get(dupKey(r)) === r);
}
// Infinite poster wall: draws the first batch and adds more as the end comes into view.
export function fillWall(wall, items, render, batch = 90) {
  let shown = 0, io = null;
  const more = () => {
    const next = items.slice(shown, shown + batch);
    shown += next.length;
    wall.insertAdjacentHTML('beforeend', next.map(render).join(''));
    if (shown >= items.length && io) { io.disconnect(); sentinel.remove(); }
  };
  wall.innerHTML = '';
  const sentinel = document.createElement('div'); sentinel.className = 'wall-more';
  more();
  if (shown < items.length) {
    wall.after(sentinel);
    io = new IntersectionObserver((e) => { if (e.some((x) => x.isIntersecting)) more(); }, { rootMargin: '900px' });
    io.observe(sentinel);
  }
  return () => { if (io) io.disconnect(); sentinel.remove(); };
}

/* Sort By: a button with a menu (a <select> cannot tell when the same option is picked again). Picking the current
   option flips its direction; the arrow shows which way it runs. */
export function sortMenu(sorts, key, rev, onPick) {
  const cur = sorts.find((x) => x[0] === key) || sorts[0];
  const wrap = document.createElement('div'); wrap.className = 'sortbtn';
  const arrow = (k) => (k === cur[0] ? (rev ? ' ↑' : ' ↓') : '');
  wrap.innerHTML = `<button type="button" aria-haspopup="menu" aria-expanded="false" title="Sort by (pick it again to reverse)">Sort: ${esc(cur[1])}<span aria-hidden="true">${rev ? '↑' : '↓'}</span></button>`;
  const btn = wrap.firstChild;
  let menu = null;
  const close = () => { menu?.remove(); menu = null; btn.setAttribute('aria-expanded', 'false'); document.removeEventListener('mousedown', outside, true); document.removeEventListener('keydown', escKey, true); };
  const outside = (e) => { if (!wrap.contains(e.target)) close(); };
  const escKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); btn.focus(); } };
  btn.addEventListener('click', () => {
    if (menu) { close(); return; }
    menu = document.createElement('div'); menu.className = 'sortmenu card'; menu.setAttribute('role', 'menu');
    menu.innerHTML = sorts.map(([k, label]) => `<button type="button" role="menuitem" data-k="${k}" class="${k === cur[0] ? 'on' : ''}">${esc(label)}<small>${k === cur[0] ? (rev ? 'reversed' + arrow(k) : 'click to reverse' + arrow(k)) : ''}</small></button>`).join('');
    menu.addEventListener('click', (e) => { const b = e.target.closest('button[data-k]'); if (!b) return; close(); onPick(b.dataset.k, b.dataset.k === cur[0] ? !rev : false); });
    wrap.append(menu); btn.setAttribute('aria-expanded', 'true');
    document.addEventListener('mousedown', outside, true); document.addEventListener('keydown', escKey, true);
    menu.querySelector('.on')?.focus();
  });
  return wrap;
}

// Settings > Artwork: the clear logo instead of the title text, and background art behind a title's page.
// Both only when ticked and saved for that title; otherwise the plain title and the usual background.
import * as S from './store.js';
export function logoOrTitle(r, title, tag = 'h2') {
  const t = esc(title);
  return S.state.settings.artLogo && r && r.Logo ? `<${tag} class="has-logo"><img class="clearlogo" src="${esc(r.Logo)}" alt="${t}" title="${t}"></${tag}>` : `<${tag}>${t}</${tag}>`;
}
export const artUrl = (r) => (S.state.settings.artBackground && r && r.Art ? r.Art : '');
