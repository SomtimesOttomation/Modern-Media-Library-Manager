// Compare (Movies > Compare): two titles, or two collections, head to head on box office and critics.
// A round is one stat row; the higher value wins it, a tie or a missing value counts for nobody.
// Collections compare their aggregates (totals and averages), then play a tournament: each side's films ranked by
// worldwide gross, #1 vs #1 down to #10 vs #10. Poster borders and the VS come from Settings > Fun.
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { h } from '../util.js';
import { num, fmtMoney, dedupe } from '../common.js';
import { overlay } from './settings.js';
import { inTab } from './collections.js';
import { openCard } from './card.js';

const CAP = 10;
// what is being compared; kept for the session so a tab switch comes back to the same match-up
export const pick = { mode: 'movie', left: '', right: '', cLeft: '', cRight: '' };

const money = (n) => fmtMoney(n) || '';
const pct = (n) => (num(n) > 0 ? Math.round(num(n)) + '%' : '');
const int = (n) => (num(n) > 0 ? String(Math.round(num(n))) : '');
const one = (n) => (num(n) > 0 ? num(n).toFixed(1) : '');

// The stat rows. get(x) reads a movie or a collection aggregate; fmt shows it.
function statDefs() {
  const box = [
    { k: 'Worldwide', f: 'BoxOfficeWorldwide', fmt: money },
    { k: 'Domestic', f: 'BoxOfficeDomestic', fmt: money },
    { k: 'Opening weekend', f: 'OpeningDomestic', fmt: money },
  ];
  const crit = [
    { k: 'RT critics', f: 'RTCritic', fmt: pct },
    { k: 'RT audience', f: 'RTAudience', fmt: pct },
    { k: 'Metacritic', f: 'Metascore', fmt: int },
  ];
  if (S.state.settings.cmpImdb !== false) crit.push({ k: 'IMDb', f: 'Rating', fmt: one });
  return { box, crit };
}

// -1 left wins, 1 right wins, 0 nobody
const judge = (a, b) => { a = num(a); b = num(b); if (a <= 0 || b <= 0 || a === b) return 0; return a > b ? -1 : 1; };

// One movie against another: { box:[l,r], crit:[l,r], l, r, rows }
function duel(a, b, defs) {
  const score = (list) => list.reduce((t, d) => { const w = judge(a?.[d.f], b?.[d.f]); if (w < 0) t[0]++; else if (w > 0) t[1]++; return t; }, [0, 0]);
  const box = score(defs.box), crit = score(defs.crit);
  return { box, crit, l: box[0] + crit[0], r: box[1] + crit[1] };
}

// ---- collections -------------------------------------------------------------------------------------------------
function members(c) {
  const L = S.state.libs.movies;
  return dedupe(L.rows.filter((r) => c.has(r))).sort((a, b) => num(b.BoxOfficeWorldwide) - num(a.BoxOfficeWorldwide));
}
// Aggregate: box office as totals, scores as averages over the films that have them
function aggregate(list, defs) {
  const o = { count: list.length, top: list[0] || null };
  const avg = (f) => { const v = list.map((r) => num(r[f])).filter((x) => x > 0); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : 0; };
  const sum = (f) => list.reduce((a, r) => a + num(r[f]), 0);
  defs.box.forEach((d) => { o[d.f] = sum(d.f); });
  o.AvgWorldwide = avg('BoxOfficeWorldwide');
  defs.crit.forEach((d) => { o[d.f] = avg(d.f); });
  return o;
}
function aggDefs(defs) {
  return {
    box: [{ k: 'Total worldwide', f: 'BoxOfficeWorldwide', fmt: money }, { k: 'Avg per film', f: 'AvgWorldwide', fmt: money },
      { k: 'Total domestic', f: 'BoxOfficeDomestic', fmt: money }, { k: 'Total opening weekends', f: 'OpeningDomestic', fmt: money }],
    crit: defs.crit.map((d) => ({ ...d, k: 'Avg ' + d.k, fmt: d.f === 'Rating' ? one : d.f === 'Metascore' ? int : pct })),
  };
}

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
// Auto: red/orange -> fire, blue -> lightning, green -> specter, anything else glows in the poster's colours
function autoFx(cols, side) {
  if (!cols.length) return side === 'l' ? 'fire' : 'lightning';
  const [hh, s] = hexToHsl(cols[0]);
  if (s < 0.18) return 'poster';
  if (hh < 45 || hh >= 335) return 'fire';
  if (hh >= 190 && hh < 255) return 'lightning';
  if (hh >= 80 && hh < 170) return 'specter';
  return 'poster';
}
const FX_NAMES = [['auto', 'Auto'], ['fire', 'Fire'], ['lightning', 'Lightning'], ['specter', 'Specter'], ['poster', 'Poster colours'], ['off', 'Off']];
async function applyFx(el, url, setting, side) {
  const cols = await posterColours(url);
  const fx = setting === 'auto' ? autoFx(cols, side) : setting;
  el.classList.remove(...FX_NAMES.map((x) => 'fx-' + x[0]));
  el.classList.add('fx-' + fx);
  const c1 = cols[0] || '#8ea4ff', c2 = cols[1] || cols[0] || '#b06cff';
  el.style.setProperty('--fx1', c1); el.style.setProperty('--fx2', c2);
  el.dataset.fx = fx;
  // the side's colour for its bars, score and winner marks
  const tone = { fire: '#ff9a3c', lightning: '#6fb7ff', specter: '#5fe39a', poster: c1 }[fx];
  const root = el.closest('.cmp');
  if (root) { if (tone) root.style.setProperty(side === 'l' ? '--cl' : '--cr', tone); else root.style.removeProperty(side === 'l' ? '--cl' : '--cr'); }
}

