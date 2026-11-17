/* Infographics: pictures built from the library, saved as PNGs in Pictures\Modern Media Library Manager.
   Opened from a movie card (one movie, or one of its actors), from Compare (two movies), from Collections (a whole
   collection) and from Stats (the library: top-grossing actors, critics against audiences). Everything is drawn from
   what the library already has; nothing is fetched. */
import * as S from '../store.js';
import { h } from '../util.js';
import { esc, num, fmtMoney, fmtSize, dedupe } from '../common.js';
import { overlay } from './settings.js';
import { blobToDataUrl, loadImage, imageAsDataUrl, inlineStyles } from './card.js';

// ---- the layouts, by where they are opened from ----
const LAYOUTS = {
  movie: [['A', 'Stat sheet'], ['B', 'Box office run'], ['C', 'Tech spec'], ['D', 'Story card'], ['L', 'Reception'], ['M', 'Actor career'], ['N', 'Actor profile']],
  pair: [['E', 'Head to head']],
  collection: [['F', 'Timeline'], ['G', 'Ranked'], ['H', 'Box office'], ['I', 'Your collection'], ['J', 'Watch order'], ['K', 'Critics vs audiences']],
  library: [['O', 'Top-grossing actors'], ['P', 'Actors over the years'], ['K', 'Critics vs audiences']],
};
const SCORES = [['rt', 'Rotten Tomatoes'], ['mc', 'Metacritic'], ['imdb', 'IMDb'], ['aud', 'Audience'], ['avg', 'Average']];

// ---- reading a title ----
const imdb = (r) => (num(r.Rating) > 0 ? num(r.Rating) : 0);
const rt = (r) => num(r.RTCritic);
const mc = (r) => num(r.Metascore);
// audience: Rotten Tomatoes' audience score, or IMDb's rating as a percentage when there is none
const aud = (r) => (num(r.RTAudience) > 0 ? num(r.RTAudience) : imdb(r) * 10);
const score = (r, k) => {
  if (k === 'rt') return rt(r); if (k === 'mc') return mc(r); if (k === 'imdb') return imdb(r) * 10; if (k === 'aud') return aud(r);
  const v = [rt(r), mc(r), imdb(r) * 10].filter((x) => x > 0); return v.length ? Math.round(v.reduce((a, b) => a + b, 0) / v.length) : 0;
};
const scoreText = (r, k) => { const v = score(r, k); return !v ? '-' : k === 'imdb' ? (v / 10).toFixed(1) : k === 'mc' ? String(Math.round(v)) : Math.round(v) + '%'; };
const ww = (r, adj) => num(adj ? r.BoxOfficeWorldwideAdj || r.BoxOfficeWorldwide : r.BoxOfficeWorldwide);
const dom = (r, adj) => num(adj ? r.BoxOfficeDomesticAdj || r.BoxOfficeDomestic : r.BoxOfficeDomestic);
const castOf = (r) => String(r.Cast || '').split(',').map((x) => x.trim()).filter(Boolean);
const genresOf = (r) => String(r.Genre || '').split(/[,/|]/).map((x) => x.trim()).filter(Boolean);
const run = (min) => { min = Math.round(num(min)); return min > 0 ? `${Math.floor(min / 60)}h ${String(min % 60).padStart(2, '0')}m` : ''; };
const short = (t, n = 22) => (String(t).length > n ? String(t).slice(0, n - 1) + '…' : String(t));
const M = (n) => (n > 0 ? fmtMoney(n) : '-');
const poster = (r, cls = '') => (r && r.Poster ? `<img class="ig-poster ${cls}" src="${esc(r.Poster)}" alt="">` : `<div class="ig-poster ig-noposter ${cls}"><span>${esc(r ? short(r.Title, 30) : '')}</span></div>`);
const hue = (s) => { let x = 0; for (const c of String(s)) x = (x * 31 + c.charCodeAt(0)) % 360; return x; };
const movies = () => dedupe(S.state.libs.movies.rows || []).filter((r) => !r.Show);
const media = (r) => [r.ResolutionClass, r.HDRStack || r.HDRType, r.ObjectAudio || r.AudioFormat].filter((x) => x && x !== 'SDR').join(' · ');
const watched = (r) => num(r.ViewCount) > 0;
const footer = () => '<div class="ig-foot">Modern Media Library Manager</div>';

