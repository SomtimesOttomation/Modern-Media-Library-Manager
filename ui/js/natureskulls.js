// Skulls for the Nature theme, drawn over the Bone skull on the skull bar (skull space: 120 x 100, facing right; the
// eye at (88, 49), nose 101-106 x 55-63, teeth x 80-100, crown near (60, 8), back of the skull near x 18).
// Only "tribal" (the Tribal mask) is in use. The others (overgrown, toadstool, antlered and the three tiki masks)
// are kept for later and are not offered anywhere yet.
import { leaf, LEAF } from './fxdraw.js';

const SKULL_PATH = new Path2D('M20,60 C10,44 14,20 40,11 C62,4 90,10 101,30 C104,36 106,40 104,44 L100,47 C104,52 108,58 107,63 L102,64 C104,68 104,72 102,75 L101,80 L78,80 C74,74 66,70 58,70 C52,72 48,76 46,80 C40,80 36,74 34,70 C28,68 22,66 20,60 Z M52,72 C55,82 60,90 70,93 L97,94 C101,93 103,90 102,86 L100,83 L80,83 C73,83 67,80 62,76 Z');
const R = (seed) => { let x = seed; return () => (x = (x * 9301 + 49297) % 233280) / 233280; };
function moss(g, rr, x0, y0, x1, y1, n, size) { for (let i = 0; i < n; i++) { const x = x0 + rr() * (x1 - x0), y = y0 + rr() * (y1 - y0), j = (rr() * 7) | 0; g.fillStyle = `rgba(${70 + j * 9},${105 + j * 10},${36 + j * 5},${.7 + j * .04})`; g.beginPath(); g.arc(x, y, size * (.5 + rr()), 0, 7); g.fill(); } }
function vine(g, pts, w) { g.lineCap = 'round'; g.lineJoin = 'round'; for (const [ww, c] of [[w + 1.4, 'rgba(10,25,6,.7)'], [w, '#3c6e22'], [w * .3, 'rgba(200,255,160,.3)']]) { g.beginPath(); pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y))); g.lineWidth = ww; g.strokeStyle = c; g.stroke(); } }
function flower(g, x, y, r, col, t) { for (let p = 0; p < 5; p++) { const a = p / 5 * 6.28 + t * .2; g.fillStyle = col; g.beginPath(); g.ellipse(x + Math.cos(a) * r, y + Math.sin(a) * r, r * .85, r * .5, a, 0, 7); g.fill(); } g.fillStyle = '#f2c94c'; g.beginPath(); g.arc(x, y, r * .55, 0, 7); g.fill(); }
function woodFill(g, path, x0, y0, x1, y1, base, dark) {
  g.save(); g.clip(path);
  const gr = g.createLinearGradient(x0, y0, x1, y1); gr.addColorStop(0, base[0]); gr.addColorStop(.5, base[1]); gr.addColorStop(1, base[2]); g.fillStyle = gr; g.fillRect(x0, y0, x1 - x0, y1 - y0);
  const rr = R(7); g.strokeStyle = dark; g.lineWidth = .5;
  for (let i = 0; i < 26; i++) { const y = y0 + rr() * (y1 - y0); g.beginPath(); g.moveTo(x0, y); g.bezierCurveTo(x0 + (x1 - x0) * .3, y + rr() * 4 - 2, x0 + (x1 - x0) * .7, y + rr() * 4 - 2, x1, y + rr() * 3 - 1.5); g.stroke(); }
  g.restore();
}

