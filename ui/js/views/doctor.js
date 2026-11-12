// PlexDoctor: the Settings tab, the report card (Compact / Verbose) and the alert toast.
// The host runs the check-up (a scan of each library, then read-only checks) on a schedule or on request; this page
// only shows what it found. Nothing here changes Plex.
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { h } from '../util.js';

const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const CHECKS = [
  ['unmatched', 'Unmatched or likely wrong matches', ['unmatched', 'wrongmatch']],
  ['poster', 'Missing posters', ['poster']],
  ['gaps', 'Gaps in a season (E01, E02, E04)', ['gaps']],
  ['dupes', 'Duplicate copies', ['dupes']],
  ['unreadable', "Files Plex couldn't read", ['unreadable']],
  ['av1', "Won't play on Shield (AV1)", ['av1']],
  ['subs', 'No English subtitles', ['subs']],
];
const fmtWhen = (iso) => { if (!iso) return ''; const d = new Date(iso); return isNaN(d) ? iso : d.toLocaleString(undefined, { weekday: 'long', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }); };
const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
const WHY = {
  unreadable: ['Nothing can play it. Often a file that was still copying, or a damaged download.', 'Check the file plays on this PC; if not, replace it. Then refresh the title in Plex.'],
  unmatched: ['No poster, plot or ratings, and it is left out of searches and dashboards by genre or year.', 'In Plex: the title\u2019s menu \u203a Fix Match, and pick the right one.'],
  wrongmatch: ['Plex may have matched a remake, or another title with the same name.', 'Open it in Plex; if the poster or plot is wrong, use Fix Match.'],
  gaps: ['Watching in order skips an episode.', 'Add the missing episode files, or ignore it if the gap is real (an unaired episode).'],
  poster: ['Shows as a blank tile in Plex and here.', 'In Plex: Edit \u203a Poster and pick one, or put poster.jpg in its folder.'],
  dupes: ['Takes space, and Plex may play the copy you did not mean.', 'Keep the copy you want and delete the other from the disk; Plex drops it at its next scan.'],
  av1: ['The Shield cannot play AV1, so Plex has to convert it while you watch (or it will not play).', 'Replace it with an HEVC or H.264 version, or play it on a device that handles AV1.'],
  subs: ['No English subtitles to turn on.', 'Add a subtitle file next to the video (same name, .en.srt), or pick a version that has them.'],
};

// ---- the alert: an extended toast that stays until it is closed or the report is opened
export function initDoctor() {
  bridge.on('doctor', (d) => {
    if (!d) return;
    S.state.doctor = { ...(S.state.doctor || {}), running: !!d.running, text: d.text || '' };
    if (d.done) { S.state.doctor.last = d.summary || S.state.doctor.last; if (d.summary && d.summary.issues > 0 && !d.error && !d.cancelled) alertToast(d.summary); }
    S.notify('doctor');
  });
  // a check-up that found issues while MMLM was not open: show the toast now
  bridge.ready().then(() => bridge.request('doctor.status')).then((st) => {
    S.state.doctor = { ...(S.state.doctor || {}), ...st };
    if (st.unseen && st.last && st.last.issues > 0) alertToast(st.last);
  }).catch(() => {});
}
function alertToast(sum) {
  document.querySelector('.toast.doctor')?.remove();
  const close = () => t.remove();
  const t = h('div', { class: 'toast doctor', role: 'status' },
    h('div', { class: 'dt-head' },
      h('span', { class: 'dt-ico', 'aria-hidden': 'true' }, '!'),
      h('div', null, h('b', null, `PlexDoctor found ${plural(sum.issues, 'issue')}`),
        h('small', null, sum.important ? `${sum.important} important: ${sum.importantText}. ${sum.minor} minor.` : `${plural(sum.minor, 'minor issue')}.`)),
      h('button', { type: 'button', class: 'dt-x', 'aria-label': 'Dismiss', onclick: () => { bridge.request('doctor.seen').catch(() => {}); close(); } }, '\u00d7')),
    h('div', { class: 'dt-act' },
      h('button', { class: 'btn', type: 'button', onclick: close }, 'Later'),
      h('button', { class: 'btn primary', type: 'button', onclick: () => { close(); openReport(); } }, 'View report')));
  document.getElementById('toasts').append(t);
}

