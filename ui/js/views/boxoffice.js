// Box office runs for one movie, pasted or typed in by hand: weekend by weekend, week by week, and country by country.
// MMLM never fetches these. The person copies a table from wherever they are reading it and pastes it here; the parser
// works out the columns, shows a preview to check, and the rows are saved in boxoffice-movies.json (see store.js).
import * as S from '../store.js';
import { h } from '../util.js';
import { overlay } from './settings.js';
import { fmtMoney } from '../common.js';

export const KINDS = [['weekends', 'Weekends'], ['weeks', 'Weeks'], ['countries', 'Countries']];

// "$1,234,567", "1.2M", "€3.4 m", "45,000", "-" -> a number (0 when there is none)
export function money(t) {
  const s = String(t ?? '').replace(/[\s ]/g, '');
  const m = s.match(/(-?[\d.,]+)([kmb])?/i);
  if (!m || !/\d/.test(m[1])) return 0;
  let n = m[1];
  if (/,\d{1,2}$/.test(n) && !/\.\d/.test(n)) n = n.replace(/\./g, '').replace(',', '.');   // 1.234,56
  else n = n.replace(/,/g, '');
  let v = parseFloat(n); if (!Number.isFinite(v)) return 0;
  const u = (m[2] || '').toLowerCase(); if (u === 'k') v *= 1e3; else if (u === 'm') v *= 1e6; else if (u === 'b') v *= 1e9;
  return Math.round(v);
}
const isMoneyish = (t) => /\d/.test(t) && /^[\s$€£¥]*-?[\d.,\s]+\s*[kmb]?$/i.test(String(t).replace(/ /g, ' ').trim());
const isPct = (t) => /%\s*$/.test(String(t).trim());

