// Compare (Movies > Compare): two titles, or two collections, head to head on box office and critics.
// A round is one stat row; the higher value wins it, a tie or a missing value counts for nobody.
// Collections compare their aggregates (totals and averages), then play a tournament: each side's films ranked by
// worldwide gross, #1 vs #1 down to #10 vs #10. What is compared: metrics.js (Settings > Compare, or the Metrics
// button). The plain look is the default; Fun mode (Settings > Compare) adds the poster borders and the VS (Settings > Fun).
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { h } from '../util.js';
import { num, fmtMoney, dedupe, logoOrTitle, artUrl } from '../common.js';
import { overlay } from './settings.js';
import { inTab } from './collections.js';
import { openCard } from './card.js';
import { fetchDialog } from './tools.js';
import { BASE_YEAR } from '../inflation.js';
import { chosen, val, GROUPS, infl, openMetrics, needsMediaInfo, MAX_SCORED } from '../metrics.js';
import { tune, mult, vsColors } from '../fxtune.js';
import { themeFx } from '../fxthemes.js';

const CAP = 10;
// what is being compared; kept for the session so a tab switch comes back to the same match-up
export const pick = { mode: 'movie', left: '', right: '', cLeft: '', cRight: '' };

const money = (n) => fmtMoney(n) || '';
const pct = (n) => (num(n) > 0 ? Math.round(num(n)) + '%' : '');
// box office, inflation-adjusted when "Adjust for inflation" is on (inflation.js, BASE_YEAR dollars)
const bo = (f) => (infl() ? f + 'Adj' : f);
const fun = () => !!S.state.settings.cmpFun;

// -1 left wins, 1 right wins, 0 nobody
const judge = (a, b) => { a = num(a); b = num(b); if (a <= 0 || b <= 0 || a === b) return 0; return a > b ? -1 : 1; };

// One movie against another over the scored metrics: { l, r }
function duel(a, b, list) {
  let l = 0, r = 0;
  for (const d of list) { const w = judge(val(d, a), val(d, b)); if (w < 0) l++; else if (w > 0) r++; }
  return { l, r };
}

// ---- collections -------------------------------------------------------------------------------------------------
function members(c) {
  const L = S.state.libs.movies;
  const f = bo('BoxOfficeWorldwide');
  return dedupe(L.rows.filter((r) => c.has(r))).sort((a, b) => num(b[f]) - num(a[f]) || num(b.BoxOfficeWorldwide) - num(a.BoxOfficeWorldwide));
}
// Aggregate: box office as totals, everything else as averages over the films that have it
function aggregate(list, defs) {
  const o = { _agg: true, count: list.length, top: list[0] || null };
  for (const d of defs) {
    const v = list.map((r) => val(d, r)).filter((x) => x > 0);
    o[d.id] = d.g === 'box' ? v.reduce((t, x) => t + x, 0) : v.length ? v.reduce((t, x) => t + x, 0) / v.length : 0;
  }
  return o;
}
const aggLabel = (d) => ({ ...d, k: (d.g === 'box' ? 'Total ' : 'Avg ') + d.k.toLowerCase() });

