// The Versus skull bar: each side's bar runs from the middle out to its score, drawn as that side's elemental theme
// (fire, water, spectral, lightning, nature), with one flaming skull riding its tip, facing outward. Eight skull looks
// and ten glowing tattoos (Settings > Versus). Glows are pre-drawn once and stamped, the number of sparks is capped,
// and drawing stops when the bar leaves the page or the window is hidden.
import { tune, mult } from './fxtune.js';

// palettes per theme: hottest to coolest
export const PAL = {
  fire: ['#fff6cf', '#ffc04a', '#ff5a1f', '#7a1200'],
  water: ['#e9fbff', '#86d6ff', '#2a86ff', '#0a2a66'],
  specter: ['#eaffd9', '#7dff4a', '#2bd61a', '#0b4d12'],
  blood: ['#ffd6d6', '#ff3b4a', '#b0001a', '#3a0006'],
  lightning: ['#ffffff', '#d4e6ff', '#7aa8ff', '#2a3a8a'],
  nature: ['#fff8d0', '#cfdc6e', '#7f952c', '#3a3a10'],
};
export const SKULL_STYLES = [
  ['bone', 'Bone'], ['char', 'Charred'], ['engulfed', 'Engulfed'], ['boneblaze', 'Bone ablaze'],
  ['glassdark', 'Cracked glass, dark'], ['glasslight', 'Cracked glass, light'], ['sugarlight', 'Day of the Dead, light'], ['sugardark', 'Day of the Dead, dark'],
];
const FRONT = { char: 0.18, engulfed: 0.5, boneblaze: 0.45 };          // flames drawn in front of the skull
const ENGULF = { engulfed: 1, boneblaze: 1 };
const RATE = { char: 1.1, engulfed: 1.5, boneblaze: 1.5 };

const GLASS_CRACKS = [
  'M66,28 L58,12 M66,28 L80,13 M66,28 L95,33 M66,28 L83,48 M66,28 L60,47 M66,28 L42,36 M66,28 L42,18 M66,28 L70,8 M66,28 L50,40',
  'M61,20 L72,19 L78,27 L74,38 L62,40 L55,31 Z M56,11 L76,9 L88,20 L87,40 L71,51 L52,45 L46,26 Z',
  'M52,15 L47,25 L50,30 M88,24 L90,40 M47,41 L36,50 M72,44 L76,56',
  'M36,46 L22,40 M36,46 L24,55 M36,46 L30,63 M36,46 L45,58 M36,46 L48,48 M36,46 L44,37 M36,46 L28,32 M31,41 L40,40 L43,50 L34,53 L28,48 Z',
  'M76,60 L66,56 M76,60 L70,69 M76,60 L84,67 M76,60 L87,55 M76,60 L80,51 M72,57 L80,56 L81,64 L73,65 Z',
  'M58,12 L54,5 M80,13 L86,8 L94,16 M95,33 L102,37 M83,48 L92,50 L96,58 M60,47 L58,58 L50,66 L42,70 M42,36 L30,30 L22,36 M42,18 L32,20 L24,28 L18,40 L20,52',
  'M70,8 L66,4 M50,40 L46,46 M28,32 L26,24 M22,40 L16,44 M24,55 L18,58 M30,63 L34,68 M45,58 L52,62 M84,67 L90,72 M87,55 L94,52 M99,22 L95,33 M36,14 L42,18 M46,8 L52,15 M78,30 L86,30 M60,34 L54,36',
  'M64,79 L72,86 L80,88 M86,86 L94,90 M70,93 L74,88 M58,82 L62,88 M96,85 L100,90 M66,74 L60,70',
].join(' ');