// ---- the single-movie layouts ----
function ring(name, val, max, col, txt) {
  const R = 38, C = 2 * Math.PI * R, f = Math.max(0, Math.min(1, val / max));
  return `<div class="ig-ring"><svg width="96" height="96" viewBox="0 0 96 96"><circle cx="48" cy="48" r="${R}" fill="none" stroke="rgba(255,255,255,.1)" stroke-width="8"/>${val > 0 ? `<circle cx="48" cy="48" r="${R}" fill="none" stroke="${col}" stroke-width="8" stroke-linecap="round" stroke-dasharray="${C * f} ${C}" transform="rotate(-90 48 48)"/>` : ''}<text x="48" y="57" text-anchor="middle" fill="#fff" font-family="Impact, sans-serif" font-size="26">${val > 0 ? txt : '-'}</text></svg><span class="ig-lbl">${name}</span></div>`;
}
const metaLine = (r) => [r.Year > 0 ? r.Year : '', run(r.RuntimeMin), r.MPAARating, genresOf(r).slice(0, 3).join(', '), r.Director ? 'Directed by ' + r.Director : '', r.Studio].filter(Boolean).map(esc).join(' · ');
function A(r) {
  return `<div class="ig ig-a">${poster(r, 'ig-pa')}<div>
    <div class="ig-lbl">Movie stat sheet</div><h3 class="ig-big">${esc(r.Title)}</h3><div class="ig-meta">${metaLine(r)}</div>
    <div class="ig-rings">${ring('IMDb', imdb(r), 10, '#f5c518', imdb(r).toFixed(1))}${ring('Rotten Tomatoes', rt(r), 100, '#fa320a', rt(r) + '%')}${ring('Metacritic', mc(r), 100, '#66cc33', String(mc(r)))}${num(r.RTAudience) > 0 ? ring('Audience', num(r.RTAudience), 100, '#3fa9f5', num(r.RTAudience) + '%') : ''}</div>
    <div class="ig-money"><div><span class="ig-lbl">Opening weekend</span><b>${M(num(r.OpeningDomestic))}</b></div><div><span class="ig-lbl">Domestic</span><b>${M(dom(r))}</b></div><div><span class="ig-lbl">Worldwide</span><b>${M(ww(r))}</b></div></div>
  </div><div class="ig-note">${esc([media(r) && 'Your copy: ' + media(r), num(r.ViewCount) > 0 ? `watched ${num(r.ViewCount)} time${num(r.ViewCount) > 1 ? 's' : ''}` : ''].filter(Boolean).join(' · '))}</div>${footer()}</div>`;
}
function B(r) {
  const b = (S.state.bo || {})[r.Rid] || {}, kind = (b.weekends || []).length ? 'weekends' : (b.weeks || []).length ? 'weeks' : '';
  const rows = kind ? b[kind] : [];
  if (!rows.length) return `<div class="ig ig-b ig-empty"><h3 class="ig-big">${esc(r.Title)}</h3><p>No box office run for this movie yet. Paste one into its card (Box office runs &gt; Paste box office) and this fills in.</p></div>`;
  const W = 992, H = 360, pl = 56, pr = 64, pt = 14, pb = 34, n = rows.length, bw = (W - pl - pr) / n, mx = Math.max(...rows.map((x) => x.gross)) * 1.08;
  const total = rows[rows.length - 1].total || rows.reduce((a, x) => a + x.gross, 0), sy = (v) => H - pb - v / mx * (H - pt - pb), sc = (v) => H - pb - v / total * (H - pt - pb);
  let s = '';
  for (let i = 0; i <= 4; i++) { const g = mx / 4 * i; s += `<line x1="${pl}" x2="${W - pr}" y1="${sy(g)}" y2="${sy(g)}" stroke="#1e2a2f"/><text x="${pl - 8}" y="${sy(g) + 4}" text-anchor="end" fill="#6f8a82" font-size="11">${esc(i ? fmtMoney(g) : '$0')}</text>`; }
  rows.forEach((x, i) => { const X = pl + i * bw + Math.min(4, bw * .15), w = bw - 2 * Math.min(4, bw * .15), y = sy(x.gross);
    s += `<rect x="${X}" y="${y}" width="${w}" height="${H - pb - y}" rx="${Math.min(4, w / 3)}" fill="${i ? '#2f6f5a' : '#5fe0a8'}"/>`;
    if (n <= 20 || i % Math.ceil(n / 20) === 0) s += `<text x="${X + w / 2}" y="${H - pb + 18}" text-anchor="middle" fill="#6f8a82" font-size="11">${kind === 'weeks' ? 'Wk' : 'W'}${i + 1}</text>`;
    if (i < 3) s += `<text x="${X + w / 2}" y="${y - 6}" text-anchor="middle" fill="#e8f4ef" font-size="12" font-weight="700">${esc(fmtMoney(x.gross))}</text>`; });
  let cum = 0; const pts = rows.map((x, i) => { cum = x.total || cum + x.gross; return `${pl + i * bw + bw / 2},${sc(cum)}`; });
  s += `<polyline fill="none" stroke="#ffd166" stroke-width="2.5" points="${pts.join(' ')}"/><text x="${W - pr + 6}" y="${sc(total) + 4}" fill="#ffd166" font-size="12" font-weight="700">Total</text>`;
  const drop = rows.length > 1 && rows[0].gross > 0 ? Math.round((rows[1].gross / rows[0].gross - 1) * 100) : null, wide = Math.max(0, ...rows.map((x) => x.theaters || 0));
  return `<div class="ig ig-b"><header><div><div class="ig-lbl">Box office run · ${kind === 'weeks' ? 'week by week' : 'weekend by weekend'}</div><h3 class="ig-big">${esc(r.Title)}</h3></div><div class="ig-tot"><span class="ig-lbl">Total</span><b>${esc(fmtMoney(total))}</b></div></header>
    <svg viewBox="0 0 ${W} ${H}" width="100%" height="100%">${s}</svg>
    <div class="ig-row"><span>Opening <b>${esc(fmtMoney(rows[0].gross))}</b></span>${drop !== null ? `<span>Second ${kind === 'weeks' ? 'week' : 'weekend'} <b>${drop > 0 ? '+' : ''}${drop}%</b></span>` : ''}<span>${kind === 'weeks' ? 'Weeks' : 'Weekends'} <b>${n}</b></span><span>Opening share of total <b>${Math.round(rows[0].gross / total * 100)}%</b></span>${wide ? `<span>Widest release <b>${wide.toLocaleString('en-US')} theaters</b></span>` : ''}</div>${footer()}</div>`;
}
function C(r) {
  const all = movies(), br = num(r.VideoBitRateMbps), sz = num(r.FileSizeGB);
  const maxBr = Math.max(1, ...all.map((x) => num(x.VideoBitRateMbps))), maxSz = Math.max(1, ...all.map((x) => num(x.FileSizeGB)));
  const top = br > 0 ? Math.round(all.filter((x) => num(x.VideoBitRateMbps) > 0 && num(x.VideoBitRateMbps) < br).length / Math.max(1, all.filter((x) => num(x.VideoBitRateMbps) > 0).length) * 100) : 0;
  const badges = [r.ResolutionClass, r.HDRStack || (r.HDRType !== 'SDR' ? r.HDRType : ''), r.VideoCodec, [r.AudioFormat, r.ObjectAudio, r.AudioLayout].filter(Boolean).join(' '), r.Source].filter(Boolean);
  const cell = (l, v, meter) => `<div><span class="ig-lbl">${l}</span><b>${esc(v || '-')}</b>${meter != null ? `<div class="ig-meter"><i style="width:${Math.round(meter * 100)}%"></i></div>` : ''}</div>`;
  return `<div class="ig ig-c">${poster(r, 'ig-pc')}<div><div class="ig-lbl">In your library</div><h3 class="ig-big">${esc(r.Title)} <span>${r.Year > 0 ? r.Year : ''}</span></h3>
    <div class="ig-badges">${badges.map((b) => `<span>${esc(String(b).toUpperCase())}</span>`).join('')}</div>
    <div class="ig-specs">${cell('Resolution', r.Resolution)}${cell('Frame rate', r.FrameRate)}${cell('Bit depth', r.BitDepth ? r.BitDepth + '-bit' : '')}${cell('Video bitrate', br > 0 ? br.toFixed(1) + ' Mb/s' : '', br > 0 ? br / maxBr : null)}${cell('Audio', [r.AudioFormat, r.AudioLayout].filter(Boolean).join(' '))}${cell('File size', sz > 0 ? fmtSize(sz) : '', sz > 0 ? sz / maxSz : null)}${cell('Audio tracks', r.AudioTracks)}${cell('Subtitles', r.SubtitleTracks ? r.SubtitleTracks + ' tracks' : '')}${cell('Container', r.Container)}</div>
    ${top ? `<p class="ig-sub">A higher bitrate than ${top}% of your library · bars compare with the highest in your library</p>` : ''}</div>${footer()}</div>`;
}
function D(r, dark) {
  const ac = dark ? '#f2f2f2' : `hsl(${hue(r.Title)} 80% 74%)`, tint = dark ? '#262626' : `hsl(${hue(r.Title)} 30% 18%)`, bg = dark ? 'linear-gradient(180deg,#141414,#0a0a0a)' : `linear-gradient(180deg,hsl(${hue(r.Title)} 45% 14%),#0a0a12 70%)`;
  const maxWW = Math.max(1, ...movies().map((x) => ww(x)));
  const bars = [['IMDb', imdb(r) * 10, imdb(r) ? imdb(r).toFixed(1) : '-'], ['Rotten Tomatoes', rt(r), rt(r) ? rt(r) + '%' : '-'], ['Metacritic', mc(r), mc(r) || '-'], ['Audience', num(r.RTAudience), num(r.RTAudience) ? num(r.RTAudience) + '%' : '-'], ['Worldwide', ww(r) / maxWW * 100, ww(r) ? fmtMoney(ww(r)) : '-']].filter((b) => b[1] > 0);
  return `<div class="ig ig-d" style="background:${bg}">${poster(r, 'ig-pd')}<h3 class="ig-big">${esc(r.Title)}</h3>
    <div class="ig-tags">${[r.Year > 0 ? r.Year : '', run(r.RuntimeMin), ...genresOf(r).slice(0, 2)].filter(Boolean).map((t) => `<span>${esc(t)}</span>`).join('')}</div>
    <div class="ig-stack">${bars.map(([n, w, t]) => `<div class="ig-hb"><span>${n}</span><i style="background:${tint}"><b style="width:${Math.max(2, Math.min(100, w))}%;background:${ac}"></b></i><span class="ig-mono">${esc(t)}</span></div>`).join('')}</div>
    <div class="ig-verdict"><span class="ig-lbl">In your library</span><b style="color:${ac}">${esc(media(r) || 'In your library')}</b><small>${watched(r) ? `Watched ${num(r.ViewCount)} time${num(r.ViewCount) > 1 ? 's' : ''}` : 'Not watched yet'}</small></div></div>`;
}
function E(a, b) {
  const rows = [['IMDb', (r) => imdb(r), (r) => imdb(r) ? imdb(r).toFixed(1) : '-', 1], ['Rotten Tomatoes', rt, (r) => rt(r) ? rt(r) + '%' : '-', 1], ['Metacritic', mc, (r) => mc(r) || '-', 1],
    ['Opening', (r) => num(r.OpeningDomestic), (r) => M(num(r.OpeningDomestic)), 1], ['Domestic', (r) => dom(r), (r) => M(dom(r)), 1], ['Worldwide', (r) => ww(r), (r) => M(ww(r)), 1],
    ['Runtime', (r) => num(r.RuntimeMin), (r) => run(r.RuntimeMin) || '-', 0], ['Your copy', (r) => ({ '4K': 4, '1080p': 3, '720p': 2 }[r.ResolutionClass] || 1), (r) => r.ResolutionClass || '-', 1]];
  const side = (r, o, left) => `<div class="ig-side ${left ? 'l' : 'r'}">${poster(r, 'ig-pe')}<div><div class="ig-lbl">${r.Year > 0 ? r.Year : ''}</div><h3 class="ig-big">${esc(short(r.Title, 28))}</h3></div><div class="ig-cmp">${rows.map(([n, f, t, better]) => {
    const win = better && f(r) > 0 && f(r) > f(o) ? 'win' : '';
    return left ? `<div class="ig-cr"><span>${n}</span><b class="${win}">${esc(t(r))}</b></div>` : `<div class="ig-cr"><b class="${win}">${esc(t(r))}</b><span>${n}</span></div>`; }).join('')}</div></div>`;
  return `<div class="ig ig-e">${side(a, b, true)}<div class="ig-vs">VS</div>${side(b, a, false)}</div>`;
}
function Lr(r) {
  const c = rt(r), a = num(r.RTAudience) || (imdb(r) ? Math.round(imdb(r) * 10) : 0), gap = c && a ? Math.abs(c - a) : 0;
  const ranked = movies().filter((x) => rt(x) > 0).sort((x, y) => rt(y) - rt(x)), pos = ranked.indexOf(r) + 1;
  const word = gap >= 30 ? 'divisive' : gap >= 15 ? 'some disagreement' : 'everyone agreed';
  return `<div class="ig ig-l">${poster(r, 'ig-pl')}<div><div class="ig-lbl">Reception</div><h3 class="ig-big">${esc(r.Title)} <span>${r.Year > 0 ? r.Year : ''}</span></h3>
    <div class="ig-split"><div><span class="ig-lbl">Critics (Rotten Tomatoes)</span><b style="color:#ffb37f">${c ? c + '%' : '-'}</b></div><div><span class="ig-lbl">${num(r.RTAudience) ? 'Audience (Rotten Tomatoes)' : 'Audience (IMDb rating)'}</span><b style="color:#7fd0ff">${a ? a + '%' : '-'}</b></div></div>
    ${c && a ? `<span class="ig-lbl">How divided</span><div class="ig-gauge"><i style="left:${Math.min(98, gap / 50 * 100)}%"></i></div><div class="ig-gl"><span>Everyone agreed</span><b>${gap} points apart · ${word}</b><span>Split down the middle</span></div>` : ''}
    <div class="ig-split three"><div><span class="ig-lbl">Metacritic</span><b style="color:#66cc33">${mc(r) || '-'}</b></div><div><span class="ig-lbl">IMDb</span><b style="color:#f5c518">${imdb(r) ? imdb(r).toFixed(1) : '-'}</b></div><div><span class="ig-lbl">In your library</span><b>${pos ? '#' + pos : '-'}</b><small>${pos ? `of ${ranked.length.toLocaleString('en-US')} by critics` : ''}</small></div></div></div>${footer()}</div>`;
}