// ---- pieces --------------------------------------------------------------------------------------------------------
function posterBox(r, side, label, small) {
  const box = h('div', { class: `cmp-poster${small ? ' small' : ''}`, 'data-side': side, title: label || '' },
    r?.Poster ? h('img', { src: r.Poster, alt: '' }) : h('div', { class: 'cmp-ph' }, label || '?'));
  applyFx(box, r?.Poster, S.state.settings[side === 'l' ? 'fxLeft' : 'fxRight'] || 'auto', side);
  return box;
}
function vsMark() {
  const st = S.state.settings.vsStyle || 'arcade';
  return st === 'off' ? null : h('div', { class: `cmp-vs ${st}`, 'aria-hidden': 'true' }, 'VS');
}
function statPanel(title, defs, a, b) {
  let lw = 0, rw = 0;
  const rows = defs.map((d) => {
    const av = num(a?.[d.f]), bv = num(b?.[d.f]), w = judge(av, bv), mx = Math.max(av, bv) || 1;
    if (w < 0) lw++; else if (w > 0) rw++;
    return h('div', { class: 'cmp-row' },
      h('span', { class: `v l${w < 0 ? ' win' : ''}` }, d.fmt(av) || '—'),
      h('div', { class: 'bar l' }, h('i', { style: { width: (av / mx * 100) + '%' } })),
      h('span', { class: 'k' }, d.k),
      h('div', { class: 'bar r' }, h('i', { style: { width: (bv / mx * 100) + '%' } })),
      h('span', { class: `v r${w > 0 ? ' win' : ''}` }, d.fmt(bv) || '—'));
  });
  return { el: h('section', { class: 'cmp-panel card' }, h('h2', null, h('span', null, title), h('span', { class: 'tally' }, `${lw} – ${rw}`)), ...rows), l: lw, r: rw };
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
  const s = S.state.settings, defs = statDefs();
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
    h('button', { class: 'btn', type: 'button', title: 'Border effects and the VS', onclick: () => import('./settings.js').then((m) => m.openSettings('fun', redraw)) }, 'Effects'));
  root.append(bar);

  const tallyOn = s.cmpTally !== false;
  if (pick.mode === 'movie') {
    const a = byRid.get(pick.left), b = byRid.get(pick.right);
    if (!a || !b) { root.append(h('div', { class: 'state' }, h('p', null, 'Compare needs at least two movies in the library.'))); el.replaceChildren(root); return; }
    const sideBox = (r, side) => h('div', { class: 'cmp-side' },
      h('button', { type: 'button', class: 'cmp-pbtn', title: 'Open its card', onclick: () => openCard(r, toast) }, posterBox(r, side, r.Title)),
      h('div', { class: 'cmp-name' }, r.Title), h('small', null, [r.Year > 0 ? r.Year : '', String(r.Genre || '').split(',')[0]].filter(Boolean).join(' · ')),
      h('button', { class: 'btn', type: 'button', onclick: () => chooseMovie(side === 'l' ? pick.left : pick.right, (rid) => { if (side === 'l') pick.left = rid; else pick.right = rid; redraw(); }) }, 'Change title'));
    const pb = statPanel('Box office', defs.box, a, b), pc = statPanel('Critical reception', defs.crit, a, b);
    const l = pb.l + pc.l, r = pb.r + pc.r;
    root.append(h('div', { class: 'cmp-stage' }, sideBox(a, 'l'),
      h('div', { class: 'cmp-mid' }, vsMark(), tallyOn ? h('small', { class: 'lbl' }, 'Rounds won') : null, tallyOn ? h('div', { class: 'cmp-score' }, h('b', { class: 'l' }, String(l)), h('span', null, '–'), h('b', { class: 'r' }, String(r))) : null),
      sideBox(b, 'r')));
    root.append(h('div', { class: 'cmp-panels' }, pb.el, pc.el));
    if (tallyOn) root.append(banner(l, r, a.Title, b.Title, `${pb.l}–${pb.r} at the box office, ${pc.l}–${pc.r} with critics`));
    root.append(h('p', { class: 'cmp-note' }, h('small', null, 'A round is one row; ties and missing numbers count for nobody. Box office and Metacritic come from Tools > Fetch info.')));
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
  const ga = aggregate(ma, defs), gb = aggregate(mb, defs), ad = aggDefs(defs);
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
    if (a && b) { const d = duel(a, b, defs); w = d.l > d.r ? -1 : d.r > d.l ? 1 : 0; note = `${d.l}–${d.r}`; }
    else if (s.cmpWalkover !== false) { w = a ? -1 : 1; note = 'walkover'; }
    else note = 'not played';
    if (w < 0) tl++; else if (w > 0) tr++;
    const cell = (r, side) => (r ? h('button', { type: 'button', class: `t ${side}${(side === 'l' ? w < 0 : w > 0) ? ' win' : ''}`, onclick: () => openCard(r, toast) }, r.Title) : h('span', { class: `t ${side} none` }, '—'));
    rows.push(h('div', { class: `cmp-trow${a && b ? '' : ' bye'}` },
      h('span', { class: 'n' }, String(i + 1)),
      cell(a, 'l'), h('span', { class: 'g l' }, money(a?.BoxOfficeWorldwide)), h('span', { class: 'c l' }, pct(a?.RTCritic)),
      h('span', { class: `w ${w < 0 ? 'l' : w > 0 ? 'r' : ''}`, title: note }, w < 0 ? '◀' : w > 0 ? '▶' : '=', h('small', null, note)),
      h('span', { class: 'c r' }, pct(b?.RTCritic)), h('span', { class: 'g r' }, money(b?.BoxOfficeWorldwide)), cell(b, 'r')));
  }
  root.append(h('div', { class: 'cmp-stage coll' }, head(ca, ga, 'l'),
    h('div', { class: 'cmp-mid' }, vsMark(), tallyOn ? h('small', { class: 'lbl' }, 'Rounds won') : null, tallyOn ? h('div', { class: 'cmp-score' }, h('b', { class: 'l' }, String(tl)), h('span', null, '–'), h('b', { class: 'r' }, String(tr))) : null),
    head(cb, gb, 'r')));
  const pb = statPanel('Box office (all films)', ad.box, ga, gb), pc = statPanel('Critical reception (averages)', ad.crit, ga, gb);
  root.append(h('div', { class: 'cmp-panels' }, pb.el, pc.el));
  root.append(h('section', { class: 'cmp-panel card cmp-tour' },
    h('h2', null, h('span', null, `Tournament: #1 vs #1 by worldwide gross${n ? `, ${n} round${n === 1 ? '' : 's'}` : ''}`), h('span', { class: 'tally' }, `${tl} – ${tr}`)),
    h('div', { class: 'cmp-trow hd' }, h('span', null, '#'), h('span', null, ca.name), h('span', null, 'Gross'), h('span', null, 'RT'), h('span', null, 'Winner'), h('span', null, 'RT'), h('span', null, 'Gross'), h('span', null, cb.name)),
    ...rows));
  if (tallyOn) root.append(banner(tl, tr, ca.name, cb.name, `tournament rounds; each round is decided by the stat rows (${defs.box.length + defs.crit.length})`));
  el.replaceChildren(root);
}

function banner(l, r, a, b, how) {
  const w = l > r ? 'l' : r > l ? 'r' : '';
  return h('div', { class: `cmp-banner ${w}` },
    h('b', null, w ? `Winner: ${w === 'l' ? a : b}` : 'A draw'), h('span', null, ` · ${Math.max(l, r)}–${Math.min(l, r)} · ${how}`));
}

// For the settings Fun tab
export { FX_NAMES };
