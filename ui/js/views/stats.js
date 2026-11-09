// Dashboard: the old dashboard page (KPIs, charts, HDR and device compatibility, largest files, library health) for the
// open tab. Click any slice, bar or chip to filter; the filters stack and show as chips. Click a title for its card.
import * as S from '../store.js';
import { h } from '../util.js';
import { esc, num, v, fmtInt, fmtSize, fmtRun } from '../common.js';
import { openCard } from './card.js';
import { searchRows } from '../common.js';
import { loadDashboards, dashboards, renderDashboard, newDashboard, saveDashboards } from './mydash.js';
import { STATUS, ST_ORDER, DEVICE_GROUPS, ALL_DEVICES, hdrClass, deviceStatus } from './devices.js';

const splitList = (s) => String(s || '').split(/\s*;\s*/).filter(Boolean);
const sum = (rows, f) => rows.reduce((a, r) => a + num(r[f]), 0);
const PALETTE = ['#6C8CFF','#B06CFF','#FF6CA8','#FFB86C','#4ADE80','#22D3EE','#F472B6','#FACC15','#A3E635','#FB7185','#38BDF8','#C084FC'];
const FIXED = {
  'Dolby Vision':'#B06CFF','HDR10+':'#FF6CA8','HDR10':'#FFB86C','HLG':'#22D3EE','SDR':'#4B5578','Unknown':'#3A4366','None':'#3A4366',
  '4K':'#B06CFF','1440p':'#FF6CA8','1080p':'#6C8CFF','720p':'#22D3EE','SD':'#4B5578'
};
const colorFor = (k, i) => FIXED[k] || PALETTE[i % PALETTE.length];

/* ================= chart definitions ================= */
const ratingBucket = r => { const x = num(r.Rating); return x > 0 ? (Math.min(Math.floor(x), 9) + '–' + (Math.min(Math.floor(x), 9) + 1)) : 'NR'; };

// "P8.1 · single layer", "P7 · FEL", "P7 · dual layer" (FEL/MEL not verified), "P5 · single layer"
const dvLabel = r => {
  if (r.HDRType !== 'Dolby Vision') return null;
  if (!r.DVProfile) return 'Profile unknown';
  const lay = r.DVLayer === 'FEL' ? 'FEL' : r.DVLayer === 'MEL' ? 'MEL' : r.DVLayer === 'Dual layer' ? 'dual layer' : 'single layer';
  return 'P' + r.DVProfile + ' · ' + lay;
};