// ---- borders -----------------------------------------------------------------------------------------------------
const colourCache = new Map();
function hexToHsl(hex) {
  const n = parseInt(hex.slice(1), 16), r = (n >> 16) / 255, g = ((n >> 8) & 255) / 255, b = (n & 255) / 255;
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, d = mx - mn;
  if (!d) return [0, 0, l];
  const s = d / (1 - Math.abs(2 * l - 1));
  let hh = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
  hh *= 60; if (hh < 0) hh += 360;
  return [hh, s, l];
}
async function sampleCanvas(url) {
  const img = new Image(); img.crossOrigin = 'anonymous'; img.src = url;
  await img.decode();
  const c = document.createElement('canvas'); c.width = 24; c.height = 36;
  const g = c.getContext('2d'); g.drawImage(img, 0, 0, 24, 36);
  const px = g.getImageData(0, 0, 24, 36).data, bins = new Map();
  for (let i = 0; i < px.length; i += 4) {
    const hex = '#' + [px[i], px[i + 1], px[i + 2]].map((x) => x.toString(16).padStart(2, '0')).join('');
    const [hh, s, l] = hexToHsl(hex); if (l < 0.12 || l > 0.92) continue;
    const w = s * (1 - Math.abs(l - 0.5)); if (w <= 0.05) continue;
    const k = Math.floor(hh / 20), o = bins.get(k) || { w: 0, r: 0, g: 0, b: 0 };
    o.w += w; o.r += px[i] * w; o.g += px[i + 1] * w; o.b += px[i + 2] * w; bins.set(k, o);
  }
  return [...bins.values()].sort((a, b) => b.w - a.w).slice(0, 2).map((o) => '#' + [o.r, o.g, o.b].map((x) => Math.round(x / o.w).toString(16).padStart(2, '0')).join(''));
}
// The poster's two main colours ([] when unknown). Read from the local cache by the host (no network).
async function posterColours(url) {
  if (!url) return [];
  if (colourCache.has(url)) return colourCache.get(url);
  let out = [];
  try { out = bridge.isHost && /^https:\/\/mmlm\.cache\//.test(url) ? (await bridge.request('poster.colours', { url })).colours || [] : await sampleCanvas(url); } catch (e) { out = []; }
  colourCache.set(url, out);
  return out;
}
// Auto: red/orange -> fire, deep blue -> water, pale blue or grey-white -> lightning, green -> spectral,
// brown/olive -> nature; anything else glows in the poster's own colours
function autoFx(cols, side) {
  if (!cols.length) return side === 'l' ? 'fire' : 'water';
  const [hh, s, l] = hexToHsl(cols[0]);
  if (s < 0.18) return l > 0.6 ? 'lightning' : 'poster';
  if (hh < 30 || hh >= 335) return 'fire';
  if (hh < 60) return l < 0.45 ? 'nature' : 'fire';
  if (hh < 80) return 'nature';
  if (hh < 170) return 'specter';
  if (hh < 255) return l > 0.65 ? 'lightning' : 'water';
  return 'poster';
}
const FX_NAMES = [['auto', 'Auto'], ['fire', 'Fire'], ['water', 'Water'], ['specter', 'Spectral'], ['lightning', 'Lightning'], ['nature', 'Nature'], ['poster', 'Poster colours'], ['off', 'Off']];
async function applyFx(el, url, setting, side) {
  const cols = await posterColours(url);
  const fx = setting === 'auto' ? autoFx(cols, side) : setting;
  el.classList.remove(...FX_NAMES.map((x) => 'fx-' + x[0]));
  el.classList.add('fx-' + fx);
  const c1 = cols[0] || '#8ea4ff', c2 = cols[1] || cols[0] || '#b06cff';
  el.style.setProperty('--fx1', c1); el.style.setProperty('--fx2', c2);
  el.dataset.fx = fx;
  flames(el, fx === 'fire');
  themeFx(el, fx);                                      // water, spectral, lightning, nature (fxthemes.js)
  // the side's colour for its bars, score and winner marks
  const tone = { fire: '#ff9a3c', water: '#4aa8ff', lightning: '#cfe6ff', specter: '#5fe39a', nature: '#8fbf4a', poster: c1 }[fx];
  const root = el.closest('.cmp');
  if (root) { if (tone) root.style.setProperty(side === 'l' ? '--cl' : '--cr', tone); else root.style.removeProperty(side === 'l' ? '--cl' : '--cr'); }
}

// ---- real flames for the Fire effect -----------------------------------------------------------------------------------
// A canvas behind the poster, a little larger than it, where small embers rise off every edge and fade from white-hot
// to yellow, orange, red and smoke. "Calm" motion burns lower and slower; "Still" (or the system's reduce-motion
// setting) keeps the steady glow with no animation. Stops by itself once the poster leaves the page.
const FLAME_PAD = { x: 34, top: 96, bottom: 20 };
let flameSprite = null;
function flameSpriteImg() {
  if (flameSprite) return flameSprite;
  const c = document.createElement('canvas'); c.width = c.height = 64;
  const g = c.getContext('2d'), gr = g.createRadialGradient(32, 32, 0, 32, 32, 32);
  gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(0.35, 'rgba(255,255,255,.55)'); gr.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = gr; g.fillRect(0, 0, 64, 64);
  return (flameSprite = c);
}
// one sprite per heat step, tinted once (white-hot -> yellow -> orange -> red -> dark red)
const FLAME_STEPS = ['#ffe9a8', '#ffd25a', '#ffb02e', '#ff8a1a', '#ff640c', '#e8400a', '#b8220a', '#6e1206', '#3a0a04'];
let flameTints = null;
function flameTint(i) {
  if (!flameTints) flameTints = FLAME_STEPS.map((col) => {
    const c = document.createElement('canvas'); c.width = c.height = 64; const g = c.getContext('2d');
    g.drawImage(flameSpriteImg(), 0, 0); g.globalCompositeOperation = 'source-in'; g.fillStyle = col; g.fillRect(0, 0, 64, 64);
    return c;
  });
  return flameTints[Math.max(0, Math.min(FLAME_STEPS.length - 1, i))];
}
function flames(el, on) {
  el._flames?.stop(); el._flames = null;
  el.classList.remove('fx-flames');
  if (!on) return;
  const still = () => el.closest('.motion-still') || matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (still()) return;                                   // the CSS glow stays, without motion
  const cv = document.createElement('canvas'); cv.className = 'fx-flame-canvas'; cv.setAttribute('aria-hidden', 'true');
  el.prepend(cv); el.classList.add('fx-flames');
  const g = cv.getContext('2d');
  let W = 0, H = 0, w = 0, hgt = 0, dpr = 1, raf = 0, last = 0, seen = false, parts = [], acc = 0;
  const size = () => {
    w = el.clientWidth; hgt = el.clientHeight; dpr = Math.min(2, window.devicePixelRatio || 1);
    W = w + FLAME_PAD.x * 2; H = hgt + FLAME_PAD.top + FLAME_PAD.bottom;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); cv.style.width = W + 'px'; cv.style.height = H + 'px';
  };
  // where a new ember starts: anywhere on the poster's edge, most often along the bottom and up the sides
  const spawn = (calm) => {
    const ox = FLAME_PAD.x, oy = FLAME_PAD.top, r = Math.random();
    let x, y;
    let out = 0;                                         // which way the ember drifts: away from the poster's sides
    if (r < 0.18) { x = ox + Math.random() * w; y = oy + hgt + 2; }
    else if (r < 0.7) { const left = Math.random() < 0.5; out = left ? -1 : 1; x = ox + (left ? -2 : w + 2) + (Math.random() - 0.5) * 5; y = oy + Math.pow(Math.random(), 0.6) * hgt; }
    else { x = ox + Math.random() * w; y = oy + 1; }
    const life = (calm ? 1.25 : 0.85) + Math.random() * 0.6;
    parts.push({ x, y, vx: (Math.random() - 0.5) * 10 + out * (6 + Math.random() * 10), vy: -(calm ? 28 : 46) - Math.random() * (calm ? 26 : 44), size: (5 + Math.random() * 8) * mult(tune().poster.size), age: 0, life, wob: Math.random() * 6.28 });
  };
  const frame = (t) => {
    raf = requestAnimationFrame(frame);
    if (!el.isConnected) { if (seen) stop(); return; }
    if (!seen) { seen = true; size(); last = t; return; }
    if (el.clientWidth !== w || el.clientHeight !== hgt) size();
    if (still()) { stop(); return; }
    const calm = !!el.closest('.motion-calm');
    const dt = Math.min(0.05, (t - last) / 1000); last = t;
    const perim = 2 * (w + hgt);
    const pt = tune().poster;
    acc += dt * perim * (calm ? 0.45 : 1.0) * mult(pt.int);   // embers per second grow with the poster's size and the Posters intensity
    while (acc >= 1 && parts.length < 1600) { spawn(calm); acc--; }
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, H);
    g.globalCompositeOperation = 'lighter';
    const keep = [];
    for (const p of parts) {
      p.age += dt;
      const k = p.age / p.life;
      if (k >= 1) continue;
      p.wob += dt * 7;
      p.x += (p.vx + Math.sin(p.wob) * 10) * dt; p.y += p.vy * dt; p.vy -= 18 * dt;   // flicker sideways, speed up as it rises
      const sz = p.size * (1 - k * 0.65);
      g.globalAlpha = 0.55 * (1 - k) * (k < 0.1 ? k / 0.1 : 1);
      g.drawImage(flameTint(Math.floor(k * FLAME_STEPS.length)), p.x - sz, p.y - sz * 1.9, sz * 2, sz * 3.4);   // tall, thin tongues
      keep.push(p);
    }
    parts = keep; g.globalAlpha = 1;
  };
  const stop = () => { cancelAnimationFrame(raf); cv.remove(); el.classList.remove('fx-flames'); if (el._flames === api) el._flames = null; };
  const api = { stop };
  el._flames = api;
  raf = requestAnimationFrame(frame);
}

