// The search box. Three kinds of words, freely mixed:
//   1. Field searches, as in the window app:  genre:Horror  year:1980-1989  rating:>=7.5  res:4k  studio:"A24"
//      Also  rating>8  year<2000  (no colon),  -genre:horror  (leave out),  genre:action|comedy  (either).
//   2. Everyday phrases:  90s sitcoms,  dolby vision 4k,  atmos,  short comedies,  highly rated thrillers from the 80s,
//      recently added,  certified fresh,  unwatched,  before 2000 ...
//   3. Anything else is plain text, found in the title, show, genre, cast, studio, director, year or collection.
// parse() returns the tests plus a readable list of what it understood (shown as chips under the title).
import { num } from './common.js';
import { colLabel } from './views/library.js';

// Short names for fields (case does not matter; any field name works too).
export const ALIASES = {
  res: 'ResolutionClass', resolution: 'ResolutionClass', genre: 'Genre', genres: 'Genre', year: 'Year', rating: 'Rating', imdb: 'Rating',
  rt: 'RTCritic', critics: 'RTCritic', tomatometer: 'RTCritic', audience: 'RTAudience', mc: 'Metascore', metacritic: 'Metascore', metascore: 'Metascore',
  studio: 'Studio', cast: 'Cast', actor: 'Cast', director: 'Director', hdr: 'HDRType', dv: 'DVProfile', layer: 'DVLayer', codec: 'VideoCodec',
  audio: 'AudioFormat', atmos: 'ObjectAudio', channels: 'AudioLayout', lang: 'AudioLanguages', language: 'AudioLanguages', subs: 'SubtitleLanguages',
  size: 'FileSizeGB', gb: 'FileSizeGB', runtime: 'RuntimeMin', minutes: 'RuntimeMin', length: 'RuntimeMin', show: 'Show', season: 'Season', episode: 'Episode',
  rated: 'MPAARating', mpaa: 'MPAARating', source: 'Source', container: 'Container', added: 'Added', country: 'Country', title: 'Title', bitrate: 'VideoBitRateMbps',
  mbps: 'VideoBitRateMbps', fps: 'FrameRate', box: 'BoxOfficeWorldwide', boxoffice: 'BoxOfficeWorldwide', domestic: 'BoxOfficeDomestic', collection: '_collection',
  watched: 'ViewCount', plays: 'ViewCount',
};
const NUMERIC = new Set(['int', 'double', 'long', 'bool']);

const lc = (x) => String(x ?? '').toLowerCase();
const hasGenre = (g) => (r) => r._genres.some((x) => lc(x).includes(g));
const yearIn = (a, b) => (r) => r.Year >= a && r.Year <= b;
const thisYear = new Date().getFullYear();
const daysAgo = (d) => { const t = new Date(Date.now() - d * 864e5); return t.toISOString().slice(0, 10); };

