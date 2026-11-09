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
export function tileHtml({ key, poster, title, sub, res, hdr, rating }) {
  return `<button class="pc" type="button" data-k="${esc(key)}"><div class="pimg">${poster}`
    + `<div class="badges">${res ? `<span class="b">${esc(res)}</span>` : ''}${hdr && hdr !== 'SDR' ? `<span class="b b-hdr">${esc(hdr)}</span>` : ''}</div>`
    + (num(rating) > 0 ? `<div class="rt">★ ${num(rating).toFixed(1)}</div>` : '') + `</div>`
    + `<div class="pt" title="${esc(title)}">${esc(title)}</div><div class="ps">${esc(sub)}</div></button>`;
}
// Search: every word must appear somewhere in the title, show, genre, cast, studio, director, year or collection.
export function matchQuery(rows, q) {
  const terms = String(q || '').toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return rows;
  return rows.filter((r) => terms.every((t) => r._search.includes(t)));
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
