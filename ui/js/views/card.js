// The title card: poster, scores, plot and every spec of one movie or episode, and the show card for TV (seasons and
// episodes). From the old dashboard page's modal; "Save as picture" now goes through the backend (picture.save).
import * as S from '../store.js';
import { overlay } from './settings.js';
import { esc, num, v, fmtInt, fmtMoney, fmtSize, fmtHMS, fmtRun, hdrLabel, posterHtml, logoOrTitle, artUrl } from '../common.js';
import { hdrClass, deviceStatus, ALL_DEVICES, STATUS } from './devices.js';
import { BASE_YEAR } from '../inflation.js';
import { addToCollection } from './collections.js';

function spec(title, pairs) {
  const p = pairs.filter((x) => x[1] !== '' && x[1] != null && x[1] !== 0 && x[1] !== '0');
  if (!p.length) return '';
  return `<div class="spec"><h4>${title}</h4><dl>${p.map((x) => `<dt>${esc(x[0])}</dt><dd>${x[1] && x[1].html ? x[1].html : esc(x[1])}</dd>`).join('')}</dl></div>`;
}
export const TOMATO = '<svg class="rti" viewBox="0 0 16 16" aria-label="Fresh"><circle cx="8" cy="9.2" r="6.4" fill="#E63428"/><path d="M8 5 4.8 2.2 8 3.2 11.4 1.4 10 5z" fill="#46AA46"/></svg>';
export const SPLAT = '<svg class="rti" viewBox="0 0 16 16" aria-label="Rotten"><g fill="#70A82C"><ellipse cx="8" cy="10" rx="6.6" ry="4.4"/><circle cx="8" cy="6" r="4"/><circle cx="2.4" cy="12.6" r="2.2"/><circle cx="13.6" cy="12" r="2.2"/><circle cx="12.6" cy="4" r="1.5"/></g></svg>';
/* Metacritic's colours: green 61-100, yellow 40-60, red 0-39, with the score on the square */
export function mc(x) {
  const n = Math.round(num(x)); if (!(n > 0)) return '';
  const c = n >= 61 ? ['#66cc33', '#fff'] : n >= 40 ? ['#ffcc33', '#222'] : ['#ff0000', '#fff'];
  return { html: `<span class="mc" style="background:${c[0]};color:${c[1]}">${n}</span>` };
}
function scoreCards(r) {
  const rt = (x) => (num(x) > 0 ? { html: (num(x) >= 60 ? TOMATO : SPLAT) + Math.round(num(x)) + '%' } : '');
  const rlabel = r.RatingSource === 'IMDb' ? 'IMDb rating' : r.RatingSource === 'TMDB' ? 'TMDB rating' : 'Rating';
  const rating = [[rlabel, num(r.Rating) > 0 ? num(r.Rating).toFixed(1) + (num(r.Votes) > 0 ? '  (' + fmtInt(num(r.Votes)) + ' votes)' : '') : ''],
    ['RT Critics', rt(r.RTCritic)], ['RT Audience', rt(r.RTAudience)],
    // Metacritic always shows on a movie: its score comes from OMDb, so say how to get it when it is missing
    ['Metacritic', mc(r.Metascore) || (r.Show ? '' : { html: '<span class="muted" title="Metacritic scores come from OMDb: Tools > Fetch info (needs an OMDb key in Settings > Data)">not fetched</span>' })], ['CinemaScore', r.CinemaScore]];
  // each figure with its inflation-adjusted value underneath (inflation.js)
  const m = (raw, adj, approx) => (fmtMoney(raw) ? (adj > 0 ? { html: `${esc(fmtMoney(raw))}<small class="adj" title="Adjusted for US inflation from the release year (${BASE_YEAR} dollars)${approx ? '; approximate for worldwide' : ''}">${approx ? '≈ ' : ''}${esc(fmtMoney(adj))} in ${BASE_YEAR} $</small>` } : fmtMoney(raw)) : '');
  const money = [['Domestic (all-time)', m(r.BoxOfficeDomestic, r.BoxOfficeDomesticAdj)], ['Worldwide (all-time)', m(r.BoxOfficeWorldwide, r.BoxOfficeWorldwideAdj, true)],
    ['Opening, domestic', m(r.OpeningDomestic, r.OpeningDomesticAdj)], ['Opening, worldwide', fmtMoney(r.OpeningWorldwide)]];
  const has = (rows) => rows.some((x) => x[1] && !(x[1].html && x[1].html.includes('not fetched')));
  return (has(rating) ? spec('Ratings', rating) : '') + (has(money) ? spec('Box office', money) : '');
}
const ADDCOL = '<span class="addcol"><button type="button" data-addcol="1" title="Add to a collection">+ Collection</button></span>';
const ALLDET = '<button type="button" data-alldet="1" title="Every detail of this file, as in the window app\'s detail view">All details</button>';
// The detailed view: every field the scan knows, grouped as in the window app (file locations left out).
const SKIP_DET = new Set(['Poster', 'Rid', 'PlexKey', 'PlexThumb', 'MetaSources']);
function allDetails(r) {
  const L = S.state.libs[r._tab] || S.state.libs.movies;
  const groups = new Map();
  for (const f of L.fields) {
    if (SKIP_DET.has(f.n)) continue;
    const x = r[f.n];
    if (x === undefined || x === null || x === '' || x === false || (typeof x === 'number' && x === 0 && f.t !== 'bool')) continue;
    if (!groups.has(f.g)) groups.set(f.g, []);
    groups.get(f.g).push([f.n.replace(/([a-z])([A-Z])/g, '$1 $2'), x === true ? 'Yes' : typeof x === 'number' && !Number.isInteger(x) ? String(Math.round(x * 1000) / 1000) : String(x)]);
  }
  return `<div class="alldet">${[...groups.entries()].map(([g, rows]) => `<div class="spec"><h4>${esc(g)}</h4><dl>${rows.map(([k, x]) => `<dt>${esc(k)}</dt><dd>${esc(x)}</dd>`).join('')}</dl></div>`).join('')}</div>`;
}
function links(r) {
  const out = [];
  if (r.IMDBID) out.push(['IMDb', `https://www.imdb.com/title/${encodeURIComponent(r.IMDBID)}/`]);
  if (r.TMDBID) out.push(['TMDB', `https://www.themoviedb.org/${r.Show ? 'tv' : 'movie'}/${encodeURIComponent(r.TMDBID)}`]);
  return `<div class="links">${out.map(([n, u]) => `<button type="button" data-url="${esc(u)}">${n} \u2197</button>`).join('')}${ADDCOL}${r.__show ? '' : ALLDET}</div>`;
}
const EXPORT_BTN = '<button class="xp" type="button" data-export="1" title="Save this card as a picture in Pictures\\Modern Media Library Manager"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2v8M4.5 6.8 8 10.3l3.5-3.5M2.5 13.5h11"/></svg><span>Save as picture</span></button>';