// ---- one actor (from the library's cast lists) ----
function actorFilms(name) { return movies().filter((r) => castOf(r).includes(name)).sort((a, b) => num(a.Year) - num(b.Year)); }
const avatar = '<div class="ig-avatar"></div>';
function Mc(name) {
  const F = actorFilms(name).filter((r) => r.Year > 0);
  if (!F.length) return `<div class="ig ig-m ig-empty"><h3 class="ig-big">${esc(name)}</h3><p>No movies in your library list ${esc(name)} in their cast.</p></div>`;
  const sv = (r) => score(r, 'avg'), y0 = Math.min(...F.map((r) => r.Year)), y1 = Math.max(y0 + 1, ...F.map((r) => r.Year)), lo = Math.max(0, Math.min(...F.map(sv).filter((x) => x > 0), 100) - 10);
  const W = 1000, H = 340, p = 44, sx = (y) => p + 30 + (y - y0) / (y1 - y0) * (W - 2 * p - 60), sy = (v) => H - p - (v - lo) / Math.max(10, 100 - lo) * (H - 2 * p), mxw = Math.max(1, ...F.map((r) => ww(r)));
  let s = '';
  for (let g = Math.ceil(lo / 10) * 10; g <= 100; g += 20) s += `<line x1="${p}" x2="${W - 10}" y1="${sy(g)}" y2="${sy(g)}" stroke="#1a2232"/><text x="${p - 6}" y="${sy(g) + 4}" text-anchor="end" fill="#5d6c86" font-size="11">${g}</text>`;
  const step = Math.max(1, Math.ceil((y1 - y0) / 10));
  for (let y = y0; y <= y1; y += step) s += `<text x="${sx(y)}" y="${H - 10}" text-anchor="middle" fill="#5d6c86" font-size="11">${y}</text>`;
  const pts = F.filter((r) => sv(r) > 0);
  s += `<polyline fill="none" stroke="#33415c" stroke-width="1.5" points="${pts.map((r) => sx(r.Year) + ',' + sy(sv(r))).join(' ')}"/>`;
  for (const r of pts) s += `<circle cx="${sx(r.Year)}" cy="${sy(sv(r))}" r="${6 + Math.sqrt(ww(r) / mxw) * 26}" fill="${watched(r) ? 'rgba(127,176,255,.75)' : 'rgba(127,176,255,.18)'}" stroke="#7fb0ff" stroke-width="1.5"/>`;
  const best = pts.slice().sort((a, b) => sv(b) - sv(a))[0], big = F.slice().sort((a, b) => ww(b) - ww(a))[0];
  if (best) s += `<text x="${sx(best.Year)}" y="${sy(sv(best)) - 34}" text-anchor="middle" fill="#fff" font-size="12" font-weight="700">${esc(short(best.Title))}</text>`;
  if (big && big !== best && ww(big) > 0 && sv(big) > 0) s += `<text x="${sx(big.Year)}" y="${sy(sv(big)) + 46}" text-anchor="middle" fill="#fff" font-size="12" font-weight="700">${esc(short(big.Title))}</text>`;
  const tot = F.reduce((a, r) => a + ww(r), 0);
  return `<div class="ig ig-m"><div class="ig-head">${avatar}<div><div class="ig-lbl">Career in your library · ${F.length} film${F.length > 1 ? 's' : ''} · ${y0} to ${y1}</div><h3 class="ig-big">${esc(name)}</h3></div></div>
    <svg viewBox="0 0 ${W} ${H}" width="100%" height="100%">${s}</svg>
    <div class="ig-row">${best ? `<span>Best reviewed <b>${esc(short(best.Title, 30))} (${scoreText(best, 'avg')})</b></span>` : ''}${big && ww(big) ? `<span>Biggest <b>${esc(short(big.Title, 30))} (${esc(fmtMoney(ww(big)))})</b></span>` : ''}${tot ? `<span>Worldwide, these films <b>${esc(fmtMoney(tot))}</b></span>` : ''}<span>Height: average score · size: worldwide gross · filled: watched</span></div>${footer()}</div>`;
}
function Np(name) {
  const F = actorFilms(name);
  if (!F.length) return `<div class="ig ig-n ig-empty"><h3 class="ig-big">${esc(name)}</h3><p>No movies in your library list ${esc(name)} in their cast.</p></div>`;
  const top = F.filter((r) => score(r, 'avg') > 0).sort((a, b) => score(b, 'avg') - score(a, 'avg')).slice(0, 5);
  const co = new Map(); for (const r of F) { for (const c of castOf(r)) if (c !== name) co.set(c, (co.get(c) || 0) + 1); if (r.Director) co.set('Director ' + r.Director, (co.get('Director ' + r.Director) || 0) + 1); }
  const coTop = [...co.entries()].filter(([, n]) => n > 1).sort((a, b) => b[1] - a[1]).slice(0, 5);
  const gen = new Map(); for (const r of F) for (const g of genresOf(r)) gen.set(g, (gen.get(g) || 0) + 1);
  const G = [...gen.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6), gt = G.reduce((a, [, n]) => a + n, 0) || 1, cols = ['#b79acb', '#e0805a', '#5aa0e0', '#5ad0b0', '#e0c05a', '#e07a9a'];
  let x = 0; const strip = G.map(([g, n], i) => { const w = n / gt * 960, s = `<rect x="${x + 1}" y="0" width="${Math.max(1, w - 2)}" height="22" rx="4" fill="${cols[i]}"/>${w > 60 ? `<text x="${x + 4}" y="38" fill="#ccc" font-size="12">${esc(g)} · ${n}</text>` : ''}`; x += w; return s; }).join('');
  const mins = F.reduce((a, r) => a + num(r.RuntimeMin), 0);
  return `<div class="ig ig-n"><header>${avatar}<div><div class="ig-lbl">Actor profile · from your library</div><h3 class="ig-big">${esc(name)}</h3><small>${F.length} film${F.length > 1 ? 's' : ''} · ${F.filter(watched).length} watched · ${run(mins)} in all</small></div></header>
    <div class="ig-box"><span class="ig-lbl">Top ${top.length} by average score</span><ol>${top.map((r) => `<li>${esc(short(r.Title, 30))} <small>${r.Year || ''} · ${scoreText(r, 'avg')}</small></li>`).join('')}</ol></div>
    <div class="ig-box"><span class="ig-lbl">Worked with most</span><ol>${coTop.length ? coTop.map(([n, c]) => `<li>${esc(n)} <small>${c} films together</small></li>`).join('') : '<li><small>No one more than once yet</small></li>'}</ol></div>
    <div class="ig-box ig-wide"><span class="ig-lbl">Genres</span><svg viewBox="0 0 960 44" width="100%" height="44">${strip}</svg></div>${footer()}</div>`;
}