// ---- pieces --------------------------------------------------------------------------------------------------------
function posterBox(r, side, label, small) {
  const box = h('div', { class: `cmp-poster${small ? ' small' : ''}`, 'data-side': side, title: label || '' },
    r?.Poster ? h('img', { src: r.Poster, alt: '' }) : h('div', { class: 'cmp-ph' }, label || '?'));
  if (fun()) {
    const t = tune().poster;
    box.style.setProperty('--gk', t.on ? mult(t.int).toFixed(2) : '0');
    applyFx(box, r?.Poster, t.on ? (S.state.settings[side === 'l' ? 'fxLeft' : 'fxRight'] || 'auto') : 'off', side);
  }
  return box;
}
function vsMark() {
  if (!fun()) return h('div', { class: 'cmp-exec', 'aria-hidden': 'true' }, 'Comparison');   // the plain look; Fun mode has the VS
  const st = S.state.settings.vsStyle || 'arcade';
  if (st === 'off') return null;
  if (st !== 'arcade') return h('div', { class: `cmp-vs ${st}`, 'aria-hidden': 'true' }, 'VS');
  // the fiery VS: its colours (Settings > Versus), size and glow, and embers rising off it
  const t = tune(), [c1, c2, c3] = vsColors();
  const vs = h('div', { class: `cmp-vs arcade${t.vs.on ? ' vs-fire' : ''}`, 'aria-hidden': 'true',
    style: { '--vs1': c1, '--vs2': c2, '--vs3': c3, '--vs-scale': (0.7 + 0.6 * t.vs.size / 100).toFixed(2), '--vk': t.vs.on ? mult(t.vs.int).toFixed(2) : '0' } }, 'VS');
  const wrap = h('div', { class: 'vs-wrap' }, vs);
  if (t.embers.on && t.vs.on) {
    const n = Math.round(4 + 14 * t.embers.int / 100), ek = mult(t.embers.size);
    for (let i = 0; i < n; i++) {
      const col = [c1, c2, c3][i % 3];
      wrap.append(h('span', { class: 'vs-ember', style: { left: `${18 + ((i * 37) % 64)}%`, background: col, boxShadow: `0 0 6px ${col}`, '--d': `${(1.2 + ((i * 7) % 10) / 10).toFixed(1)}s`, '--delay': `${((i * 0.37) % 1.6).toFixed(2)}s`, '--dx': `${((i % 5) - 2) * 6}px`, '--ek': ek.toFixed(2), width: `${Math.round(5 * ek)}px`, height: `${Math.round(8 * ek)}px` } }));
    }
  }
  return wrap;
}
function statPanel(title, defs, a, b, info) {
  let lw = 0, rw = 0;
  // a row only some titles can have (opening weekend is typed in by hand) shows only when one side has it
  defs = defs.filter((d) => !d.optional || val(d, a) > 0 || val(d, b) > 0);
  const rows = defs.map((d) => {
    const av = val(d, a), bv = val(d, b), w = info ? 0 : judge(av, bv), mx = Math.max(av, bv) || 1;
    if (w < 0) lw++; else if (w > 0) rw++;
    return h('div', { class: 'cmp-row' },
      h('span', { class: `v l${w < 0 ? ' win' : ''}` }, d.fmt(av) || '—'),
      h('div', { class: 'bar l' }, h('i', { style: { width: (av / mx * 100) + '%' } })),
      h('span', { class: 'k' }, d.k),
      h('div', { class: 'bar r' }, h('i', { style: { width: (bv / mx * 100) + '%' } })),
      h('span', { class: `v r${w > 0 ? ' win' : ''}` }, d.fmt(bv) || '—'));
  });
  return { el: h('section', { class: `cmp-panel card${info ? ' info' : ''}` }, h('h2', null, h('span', null, title), info ? null : h('span', { class: 'tally' }, `${lw} – ${rw}`)), ...rows), l: lw, r: rw };
}
// One panel per group that has a chosen metric, then the information rows; returns the panels and the totals
function panels(a, b, coll) {
  const { scored, info } = chosen();
  const out = [], how = [];
  let l = 0, r = 0;
  for (const [g, title] of GROUPS) {
    if (g === 'info') continue;
    let defs = scored.filter((d) => d.g === g);
    if (!defs.length) continue;
    if (coll) defs = defs.map(aggLabel);
    const t = g === 'box' && infl() ? `${title} (${coll ? 'all films, ' : ''}${BASE_YEAR} dollars)` : coll && g === 'box' ? `${title} (all films)` : coll ? `${title} (averages)` : title;
    const p = statPanel(t, defs, a, b, false);
    out.push(p.el); l += p.l; r += p.r;
    how.push(`${p.l}–${p.r} ${g === 'box' ? 'at the box office' : g === 'crit' ? 'with critics' : g === 'file' ? 'on the file' : 'on brightness'}`);
  }
  if (info.length) out.push(statPanel(coll ? 'For information (averages)' : 'For information', coll ? info.map(aggLabel) : info, a, b, true).el);
  return { out, l, r, how: how.join(', ') };
}
function metricsBtn(redraw) {
  const { scored } = chosen();
  return h('button', { class: 'btn cmp-metrics', type: 'button', title: 'Choose what is compared', onclick: () => openMetrics(redraw) }, `Metrics (${scored.length} of ${MAX_SCORED})`);
}
// Brightness: MediaInfo reads the two files the first time they are compared (in the background, no network)
const miTried = new Set();
function brightnessNote(list) {
  if (!needsMediaInfo()) return null;
  const want = list.filter((r) => r && !S.state.mi[r.Rid] && !miTried.has(r.Rid));
  if (want.length && !S.state.miRun?.running) { want.forEach((r) => miTried.add(r.Rid)); S.readMediaInfo(want.map((r) => r.Rid)).catch(() => { /* not set up: the note says so */ }); }
  const missing = list.filter((r) => r && !(S.state.mi[r.Rid] && !S.state.mi[r.Rid][2]));
  if (!missing.length) return null;
  return h('div', { class: 'cmp-hint' },
    h('span', null, S.state.miRun?.running ? 'MediaInfo is reading the files for brightness...' : 'Brightness comes from MediaInfo reading the file. It needs MediaInfo on this PC and a file it can reach.'),
    h('button', { class: 'btn', type: 'button', onclick: () => import('./settings.js').then((m) => m.openSettings('compare')) }, 'MediaInfo settings'));
}
function seg(cur, opts, onPick, label) {
  return h('div', { class: 'seg', role: 'tablist', 'aria-label': label }, opts.map(([k, t]) =>
    h('button', { type: 'button', class: cur === k ? 'active' : '', 'aria-selected': cur === k ? 'true' : 'false', onclick: () => onPick(k) }, t)));
}