function titleSheet(r) {
  const hdr = v(r.HDRStack, v(r.HDRType, 'SDR'));
  const compat = hdrClass(r).k === 'sdr' ? '' :
    `<div class="spec compat"><h4>Device compatibility</h4><dl>${ALL_DEVICES.map((d) => { const s = deviceStatus(d, r);
      return `<dt title="${esc(d.note)}">${esc(d.name)}</dt><dd><span class="sdot" style="background:${STATUS[s].color}"></span>${STATUS[s].label}</dd>`; }).join('')}</dl></div>`;
  const ep = r.Show ? `<div class="eyebrow">${esc(r.Show)} · ${num(r.Season) === 0 ? 'Specials' : 'Season ' + num(r.Season)}, episode ${num(r.Episode)}</div>` : '';
  const art = artUrl(r);
  // an episode keeps its own title as text; the show's logo goes above it in place of the show name
  const head = r.Show ? (S.state.settings.artLogo && r.Logo ? `<div class="eyebrow logo-row">${logoOrTitle(r, r.Show, 'span')}</div>${ep}` : ep) + `<h2>${esc(String(r.Title).replace(/^.* - S\d+E\d+ - /, ''))}</h2>` : logoOrTitle(r, r.Title);
  return `<div class="sheet${art ? ' has-art' : ''}"${art ? ` style="--art:url('${esc(art)}')"` : ''}>${EXPORT_BTN}<button class="x" type="button" data-close="1" aria-label="Close">✕</button>
    <div class="pcol"><div class="pimg">${posterHtml(r)}</div>${scoreCards(r)}</div>
    <div>
      ${head}
      <div class="meta">${[r.Year > 0 ? r.Year : '', num(r.RuntimeMin) > 0 ? fmtHMS(r.RuntimeMin) : '', r.MPAARating, num(r.Rating) > 0 ? '★ ' + num(r.Rating).toFixed(1) : ''].filter(Boolean).map(esc).join(' · ')}</div>
      ${r.Tagline ? `<div class="tagline">${esc(r.Tagline)}</div>` : ''}
      ${r.Plot ? `<p class="plot">${esc(r.Plot)}</p>` : ''}
      <div class="gchips">${r._genres.map((g) => `<span>${esc(g)}</span>`).join('')}</div>
      ${links(r)}
      <div class="specs">
        ${spec('Video', [['Resolution', r.Resolution], ['Class', r.ResolutionClass], ['Codec', [r.VideoCodec, r.FormatProfile].filter(Boolean).join(' ')],
          ['Bitrate', num(r.VideoBitRateMbps) > 0 ? num(r.VideoBitRateMbps).toFixed(1) + ' Mbps' : ''], ['Frame rate', num(r.FrameRate) > 0 ? num(r.FrameRate) + ' fps' : ''],
          ['Bit depth', num(r.BitDepth) > 0 ? r.BitDepth + '-bit' : ''], ['Dynamic range', hdr], ['DV profile', r.DVProfile ? 'P' + r.DVProfile : ''], ['DV layer', r.DVLayer], ['DV base layer', r.DVBase],
          ['Chroma', r.ChromaSubsampling], ['Encoder', r.Encoder]])}
        ${spec('Audio', [['Format', r.AudioFormat], ['Immersive', r.ObjectAudio], ['Channels', r.AudioLayout], ['Bitrate', num(r.AudioBitRateKbps) > 0 ? r.AudioBitRateKbps + ' kbps' : ''],
          ['Languages', r.AudioLanguages], ['Tracks', num(r.AudioTracks)]])}
        ${spec('Subtitles', [['Tracks', num(r.SubtitleTracks)], ['Languages', r.SubtitleLanguages], ['Formats', r.SubtitleFormats]])}
        ${spec('File', [['Container', r.Container], ['Size', num(r.FileSizeGB) > 0 ? fmtSize(r.FileSizeGB) : ''], ['Source', r.Source], ['Added', r.Added]])}
        ${spec('People & studio', [['Director', r.Director], ['Cast', r.Cast], ['Studio', r.Studio], ['Country', r.Country], ['Collection', r.Collection]])}
        ${compat}
      </div>
    </div></div>`;
}

