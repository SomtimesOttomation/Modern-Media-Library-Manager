// Browser preview host (as in DashLauncher's Sample): serve the ui folder with any local web server, for example
// `python -m http.server` inside ui, and open index.html. It answers the same commands as modules\MMLM.Host.psm1 with a
// small made-up library. Dev only: the real host never loads this file.
let emit = () => {};
export function attach(fn) { emit = fn; }

const qs = new URLSearchParams(location.search);
const settings = { theme: qs.get('theme') || 'system', updateCheck: false, moviesView: qs.get('view') || 'posters', tvView: qs.get('view') || 'posters', moviesSort: 'added', tvSort: 'title', columns: [], hideDupes: false, tvScale: 100, clearScale: 100, bannerScale: 100, doctorFreq: 'off', doctorAck: false, doctorDay: 0, doctorTime: '03:00', doctorStyle: 'compact', doctorChecks: ['unreadable', 'unmatched', 'wrongmatch', 'gaps', 'poster', 'dupes', 'av1'], cmpInflation: false, artLogo: false, artBackground: false, artBanner: false, fxLeft: 'auto', fxRight: 'auto', fxMotion: 'full', vsStyle: 'arcade', cmpTally: true, cmpWalkover: true, cmpImdb: true };
const plex = { url: 'http://plex-server:32400', hasToken: true, jellyfin: { url: '', hasKey: false }, use: { movies: 'plex', tv: 'plex' } };
if (qs.has('fresh')) { plex.url = ''; plex.hasToken = false; }
const traffic = { requests: 0, bytes: 0, errors: 0 };
let halted = false, scanTimer = 0;
const empty = qs.has('empty');