// Picker overlays
function chooseMovie(cur, onPick) {
  const L = S.state.libs.movies;
  const all = dedupe(L.rows).slice().sort((a, b) => num(b.BoxOfficeWorldwide) - num(a.BoxOfficeWorldwide) || String(a.Title).localeCompare(b.Title));
  overlay((close) => {
    const list = h('div', { class: 'cmp-pick-list' });
    const input = h('input', { type: 'search', placeholder: 'Type a title', spellcheck: 'false', autocomplete: 'off' });
    const paint = () => {
      const q = input.value.trim().toLowerCase();
      const hits = (q ? all.filter((r) => String(r.Title).toLowerCase().includes(q)) : all).slice(0, 60);
      list.replaceChildren(...hits.map((r) => h('button', { type: 'button', class: r.Rid === cur ? 'on' : '', onclick: () => { close(); onPick(r.Rid); } },
        h('span', null, r.Title, r.Year > 0 ? h('small', null, ` ${r.Year}`) : null), h('small', null, money(r.BoxOfficeWorldwide)))));
      if (!hits.length) list.append(h('p', null, h('small', null, 'No title matches.')));
    };
    input.addEventListener('input', paint);
    paint(); setTimeout(() => input.focus(), 0);
    return h('div', { class: 'cmp-pick' }, h('h2', null, 'Pick a movie'), input, list);
  });
}
function chooseCollection(cur, onPick) {
  const cols = S.state.collections.filter((c) => inTab(c, 'movies'));
  overlay((close) => h('div', { class: 'cmp-pick' }, h('h2', null, 'Pick a collection'),
    cols.length ? h('div', { class: 'cmp-pick-list' }, cols.map((c) => h('button', { type: 'button', class: c.name === cur ? 'on' : '', onclick: () => { close(); onPick(c.name); } },
      h('span', null, c.name), h('small', null, `${members(c).length} films`))))
      : h('p', null, 'No movie collections yet. Make one with Collection mode in Posters or Grid.')));
}