// A show: poster, totals, and its seasons with every episode (click one for its card).
export function showSummary(eps) {
  const seasons = new Map();
  for (const e of eps) { const s = num(e.Season); if (!seasons.has(s)) seasons.set(s, []); seasons.get(s).push(e); }
  for (const list of seasons.values()) list.sort((a, b) => num(a.Episode) - num(b.Episode));
  const years = eps.map((e) => e.Year).filter((y) => y > 0);
  const aired = eps.map((e) => e.ReleaseDate).filter(Boolean).sort();
  return {
    seasons: [...seasons.entries()].sort((a, b) => (a[0] === 0) - (b[0] === 0) || a[0] - b[0]),
    y0: years.length ? Math.min(...years) : 0, y1: years.length ? Math.max(...years) : 0,
    firstAired: aired[0] || '', added: eps.map((e) => e.Added || '').sort().pop() || '',
    size: eps.reduce((a, e) => a + num(e.FileSizeGB), 0), runtime: eps.reduce((a, e) => a + num(e.RuntimeMin), 0),
  };
}
function showSheet(name, eps) {
  const s = showSummary(eps), first = eps.find((e) => e.Poster) || eps[0];
  const years = !s.y0 ? '' : s.y0 === s.y1 ? String(s.y0) : `${s.y0}–${s.y1}`;
  const q = (e) => [e.ResolutionClass, hdrLabel(e) !== 'SDR' ? hdrLabel(e) : ''].filter(Boolean).map((x) => `<span>${esc(x)}</span>`).join('');
  const seasonsHtml = s.seasons.map(([n, list]) => `<h3>${n === 0 ? 'Specials' : 'Season ' + n} <small>${list.length} episode${list.length === 1 ? '' : 's'} · ${fmtSize(list.reduce((a, e) => a + num(e.FileSizeGB), 0))}</small></h3>`
    + list.map((e) => `<div class="eprow" data-ep="${e._i}"><span class="n">E${String(num(e.Episode)).padStart(2, '0')}</span><span class="t">${esc(String(e.Title).replace(/^.* - S\d+E\d+ - /, ''))}</span><span class="q">${q(e)}</span><span class="s">${num(e.FileSizeGB) > 0 ? fmtSize(e.FileSizeGB) : ''}</span></div>`).join('')).join('');
  const art = artUrl(first);
  return `<div class="sheet${art ? ' has-art' : ''}"${art ? ` style="--art:url('${esc(art)}')"` : ''}><button class="x" type="button" data-close="1" aria-label="Close">✕</button>
    <div class="pcol"><div class="pimg">${posterHtml(first, name)}</div>
      ${spec('Show', [['Seasons', s.seasons.filter((x) => x[0] > 0).length], ['Episodes', eps.length], ['First aired', s.firstAired], ['Last added', s.added], ['Size', fmtSize(s.size)], ['Runtime', fmtRun(s.runtime)]])}</div>
    <div>${logoOrTitle(first, name)}
      <div class="meta">${[years, first.Studio, first.MPAARating].filter(Boolean).map(esc).join(' · ')}</div>
      <div class="gchips">${first._genres.map((g) => `<span>${esc(g)}</span>`).join('')}</div>
      ${links({ IMDBID: '', TMDBID: '', Show: name, __show: true })}
      <div class="eps">${seasonsHtml}</div>
    </div></div>`;
}