const seed = (s) => { let x = 17; for (const c of String(s)) x = (x * 31 + c.charCodeAt(0)) % 2147483647; const r = () => (x = (x * 48271) % 2147483647) / 2147483647; r(); r(); r(); return r; };
const pick = (rnd, a) => a[Math.floor(rnd() * a.length)];
// Settings > Artwork samples: background art, a clear logo (most titles), a TV banner (some shows)
const svgUrl = (svg) => 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
const artOf = (hue) => svgUrl(`<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720"><defs><radialGradient id="a" cx=".7" cy=".3" r=".9"><stop offset="0" stop-color="hsl(${hue},60%,55%)"/><stop offset=".6" stop-color="hsl(${(hue + 30) % 360},50%,22%)"/><stop offset="1" stop-color="hsl(${hue},40%,8%)"/></radialGradient></defs><rect width="1280" height="720" fill="url(#a)"/><circle cx="980" cy="260" r="180" fill="hsl(${(hue + 180) % 360},70%,70%)" opacity=".25"/><path d="M0 560 L320 420 L560 520 L860 380 L1280 540 V720 H0Z" fill="hsl(${hue},30%,10%)" opacity=".85"/></svg>`);
const logoOf = (title, hue) => svgUrl(`<svg xmlns="http://www.w3.org/2000/svg" width="800" height="310"><text x="0" y="200" textLength="780" lengthAdjust="spacingAndGlyphs" font-family="Impact, Arial Black, sans-serif" font-size="${Math.min(150, 1400 / Math.max(6, title.length))}" fill="hsl(${hue},80%,78%)" stroke="#000" stroke-width="5" paint-order="stroke" letter-spacing="3">${title.toUpperCase().replace(/&/g, '&amp;')}</text></svg>`);
const bannerOf = (title, hue) => svgUrl(`<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="185"><defs><linearGradient id="b"><stop offset="0" stop-color="hsl(${hue},60%,35%)"/><stop offset="1" stop-color="hsl(${(hue + 60) % 360},55%,14%)"/></linearGradient></defs><rect width="1000" height="185" fill="url(#b)"/><text x="28" y="92" font-family="Georgia, serif" font-size="54" fill="#fff" font-style="italic">${title.replace(/&/g, '&amp;')}</text></svg>`);
// what Plex would have for a title (decided by its name, so the other sample values stay the same)
function artwork(title, tv) {
  let x = 0; for (const c of title) x = (x * 31 + c.charCodeAt(0)) >>> 0;
  const hue = x % 360;
  return { Art: x % 7 ? artOf(hue) : '', Logo: x % 5 ? logoOf(title, hue) : '', Banner: tv && x % 3 ? bannerOf(title, hue) : '' };
}
function poster(title, hue) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="240" height="360"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="hsl(${hue},55%,42%)"/><stop offset="1" stop-color="hsl(${(hue + 40) % 360},60%,18%)"/></linearGradient></defs><rect width="240" height="360" fill="url(#g)"/><circle cx="185" cy="80" r="46" fill="hsla(${(hue + 180) % 360},70%,70%,.35)"/><text x="18" y="300" font-family="Segoe UI,Arial" font-size="22" font-weight="700" fill="#fff">${title.replace(/&/g, '&amp;').slice(0, 18)}</text></svg>`;
  return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
}
const FIELDS = [
  ['Title', 'string', 'Overview', 1], ['Library', 'string', 'Overview', 1], ['Show', 'string', 'Overview', 1], ['Season', 'int', 'Overview', 0], ['Episode', 'int', 'Overview', 0],
  ['Year', 'int', 'Overview', 1], ['Genre', 'string', 'Overview', 1], ['MPAARating', 'string', 'Overview', 1], ['Rating', 'double', 'Overview', 1], ['RuntimeMin', 'double', 'Overview', 1],
  ['Studio', 'string', 'Overview', 1], ['Director', 'string', 'Overview', 0], ['Cast', 'string', 'Overview', 0], ['Tagline', 'string', 'Overview', 0], ['Plot', 'string', 'Overview', 0],
  ['ReleaseDate', 'string', 'Overview', 0], ['IMDBID', 'string', 'Overview', 0], ['Resolution', 'string', 'Video', 0], ['ResolutionClass', 'string', 'Video', 1], ['VideoCodec', 'string', 'Video', 1],
  ['VideoBitRateMbps', 'double', 'Video', 1], ['BitsPerPixel', 'double', 'Video', 0], ['FrameRate', 'double', 'Video', 1], ['BitDepth', 'int', 'Video', 1], ['HDRType', 'string', 'HDR', 1],
  ['HDRStack', 'string', 'HDR', 0], ['DVProfile', 'string', 'HDR', 1], ['DVLayer', 'string', 'HDR', 1], ['AudioFormat', 'string', 'Audio', 1], ['ObjectAudio', 'string', 'Audio', 1],
  ['AudioChannels', 'int', 'Audio', 0], ['AudioLayout', 'string', 'Audio', 1], ['AudioLanguages', 'string', 'Audio', 1], ['SubtitleTracks', 'int', 'Subtitles', 1], ['SubtitleLanguages', 'string', 'Subtitles', 0],
  ['FileName', 'string', 'File', 1], ['Container', 'string', 'File', 1], ['Type', 'string', 'File', 0], ['FileSizeGB', 'double', 'File', 1], ['Source', 'string', 'File', 1], ['Added', 'string', 'File', 1],
  ['HasNfo', 'bool', 'Library', 0], ['HasPoster', 'bool', 'Library', 0], ['RTCritic', 'int', 'Ratings', 1], ['RTAudience', 'int', 'Ratings', 1], ['Metascore', 'int', 'Ratings', 1],
  ['BoxOfficeDomestic', 'double', 'Box office', 1], ['BoxOfficeWorldwide', 'double', 'Box office', 1], ['OpeningDomestic', 'double', 'Box office', 1], ['ViewCount', 'int', 'Library', 0], ['Poster', 'string', 'Library', 0], ['Art', 'string', 'Library', 0], ['Logo', 'string', 'Library', 0], ['Banner', 'string', 'Library', 0], ['Rid', 'string', 'Library', 0],
].map(([n, t, g, s]) => ({ n, t, g, s: !!s }));
const W1 = ['Silent', 'Crimson', 'Last', 'Hidden', 'Golden', 'Broken', 'Northern', 'Midnight', 'Paper', 'Iron', 'Glass', 'Electric', 'Quiet', 'Burning', 'Lost'];
const W2 = ['Harbor', 'Orchard', 'Signal', 'Kingdom', 'Frontier', 'Lantern', 'Meridian', 'Tide', 'Archive', 'Comet', 'Garden', 'Engine', 'Summit', 'Mirror', 'River'];
const GEN = ['Drama', 'Comedy', 'Thriller', 'Science Fiction', 'Animation', 'Documentary', 'Adventure', 'Horror', 'Romance', 'Crime'];
function quality(rnd) {
  const res = pick(rnd, ['4K', '4K', '1080p', '1080p', '1080p', '720p', 'SD']);
  const hdr = res === '4K' ? pick(rnd, ['Dolby Vision', 'Dolby Vision', 'HDR10', 'HDR10+', 'SDR']) : 'SDR';
  const prof = hdr === 'Dolby Vision' ? pick(rnd, ['8', '8', '7', '5']) : '';
  return { ResolutionClass: res, Resolution: { '4K': '3840x2160', '1080p': '1920x1080', '720p': '1280x720', SD: '720x480' }[res], HDRType: hdr, HDRStack: hdr === 'Dolby Vision' ? `Dolby Vision P${prof}` : hdr,
    DVProfile: prof, DVLayer: prof === '7' ? pick(rnd, ['FEL', 'MEL']) : prof ? 'Single layer' : '', VideoCodec: res === 'SD' ? 'AVC' : pick(rnd, ['HEVC', 'HEVC', 'AVC', 'AV1']),
    BitDepth: hdr === 'SDR' ? 8 : 10, FrameRate: 23.976, VideoBitRateMbps: Math.round((res === '4K' ? 18 + rnd() * 50 : res === '1080p' ? 4 + rnd() * 20 : 1 + rnd() * 4) * 10) / 10,
    BitsPerPixel: Math.round((0.03 + rnd() * 0.2) * 1000) / 1000,
    AudioFormat: pick(rnd, ['Dolby TrueHD', 'DTS-HD MA', 'Dolby Digital Plus', 'AAC', 'Dolby Digital']), ObjectAudio: pick(rnd, ['Dolby Atmos', 'None', 'None', 'DTS:X']),
    AudioLayout: pick(rnd, ['7.1', '5.1', '5.1', 'Stereo']), AudioChannels: 6, AudioLanguages: pick(rnd, ['English', 'English; French', 'English; Spanish', 'Japanese; English']),
    SubtitleTracks: Math.floor(rnd() * 6), SubtitleLanguages: 'English', Container: pick(rnd, ['Matroska', 'Matroska', 'MPEG-4']), Type: 'Video', Source: pick(rnd, ['Blu-ray', 'UHD Blu-ray', 'WEB-DL', 'Unknown']),
    HasNfo: rnd() > 0.2, HasPoster: true };
}
function movies() {
  const out = [];
  for (let i = 0; i < (qs.has('big') ? 5000 : 84); i++) {
    const rnd = seed('m' + i), title = `The ${pick(rnd, W1)} ${pick(rnd, W2)}${i % 9 === 0 ? ' II' : ''}`, year = 1975 + Math.floor(rnd() * 51);
    const q = quality(rnd);
    out.push({ Title: title, Library: 'Movies', Year: year, Genre: `${pick(rnd, GEN)}, ${pick(rnd, GEN)}`, MPAARating: pick(rnd, ['G', 'PG', 'PG-13', 'R', 'R']), Rating: Math.round((5 + rnd() * 4) * 10) / 10,
      RuntimeMin: 85 + Math.floor(rnd() * 80), Studio: pick(rnd, ['Northlight Pictures', 'Blue Harbor Films', 'Kestrel Studios', 'Paper Moon']), Director: pick(rnd, ['A. Moreau', 'J. Okafor', 'R. Castell', 'M. Vance']),
      Cast: 'Alex Hale, Sam Brandt, Jordan Pike', Tagline: rnd() > 0.5 ? 'Some stories wait for the right night.' : '', Plot: 'A made-up film for the browser preview. Every title, poster and number here is invented.',
      ReleaseDate: `${year}-${String(1 + Math.floor(rnd() * 12)).padStart(2, '0')}-${String(1 + Math.floor(rnd() * 28)).padStart(2, '0')}`, IMDBID: rnd() > 0.3 ? 'tt' + (1000000 + i) : '',
      ...q, FileName: `${title} (${year}).mkv`, FileSizeGB: Math.round((q.ResolutionClass === '4K' ? 40 + rnd() * 40 : 4 + rnd() * 16) * 100) / 100,
      Added: `20${20 + Math.floor(rnd() * 7)}-${String(1 + Math.floor(rnd() * 12)).padStart(2, '0')}-${String(1 + Math.floor(rnd() * 28)).padStart(2, '0')}`,
      RTCritic: rnd() > 0.25 ? Math.floor(20 + rnd() * 80) : 0, RTAudience: rnd() > 0.25 ? Math.floor(30 + rnd() * 70) : 0, Metascore: rnd() > 0.3 ? Math.floor(25 + rnd() * 70) : 0,
      Rid: 'p:' + (1000 + i), ViewCount: rnd() > 0.5 ? 1 : 0,
      BoxOfficeDomestic: rnd() > 0.4 ? Math.floor(rnd() * 4e8) : 0, BoxOfficeWorldwide: rnd() > 0.4 ? Math.floor(rnd() * 1.1e9) : 0, OpeningDomestic: rnd() > 0.5 ? Math.floor(rnd() * 9e7) : 0, Poster: rnd() > 0.06 ? poster(title, Math.floor(rnd() * 360)) : '', ...artwork(title, false) });
  }
  return out;
}
function tv() {
  const out = [];
  for (let s = 0; s < (qs.has('big') ? 420 : 14); s++) {
    const rnd = seed('s' + s), show = `${pick(rnd, W1)} ${pick(rnd, W2)}`, y0 = 1995 + Math.floor(rnd() * 28), seasons = 1 + Math.floor(rnd() * 5), p = poster(show, Math.floor(rnd() * 360));
    const genre = `${pick(rnd, GEN)}, ${pick(rnd, GEN)}`, q = quality(rnd), showArt = artwork(show, true);
    for (let n = 1; n <= seasons; n++) for (let e = 1; e <= 6 + Math.floor(rnd() * 6); e++) {
      out.push({ Title: `${show} - S${String(n).padStart(2, '0')}E${String(e).padStart(2, '0')} - Chapter ${e}`, Library: 'TV', Show: show, Season: n, Episode: e, Year: y0 + n - 1, Genre: genre,
        MPAARating: 'TV-14', RuntimeMin: 42 + Math.floor(rnd() * 20), Studio: pick(rnd, ['Harbor TV', 'Northlight', 'Kestrel']), ReleaseDate: `${y0 + n - 1}-0${1 + (e % 9)}-1${e % 9}`,
        ...q, Rid: `p:${5000 + s * 1000 + n * 50 + e}`, ViewCount: rnd() > 0.4 ? 1 : 0, FileName: `S${n}E${e}.mkv`, FileSizeGB: Math.round((1 + rnd() * 5) * 100) / 100, Added: `202${Math.floor(rnd() * 6)}-0${1 + Math.floor(rnd() * 9)}-1${Math.floor(rnd() * 9)}`, Poster: p, ...showArt });
    }
  }
  return out;
}
const libs = { movies: movies(), tv: tv() };
// PlexDoctor sample report (made up, from the sample library)
let doctorReport = null;
function mockDoctorReport() {
  const mv = libs.movies, shows = [...new Set(libs.tv.map((r) => r.Show))], today = '2026-11-12';
  const I = (check, sev, title, detail, rid, show, firstSeen) => ({ id: check + '|' + (rid || show), check, sev, title, detail, rid: rid || '', show: show || '', firstSeen: firstSeen || today });
  const issues = [
    I('unreadable', 'important', `${mv[3].Title} (${mv[3].Year})`, 'Plex found no video or audio in it, so it will not play.', mv[3].Rid),
    I('unmatched', 'important', `${mv[8].Title} (${mv[8].Year})`, 'Plex did not match it: no IMDb or TMDB link, no genres or plot.', mv[8].Rid, '', '2026-10-22'),
    I('wrongmatch', 'minor', mv[12].Title, `The folder says 1995, Plex says ${mv[12].Year}.`, mv[12].Rid),
    I('gaps', 'minor', `${shows[1]}, Season 2`, 'Missing E07 (has 9 of 10).', '', shows[1], '2026-10-29'),
    I('gaps', 'minor', `${shows[4]}, Season 1`, 'Missing E03, E04 (has 6 of 8).', '', shows[4]),
    I('poster', 'minor', `${mv[20].Title} (${mv[20].Year})`, 'No poster in Plex.', mv[20].Rid, '', '2026-10-08'),
    I('av1', 'minor', `${mv[30].Title} (${mv[30].Year})`, 'AV1 4K', mv[30].Rid),
  ];
  return { at: '2026-11-08T03:00:00', late: '', notes: [], counts: { movies: mv.length, shows: shows.length, episodes: libs.tv.length }, issues,
    important: 2, minor: 5, clean: ['dupes'], skipped: ['subs'], compared: true, newCount: 2, fixedCount: 3,
    names: { unreadable: "Plex couldn't read the file", unmatched: 'Not matched', wrongmatch: 'Possible wrong match', gaps: 'Gaps in a season', poster: 'Missing poster', dupes: 'Duplicate copies', av1: "Won't play on Shield (AV1)", subs: 'No English subtitles' } };
}
function doctorSum() { const r = doctorReport; return { at: r.at, late: r.late, issues: r.issues.length, important: r.important, minor: r.minor, importantText: '1 unreadable file, 1 not matched', counts: r.counts, newCount: r.newCount, fixedCount: r.fixedCount, compared: true }; }
let dashData = { movies: [], tv: [] };
let collections = [
  { name: 'Weekend picks', type: 'manual', query: '', items: [0, 3, 7, 11].map((i) => ({ ids: ['p:' + (1000 + i)], title: '', year: 0 })) },
  { name: 'Late-night saga', type: 'manual', tab: 'movies', query: '', items: [1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 15].map((i) => ({ ids: ['p:' + (1000 + i)], title: '', year: 0 })) },
  { name: '80s 4K', type: 'rule', query: 'year:1980-1989 res:4k', items: [] },
];
const pack = (rows) => ({ fields: FIELDS, rows: rows.map((r) => FIELDS.map((f) => (r[f.n] === undefined || r[f.n] === '' ? null : r[f.n]))) });

const later = (ms, fn) => setTimeout(fn, ms);
export async function request(cmd, args = {}) {
  await new Promise((r) => setTimeout(r, 30));
  switch (cmd) {
    case 'init': return { version: '0.5.0', movies: { count: libs.movies.length, when: '2026-11-07 21:14' }, tv: { count: libs.tv.length, when: '2026-11-06 09:02' }, halted, scanning: false, scanTab: '', mode: qs.get('mode') || 'standalone', theme: qs.get('hosttheme') || '', settings, plex, updateNote: null, debug: true };
    case 'library.get': return empty ? { empty: true } : pack(libs[args.tab === 'tv' ? 'tv' : 'movies']);
    case 'settings.set': settings[args.key] = args.value; return settings;
    case 'plex.set': plex.url = args.url; if (args.token) plex.hasToken = true; return plex;
    case 'jellyfin.set': plex.jellyfin.url = args.url; if (args.key) plex.jellyfin.hasKey = true; return plex;
    case 'server.use': plex.use[args.tab] = args.kind; return plex;
    case 'scan.timing': return { movies: '2026-11-12 20:10  movies  server=plex  items=4120  new=12  finished  total=41.3s  rebuild=False  PowerShell 5.1  MMLM 0.15.3\nlist                3.10 s     4120\nfetch              21.40 s      300\nconvert             9.80 s      300', tv: '' };
    case 'server.test':
      setTimeout(() => emit('servertest', args.kind === 'jellyfin'
        ? { kind: 'jellyfin', ok: true, info: { name: 'Sample Jellyfin', version: '10.10.3', libraries: [{ name: 'Films', type: 'movie' }, { name: 'Series', type: 'show' }] }, error: '' }
        : { kind: 'plex', ok: true, info: { name: 'Plex', version: '', libraries: [{ name: 'Movies', type: 'movie' }, { name: 'TV Shows', type: 'show' }] }, error: '' }), 400);
      return true;
    case 'scan.start': {
      if (halted) throw new Error('Traffic is paused. Resume it first.');
      let pct = 0;
      clearInterval(scanTimer);
      scanTimer = setInterval(() => {
        pct += 7; traffic.requests += 3; traffic.bytes += 90000;
        if (pct >= 100) { clearInterval(scanTimer); emit('scan', { running: false, tab: args.tab, count: libs[args.tab].length, new: 2, cancelled: false, error: null }); emit('library', { tab: args.tab, ready: true }); }
        else emit('scan', { running: true, tab: args.tab, pct, text: pct < 30 ? 'Reading the library...' : pct < 80 ? `Details ${Math.round(pct * 1.2)} of 120...` : 'Saving...' });
      }, 250);
      return true;
    }
    case 'scan.cancel': clearInterval(scanTimer); later(100, () => emit('scan', { running: false, tab: 'movies', count: 0, new: 0, cancelled: true, error: null })); return true;
    case 'series.open': {
      const eps = libs.tv.filter((r) => r.Show === args.show);
      if (!eps.length) throw new Error('No such show');
      const hue = (args.show.length * 47) % 360;
      const still = (t, k) => poster(t, (hue + k * 13) % 360).replace('width="240" height="360"', 'width="400" height="225" viewBox="0 0 240 135" preserveAspectRatio="xMidYMid slice"');
      const seasons = [...new Set(eps.map((e) => e.Season))].sort((a, b) => a - b);
      return { key: '9', title: args.show, year: eps[0].Year, summary: 'A made-up show for the browser preview: a group of friends run a bar badly, for years.', studio: eps[0].Studio, rated: 'TV-MA', rating: '8.4',
        genres: ['Comedy'], firstAired: eps[0].ReleaseDate, poster: '', fetchedAt: '2026-11-08 23:00',
        seasons: seasons.map((n) => ({ key: 's' + n, index: n, title: `Season ${n}`, episodes: eps.filter((e) => e.Season === n).length, watched: eps.filter((e) => e.Season === n && e.ViewCount).length, poster: poster(`${args.show} S${n}`, (hue + n * 40) % 360) })),
        episodes: eps.map((e) => ({ key: e.Rid, season: e.Season, index: e.Episode, title: `Chapter ${e.Episode}`, summary: 'Something happens.', aired: e.ReleaseDate, minutes: Math.round(e.RuntimeMin), watched: !!e.ViewCount, progress: e.ViewCount ? 0 : (e.Episode === 4 ? 40 : 0), thumb: still(`S${e.Season}E${e.Episode}`, e.Episode) })),
        cast: ['Alex Hale', 'Sam Brandt', 'Jordan Pike', 'Robin Vale', 'Casey Moor', 'Drew Lin'].map((n, i) => ({ name: n, role: ['Charlie', 'Mac', 'Dee', 'Dennis', 'Frank', 'The Waitress'][i], photo: poster(n.split(' ')[0], (hue + i * 50) % 360) })),
        related: libs.tv.filter((r) => r.Show !== args.show && r.Episode === 1 && r.Season === 1).slice(0, 8).map((r, i) => ({ key: 'r' + i, title: r.Show, year: r.Year, seasons: 2 + i, unwatched: i * 7, poster: r.Poster })) };
    }
    case 'doctor.status': return { running: false, next: '2026-11-15T03:00:00', unseen: false, last: doctorReport ? doctorSum() : null, checks: [] };
    case 'doctor.run': {
      emit('doctor', { running: true, text: 'Starting the check-up...' });
      setTimeout(() => { doctorReport = mockDoctorReport(); emit('doctor', { running: false, done: true, error: null, cancelled: false, summary: doctorSum() }); }, 900);
      return true;
    }
    case 'doctor.report': return doctorReport;
    case 'doctor.seen': return true;
    case 'image.data': return null;
    case 'shows.status': return Object.fromEntries([...new Set(libs.tv.map((r) => r.Show))].map((n, i) => [n, { state: i % 3 ? 'Ongoing' : 'Ended', tmdb: i % 3 ? 'Returning Series' : 'Ended' }]));
    case 'keys.get': case 'keys.set': return { tmdb: true, omdb: false };
    case 'tools.start': {
      let pct = 0; const t = setInterval(() => { pct += 25; if (pct < 100) emit('tool', { kind: args.kind, tab: args.tab, running: true, pct, text: 'Working on it...' });
        else { clearInterval(t); emit('tool', { kind: args.kind, tab: args.tab, running: false, error: null, summary: args.kind === 'fel' ? 'Checked 3: 2 FEL, 1 MEL, 0 could not tell.' : `${(args.rids || []).length || 'All'} titles saved.`, path: /csv|html/.test(args.kind) ? `C:\\Users\\you\\Documents\\Modern Media Library Manager\\${args.name}.${args.kind}` : '', cancelled: false }); } }, 200);
      return true;
    }
    case 'tools.cancel': case 'folder.show': return true;
    case 'dashboards.get': return dashData;
    case 'dashboards.save': dashData = args.data; return dashData;
    case 'collections.get': return collections;
    case 'collections.save': collections = args.collections; return collections;
    case 'summary.get': return { title: 'Recently added', items: [], updatedAt: null };
    case 'traffic.get': return { ...traffic, stopped: halted, uptimeSec: Math.round(performance.now() / 1000) };
    case 'traffic.stop': halted = true; clearInterval(scanTimer); emit('traffic', { stopped: true }); return true;
    case 'traffic.resume': halted = false; emit('traffic', { stopped: false }); return true;
    case 'update.check': later(600, () => emit('update', { running: false, action: 'Check', result: { status: 'current', current: '0.5.0', latest: '0.5.0' } })); return true;
    case 'update.stage': case 'update.stagezip': later(600, () => emit('update', { running: false, action: 'Stage', result: { status: 'error', error: 'The browser preview cannot install updates.' } })); return true;
    case 'update.cancel': case 'update.apply': return true;
    case 'open.url': console.log('open.url', args.url); return true;
    case 'picture.save': return `Pictures\\Modern Media Library Manager\\${args.name}.png`;
    default: throw new Error(`unknown command: ${cmd}`);
  }
}