// Day of the Dead decorations (skull space, facing right); fixed festival colours, glowing on the dark skull
function sugarDeco(dark, uid) {
  const C = { pink: '#ff4fa3', orange: '#ff9f1c', yellow: '#ffd23f', teal: '#2ec4b6', purple: '#9b5de5', blue: '#3a86ff' };
  const petals = (cx, cy, r, n, rx, ry, cols) => Array.from({ length: n }, (_, i) => { const a = i * 360 / n, x = cx + r * Math.cos(a * Math.PI / 180), y = cy + r * Math.sin(a * Math.PI / 180); return `<ellipse cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" rx="${rx}" ry="${ry}" transform="rotate(${a} ${x.toFixed(1)} ${y.toFixed(1)})" fill="${cols[i % cols.length]}"/>`; }).join('');
  const teeth = !dark ? '' : [80, 84, 88, 92, 96].map((x) => `<rect x="${x}" y="74.5" width="3.6" height="6" rx="1" fill="#f4ecdc" stroke="${C.teal}" stroke-width=".7"/><rect x="${x}" y="82.6" width="3.6" height="5" rx="1" fill="#f4ecdc" stroke="${C.teal}" stroke-width=".7"/>`).join('');
  const art = `
    ${teeth}
    ${petals(88, 49, 12.6, 12, 3.2, 1.8, [C.pink, C.orange])}
    ${petals(88, 49, 16.8, 18, .9, .9, [C.teal])}
    ${petals(58, 25, 6.2, 12, 3.2, 1.7, [C.orange, C.yellow])}
    ${petals(58, 25, 3.2, 8, 1.6, 1, [C.yellow])}
    <circle cx="58" cy="25" r="2.2" fill="${C.pink}"/>
    <path d="M44,17 C48,13 52,14 53,18 M72,15 C76,12 80,13 81,17" stroke="${C.teal}" stroke-width="1.2" fill="none" stroke-linecap="round"/>
    <ellipse cx="47" cy="14.5" rx="2.4" ry="1.1" transform="rotate(-30 47 14.5)" fill="${C.teal}"/><ellipse cx="78" cy="13.5" rx="2.4" ry="1.1" transform="rotate(20 78 13.5)" fill="${C.teal}"/>
    <path d="M30,50 C24,42 32,34 38,39 C42,43 37,48 34,45 C32,43 35,41 36,43" stroke="${C.purple}" stroke-width="1.4" fill="none" stroke-linecap="round"/>
    <path d="M40,58 C36,54 40,49 44,52 C46,54 43,56 42,54" stroke="${C.blue}" stroke-width="1.2" fill="none" stroke-linecap="round"/>
    <circle cx="26" cy="56" r="1.3" fill="${C.pink}"/><circle cx="31" cy="60" r="1.1" fill="${C.yellow}"/><circle cx="46" cy="44" r="1.1" fill="${C.orange}"/>
    <circle cx="70" cy="60" r="1.3" fill="${C.pink}"/><circle cx="75" cy="62.5" r="1.1" fill="${C.purple}"/><circle cx="66" cy="63" r="1" fill="${C.yellow}"/>
    <path d="M103.5,61 C101,58.6 99.5,57 101,55.6 C102,54.8 103,55.4 103.5,56.4 C104,55.4 105,54.8 106,55.6 C107.5,57 106,58.6 103.5,61 Z" fill="${C.pink}"/>
    <path d="M78,81.5 L101,81.5" stroke="${dark ? C.teal : '#3a2a20'}" stroke-width=".8"/>
    ${[80.5, 84.5, 88.5, 92.5, 96.5, 100].map((x) => `<path d="M${x},79.5 L${x},83.5" stroke="${dark ? C.teal : '#3a2a20'}" stroke-width=".7"/>`).join('')}
    <path d="M60,88 C66,92 74,93 82,92" stroke="${C.orange}" stroke-width="1" fill="none" stroke-dasharray="1.5 1.5"/>`;
  return dark ? `<g filter="url(#w${uid})" opacity=".85">${art}</g><g>${art}</g>` : `<g opacity=".95">${art}</g>`;
}