const LOOKS = [
  { tag: 'A', name: 'Overgrown', blurb: 'The bone skull reclaimed by the forest: moss creeping over the crown and down the back, a vine wrapping round the cranium and threading through the eye socket, leaves that sway, and a small white flower in bloom.',
    draw(g, st) {
      const t = st.t;
      g.save(); g.clip(SKULL_PATH); moss(g, R(3), 18, 6, 70, 34, 70, 2.2); moss(g, R(5), 16, 30, 34, 66, 40, 2); moss(g, R(9), 60, 64, 100, 72, 14, 1.4); g.restore();
      const sway = Math.sin(t * 1.2) * .6;
      vine(g, [[10, 54], [22, 38], [40, 26], [60, 22], [78, 30], [84, 44], [90, 52], [98, 58], [110, 66]], 2.4);
      vine(g, [[30, 14], [44, 18], [56, 30], [52, 44], [44, 56]], 1.6);
      for (const [x, y, a, c] of [[22, 38, -2.2, 0], [40, 26, -1.4, 1], [60, 22, -1.8, 2], [78, 30, -.6, 0], [92, 54, .4, 1], [108, 64, .9, 2], [44, 18, -1.2, 0], [52, 44, 2.4, 1], [44, 56, 2.0, 2]]) leaf(g, x, y, 9, a + sway * .3 + Math.sin(t * 1.6 + x) * .12, LEAF[c], true);
      flower(g, 36, 22, 2.6, '#f4f1e6', t);
    } },
  { tag: 'B', name: 'Tribal mask', blurb: 'The skull wears a carved wooden mask over its face: grained wood with deep-cut eye holes, white and ochre painted markings, a carved grimace with pegged teeth, feathers and leaves tied on with cord above, and an eerie glowing eye (set its colour, size and intensity at the top). Moss and vines overgrow the bone round the back, mushrooms grow from it, and a wooden antler on the brow of the mask is snapped in half, its top dangling and swinging, leaves sprouting at the tips.',
    draw(g, st) {
      const t = st.t;
      // oversized top to bottom like the tiki masks: stretched 1.45x about mid-face; cord and feathers are not stretched
      const SY = 1.45, CY = 56, Y = (y) => CY + (y - CY) * SY;
      // overgrowth on the bone round the back: moss, and vines over the crown and down the back of the skull
      g.save(); g.clip(SKULL_PATH); moss(g, R(21), 18, 10, 62, 34, 46, 2); moss(g, R(23), 16, 34, 32, 64, 26, 1.8); g.restore();
      { const sw = Math.sin(t * 1.2) * .6;
        vine(g, [[64, 10], [50, 12], [36, 18], [26, 30], [20, 44], [22, 58], [30, 70]], 2.2);
        vine(g, [[58, 16], [46, 26], [40, 40], [34, 54], [38, 68]], 1.5);
        for (const [x, y, a, c] of [[50, 12, -2.0, 0], [36, 18, -2.5, 1], [26, 30, -2.9, 2], [20, 44, 2.9, 0], [22, 58, 2.6, 1], [46, 26, -2.3, 2], [40, 40, 2.8, 0], [34, 54, 2.5, 1]]) leaf(g, x, y, 8.5, a + sw * .3 + Math.sin(t * 1.6 + x) * .12, LEAF[c], true);
        flower(g, 30, 24, 2.3, '#f4f1e6', t); }
      g.save(); g.translate(0, CY); g.scale(1, SY); g.translate(0, -CY);
      // the mask covers the face, from the brow down past the jaw
      const mask = new Path2D('M62,16 C82,10 104,18 110,36 C114,48 114,62 110,74 C107,86 100,96 88,100 C76,103 66,98 62,90 C56,78 54,60 56,42 C57,30 58,22 62,16 Z');
      g.save(); g.shadowColor = 'rgba(0,0,0,.55)'; g.shadowBlur = 4; g.shadowOffsetX = -1.5; g.fillStyle = '#5a3a1e'; g.fill(mask); g.restore();
      woodFill(g, mask, 54, 10, 116, 104, ['#a8743e', '#7a4e26', '#4a2c14'], 'rgba(40,20,6,.45)');
      g.strokeStyle = '#2a170a'; g.lineWidth = 1.4; g.stroke(mask);
      // carved eye hole (with the skull's dark socket behind) and a carved brow ridge
      g.fillStyle = '#120a05'; g.beginPath(); g.moveTo(80, 44); g.quadraticCurveTo(90, 36, 102, 44); g.quadraticCurveTo(92, 54, 80, 44); g.fill();
      // the eye glows an eerie colour (Eye glow controls at the top): a haze round the hole and a hot core inside it
      { const sz = .4 + (st.eye || EYE).size / 50, it = (st.eye || EYE).int / 50, fl = .82 + .18 * Math.sin(t * 2.3) * Math.sin(t * 5.1 + 1);
        const [r, gg, b] = hexRgb((st.eye || EYE).col);
        g.save(); g.globalCompositeOperation = 'lighter';
        const halo = g.createRadialGradient(91, 44.5, 0, 91, 44.5, 16 * sz); halo.addColorStop(0, `rgba(${r},${gg},${b},${Math.min(1, .55 * it * fl)})`); halo.addColorStop(1, `rgba(${r},${gg},${b},0)`);
        g.fillStyle = halo; g.beginPath(); g.ellipse(91, 44.5, 16 * sz, 11 * sz, 0, 0, 7); g.fill();
        const core = g.createRadialGradient(91, 44.5, 0, 91, 44.5, 6 * sz); core.addColorStop(0, `rgba(255,255,255,${Math.min(1, .9 * it * fl)})`); core.addColorStop(.35, `rgba(${r},${gg},${b},${Math.min(1, it * fl)})`); core.addColorStop(1, `rgba(${r},${gg},${b},0)`);
        g.fillStyle = core; g.beginPath(); g.ellipse(91, 44.5, 6 * sz, 3.6 * sz, 0, 0, 7); g.fill();
        g.restore(); }
      g.strokeStyle = 'rgba(255,220,170,.35)'; g.lineWidth = 1.2; g.beginPath(); g.moveTo(74, 36); g.quadraticCurveTo(90, 28, 106, 36); g.stroke();
      // carved nose ridge
      g.strokeStyle = '#3a220e'; g.lineWidth = 1.6; g.beginPath(); g.moveTo(104, 46); g.lineTo(110, 60); g.lineTo(104, 62); g.stroke();
      // carved grimace with pegged teeth
      g.fillStyle = '#120a05'; g.beginPath(); g.moveTo(74, 74); g.quadraticCurveTo(92, 70, 108, 74); g.quadraticCurveTo(92, 86, 74, 74); g.fill();
      g.fillStyle = '#e8dcc0'; for (let i = 0; i < 7; i++) { const x = 78 + i * 4.2; g.beginPath(); g.moveTo(x, 73.5); g.lineTo(x + 1.6, 78 - Math.abs(i - 3) * .5); g.lineTo(x + 3.2, 73.5); g.fill(); }
      // painted markings: white zigzag across the cheek, ochre bands and dots, a white line down the brow
      g.lineCap = 'round'; g.lineJoin = 'round';
      g.strokeStyle = 'rgba(240,235,220,.9)'; g.lineWidth = 1.6; g.beginPath(); g.moveTo(64, 58); for (let i = 1; i <= 8; i++) g.lineTo(64 + i * 4, 58 + (i % 2 ? -4 : 0)); g.stroke();
      g.beginPath(); g.moveTo(92, 18); g.lineTo(92, 32); g.stroke();
      g.strokeStyle = 'rgba(214,140,40,.95)'; g.lineWidth = 2.2; g.beginPath(); g.moveTo(62, 66); g.quadraticCurveTo(80, 64, 104, 68); g.stroke(); g.beginPath(); g.moveTo(64, 92); g.quadraticCurveTo(80, 96, 98, 94); g.stroke();
      g.fillStyle = 'rgba(240,235,220,.9)'; for (const [x, y] of [[68, 46], [72, 50], [68, 54], [104, 86], [100, 90]]) { g.beginPath(); g.arc(x, y, 1.2, 0, 7); g.fill(); }
      g.fillStyle = 'rgba(180,40,30,.85)'; for (const [x, y] of [[66, 40], [110, 52]]) { g.beginPath(); g.moveTo(x, y - 3); g.lineTo(x + 3, y); g.lineTo(x, y + 3); g.lineTo(x - 3, y); g.closePath(); g.fill(); }
      g.restore();
      // cord, feathers and leaves tied at the top
      g.strokeStyle = '#6b4a2b'; g.lineWidth = 1.4; g.beginPath(); g.moveTo(58, Y(26)); g.quadraticCurveTo(40, Y(20), 24, Y(30)); g.stroke();
      const sw = Math.sin(t * 1.3) * .08;
      for (const [x, y, a, col] of [[64, Y(16), -1.9, '#d9c7a4'], [70, Y(14), -1.55, '#7a3a24'], [76, Y(14), -1.25, '#e8e1cf']]) {
        g.save(); g.translate(x, y); g.rotate(a + sw); const L = 26;
        g.fillStyle = col; g.beginPath(); g.moveTo(0, 0); g.quadraticCurveTo(L * .5, -4, L, 0); g.quadraticCurveTo(L * .5, 4, 0, 0); g.fill();
        g.strokeStyle = 'rgba(0,0,0,.35)'; g.lineWidth = .5; g.beginPath(); g.moveTo(0, 0); g.lineTo(L, 0); for (let k = 4; k < L; k += 3) { g.moveTo(k, 0); g.lineTo(k + 2, -2.6); g.moveTo(k, 0); g.lineTo(k + 2, 2.6); } g.stroke();
        g.fillStyle = 'rgba(30,20,10,.6)'; g.fillRect(L * .78, -2.5, 1.5, 5); g.restore();
      }
      leaf(g, 60, Y(18), 10, -2.6 + sw, LEAF[0], true); leaf(g, 80, Y(16), 9, -.9 + sw, LEAF[2], true);
      // mushrooms growing out of the back of the skull, leaning outward
      for (const [x, y, h, r, cap, spots, a, i] of [[26, 30, 15, 10, ['#ff5a3c', '#a31d10'], true, -.85, 0], [19, 44, 12, 7.5, ['#c79a62', '#6e4a24'], false, -1.2, 1], [20, 57, 9, 6, ['#d8b07a', '#7e5428'], false, -1.5, 2], [34, 20, 9, 5.5, ['#ff6a4a', '#b0281a'], true, -.55, 3], [24, 66, 7, 4.5, ['#c79a62', '#6e4a24'], false, -1.8, 4]]) {
        g.save(); g.translate(x, y); g.rotate(a); shroomAt(g, 0, 0, h, r, cap, spots, Math.sin(t * 1.5 + i) * .6); g.restore();
      }
      // one antler from the top front of the mask, leaning 30 degrees forward, snapped halfway: the top half dangles
      // from the break by a strip of bark and swings
      { const bx = 92, by = Y(20), up = -Math.PI / 2 + Math.PI / 6, L1 = 20;
        const kx = bx + Math.cos(up) * L1, ky = by + Math.sin(up) * L1;
        const tine = (x0, y0, a, L, w) => { const x1 = x0 + Math.cos(a) * L, y1 = y0 + Math.sin(a) * L; g.lineCap = 'round'; g.strokeStyle = '#3a2614'; g.lineWidth = w + 1; g.beginPath(); g.moveTo(x0, y0); g.lineTo(x1, y1); g.stroke(); g.strokeStyle = '#7a5532'; g.lineWidth = w; g.stroke(); return [x1, y1]; };   // the gnarled wood of Antlered
        const sprout = (x, y, a) => leaf(g, x, y, 8, a + Math.sin(t * 1.6 + x) * .2, LEAF[(x | 0) % 3], true);
        g.fillStyle = '#5a3c22'; g.beginPath(); g.ellipse(bx, by, 5.2, 2.6, up + Math.PI / 2, 0, 7); g.fill(); g.strokeStyle = '#3a2614'; g.lineWidth = .8; g.stroke();   // the burr where it meets the mask
        tine(bx, by, up, L1, 5.4);
        { const [sx, sy] = tine(bx + Math.cos(up) * 9, by + Math.sin(up) * 9, up + .75, 9, 3); sprout(sx, sy, up + .75); }            // a short tine on the standing half
        g.fillStyle = '#c9a77a'; g.beginPath(); g.moveTo(kx - 2.4, ky + 1); g.lineTo(kx - 1, ky - 1.8); g.lineTo(kx + .4, ky - .2); g.lineTo(kx + 1.6, ky - 2); g.lineTo(kx + 2.6, ky + .8); g.closePath(); g.fill();   // the jagged break
        const swing = Math.sin(t * 1.8) * .2 + Math.sin(t * 3.7) * .05, ha = Math.PI / 2 + .12 + swing;   // hangs down, swinging
        g.strokeStyle = '#4a3220'; g.lineWidth = 1.8; g.beginPath(); g.moveTo(kx + 2, ky - .5); g.bezierCurveTo(kx + 6, ky + 1, kx + 6, ky + 4, kx + 3 + Math.cos(ha) * 4, ky + Math.sin(ha) * 4); g.stroke();   // the strip of bark it hangs by
        const hx = kx + 3 + Math.cos(ha) * 4, hy = ky + Math.sin(ha) * 4;
        const [ex, ey] = tine(hx, hy, ha, 24, 4.4);
        { const [sx, sy] = tine(hx + Math.cos(ha) * 10, hy + Math.sin(ha) * 10, ha - .8, 9, 2.6); sprout(sx, sy, ha - .8); }
        { const [sx, sy] = tine(ex, ey, ha + .5, 8, 2.2); sprout(sx, sy, ha + .5); } { const [sx, sy] = tine(ex, ey, ha - .45, 6, 2); sprout(sx, sy, ha - .45); }
        g.fillStyle = '#c9a77a'; g.beginPath(); g.moveTo(hx - 2.2, hy + 1); g.lineTo(hx - 1, hy - 1.6); g.lineTo(hx + .6, hy); g.lineTo(hx + 2.2, hy - 1.4); g.lineTo(hx + 2.4, hy + 1.2); g.closePath(); g.fill(); }
    } },
  { tag: 'C', name: 'Toadstool crown', blurb: 'Fungus has taken the skull: red-capped toadstools and little brown mushrooms grow from the crown, roots trail from the jaw, and moss fills the cracks. The caps bob slightly as if breathing.',
    draw(g, st) {
      const t = st.t;
      g.save(); g.clip(SKULL_PATH); moss(g, R(11), 30, 8, 92, 24, 60, 1.8); moss(g, R(13), 18, 40, 30, 62, 22, 1.6); g.restore();
      // roots from under the jaw and the back
      g.strokeStyle = '#5a3c22'; g.lineCap = 'round';
      for (const [x, y, len, a, w] of [[66, 94, 18, 1.7, 2], [84, 98, 14, 1.4, 1.6], [24, 64, 16, 2.2, 1.6], [96, 96, 10, 1.2, 1.2]]) { g.lineWidth = w; g.beginPath(); g.moveTo(x, y); let px = x, py = y; for (let k = 0; k < 4; k++) { px += Math.cos(a + Math.sin(k * 2 + t * .5) * .3) * len / 4; py += Math.sin(a) * len / 4; g.lineTo(px, py); } g.stroke(); }
      const bob = (i) => Math.sin(t * 1.5 + i) * .6;
      const shroom = (x, y, h, r, cap, spots, i) => {
        g.fillStyle = '#efe6cf'; g.beginPath(); g.moveTo(x - r * .28, y); g.quadraticCurveTo(x - r * .2, y - h * .6, x - r * .22, y - h); g.lineTo(x + r * .22, y - h); g.quadraticCurveTo(x + r * .2, y - h * .6, x + r * .28, y); g.closePath(); g.fill();
        g.strokeStyle = 'rgba(80,60,30,.4)'; g.lineWidth = .5; g.stroke();
        const cy = y - h + bob(i); const gr = g.createRadialGradient(x - r * .3, cy - r * .5, 0, x, cy, r * 1.2); gr.addColorStop(0, cap[0]); gr.addColorStop(1, cap[1]);
        g.fillStyle = gr; g.beginPath(); g.ellipse(x, cy, r, r * .62, 0, Math.PI, 0); g.quadraticCurveTo(x, cy + r * .22, x - r, cy); g.fill();
        if (spots) { g.fillStyle = 'rgba(250,245,235,.95)'; for (const [dx, dy, s] of [[-.4, -.3, .14], [.1, -.45, .12], [.45, -.22, .1], [-.05, -.12, .09]]) { g.beginPath(); g.ellipse(x + dx * r, cy + dy * r, s * r, s * r * .8, 0, 0, 7); g.fill(); } }
      };
      shroom(56, 12, 14, 10, ['#ff5a3c', '#a31d10'], true, 0);
      shroom(72, 10, 10, 7, ['#ff6a4a', '#b0281a'], true, 1);
      shroom(42, 16, 8, 5.5, ['#c79a62', '#6e4a24'], false, 2);
      shroom(84, 16, 6, 4.5, ['#c79a62', '#6e4a24'], false, 3);
      shroom(32, 24, 6, 4, ['#d8b07a', '#7e5428'], false, 4);
    } },
  { tag: 'D', name: 'Antlered', blurb: 'A forest spirit: branching antlers of gnarled wood grow from the skull, sprouting fresh leaves that sway, with moss on the brow and a soft green light in the eye.',
    draw(g, st) {
      const t = st.t;
      g.save(); g.clip(SKULL_PATH); moss(g, R(17), 60, 26, 98, 36, 30, 1.6); g.restore();
      const glow = .5 + .5 * Math.sin(t * 1.2);
      g.fillStyle = `rgba(150,240,90,${.25 + glow * .35})`; g.beginPath(); g.ellipse(88, 49, 6, 5, 0, 0, 7); g.fill();
      g.fillStyle = `rgba(230,255,200,${.6 + glow * .3})`; g.beginPath(); g.arc(89, 49, 1.6, 0, 7); g.fill();
      const branch = (x, y, a, len, w, depth) => {
        const x2 = x + Math.cos(a) * len, y2 = y + Math.sin(a) * len;
        g.strokeStyle = '#3a2614'; g.lineWidth = w + 1; g.lineCap = 'round'; g.beginPath(); g.moveTo(x, y); g.lineTo(x2, y2); g.stroke();
        g.strokeStyle = '#7a5532'; g.lineWidth = w; g.stroke();
        if (depth > 0) { branch(x2, y2, a - .45, len * .7, w * .7, depth - 1); branch(x2, y2, a + .35, len * .62, w * .66, depth - 1); }
        else leaf(g, x2, y2, 8, a + Math.sin(t * 1.6 + x2) * .2, LEAF[(x2 | 0) % 3], true);
      };
      branch(48, 14, -2.0, 16, 3.4, 3);
      branch(70, 12, -1.15, 16, 3.4, 3);
    } },
];
// ---- tiki mask (side profile over the skull, facing right): carved wood, a big ringed eye, a heavy carved brow,
// a broad bulbous nose, a wide snarl of block teeth, chevrons cut into the forehead, carved scales on the chin.
// pal: wood (3 stops), groove paint colours, accent flowers
const EYE = { col: '#7dff4a', size: 50, int: 60 };
const hexRgb = (h) => { const m = /^#?([0-9a-f]{6})$/i.exec(h) || [0, '7dff4a']; const n = parseInt(m[1], 16); return [n >> 16, (n >> 8) & 255, n & 255]; };
function shroomAt(g, x, y, h, r, cap, spots, bob) {
  g.fillStyle = '#efe6cf'; g.beginPath(); g.moveTo(x - r * .28, y); g.quadraticCurveTo(x - r * .2, y - h * .6, x - r * .22, y - h); g.lineTo(x + r * .22, y - h); g.quadraticCurveTo(x + r * .2, y - h * .6, x + r * .28, y); g.closePath(); g.fill();
  g.strokeStyle = 'rgba(80,60,30,.4)'; g.lineWidth = .5; g.stroke();
  const cy = y - h + bob, gr = g.createRadialGradient(x - r * .3, cy - r * .5, 0, x, cy, r * 1.2); gr.addColorStop(0, cap[0]); gr.addColorStop(1, cap[1]);
  g.fillStyle = gr; g.beginPath(); g.ellipse(x, cy, r, r * .62, 0, Math.PI, 0); g.quadraticCurveTo(x, cy + r * .22, x - r, cy); g.fill();
  if (spots) { g.fillStyle = 'rgba(250,245,235,.95)'; for (const [dx, dy, s] of [[-.4, -.3, .14], [.1, -.45, .12], [.45, -.22, .1], [-.05, -.12, .09]]) { g.beginPath(); g.ellipse(x + dx * r, cy + dy * r, s * r, s * r * .8, 0, 0, 7); g.fill(); } }
}
function tiki(g, st, pal) {
  const t = st.t;
  // the mask is oversized top to bottom: stretched 1.45x about mid-face, so it towers over the skull
  const SY = 1.45, CY = 56, Y = (y) => CY + (y - CY) * SY;
  const DX = 0;
  g.save(); g.translate(DX, CY); g.scale(1, SY); g.translate(0, -CY);
  const mask = new Path2D('M58,8 C78,2 102,8 112,26 C118,38 118,52 116,62 C121,66 122,74 116,78 C118,88 112,100 98,104 C84,107 68,104 62,94 C55,82 52,62 53,44 C54,28 54,16 58,8 Z');
  g.save(); g.shadowColor = 'rgba(0,0,0,.55)'; g.shadowBlur = 5; g.shadowOffsetX = -2; g.fillStyle = pal.wood[2]; g.fill(mask); g.restore();
  woodFill(g, mask, 50, 0, 124, 108, pal.wood, 'rgba(50,25,8,.35)');
  // shading: darker toward the back edge, a sheen on the front planes
  g.save(); g.clip(mask);
  const sh = g.createLinearGradient(52, 0, 118, 0); sh.addColorStop(0, 'rgba(30,15,5,.45)'); sh.addColorStop(.45, 'rgba(30,15,5,0)'); sh.addColorStop(.85, 'rgba(255,240,210,.12)'); sh.addColorStop(1, 'rgba(30,15,5,.25)');
  g.fillStyle = sh; g.fillRect(50, 0, 74, 108);
  g.restore();
  const groove = (path, w, col) => { g.lineCap = 'round'; g.lineJoin = 'round'; g.strokeStyle = 'rgba(30,14,4,.75)'; g.lineWidth = w + 1.6; g.stroke(path); g.strokeStyle = col; g.lineWidth = w; g.stroke(path); };
  // forehead chevrons, painted in the grooves
  for (let i = 0; i < 3; i++) groove(new Path2D(`M${66 + i * 3},${12 + i * 5} L${84},${20 + i * 5} L${102 - i * 2},${12 + i * 5}`), 1.6, pal.paint[i % pal.paint.length]);
  groove(new Path2D('M84,6 L84,30'), 1.4, pal.paint[1]);
  // heavy brow overhang
  const brow = new Path2D('M66,34 C76,26 98,26 110,36 C104,34 96,33 88,34 C80,35 72,37 66,40 Z');
  g.fillStyle = 'rgba(40,20,6,.55)'; g.fill(brow); groove(new Path2D('M66,38 C78,30 98,30 110,37'), 1.4, pal.paint[0]);
  // the ringed eye: a raised carved ring with a hole, the skull's dark socket behind it
  const ex = 88, ey = 48, pulse = 1 + Math.sin(t * 1.3) * .02;
  g.fillStyle = 'rgba(30,14,4,.55)'; g.beginPath(); g.ellipse(ex, ey, 14, 12.5, 0, 0, 7); g.fill();
  const ring = g.createRadialGradient(ex - 3, ey - 4, 2, ex, ey, 11); ring.addColorStop(0, pal.wood[0]); ring.addColorStop(1, pal.wood[2]);
  g.fillStyle = ring; g.beginPath(); g.ellipse(ex, ey, 10.5 * pulse, 9.5 * pulse, 0, 0, 7); g.fill();
  g.strokeStyle = pal.paint[2]; g.lineWidth = 2; g.beginPath(); g.ellipse(ex, ey, 8, 7.2, 0, 0, 7); g.stroke();
  g.fillStyle = '#0c0603'; g.beginPath(); g.ellipse(ex + .5, ey, 4.6, 4.2, 0, 0, 7); g.fill();
  g.fillStyle = 'rgba(255,245,225,.5)'; g.beginPath(); g.ellipse(ex - 4.5, ey - 4.5, 2.2, 1.4, -.6, 0, 7); g.fill();
  // cheek swirl
  groove(new Path2D('M70,58 C64,52 68,44 76,48 C80,51 76,56 72,54'), 1.6, pal.paint[1]);
  // broad bulbous nose
  const nose = new Path2D('M106,44 C112,50 122,56 121,64 C120,70 112,70 106,68 C104,62 104,52 106,44 Z');
  g.fillStyle = pal.wood[1]; g.fill(nose); g.strokeStyle = 'rgba(30,14,4,.8)'; g.lineWidth = 1.2; g.stroke(nose);
  g.fillStyle = '#1a0c04'; g.beginPath(); g.ellipse(113, 66, 2.6, 1.6, .2, 0, 7); g.fill();
  g.fillStyle = 'rgba(255,240,210,.25)'; g.beginPath(); g.ellipse(115, 57, 3, 2, -.5, 0, 7); g.fill();
  // the wide snarl: thick carved lips round a dark mouth, two rows of block teeth
  const mouth = new Path2D('M66,74 C80,68 104,68 116,74 C114,84 106,92 90,92 C76,92 68,86 66,74 Z');
  g.fillStyle = '#120804'; g.fill(mouth);
  for (let r = 0; r < 2; r++) for (let i = 0; i < 6; i++) {
    const x = 72 + i * 7, y = r ? 84 : 73.5, h = r ? -6.5 : 6.5;
    g.fillStyle = pal.teeth; g.beginPath(); if (g.roundRect) g.roundRect(x, Math.min(y, y + h), 6, Math.abs(h), 1.6); else g.rect(x, Math.min(y, y + h), 6, Math.abs(h)); g.fill();
    g.strokeStyle = 'rgba(60,35,15,.6)'; g.lineWidth = .6; g.stroke();
  }
  g.strokeStyle = 'rgba(30,14,4,.85)'; g.lineWidth = 2.6; g.stroke(mouth);
  groove(new Path2D('M64,72 C80,64 104,64 118,72'), 1.6, pal.paint[0]);
  // carved scales on the chin
  g.save(); g.clip(mask);
  for (let row = 0; row < 2; row++) for (let i = 0; i < 5 - row; i++) {
    const x = 72 + i * 8 + row * 4, y = 96 + row * 5;
    g.fillStyle = 'rgba(40,20,6,.4)'; g.beginPath(); g.arc(x, y, 3.6, Math.PI, 0); g.fill();
    g.strokeStyle = pal.paint[(i + row) % pal.paint.length]; g.lineWidth = .9; g.beginPath(); g.arc(x, y, 3.6, Math.PI, 0); g.stroke();
  }
  g.restore();
  g.restore();
  // tropical touches (not stretched): a hibiscus behind the ear, palm fronds tied on top of the tall mask, a frangipani
  const sw = Math.sin(t * 1.2) * .08;
  const frond = (x, y, a, L) => { g.save(); g.translate(x, y); g.rotate(a + sw); g.strokeStyle = pal.leaf[1]; g.lineWidth = 1.2; g.beginPath(); g.moveTo(0, 0); g.quadraticCurveTo(L * .5, -4, L, 0); g.stroke(); for (let k = 3; k < L; k += 2.4) { g.strokeStyle = pal.leaf[k % 2 ? 0 : 1]; g.lineWidth = 1.4; g.beginPath(); g.moveTo(k, -(k / L) * 4 + 2 * (k / L) * (k / L) * 0); g.lineTo(k + 3.5, -6 + (k / L) * 3); g.moveTo(k, 0); g.lineTo(k + 3.5, 5 - (k / L) * 2); g.stroke(); } g.restore(); };
  frond(62 + DX, Y(10), -2.3, 28); frond(70 + DX, Y(6), -1.75, 30); frond(80 + DX, Y(6), -1.25, 26);
  const hib = (x, y, r, col) => {
    for (let p = 0; p < 5; p++) { const a = p / 5 * 6.28 + t * .15; const gr = g.createRadialGradient(x, y, 0, x + Math.cos(a) * r, y + Math.sin(a) * r, r * 1.1); gr.addColorStop(0, col[1]); gr.addColorStop(1, col[0]); g.fillStyle = gr; g.beginPath(); g.ellipse(x + Math.cos(a) * r * .8, y + Math.sin(a) * r * .8, r * .85, r * .62, a, 0, 7); g.fill(); }
    g.strokeStyle = '#f2c94c'; g.lineWidth = 1.2; g.beginPath(); g.moveTo(x, y); g.lineTo(x + r * 1.3, y - r * .6); g.stroke(); g.fillStyle = '#f2c94c'; g.beginPath(); g.arc(x + r * 1.3, y - r * .6, 1.2, 0, 7); g.fill();
  };
  hib(46 + DX * .8, Y(30), 7, pal.flower);
  const frang = (x, y, r) => { for (let p = 0; p < 5; p++) { const a = p / 5 * 6.28 - t * .1; g.fillStyle = '#fffaf0'; g.beginPath(); g.ellipse(x + Math.cos(a) * r * .7, y + Math.sin(a) * r * .7, r * .8, r * .42, a + .5, 0, 7); g.fill(); } const c = g.createRadialGradient(x, y, 0, x, y, r * .7); c.addColorStop(0, '#ffd23f'); c.addColorStop(1, 'rgba(255,210,63,0)'); g.fillStyle = c; g.beginPath(); g.arc(x, y, r * .7, 0, 7); g.fill(); };
  frang(38 + DX * .8, Y(44), 4.6);
}
const TIKI = [
  { tag: 'T1', name: 'Tiki, natural wood', blurb: 'An original carved tiki mask in warm natural wood (big ringed eye, heavy brow, broad nose, a snarl of block teeth, carved chevrons and scales) with its grooves painted lagoon turquoise, coral and lime, palm fronds on top, a red hibiscus and a frangipani.',
    pal: { wood: ['#c99a64', '#9a6a3a', '#5e3a1c'], paint: ['#3fd0c9', '#ff7a59', '#9be15d'], teeth: '#f1e4c6', leaf: ['#3fae4a', '#1f7a34'], flower: ['#e0263c', '#ff8a8a'] } },
  { tag: 'T2', name: 'Tiki, painted bold', blurb: 'The same mask painted loud like a beach-bar tiki: deep reef-teal wood, grooves in hot coral, sunflower yellow and hibiscus pink, a magenta hibiscus and bright jungle fronds.',
    pal: { wood: ['#2bb3a6', '#16857c', '#0b4e49'], paint: ['#ff5e5b', '#ffd23f', '#ff4fa3'], teeth: '#fff3d6', leaf: ['#7be04a', '#27a03a'], flower: ['#ff2f8f', '#ffb3d6'] } },
  { tag: 'T3', name: 'Tiki, lagoon pastel', blurb: 'Sun-bleached driftwood in soft pastels, like the lagoon at noon: seafoam, aqua and shell-pink grooves, lilac accents, a peach hibiscus and pale fronds.',
    pal: { wood: ['#e7d8c3', '#c9b497', '#8f7a5e'], paint: ['#7fdcd4', '#f6a8b8', '#b9a6ff'], teeth: '#fffaf0', leaf: ['#9fd8a4', '#5fb08a'], flower: ['#ffab91', '#ffe0cc'] } },
];
for (const T of TIKI) LOOKS.push({ tag: T.tag, name: T.name, blurb: T.blurb, draw(g, st) { tiki(g, st, T.pal); } });

// key -> the look; the tag is the mock-up's card letter
const KEYS = { A: 'overgrown', B: 'tribal', C: 'toadstool', D: 'antlered', T1: 'tikiNatural', T2: 'tikiBold', T3: 'tikiLagoon' };
export const NATURE_SKULLS = Object.fromEntries(LOOKS.map((l) => [KEYS[l.tag], l]));
export const NATURE_SKULL_IN_USE = 'tribal';

// draws a nature skull's dressing over the Bone skull at (x, y), w wide; face 1 looks right, -1 left.
// st keeps its own time; st.eye = { col, size, int } sets the Tribal mask's eye glow
export function natureSkull(g, st, key, x, y, w, face, dt) {
  const look = NATURE_SKULLS[key] || NATURE_SKULLS.tribal;
  const k = w / 120; st.t = (st.t || 0) + dt;
  g.save(); g.translate(x + (face < 0 ? w : 0), y); g.scale(k * face, k);
  look.draw(g, st);
  g.restore();
}