// ---- Settings > PlexDoctor
export function doctorTab(repaint, overlay) {
  const s = S.state.settings;
  const status = h('div', { class: 'dr-status' }, h('small', null, 'Loading...'));
  const nextLine = h('small', { class: 'dr-next' });
  const runBtn = h('button', { class: 'btn', type: 'button', onclick: async () => {
    try { runBtn.disabled = true; await bridge.request('doctor.run'); S.state.doctor = { ...(S.state.doctor || {}), running: true }; paintStatus(); } catch (e) { runBtn.disabled = false; S.toast(e.message); }
  } }, 'Run check-up now');
  const set = (k, v) => S.saveSettings({ [k]: v }).then(load);
  const paintStatus = () => {
    const d = S.state.doctor || {}, last = d.last;
    runBtn.disabled = !!d.running;
    if (d.running) { status.className = 'dr-status run'; status.replaceChildren(h('b', null, 'Check-up running...'), h('small', null, d.text || 'Scanning, then checking. Progress shows under the top bar.')); }
    else if (!last) { status.className = 'dr-status'; status.replaceChildren(h('b', null, 'No check-up yet'), h('small', null, 'Run one now, or wait for the schedule.')); }
    else if (last.issues === 0) {
      status.className = 'dr-status ok';
      status.replaceChildren(h('span', { class: 'dr-ico', 'aria-hidden': 'true' }, '\u2713'), h('div', null, h('b', null, 'No issues found'), h('small', null, `${fmtWhen(last.at)}${last.late ? ' \u00b7 ' + last.late.toLowerCase() : ''}`)),
        h('button', { class: 'btn', type: 'button', onclick: () => openReport() }, 'View latest report'));
    } else {
      status.className = 'dr-status warn';
      status.replaceChildren(h('span', { class: 'dr-ico', 'aria-hidden': 'true' }, '!'),
        h('div', null, h('b', null, `${plural(last.issues, 'issue')} found`), h('small', null, `${last.important} important, ${last.minor} minor \u00b7 ${fmtWhen(last.at)}`)),
        h('button', { class: 'btn primary', type: 'button', onclick: () => openReport() }, 'View latest report'));
    }
    nextLine.textContent = (s.doctorFreq || 'weekly') === 'off' ? 'No schedule: check-ups run only when you click Run check-up now.'
      : `Next: ${fmtWhen(d.next)}. Runs only while MMLM is open; a missed one runs the next time you open it.`;
  };
  const load = () => bridge.request('doctor.status').then((st) => { S.state.doctor = { ...(S.state.doctor || {}), ...st }; paintStatus(); }).catch(() => {});
  load();
  const unsub = S.subscribe((t) => { if (t.has('doctor')) { if (!status.isConnected) { unsub?.(); return; } if (!(S.state.doctor || {}).running) load(); else paintStatus(); } });

  const sel = (key, opts, val) => h('select', { onchange: (e) => set(key, key === 'doctorDay' ? +e.target.value : e.target.value) },
    opts.map(([v, t]) => h('option', { value: String(v), selected: String(v) === String(val) ? true : null }, t)));
  const time = h('input', { type: 'time', value: s.doctorTime || '03:00', onchange: (e) => { if (/^\d\d:\d\d$/.test(e.target.value)) set('doctorTime', e.target.value); } });
  const on = new Set(s.doctorChecks || []);
  const checks = CHECKS.map(([id, label, ids]) => h('label', null,
    h('input', { type: 'checkbox', checked: ids.every((x) => on.has(x)) ? true : null, onchange: (e) => {
      const next = new Set(S.state.settings.doctorChecks || []); ids.forEach((x) => (e.target.checked ? next.add(x) : next.delete(x)));
      S.saveSettings({ doctorChecks: [...next] });
    } }), ' ' + label));
  return [
    h('p', null, h('b', null, 'PlexDoctor'), ' gives your Plex library a regular check-up. It looks for the things that quietly go wrong: titles Plex couldn\u2019t match, missing artwork, gaps in a season, files your players can\u2019t play, duplicates. You get a short report of what\u2019s wrong and how to fix it, so problems are caught before you sit down to watch. It only reads; it never changes anything.'),
    status,
    h('div', { class: 'dr-grid' },
      h('span', null, 'Schedule'),
      h('div', { class: 'dr-row' },
        h('label', null, h('small', null, 'How often'), sel('doctorFreq', [['off', 'Off'], ['weekly', 'Weekly'], ['biweekly', 'Every 2 weeks'], ['monthly', 'Monthly (first of the month)']], s.doctorFreq || 'weekly')),
        h('label', null, h('small', null, 'Day'), sel('doctorDay', DAYS.map((d, i) => [i, d]), s.doctorDay ?? 0)),
        h('label', null, h('small', null, 'Time'), time)),
      h('span', null), nextLine,
      h('span', null, 'Run it now'), h('div', null, runBtn),
      h('span', null, 'Report style'),
      h('div', { class: 'seg' }, [['compact', 'Compact'], ['verbose', 'Verbose']].map(([k, t]) => h('button', { type: 'button', class: (s.doctorStyle || 'compact') === k ? 'active' : '', onclick: () => S.saveSettings({ doctorStyle: k }).then(repaint) }, t)))),
    h('hr'),
    h('p', null, h('b', null, 'What it checks')),
    h('div', { class: 'dr-checks' }, checks),
  ];
}

