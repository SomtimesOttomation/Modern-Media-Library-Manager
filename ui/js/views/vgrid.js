// A table that draws only the rows in view, so 20,000 episodes scroll as smoothly as 20.
// rowsHtml(list) returns the <tr>s; columns are drawn by the caller in the <thead>.
const ROW = 33;

export function vgrid(host, { head, rowHtml, onRow, onHead }) {
  host.innerHTML = '<div class="vgrid"><div class="vgrid-scroll"><table><thead></thead><tbody></tbody></table></div></div>';
  const scroll = host.querySelector('.vgrid-scroll'), thead = host.querySelector('thead'), tbody = host.querySelector('tbody');
  let items = [], cols = 1, raf = 0, last = '';
  const paint = (force) => {
    const top = scroll.scrollTop, hgt = scroll.clientHeight || 600;
    const a = Math.max(0, Math.floor(top / ROW) - 10), b = Math.min(items.length, Math.ceil((top + hgt) / ROW) + 10);
    const key = `${a}|${b}|${items.length}`;
    if (!force && key === last) return;
    last = key;
    let html = `<tr class="spacer"><td colspan="${cols}" style="height:${a * ROW}px"></td></tr>`;
    for (let i = a; i < b; i++) html += rowHtml(items[i], i);
    html += `<tr class="spacer"><td colspan="${cols}" style="height:${(items.length - b) * ROW}px"></td></tr>`;
    tbody.innerHTML = html;
  };
  scroll.addEventListener('scroll', () => { if (!raf) raf = requestAnimationFrame(() => { raf = 0; paint(false); }); });
  const onResize = () => paint(true);
  window.addEventListener('resize', onResize);
  tbody.addEventListener('click', (e) => { const tr = e.target.closest('tr[data-i]'); if (tr) onRow(items[+tr.dataset.i], e); });
  thead.addEventListener('click', (e) => { const th = e.target.closest('th[data-c]'); if (th && onHead) onHead(th.dataset.c, e); else if (onHead) onHead(null, e); });
  return {
    set(list, { keepScroll = true } = {}) {
      items = list;
      const hd = head();
      thead.innerHTML = hd.html; cols = hd.count;
      if (!keepScroll) scroll.scrollTop = 0;
      paint(true);
    },
    destroy() { window.removeEventListener('resize', onResize); },
  };
}
export const ROW_HEIGHT = ROW;