// ---- the view ----------------------------------------------------------------------------------------------------
export function render(el, redraw, toast) {
  const L = S.state.libs.movies;
  const s = S.state.settings;
  const motion = s.fxMotion || 'full';
  const root = h('div', { class: `cmp motion-${motion}` });
  const byRid = new Map(L.rows.map((r) => [r.Rid, r]));
  const ranked = dedupe(L.rows).slice().sort((a, b) => num(b.BoxOfficeWorldwide) - num(a.BoxOfficeWorldwide));
  if (!byRid.has(pick.left)) pick.left = ranked[0]?.Rid || '';
  if (!byRid.has(pick.right) || pick.right === pick.left) pick.right = ranked.find((r) => r.Rid !== pick.left)?.Rid || '';
  const cols = S.state.collections.filter((c) => inTab(c, 'movies'));
  const colBy = (n) => cols.find((c) => c.name === n);
  if (!colBy(pick.cLeft)) pick.cLeft = cols[0]?.name || '';
  if (!colBy(pick.cRight) || pick.cRight === pick.cLeft) pick.cRight = cols.find((c) => c.name !== pick.cLeft)?.name || '';

  const bar = h('div', { class: 'cmp-tools' },
    seg(pick.mode, [['movie', 'Movie vs movie'], ['collection', 'Collection vs collection']], (k) => { pick.mode = k; redraw(); }, 'Compare mode'),
    h('button', { class: 'btn', type: 'button', title: 'Swap sides', onclick: () => {
      if (pick.mode === 'movie') [pick.left, pick.right] = [pick.right, pick.left]; else [pick.cLeft, pick.cRight] = [pick.cRight, pick.cLeft];
      redraw();
    } }, 'Swap sides'),
    h('label', { class: 'cmp-infl', title: `Box office in ${BASE_YEAR} dollars, adjusted for US inflation from each release year (worldwide is approximate)` },
      h('input', { type: 'checkbox', checked: infl() ? true : null, onchange: (e) => S.saveSettings({ cmpInflation: e.target.checked }).then(redraw) }), ' Adjust for inflation'),
    fun() ? h('button', { class: 'btn', type: 'button', title: 'Border effects and the VS', onclick: () => import('./settings.js').then((m) => m.openSettings('fun', redraw)) }, 'Effects') : null);
  root.append(bar);

  const tallyOn = s.cmpTally !== false;
  if (pick.mode === 'movie') {
    const a = byRid.get(pick.left), b = byRid.get(pick.right);
    if (!a || !b) { root.append(h('div', { class: 'state' }, h('p', null, 'Compare needs at least two movies in the library.'))); el.replaceChildren(root); return; }
    const nameEl = (r) => { const d = h('div', { class: 'cmp-name' }); d.innerHTML = logoOrTitle(r, r.Title, 'span'); return d; };
    const sideBox = (r, side) => h('div', { class: `cmp-side${artUrl(r) ? ' has-art' : ''}`, style: artUrl(r) ? { '--art': `url('${artUrl(r).replace(/'/g, '%27')}')` } : null },
      h('button', { type: 'button', class: 'cmp-pbtn', title: 'Open its card', onclick: () => openCard(r, toast) }, posterBox(r, side, r.Title)),
      nameEl(r), h('small', null, [r.Year > 0 ? r.Year : '', String(r.Genre || '').split(',')[0]].filter(Boolean).join(' · ')),
      h('button', { class: 'btn', type: 'button', onclick: () => chooseMovie(side === 'l' ? pick.left : pick.right, (rid) => { if (side === 'l') pick.left = rid; else pick.right = rid; redraw(); }) }, 'Change title'));
    const P = panels(a, b, false), l = P.l, r = P.r;
    root.append(h('div', { class: 'cmp-stage' }, sideBox(a, 'l'),
      h('div', { class: 'cmp-mid' }, metricsBtn(redraw), vsMark(), tallyOn ? h('small', { class: 'lbl' }, fun() ? 'Rounds won' : 'Metrics led') : null, tallyOn ? h('div', { class: 'cmp-score' }, h('b', { class: 'l' }, String(l)), h('span', null, '–'), h('b', { class: 'r' }, String(r))) : null),
      sideBox(b, 'r')));
    if (fun() && tallyOn) { const sb = skullBar(l, r, Math.min(MAX_SCORED, chosen().scored.length)); if (sb) root.append(sb); }
    root.append(h('div', { class: 'cmp-panels' }, ...P.out));
    for (const x of [fetchHint([a, b]), brightnessNote([a, b])]) if (x) root.append(x);
    if (tallyOn) root.append(banner(l, r, a.Title, b.Title, P.how));
    root.append(h('p', { class: 'cmp-note' }, h('small', null, 'Each row goes to the bigger number; ties and missing numbers count for nobody. Box office and Metacritic come from Tools > Fetch info; brightness from MediaInfo.')));
    el.replaceChildren(root);
    return;
  }

  // collection vs collection
  const ca = colBy(pick.cLeft), cb = colBy(pick.cRight);
  if (!ca || !cb) {
    root.append(h('div', { class: 'state' }, h('p', null, 'Collection vs collection needs two movie collections. Make them with Collection mode in Posters or Grid (tick Collection mode, name it, click the + on titles, then Done).')));
    el.replaceChildren(root); return;
  }
  const ma = members(ca), mb = members(cb);
  const C = chosen(), all = [...C.scored, ...C.info];
  const ga = aggregate(ma, all), gb = aggregate(mb, all);
  const head = (c, g, side) => h('div', { class: `cmp-chead ${side}` },
    posterBox(g.top, side, c.name, true),
    h('div', { class: 'info' }, h('small', { class: 'lbl' }, 'Collection'), h('div', { class: 'cmp-name' }, c.name),
      h('small', null, `${g.count} film${g.count === 1 ? '' : 's'}${g.count > CAP ? ` · top ${CAP} play` : ''} · poster: top grosser`),
      h('button', { class: 'btn', type: 'button', onclick: () => chooseCollection(c.name, (n) => { if (side === 'l') pick.cLeft = n; else pick.cRight = n; redraw(); }) }, 'Change collection')));
  // tournament
  const n = Math.min(CAP, Math.max(ma.length, mb.length));
  let tl = 0, tr = 0;
  const rows = [];
  for (let i = 0; i < n; i++) {
    const a = ma[i], b = mb[i];
    let w = 0, note = '';
    if (a && b) { const d = duel(a, b, C.scored); w = d.l > d.r ? -1 : d.r > d.l ? 1 : 0; note = `${d.l}–${d.r}`; }
    else if (s.cmpWalkover !== false) { w = a ? -1 : 1; note = 'walkover'; }
    else note = 'not played';
    if (w < 0) tl++; else if (w > 0) tr++;
    const cell = (r, side) => (r ? h('button', { type: 'button', class: `t ${side}${(side === 'l' ? w < 0 : w > 0) ? ' win' : ''}`, onclick: () => openCard(r, toast) }, r.Title) : h('span', { class: `t ${side} none` }, '—'));
    rows.push(h('div', { class: `cmp-trow${a && b ? '' : ' bye'}` },
      h('span', { class: 'n' }, String(i + 1)),
      cell(a, 'l'), h('span', { class: 'g l' }, money(a?.[bo('BoxOfficeWorldwide')])), h('span', { class: 'c l' }, pct(a?.RTCritic)),
      h('span', { class: `w ${w < 0 ? 'l' : w > 0 ? 'r' : ''}`, title: note }, w < 0 ? '◀' : w > 0 ? '▶' : '=', h('small', null, note)),
      h('span', { class: 'c r' }, pct(b?.RTCritic)), h('span', { class: 'g r' }, money(b?.[bo('BoxOfficeWorldwide')])), cell(b, 'r')));
  }
  root.append(h('div', { class: 'cmp-stage coll' }, head(ca, ga, 'l'),
    h('div', { class: 'cmp-mid' }, metricsBtn(redraw), vsMark(), tallyOn ? h('small', { class: 'lbl' }, fun() ? 'Rounds won' : 'Rounds led') : null, tallyOn ? h('div', { class: 'cmp-score' }, h('b', { class: 'l' }, String(tl)), h('span', null, '–'), h('b', { class: 'r' }, String(tr))) : null),
    head(cb, gb, 'r')));
  if (fun() && tallyOn) { const sb = skullBar(tl, tr, n); if (sb) root.append(sb); }
  root.append(h('div', { class: 'cmp-panels' }, ...panels(ga, gb, true).out));
  const fh = fetchHint([...ma.slice(0, CAP), ...mb.slice(0, CAP)]); if (fh) root.append(fh);
  root.append(h('section', { class: 'cmp-panel card cmp-tour' },
    h('h2', null, h('span', null, `Tournament: #1 vs #1 by worldwide gross${infl() ? ' (inflation-adjusted)' : ''}${n ? `, ${n} round${n === 1 ? '' : 's'}` : ''}`), h('span', { class: 'tally' }, `${tl} – ${tr}`)),
    h('div', { class: 'cmp-trow hd' }, h('span', null, '#'), h('span', null, ca.name), h('span', null, 'Gross'), h('span', null, 'RT'), h('span', null, 'Winner'), h('span', null, 'RT'), h('span', null, 'Gross'), h('span', null, cb.name)),
    ...rows));
  if (tallyOn) root.append(banner(tl, tr, ca.name, cb.name, `tournament rounds; each round is decided by the ${C.scored.length} scored metrics`));
  el.replaceChildren(root);
}