// side-profile skull facing right, 120 x 100
export function skullSVG(style, pal, uid, tat = 0, int = 50) {
  const bone = style === 'bone' || style === 'boneblaze', char = style === 'char';
  const gd = style === 'glassdark', gl = style === 'glasslight', glass = gd || gl;
  const sl = style === 'sugarlight', sd = style === 'sugardark', sugar = sl || sd;
  const darkEye = style === 'bone' || gl || sugar;   // plain dark sockets; the others burn in the theme
  const b0 = sl ? '#fbf6ee' : sd ? '#2c2733' : bone ? '#f4ecd8' : char ? '#3a332d' : gd ? '#4a5466' : gl ? '#ffffff' : '#1b1512';
  const b1 = sl ? '#e6dccd' : sd ? '#15121a' : bone ? '#c9b993' : char ? '#1e1a17' : gd ? '#161b24' : gl ? '#dbe6f1' : '#0c0908';
  const b2 = sl ? '#9a8c78' : sd ? '#050407' : bone ? '#6d5c42' : gd ? '#05070a' : gl ? '#8ea3b9' : '#050404';
  const crack = char ? pal[1] : bone ? '#5b4a35' : pal[2];
  const eye = darkEye ? (gl ? '#1a2430' : '#140e09') : pal[0];
  const fo = gd ? ' fill-opacity=".82"' : gl ? ' fill-opacity=".32"' : '';
  const mouth = !glass ? '' : `<g fill="none" stroke-linecap="round" stroke-linejoin="round">
      <path d="M78,80 L101,80 M80,83 L100,83 M52,72 C55,82 60,90 70,93 L97,94 C101,93 103,90 102,86 L100,83 M101,80 L102,75 M78,80 C74,74 66,70 58,70" stroke="${pal[2]}" stroke-width="2.4" opacity="${gd ? .7 : .4}" filter="url(#w${uid})"/>
      <path d="M78,80 L101,80 M80,83 L100,83 M52,72 C55,82 60,90 70,93 L97,94 C101,93 103,90 102,86 L100,83 M101,80 L102,75 M78,80 C74,74 66,70 58,70" stroke="${gd ? pal[1] : '#ffffff'}" stroke-width=".9"/>
    </g>`;
  const glassBits = !glass ? '' : `
    <path d="M30,24 C44,12 64,8 84,14" stroke="#fff" stroke-width="2.6" fill="none" stroke-linecap="round" opacity="${gl ? .7 : .35}" filter="url(#w${uid})"/>
    <path d="M34,22 C46,14 60,11 72,12" stroke="#fff" stroke-width="1" fill="none" stroke-linecap="round" opacity="${gl ? .9 : .5}"/>
    <path d="M24,58 C22,50 22,44 25,38" stroke="#fff" stroke-width="1.4" fill="none" stroke-linecap="round" opacity="${gl ? .55 : .25}"/>
    <clipPath id="k${uid}"><use href="#c${uid}"/><path d="M52,72 C55,82 60,90 70,93 L97,94 C101,93 103,90 102,86 L100,83 L80,83 C73,83 67,80 62,76 Z"/></clipPath>
    <g fill="none" stroke-linecap="round" stroke-linejoin="round" clip-path="url(#k${uid})">
      <path d="${GLASS_CRACKS}" stroke="${pal[2]}" stroke-width="2.6" opacity="${gd ? .8 : .45}" filter="url(#w${uid})"/>
      <path d="${GLASS_CRACKS}" stroke="${gd ? pal[1] : '#ffffff'}" stroke-width=".7"/>
    </g>`;
  return `<svg viewBox="0 0 120 100" aria-hidden="true">
  <defs>
    <radialGradient id="g${uid}" cx="58%" cy="34%" r="70%"><stop offset="0" stop-color="${b0}"/><stop offset=".55" stop-color="${b1}"/><stop offset="1" stop-color="${b2}"/></radialGradient>
    <radialGradient id="e${uid}" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="${eye}"/><stop offset=".55" stop-color="${darkEye ? '#0b0806' : pal[1]}"/><stop offset="1" stop-color="${darkEye ? '#2a2016' : pal[3]}"/></radialGradient>
    <linearGradient id="r${uid}" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="${pal[2]}" stop-opacity="${bone ? .45 : .35}"/><stop offset=".6" stop-color="${pal[2]}" stop-opacity="0"/></linearGradient>
    <filter id="n${uid}"><feTurbulence type="fractalNoise" baseFrequency="1.6" numOctaves="2" seed="4"/><feColorMatrix values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 .35 0"/><feComposite in2="SourceGraphic" operator="in"/></filter>
    <filter id="w${uid}" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="2.2"/></filter>
  </defs>
  <g>
    <path id="c${uid}" fill="url(#g${uid})"${fo} stroke="${b2}" stroke-width="1" d="M20,60 C10,44 14,20 40,11 C62,4 90,10 101,30 C104,36 106,40 104,44 L100,47 C104,52 108,58 107,63 L102,64 C104,68 104,72 102,75 L101,80 L78,80 C74,74 66,70 58,70 C52,72 48,76 46,80 C40,80 36,74 34,70 C28,68 22,66 20,60 Z"/>
    <path fill="url(#g${uid})"${fo} stroke="${b2}" stroke-width="1" d="M52,72 C55,82 60,90 70,93 L97,94 C101,93 103,90 102,86 L100,83 L80,83 C73,83 67,80 62,76 Z"/>
    <g fill="${bone ? '#efe4c8' : b1}"${fo} stroke="${glass ? (gd ? pal[1] : '#ffffff') : b2}" stroke-width="${glass ? .75 : .6}">
      ${[80,84,88,92,96].map((x) => `<rect x="${x}" y="74.5" width="3.6" height="6" rx="1"/>`).join('')}
      ${[80,84,88,92,96].map((x) => `<rect x="${x}" y="82.6" width="3.6" height="5" rx="1"/>`).join('')}
    </g>
    ${glass || sugar ? '' : `<g filter="url(#n${uid})"><use href="#c${uid}"/></g>`}
    <path d="M58,70 C66,64 78,64 86,62" stroke="${b2}" stroke-width="1.6" fill="none" opacity=".7"/>
    ${glass ? glassBits : ''}
    <path ${glass || sugar ? 'display="none" ' : ''}d="M40,28 C56,20 76,20 92,30" stroke="${crack}" stroke-width="${char ? 1.2 : .7}" fill="none" opacity="${char ? .95 : .45}" ${char ? `filter="url(#w${uid})"` : ''}/>
    ${char ? `<path d="M40,28 C56,20 76,20 92,30 M60,14 L64,24 L58,32 M30,40 L40,44 L36,54 M74,36 L70,46" stroke="${pal[1]}" stroke-width=".9" fill="none"/>` : glass || sugar ? '' : `<path d="M60,14 L63,22 L59,28" stroke="${crack}" stroke-width=".6" fill="none" opacity=".5"/>`}
    <ellipse cx="55" cy="64" rx="3" ry="2.6" fill="#0a0806"/>
    ${!darkEye ? `<ellipse cx="88" cy="49" rx="12" ry="11" fill="${pal[2]}" opacity=".55" filter="url(#w${uid})"/>` : ''}
    <ellipse cx="88" cy="49" rx="9" ry="8.2" fill="url(#e${uid})"/>
    <path d="M101,55 L106,62 L100,63 C99,60 99,57 101,55 Z" fill="${darkEye ? '#120c08' : pal[3]}"${fo}/>
    <path d="M20,60 C28,68 40,72 58,70 C70,70 80,74 101,80 L101,82 C80,84 60,84 40,78 Z" fill="url(#r${uid})"/>
    ${mouth}
    ${sugar ? sugarDeco(sd, uid) : ''}
    ${tattoo(pal, uid, tat, int)}
  </g></svg>`;
}