// Everyday words and phrases. Longest first, so "dolby vision" wins over "vision". Each: [words, label, test, tab?]
const G = (g, label) => [label, hasGenre(g)];
const PHRASES = [
  ['romantic comedies|romantic comedy|romcoms|romcom|rom-coms|rom-com', 'Romance + Comedy', (r) => hasGenre('romance')(r) && hasGenre('comedy')(r)],
  ['sitcoms|sitcom', 'Comedy series', hasGenre('comedy'), 'tv'],
  ['cartoons|cartoon|animated|anime', ...G('animation', 'Animation')],
  ['science fiction|sci-fi|scifi|sci fi', ...G('science fiction', 'Science Fiction')],
  ['documentaries|documentary|docs|docuseries', ...G('documentary', 'Documentary')],
  ['comedies|comedy|funny', ...G('comedy', 'Comedy')], ['dramas|drama', ...G('drama', 'Drama')], ['thrillers|thriller', ...G('thriller', 'Thriller')],
  ['horror|scary', ...G('horror', 'Horror')], ['westerns|western', ...G('western', 'Western')], ['musicals|musical', ...G('music', 'Music')],
  ['mysteries|mystery|whodunit|whodunnit', ...G('mystery', 'Mystery')], ['crime', ...G('crime', 'Crime')], ['fantasy', ...G('fantasy', 'Fantasy')],
  ['adventures|adventure', ...G('adventure', 'Adventure')], ['action', ...G('action', 'Action')], ['war', ...G('war', 'War')],
  ['romance|romantic', ...G('romance', 'Romance')], ['family|kids|children', ...G('family', 'Family')], ['history|historical', ...G('history', 'History')],
  ['biopics|biopic|biography', ...G('biography', 'Biography')], ['sports|sport', ...G('sport', 'Sport')],
  ['4k|uhd|2160p', '4K', (r) => r.ResolutionClass === '4K'], ['1080p|full hd|fhd', '1080p', (r) => r.ResolutionClass === '1080p'],
  ['720p', '720p', (r) => r.ResolutionClass === '720p'], ['sd|dvd quality', 'SD', (r) => r.ResolutionClass === 'SD'],
  ['dolby vision|dovi', 'Dolby Vision', (r) => lc(r.HDRType).includes('dolby vision')], ['hdr10+|hdr10 plus', 'HDR10+', (r) => lc(r.HDRType).includes('hdr10+') || lc(r.HDRStack).includes('hdr10+')],
  ['hdr', 'HDR (any)', (r) => !!r.HDRType && r.HDRType !== 'SDR'], ['sdr', 'SDR', (r) => !r.HDRType || r.HDRType === 'SDR'],
  ['fel', 'DV FEL', (r) => r.DVLayer === 'FEL'], ['mel', 'DV MEL', (r) => r.DVLayer === 'MEL'],
  ['atmos', 'Dolby Atmos', (r) => lc(r.ObjectAudio).includes('atmos')], ['dts:x|dtsx', 'DTS:X', (r) => lc(r.ObjectAudio).includes('dts:x')],
  ['truehd', 'TrueHD', (r) => lc(r.AudioFormat).includes('truehd')], ['dts-hd|dts hd', 'DTS-HD', (r) => lc(r.AudioFormat).includes('dts-hd')],
  ['lossless audio|lossless', 'Lossless audio', (r) => /truehd|dts-hd ma|flac|pcm/.test(lc(r.AudioFormat))],
  ['hevc|h265|h.265|x265', 'HEVC', (r) => lc(r.VideoCodec).includes('hevc')], ['av1', 'AV1', (r) => lc(r.VideoCodec) === 'av1'], ['h264|h.264|x264|avc', 'AVC', (r) => lc(r.VideoCodec) === 'avc'],
  ['remux|remuxes', 'Remux', (r) => /remux/.test(lc(r.Source) + ' ' + lc(r.FileName))],
  ['highly rated|top rated|best rated|best|great', 'Highly rated', (r) => num(r.Rating) >= 8 || num(r.RTCritic) >= 90 || num(r.Metascore) >= 80],
  ['certified fresh', 'RT 75%+', (r) => num(r.RTCritic) >= 75], ['fresh', 'RT 60%+', (r) => num(r.RTCritic) >= 60], ['rotten', 'RT under 60%', (r) => num(r.RTCritic) > 0 && num(r.RTCritic) < 60],
  ['acclaimed|critically acclaimed|must see|must-see', 'Metacritic 75+', (r) => num(r.Metascore) >= 75],
  ['poorly rated|bad|worst', 'Low rated', (r) => (num(r.Rating) > 0 && num(r.Rating) < 5.5) || (num(r.RTCritic) > 0 && num(r.RTCritic) < 40)],
  ['blockbusters|blockbuster|box office hits|hits', 'Box office $300M+', (r) => num(r.BoxOfficeWorldwide) >= 3e8],
  ['long|epic|epics', 'Over 2h30', (r) => num(r.RuntimeMin) >= 150], ['short', 'Under 1h30', (r) => num(r.RuntimeMin) > 0 && num(r.RuntimeMin) < 90],
  ['recently added|just added|new additions', 'Added in the last 90 days', (r) => String(r.Added || '') >= daysAgo(90)],
  ['new releases|new release|new|recent|latest', `${thisYear - 1} or later`, (r) => r.Year >= thisYear - 1],
  ['classics|classic|old', 'Before 1980', (r) => r.Year > 0 && r.Year < 1980],
  ['unwatched|not watched|unseen|haven\'t seen', 'Unwatched', (r) => num(r.ViewCount) === 0],
  ['watched|seen', 'Watched', (r) => num(r.ViewCount) > 0],
  ['no poster|missing poster|missing posters', 'No poster', (r) => !r.Poster], ['no rating|unrated', 'No rating', (r) => !num(r.Rating) && !num(r.RTCritic) && !num(r.Metascore)],
  ['big files|large files|huge', 'Over 40 GB', (r) => num(r.FileSizeGB) >= 40],
  ['tv shows|tv series|tv|shows|series|episodes', 'TV', () => true, 'tv'], ['movies|movie|films|film', 'Movies', () => true, 'movies'],
].map(([w, label, test, tab]) => ({ words: w.split('|').map((x) => x.split(' ')), label, test, tab }));