/* ---- Save the open card as a picture ----
   The card is cloned with every computed style written inline, drawn through an SVG foreignObject onto a canvas and
   sent to the backend as a PNG, which saves it in Pictures\Modern Media Library Manager. */
const blobToDataUrl = (b) => new Promise((ok, no) => { const f = new FileReader(); f.onload = () => ok(f.result); f.onerror = () => no(f.error); f.readAsDataURL(b); });
const loadImage = (src) => new Promise((ok, no) => { const im = new Image(); im.onload = () => ok(im); im.onerror = () => no(new Error('image')); im.src = src; });
async function imageAsDataUrl(src) {
  if (!src) return null;
  if (/^data:/i.test(src)) return src;
  try { const im = await loadImage(src), c = document.createElement('canvas'); c.width = im.naturalWidth; c.height = im.naturalHeight; c.getContext('2d').drawImage(im, 0, 0); return c.toDataURL('image/jpeg', 0.92); } catch (e) { return null; }
}
function inlineStyles(src, dst) {
  const cs = getComputedStyle(src); let t = '';
  for (let i = 0; i < cs.length; i++) { const p = cs[i]; if (/^(animation|transition)/.test(p)) continue; t += p + ':' + cs.getPropertyValue(p) + ';'; }
  dst.style.cssText = t;
  for (let i = 0; i < src.children.length; i++) inlineStyles(src.children[i], dst.children[i]);
}
async function exportCard(sheet, btn, r, toast) {
  if (btn.disabled) return;
  const label = btn.querySelector('span'), idle = label.textContent;
  btn.disabled = true; label.textContent = 'Saving...';
  try {
    const W = Math.ceil(sheet.getBoundingClientRect().width);
    const clone = sheet.cloneNode(true);
    inlineStyles(sheet, clone);
    clone.querySelectorAll('.x,.xp').forEach((n) => n.remove());
    let note = '';
    for (const im of [...clone.querySelectorAll('img')]) {
      const d = await imageAsDataUrl(im.getAttribute('src'));
      if (d) im.setAttribute('src', d); else { im.remove(); note = ' (without the poster)'; }
    }
    clone.style.cssText += ';width:' + W + 'px;height:auto;max-height:none;overflow:visible;position:relative;margin:0;';
    const host = document.createElement('div');
    host.style.cssText = 'position:fixed;left:-30000px;top:0;visibility:hidden;pointer-events:none';
    host.appendChild(clone); document.body.appendChild(host);
    const H = Math.ceil(clone.getBoundingClientRect().height);
    const xml = new XMLSerializer().serializeToString(clone);
    host.remove();
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><foreignObject x="0" y="0" width="${W}" height="${H}">${xml}</foreignObject></svg>`;
    const img = await loadImage('data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg));
    const c = document.createElement('canvas'); c.width = W * 2; c.height = H * 2;
    const ctx = c.getContext('2d'); ctx.scale(2, 2); ctx.drawImage(img, 0, 0, W, H);
    const blob = await new Promise((ok) => c.toBlob(ok, 'image/png'));
    if (!blob) throw new Error('The picture came out empty.');
    const data = await blobToDataUrl(blob);
    const name = (r.Title + (r.Year > 0 ? ` (${r.Year})` : '')).replace(/[\\/:*?"<>|]+/g, '_').trim();
    const path = await S.savePicture(name, data.slice(data.indexOf(',') + 1));
    toast(`Saved${note}: ${path}`);
  } catch (e) { toast(`Could not save the picture: ${e.message}`); }
  label.textContent = idle; btn.disabled = false;
}

// Opens a card. back: a function that reopens what this card came from (the show card, for an episode).
export function openCard(r, toast, back) {
  if (!r) return;
  overlay((close) => {
    const box = document.createElement('div');
    box.innerHTML = titleSheet(r);
    box.addEventListener('click', (e) => {
      const t = e.target.closest('[data-close],[data-export],[data-url],[data-addcol],[data-alldet]');
      if (!t) return;
      if (t.dataset.alldet) {
        const specs = box.querySelector('.specs'), have = box.querySelector('.alldet');
        if (have) { have.remove(); specs.hidden = false; t.textContent = 'All details'; }
        else { specs.insertAdjacentHTML('afterend', allDetails(r)); specs.hidden = true; t.textContent = 'Summary'; }
        return;
      }
      if (t.dataset.addcol) { if (!t.parentElement.querySelector('.colpop')) addToCollection(t, r); return; }
      if (t.dataset.close) { close(); if (back) back(); }
      else if (t.dataset.export) exportCard(box.querySelector('.sheet'), t, r, toast);
      else if (t.dataset.url) S.openUrl(t.dataset.url).catch((err) => toast(err.message));
    });
    return box;
  }, 'sheet-host');
}
export function openShow(name, eps, toast) {
  overlay((close) => {
    const box = document.createElement('div');
    box.innerHTML = showSheet(name, eps);
    box.addEventListener('click', (e) => {
      const t = e.target.closest('[data-close],[data-ep],[data-addcol]');
      if (!t) return;
      if (t.dataset.addcol) { if (!t.parentElement.querySelector('.colpop')) addToCollection(t, eps[0], eps); return; }
      if (t.dataset.close) close();
      else { const ep = S.state.libs.tv.rows[+t.dataset.ep]; close(); openCard(ep, toast, () => openShow(name, eps, toast)); }
    });
    return box;
  }, 'sheet-host');
}