// ---- a collection ----
function Ft(name, F) {
  F = F.filter((r) => r.Year > 0).sort((a, b) => a.Year - b.Year);
  const y0 = Math.min(...F.map((r) => r.Year)), y1 = Math.max(y0 + 1, ...F.map((r) => r.Year)), W = 1000, y = 200, x0 = 60, x1 = 940, mx = Math.max(1, ...F.map((r) => ww(r)));
  const sx = (yr, i) => x0 + (F.length > 1 ? ((yr - y0) / (y1 - y0) * .6 + i / (F.length - 1) * .4) : .5) * (x1 - x0);
  let s = `<line x1="${x0}" x2="${x1}" y1="${y}" y2="${y}" stroke="#4a6fd0" stroke-width="5" stroke-linecap="round"/>`;
  const lab = F.length <= 14;
  F.forEach((r, i) => { const x = sx(r.Year, i), up = i % 2 === 0, hh = 20 + ww(r) / mx * 100, yy = up ? y - 12 - hh : y + 12;
    s += `<rect x="${x - 10}" y="${yy}" width="20" height="${hh}" rx="5" fill="rgba(127,170,255,.35)"/><circle cx="${x}" cy="${y}" r="6" fill="#fff"/>`;
    if (lab) { const ty = up ? yy - 22 : yy + hh + 15; s += `<text x="${x}" y="${ty}" text-anchor="middle" fill="#fff" font-size="12" font-weight="700">${esc(short(r.Title, 18))}</text><text x="${x}" y="${ty + 14}" text-anchor="middle" fill="#a9b4d0" font-size="11">${r.Year}${rt(r) ? ' · ' + rt(r) + '%' : ''}${ww(r) ? ' · ' + esc(fmtMoney(ww(r))) : ''}</text>`; } });
  const tot = F.reduce((a, r) => a + ww(r), 0), rts = F.filter((r) => rt(r) > 0), big = F.slice().sort((a, b) => ww(b) - ww(a))[0];
  return `<div class="ig ig-f"><div><div class="ig-lbl">Collection timeline · ${F.length} films · ${y0} to ${Math.max(...F.map((r) => r.Year))}</div><h3 class="ig-big">${esc(name)}</h3></div><svg viewBox="0 0 ${W} 380" width="100%" height="100%">${s}</svg>
    <div class="ig-row">${tot ? `<span>Total worldwide <b>${esc(fmtMoney(tot))}</b></span>` : ''}${rts.length ? `<span>Average Rotten Tomatoes <b>${Math.round(rts.reduce((a, r) => a + rt(r), 0) / rts.length)}%</b></span>` : ''}<span>Marathon <b>${run(F.reduce((a, r) => a + num(r.RuntimeMin), 0))}</b></span>${big && ww(big) ? `<span>Biggest <b>${esc(short(big.Title, 30))}</b></span>` : ''}</div>${footer()}</div>`;
}
function Gr(name, F, k) {
  const r = F.filter((x) => score(x, k) > 0).sort((a, b) => score(b, k) - score(a, k)).slice(0, 12), half = Math.ceil(r.length / 2);
  const row = (x, i) => `<div class="ig-rk"><span class="ig-rn">${i + 1}</span><span>${esc(short(x.Title, 30))}<br><small>${x.Year || ''}</small></span><i><b style="width:${Math.min(100, score(x, k))}%"></b></i><span class="ig-mono">${scoreText(x, k)}</span></div>`;
  return `<div class="ig ig-g"><header><div><div class="ig-lbl">Every film ranked · ${SCORES.find((s) => s[0] === k)[1]}${F.length > 12 ? ' · top 12' : ''}</div><h3 class="ig-big">${esc(name)}</h3></div>${r.length ? `<div class="ig-bw">Best <b>${esc(short(r[0].Title, 26))} ${scoreText(r[0], k)}</b><br>Lowest <b>${esc(short(r[r.length - 1].Title, 26))} ${scoreText(r[r.length - 1], k)}</b></div>` : ''}</header>
    <div class="ig-cols"><div>${r.slice(0, half).map(row).join('')}</div><div>${r.slice(half).map((x, i) => row(x, i + half)).join('')}</div></div>${r.length ? '' : '<p>None of these films has that score yet. Fetch info fills it in.</p>'}${footer()}</div>`;
}
function Hb(name, F, adj) {
  F = F.filter((r) => ww(r, adj) > 0).sort((a, b) => num(a.Year) - num(b.Year)).slice(0, 16);
  const W = 1000, H = 360, pl = 64, pb = 46, mx = Math.max(1, ...F.map((r) => ww(r, adj))) * 1.1, bw = (W - pl - 20) / Math.max(1, F.length), sy = (v) => H - pb - v / mx * (H - pb - 20);
  let s = '';
  for (let i = 0; i <= 3; i++) { const g = mx / 3 * i; s += `<line x1="${pl}" x2="${W - 10}" y1="${sy(g)}" y2="${sy(g)}" stroke="#1b2630"/><text x="${pl - 8}" y="${sy(g) + 4}" text-anchor="end" fill="#6d8496" font-size="11">${esc(i ? fmtMoney(g) : '$0')}</text>`; }
  const best = F.slice().sort((a, b) => ww(b, adj) - ww(a, adj))[0];
  F.forEach((r, i) => { const x = pl + i * bw + bw * .12, w = bw * .76;
    s += `<rect x="${x}" y="${sy(ww(r, adj))}" width="${w}" height="${H - pb - sy(ww(r, adj))}" rx="5" fill="${r === best ? '#3f86b5' : '#2c5f80'}"/>`;
    if (dom(r, adj) > 0) s += `<rect x="${x + w * .2}" y="${sy(dom(r, adj))}" width="${w * .6}" height="${H - pb - sy(dom(r, adj))}" rx="4" fill="#7fd0ff"/>`;
    s += `<text x="${x + w / 2}" y="${sy(ww(r, adj)) - 6}" text-anchor="middle" fill="#e6f4ff" font-size="${F.length > 10 ? 10 : 12}" font-weight="700">${esc(fmtMoney(ww(r, adj)))}</text><text x="${x + w / 2}" y="${H - pb + 16}" text-anchor="middle" fill="#9ab" font-size="10">${esc(short(r.Title, F.length > 10 ? 9 : 14))}</text><text x="${x + w / 2}" y="${H - pb + 30}" text-anchor="middle" fill="#6d8496" font-size="10">${r.Year || ''}</text>`; });
  const tot = F.reduce((a, r) => a + ww(r, adj), 0);
  return `<div class="ig ig-h"><header><div><div class="ig-lbl">Box office · worldwide and domestic${adj ? ' · adjusted for inflation' : ''}</div><h3 class="ig-big">${esc(name)}</h3></div><div class="ig-tot"><span class="ig-lbl">Collection total</span><b>${esc(fmtMoney(tot) || '-')}</b></div></header>
    <svg viewBox="0 0 ${W} ${H}" width="100%" height="100%">${s}</svg><div class="ig-row"><span><i class="ig-key" style="background:#2c5f80"></i> Worldwide</span><span><i class="ig-key" style="background:#7fd0ff"></i> Domestic</span></div>${footer()}</div>`;
}
function Ic(name, F) {
  const sh = F.slice().sort((a, b) => num(a.Year) - num(b.Year)), w = sh.filter(watched).length, best = new Map();
  for (const r of sh) { const k = [r.ResolutionClass, r.HDRStack || r.HDRType].filter((x) => x && x !== 'SDR').join(' '); if (k) best.set(k, (best.get(k) || 0) + 1); }
  const top = [...best.entries()].sort((a, b) => b[1] - a[1])[0];
  return `<div class="ig ig-i"><div><div class="ig-lbl">Your collection</div><h3 class="ig-big">${esc(name)}</h3><div class="ig-shelf">${sh.slice(0, 12).map((r) => `<div>${poster(r, 'ig-pi')}<small>${esc(short(r.Title, 18))}</small><small class="ig-w">${watched(r) ? '✓ watched' : 'unwatched'}</small></div>`).join('')}${sh.length > 12 ? `<div class="ig-more">+${sh.length - 12} more</div>` : ''}</div></div>
    <div class="ig-stats"><div><span class="ig-lbl">In your library</span><b>${sh.length} film${sh.length === 1 ? '' : 's'}</b></div><div><span class="ig-lbl">Watched</span><b>${w} of ${sh.length}</b></div><div><span class="ig-lbl">Marathon</span><b>${run(sh.reduce((a, r) => a + num(r.RuntimeMin), 0)) || '-'}</b></div><div><span class="ig-lbl">On disk</span><b>${fmtSize(sh.reduce((a, r) => a + num(r.FileSizeGB), 0))}</b></div>${top ? `<div><span class="ig-lbl">Best copy</span><b class="ig-small">${esc(top[0])} ×${top[1]}</b></div>` : ''}</div>${footer()}</div>`;
}
// the story order is set by hand for each collection (Settings key igOrder: { name: [rid, ...] })
function storyOrder(name, F) {
  const saved = ((S.state.settings.igOrder || {})[name] || []).filter((rid) => F.some((r) => r.Rid === rid));
  return [...saved.map((rid) => F.find((r) => r.Rid === rid)), ...F.filter((r) => !saved.includes(r.Rid)).sort((a, b) => num(a.Year) - num(b.Year))];
}
function Jo(name, F) {
  const rel = F.slice().sort((a, b) => num(a.Year) - num(b.Year)).slice(0, 12), story = storyOrder(name, F).filter((r) => rel.includes(r));
  const W = 1000, H = 440, lx = 330, rx = 670, step = Math.min(50, (H - 40) / Math.max(1, rel.length)), top = 34;
  let s = `<text x="${lx}" y="16" text-anchor="end" fill="#b79acb" font-size="12" letter-spacing="2">RELEASE ORDER</text><text x="${rx}" y="16" fill="#b79acb" font-size="12" letter-spacing="2">STORY ORDER</text>`;
  rel.forEach((r, i) => { const si = story.indexOf(r), y1 = top + i * step, y2 = top + si * step;
    s += `<path d="M${lx + 10},${y1} C${(lx + rx) / 2},${y1} ${(lx + rx) / 2},${y2} ${rx - 10},${y2}" fill="none" stroke="hsl(${260 + i * 14} 60% 62%)" stroke-width="2.5" opacity=".85"/><text x="${lx}" y="${y1 + 4}" text-anchor="end" fill="#eee" font-size="14">${esc(short(r.Title, 34))} <tspan fill="#8a7a96">${r.Year || ''}</tspan></text>`; });
  story.forEach((r, si) => { s += `<text x="${rx}" y="${top + si * step + 4}" fill="#eee" font-size="14"><tspan fill="#b79acb" font-weight="700">${si + 1}.</tspan> ${esc(short(r.Title, 34))}</text>`; });
  return `<div class="ig ig-j"><div><div class="ig-lbl">Watch order</div><h3 class="ig-big">${esc(name)}</h3></div><svg viewBox="0 0 ${W} ${H}" width="100%" height="100%">${s}</svg>${footer()}</div>`;
}
function Ks(name, F) {
  const P = F.filter((r) => rt(r) > 0 && aud(r) > 0).slice(0, 400), audSrc = P.some((r) => num(r.RTAudience) > 0) ? 'audience score (IMDb rating where there is none)' : 'IMDb rating';
  const W = 640, H = 460, p = 44, sx = (v) => p + v / 100 * (W - p - 14), sy = (v) => H - p - v / 100 * (H - p - 14);
  let s = `<line x1="${sx(0)}" y1="${sy(0)}" x2="${sx(100)}" y2="${sy(100)}" stroke="#333" stroke-dasharray="4 4"/>`;
  for (const g of [20, 40, 60, 80, 100]) s += `<text x="${sx(g)}" y="${H - p + 18}" text-anchor="middle" fill="#777" font-size="11">${g}%</text><text x="${p - 8}" y="${sy(g) + 4}" text-anchor="end" fill="#777" font-size="11">${g}%</text>`;
  s += `<text x="${(W + p) / 2}" y="${H - 6}" text-anchor="middle" fill="#ffb37f" font-size="12">Critics →</text><text x="12" y="${H / 2}" fill="#7fd0ff" font-size="12" transform="rotate(-90 12 ${H / 2})" text-anchor="middle">Audiences →</text><text x="${sx(3)}" y="${sy(97)}" fill="#7fd0ff" font-size="12" opacity=".8">Crowd-pleasers</text><text x="${sx(97)}" y="${sy(3)}" fill="#ffb37f" font-size="12" text-anchor="end" opacity=".8">Critics' darlings</text>`;
  for (const r of P) { const c = rt(r), a = aud(r); s += `<circle cx="${sx(c)}" cy="${sy(a)}" r="${P.length > 150 ? 4 : 6}" fill="${Math.abs(c - a) < 10 ? '#bfe7a0' : a > c ? '#7fd0ff' : '#ffb37f'}" opacity=".85" stroke="#0e0f12" stroke-width="1.5"/>`; }
  const up = P.slice().sort((x, y) => (aud(y) - rt(y)) - (aud(x) - rt(x)))[0], dn = P.slice().sort((x, y) => (rt(y) - aud(y)) - (rt(x) - aud(x)))[0], agree = P.filter((r) => Math.abs(rt(r) - aud(r)) < 10).length;
  for (const r of [up, dn]) if (r) s += `<circle cx="${sx(rt(r))}" cy="${sy(aud(r))}" r="10" fill="none" stroke="#fff" stroke-width="2"/>`;
  const card = (l, r, col) => (r ? `<div><span class="ig-lbl">${l}</span><b style="color:${col}">${esc(short(r.Title, 24))}</b><small>critics ${rt(r)}% · audience ${Math.round(aud(r))}%</small></div>` : '');
  return `<div class="ig ig-k"><div class="ig-kl"><div><div class="ig-lbl">Critics vs audiences · ${P.length} movies · ${esc(name)}</div><h3 class="ig-big">Who agreed?</h3></div>${P.length ? `<svg viewBox="0 0 ${W} ${H}" width="100%" height="100%">${s}</svg>` : '<p>No movies here have both a critics score and an audience score yet.</p>'}</div>
    <div class="ig-kr">${card('Audiences liked it more', up, '#7fd0ff')}${card('Critics liked it more', dn, '#ffb37f')}${P.length ? `<div><span class="ig-lbl">Agreed most often</span><b style="color:#bfe7a0">${agree} of ${P.length}</b><small>within 10 points of each other</small></div>` : ''}<p class="ig-sub">Audience: ${audSrc}</p></div>${footer()}</div>`;
}