// tattoos on the side of the cranium, drawn in a 30 x 30 box and glowing in the theme
export const TATTOOS = [
  ['None', []],
  ['Crossed swords', [{ d: 'M5,25 L26,4 M25,25 L4,4' }, { d: 'M6,19 L11,24 M19,24 L24,19', w: 2 }, { d: 'M2.5,27.5 a1.6,1.6 0 1,0 0.1,0 M27.5,27.5 a1.6,1.6 0 1,0 0.1,0' }]],
  ['Lightning bolt', [{ d: 'M17,1 L6,17 L14,17 L11,29 L24,11 L16,11 Z', fill: true }]],
  ['Pentagram', [{ d: 'M2,15 a13,13 0 1,0 26,0 a13,13 0 1,0 -26,0' }, { d: 'M15,3 L22.1,24.7 L3.6,11.3 L26.4,11.3 L7.9,24.7 Z' }]],
  ['Bullet hole', [{ d: 'M15,11 L14,3 M19,14 L28,10 M18,19 L25,27 M12,18 L5,25 M11,13 L2,12' }, { d: 'M11,15 a4,4 0 1,0 8,0 a4,4 0 1,0 -8,0', hole: true }]],
  ['Angel wings', [{ d: 'M15,17 C10,8 4,6 1,8 C4,11 5,13 3,15 C7,16 8,18 6,20 C10,20 13,19 15,17 Z M15,17 C20,8 26,6 29,8 C26,11 25,13 27,15 C23,16 22,18 24,20 C20,20 17,19 15,17 Z', fill: true }, { d: 'M10,5 a5,1.6 0 1,0 10,0 a5,1.6 0 1,0 -10,0' }]],
  ['Demon horns', [{ d: 'M8,27 C3,19 3,8 10,2 C9,10 11,18 14,25 Z M22,27 C27,19 27,8 20,2 C21,10 19,18 16,25 Z', fill: true }]],
  ['Fissures', [{ d: 'M3,5 L9,11 L8,17 L14,21 L13,28 M9,11 L16,9 L20,3 M14,21 L21,19 L27,24 M16,9 L18,14 M8,17 L3,20' }]],
  ['Holy cross', [{ d: 'M15,2 L15,28 M7,10 L23,10', w: 3.2 }]],
  ['Vampire fangs', [{ d: 'M3,8 C9,14 21,14 27,8' }, { d: 'M8,11 L10.5,25 L13.5,13 Z M16.5,13 L19.5,25 L22,11 Z', fill: true }]],
  ['Blood drop', [{ d: 'M15,2 C15,2 6,14 6,20 C6,25 10,28 15,28 C20,28 24,25 24,20 C24,14 15,2 15,2 Z', fill: true }]],
];
function tattoo(pal, uid, tat, int) {
  const parts = (TATTOOS[tat] || TATTOOS[0])[1]; if (!parts.length) return '';
  const a = Math.min(1, 0.55 + 0.45 * int / 50);
  const glow = parts.map((p) => `<path d="${p.d}" fill="${p.fill ? pal[2] : 'none'}" stroke="${pal[2]}" stroke-width="${(p.w || 1.4) + 2.4}" stroke-linejoin="round" stroke-linecap="round"/>`).join('');
  const ink = parts.map((p) => `<path d="${p.d}" fill="${p.hole ? '#050404' : p.fill ? pal[1] : 'none'}" fill-opacity="${p.fill ? .9 : 1}" stroke="${p.hole ? pal[1] : pal[0]}" stroke-width="${p.w || 1.4}" stroke-linejoin="round" stroke-linecap="round"/>`).join('');
  return `<g transform="translate(43,17) scale(1.05)"><g filter="url(#w${uid})" opacity="${(0.75 * a).toFixed(2)}">${glow}</g><g opacity="${a.toFixed(2)}">${ink}</g></g>`;
}