const CHARTS = [
  {id:'library',  title:'Library',             kind:'donut', keys:r=>[v(r.Library,'Library')]},
  {id:'res',     title:'Resolution',          kind:'donut', keys:r=>[v(r.ResolutionClass,'Unknown')], order:['4K','1440p','1080p','720p','SD','Unknown']},
  {id:'hdr',      title:'Dynamic Range',       kind:'donut', group:'hdr', keys:r=>[v(r.HDRType,'SDR')], order:['Dolby Vision','HDR10+','HDR10','HLG','SDR']},
  {id:'dvprof',   title:'Dolby Vision Profile & Layer', kind:'bar', group:'hdr', sub:'DV titles only', keys:r=>{const l=dvLabel(r);return l?[l]:[]}, top:8},
  {id:'hdrstack', title:'HDR Format Stack',    kind:'bar',   group:'hdr', sub:'incl. fallback', wide:true, keys:r=>[v(r.HDRStack, v(r.HDRType,'SDR'))], top:9},
  {id:'vcodec',   title:'Video Codec',         kind:'bar',   keys:r=>[v(r.VideoCodec,'Unknown')], top:8},
  {id:'source',   title:'Source',              kind:'donut', keys:r=>[v(r.Source,'Unknown')]},
  {id:'acodec',   title:'Audio Format',        kind:'bar',   keys:r=>[v(r.AudioFormat,'Unknown')], top:8},
  {id:'layout',   title:'Audio Channels',      kind:'donut', keys:r=>[v(r.AudioLayout,'Unknown')], order:['7.1','5.1','Stereo','Mono','Unknown']},
  {id:'object',   title:'Immersive Audio',     kind:'donut', keys:r=>[v(r.ObjectAudio,'None')], order:['Dolby Atmos','DTS:X','None']},
  {id:'container',title:'Container',           kind:'donut', keys:r=>[v(r.Container,'Unknown')]},
  {id:'storage',  title:'Storage by Resolution',kind:'bar',  keys:r=>[v(r.ResolutionClass,'Unknown')], measure:'size', order:['4K','1440p','1080p','720p','SD','Unknown']},
  {id:'genre',    title:'Top Genres',          kind:'bar',   keys:r=>r._genres.length?r._genres:['Unknown'], top:10},
  {id:'studio',   title:'Top Studios',         kind:'bar',   keys:r=>[v(r.Studio,'Unknown')], top:8},
  {id:'mpaa',     title:'Content Rating',      kind:'donut', keys:r=>[v(r.MPAARating,'Unrated')]},
  {id:'decade',   title:'Releases by Decade',  kind:'cols',  keys:r=>[r.Decade], sort:'key', span:2},
  {id:'added',    title:'Added to Library (by year)', kind:'cols', keys:r=>[(r.Added||'').slice(0,4)||'Unknown'], sort:'key', span:2},
  {id:'rating',   title:'Rating Distribution', kind:'cols',  keys:r=>[ratingBucket(r)], sort:'key'},
  {id:'alang',    title:'Audio Languages',     kind:'bar',   keys:r=>{const l=splitList(r.AudioLanguages);return l.length?l:['Unknown']}, top:8},
  {id:'slang',    title:'Subtitle Languages',  kind:'bar',   keys:r=>{const l=splitList(r.SubtitleLanguages);return l.length?l:['None']}, top:8},
  {id:'bitdepth', title:'Bit Depth',           kind:'donut', group:'hdr', keys:r=>[num(r.BitDepth)>0?num(r.BitDepth)+'-bit':'Unknown']}
];

const HEALTH = [
  {id:'h_nfo',   label:'Missing NFO',         pred:r=>!r.HasNfo},
  {id:'h_poster',label:'Missing poster',      pred:r=>!r.HasPoster},
  {id:'h_subs',  label:'No subtitles',        pred:r=>!(num(r.SubtitleTracks)>0)},
  {id:'h_stereo',label:'Stereo-only audio',   pred:r=>num(r.AudioChannels)>0 && num(r.AudioChannels)<=2},
  {id:'h_lowbr', label:'Video < 2 Mbps',      pred:r=>num(r.VideoBitRateMbps)>0 && num(r.VideoBitRateMbps)<2},
  {id:'h_sd',    label:'SD resolution',       pred:r=>r.ResolutionClass==='SD'},
  {id:'h_src',   label:'Unknown source',      pred:r=>v(r.Source,'Unknown')==='Unknown'},
  {id:'h_noyear',label:'No release year',     pred:r=>!(r.Year>0)}
];

const KPIS = [
  {id:'k1', label:'Titles',            val:rows=>rows.length,                         fmt:fmtInt},
  {id:'k2', label:'Library Size',      val:rows=>sum(rows,'FileSizeGB'),              fmt:fmtSize},
  {id:'k3', label:'Total Runtime',     val:rows=>sum(rows,'RuntimeMin'),              fmt:fmtRun},
  {id:'k4', label:'Avg Video Bitrate', val:rows=>{const a=rows.filter(r=>num(r.VideoBitRateMbps)>0);return a.length?sum(a,'VideoBitRateMbps')/a.length:0}, fmt:n=>n.toFixed(1)+' Mbps'},
  {id:'k5', label:'4K Content',        val:rows=>rows.length?rows.filter(r=>r.ResolutionClass==='4K').length/rows.length*100:0, fmt:n=>n.toFixed(0)+'%'},
  {id:'k6', label:'HDR / Dolby Vision',val:rows=>rows.length?rows.filter(r=>r.HDRType&&r.HDRType!=='SDR').length/rows.length*100:0, fmt:n=>n.toFixed(0)+'%'}
];