const DECADE_WORDS = { twenties: 1920, thirties: 1930, forties: 1940, fifties: 1950, sixties: 1960, seventies: 1970, eighties: 1980, nineties: 1990, noughties: 2000, aughts: 2000 };
const STOP = new Set(['the', 'a', 'an', 'of', 'from', 'in', 'with', 'and', 'era', 'made', 'that', 'are', 'is', 'show', 'me', 'all', 'my', 'some', 'good', 'released', 'to', 'for', 'on']);

// Tokens: quoted text stays together; field:"two words" too.
function tokenize(q) {
  const out = [];
  const re = /(-?[A-Za-z_]+\s*(?::|>=|<=|>|<|=)\s*"[^"]*")|("[^"]*")|(\S+)/g;
  let m;
  while ((m = re.exec(q))) out.push(m[0]);
  return out;
}
function decade(word) {
  let m = /^(?:(19|20)?(\d)0)'?s$/.exec(word);
  if (m) { const c = m[1] ? +m[1] * 100 : (+m[2] >= 3 ? 1900 : 2000); return c + +m[2] * 10; }
  return DECADE_WORDS[word] || 0;
}
// One field test: text contains (a|b = either), numbers take 7.5, >=7.5, <2000, 1980-1989
function fieldTest(field, op, value, L) {
  const f = L.byName.get(field);
  const isNum = f ? NUMERIC.has(f.t) : field === 'ViewCount';
  const v = value.replace(/^"|"$/g, '').trim();
  if (!isNum) {
    const alts = v.toLowerCase().split('|').map((x) => x.trim()).filter(Boolean);
    if (op && op !== ':' && op !== '=') return null;
    return (r) => alts.some((a) => lc(r[field]).includes(a));
  }
  let m = /^(-?\d+(?:\.\d+)?)\s*-\s*(-?\d+(?:\.\d+)?)$/.exec(v);
  if (m && (op === ':' || op === '=')) { let a = +m[1], b = +m[2]; if (a > b) [a, b] = [b, a]; return (r) => num(r[field]) >= a && num(r[field]) <= b; }
  m = /^(>=|<=|>|<|=)?\s*(-?\d+(?:\.\d+)?)([kmb])?$/i.exec(v);
  if (!m) return null;
  const o = (op === ':' || op === '=') ? (m[1] || '=') : op;
  const n = +m[2] * ({ k: 1e3, m: 1e6, b: 1e9 }[lc(m[3])] || 1);
  return { '=': (r) => num(r[field]) === n, '>': (r) => num(r[field]) > n, '<': (r) => num(r[field]) < n, '>=': (r) => num(r[field]) >= n, '<=': (r) => num(r[field]) <= n }[o];
}
function resolveField(name, L) {
  const k = name.toLowerCase();
  if (ALIASES[k]) return ALIASES[k];
  for (const f of L.fields) if (f.n.toLowerCase() === k) return f.n;
  return null;
}

/* parse(query, library, collections) -> { tests: [fn], chips: [text], tab: 'movies'|'tv'|'' }
   A query that reads as plain text and finds something ("new girl", "alien", "comedy") stays plain text, so a title is
   never turned into a filter; the phrase reader steps in when plain text finds nothing ("90s sitcoms", "4k atmos"). */