// split pasted text into rows of cells: tabs (copied from a web table or a spreadsheet), else 2+ spaces, else commas
export function cells(text) {
  const lines = String(text || '').replace(/\r/g, '').split('\n').map((l) => l.replace(/\s+$/, '')).filter((l) => l.trim());
  if (!lines.length) return [];
  const tabbed = lines.some((l) => l.includes('\t'));
  return lines.map((l) => (tabbed ? l.split('\t') : / {2,}/.test(l) ? l.split(/ {2,}/) : l.split(/,(?=(?:[^"]*"[^"]*")*[^"]*$)(?!\d{3}\b)/)).map((c) => c.replace(/^"|"$/g, '').trim()));
}

// work out what each column is, from the header row when there is one, else from what the cells look like
const HEAD = {
  label: /^(date|dates|weekend|week|period|release)\b|^(rank|#)$/i,
  country: /country|area|market|territor|region/i,
  gross: /gross|box ?office|earnings|weekend|week|opening/i,
  total: /to ?date|total|cume|cumulative|running/i,
  theaters: /theat|cinema|location|screen/i,
  opening: /opening/i,
  release: /release/i,
  skip: /change|%|avg|average|per |rank|#|distributor|days|estim/i,
};
export function parse(text, want) {
  const rows = cells(text);
  if (!rows.length) return { kind: want || 'weekends', rows: [], note: 'Nothing to read yet.' };
  const head = rows[0].some((c) => c && !/\d/.test(c)) && rows[0].filter((c) => /\d/.test(c)).length <= 1 ? rows.shift().map((c) => c.toLowerCase()) : null;
  const n = Math.max(...rows.map((r) => r.length));
  const col = (re, not) => (head ? head.findIndex((c) => re.test(c) && !(not && not.test(c))) : -1);
  let kind = want;
  if (!kind) kind = head && head.some((c) => HEAD.country.test(c)) ? 'countries' : head && head.some((c) => /\bweek\b(?!end)/.test(c)) && !head.some((c) => /weekend/.test(c)) ? 'weeks' : 'weekends';
  // money columns (by content), most of the rows must look like money
  const moneyCols = [];
  for (let i = 0; i < n; i++) {
    const vals = rows.map((r) => r[i] || '');
    // money: a currency sign or a k/M/B, or big enough not to be a theater count
    const ok = (v) => isMoneyish(v) && !isPct(v) && (/[$€£¥]|\d\s*[kmb]\s*$/i.test(v) || money(v) >= 100000);
    if (vals.filter(ok).length >= Math.max(1, rows.length * 0.6)) moneyCols.push(i);
  }
  let label = -1, gross = -1, total = -1, theaters = -1, country = -1, opening = -1, release = -1;
  if (head) {
    country = col(HEAD.country);
    release = col(HEAD.release);
    total = col(HEAD.total);
    opening = kind === 'countries' ? col(HEAD.opening) : -1;
    theaters = col(HEAD.theaters, /avg|average|change|%/);
    gross = head.findIndex((c, i) => HEAD.gross.test(c) && !HEAD.total.test(c) && !/avg|average|per |change|%/.test(c) && i !== opening && moneyCols.includes(i));
    label = kind === 'countries' ? country : head.findIndex((c, i) => /date|weekend|week|period/.test(c) && !moneyCols.includes(i) && !HEAD.theaters.test(c));
  }
  if (gross < 0) gross = moneyCols.find((i) => i !== total && i !== opening) ?? -1;
  if (total < 0 && moneyCols.length > 1 && kind !== 'countries') total = moneyCols[moneyCols.length - 1] === gross ? -1 : moneyCols[moneyCols.length - 1];
  // theaters with no header: whole numbers between 1 and 20,000 in a column that is not money
  if (theaters < 0 && kind !== 'countries') theaters = [...Array(n).keys()].find((i) => !moneyCols.includes(i) && rows.every((r) => /^[\d,]+$/.test((r[i] || '').trim()) && money(r[i]) > 0 && money(r[i]) <= 20000) && !(head && HEAD.skip.test(head[i] || ''))) ?? -1;
  if (label < 0) label = [...Array(n).keys()].find((i) => !moneyCols.includes(i) && rows.some((r) => r[i] && /[a-z]/i.test(r[i])) && !(head && HEAD.skip.test(head[i] || ''))) ?? -1;
  const out = [];
  rows.forEach((r, k) => {
    const g = gross >= 0 ? money(r[gross]) : 0;
    if (kind === 'countries') {
      const name = label >= 0 ? r[label] : '';
      if (!name || (!g && !(opening >= 0 && money(r[opening])))) return;
      out.push({ country: name, opening: opening >= 0 ? money(r[opening]) : 0, gross: total >= 0 && !g ? money(r[total]) : g, release: release >= 0 ? r[release] || '' : '' });
    } else {
      if (!g) return;
      out.push({ n: out.length + 1, label: label >= 0 ? r[label] || '' : `${kind === 'weeks' ? 'Week' : 'Weekend'} ${k + 1}`, gross: g,
        total: total >= 0 ? money(r[total]) : 0, theaters: theaters >= 0 ? money(r[theaters]) || parseInt(String(r[theaters]).replace(/\D/g, ''), 10) || 0 : 0 });
    }
  });
  // running totals when the table did not have them
  if (kind !== 'countries' && out.length && !out.some((x) => x.total)) { let t = 0; for (const x of out) { t += x.gross; x.total = t; } }
  const note = out.length ? '' : 'No rows with money figures were found. Copy the table including its header row, or check the type below.';
  return { kind, rows: out, note, headed: !!head };
}

const fmt = (n) => (n > 0 ? fmtMoney(n) : '');
const th = (n) => (n > 0 ? n.toLocaleString('en-US') : '');
export function table(kind, rows, limit) {
  const list = limit ? rows.slice(0, limit) : rows;
  const tr = (cells2) => h('tr', null, ...cells2.map((c, i) => h(i ? 'td' : 'th', { scope: i ? null : 'row' }, c)));
  const head = kind === 'countries' ? ['Country', 'Opening', 'Gross', 'Release'] : [kind === 'weeks' ? 'Week' : 'Weekend', 'Gross', 'To date', 'Theaters'];
  return h('div', { class: 'bo-scroll' }, h('table', { class: 'bo-t' },
    h('thead', null, h('tr', null, ...head.map((x) => h('th', { scope: 'col' }, x)))),
    h('tbody', null, ...list.map((x) => (kind === 'countries' ? tr([x.country, fmt(x.opening), fmt(x.gross), x.release]) : tr([x.label || '#' + x.n, fmt(x.gross), fmt(x.total), th(x.theaters)]))))));
}

// The paste dialog. back() reopens what it was opened from (the movie card) when it closes, saved or not.
export function pasteDialog(r, back) {
  const cur = (S.state.bo && S.state.bo[r.Rid]) || {};
  overlay((close) => {
    const ta = h('textarea', { class: 'bo-in', rows: '8', spellcheck: 'false', placeholder: 'Paste a table here: select the rows on the page you are reading (header row included), copy, and paste.', 'aria-label': 'Pasted table' });
    const kindSel = h('select', { 'aria-label': 'What this table is' }, ...KINDS.map(([k, t]) => h('option', { value: k }, t)));
    const setOpen = h('input', { type: 'checkbox', checked: true });
    const openLbl = h('label', null, setOpen, ' Use the first weekend as the opening weekend');
    const prev = h('div', { class: 'bo-prev' }), msg = h('p', { class: 'bo-msg' });
    const save = h('button', { class: 'btn primary', type: 'button', disabled: true }, 'Save');
    let res = null, chosen = '';
    const run = () => {
      res = parse(ta.value, chosen || undefined);
      if (!chosen) kindSel.value = res.kind;
      msg.textContent = res.rows.length ? `${res.rows.length} row${res.rows.length === 1 ? '' : 's'} found${res.headed ? '' : ' (no header row, so the columns were guessed)'}. Check them before saving.` : res.note;
      prev.replaceChildren(res.rows.length ? table(res.kind, res.rows, 60) : h('span'));
      openLbl.hidden = res.kind !== 'weekends';
      save.disabled = !res.rows.length;
    };
    ta.addEventListener('input', run);
    kindSel.addEventListener('change', () => { chosen = kindSel.value; run(); });
    save.onclick = async () => {
      save.disabled = true;
      const data = { ...cur, [res.kind]: res.rows, updated: new Date().toISOString().slice(0, 10) };
      if (res.kind === 'weekends' && setOpen.checked && res.rows[0]) data.opening = res.rows[0].gross;
      try { await S.saveBoxOffice(r, data); close(); } catch (e) { msg.textContent = 'Could not save: ' + e.message; save.disabled = false; }
    };
    run();
    setTimeout(() => ta.focus(), 30);
    return h('div', { class: 'bo-dlg' },
      h('h2', null, 'Paste box office'),
      h('p', null, h('small', null, `For ${r.Title}${r.Year > 0 ? ' (' + r.Year + ')' : ''}. MMLM does not look these up; paste a table you are reading yourself. It stays on this PC.`)),
      ta,
      h('div', { class: 'bo-opts' }, h('label', null, 'This table is ', kindSel), openLbl),
      msg, prev,
      h('div', { class: 'bo-foot' }, h('button', { class: 'btn', type: 'button', onclick: close }, 'Cancel'), save));
  }, 'bo-host', () => back && back());
}

// The section on the movie card: what has been pasted so far, with Paste and Clear
export function cardSection(r, redraw, reopen) {
  const b = (S.state.bo && S.state.bo[r.Rid]) || {};
  const have = KINDS.filter(([k]) => (b[k] || []).length);
  let tab = have.length ? have[0][0] : 'weekends';
  const body = h('div', { class: 'bo-body' });
  const tabs = h('div', { class: 'bo-tabs', role: 'tablist' });
  const paint = () => {
    tabs.replaceChildren(...have.map(([k, t]) => h('button', { type: 'button', role: 'tab', 'aria-selected': k === tab ? 'true' : 'false', class: k === tab ? 'on' : '', onclick: () => { tab = k; paint(); } }, `${t} (${b[k].length})`)));
    body.replaceChildren(have.length ? table(tab, b[tab]) : h('p', { class: 'muted' }, 'No weekend, weekly or country figures yet. Paste a table you are reading to add them.'));
  };
  paint();
  const clear = have.length ? h('button', { type: 'button', class: 'btn small', onclick: async () => { const d = { ...b }; delete d[tab]; if (tab === 'weekends') delete d.opening; const left = KINDS.some(([k]) => (d[k] || []).length); await S.saveBoxOffice(r, left ? d : null); redraw(); } }, 'Clear this table') : null;
  return h('div', { class: 'spec bo-card' },
    h('h4', null, 'Box office runs'),
    tabs, body,
    h('div', { class: 'bo-actions' }, h('button', { type: 'button', class: 'btn small', onclick: () => pasteDialog(r, reopen || redraw) }, 'Paste box office…'), clear,
      b.updated ? h('small', { class: 'muted' }, 'Added ' + b.updated) : null));
}