// ---- the library: top-grossing actors ----
// an actor's year: the worldwide gross of the films released that year that list them (lead: the first three billed)
function actorYear(year, lead) {
  const t = new Map();
  for (const r of movies()) { if (num(r.Year) !== year || !(ww(r) > 0)) continue; for (const a of castOf(r).slice(0, lead ? 3 : 6)) { const e = t.get(a) || { name: a, films: [], total: 0 }; e.films.push(r); e.total += ww(r); t.set(a, e); } }
  return [...t.values()].map((e) => ({ ...e, films: e.films.sort((a, b) => ww(b) - ww(a)) })).sort((a, b) => b.total - a.total);
}
const grossYears = () => [...new Set(movies().filter((r) => ww(r) > 0 && r.Year > 0 && castOf(r).length).map((r) => num(r.Year)))].sort((a, b) => b - a);
function Ot(year, lead) {
  const rows = actorYear(year, lead).slice(0, 10), mx = Math.max(1, ...rows.map((r) => r.total)), cols = ['#f0c76a', '#c08a3a', '#8a6a2a', '#5e4a20'];
  return `<div class="ig ig-o"><header><div><div class="ig-lbl">Top-grossing actors · worldwide · films released in</div><h3 class="ig-big">${year}</h3></div><div class="ig-bw">Movies in your library only<br>${lead ? 'Lead roles (first three billed)' : 'Any of the top six billed'} · each segment is one film</div></header>
    <div class="ig-orows">${rows.length ? rows.map((e, i) => `<div class="ig-or"><span class="ig-rn">${i + 1}</span>${avatar}<span><b>${esc(short(e.name, 24))}</b><br><small>${e.films.length} film${e.films.length > 1 ? 's' : ''} · top: ${esc(short(e.films[0].Title, 22))}</small></span><i>${e.films.slice(0, 4).map((r, k) => `<b style="width:${ww(r) / mx * 100}%;background:${cols[k]}"></b>`).join('')}</i><span class="ig-mono">${esc(fmtMoney(e.total))}</span></div>`).join('') : '<p>No movies from that year have both a cast list and box office.</p>'}</div>${footer()}</div>`;
}
function Pb(lead) {
  const Y = grossYears().slice(0, 6).reverse();
  if (Y.length < 2) return '<div class="ig ig-p ig-empty"><h3 class="ig-big">Actors over the years</h3><p>This needs box office and cast lists for movies from at least two years.</p></div>';
  const ranks = Y.map((y) => actorYear(y, lead).slice(0, 10).map((e) => e.name));
  const who = []; for (const list of ranks) for (const n of list.slice(0, 3)) if (!who.includes(n)) who.push(n);
  const names = who.slice(0, 8), C = ['#f0c76a', '#7fb0ff', '#ff8a5a', '#7fe0a8', '#c99aff', '#5ad0e0', '#e07a9a', '#d0d070'];
  const W = 1000, H = 440, lx = 80, rx = 790, sx = (i) => lx + i / (Y.length - 1) * (rx - lx), sy = (r) => 30 + (r - 1) * 40;
  let s = Y.map((y, i) => `<text x="${sx(i)}" y="${H - 6}" text-anchor="middle" fill="#777" font-size="12">${y}</text>`).join('');
  for (let r = 1; r <= 10; r++) s += `<text x="${lx - 30}" y="${sy(r) + 4}" text-anchor="end" fill="#555" font-size="12">#${r}</text>`;
  names.forEach((n, k) => { const c = C[k], rk = ranks.map((l) => (l.indexOf(n) >= 0 ? l.indexOf(n) + 1 : null)); let d = '', pen = false;
    rk.forEach((r, i) => { if (r == null) { pen = false; return; } d += (pen ? 'L' : 'M') + sx(i) + ',' + sy(r); pen = true; });
    s += `<path d="${d}" fill="none" stroke="${c}" stroke-width="3.5" stroke-linejoin="round" opacity=".9"/>` + rk.map((r, i) => (r == null ? '' : `<circle cx="${sx(i)}" cy="${sy(r)}" r="6" fill="${c}" stroke="#0c0d12" stroke-width="2"/>`)).join('');
    const last = rk.length - 1 - [...rk].reverse().findIndex((r) => r != null);
    s += `<text x="${sx(last) + 12}" y="${sy(rk[last]) + 4}" fill="${c}" font-size="13" font-weight="700">${esc(short(n, 22))}</text>`; });
  return `<div class="ig ig-p"><div><div class="ig-lbl">Top-grossing actors · rank by year · movies in your library</div><h3 class="ig-big">${Y[0]} to ${Y[Y.length - 1]}</h3></div><svg viewBox="0 0 ${W} ${H}" width="100%" height="100%">${s}</svg>${footer()}</div>`;
}

