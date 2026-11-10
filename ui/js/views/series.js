// The series view (#/tv/<show>): Plex-style page for one show. Season strip, a raised info card, episode stills with
// watched marks, cast and related shows. The background is a gradient from the open season's poster colours, with
// white text. Library data shows straight away; the Plex details (stills, watched marks, cast, related) come from your
// Plex server the first time the show is opened, then from the saved copy until you press Refresh.
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { h } from '../util.js';
import { esc, num, fmtSize, fmtRun, hdrLabel } from '../common.js';
import { openCard, showSummary } from './card.js';
import { addToCollection } from './collections.js';

const cacheUrl = (p) => (p ? (bridge.isHost ? 'https://mmlm.cache/' : '') + p : '');
const plexByShow = new Map();          // show -> data from Plex (kept while the page is open)
const colourCache = new Map();         // poster path -> [c1, c2, c3]

// ---- colours: the poster's dominant and second colours, darkened so white text stays readable ----------------
function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b); let hh = 0, s = 0; const l = (mx + mn) / 2;
  if (mx !== mn) { const d = mx - mn; s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn); hh = mx === r ? (g - b) / d + (g < b ? 6 : 0) : mx === g ? (b - r) / d + 2 : (r - g) / d + 4; hh /= 6; }
  return [hh * 360, s, l];
}
const hsl = (hh, s, l) => `hsl(${Math.round(hh)} ${Math.round(Math.min(s, 0.7) * 100)}% ${Math.round(l * 100)}%)`;
async function posterColours(src) {
  if (!src) return null;
  if (colourCache.has(src)) return colourCache.get(src);
  let data = src;
  if (!/^data:/.test(src)) {
    // the cache is another origin: ask the backend for the picture's bytes so the canvas may read them
    const rel = src.replace(/^https:\/\/mmlm\.cache\//, '');
    try { data = await bridge.request('image.data', { path: rel }); } catch { data = null; }
    if (!data) return null;
  }
  const img = await new Promise((ok) => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => ok(null); i.src = data; });
  if (!img) return null;
  const c = document.createElement('canvas'); c.width = 24; c.height = 36;
  const g = c.getContext('2d'); g.drawImage(img, 0, 0, 24, 36);
  const px = g.getImageData(0, 0, 24, 36).data;
  // group the pixels by hue (24-degree buckets), weighting colourful pixels more; greys and near-black/white are skipped
  const buckets = new Map();
  for (let i = 0; i < px.length; i += 4) {
    const [hh, sat, l] = rgbToHsl(px[i], px[i + 1], px[i + 2]);
    if (l < 0.08 || l > 0.94 || sat < 0.15) continue;
    const k = Math.round(hh / 24) % 15;
    const bk = buckets.get(k) || { w: 0, n: 0, s: 0 }; bk.w += 1 + sat * 2; bk.n += 1; bk.s += sat; buckets.set(k, bk);
  }
  const top = [...buckets.entries()].sort((x, y) => y[1].w - x[1].w);
  let out;
  if (!top.length) out = ['hsl(220 12% 26%)', 'hsl(220 12% 15%)', 'hsl(220 12% 9%)'];
  else {
    const [ka, a] = top[0], [kb, b] = top[1] || top[0];
    const sa = a.s / a.n, sb = b.s / b.n;
    out = [hsl(ka * 24, Math.max(0.35, sa), 0.30), hsl(ka * 24, Math.max(0.3, sa), 0.17), hsl(kb * 24, Math.max(0.25, sb), 0.10)];
  }
  colourCache.set(src, out);
  return out;
}

// ---- page -----------------------------------------------------------------------------------------------------
function starHtml(rating10) {
  const n = num(rating10) / 2;
  return `<span class="stars" title="${rating10 ? num(rating10).toFixed(1) + ' / 10' : 'Not rated'}">${[1, 2, 3, 4, 5].map((i) => `<i class="${n >= i - 0.25 ? 'on' : n >= i - 0.75 ? 'half' : ''}">★</i>`).join('')}</span>`;
}

