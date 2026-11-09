// End-to-end test of the page against the real backend (no WebView2): tests/host-pipe.ps1 runs modules\MMLM.Host.psm1,
// Playwright's Chromium shows ui\ with a stand-in for window.chrome.webview, and tests/plex-mock.py plays Plex.
// Run: python3 tests/plex-mock.py &  then  LOCALAPPDATA=<scratch> MMLM_HOST_TEST_TOKEN=tok node tests/page-e2e.js <pwsh> <out-dir>
const { chromium } = require('playwright');
const { spawn } = require('child_process');
const path = require('path'), fs = require('fs');
const root = path.resolve(__dirname, '..'), [pwsh = 'pwsh', outDir = '.'] = process.argv.slice(2);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json', '.jpg': 'image/jpeg', '.png': 'image/png' };
let fails = 0; const check = (ok, text) => { console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${text}`); if (!ok) fails++; };

(async () => { let page = null; try { await run(); } catch (e) { console.log('FAIL  ' + e.message.split('\n')[0]); if (globalThis.__page) await globalThis.__page.screenshot({ path: path.join(outDir, 'e2e-fail.png') }); process.exit(1); } })();
async function run() {
  const data = path.join(process.env.LOCALAPPDATA, 'Modern-Media-Library-Manager');
  fs.mkdirSync(data, { recursive: true });
  fs.rmSync(path.join(data, 'Library'), { recursive: true, force: true }); fs.rmSync(path.join(data, 'Dashboard'), { recursive: true, force: true });
  fs.writeFileSync(path.join(data, 'settings.json'), JSON.stringify({ PlexUrl: 'http://127.0.0.1:32499', PlexTokenProtected: 'x' }));
  const host = spawn(pwsh, ['-NoProfile', '-File', path.join(__dirname, 'host-pipe.ps1')], { env: process.env });
  let page = null, cache = '', buf = '';
  void page;
  const early = [];
  host.stdout.on('data', (d) => {
    buf += d; let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (line.startsWith('CACHE ')) cache = line.slice(6);
      else if (line.startsWith('POST ')) { const j = line.slice(5); if (process.env.E2E_TRACE && !j.includes('"rows"')) console.log('  <- ' + j.slice(0, 160)); if (page) page.evaluate((m) => window.__deliver(m), j).catch(() => {}); else early.push(j); }
      else if (line) console.log('host:', line);
    }
  });
  host.stderr.on('data', (d) => console.log('host err:', String(d).trim()));
  while (!cache) await new Promise((r) => setTimeout(r, 100));

  const b = await chromium.launch();
  page = await b.newPage({ viewport: { width: 1400, height: 900 } }); globalThis.__page = page;
  const errs = []; page.on('pageerror', (e) => errs.push(e.message)); page.on('console', (m) => { if (m.type() === 'error') errs.push(m.text()); });
  await page.exposeFunction('__hostSend', (m) => { if (process.env.E2E_TRACE) console.log('  -> ' + m.slice(0, 160)); host.stdin.write(m + '\n'); });
  await page.addInitScript(() => {
    const ls = [];
    window.__deliver = (j) => ls.forEach((fn) => fn({ data: JSON.parse(j) }));
    window.chrome = { webview: { postMessage: (m) => window.__hostSend(JSON.stringify(m)), addEventListener: (t, fn) => ls.push(fn) } };
  });
  await page.route(/^https:\/\/mmlm\.(ui|cache)\//, (route) => {
    const u = new URL(route.request().url()), base = u.host === 'mmlm.ui' ? path.join(root, 'ui') : cache;
    const f = path.join(base, decodeURIComponent(u.pathname));
    if (!f.startsWith(base) || !fs.existsSync(f)) return route.fulfill({ status: 404, body: '' });
    route.fulfill({ status: 200, body: fs.readFileSync(f), contentType: types[path.extname(f)] || 'application/octet-stream' });
  });
  await page.goto('https://mmlm.ui/index.html');
  await page.waitForTimeout(1500);
  check(await page.isVisible('text=No Movies yet'), 'an empty library offers a scan');
  await page.click('text=Scan Movies from Plex');
  await page.waitForSelector('.wall .pc', { timeout: 30000 });
  check((await page.$$('.wall .pc')).length === 7, 'the scan fills the poster wall (7 movies)');
  await page.waitForTimeout(400);
  const img = await page.$eval('.wall .pc img', (i) => i.complete && i.naturalWidth > 0).catch(() => false);
  check(img, 'posters load from the cache folder');
  check(await page.isVisible('text=Scan finished'), 'the scan strip reports the end of the scan');
  await page.screenshot({ path: path.join(outDir, 'e2e-movies.png') });
  await page.click('.wall .pc');
  check(await page.isVisible('.sheet h2'), 'a poster opens its card');
  const html = await page.content();
  check(!/[A-Z]:\\|\/library\/parts|FullPath/.test(html), 'no file paths on the page');
  await page.keyboard.press('Escape');
  await page.click('#nav a[data-route="tv"]');
  await page.waitForTimeout(500);
  await page.click('#btn-refresh');
  await page.waitForSelector('.wall .pc', { timeout: 30000 });
  check((await page.$$('.wall .pc')).length === 2, 'F5 / refresh scans TV: one tile per show (2 shows)');
  await page.click('.seg button:has-text("Grid")');
  await page.click('.xall');
  check((await page.$$('tr.ep')).length === 10, 'Expand all shows every episode in the grid');
  await page.screenshot({ path: path.join(outDir, 'e2e-tvgrid.png') });
  await page.click('#live-status');
  await page.waitForTimeout(500);
  check(await page.isVisible('#haltbar button:has-text("Resume")'), 'the live status button pauses traffic');
  await page.click('#btn-refresh'); await page.waitForTimeout(400);
  check(await page.isVisible('text=paused'), 'no scan while paused');
  await page.click('#haltbar button:has-text("Resume")'); await page.waitForTimeout(400);
  check(await page.isHidden('#haltbar'), 'Resume clears the pause');
  await page.goto('https://mmlm.ui/index.html#/stats');
  await page.waitForTimeout(1500);
  check(await page.isVisible('.kpi'), 'Stats opens after a reload (library read back from the cache)');
  check(errs.length === 0, 'no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''));
  await b.close();
  host.stdin.end();
  console.log(`Done: ${fails} problem(s).`);
  process.exit(fails ? 1 : 0);
}