// ---- saving ----
async function savePng(node, name) {
  const W = node.offsetWidth, H = node.offsetHeight, clone = node.cloneNode(true);
  inlineStyles(node, clone);
  for (const im of [...clone.querySelectorAll('img')]) { const d = await imageAsDataUrl(im.getAttribute('src')); if (d) im.setAttribute('src', d); else im.remove(); }
  clone.style.transform = 'none';
  const xml = new XMLSerializer().serializeToString(clone);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><foreignObject x="0" y="0" width="${W}" height="${H}">${xml}</foreignObject></svg>`;
  const img = await loadImage('data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg));
  const c = document.createElement('canvas'); c.width = W * 2; c.height = H * 2;
  const g = c.getContext('2d'); g.scale(2, 2); g.drawImage(img, 0, 0, W, H);
  const blob = await new Promise((ok) => c.toBlob(ok, 'image/png'));
  if (!blob) throw new Error('The picture came out empty.');
  const data = await blobToDataUrl(blob);
  return S.savePicture(name.replace(/[\\/:*?"<>|]+/g, '_').trim(), data.slice(data.indexOf(',') + 1));
}

// ---- the window ----
// ctx: { kind: 'movie', r } | { kind: 'pair', a, b } | { kind: 'collection', name } | { kind: 'library' }
export function openInfographic(ctx, toast = S.toast || (() => {})) {
  const list = LAYOUTS[ctx.kind];
  const st = { lay: list[0][0], score: 'rt', adj: false, dark: false, lead: true, year: grossYears()[0] || new Date().getFullYear(), actor: ctx.kind === 'movie' ? castOf(ctx.r)[0] || '' : '' };
  const rows = () => {
    if (ctx.kind !== 'collection') return movies();
    const c = S.state.collections.find((x) => x.name === ctx.name);
    return c ? movies().filter((r) => c.has(r)) : [];
  };
  overlay((close) => {
    const stage = h('div', { class: 'ig-stage' }), opts = h('div', { class: 'ig-opts' }), side = h('div', { class: 'ig-order' });
    const saveBtn = h('button', { class: 'btn primary', type: 'button', onclick: async () => {
      const node = stage.querySelector('.ig'); if (!node || saveBtn.disabled) return;
      saveBtn.disabled = true; saveBtn.textContent = 'Saving...';
      try { toast('Saved: ' + await savePng(node, `${title()} - ${list.find((l) => l[0] === st.lay)[1]}`)); } catch (e) { toast('Could not save the picture: ' + e.message); }
      saveBtn.disabled = false; saveBtn.textContent = 'Save as picture';
    } }, 'Save as picture');
    const title = () => (ctx.kind === 'movie' ? (['M', 'N'].includes(st.lay) ? st.actor : ctx.r.Title) : ctx.kind === 'pair' ? `${ctx.a.Title} vs ${ctx.b.Title}` : ctx.kind === 'collection' ? ctx.name : st.lay === 'O' ? `Top-grossing actors ${st.year}` : 'Library');
    const html = () => {
      const F = rows(), nm = ctx.kind === 'collection' ? ctx.name : 'your library';
      switch (st.lay) {
        case 'A': return A(ctx.r); case 'B': return B(ctx.r); case 'C': return C(ctx.r); case 'D': return D(ctx.r, st.dark); case 'L': return Lr(ctx.r);
        case 'M': return Mc(st.actor); case 'N': return Np(st.actor); case 'E': return E(ctx.a, ctx.b);
        case 'F': return Ft(nm, F); case 'G': return Gr(nm, F, st.score); case 'H': return Hb(nm, F, st.adj); case 'I': return Ic(nm, F); case 'J': return Jo(nm, F); case 'K': return Ks(nm, F);
        case 'O': return Ot(st.year, st.lead); case 'P': return Pb(st.lead);
      }
      return '';
    };
    const fit = () => { const n = stage.firstElementChild; if (!n) return; const k = Math.min(1, (stage.clientWidth - 2) / n.offsetWidth); n.style.transform = `scale(${k})`; stage.style.height = Math.ceil(n.offsetHeight * k) + 'px'; };
    const sel = (label, val, items, on) => h('label', null, label + ' ', h('select', { 'aria-label': label, onchange: (e) => on(e.target.value) }, ...items.map(([k, t]) => h('option', { value: k, selected: String(k) === String(val) ? true : null }, t))));
    const tick = (label, on, set) => h('label', null, h('input', { type: 'checkbox', checked: on ? true : null, onchange: (e) => set(e.target.checked) }), ' ' + label);
    const paint = () => {
      stage.innerHTML = html(); requestAnimationFrame(fit);
      const o = [];
      if (['M', 'N'].includes(st.lay)) o.push(sel('Actor', st.actor, castOf(ctx.r).map((a) => [a, a]), (v) => { st.actor = v; paint(); }));
      if (st.lay === 'D') o.push(tick('Plain dark', st.dark, (v) => { st.dark = v; paint(); }));
      if (st.lay === 'G') o.push(sel('Score', st.score, SCORES, (v) => { st.score = v; paint(); }));
      if (st.lay === 'H') o.push(tick('Adjust for inflation', st.adj, (v) => { st.adj = v; paint(); }));
      if (st.lay === 'O') o.push(sel('Year', st.year, (grossYears().length ? grossYears() : [st.year]).map((y) => [y, String(y)]), (v) => { st.year = +v; paint(); }));
      if (['O', 'P'].includes(st.lay)) o.push(tick('Lead roles only', st.lead, (v) => { st.lead = v; paint(); }));
      opts.replaceChildren(...o);
      // the story order, set by hand
      side.replaceChildren();
      if (st.lay === 'J') {
        const order = storyOrder(ctx.name, rows()).slice(0, 12);
        const move = async (i, d) => { const o2 = order.map((r) => r.Rid); [o2[i], o2[i + d]] = [o2[i + d], o2[i]]; await S.saveSettings({ igOrder: { ...(S.state.settings.igOrder || {}), [ctx.name]: o2 } }); paint(); };
        side.append(h('p', null, h('small', null, 'Story order: move films up or down. It is kept for this collection.')),
          ...order.map((r, i) => h('div', { class: 'ig-ordrow' }, h('span', null, `${i + 1}. ${short(r.Title, 34)}`),
            h('button', { class: 'btn', type: 'button', 'aria-label': `Move ${r.Title} up`, disabled: i ? null : true, onclick: () => move(i, -1) }, '↑'),
            h('button', { class: 'btn', type: 'button', 'aria-label': `Move ${r.Title} down`, disabled: i < order.length - 1 ? null : true, onclick: () => move(i, 1) }, '↓'))));
      }
    };
    const chips = h('div', { class: 'seg ig-lays', role: 'tablist', 'aria-label': 'Layout' }, ...list.map(([k, t]) => h('button', { type: 'button', class: st.lay === k ? 'active' : '', 'data-lay': k, onclick: (e) => { st.lay = k; chips.querySelectorAll('button').forEach((b) => b.classList.toggle('active', b === e.currentTarget)); paint(); } }, t)));
    const box = h('div', { class: 'ig-win' }, h('div', { class: 'ig-top' }, h('h2', null, 'Infographic'), chips, opts, h('span', { style: { flex: 1 } }), saveBtn, h('button', { class: 'btn', type: 'button', onclick: close }, 'Close')), stage, side);
    paint();
    const ro = new ResizeObserver(fit); ro.observe(stage);
    return box;
  }, 'ig-host');
}