// ---- the report card
export async function openReport() {
  const { overlay } = await import('./settings.js');
  let rep = null;
  try { rep = await bridge.request('doctor.report'); } catch (e) { S.toast(e.message); return; }
  S.state.doctor = { ...(S.state.doctor || {}), unseen: false };
  overlay((close) => {
    const body = h('div', { class: 'dr-report' });
    const paint = () => {
      const style = S.state.settings.doctorStyle || 'compact';
      if (!rep) { body.replaceChildren(h('h2', null, 'PlexDoctor'), h('p', null, 'No report yet. Run a check-up first (Settings \u203a PlexDoctor).')); return; }
      const n = rep.issues.length, names = rep.names || {};
      const head = h('div', { class: 'dr-head' },
        h('div', null, h('small', { class: 'dr-kicker' }, 'PlexDoctor report'), h('h2', null, n ? `${plural(n, 'issue')} found` : 'No issues found'),
          h('small', null, `${fmtWhen(rep.at)} \u00b7 ${rep.counts.movies.toLocaleString()} movies, ${rep.counts.shows.toLocaleString()} shows, ${rep.counts.episodes.toLocaleString()} episodes`)),
        h('div', { class: 'dr-tools' },
          h('div', { class: 'seg' }, [['compact', 'Compact'], ['verbose', 'Verbose']].map(([k, t]) => h('button', { type: 'button', class: style === k ? 'active' : '', onclick: () => S.saveSettings({ doctorStyle: k }).then(paint) }, t))),
          h('button', { class: 'x', type: 'button', 'aria-label': 'Close', onclick: close }, '\u2715')));
      const chips = h('div', { class: 'dr-chips' },
        rep.important ? h('span', { class: 'chip imp' }, `${rep.important} important`) : null,
        rep.minor ? h('span', { class: 'chip min' }, `${rep.minor} minor`) : null,
        rep.compared ? h('span', { class: 'chip' }, `vs last time: ${rep.newCount} new, ${rep.fixedCount} fixed`) : null);
      const notes = [rep.late, ...(rep.notes || [])].filter(Boolean).map((x) => h('p', { class: 'dr-note' }, x));
      const open = (it) => (it.rid || it.show ? h('a', { href: '#', onclick: (e) => { e.preventDefault(); close(); goTo(it); } }, 'Open in MMLM \u203a') : null);
      let list;
      if (style === 'compact') {
        const groups = new Map();
        rep.issues.forEach((it) => { if (!groups.has(it.check)) groups.set(it.check, []); groups.get(it.check).push(it); });
        list = h('div', { class: 'dr-compact' }, [...groups].map(([check, items]) => h('div', { class: 'dr-line' },
          h('span', { class: `dot ${items[0].sev}` }), h('b', null, names[check] || check), h('span', { class: 'n' }, String(items.length)),
          h('span', { class: 't', title: items.map((i) => i.title).join(', ') }, items.slice(0, 4).map((i) => i.check === 'gaps' || i.check === 'wrongmatch' ? `${i.title}: ${i.detail}` : i.title).join(' \u00b7 ') + (items.length > 4 ? ` \u00b7 +${items.length - 4} more` : '')))));
      } else {
        const today = new Date();
        const since = (d) => { if (!d) return ''; const days = Math.round((today - new Date(d)) / 864e5); return days < 7 ? 'new this week' : `for ${Math.round(days / 7)} week${Math.round(days / 7) === 1 ? '' : 's'}`; };
        list = h('div', { class: 'dr-verbose' }, rep.issues.slice(0, 300).map((it) => h('div', { class: 'dr-item' },
          h('div', { class: 'dr-ih' }, h('span', { class: `chip ${it.sev === 'important' ? 'imp' : 'min'}` }, it.sev === 'important' ? 'Important' : 'Minor'), h('b', null, names[it.check] || it.check), h('small', null, since(it.firstSeen))),
          h('div', { class: 'dr-it' }, it.title),
          h('dl', null, h('dt', null, 'What'), h('dd', null, it.detail), h('dt', null, 'Why it matters'), h('dd', null, WHY[it.check]?.[0] || ''), h('dt', null, 'How to fix'), h('dd', null, WHY[it.check]?.[1] || '')),
          open(it))), rep.issues.length > 300 ? h('p', null, h('small', null, `+ ${rep.issues.length - 300} more (Compact lists them all by type).`)) : null);
      }
      const clean = (rep.clean || []).length ? h('p', { class: 'dr-clean' }, `\u2713 No problems: ${rep.clean.map((c) => names[c] || c).join(', ')}.`) : null;
      const skipped = (rep.skipped || []).length ? h('p', { class: 'dr-skip' }, `Not checked (turned off): ${rep.skipped.map((c) => names[c] || c).join(', ')}.`) : null;
      body.replaceChildren(head, chips, ...notes, n ? list : null, clean, skipped);
    };
    paint();
    return body;
  }, 'dr-host');
}
function goTo(it) {
  if (it.show) { location.hash = `#/tv/${encodeURIComponent(it.show)}`; return; }
  const r = S.state.libs.movies.rows?.find((x) => x.Rid === it.rid);
  location.hash = '#/movies';
  if (r) import('./card.js').then((m) => m.openCard(r, S.toast));
  else S.toast('That title is not in the library any more.');
}
