// Compare's metrics: what can be compared, which are chosen (Settings > Compare, or the Metrics button), and the
// picker. Up to 8 scored metrics, where the bigger number wins each one; Runtime and File size are shown for
// information only and do not count toward the 8.
import * as S from './store.js';
import { h } from './util.js';
import { num, fmtMoney } from './common.js';
import { overlay } from './views/settings.js';
import { BASE_YEAR } from './inflation.js';

export const MAX_SCORED = 8;
export const DEFAULT_METRICS = ['ww', 'dom', 'open', 'rtc', 'rta', 'meta', 'imdb'];
export const DEFAULT_INFO = ['run', 'size'];

const money = (n) => fmtMoney(n) || '';
const pct = (n) => (num(n) > 0 ? Math.round(num(n)) + '%' : '');
const int = (n) => (num(n) > 0 ? String(Math.round(num(n))) : '');
const one = (n) => (num(n) > 0 ? num(n).toFixed(1) : '');
const mbps = (n) => (num(n) > 0 ? num(n).toFixed(1) + ' Mbps' : '');
const kbps = (n) => (num(n) <= 0 ? '' : num(n) >= 1000 ? (num(n) / 1000).toFixed(1) + ' Mbps' : Math.round(num(n)) + ' kbps');
const nits = (n) => (num(n) > 0 ? Math.round(num(n)).toLocaleString('en-US') + ' nits' : '');
const mins = (n) => (num(n) > 0 ? Math.round(num(n)) + ' min' : '');
const gb = (n) => (num(n) > 0 ? num(n).toFixed(1) + ' GB' : '');

export const infl = () => !!S.state.settings.cmpInflation;
const bo = (f) => (infl() ? f + 'Adj' : f);

// Brightness is not a library field: it comes from MediaInfo (S.state.mi: rid -> [maxCLL, maxFALL, failed])
const mi = (i) => (r) => { const v = r && S.state.mi?.[r.Rid]; return v ? num(v[i]) : 0; };

// id, group, label, how to read it, how to show it, note for the picker, optional (hidden when neither side has it)
export function catalog() {
  return [
    { id: 'ww', g: 'box', k: 'Worldwide', f: bo('BoxOfficeWorldwide'), fmt: money, note: infl() ? `${BASE_YEAR} dollars` : '' },
    { id: 'dom', g: 'box', k: 'Domestic', f: bo('BoxOfficeDomestic'), fmt: money, note: infl() ? `${BASE_YEAR} dollars` : '' },
    { id: 'open', g: 'box', k: 'Opening weekend', f: bo('OpeningDomestic'), fmt: money, optional: true, note: 'only when typed in' },
    { id: 'rtc', g: 'crit', k: 'RT critics', f: 'RTCritic', fmt: pct },
    { id: 'rta', g: 'crit', k: 'RT audience', f: 'RTAudience', fmt: pct },
    { id: 'meta', g: 'crit', k: 'Metacritic', f: 'Metascore', fmt: int },
    { id: 'imdb', g: 'crit', k: 'IMDb', f: 'Rating', fmt: one },
    { id: 'vbr', g: 'file', k: 'Video bitrate', f: 'VideoBitRateMbps', fmt: mbps },
    { id: 'abr', g: 'file', k: 'Audio bitrate', f: 'AudioBitRateKbps', fmt: kbps, note: 'main track' },
    { id: 'cll', g: 'pic', k: 'Max brightness', get: mi(0), fmt: nits, note: 'MaxCLL, from MediaInfo' },
    { id: 'fall', g: 'pic', k: 'Average brightness', get: mi(1), fmt: nits, note: 'MaxFALL, from MediaInfo' },
    { id: 'run', g: 'info', k: 'Runtime', f: 'RuntimeMin', fmt: mins, info: true },
    { id: 'size', g: 'info', k: 'File size', f: 'FileSizeGB', fmt: gb, info: true },
  ];
}
export const GROUPS = [['box', 'Box office'], ['crit', 'Critical reception'], ['file', 'File'], ['pic', 'Picture (MediaInfo)'], ['info', 'For information (not scored)']];

// the value of a metric for a movie (or a collection aggregate, which carries every metric under its id)
export const val = (d, r) => (r && r._agg ? num(r[d.id]) : d.get ? d.get(r) : num(r?.[d.f]));

// what is chosen, in catalogue order; a saved list that has gone stale is cleaned up here
export function chosen() {
  const s = S.state.settings, all = catalog();
  const pick = new Set(Array.isArray(s.cmpMetrics) ? s.cmpMetrics : DEFAULT_METRICS);
  const info = new Set(Array.isArray(s.cmpInfo) ? s.cmpInfo : DEFAULT_INFO);
  const scored = all.filter((d) => !d.info && pick.has(d.id)).slice(0, MAX_SCORED);
  return { scored, info: all.filter((d) => d.info && info.has(d.id)) };
}
export const needsMediaInfo = () => chosen().scored.some((d) => d.g === 'pic');

export function openMetrics(onDone) {
  const s = S.state.settings;
  let pick = new Set(Array.isArray(s.cmpMetrics) ? s.cmpMetrics : DEFAULT_METRICS);
  let info = new Set(Array.isArray(s.cmpInfo) ? s.cmpInfo : DEFAULT_INFO);
  overlay((close) => {
    const body = h('div', { class: 'met-body' });
    const count = h('span', { class: 'met-count' });
    const paint = () => {
      const n = catalog().filter((d) => !d.info && pick.has(d.id)).length;
      count.textContent = `${n} of ${MAX_SCORED} chosen`;
      count.classList.toggle('full', n >= MAX_SCORED);
      body.replaceChildren(...GROUPS.map(([g, title]) => {
        const items = catalog().filter((d) => d.g === g);
        return h('div', { class: 'met-group' }, h('div', { class: 'met-g' }, title), ...items.map((d) => {
          const set = d.info ? info : pick, on = set.has(d.id), off = !on && !d.info && n >= MAX_SCORED;
          return h('label', { class: `met-item${on ? ' on' : ''}${off ? ' off' : ''}` },
            h('input', { type: 'checkbox', checked: on ? true : null, disabled: off ? true : null, onchange: (e) => { if (e.target.checked) set.add(d.id); else set.delete(d.id); paint(); } }),
            h('span', null, d.k), d.note ? h('small', null, d.note) : null);
        }));
      }));
    };
    paint();
    const save = async () => {
      const order = catalog().map((d) => d.id);
      await S.saveSettings({ cmpMetrics: order.filter((id) => pick.has(id)), cmpInfo: order.filter((id) => info.has(id)) });
      close(); onDone?.();
    };
    return h('div', { class: 'met' },
      h('div', { class: 'met-head' }, h('h2', null, 'Metrics'), count),
      h('p', null, h('small', null, `Pick up to ${MAX_SCORED} rows to score; the bigger number wins each one, and a tie or a missing number counts for nobody. Runtime and file size are shown for information only and do not count toward the ${MAX_SCORED}.`)),
      body,
      h('div', { class: 'met-foot' },
        h('button', { class: 'btn', type: 'button', onclick: () => { pick = new Set(DEFAULT_METRICS); info = new Set(DEFAULT_INFO); paint(); } }, 'Reset to defaults'),
        h('button', { class: 'btn primary', type: 'button', onclick: save }, 'Done')));
  });
}