// Box office and Metacritic are only filled in by Tools > Fetch info (Plex has neither). When some are missing, offer
// to fetch just these titles; it is the same Fetch info, with its warning, and nothing runs until it is confirmed.
function fetchHint(list) {
  const missing = list.filter((r) => r && (num(r.BoxOfficeWorldwide) <= 0 || num(r.Metascore) <= 0));
  if (!missing.length) return null;
  const rids = missing.map((r) => r.Rid).filter(Boolean);
  return h('div', { class: 'cmp-hint' },
    h('span', null, `${missing.length === 1 ? (list.length === 2 ? 'One title has' : '1 title here has') : missing.length === list.length && list.length === 2 ? 'Both titles have' : `${missing.length} titles here have`} no box office or Metacritic yet. Plex does not have them; Fetch info looks them up (TMDB and OMDb, with your keys).`),
    h('button', { class: 'btn', type: 'button', disabled: S.state.halted || S.state.tool?.running ? true : null, onclick: () => fetchDialog('movies', rids) }, `Fetch info for ${rids.length === 1 ? 'this title' : `these ${rids.length}`}`));
}

// The skull bar (Fun mode): each metric (or round) a side wins adds a skull on its side of the middle; skulls further
// out are bigger and glow harder, and the bar glows more as the lead grows. Stops: the scored metrics (8 at most),
// or the rounds of a tournament.
const SKULL = '<svg viewBox="0 0 32 32" aria-hidden="true"><path fill="currentColor" d="M16 3C9 3 4 8 4 14.5c0 4 2 6.8 4.5 8.2V27a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-4.3C26 21.3 28 18.5 28 14.5 28 8 23 3 16 3z"/><circle cx="11" cy="15" r="3.4" fill="#120d10"/><circle cx="21" cy="15" r="3.4" fill="#120d10"/><path d="M14.5 20.5 16 18l1.5 2.5z" fill="#120d10"/><path d="M12 25v3M16 25v3M20 25v3" stroke="#120d10" stroke-width="1.6"/></svg>';
function skullBar(l, r, stops) {
  const t = tune();
  if (!t.skulls.on && !t.bar.on) return null;
  stops = Math.max(stops, l, r, 1);
  const span = 46;                                     // % from the middle to the last stop
  const at = (side, i) => 50 + side * (i / stops) * span;
  const skScale = mult(t.skulls.size), skInt = mult(t.skulls.int), barScale = mult(t.bar.size), barInt = mult(t.bar.int);
  const bar = h('div', { class: 'sk-bar', style: { '--sk-scale': skScale.toFixed(2), '--bar-scale': barScale.toFixed(2) } },
    h('div', { class: 'sk-track' }), h('div', { class: 'sk-mid' }));
  const lead = l - r, tone = lead > 0 ? 'var(--cl, #ff9a3c)' : 'var(--cr, #6fb7ff)';
  if (t.bar.on && lead !== 0) {
    const w = Math.abs(lead) / stops * span;
    bar.append(h('div', { class: 'sk-fill', style: { left: `${lead > 0 ? 50 - w : 50}%`, width: `${w}%`, '--tone': tone, '--glow': (4 + 26 * Math.abs(lead) / stops * barInt).toFixed(1) } }));
  }
  if (t.skulls.on) {
    for (const [side, n, tn] of [[-1, l, 'var(--cl, #ff9a3c)'], [1, r, 'var(--cr, #6fb7ff)']]) {
      for (let i = 1; i <= n; i++) {
        const k = i / stops;                               // 0..1: how far out this skull sits
        const sk = h('div', { class: 'sk', style: { left: `${at(side, i)}%`, '--tone': tn, '--px': Math.round((22 + 26 * k) * skScale), '--glow': (2 + 22 * k * skInt).toFixed(1), '--delay': `${(i * 0.15).toFixed(2)}s`, opacity: (0.6 + 0.4 * k).toFixed(2) } });
        sk.innerHTML = SKULL;
        bar.append(sk);
      }
    }
  }
  return h('div', { class: 'sk-wrap', role: 'img', 'aria-label': `Skull bar: ${l} to ${r} out of ${stops}` }, bar,
    h('div', { class: 'sk-legend' }, h('span', null, `${l} won`), h('span', null, `${stops} stops`), h('span', null, `${r} won`)));
}

function banner(l, r, a, b, how) {
  const w = l > r ? 'l' : r > l ? 'r' : '';
  return h('div', { class: `cmp-banner ${w}` },
    h('b', null, w ? `Winner: ${w === 'l' ? a : b}` : 'A draw'), h('span', null, ` · ${Math.max(l, r)}–${Math.min(l, r)} · ${how}`));
}

// For the settings Fun tab
export { FX_NAMES };
