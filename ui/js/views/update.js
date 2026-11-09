import * as S from '../store.js';
import { h } from '../util.js';
import { overlay } from './settings.js';

const fmtDate = (iso) => { const d = new Date(iso); return isNaN(d) ? '' : d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }); };
const mb = (n) => (n ? `${(n / 1048576).toFixed(1)} MB` : '');

// Release notes arrive as GitHub markdown; show them as simple text (headings become bold lines, bullets stay bullets).
function notesView(text) {
  const box = h('div', { class: 'upd-notes' });
  String(text || '').split(/\r?\n/).forEach((line) => {
    const t = line.trim();
    if (!t) return;
    if (/^#{1,6}\s/.test(t)) box.append(h('div', { class: 'upd-h' }, t.replace(/^#{1,6}\s+/, '')));
    else if (/^[-*]\s/.test(t)) box.append(h('div', { class: 'upd-li' }, t.replace(/^[-*]\s+/, '')));
    else box.append(h('div', null, t));
  });
  if (!box.childNodes.length) box.append(h('div', { class: 'muted' }, 'No release notes were published.'));
  return box;
}

export function openUpdate() {
  S.state.update.quiet = false;
  // clicking the version chip always asks GitHub again, unless a check/download is running or an update is already waiting
  if (!['checking', 'downloading', 'available', 'staged'].includes(S.state.update.phase)) S.checkUpdate();
  overlay((close) => {
    const box = h('div', { class: 'upd' });
    const paint = () => {
      if (!box.isConnected && box.dataset.mounted) { unsub(); return; }
      box.dataset.mounted = '1';
      const u = S.state.update, i = u.info || {};
      const head = h('h2', null, 'Updates');
      const cur = h('p', { class: 'muted' }, `You have v${S.state.version || '?'}`);
      const btn = (label, fn, primary) => h('button', { class: `btn ${primary ? 'primary' : ''}`, type: 'button', onclick: fn }, label);
      const bar = () => h('div', null, h('div', { class: 'bar' }, h('i', { style: { width: `${u.pct || 3}%` } })), h('small', null, u.text || ''));
      let body;
      switch (u.phase) {
        case 'checking':
          body = [bar(), h('div', { class: 'upd-actions' }, btn('Close', close))]; break;
        case 'current':
          body = [h('p', null, h('b', null, `You're up to date (v${i.latest}).`)), h('div', { class: 'upd-actions' }, btn('Check again', () => S.checkUpdate()), btn('Done', close, true))]; break;
        case 'ahead':
          body = [h('p', null, `This copy (v${i.current}) is newer than the latest published release (v${i.latest}).`), h('div', { class: 'upd-actions' }, btn('Done', close, true))]; break;
        case 'none':
          body = [h('p', null, 'No release has been published yet.'), h('div', { class: 'upd-actions' }, btn('Done', close, true))]; break;
        case 'available':
          body = [h('p', null, h('b', null, `Version ${i.latest} is available`), h('small', { style: { marginLeft: '8px' } }, [fmtDate(i.published), mb(i.size)].filter(Boolean).join(' \u00b7 '))),
            notesView(i.notes),
            i.installable === false ? h('p', { class: 'muted' }, 'This release has no update package attached yet, so it cannot be installed from here. Try again later.') : null,
            h('div', { class: 'upd-actions' }, btn('Later', close), i.installable === false ? null : btn('Download and install', () => S.downloadUpdate(), true))]; break;
        case 'downloading':
          body = [h('p', null, h('b', null, `Downloading version ${i.latest || ''}`)), bar(), h('div', { class: 'upd-actions' }, btn('Cancel', () => S.cancelUpdate()))]; break;
        case 'staged':
          body = [h('p', null, h('b', null, `Version ${i.latest} is downloaded and verified.`)),
            h('p', { class: 'muted' }, 'The dashboard will close, swap in the new files and reopen. Your favorites, settings and cached data stay as they are. If the new version fails to start, the previous one is restored.'),
            h('div', { class: 'upd-actions' }, btn('Not now', close), btn('Restart now', () => { S.installUpdate(); }, true))]; break;
        case 'error':
          body = [h('p', { class: 'upd-err' }, u.error), h('div', { class: 'upd-actions' }, btn('Close', close), btn('Try again', () => S.checkUpdate(), true))]; break;
        default:
          body = [h('div', { class: 'upd-actions' }, btn('Check for updates', () => S.checkUpdate(), true))];
      }
      box.replaceChildren(head, cur, ...body.filter(Boolean));
    };
    const unsub = S.subscribe((t) => { if (t.has('update')) paint(); });
    paint();
    return box;
  });
}