export function mount(ctx) {
  const name = ctx.arg;
  const L = S.state.libs.tv;
  const state = { season: null, fetching: false, pct: 0, text: '', error: '' };
  const root = h('div', { class: 'series' });
  ctx.el.replaceChildren(root);
  document.body.classList.add('series-open');

  const eps = () => L.rows.filter((r) => (r.Show || r.Title) === name);
  const draw = async () => {
    const local = eps();
    if (L.status !== 'ready') { root.innerHTML = '<div class="state"><h2>Opening TV Shows...</h2></div>'; return; }
    if (!local.length) { root.innerHTML = `<div class="state"><h2>${esc(name)}</h2><p>This show is not in your library (any more).</p><p><a class="btn" href="#/tv">Back to TV Shows</a></p></div>`; return; }
    const sum = showSummary(local);
    const P = plexByShow.get(name);
    // seasons: Plex's list when we have it (posters, watched counts), else the library's
    const seasons = P ? P.seasons.slice().sort((a, b) => (a.index === 0) - (b.index === 0) || a.index - b.index)
      : sum.seasons.map(([n, list]) => ({ index: n, title: n === 0 ? 'Specials' : `Season ${n}`, episodes: list.length, poster: '' }));
    if (state.season === null || !seasons.some((s) => s.index === state.season)) state.season = (seasons.find((s) => s.index > 0) || seasons[0]).index;
    const cur = seasons.find((s) => s.index === state.season);
    const first = local.find((e) => e.Poster) || local[0];
    const posterSrc = cur && cur.poster ? cacheUrl(cur.poster) : (P && P.poster ? cacheUrl(P.poster) : first.Poster || '');
    const libEps = new Map(local.map((e) => [`${num(e.Season)}|${num(e.Episode)}`, e]));
    const plexEps = P ? P.episodes.filter((e) => e.season === state.season) : [];
    const seasonEps = P ? plexEps.sort((a, b) => a.index - b.index)
      : (sum.seasons.find((x) => x[0] === state.season) || [0, []])[1].map((e) => ({ season: num(e.Season), index: num(e.Episode), title: String(e.Title).replace(/^.* - S\d+E\d+ - /, ''), watched: num(e.ViewCount) > 0, thumb: '', minutes: num(e.RuntimeMin), summary: e.Plot || '' }));
    const watchedAll = P ? P.episodes.filter((e) => e.watched).length : local.filter((e) => num(e.ViewCount) > 0).length;
    const years = !sum.y0 ? '' : sum.y0 === sum.y1 ? String(sum.y0) : `${sum.y0}–${sum.y1}`;
    root.innerHTML = `
      <div class="sv-top">
        <a class="sv-back" href="#/tv">‹ TV Shows</a>
        <div class="sv-actions">
          ${state.fetching ? `<span class="sv-progress"><span style="width:${state.pct}%"></span></span><small>${esc(state.text || 'Getting details from Plex...')}</small>` : ''}
          ${P ? `<small title="Saved from Plex">Plex details from ${esc(P.fetchedAt)}</small>` : ''}
          <span class="addcol"><button class="sv-btn" type="button" data-addcol="1">+ Collection</button></span>
          <button class="sv-btn" type="button" data-refresh="1" ${state.fetching ? 'disabled' : ''} title="Ask Plex again for stills, watched marks, cast and related shows">${P ? 'Refresh from Plex' : 'Get details from Plex'}</button>
        </div>
      </div>
      ${state.error ? `<div class="sv-error">${esc(state.error)}</div>` : ''}
      <div class="sv-head">
        <div class="sv-poster">${posterSrc ? `<img src="${esc(posterSrc)}" alt="">` : `<div class="ph">${esc(name)}</div>`}${cur ? `<span class="sv-pnum">${cur.index}</span>` : ''}</div>
        <div class="sv-main">
          <h1>${esc(P ? P.title || name : name)}</h1>
          <h2>${cur ? esc(cur.title || (cur.index === 0 ? 'Specials' : 'Season ' + cur.index)) : ''}</h2>
          <div class="sv-meta">${starHtml(P ? P.rating || P.audienceRating : first.Rating)}<span>${[years, P ? P.rated : first.MPAARating, P ? P.studio : first.Studio].filter(Boolean).map(esc).join(' · ')}</span></div>
          <div class="sv-strip"><button class="edge l" type="button" data-scroll="seasons" data-dir="-1" aria-label="Earlier seasons" hidden>\u2039</button><div class="sv-seasons hrow" data-row="seasons" role="tablist">${seasons.map((s) => `<button type="button" role="tab" data-season="${s.index}" class="${s.index === state.season ? 'on' : ''}" aria-selected="${s.index === state.season}"><b>${esc(s.index === 0 ? 'Specials' : 'Season ' + s.index)}</b><small>${s.episodes} episode${s.episodes === 1 ? '' : 's'}${P && s.watched ? ` · ${s.watched} watched` : ''}</small></button>`).join('')}</div><button class="edge r" type="button" data-scroll="seasons" data-dir="1" aria-label="Later seasons" hidden>\u203a</button></div>
          <div class="sv-row">
            <div class="sv-info">
              <h4>Show</h4>
              <dl>
                <dt>Seasons</dt><dd>${seasons.filter((s) => s.index > 0).length || seasons.length}</dd>
                <dt>Episodes</dt><dd>${local.length}${P && P.episodes.length !== local.length ? ` <small>(${P.episodes.length} on Plex)</small>` : ''}</dd>
                <dt>Watched</dt><dd>${watchedAll} of ${P ? P.episodes.length : local.length}</dd>
                <dt>First aired</dt><dd>${esc(P && P.firstAired ? P.firstAired : sum.firstAired || '–')}</dd>
                <dt>Last added</dt><dd>${esc(sum.added ? sum.added.slice(0, 10) : '–')}</dd>
                <dt>Size</dt><dd>${fmtSize(sum.size)}</dd>
                <dt>Runtime</dt><dd>${fmtRun(sum.runtime)}</dd>
              </dl>
            </div>
            <div class="sv-about">
              ${(P && P.genres && P.genres.length ? P.genres : first._genres).map((g) => `<span class="sv-chip">${esc(g)}</span>`).join('')}
              ${P && P.summary ? `<p>${esc(P.summary)}</p>` : first.Plot ? `<p>${esc(first.Plot)}</p>` : ''}
            </div>
          </div>
        </div>
      </div>
      <h3 class="sv-h">${seasonEps.length} Episode${seasonEps.length === 1 ? '' : 's'}</h3>
      <div class="sv-eps">${seasonEps.map((e) => {
        const le = libEps.get(`${e.season}|${e.index}`);
        const q = le ? [le.ResolutionClass, hdrLabel(le) !== 'SDR' ? hdrLabel(le) : ''].filter(Boolean).join(' · ') : 'Not in your library';
        return `<button class="sv-ep${le ? '' : ' missing'}" type="button" data-ep="${e.season}|${e.index}" title="${esc(e.summary || '')}">
          <div class="sv-still">${e.thumb ? `<img loading="lazy" src="${esc(cacheUrl(e.thumb))}" alt="">` : `<div class="ph">E${e.index}</div>`}
            ${e.watched ? '<span class="sv-check" title="Watched">✓</span>' : ''}${!e.watched && e.progress > 2 ? `<span class="sv-part" style="width:${e.progress}%"></span>` : ''}</div>
          <div class="sv-et">${esc(e.title)}</div><div class="sv-es">Episode ${e.index}${e.minutes ? ` · ${e.minutes} min` : ''} · ${esc(q)}</div></button>`;
      }).join('')}</div>
      ${P && P.cast.length ? `<h3 class="sv-h">Cast &amp; Crew <span class="arrows" data-arrows="cast"><button type="button" data-scroll="cast" data-dir="-1" aria-label="Scroll left">\u2039</button><button type="button" data-scroll="cast" data-dir="1" aria-label="Scroll right">\u203a</button></span></h3><div class="sv-cast hrow" data-row="cast">${P.cast.map((c) => `<div class="sv-person"><div class="sv-face">${c.photo ? `<img loading="lazy" src="${esc(cacheUrl(c.photo))}" alt="">` : `<span>${esc((c.name || '?').slice(0, 1))}</span>`}</div><b>${esc(c.name)}</b><small>${esc(c.role || '')}</small></div>`).join('')}</div>` : ''}
      ${P && P.related.length ? `<h3 class="sv-h">Related Shows <span class="arrows" data-arrows="related"><button type="button" data-scroll="related" data-dir="-1" aria-label="Scroll left">\u2039</button><button type="button" data-scroll="related" data-dir="1" aria-label="Scroll right">\u203a</button></span></h3><div class="sv-related hrow" data-row="related">${P.related.map((r) => {
        const inLib = L.rows.some((e) => (e.Show || e.Title) === r.title);
        return `<button class="sv-rel${inLib ? '' : ' notlib'}" type="button" data-rel="${esc(r.title)}" title="${inLib ? 'Open' : 'Not in your library'}"><div class="sv-rp">${r.poster ? `<img loading="lazy" src="${esc(cacheUrl(r.poster))}" alt="">` : `<div class="ph">${esc(r.title)}</div>`}${r.unwatched ? `<span class="sv-badge">${r.unwatched}</span>` : ''}</div><b>${esc(r.title)}</b><small>${r.seasons ? `${r.seasons} season${r.seasons === 1 ? '' : 's'}` : r.year || ''}</small></button>`;
      }).join('')}</div>` : ''}`;
    arrowsInit();
    const cols = await posterColours(posterSrc);
    if (cols && root.isConnected) { root.style.setProperty('--s1', cols[0]); root.style.setProperty('--s2', cols[1]); root.style.setProperty('--s3', cols[2]); }
  };

  // Arrows instead of scroll bars: hidden when the row fits, greyed at either end.
  const arrowsInit = () => {
    root.querySelectorAll('[data-row]').forEach((row) => {
      const k = row.dataset.row;
      const btns = root.querySelectorAll(`[data-scroll="${k}"]`);
      const set = () => {
        const fits = row.scrollWidth <= row.clientWidth + 2;
        const atL = row.scrollLeft <= 2, atR = row.scrollLeft + row.clientWidth >= row.scrollWidth - 2;
        const grp = root.querySelector(`[data-arrows="${k}"]`); if (grp) grp.hidden = fits;
        btns.forEach((b) => {
          const left = b.dataset.dir === '-1';
          if (b.classList.contains('edge')) b.hidden = fits || (left ? atL : atR);
          else b.disabled = left ? atL : atR;
        });
      };
      row.onscroll = set; set();
    });
  };
  const onResize = () => arrowsInit();
  window.addEventListener('resize', onResize);
  // A click beside the card (not on it, the bar or a dialog) closes the series view: back to the posters.
  const outside = (e) => {
    if (e.button !== 0 || !root.isConnected) return;
    if (e.target.closest('.series, #chrome, #overlay-root, #toasts, #sizepop, .wgrip')) return;
    if (!e.target.closest('#frame, #app') && e.target !== document.body && e.target !== document.documentElement) return;
    S.saveSettings({ tvView: 'posters' });
    location.hash = '#/tv';
  };
  document.addEventListener('click', outside);

  const fetchPlex = async (refresh) => {
    const local = eps();
    const ep = local.map((e) => String(e.Rid || '')).find((x) => x.startsWith('p:'));
    state.error = '';
    try {
      const r = await bridge.request('series.open', { show: name, ep: ep ? ep.slice(2) : '', refresh: !!refresh }, 60000);
      if (r && r.loading) { state.fetching = true; state.pct = 0; state.text = ''; }
      else if (r && r.title !== undefined) { plexByShow.set(name, r); state.fetching = false; }
    } catch (e) { state.fetching = false; state.error = e.message; }
    draw();
  };
  const onSeries = (d) => {
    if (!d || d.show !== name) return;
    if (d.running) { state.fetching = true; state.pct = d.pct || 0; state.text = d.text || ''; draw(); return; }
    state.fetching = false;
    if (d.error) { state.error = d.error; draw(); } else if (!d.cancelled) fetchPlex(false);
    else draw();
  };
  const off = bridge.on('series', onSeries);
  root.addEventListener('click', (e) => {
    const t = e.target.closest('[data-season],[data-ep],[data-rel],[data-refresh],[data-addcol],[data-scroll]');
    if (!t) return;
    if (t.dataset.scroll) { const row = root.querySelector(`[data-row="${t.dataset.scroll}"]`); if (row) row.scrollBy({ left: +t.dataset.dir * row.clientWidth * 0.8, behavior: 'smooth' }); return; }
    if (t.dataset.season !== undefined) { state.season = +t.dataset.season; draw(); }
    else if (t.dataset.refresh) fetchPlex(true);
    else if (t.dataset.addcol) { if (!t.parentElement.querySelector('.colpop')) { const list = eps(); addToCollection(t, list[0], list); } }
    else if (t.dataset.rel) { if (L.rows.some((x) => (x.Show || x.Title) === t.dataset.rel)) location.hash = `#/tv/${encodeURIComponent(t.dataset.rel)}`; }
    else if (t.dataset.ep) {
      const [s, n] = t.dataset.ep.split('|').map(Number);
      const le = eps().find((x) => num(x.Season) === s && num(x.Episode) === n);
      if (le) openCard(le, ctx.toast);
    }
  });
  plexByShow.has(name) ? draw() : (draw(), (eps().length && !S.state.halted ? fetchPlex(false) : null));
  ctx.redraw = draw;
  return () => { document.body.classList.remove('series-open'); window.removeEventListener('resize', onResize); document.removeEventListener('click', outside); if (typeof off === 'function') off(); };
}