export function parse(query, L, collections = []) {
  const q = String(query || '').trim();
  const res = { tests: [], chips: [], tab: '', empty: !q };
  if (!q) return res;
  const toks = tokenize(q);
  if (!toks.some((t) => /^-?[A-Za-z_]+\s*(:|>=|<=|>|<|=)/.test(t) || /^".*"$/.test(t))) {
    const plain = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (L.rows.some((r) => plain.every((t) => r._search.includes(t)))) {
      res.tests.push((r) => plain.every((t) => r._search.includes(t)));
      res.chips.push(`\u201c${q}\u201d`);
      return res;
    }
  }
  const words = [];
  // 1. field terms
  for (const t of toks) {
    const m = /^(-?)([A-Za-z_]+)\s*(:|>=|<=|>|<|=)\s*(.+)$/.exec(t);
    const field = m && resolveField(m[2], L);
    if (m && (field || m[2].toLowerCase() === 'collection')) {
      let test;
      if (field === '_collection' || m[2].toLowerCase() === 'collection') {
        const name = m[4].replace(/^"|"$/g, '').toLowerCase();
        const cs = collections.filter((c) => c.name.toLowerCase().includes(name));
        test = (r) => cs.some((c) => c.has(r));
      } else test = fieldTest(field, m[3], m[4], L);
      if (test) {
        res.tests.push(m[1] ? (r) => !test(r) : test);
        res.chips.push(`${m[1] ? 'not ' : ''}${field === '_collection' || !field ? 'Collection' : colLabel(field)}${m[3] === ':' ? ': ' : ' ' + m[3] + ' '}${m[4].replace(/^"|"$/g, '')}`);
        continue;
      }
    }
    words.push(t);
  }
  // 2. phrases, decades, years, before/after
  const w = words.map((x) => x.toLowerCase());
  const used = new Array(w.length).fill(false);
  for (let i = 0; i < w.length; i++) {
    if (used[i]) continue;
    const neg = w[i] === 'not' || w[i] === 'no' || w[i] === 'without';
    const at = neg ? i + 1 : i;
    // phrases (longest match first)
    let hit = null, len = 0;
    for (const p of PHRASES) for (const ph of p.words) {
      if (ph.length <= len) continue;
      if (ph.every((x, k) => w[at + k] === x)) { hit = p; len = ph.length; }
    }
    if (hit && !(neg && hit.tab)) {
      for (let k = i; k < at + len; k++) used[k] = true;
      if (hit.tab && !neg) res.tab = hit.tab;
      if (!(hit.tab && hit.label.match(/^(TV|Movies)$/))) { res.tests.push(neg ? (r) => !hit.test(r) : hit.test); res.chips.push((neg ? 'not ' : '') + hit.label); }
      else res.chips.push(hit.label);
      continue;
    }
    const d = decade(w[i]);
    if (d) { used[i] = true; res.tests.push(yearIn(d, d + 9)); res.chips.push(`${d}s`); continue; }
    if ((w[i] === 'before' || w[i] === 'after' || w[i] === 'since') && /^\d{4}$/.test(w[i + 1] || '')) {
      const y = +w[i + 1]; used[i] = used[i + 1] = true;
      res.tests.push(w[i] === 'before' ? (r) => r.Year > 0 && r.Year < y : (r) => r.Year >= (w[i] === 'after' ? y + 1 : y));
      res.chips.push(`${w[i]} ${y}`); continue;
    }
    if (/^(19|20)\d{2}$/.test(w[i]) && !/^(19|20)\d{2}$/.test(w[i + 1] || '')) {
      // a year on its own: that year, or a title with the number in it ("2001", "1917")
      const y = +w[i]; used[i] = true;
      res.tests.push((r) => r.Year === y || r._search.includes(w[i])); res.chips.push(`${y}`); continue;
    }
    if (STOP.has(w[i]) && w.length > 1) { used[i] = true; continue; }
  }
  // 3. what is left is plain text (every word must appear somewhere)
  const rest = w.filter((x, i) => !used[i]).map((x) => x.replace(/^"|"$/g, '')).filter(Boolean);
  if (rest.length) {
    const colls = collections.filter((c) => rest.join(' ').includes(c.name.toLowerCase()));
    if (colls.length && colls.some((c) => c.name.toLowerCase() === rest.join(' '))) {
      res.tests.push((r) => colls.some((c) => c.has(r))); res.chips.push(`Collection: ${colls.map((c) => c.name).join(', ')}`);
    } else {
      res.tests.push((r) => rest.every((t) => r._search.includes(t) || colls.some((c) => c.has(r) && c.name.toLowerCase().includes(t))));
      res.chips.push(`“${rest.join(' ')}”`);
    }
  }
  return res;
}
export function filterRows(rows, parsed) {
  if (!parsed || !parsed.tests.length) return rows;
  return rows.filter((r) => parsed.tests.every((t) => t(r)));
}