const decade = (r) => (r.Year > 0 ? Math.floor(r.Year / 10) * 10 + 's' : 'Unknown');
CHARTS.find((c) => c.id === 'decade').keys = (r) => [decade(r)];

const fmtVal = (cfg, n) => (cfg.fmt ? cfg.fmt(n) : cfg.measure === 'size' ? fmtSize(n) : fmtInt(n));
function counts(cfg, rows) {
  const m = new Map();
  for (const r of rows) { const w = cfg.measure === 'size' ? num(r.FileSizeGB) : 1; for (const k of new Set(cfg.keys(r))) m.set(k, (m.get(k) || 0) + w); }
  return m;
}
function ordered(cfg, m, sel) {
  let e = [...m.entries()];
  if (cfg.order) { const o = cfg.order; e.sort((a, b) => ((o.indexOf(a[0]) < 0 ? 99 : o.indexOf(a[0])) - (o.indexOf(b[0]) < 0 ? 99 : o.indexOf(b[0]))) || b[1] - a[1]); }
  else if (cfg.sort === 'key') e.sort((a, b) => String(a[0]).localeCompare(String(b[0]), undefined, { numeric: true }));
  else e.sort((a, b) => b[1] - a[1]);
  if (cfg.top) e = e.slice(0, cfg.top);
  if (sel && !e.some((x) => x[0] === sel)) e.push([sel, m.get(sel) || 0]);
  return e;
}
export function donut(cfg, entries, sel) {
  const total = entries.reduce((a, e) => a + e[1], 0) || 1;
  const R = 54, C = 2 * Math.PI * R; let off = 0, segs = '', legend = '';
  entries.forEach(([k, val], i) => {
    const frac = val / total, len = Math.max(frac * C - (entries.length > 1 ? 2 : 0), 0.001);
    const col = colorFor(k, i), dim = sel && sel !== k ? ' dim' : '';
    segs += `<circle class="seg${dim}" data-chart="${cfg.id}" data-key="${esc(k)}" cx="70" cy="70" r="${R}" fill="none" stroke="${col}" stroke-width="20" stroke-dasharray="${len} ${C - len}" stroke-dashoffset="${-off}" transform="rotate(-90 70 70)"><title>${esc(k)}: ${fmtVal(cfg, val)} (${(frac * 100).toFixed(1)}%)</title></circle>`;
    legend += `<div class="lg${dim}" data-chart="${cfg.id}" data-key="${esc(k)}"><span class="dot" style="background:${col}"></span><span class="n">${esc(k)}</span><span class="c">${fmtVal(cfg, val)} · ${(frac * 100).toFixed(0)}%</span></div>`;
    off += frac * C;
  });
  return `<div class="donut-wrap"><svg viewBox="0 0 140 140" class="donut">${segs}<text x="70" y="68" class="dc-num">${cfg.center !== undefined ? esc(cfg.center) : fmtVal(cfg, total)}</text><text x="70" y="83" class="dc-sub">${esc(cfg.sub || (cfg.measure === 'size' ? 'total' : 'titles'))}</text></svg><div class="legend">${legend}</div></div>`;
}
export function bars(cfg, entries, sel) {
  const max = Math.max(...entries.map((e) => e[1]), 1);
  return `<div class="bars${cfg.wide ? ' wide' : ''}">` + entries.map(([k, val], i) => {
    const c = colorFor(k, i), dim = sel && sel !== k ? ' dim' : '';
    return `<div class="hbar${dim}" data-chart="${cfg.id}" data-key="${esc(k)}"><span class="bl" title="${esc(k)}">${esc(k)}</span><div class="bt"><div class="bf" style="width:${(val / max * 100).toFixed(1)}%;background:${c}"></div></div><span class="bv">${fmtVal(cfg, val)}</span></div>`;
  }).join('') + '</div>';
}
export function cols(cfg, entries, sel) {
  const max = Math.max(...entries.map((e) => e[1]), 1);
  return '<div class="cols">' + entries.map(([k, val]) => {
    const dim = sel && sel !== k ? ' dim' : '';
    return `<div class="col${dim}" data-chart="${cfg.id}" data-key="${esc(k)}" title="${esc(k)}: ${fmtVal(cfg, val)}"><span class="cv">${fmtVal(cfg, val)}</span><div class="cb" style="height:${Math.max(val / max * 120, 3)}px"></div><span class="cl">${esc(k)}</span></div>`;
  }).join('') + '</div>';
}