// ---- drawing helpers --------------------------------------------------------------------------------------------------
let sprite = null;
const tints = new Map();
function glowImg(col) {
  if (!sprite) {
    sprite = document.createElement('canvas'); sprite.width = sprite.height = 64;
    const g = sprite.getContext('2d'), gr = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(0.45, 'rgba(255,255,255,.35)'); gr.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = gr; g.fillRect(0, 0, 64, 64);
  }
  let c = tints.get(col);
  if (!c) {
    c = document.createElement('canvas'); c.width = c.height = 64; const g = c.getContext('2d');
    g.drawImage(sprite, 0, 0); g.globalCompositeOperation = 'source-in'; g.fillStyle = col; g.fillRect(0, 0, 64, 64);
    tints.set(col, c);
  }
  return c;
}
function glow(g, x, y, r, col, a) { if (a <= 0.004 || r <= 0.3) return; g.globalAlpha = Math.min(1, a); g.drawImage(glowImg(col), x - r, y - r, r * 2, r * 2); }
const MAX_PARTS = 900;
const hexA = (a) => Math.round(Math.max(0, Math.min(1, a)) * 255).toString(16).padStart(2, '0');

// a palette for any side: the theme's own, or one built from the side's colour (poster colours, off)
function palFor(fx, tone) {
  if (PAL[fx]) return PAL[fx];
  const c = /^#[0-9a-f]{6}$/i.test(tone) ? tone : '#8ea4ff';
  return ['#ffffff', c, c, '#1a1a22'];
}