// Filters live for the session per tab, so going to a card and back keeps them.
const filtersByTab = { movies: new Map(), tv: new Map() };

export function mount(ctx) {
  const tab = ctx.arg === 'tv' ? 'tv' : 'movies';
  const L = S.state.libs[tab], filters = filtersByTab[tab];
  // the titles the tab shows: the search box and collections narrow the dashboard too
  const shown = () => searchRows(L.rows, S.state.query, L, S.state.collections).rows;
  const base = () => { const rows = shown(); const vid = rows.filter((r) => r.Type === 'Video'); return vid.length ? vid : rows; };
  const KEY = `mmlm.dash.${tab}`;
  let active = 'overview';
  try { active = localStorage.getItem(KEY) || 'overview'; } catch { /* ignore */ }
  const setActive = (id) => { active = id; try { localStorage.setItem(KEY, id); } catch { /* ignore */ } draw(); };
  // Overview | your dashboards | + New
  const strip = () => {
    const mine = dashboards(tab);
    if (active !== 'overview' && !mine.some((d) => d.id === active)) active = 'overview';
    const cur = mine.find((d) => d.id === active);
    return h('div', { class: 'dashstrip' },
      h('div', { class: 'seg', role: 'tablist', 'aria-label': 'Dashboards' },
        h('button', { type: 'button', class: active === 'overview' ? 'active' : '', onclick: () => setActive('overview') }, 'Overview'),
        ...mine.map((d) => h('button', { type: 'button', class: active === d.id ? 'active' : '', onclick: () => setActive(d.id) }, d.name))),
      h('button', { class: 'btn', type: 'button', onclick: () => { const d = newDashboard(tab, `My dashboard ${mine.length + 1}`, mine.length === 0); setActive(d.id); } }, '+ New dashboard'),
      cur ? h('input', { class: 'dashname', type: 'text', value: cur.name, 'aria-label': 'Dashboard name', maxlength: '40', onchange: (e) => { cur.name = e.target.value.trim() || cur.name; saveDashboards(); draw(); } }) : null,
      cur ? h('button', { class: 'btn', type: 'button', title: 'Delete this dashboard (click twice)', onclick: (e) => {
        if (!e.currentTarget.dataset.sure) { e.currentTarget.dataset.sure = '1'; e.currentTarget.textContent = 'Sure?'; return; }
        const list = dashboards(tab); list.splice(list.indexOf(cur), 1); saveDashboards(); setActive('overview');
      } }, 'Delete') : null);
  };
  const filtered = (rows, except) => rows.filter((r) => { for (const [id, f] of filters) if (id !== except && !f.pred(r)) return false; return true; });
  const draw = () => {
    const head = ctx.embedded ? h('span') : h('div', { class: 'lib-head' },
      h('div', { class: 'lib-title' }, h('h1', null, 'Stats'), h('small', null, tab === 'tv' ? 'TV Shows (episodes)' : 'Movies')),
      h('div', { class: 'lib-tools' }, h('div', { class: 'seg', role: 'tablist', 'aria-label': 'Library' }, [['movies', 'Movies'], ['tv', 'TV Shows']].map(([k, label]) =>
        h('a', { href: `#/stats/${k}`, class: `btn ${tab === k ? 'primary' : ''}`, style: { border: 0, borderRadius: 0 }, 'aria-selected': tab === k ? 'true' : 'false' }, label)))));
    if (L.status !== 'ready') {
      ctx.el.replaceChildren(head, h('div', { class: 'state' }, h('h2', null, L.status === 'empty' ? 'Nothing scanned yet' : L.status === 'error' ? 'Could not open the library' : 'Opening the library...'), h('p', null, L.error || '')));
      return;
    }
    const box = document.createElement('div');
    const custom = dashboards(tab).find((d) => d.id === active);
    if (custom) {
      ctx.el.replaceChildren(head, strip(), box);
      renderDashboard(box, tab, custom, shown(), L, draw, (rows, q) => { const set = new Set(S.filterByQuery(L, q)); return rows.filter((r) => set.has(r)); });
      return;
    }
    const all = base(), rows = filtered(all);
    const chips = filters.size ? [...filters.entries()].map(([id, f]) => `<span class="fchip">${esc(f.label)}<button type="button" data-remove="${id}" title="Remove">✕</button></span>`).join('') + '<button class="btn" type="button" data-clear="1">Clear all</button>' : '';
    const chartHtml = (cfg) => {
      const sel = filters.get(cfg.id)?.key, entries = ordered(cfg, counts(cfg, filtered(all, cfg.id)), sel);
      const body = entries.length ? (cfg.kind === 'donut' ? donut(cfg, entries, sel) : cfg.kind === 'bar' ? bars(cfg, entries, sel) : cols(cfg, entries, sel)) : '<div class="empty-s">No data for the current filters</div>';
      return `<div class="st-card${cfg.span === 2 ? ' span2' : ''}"><h3>${esc(cfg.title)}<small>${esc(cfg.sub || (cfg.measure === 'size' ? 'by size' : ''))}</small></h3>${body}</div>`;
    };
    const compatHtml = (g) => {
      let html = '', any = false;
      for (const dev of g.devices) {
        const fid = 'cx_' + dev.id, sel = filters.get(fid)?.key;
        const cnt = { full: 0, partial: 0, fallback: 0, none: 0 }; let tot = 0;
        for (const r of filtered(all, fid)) { const st = deviceStatus(dev, r); if (st) { cnt[st]++; tot++; } }
        if (tot) any = true;
        const segs = ST_ORDER.filter((k) => cnt[k] > 0).map((k) => `<div class="cxs${sel && sel !== k ? ' dim' : ''}" data-dev="${dev.id}" data-st="${k}" style="width:${(cnt[k] / tot * 100).toFixed(2)}%;background:${STATUS[k].color}" title="${esc(dev.name)} · ${STATUS[k].label}: ${fmtInt(cnt[k])} (${(cnt[k] / tot * 100).toFixed(1)}%)"></div>`).join('');
        html += `<div class="cxr"><span class="cxn" title="${esc(dev.note)}">${esc(dev.name)}</span><div class="cxb">${segs}</div><span class="cxp">${tot ? (cnt.full / tot * 100).toFixed(0) + '% full' : '–'}</span></div>`;
      }
      const legend = ST_ORDER.map((k) => `<span title="${esc(STATUS[k].tip)}"><i style="background:${STATUS[k].color}"></i>${STATUS[k].label}</span>`).join('');
      return `<div class="st-card span2"><h3>${esc(g.title)}</h3><div class="cx">${any ? html : '<div class="empty-s">No HDR or Dolby Vision titles in the current view</div>'}</div><div class="cxlegend">${legend}</div><div class="cxnote">Counts HDR and Dolby Vision titles only. Hover a name for caveats: curated from public specs and community reports, not lab-tested.</div></div>`;
    };
    const li = (r, right) => `<li data-open="${r._i}"><span>${esc(r.Show ? r.Show + ' · ' : '')}${esc(r.Title)}${r.Year > 0 ? ' (' + r.Year + ')' : ''}</span><b>${right}</b></li>`;
    const big = rows.slice().sort((a, b) => num(b.FileSizeGB) - num(a.FileSizeGB)).slice(0, 7);
    const low = rows.filter((r) => num(r.BitsPerPixel) > 0).sort((a, b) => num(a.BitsPerPixel) - num(b.BitsPerPixel)).slice(0, 7);
    const health = HEALTH.map((x) => { const n = filtered(all, x.id).filter(x.pred).length; return `<div class="hchip${n === 0 ? ' zero' : ''}${filters.has(x.id) ? ' on' : ''}" data-health="${x.id}"><b>${fmtInt(n)}</b><span>${x.label}</span></div>`; }).join('');
    box.innerHTML = `<div class="chips">${chips}</div>
      <div class="kpis">${KPIS.map((k) => { const s = k.fmt(k.val(rows)); return `<div class="kpi"><div class="l">${k.label}</div><div class="v" style="${s.length > 15 ? 'font-size:18px' : s.length > 10 ? 'font-size:22px' : ''}">${esc(s)}</div></div>`; }).join('')}</div>
      <div class="st-section"><h2>Library</h2></div><div class="st-grid">${CHARTS.filter((c) => c.group !== 'hdr').map(chartHtml).join('')}</div>
      <div class="st-section"><h2>HDR and devices</h2></div><div class="st-grid">${CHARTS.filter((c) => c.group === 'hdr').map(chartHtml).join('')}${DEVICE_GROUPS.map(compatHtml).join('')}</div>
      <div class="st-section"><h2>Insights</h2></div><div class="st-grid">
        <div class="st-card"><h3>Largest files <small>click to open</small></h3><ul class="rank">${big.map((r) => li(r, fmtSize(r.FileSizeGB))).join('') || '<div class="empty-s">No data</div>'}</ul></div>
        <div class="st-card"><h3>Lowest bits per pixel <small>possible quality concern</small></h3><ul class="rank">${low.map((r) => li(r, num(r.BitsPerPixel).toFixed(3) + ' bpp')).join('') || '<div class="empty-s">No data</div>'}</ul></div>
        <div class="st-card"><h3>Library health <small>click to filter</small></h3><div class="health">${health}</div></div></div>`;
    ctx.el.replaceChildren(head, strip(), box);
  };
  ctx.el.addEventListener('click', ctx.onClick = (e) => {
    if (dashboards(tab).some((d) => d.id === active)) return;        // your own dashboards handle their own clicks
    const t = e.target.closest('[data-chart],[data-dev],[data-open],[data-health],[data-remove],[data-clear]');
    if (!t) return;
    if (t.dataset.open !== undefined) { openCard(L.rows[+t.dataset.open], ctx.toast); return; }
    if (t.dataset.clear) filters.clear();
    else if (t.dataset.remove) filters.delete(t.dataset.remove);
    else if (t.dataset.health) { const x = HEALTH.find((y) => y.id === t.dataset.health); if (filters.has(x.id)) filters.delete(x.id); else filters.set(x.id, { label: x.label, pred: x.pred }); }
    else if (t.dataset.dev) {
      const dev = ALL_DEVICES.find((d) => d.id === t.dataset.dev), st = t.dataset.st, fid = 'cx_' + dev.id;
      if (filters.get(fid)?.key === st) filters.delete(fid); else filters.set(fid, { label: `${dev.name}: ${STATUS[st].label}`, key: st, pred: (r) => deviceStatus(dev, r) === st });
    } else if (t.dataset.chart) {
      const cfg = CHARTS.find((c) => c.id === t.dataset.chart), key = t.dataset.key;
      if (filters.get(cfg.id)?.key === key) filters.delete(cfg.id); else filters.set(cfg.id, { label: `${cfg.title}: ${key}`, key, pred: (r) => cfg.keys(r).includes(key) });
    }
    draw();
  });
  draw();
  loadDashboards().then(() => { if (ctx.el.isConnected) draw(); });
  ctx.redraw = draw;
  ctx.seen = { status: L.status, rows: L.rows };
  return () => ctx.el.removeEventListener('click', ctx.onClick);
}
export function update(topics, ctx) {
  const L = S.state.libs[ctx.arg === 'tv' ? 'tv' : 'movies'];
  if (ctx.seen && (ctx.seen.status !== L.status || ctx.seen.rows !== L.rows)) { ctx.seen = { status: L.status, rows: L.rows }; ctx.redraw?.(); }
}
void v; void hdrClass;