let uidN = 0;
// l, r: wins on each side; stops: how many rows are scored; opts: { style, tattoo, radius } from settings
export function skullBar(l, r, stops, opts = {}) {
  const t = tune();
  if (!t.skulls.on && !t.bar.on) return null;
  stops = Math.max(stops, l, r, 1);
  const style = SKULL_STYLES.some((x) => x[0] === opts.style) ? opts.style : 'bone';
  const tat = Math.max(0, Math.min(10, Math.round(Number(opts.tattoo) || 0)));
  const R = mult(Number.isFinite(Number(opts.radius)) ? Number(opts.radius) : 50);
  const skS = mult(t.skulls.size), skI = mult(t.skulls.int), bS = mult(t.bar.size), bI = mult(t.bar.int);
  const skW = 48 * skS, skH = skW * 100 / 120;
  const height = Math.round(Math.max(64, skH * 0.62 + 40 * bS + 34 * R));
  const host = document.createElement('div'); host.className = 'sk-bar'; host.style.height = height + 'px';
  const back = document.createElement('canvas'), front = document.createElement('canvas');
  back.className = 'sk-cv'; front.className = 'sk-cv';
  const track = document.createElement('div'); track.className = 'sk-track';
  const mid = document.createElement('div'); mid.className = 'sk-mid';
  host.append(track, mid, back);
  const sides = [{ side: -1, n: l, key: 'l' }, { side: 1, n: r, key: 'r' }].map((s) => {
    const el = document.createElement('div'); el.className = 'sk-skull';
    if (!t.skulls.on) el.hidden = true;
    host.append(el);
    return { ...s, el, fx: '', pal: null };
  });
  host.append(front);
  const wrap = document.createElement('div'); wrap.className = 'sk-wrap'; wrap.setAttribute('role', 'img');
  wrap.setAttribute('aria-label', `Skull bar: ${l} to ${r} out of ${stops}`);
  const legend = document.createElement('div'); legend.className = 'sk-legend';
  for (const txt of [`${l} won`, `${stops} stops`, `${r} won`]) { const sp = document.createElement('span'); sp.textContent = txt; legend.append(sp); }
  wrap.append(host, legend);

  const gb = back.getContext('2d'), gf = front.getContext('2d');
  let W = 0, H = 0, dpr = 1, raf = 0, last = 0, seen = false, parts = [], fparts = [], bolts = [], clock = 0;
  const size = () => {
    W = host.clientWidth; H = host.clientHeight; dpr = Math.min(2, window.devicePixelRatio || 1);
    for (const c of [back, front]) { c.width = Math.round(W * dpr); c.height = Math.round(H * dpr); }
    gb.setTransform(dpr, 0, 0, dpr, 0, 0); gf.setTransform(dpr, 0, 0, dpr, 0, 0);
    place();
  };
  const barY = () => H * 0.64;
  const geo = (s) => {
    const k = s.n / stops, tip = W * (0.5 + s.side * k * 0.46);
    const x = s.side < 0 ? tip - skW * 0.75 : tip - skW * 0.25, y = barY() - skH * 0.56;
    return { tip, x, y, x0: Math.min(W / 2, tip), x1: Math.max(W / 2, tip) };
  };
  const place = () => { for (const s of sides) { const g = geo(s); Object.assign(s.el.style, { left: g.x + 'px', top: g.y + 'px', width: skW + 'px', height: skH + 'px' }); } };
  // which theme each side has: set on the Compare page once its poster colours are known
  const sync = () => {
    const cmp = host.closest('.cmp'); if (!cmp) return;
    const cs = getComputedStyle(cmp);
    for (const s of sides) {
      const fx = cmp.dataset['fx' + s.key] || 'poster', tone = cs.getPropertyValue(s.key === 'l' ? '--cl' : '--cr').trim() || (s.key === 'l' ? '#ff9a3c' : '#6fb7ff');
      const id = fx + tone;
      if (id === s.fx) continue;
      s.fx = id; s.theme = fx; s.pal = palFor(fx, tone);
      s.el.innerHTML = skullSVG(style, s.pal, 'k' + (uidN++), tat, t.skulls.int);
      const svg = s.el.querySelector('svg'); if (svg && s.side < 0) svg.style.transform = 'scaleX(-1)';
    }
  };
  const still = () => !!host.closest('.motion-still') || matchMedia('(prefers-reduced-motion: reduce)').matches;
  const calm = () => !!host.closest('.motion-calm');

  function drawBars(rate, dt) {
    if (!t.bar.on) return;
    const y = barY(), th = 8 * bS;
    for (const s of sides) {
      const g = geo(s), len = g.x1 - g.x0, P = s.pal; if (len < 2 || !P) continue;
      gb.globalAlpha = 1; gb.globalCompositeOperation = 'source-over';
      gb.shadowColor = P[2]; gb.shadowBlur = 8 + 16 * bI;
      const lg = gb.createLinearGradient(s.side < 0 ? g.x1 : g.x0, 0, s.side < 0 ? g.x0 : g.x1, 0);
      lg.addColorStop(0, P[3]); lg.addColorStop(0.6, P[2]); lg.addColorStop(1, P[1]);
      gb.fillStyle = lg; gb.beginPath();
      if (gb.roundRect) gb.roundRect(g.x0, y - th / 2, len, th, th / 2); else gb.rect(g.x0, y - th / 2, len, th);
      gb.fill(); gb.shadowBlur = 0;
      if (!rate) continue;
      const n = len * 0.04 * bI * rate * dt * 60, rnd = () => g.x0 + Math.random() * len, room = parts.length < MAX_PARTS;
      const th2 = s.theme;
      if (th2 === 'fire' && room) for (let i = 0; i < n * 2; i++) parts.push({ k: 'f', x: rnd(), y: y - th * 0.3, vx: (Math.random() - 0.5) * 0.4, vy: -(0.6 + Math.random() * 1.2) * bS, life: 1, decay: 0.03 + Math.random() * 0.04, r: (3 + Math.random() * 3.5) * bS, P, wob: Math.random() * 6 });
      if (th2 === 'water') {
        gb.globalCompositeOperation = 'lighter';
        for (let w = 0; w < 2; w++) {
          gb.beginPath();
          for (let x = g.x0; x <= g.x1; x += 3) { const yy = y + Math.sin(x * 0.06 - clock * (3 + w) * s.side) * th * (0.55 + w * 0.3); if (x === g.x0) gb.moveTo(x, yy); else gb.lineTo(x, yy); }
          gb.globalAlpha = 1; gb.strokeStyle = (w ? P[0] : P[1]) + hexA(0.35 * bI); gb.lineWidth = 1.5 * bS; gb.stroke();
        }
        if (room && Math.random() < n * 0.3) parts.push({ k: 'b', x: rnd(), y, vx: 0, vy: -(0.3 + Math.random() * 0.5) * bS, life: 1, decay: 0.012, r: (1 + Math.random() * 2) * bS, P, wob: Math.random() * 6 });
      }
      if (th2 === 'blood' && room && Math.random() < n * 0.9) parts.push({ k: 'd', x: rnd(), y: y + th * 0.4, vx: 0, vy: 0.05, life: 1, decay: 0.006, r: (1.4 + Math.random() * 1.6) * bS, P, wob: 0, hang: 0.4 + Math.random() * 0.8 });
      if (th2 === 'specter' && room) for (let i = 0; i < n * 1.2; i++) parts.push({ k: 'f', x: rnd(), y: y - th * 0.3, vx: (Math.random() - 0.5) * 0.4, vy: -(0.7 + Math.random() * 1.3) * bS, life: 1, decay: 0.03 + Math.random() * 0.04, r: (3 + Math.random() * 3.5) * bS, P, wob: Math.random() * 6 });
      if (th2 === 'specter' && room) for (let i = 0; i < n * 0.8; i++) parts.push({ k: 's', x: rnd(), y, vx: (Math.random() - 0.5) * 0.5, vy: -(0.25 + Math.random() * 0.5) * bS, life: 1, decay: 0.01 + Math.random() * 0.012, r: (4 + Math.random() * 6) * bS, P, wob: Math.random() * 6 });
      if (th2 === 'nature') {
        gb.globalCompositeOperation = 'source-over'; gb.globalAlpha = 1; gb.beginPath();
        for (let x = g.x0; x <= g.x1; x += 2) { const yy = y + Math.sin(x * 0.09) * th * 0.9; if (x === g.x0) gb.moveTo(x, yy); else gb.lineTo(x, yy); }
        gb.strokeStyle = P[2]; gb.lineWidth = 1.6 * bS; gb.stroke();
        if (room && Math.random() < n * 0.25) parts.push({ k: 'l', x: rnd(), y: y - th, vx: (Math.random() - 0.5) * 0.6, vy: (0.2 + Math.random() * 0.4) * bS, life: 1, decay: 0.008, r: (2.5 + Math.random() * 2.5) * bS, P, wob: Math.random() * 6, rot: Math.random() * 6 });
      }
      if (th2 === 'lightning') {
        if (Math.random() < 0.12 * bI * rate * dt * 60) {
          const pts = []; for (let x = g.x0; x <= g.x1; x += 6 + Math.random() * 8) pts.push([x, y + (Math.random() - 0.5) * th * 3.2 * R]);
          pts.push([g.x1, y]); bolts.push({ P, life: 1, pts });
        }
        if (room) for (let i = 0; i < n * 0.4; i++) parts.push({ k: 'z', x: rnd(), y, vx: (Math.random() - 0.5) * 3, vy: (Math.random() - 0.5) * 3, life: 1, decay: 0.08, r: (1 + Math.random()) * bS, P, wob: 0 });
      }
    }
  }
  function emitSkulls(rate, dt) {
    if (!t.skulls.on || !rate) return;
    const engulf = ENGULF[style], fr = FRONT[style] || 0;
    for (const s of sides) {
      if (!s.pal) continue;
      const g = geo(s), sp = skW / 60, dir = s.side;            // dir: the way the skull faces
      const n = skW * 0.08 * rate * (RATE[style] || 1) * skI * dt * 60;
      for (let i = 0; i < n; i++) {
        const u = Math.random();
        const ex = engulf && Math.random() < 0.35 ? 30 + Math.random() * 75 : 16 + u * 70;
        const ey = engulf ? 10 + Math.random() * 60 : 12 + (1 - u) * 40 * Math.random() + (u < 0.3 ? 25 : 0);
        const x = g.x + (dir > 0 ? ex : 120 - ex) / 120 * skW, y = g.y + ey / 100 * skH;
        const p = { k: 'f', x, y, vx: (-dir * (0.6 + Math.random() * 1.2) + (Math.random() - 0.5) * 0.6) * sp, vy: -(1.2 + Math.random() * 1.6) * sp, life: 1, decay: 0.022 + Math.random() * 0.03, r: (3.5 + Math.random() * 4) * sp, P: s.pal, wob: Math.random() * 6, a: skI };
        if (fr && Math.random() < 0.5) { if (fparts.length < MAX_PARTS / 2) fparts.push({ ...p, a: skI * fr }); } else if (parts.length < MAX_PARTS) parts.push(p);
      }
    }
  }
  function drawParts(g, list, dt) {
    g.globalCompositeOperation = 'lighter';
    for (const p of list) {
      p.x += p.vx * dt * 60; p.y += p.vy * dt * 60; p.wob += 0.15; p.life -= p.decay * dt * 60 / R;
      if (p.life <= 0) continue;
      const L = p.life, P = p.P, a = p.a || bI;
      if (p.k === 'f') { p.vy -= 0.02 * dt * 60; p.x += Math.sin(p.wob) * 0.2; const c = L > 0.85 ? P[0] : L > 0.6 ? P[1] : L > 0.3 ? P[2] : P[3]; glow(g, p.x, p.y, p.r * (0.3 + L * 0.8), c, L * L * 0.55 * a); }
      else if (p.k === 's') { p.x += Math.sin(p.wob) * 0.5; glow(g, p.x, p.y, p.r * (1.2 - L * 0.4), P[1], L * 0.3 * a); }
      else if (p.k === 'b') { p.x += Math.sin(p.wob) * 0.3; g.globalAlpha = L * 0.7; g.strokeStyle = P[0]; g.lineWidth = 1; g.beginPath(); g.arc(p.x, p.y, p.r, 0, 6.3); g.stroke(); }
      else if (p.k === 'd') {
        p.hang -= dt; if (p.hang < 0) p.vy += 0.09 * dt * 60;
        g.globalCompositeOperation = 'source-over'; g.globalAlpha = Math.min(1, L * 1.4); g.fillStyle = P[2];
        const len = Math.max(p.r, Math.min(14 * bS, p.vy * 4)); g.beginPath(); g.ellipse(p.x, p.y, p.r * 0.8, len, 0, 0, 6.3); g.fill();
        g.globalCompositeOperation = 'lighter';
      }
      else if (p.k === 'z') glow(g, p.x, p.y, p.r * 3, P[0], L * 0.9);
      else if (p.k === 'l') {
        g.globalCompositeOperation = 'source-over'; p.rot += 0.05; g.save(); g.translate(p.x + Math.sin(p.wob) * 4, p.y); g.rotate(p.rot);
        g.globalAlpha = Math.min(1, L * 1.5); g.fillStyle = L > 0.5 ? P[1] : P[2]; g.beginPath(); g.ellipse(0, 0, p.r, p.r * 0.45, 0, 0, 6.3); g.fill(); g.restore();
        g.globalCompositeOperation = 'lighter';
      }
    }
    g.globalAlpha = 1;
    return list.filter((p) => p.life > 0);
  }
  function drawBolts(dt) {
    gb.globalCompositeOperation = 'lighter';
    for (const b of bolts) {
      gb.beginPath(); b.pts.forEach(([x, y], i) => (i ? gb.lineTo(x, y) : gb.moveTo(x, y)));
      gb.globalAlpha = Math.max(0, b.life); gb.shadowColor = b.P[2]; gb.shadowBlur = 12 * bI; gb.strokeStyle = b.P[0]; gb.lineWidth = 1.6 * bS; gb.stroke(); gb.shadowBlur = 0;
      b.life -= 0.12 * dt * 60;
    }
    gb.globalAlpha = 1;
    bolts = bolts.filter((b) => b.life > 0);
  }
  const frame = (now) => {
    raf = requestAnimationFrame(frame);
    if (!host.isConnected) { if (seen) cancelAnimationFrame(raf); return; }
    if (!seen) { seen = true; size(); sync(); last = now; window.addEventListener('resize', size); return; }
    if (document.hidden) { last = now; return; }
    const dt = Math.min(0.05, (now - last) / 1000); last = now; clock += dt;
    sync();
    const rate = still() ? 0 : calm() ? 0.45 : 1;
    gb.setTransform(1, 0, 0, 1, 0, 0); gb.clearRect(0, 0, back.width, back.height); gb.setTransform(dpr, 0, 0, dpr, 0, 0);
    gf.setTransform(1, 0, 0, 1, 0, 0); gf.clearRect(0, 0, front.width, front.height); gf.setTransform(dpr, 0, 0, dpr, 0, 0);
    drawBars(rate, dt);
    if (rate) {
      emitSkulls(rate, dt);
      parts = drawParts(gb, parts, dt); fparts = drawParts(gf, fparts, dt); drawBolts(dt);
    } else { parts = []; fparts = []; bolts = []; }
    if (!rate) { cancelAnimationFrame(raf); raf = 0; setTimeout(() => { if (host.isConnected) raf = requestAnimationFrame(frame); }, 500); }
  };
  raf = requestAnimationFrame(frame);
  return wrap;
}
