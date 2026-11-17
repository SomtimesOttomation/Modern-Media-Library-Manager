// Themed skulls for the skull bar (Compare): Fire (Inferno, or Molten), Water (Coral reef), Lightning (Storm-charged),
// Souls of the Damned (Fel-possessed) and Poster colours (Neon glass, or Painted). Each is the Bone skull drawn on a
// canvas with its own effects around and over it, plus a bar of its own for Fire, Souls and Lightning.
// Skull space: 120 x 100, facing right. Ported from the themed-skull mock-up the look was picked from.
import { skullSVG } from './skullfx.js';
const CTL = { auraCol: '#ff6a1f', auraSize: 50, auraInt: 40, eyeCol: '#ffb347', eyeSize: 40, eyeInt: 50 };
// skull space: 120 x 100, facing right; eye at (88, 49), nose 101-106 x 55-63, teeth x 80-100 y 74-88, crown near
// (60, 8), back of the skull near x 18
const SKULL_PATH = new Path2D('M20,60 C10,44 14,20 40,11 C62,4 90,10 101,30 C104,36 106,40 104,44 L100,47 C104,52 108,58 107,63 L102,64 C104,68 104,72 102,75 L101,80 L78,80 C74,74 66,70 58,70 C52,72 48,76 46,80 C40,80 36,74 34,70 C28,68 22,66 20,60 Z M52,72 C55,82 60,90 70,93 L97,94 C101,93 103,90 102,86 L100,83 L80,83 C73,83 67,80 62,76 Z');
const R = (seed) => { let x = seed; return () => (x = (x * 9301 + 49297) % 233280) / 233280; };
const rgba = (h, a) => { const n = parseInt(h.slice(1), 16); return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`; };
function glowAt(g, x, y, r, col, a) { const gr = g.createRadialGradient(x, y, 0, x, y, r); gr.addColorStop(0, rgba(col, a)); gr.addColorStop(1, rgba(col, 0)); g.fillStyle = gr; g.beginPath(); g.arc(x, y, r, 0, 7); g.fill(); }
// the cracks over the skull: a fixed web so they don't jump about
const CRACKS = 'M60,10 L56,22 L62,30 L58,42 M56,22 L44,26 L36,36 M62,30 L76,30 L84,22 M76,30 L80,40 M36,36 L28,46 L30,58 M44,26 L40,14 M84,22 L96,26 M58,42 L50,52 L54,62 M50,52 L40,56';
const crackPath = new Path2D(CRACKS);
function flameTongue(g, x, y, h, w, t, ph, cols) {
  const sway = Math.sin(t * 6 + ph) * w * .35, top = y - h * (.85 + .15 * Math.sin(t * 9 + ph * 2));
  const gr = g.createLinearGradient(0, y, 0, top); gr.addColorStop(0, cols[0]); gr.addColorStop(.45, cols[1]); gr.addColorStop(1, cols[2]);
  g.fillStyle = gr; g.beginPath(); g.moveTo(x - w, y); g.bezierCurveTo(x - w * 1.1, y - h * .45, x + sway - w * .3, y - h * .7, x + sway, top); g.bezierCurveTo(x + sway + w * .3, y - h * .7, x + w * 1.1, y - h * .45, x + w, y); g.closePath(); g.fill();
}
function sparks(st, key, n, spawn, step, g, dt, draw) { st[key] = st[key] || []; if (Math.random() < dt * n) st[key].push(spawn()); st[key] = st[key].filter((p) => { step(p, dt); if (p.life <= 0) return false; draw(g, p); return true; }); }
function bolt(g, x0, y0, x1, y1, rough, col, w) {
  const pts = [[x0, y0]], n = 7; for (let i = 1; i < n; i++) { const k = i / n; pts.push([x0 + (x1 - x0) * k + (Math.random() - .5) * rough, y0 + (y1 - y0) * k + (Math.random() - .5) * rough]); } pts.push([x1, y1]);
  g.lineCap = 'round'; g.lineJoin = 'round';
  for (const [ww, c] of [[w * 4, rgba(col, .25)], [w * 2, rgba(col, .6)], [w * .8, 'rgba(255,255,255,.95)']]) { g.strokeStyle = c; g.lineWidth = ww; g.beginPath(); pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y))); g.stroke(); }
}

const LOOKS = [
  // ---------------- Fire ----------------
  { theme: 'Fire', tag: 'F1', name: 'Molten', bar: ['#ffd27a', '#ff6a1f', '#7a1200'],
    blurb: 'The skull glows like metal in a forge: the bone darkened and charred, cracks glowing white-hot to orange that pulse, the eye a burning core with a flame curling out of it, embers drifting up.',
    draw(g, st, dt) {
      const t = st.t, pulse = .75 + .25 * Math.sin(t * 2.2);
      g.save(); g.clip(SKULL_PATH);
      g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(70,30,20,.85)'; g.fill(SKULL_PATH); g.globalCompositeOperation = 'source-over';
      const heat = g.createRadialGradient(60, 70, 4, 60, 60, 60); heat.addColorStop(0, `rgba(255,120,30,${.35 * pulse})`); heat.addColorStop(1, 'rgba(255,80,20,0)'); g.fillStyle = heat; g.fillRect(0, 0, 120, 100);
      g.lineCap = 'round'; g.lineJoin = 'round';
      for (const [w, c] of [[5, `rgba(255,90,20,${.35 * pulse})`], [2.4, `rgba(255,170,60,${.9 * pulse})`], [.9, `rgba(255,245,200,${pulse})`]]) { g.strokeStyle = c; g.lineWidth = w; g.stroke(crackPath); }
      g.restore();
      g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, 88, 49, 16, '#ff7a1f', .7 * pulse); glowAt(g, 88, 49, 6, '#fff3c0', .95); g.restore();
      flameTongue(g, 90, 46, 18, 4.5, t, 0, ['rgba(255,240,180,.95)', 'rgba(255,140,40,.9)', 'rgba(200,40,10,0)']);
      sparks(st, 'em', 14, () => ({ x: 30 + Math.random() * 70, y: 20 + Math.random() * 30, vx: (Math.random() - .5) * 8, vy: -20 - Math.random() * 20, life: 1 }), (p, d) => { p.x += p.vx * d; p.y += p.vy * d; p.life -= d * .9; }, g, dt,
        (g2, p) => { g2.save(); g2.globalCompositeOperation = 'lighter'; glowAt(g2, p.x, p.y, 2.6, p.life > .5 ? '#ffd27a' : '#ff6a1f', p.life); g2.restore(); });
    } },
  { theme: 'Fire', tag: 'F2', name: 'Hellfire crown', bar: ['#ffd27a', '#ff6a1f', '#7a1200'],
    blurb: 'A blackened skull wearing a crown of living flame: tall tongues of fire burn along the top of the head, the eye socket blazes, and smoke curls off the back.',
    draw(g, st, dt) {
      const t = st.t;
      g.save(); g.clip(SKULL_PATH); g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(45,35,30,.9)'; g.fill(SKULL_PATH); g.restore();
      sparks(st, 'sm', 4, () => ({ x: 20, y: 30 + Math.random() * 20, r: 4, life: 1 }), (p, d) => { p.x -= 10 * d; p.y -= 8 * d; p.r += 6 * d; p.life -= d * .5; }, g, dt, (g2, p) => { g2.fillStyle = `rgba(60,55,55,${p.life * .3})`; g2.beginPath(); g2.arc(p.x, p.y, p.r, 0, 7); g2.fill(); });
      const crown = [[30, 22], [38, 15], [47, 11], [56, 9], [65, 8], [74, 10], [83, 13], [92, 20]];
      g.save(); g.globalCompositeOperation = 'lighter';
      crown.forEach(([x, y], i) => flameTongue(g, x, y + 3, 16 + (i % 3) * 6, 4.5, t, i * 1.7, ['rgba(255,220,120,.9)', 'rgba(255,110,30,.8)', 'rgba(180,20,0,0)']));
      crown.forEach(([x, y], i) => flameTongue(g, x + 2, y + 2, 9 + (i % 2) * 4, 2.6, t, i * 2.3 + 1, ['rgba(255,255,220,.9)', 'rgba(255,200,80,.7)', 'rgba(255,120,30,0)']));
      glowAt(g, 88, 49, 14, '#ff5a1a', .85); glowAt(g, 88, 49, 5, '#fff3c0', .95);
      g.restore();
    } },
  { theme: 'Fire', tag: 'F3', name: 'Inferno', bar: ['#ffd27a', '#ff6a1f', '#7a1200'],
    blurb: 'A clean, pale skull completely engulfed: a roaring wall of fire wraps the whole head and streams up and back as if it is charging forward, fire burns inside the eye socket and nose, and sparks whip off the back.',
    draw(g, st, dt) {
      const t = st.t;
      // heat on the bone: lit warm from the fire around it, dark hollows stay dark
      g.save(); g.clip(SKULL_PATH); const lit = g.createLinearGradient(0, 0, 0, 100); lit.addColorStop(0, 'rgba(255,170,80,.35)'); lit.addColorStop(1, 'rgba(255,90,20,.15)'); g.fillStyle = lit; g.fillRect(0, 0, 120, 100); g.restore();
      // back layer of fire: tall tongues all round the head, leaning back (to the left)
      const rim = [[96, 26], [88, 16], [78, 10], [68, 7], [58, 7], [48, 9], [38, 13], [29, 20], [22, 30], [17, 42], [18, 54], [24, 64], [34, 72]];
      // keep the fire off the bone so it reads as burning around and behind the skull
      const outside = new Path2D(); outside.rect(-300, -300, 720, 700); outside.addPath(SKULL_PATH);
      g.save(); g.clip(outside, 'evenodd'); g.globalCompositeOperation = 'lighter';
      rim.forEach(([x, y], i) => { g.save(); g.translate(x, y); g.rotate(-.55 - (i / rim.length) * .5); flameTongue(g, 0, 12, (48 + (i % 3) * 14) * TAP(i, rim.length), 9 * TAP(i, rim.length), t, i * 1.3, ['rgba(255,200,90,.85)', 'rgba(255,90,20,.7)', 'rgba(150,10,0,0)']); g.restore(); });
      rim.forEach(([x, y], i) => { g.save(); g.translate(x, y); g.rotate(-.5 - (i / rim.length) * .45); flameTongue(g, 0, 9, (28 + (i % 2) * 10) * TAP(i, rim.length), 5 * TAP(i, rim.length), t, i * 2.1 + 1, ['rgba(255,255,220,.9)', 'rgba(255,190,70,.75)', 'rgba(255,100,20,0)']); g.restore(); });
      glowAt(g, 60, 40, 62, '#ff5a10', .35);
      g.restore();
      // fire inside the eye socket and the nose
      g.save(); g.globalCompositeOperation = 'lighter';
      glowAt(g, 88, 49, 10, '#ff7a1f', .9); flameTongue(g, 88, 54, 14, 4, t, .7, ['rgba(255,250,210,.95)', 'rgba(255,150,40,.85)', 'rgba(200,40,0,0)']);
      flameTongue(g, 103, 63, 8, 2.2, t, 2.4, ['rgba(255,240,190,.9)', 'rgba(255,130,30,.8)', 'rgba(200,40,0,0)']);
      g.restore();
      sparks(st, 'sp', 30, () => ({ x: 20 + Math.random() * 40, y: 10 + Math.random() * 50, vx: -40 - Math.random() * 40, vy: -30 - Math.random() * 30, life: 1 }), (p, d) => { p.x += p.vx * d; p.y += p.vy * d; p.life -= d * 1.4; }, g, dt,
        (g2, p) => { g2.save(); g2.globalCompositeOperation = 'lighter'; glowAt(g2, p.x, p.y, 2.2, '#ffd27a', p.life); g2.restore(); });
    } },
  // ---------------- Water ----------------
  { theme: 'Water', tag: 'W1', name: 'Drowned', bar: ['#cfefff', '#4aa8ff', '#0a2a66'],
    blurb: 'Pulled up from the deep: wet, sea-stained bone with water streaming off it, seaweed draped over the crown and swaying, barnacles on the jaw, and bubbles rising from the mouth and eye.',
    draw(g, st, dt) {
      const t = st.t;
      g.save(); g.clip(SKULL_PATH);
      g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(120,170,175,.55)'; g.fill(SKULL_PATH); g.globalCompositeOperation = 'source-over';
      const sheen = g.createLinearGradient(30, 10, 70, 60); sheen.addColorStop(0, 'rgba(255,255,255,.35)'); sheen.addColorStop(.4, 'rgba(255,255,255,0)'); g.fillStyle = sheen; g.fillRect(0, 0, 120, 100);
      // water running down in thin glossy rivulets
      for (let i = 0; i < 6; i++) { const x = 30 + i * 12, ph = (t * 18 + i * 13) % 70; g.strokeStyle = 'rgba(220,245,255,.55)'; g.lineWidth = 1.2; g.beginPath(); g.moveTo(x, 12 + i % 3 * 4); g.lineTo(x + 1, 12 + ph); g.stroke(); g.fillStyle = 'rgba(240,252,255,.8)'; g.beginPath(); g.arc(x + 1, 12 + ph, 1.4, 0, 7); g.fill(); }
      const rr = R(5); for (let i = 0; i < 9; i++) { const x = 60 + rr() * 40, y = 82 + rr() * 10; g.fillStyle = '#d8d2c0'; g.beginPath(); g.arc(x, y, 1.8 + rr() * 1.4, 0, 7); g.fill(); g.fillStyle = '#5a5a50'; g.beginPath(); g.arc(x, y, .7, 0, 7); g.fill(); }
      g.restore();
      // seaweed over the crown, hanging down the back
      for (const [x0, y0, len, ph, col] of [[44, 14, 40, .3, '#2f6a3a'], [56, 10, 34, 1.4, '#3f7d3a'], [36, 20, 44, 2.2, '#1f5a34'], [66, 9, 22, 3.1, '#4a8a3e']]) {
        g.strokeStyle = col; g.lineCap = 'round'; g.lineWidth = 4; g.beginPath(); g.moveTo(x0, y0);
        for (let k = 1; k <= 8; k++) { const f = k / 8; g.lineTo(x0 - f * len * .55 + Math.sin(t * 1.4 + ph + f * 4) * 3 * f, y0 + f * len); }
        g.stroke(); g.strokeStyle = 'rgba(180,240,190,.25)'; g.lineWidth = 1; g.stroke();
      }
      sparks(st, 'bub', 6, () => { const m = Math.random() < .6; return { x: m ? 92 + Math.random() * 6 : 88, y: m ? 82 : 46, r: .8 + Math.random() * 1.8, ph: Math.random() * 6, life: 1 }; }, (p, d) => { p.y -= 22 * d; p.x += Math.sin(p.y * .2 + p.ph) * .3; p.life -= d * .45; }, g, dt,
        (g2, p) => { g2.strokeStyle = `rgba(220,245,255,${p.life})`; g2.lineWidth = .7; g2.beginPath(); g2.arc(p.x, p.y, p.r, 0, 7); g2.stroke(); g2.fillStyle = `rgba(255,255,255,${p.life * .7})`; g2.beginPath(); g2.arc(p.x - p.r * .35, p.y - p.r * .35, p.r * .3, 0, 7); g2.fill(); });
    } },
  { theme: 'Water', tag: 'W2', name: 'Coral reef', bar: ['#cfefff', '#4aa8ff', '#0a2a66'],
    blurb: 'Years on the sea floor: pastel coral branches grow from the crown, a sea anemone waves its tentacles from the back of the head, little shells cling to the bone and bubbles drift up.',
    draw(g, st, dt) {
      const t = st.t;
      g.save(); g.clip(SKULL_PATH); g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(200,215,220,.6)'; g.fill(SKULL_PATH); g.restore();
      const coral = (x, y, a, len, w, col, depth) => { const x2 = x + Math.cos(a) * len, y2 = y + Math.sin(a) * len; g.strokeStyle = col; g.lineCap = 'round'; g.lineWidth = w; g.beginPath(); g.moveTo(x, y); g.lineTo(x2, y2); g.stroke(); if (depth) { coral(x2, y2, a - .5, len * .72, w * .72, col, depth - 1); coral(x2, y2, a + .45, len * .68, w * .7, col, depth - 1); } else { g.fillStyle = col; g.beginPath(); g.arc(x2, y2, w * .7, 0, 7); g.fill(); } };
      coral(56, 12, -1.75, 12, 3.4, '#ff9eb5', 3); coral(72, 12, -1.3, 10, 3, '#ffb38a', 3); coral(42, 18, -2.2, 9, 2.6, '#c9a6ff', 2);
      // anemone at the back of the head
      for (let i = 0; i < 9; i++) { const a = Math.PI + (i - 4) * .22; g.strokeStyle = '#7fdcd4'; g.lineWidth = 2.2; g.lineCap = 'round'; g.beginPath(); g.moveTo(20, 42); const L = 12; g.quadraticCurveTo(20 + Math.cos(a) * L * .6, 42 + Math.sin(a) * L * .6 + Math.sin(t * 2 + i) * 2, 20 + Math.cos(a + Math.sin(t * 1.6 + i) * .15) * L, 42 + Math.sin(a) * L); g.stroke(); g.fillStyle = '#ffd1e8'; g.beginPath(); g.arc(20 + Math.cos(a + Math.sin(t * 1.6 + i) * .15) * L, 42 + Math.sin(a) * L, 1.2, 0, 7); g.fill(); }
      g.fillStyle = '#e78fb3'; g.beginPath(); g.ellipse(20, 42, 4, 3, 0, 0, 7); g.fill();
      for (const [x, y, c] of [[36, 52, '#ffe0cc'], [64, 66, '#f6a8b8'], [28, 30, '#fff1d6']]) { g.fillStyle = c; g.beginPath(); g.moveTo(x, y); g.arc(x, y, 3, Math.PI, 0); g.closePath(); g.fill(); g.strokeStyle = 'rgba(120,80,60,.5)'; g.lineWidth = .5; for (let k = -2; k <= 2; k++) { g.beginPath(); g.moveTo(x, y); g.lineTo(x + k * 1.2, y - 2.6); g.stroke(); } }
      sparks(st, 'bub', 4, () => ({ x: 40 + Math.random() * 40, y: 14, r: .8 + Math.random() * 1.6, ph: Math.random() * 6, life: 1 }), (p, d) => { p.y -= 18 * d; p.x += Math.sin(p.y * .2 + p.ph) * .3; p.life -= d * .5; }, g, dt,
        (g2, p) => { g2.strokeStyle = `rgba(220,245,255,${p.life})`; g2.lineWidth = .7; g2.beginPath(); g2.arc(p.x, p.y, p.r, 0, 7); g2.stroke(); });
    } },
  // ---------------- Lightning ----------------
  { theme: 'Lightning', tag: 'L1', name: 'Storm-charged', bar: ['#ffffff', '#9cc4ff', '#2a3a8a'],
    blurb: 'A skull full of electricity: the bone gone storm-grey with blue-white cracks humming with charge, the eye blazing, and arcs crackling between the eye, the crown and the jaw every moment or so.',
    draw(g, st, dt) {
      const t = st.t, hum = .7 + .3 * Math.sin(t * 13) * Math.sin(t * 7);
      g.save(); g.clip(SKULL_PATH); g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(110,120,150,.75)'; g.fill(SKULL_PATH); g.globalCompositeOperation = 'source-over';
      g.lineCap = 'round'; g.lineJoin = 'round';
      for (const [w, c] of [[4, `rgba(120,170,255,${.3 * hum})`], [1.8, `rgba(170,210,255,${.9 * hum})`], [.7, 'rgba(255,255,255,.95)']]) { g.strokeStyle = c; g.lineWidth = w; g.stroke(crackPath); }
      g.restore();
      g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, 88, 49, 15, '#7aa8ff', .8 * hum); glowAt(g, 88, 49, 5, '#ffffff', 1);
      st.arc = (st.arc || 0) - dt;
      if (st.arc <= 0) { st.arc = .25 + Math.random() * .9; st.from = [[88, 49], [60, 10], [30, 40]][Math.floor(Math.random() * 3)]; st.to = [[92, 86], [104, 60], [70, 4]][Math.floor(Math.random() * 3)]; st.flash = .14; }
      if (st.flash > 0) { st.flash -= dt; bolt(g, st.from[0], st.from[1], st.to[0], st.to[1], 9, '#9cc4ff', 1.3); }
      g.restore();
    } },
  { theme: 'Lightning', tag: 'L2', name: 'Thunderhead', bar: ['#ffffff', '#9cc4ff', '#2a3a8a'],
    blurb: 'A small storm cloud churns over the skull, raining on it; every few seconds lightning strikes the crown, lighting the whole skull up white for a flash, and the eye flickers like a failing bulb.',
    draw(g, st, dt) {
      const t = st.t;
      st.strike = (st.strike ?? 1.5) - dt; let flash = 0;
      if (st.strike <= 0) { st.strike = 1.6 + Math.random() * 2.2; st.f = .22; }
      if (st.f > 0) { st.f -= dt; flash = st.f / .22; }
      if (flash) { g.save(); g.clip(SKULL_PATH); g.fillStyle = `rgba(230,240,255,${.55 * flash})`; g.fillRect(0, 0, 120, 100); g.restore(); }
      const flick = Math.random() < .12 ? .2 : .9; g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, 88, 49, 10, '#9cc4ff', .7 * flick); glowAt(g, 88, 49, 3.5, '#ffffff', flick); g.restore();
      // rain falling from the cloud
      g.strokeStyle = 'rgba(190,215,255,.6)'; g.lineWidth = .8;
      for (let i = 0; i < 14; i++) { const x = 34 + i * 4.4, y = ((t * 90 + i * 37) % 40) - 18; g.beginPath(); g.moveTo(x, y); g.lineTo(x - 1.5, y + 5); g.stroke(); }
      // the cloud
      for (const [x, y, r, d] of [[44, -22, 10, 0], [56, -27, 13, 1], [70, -24, 12, 2], [82, -20, 9, 3], [62, -18, 11, 4]]) { const wob = Math.sin(t * .9 + d) * 1.2; const gr = g.createRadialGradient(x - 3, y - 4, 1, x, y, r); gr.addColorStop(0, flash ? '#c8d4f0' : '#6a7390'); gr.addColorStop(1, flash ? '#7a86aa' : '#2c3246'); g.fillStyle = gr; g.beginPath(); g.arc(x + wob, y, r, 0, 7); g.fill(); }
      if (flash) { g.save(); g.globalCompositeOperation = 'lighter'; bolt(g, 60, -14, 60, 12, 10, '#bcd6ff', 1.6); g.restore(); }
    } },
  // ---------------- Souls of the Damned ----------------
  { theme: 'Souls of the Damned', tag: 'S1', name: 'Fel-possessed', bar: ['#eaffd9', '#5dff3a', '#0b4d12'],
    blurb: 'Taken by fel fire: the bone gone sickly green-grey, green flame pouring up out of the eye socket and the cracks, and a thin wisp of a soul leaking from the jaw.',
    draw(g, st, dt) {
      const t = st.t, pulse = .75 + .25 * Math.sin(t * 2.6);
      g.save(); g.clip(SKULL_PATH); g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(120,150,110,.75)'; g.fill(SKULL_PATH); g.globalCompositeOperation = 'source-over';
      g.lineCap = 'round'; for (const [w, c] of [[4, `rgba(60,220,30,${.3 * pulse})`], [1.6, `rgba(140,255,90,${.85 * pulse})`]]) { g.strokeStyle = c; g.lineWidth = w; g.stroke(crackPath); }
      g.restore();
      g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, 88, 49, 15, '#2bd61a', .8 * pulse); glowAt(g, 88, 49, 5, '#eaffd9', 1);
      flameTongue(g, 89, 46, 22, 5, t, 0, ['rgba(234,255,217,.95)', 'rgba(93,255,58,.8)', 'rgba(11,77,18,0)']);
      flameTongue(g, 86, 46, 14, 3, t, 2.1, ['rgba(234,255,217,.8)', 'rgba(93,255,58,.6)', 'rgba(11,77,18,0)']);
      g.restore();
      // a soul leaking from the jaw: a pale wisp that curls away
      g.save(); g.globalCompositeOperation = 'lighter';
      for (let i = 0; i < 18; i++) { const f = i / 18, x = 92 + f * 22 + Math.sin(t * 2 + f * 6) * 4, y = 88 - f * 30 + Math.cos(t * 1.5 + f * 5) * 3; glowAt(g, x, y, 4 + f * 3, '#b6ff8a', (1 - f) * .35); }
      g.restore();
    } },
  { theme: 'Souls of the Damned', tag: 'S2', name: 'Screaming soul', bar: ['#eaffd9', '#5dff3a', '#0b4d12'],
    blurb: 'A damned soul trying to tear itself out of the skull: a ghostly green face stretches forward out of the bone, mouth open in a scream, pulling away and snapping back, with fel light in the eye.',
    draw(g, st, dt) {
      const t = st.t, pull = Math.max(0, Math.sin(t * 1.3)) ** 2, dx = pull * 18;
      g.save(); g.clip(SKULL_PATH); g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(150,170,140,.6)'; g.fill(SKULL_PATH); g.restore();
      g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, 88, 49, 10, '#5dff3a', .7);
      // the stretched ghost face, drawn as a soft green shape with dark hollow eyes and a long screaming mouth
      const cx = 86 + dx, cy = 52;
      for (let k = 0; k < 4; k++) glowAt(g, cx - k * dx * .25, cy, 22 - k * 3, '#7dff4a', .18 * (1 - k * .2) * (.4 + pull));
      g.restore();
      g.save(); g.globalAlpha = .35 + pull * .5;
      const face = g.createRadialGradient(cx, cy - 6, 2, cx, cy, 22); face.addColorStop(0, 'rgba(220,255,210,.9)'); face.addColorStop(1, 'rgba(90,220,90,0)');
      g.fillStyle = face; g.beginPath(); g.ellipse(cx, cy, 15, 22 + pull * 6, 0, 0, 7); g.fill();
      g.fillStyle = 'rgba(5,25,8,.9)'; g.beginPath(); g.ellipse(cx - 5, cy - 7, 3, 4.5, 0, 0, 7); g.ellipse(cx + 5, cy - 7, 3, 4.5, 0, 0, 7); g.fill();
      g.beginPath(); g.ellipse(cx, cy + 9, 3.6, 6 + pull * 7, 0, 0, 7); g.fill();
      g.restore();
    } },
  // ---------------- Poster colours ----------------
  { theme: 'Poster colours', tag: 'P1', name: 'Neon glass', poster: true, bar: ['#ffffff', '#c06cff', '#3a1a6a'],
    blurb: 'For posters with no element: a smoked glass skull lit from inside in the poster\u2019s own two main colours (sampled here as violet and teal), with a neon outline, a light sweeping across it and the eye glowing.',
    draw(g, st, dt) {
      const t = st.t, c1 = CTL.c1, c2 = CTL.c2;
      g.save(); g.clip(SKULL_PATH); g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(40,40,60,.9)'; g.fill(SKULL_PATH); g.globalCompositeOperation = 'lighter';
      const inner = g.createLinearGradient(20, 10, 100, 90); inner.addColorStop(0, rgba(c1, .55)); inner.addColorStop(1, rgba(c2, .55)); g.fillStyle = inner; g.fillRect(0, 0, 120, 100);
      const sx = ((t * 40) % 180) - 30, sweep = g.createLinearGradient(sx - 14, 0, sx + 14, 0); sweep.addColorStop(0, 'rgba(255,255,255,0)'); sweep.addColorStop(.5, 'rgba(255,255,255,.35)'); sweep.addColorStop(1, 'rgba(255,255,255,0)'); g.fillStyle = sweep; g.fillRect(0, 0, 120, 100);
      g.restore();
      g.save(); g.globalCompositeOperation = 'lighter'; g.lineJoin = 'round';
      const og = g.createLinearGradient(20, 10, 100, 90); og.addColorStop(0, c1); og.addColorStop(1, c2);
      for (const [w, a] of [[6, .2], [3, .45], [1.2, 1]]) { g.globalAlpha = a; g.strokeStyle = og; g.lineWidth = w; g.stroke(SKULL_PATH); }
      g.globalAlpha = 1; glowAt(g, 88, 49, 11, c2, .8); glowAt(g, 88, 49, 4, '#ffffff', .9);
      g.restore();
    } },
  { theme: 'Poster colours', tag: 'P2', name: 'Painted', poster: true, bar: ['#ffffff', '#c06cff', '#3a1a6a'],
    blurb: 'The bone skull painted in the poster\u2019s colours, like a hand-painted prop: two-tone bands and dots in the poster\u2019s main colours (violet and teal here), glossy varnish, a soft glow in the eye.',
    draw(g, st, dt) {
      const t = st.t, c1 = CTL.c1, c2 = CTL.c2;
      g.save(); g.clip(SKULL_PATH);
      g.globalCompositeOperation = 'multiply';
      const band = g.createLinearGradient(20, 0, 100, 0); band.addColorStop(0, rgba(c1, .8)); band.addColorStop(.5, rgba(c1, .5)); band.addColorStop(1, rgba(c2, .7)); g.fillStyle = band; g.fillRect(0, 0, 120, 100);
      g.globalCompositeOperation = 'source-over';
      g.strokeStyle = rgba(c2, .9); g.lineWidth = 3; g.beginPath(); g.moveTo(30, 20); g.quadraticCurveTo(60, 8, 96, 28); g.stroke();
      g.strokeStyle = rgba(c1, .95); g.lineWidth = 2; g.beginPath(); g.moveTo(22, 46); g.quadraticCurveTo(50, 36, 80, 40); g.stroke();
      g.fillStyle = 'rgba(255,255,255,.85)'; for (const [x, y] of [[40, 30], [48, 28], [56, 27], [34, 56], [42, 58]]) { g.beginPath(); g.arc(x, y, 1.4, 0, 7); g.fill(); }
      const gl = g.createLinearGradient(40, 6, 70, 40); gl.addColorStop(0, 'rgba(255,255,255,.4)'); gl.addColorStop(.5, 'rgba(255,255,255,0)'); g.fillStyle = gl; g.fillRect(0, 0, 120, 100);
      g.restore();
      g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, 88, 49, 9, c2, .6 + .2 * Math.sin(t * 2)); g.restore();
    } },
];

// ===== extras: effect controls, progress, jaw, and the reworked W2 / L1 / F3 =====
Object.assign(CTL, { emAmt: 50, emInt: 50, fxCol: '#ff6a1f', fxInt: 50, fxSize: 50, fxTheme: true, prog: .5, auraTheme: true, eyeTheme: true, c1: '#c06cff', c2: '#3fe0d0' });
const fxK = () => CTL.fxInt / 50, fxS = () => CTL.fxSize / 50, fxC = (L) => (CTL.fxTheme ? L.fx : CTL.fxCol);
const JAW = new Path2D('M52,72 C55,82 60,90 70,93 L97,94 C101,93 103,90 102,86 L100,83 L80,83 C73,83 67,80 62,76 Z');
const NOJAW = new Path2D(); NOJAW.rect(-200, -200, 520, 500); NOJAW.addPath(JAW);
const themeCol = (L) => (L.poster ? CTL.c1 : L.glow || L.fx);
function bloodySkull(g, L, st, x, y, w, face, dt) {
  const k = w / 120; st.t = (st.t || 0) + dt;
  if (!st.img) st.img = skullImage();
  if (!st.img.complete) return;
  st.jaw = 0; st.shake = 0; st.auraBoost = 0; st.dt = dt;
  if (L.update) L.update(st, dt);
  g.save(); g.translate(x + (face < 0 ? w : 0), y); g.scale(k * face, k);
  if (st.shake) g.translate((Math.random() - .5) * st.shake, (Math.random() - .5) * st.shake);
  const ai = Math.min(1, CTL.auraInt / 100 * (1 + st.auraBoost));
  if (ai > 0) { const r = (30 + CTL.auraSize * 1.1) * (1 + st.auraBoost * .25), fl = .92 + .08 * Math.sin(st.t * 3); g.save(); g.globalCompositeOperation = 'lighter'; const ac = CTL.auraTheme ? themeCol(L) : CTL.auraCol; glowAt(g, 60, 50, r * fl, ac, ai * .8); glowAt(g, 60, 50, r * .55, ac, ai * .5); g.restore(); }
  if (L.behind) L.behind(g, st, dt);
  if (st.jaw) {
    g.fillStyle = '#120806'; g.beginPath(); g.moveTo(60, 76); g.lineTo(101, 82); g.lineTo(101, 82 + st.jaw * 40); g.closePath(); g.fill();
    g.save(); g.clip(NOJAW, 'evenodd'); g.drawImage(st.img, 0, 0, 120, 100); g.restore();
    g.save(); g.translate(58, 74); g.rotate(st.jaw); g.translate(-58, -74); g.clip(JAW); g.drawImage(st.img, 0, 0, 120, 100); g.restore();
  } else g.drawImage(st.img, 0, 0, 120, 100);
  L.draw(g, st, dt);
  if (CTL.eyeInt > 0) { const r = 4 + CTL.eyeSize * .3, a = CTL.eyeInt / 100; g.save(); g.globalCompositeOperation = 'lighter'; const ec = CTL.eyeTheme ? themeCol(L) : CTL.eyeCol; glowAt(g, 88, 49, r * 2.2, ec, a * .7); glowAt(g, 88, 49, r, ec, a); glowAt(g, 88, 49, r * .35, '#ffffff', a * .9); g.restore(); }
  g.restore();
}

// ---- W2 Coral reef: a fish swims out of the eye, U-turns, and the jaw eats it ----
const coralBase = LOOKS.find((l) => l.tag === 'W2');
function fishPos(p) {
  if (p < .15) { const f = p / .15; return [88 + f * 8, 49, f]; }
  if (p < .45) { const f = (p - .15) / .3; return [96 + f * 18, 49 - Math.sin(f * Math.PI) * 4, 1]; }
  if (p < .6) { const f = (p - .45) / .15; return [114 + Math.sin(f * Math.PI) * 9, 63 - Math.cos(f * Math.PI) * 14, 1]; }
  if (p < .85) { const f = (p - .6) / .25; return [114 - f * 14, 77 + f * 7, 1]; }
  return null;
}
const coral = { ...coralBase, fx: '#ff8a3d',
  blurb: 'Years on the sea floor: pastel coral on the crown, a sea anemone at the back, shells and bubbles. Every 10 to 15 seconds a little fish swims out of the eye socket, turns back, and the jaw drops open and snaps it up.',
  update(st, dt) {
    if (st.fs === undefined) st.fs = st.t + 1;
    if (st.t - st.fs > 7) st.fs += 10 + Math.random() * 5;
    const p = Math.max(0, (st.t - st.fs) / 7); st.p = p >= 1 ? 1 : p;
    if (st.t < st.fs || p >= 1) { st.jaw = 0; st.p = 1; return; }
    st.jaw = p < .62 ? 0 : p < .8 ? (p - .62) / .18 * .34 : p < .85 ? .34 : p < .9 ? .34 * (1 - (p - .85) / .05) : 0;
  },
  draw(g, st, dt) {
    coralBase.draw.call(this, g, st, dt);
    const a = fishPos(st.p); if (!a) return;
    const b = fishPos(Math.min(.849, st.p + .004)) || a, ang = Math.atan2(b[1] - a[1], b[0] - a[0]);
    const s = a[2] * fxS() * 1.1, wig = Math.sin(st.t * 18) * .35, col = fxC(this);
    g.save(); g.translate(a[0], a[1]); g.rotate(ang); g.scale(s, s);
    g.fillStyle = col; g.beginPath(); g.moveTo(-3.4, 0); g.lineTo(-7, -2.6 + wig); g.lineTo(-7, 2.6 + wig); g.closePath(); g.fill();
    g.beginPath(); g.ellipse(0, 0, 4.4, 2.5, 0, 0, 7); g.fill();
    g.fillStyle = 'rgba(255,255,255,.9)'; g.fillRect(-1, -2.3, 1.1, 4.6);
    g.fillStyle = '#111'; g.beginPath(); g.arc(2.4, -.6, .55, 0, 7); g.fill();
    g.restore();
  } };

// ---- L1 Storm-charged: dense veins, pulses, 20 s build-up, discharge, charred for ~3.5 s ----
const BUILD = 20, BLAST = .4, CHAR = 7, CYCLE = BUILD + BLAST + CHAR;
function makeVeins() {
  const rr = R(17), out = [], starts = [[88, 49], [60, 10], [26, 42], [72, 28], [46, 22], [36, 58], [96, 30], [66, 62], [52, 40], [80, 66]];
  const walk = (x, y, a, n, depth) => { const pts = [[x, y]]; for (let i = 0; i < n; i++) { a += (rr() - .5) * 1.1; x += Math.cos(a) * (4 + rr() * 4); y += Math.sin(a) * (4 + rr() * 4); pts.push([x, y]); if (depth && rr() < .3) walk(x, y, a + (rr() < .5 ? -1 : 1) * .9, 3 + Math.floor(rr() * 3), depth - 1); } out.push(pts); };
  starts.forEach(([x, y]) => { for (let j = 0; j < 2; j++) walk(x, y, rr() * 6.28, 5 + Math.floor(rr() * 4), 2); });
  return out;
}
const VEINS = makeVeins();
const veinPath = new Path2D(); VEINS.forEach((v) => v.forEach(([x, y], i) => (i ? veinPath.lineTo(x, y) : veinPath.moveTo(x, y))));
function along(v, f) { const n = v.length - 1, i = Math.min(n - 1, Math.floor(f * n)), k = f * n - i; return [v[i][0] + (v[i + 1][0] - v[i][0]) * k, v[i][1] + (v[i + 1][1] - v[i][1]) * k]; }
const storm = { ...LOOKS.find((l) => l.tag === 'L1'), fx: '#9cc4ff',
  blurb: 'A skull full of electricity: a dense web of blue-white veins with pulses racing along them. Over 20 seconds the charge builds, the aura swells and the skull shakes harder and harder, then it discharges in a huge blast and sits charred and smoking for 7 seconds before the charge starts again.',
  update(st, dt) {
    st.ph = (st.t % CYCLE); const b = Math.min(1, st.ph / BUILD); st.b = st.ph < BUILD ? b : 0;
    st.shake = st.ph < BUILD ? b * b * 3.2 * fxS() : st.ph < BUILD + BLAST ? 5 * fxS() : 0;
    st.auraBoost = st.ph < BUILD ? b * 1.6 : 0;
  },
  behind(g, st) {
    if (st.ph < BUILD) { g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, 60, 50, (40 + st.b * 40) * fxS(), fxC(this), st.b * .6 * fxK()); g.restore(); }
  },
  draw(g, st, dt) {
    const col = fxC(this), K = fxK(), S = fxS(), t = st.t, ph = st.ph, b = st.b;
    const charA = ph < BUILD + BLAST ? 0 : ph < CYCLE - .7 ? 1 : (CYCLE - ph) / .7;
    const live = 1 - charA;
    g.save(); g.clip(SKULL_PATH);
    g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(110,120,150,.7)'; g.fill(SKULL_PATH);
    if (charA) { g.fillStyle = `rgba(40,28,22,${.9 * charA})`; g.fill(SKULL_PATH); }
    g.globalCompositeOperation = 'source-over';
    if (live > .01) {
      const hum = (.6 + .4 * Math.sin(t * (13 + b * 20)) * Math.sin(t * 7)) * (0.6 + b * .6) * live;
      g.lineCap = 'round'; g.lineJoin = 'round';
      for (const [w, a] of [[4 * S, .25], [1.8 * S, .8], [.7 * S, 1]]) { g.strokeStyle = w < 1 * S ? `rgba(255,255,255,${Math.min(1, hum * K)})` : rgba(col, Math.min(1, a * hum * K)); g.lineWidth = w; g.stroke(veinPath); }
    }
    if (charA) { g.strokeStyle = `rgba(255,120,40,${.5 * charA})`; g.lineWidth = .8; g.stroke(veinPath); }
    g.restore();
    // pulses racing along the veins
    st.pul = st.pul || [];
    if (live > .5 && Math.random() < dt * (8 + b * 40) * K) st.pul.push({ v: VEINS[Math.floor(Math.random() * VEINS.length)], f: 0, sp: 1.5 + Math.random() * 2 + b * 2 });
    g.save(); g.globalCompositeOperation = 'lighter';
    st.pul = st.pul.filter((p) => { p.f += dt * p.sp; if (p.f >= 1) return false; const [x, y] = along(p.v, p.f); glowAt(g, x, y, 4 * S, col, .9 * live); glowAt(g, x, y, 1.4 * S, '#ffffff', live); return true; });
    // arcs jumping across the skull, more often as the charge builds
    st.arc = (st.arc || 0) - dt;
    if (live > .5 && st.arc <= 0) { st.arc = (.9 - b * .75) * Math.random() + .08; const pts = [[88, 49], [60, 10], [30, 40], [92, 86], [104, 60], [70, 4], [20, 58], [48, 24]]; st.from = pts[Math.floor(Math.random() * 8)]; st.to = pts[Math.floor(Math.random() * 8)]; st.flash = .12; }
    if (st.flash > 0) { st.flash -= dt; bolt(g, st.from[0], st.from[1], st.to[0], st.to[1], 10, col, 1.2 * S); }
    glowAt(g, 88, 49, 12 * S, col, (.5 + b * .5) * live); glowAt(g, 88, 49, 4 * S, '#ffffff', live);
    // the discharge
    if (ph >= BUILD && ph < BUILD + BLAST) {
      const f = 1 - (ph - BUILD) / BLAST;
      glowAt(g, 60, 50, 120 * S, col, f * K); glowAt(g, 60, 50, 50 * S, '#ffffff', f);
      for (let i = 0; i < 10; i++) { const a = i / 10 * 6.28 + Math.random() * .3; bolt(g, 60, 48, 60 + Math.cos(a) * 110 * S, 48 + Math.sin(a) * 90 * S, 22, col, 1.8 * S); }
    }
    g.restore();
    // smoke while charred
    if (charA) sparks(st, 'smk', 18, () => ({ x: 25 + Math.random() * 75, y: 10 + Math.random() * 50, r: 3, life: 1 }), (p, d) => { p.y -= 14 * d; p.x -= 4 * d; p.r += 7 * d; p.life -= d * .5; }, g, dt, (g2, p) => { g2.fillStyle = `rgba(70,66,64,${p.life * .35 * charA})`; g2.beginPath(); g2.arc(p.x, p.y, p.r, 0, 7); g2.fill(); });
    else st.smk = (st.smk || []).filter((p) => { p.y -= 14 * dt; p.r += 7 * dt; p.life -= dt; if (p.life <= 0) return false; g.fillStyle = `rgba(70,66,64,${p.life * .3})`; g.beginPath(); g.arc(p.x, p.y, p.r, 0, 7); g.fill(); return true; });
  } };

// ---- F3 Inferno: bigger fire, jets off the back, eye jet near max, teeth glow and lava drips that grow with progress ----
const infBase = LOOKS.find((l) => l.tag === 'F3');
const RIM = [[96, 26], [88, 16], [78, 10], [68, 7], [58, 7], [48, 9], [38, 13], [29, 20], [22, 30], [17, 42], [18, 54], [24, 64], [34, 72]];
const OUTSIDE = new Path2D(); OUTSIDE.rect(-300, -300, 720, 700); OUTSIDE.addPath(SKULL_PATH);
const TEETH = new Path2D(); TEETH.rect(78, 72, 26, 22);
function emberDot(g, p, I, col, t) {
  const fl = .6 + .4 * Math.sin(t * 20 + p.ph * 5), a = Math.min(1, p.life * fl * I);
  g.save(); g.globalCompositeOperation = 'lighter';
  glowAt(g, p.x, p.y, p.r * (2.5 + I), col, a * .7);
  g.fillStyle = p.life > .55 ? `rgba(255,240,190,${a})` : `rgba(255,160,60,${a})`; g.beginPath(); g.arc(p.x, p.y, p.r * .6, 0, 7); g.fill();
  g.restore();
}
const inferno = { ...infBase, fx: '#ff6a1f',
  blurb: 'Completely engulfed, and it gets fiercer as the bar fills: a roaring wall of fire around the head, jets of flame blasting out of the back from time to time, the teeth glowing hotter and hotter, molten lava dripping from the mouth in bigger and faster drops, near the end a jet of fire roaring out of the eye socket, and embers of all sizes flaring out behind the flames and from the eye.',
  behind(g, st) {
    const t = st.t, P = CTL.prog, K = fxK(), S = fxS(), col = fxC(this);
    g.save(); g.clip(OUTSIDE, 'evenodd'); g.globalCompositeOperation = 'lighter';
    RIM.forEach(([x, y], i) => { g.save(); g.translate(x, y); g.rotate(-.6 - (i / RIM.length) * .5); flameTongue(g, 0, 14, (52 + (i % 3) * 16) * S * (.8 + P * .6) * TAP(i, RIM.length), 11 * S * TAP(i, RIM.length), t, i * 1.9 + .5, ['rgba(255,220,120,' + (.55 * K) + ')', rgba(col, Math.min(1, .55 * K)), 'rgba(120,10,0,0)']); g.restore(); });
    // jets of flame shooting out of the back of the head
    st.jt = (st.jt ?? 1) - st.dt; if (st.jt <= 0) { st.jt = (1.4 + Math.random() * 2.6) * (1.2 - P * .7); st.jet = 1; st.jy = 30 + Math.random() * 24; }
    if (st.jet > 0) { st.jet -= st.dt * 1.6; const e = Math.sin(st.jet * Math.PI); g.save(); g.translate(20, st.jy); g.rotate(-Math.PI / 2 - .25); flameTongue(g, 0, 0, 70 * S * e * (.7 + P * .6), 8 * S * e, t * 2, 0, ['rgba(255,250,220,' + Math.min(1, .9 * K) + ')', rgba(col, Math.min(1, .8 * K)), 'rgba(140,10,0,0)']); g.restore(); }
    g.restore();
    // embers flaring out behind the fire, mixed sizes
    const EA = CTL.emAmt / 50, EI = CTL.emInt / 50;
    sparks(st, 'emb', 40 * EA * (.7 + P * .6), () => { const [x, y] = RIM[Math.floor(Math.random() * RIM.length)], big = Math.random() < .15; return { x: x - 6, y, vx: -30 - Math.random() * 60, vy: -20 - Math.random() * 50, r: big ? 2.2 + Math.random() * 1.8 : .5 + Math.random() * 1.4, life: 1, ph: Math.random() * 6, dec: .5 + Math.random() * .8 }; },
      (p, d) => { p.x += p.vx * d; p.y += p.vy * d; p.vy += 12 * d; p.vx *= 1 - d * .4; p.life -= d * p.dec; }, g, st.dt, (g2, p) => emberDot(g2, p, EI, col, st.t));
  },
  draw(g, st, dt) {
    infBase.draw.call(this, g, st, dt);
    { const EA = CTL.emAmt / 50, EI = CTL.emInt / 50;
      sparks(st, 'eemb', 12 * EA, () => ({ x: 90, y: 47, vx: 10 + Math.random() * 30, vy: -25 - Math.random() * 35, r: .4 + Math.random() * 1.6, life: 1, ph: Math.random() * 6, dec: .9 + Math.random() }), (p, d) => { p.x += p.vx * d; p.y += p.vy * d; p.life -= d * p.dec; }, g, dt, (g2, p) => emberDot(g2, p, EI, fxC(this), st.t)); }
    const t = st.t, P = CTL.prog, K = fxK(), S = fxS(), col = fxC(this);
    // teeth glow, hotter as the bar fills
    g.save(); g.clip(SKULL_PATH); g.clip(TEETH); g.globalCompositeOperation = 'lighter';
    g.fillStyle = rgba(col, Math.min(1, P * .9 * K)); g.fillRect(78, 72, 26, 22);
    g.fillStyle = `rgba(255,240,190,${Math.min(1, Math.max(0, P - .5) * 1.2 * K)})`; g.fillRect(78, 72, 26, 22);
    g.restore();
    g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, 91, 84, 16 * S, col, P * .6 * K); g.restore();
    // jet of fire from the eye socket near the end
    if (P > .8) { const e = (P - .8) / .2; g.save(); g.globalCompositeOperation = 'lighter'; g.translate(90, 49); g.rotate(Math.PI / 2 - .15); flameTongue(g, 0, 0, 46 * S * e, 6 * S * e, t * 1.6, 1, ['rgba(255,255,230,.95)', rgba(col, .85), 'rgba(150,10,0,0)']); g.restore(); }
    // lava leaking from the mouth
    sparks(st, 'lava', (1 + P * 14) * K, () => ({ x: 82 + Math.random() * 18, y: 88 + Math.random() * 4, v: 0, r: (.8 + P * 2.6 * Math.random() + P) * S, life: 1, hang: .2 + Math.random() * .4 }), (p, d) => { if (p.hang > 0) { p.hang -= d; p.y += 4 * d; } else { p.v += 160 * d; p.y += p.v * d; } p.life -= d * .55; }, g, dt,
      (g2, p) => { const hot = p.life; g2.fillStyle = `rgb(255,${Math.round(90 + 150 * hot * hot)},${Math.round(40 * hot)})`; g2.shadowColor = col; g2.shadowBlur = 6; g2.beginPath(); g2.ellipse(p.x, p.y, p.r, p.r * (1.2 + Math.min(1.4, p.v / 120)), 0, 0, 7); g2.fill(); g2.shadowBlur = 0; });
  } };
// ---- S1 Fel-possessed: builds for 20 s into a horned, fel-crowned demon, holds 10 s, resets ----
const felBase = LOOKS.find((l) => l.tag === 'S1');
const FB = 20, FH = 10, FC = FB + FH + 1.2;
function horn(g, bx, by, grow, S, far, dir = 1) {
  // centre line: up and back, then curling up and forward at the tip
  const P = [[bx, by], [bx - dir * 30 * S, by - 6 * S], [bx - dir * 34 * S, by - 46 * S], [bx - dir * 16 * S, by - 62 * S]];
  const at = (u) => { const v = 1 - u; return [0, 1].map((i) => v * v * v * P[0][i] + 3 * v * v * u * P[1][i] + 3 * v * u * u * P[2][i] + u * u * u * P[3][i]); };
  const n = 28, L = [], Rr = [];
  for (let i = 0; i <= n; i++) { const u = i / n * grow, [x, y] = at(u), [x2, y2] = at(Math.min(1, u + .01)), a = Math.atan2(y2 - y, x2 - x) + Math.PI / 2, w = (6.5 * (1 - i / n) + .3) * S; L.push([x + Math.cos(a) * w, y + Math.sin(a) * w]); Rr.push([x - Math.cos(a) * w, y - Math.sin(a) * w]); }
  const pts = L.concat(Rr.reverse());
  const gr = g.createLinearGradient(bx, by, bx - 30 * S, by - 80 * S); gr.addColorStop(0, far ? '#2a2620' : '#5a4c3e'); gr.addColorStop(1, far ? '#14120e' : '#1e1814');
  g.fillStyle = gr; g.beginPath(); pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y))); g.closePath(); g.fill();
  if (!far) { g.save(); g.globalCompositeOperation = 'lighter'; g.strokeStyle = 'rgba(120,255,80,.35)'; g.lineWidth = 3; g.stroke(); g.strokeStyle = 'rgba(190,255,150,.9)'; g.lineWidth = 1; g.stroke(); g.restore();
    g.strokeStyle = 'rgba(0,0,0,.45)'; g.lineWidth = .7; for (let i = 3; i < n * grow; i += 3) { g.beginPath(); g.moveTo(...L[i]); g.lineTo(...Rr[Rr.length - 1 - i]); g.stroke(); } }
  return at(grow);
}
// where the fel fire takes hold, in the order it spreads: crown first, then back and brow, then the face and jaw
function felEmber(g, p, I, col, t) {
  const fl = .6 + .4 * Math.sin(t * 20 + p.ph * 5), a = Math.min(1, p.life * fl * I);
  g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, p.x, p.y, p.r * (2.5 + I), col, a * .7);
  g.fillStyle = `rgba(230,255,210,${a})`; g.beginPath(); g.arc(p.x, p.y, p.r * .6, 0, 7); g.fill(); g.restore();
}
const ENGULF = [[60, 10, 14], [50, 12, 13], [70, 10, 13], [40, 16, 12], [80, 14, 12], [30, 22, 12], [56, 24, 10], [72, 24, 10], [90, 22, 11], [24, 32, 12], [44, 30, 10], [64, 36, 9], [20, 44, 12], [38, 44, 10], [98, 32, 10], [52, 46, 9], [76, 40, 9], [22, 56, 11], [44, 58, 9], [62, 58, 9], [102, 44, 9], [30, 66, 10], [80, 62, 9], [104, 56, 8], [96, 70, 9], [66, 70, 8], [86, 78, 8], [62, 84, 8], [76, 90, 8], [92, 92, 8]];
const FEL_RIDGE = [[96, 26], [88, 16], [78, 10], [68, 7], [58, 7], [48, 9], [38, 13], [29, 20], [22, 30], [17, 42], [18, 54]];
const fel = { ...felBase, fx: '#5dff3a',
  blurb: 'Taken by fel fire, and it keeps building: over 20 seconds a great arch of green fel flame rises around the top and back of the head, huge demon horns grow out of the skull, a huge crown of fel fire takes shape, a flaming ring floating above the head between the horns, the skull is slowly engulfed in a roaring wall of fel fire like the Inferno skull, spreading from the crown outwards, more and more fel cracks split the bone and the eyes blaze. It holds the full demon form for 10 seconds, then resets.',
  update(st) { const ph = st.t % FC; st.fg = ph < FB ? ph / FB : ph < FB + FH ? 1 : 1 - (ph - FB - FH) / 1.2; st.fg = st.fg * st.fg * (3 - 2 * st.fg); st.auraBoost = 0; },
  behind(g, st) {
    const G = st.fg, S = fxS(), K = fxK(), col = fxC(this), t = st.t;
    if (G < .02) return;
    g.save(); g.globalCompositeOperation = 'lighter';
    // the arch of fel fire around the top and back
    const n = 9, shown = Math.ceil(n * Math.min(1, G * 1.3));
    for (let i = 0; i < shown; i++) { const a = Math.PI * (1.4 + i / (n - 1) * .24), x = 62 + Math.cos(a) * 46 * S, y = 54 + Math.sin(a) * 46 * S; g.save(); g.translate(x, y); g.rotate(a + Math.PI / 2); flameTongue(g, 0, 6, (10 + 18 * G) * S * (.8 + .3 * Math.sin(i * 1.7)), 5 * S, t, i * 1.3, ['rgba(234,255,217,' + Math.min(1, .7 * K) + ')', rgba(col, Math.min(1, .65 * K * G)), 'rgba(11,77,18,0)']); g.restore(); }
    glowAt(g, 58, 34, 46 * S, col, .3 * G * K);
    g.restore();
    st.fTip = horn(g, 80, 14, Math.min(1, G * 1.15), S * .95, false, -1);
    // engulfed: the Inferno wall of flame in fel colours, spreading from the crown outwards as it builds
    const E = Math.min(1, Math.max(0, (G - .05) / .9));
    if (E > 0) {
      g.save(); g.clip(OUTSIDE, 'evenodd'); g.globalCompositeOperation = 'lighter';
      const n = RIM.length, mid = (n - 1) / 2;
      RIM.forEach(([x, y], i) => {
        const reach = Math.max(0, Math.min(1, E * 1.6 - Math.abs(i - mid) / mid * .6)); if (!reach) return;
        const tap = TAP(i, n);
        g.save(); g.translate(x, y); g.rotate(-.6 - (i / n) * .5); flameTongue(g, 0, 14, (52 + (i % 3) * 16) * S * reach * 1.3 * tap, 11 * S * tap, t, i * 1.9 + .5, ['rgba(234,255,217,' + (.55 * K) + ')', rgba(col, Math.min(1, .6 * K)), 'rgba(11,77,18,0)']); g.restore();
        g.save(); g.translate(x, y); g.rotate(-.55 - (i / n) * .5); flameTongue(g, 0, 12, (48 + (i % 3) * 14) * S * reach * 1.3 * tap, 9 * tap, t, i * 1.3, ['rgba(220,255,200,.8)', rgba(col, .7), 'rgba(11,77,18,0)']); g.restore();
        g.save(); g.translate(x, y); g.rotate(-.5 - (i / n) * .45); flameTongue(g, 0, 9, (28 + (i % 2) * 10) * S * reach * 1.3 * tap, 5 * tap, t, i * 2.1 + 1, ['rgba(245,255,235,.9)', 'rgba(170,255,120,.75)', 'rgba(60,200,40,0)']); g.restore();
      });
      g.restore();
      sparks(st, 'femb', 30 * E * CTL.emAmt / 50, () => { const [x, y] = RIM[Math.floor(Math.random() * RIM.length)], big = Math.random() < .15; return { x: x - 6, y, vx: -30 - Math.random() * 60, vy: -20 - Math.random() * 50, r: big ? 2.2 + Math.random() * 1.8 : .5 + Math.random() * 1.4, life: 1, ph: Math.random() * 6, dec: .5 + Math.random() * .8 }; },
        (p, d) => { p.x += p.vx * d; p.y += p.vy * d; p.vy += 12 * d; p.vx *= 1 - d * .4; p.life -= d * p.dec; }, g, st.dt, (g2, p) => felEmber(g2, p, CTL.emInt / 50, col, t));
    }
  },
  draw(g, st, dt) {
    const G = st.fg, S = fxS(), K = fxK(), col = fxC(this), t = st.t;
    felBase.draw.call(this, g, st, dt);
    // more fel cracks as it builds
    const nV = Math.floor(VEINS.length * Math.max(0, G - .2) / .8);
    if (nV) { g.save(); g.clip(SKULL_PATH); g.lineCap = 'round'; g.lineJoin = 'round';
      for (const [w, a] of [[2.2, .22], [.8, .8]]) { g.strokeStyle = rgba(col, a * (.75 + .25 * Math.sin(t * 3)) * K * (1 - .5 * G)); g.lineWidth = w * S; g.beginPath(); for (let i = 0; i < nV; i++) VEINS[i].forEach(([x, y], j) => (j ? g.lineTo(x, y) : g.moveTo(x, y))); g.stroke(); }
      g.restore(); }
    // slowly engulfed: fel fire spreads from the crown down over the whole skull
    if (G > .05) {
      const E = Math.min(1, (G - .05) / .9);
      g.save(); g.clip(SKULL_PATH); g.globalCompositeOperation = 'lighter';
      const wash = g.createLinearGradient(0, 0, 0, 100); wash.addColorStop(0, rgba(col, .55 * E * K * (1 - .6 * E))); wash.addColorStop(Math.min(1, E), rgba(col, .25 * E * K * (1 - .6 * E))); wash.addColorStop(1, rgba(col, 0)); g.fillStyle = wash; g.fillRect(0, 0, 120, 100);
      g.restore();
    }
    // the near horn
    let nTip = null;
    if (G > .02) { nTip = horn(g, 46, 14, Math.min(1, G * 1.15), S, false); g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, nTip[0], nTip[1], 6 * S, col, G * .8 * K); g.restore(); }
    // the huge floating crown: a ring of fel fire hovering above the head between the horns, flaming tips all round
    if (G > .35) {
      const c = Math.min(1, (G - .35) / .5), cx = 62, cy = -16 + (1 - c) * 10, rx = 28 * S, ry = 6.5 * S, bob = Math.sin(t * 1.6) * 1.2;
      g.save(); g.globalCompositeOperation = 'lighter'; g.globalAlpha = c;
      glowAt(g, cx, cy + bob - 8 * S, 38 * S, col, .35 * K);
      const N = 18, pts = [];
      for (let i = 0; i < N; i++) { const a = i / N * Math.PI * 2; pts.push({ a, x: cx + Math.cos(a) * rx, y: cy + bob + Math.sin(a) * ry, back: Math.sin(a) < 0 }); }
      const tongue = (p, i) => { const m = Math.pow(1 - Math.abs(Math.cos(p.a)), 1.6), h = (14 + 44 * m + 4 * Math.sin(i * 2.3)) * S * c; flameTongue(g, p.x, p.y, h, 3.6 * S, t, i * 1.9, [p.back ? 'rgba(220,255,200,.6)' : 'rgba(250,255,240,.95)', rgba(col, p.back ? .55 : .85), 'rgba(11,77,18,0)']); };
      pts.filter((p) => p.back).forEach(tongue);
      // the ring itself
      g.lineWidth = 3.4 * S; g.strokeStyle = rgba(col, .9); g.beginPath(); g.ellipse(cx, cy + bob, rx, ry, 0, 0, 7); g.stroke();
      g.lineWidth = 1.1 * S; g.strokeStyle = 'rgba(240,255,225,.95)'; g.stroke();
      pts.filter((p) => !p.back).forEach(tongue);
      g.restore();
    }
    // flame trails streaming back from the eye
    sparks(st, 'trail', 50 * (.3 + .7 * G), () => ({ x: 88 + (Math.random() - .5) * 3, y: 47 + (Math.random() - .5) * 3, vx: -40 - Math.random() * 30, vy: -14 - Math.random() * 14, r: (2.2 + Math.random() * 2) * S * (.6 + .5 * G), life: 1, ph: Math.random() * 6 }),
      (p, d) => { p.x += p.vx * d; p.y += p.vy * d + Math.sin(st.t * 9 + p.ph) * .3; p.life -= d * 1.6; }, g, dt,
      (g2, p) => { g2.save(); g2.globalCompositeOperation = 'lighter'; glowAt(g2, p.x, p.y, p.r * (1.4 + (1 - p.life)), col, p.life * .55 * K); glowAt(g2, p.x, p.y, p.r * .5 * p.life, '#eaffd9', p.life * .7); g2.restore(); });
    // eyes blazing
    g.save(); g.globalCompositeOperation = 'lighter'; glowAt(g, 88, 49, (8 + 9 * G) * S, col, (.5 + .5 * G) * K); glowAt(g, 88, 49, (3 + 5 * G) * S, '#ffffff', .6 + .4 * G); g.restore();
  } };
for (const L of [coral, storm, inferno, fel]) LOOKS[LOOKS.findIndex((l) => l.tag === L.tag)] = L;

function TAP(i, n) { const f = Math.sin(Math.PI * (i + .5) / n); return .12 + .88 * Math.pow(f, 1.4); }
// a flamethrower jet: from the nozzle (mid) out to the skull (tip), widening and roaring
function flameJet(g, tip, mid, y, cols, st, dt) {
  const t = (st.t = (st.t || 0) + dt), L = mid - tip; if (L < 4) return;
  g.save(); g.globalCompositeOperation = 'lighter';
  const layer = (wMax, col, a, wob, sp) => {
    const n = 30, top = [], bot = [];
    for (let i = 0; i <= n; i++) { const f = i / n, x = mid - f * L, w = (1.5 + wMax * Math.pow(f, .7)) * (1 + .25 * Math.sin(t * sp + f * 14)), c = Math.sin(t * sp * .7 - f * 9) * wob * f; top.push([x, y + c - w]); bot.push([x, y + c + w * .8]); }
    g.fillStyle = col; g.globalAlpha = a; g.beginPath(); top.concat(bot.reverse()).forEach(([x, yy], i) => (i ? g.lineTo(x, yy) : g.moveTo(x, yy))); g.closePath(); g.fill(); g.globalAlpha = 1;
  };
  layer(11, cols[2], .55, 3, 9); layer(7, cols[1], .75, 2, 13); layer(3, cols[0], .9, 1, 17);
  // puffs rolling down the jet
  st.puff = st.puff || [];
  if (Math.random() < dt * 30) st.puff.push({ f: 0, ph: Math.random() * 6, r: 2 + Math.random() * 3 });
  st.puff = st.puff.filter((p) => { p.f += dt * 1.6; if (p.f > 1) return false; const x = mid - p.f * L, yy = y + Math.sin(t * 9 + p.ph) * 3 * p.f; glowAt(g, x, yy, p.r * (1 + p.f * 2.5), cols[1], (1 - p.f) * .7); return true; });
  glowAt(g, mid, y, 7, cols[0], .9);
  g.restore();
}
// an energetic lightning bar: crackling core plus arcs of different sizes jumping along it
function stormBar(g, tip, mid, y, st, dt) {
  const t = (st.t = (st.t || 0) + dt), col = '#9cc4ff';
  const fl = .7 + .3 * Math.random();
  const gr = g.createLinearGradient(tip, 0, mid, 0); gr.addColorStop(0, '#d8e8ff'); gr.addColorStop(1, '#2a3a8a');
  g.save(); g.shadowColor = col; g.shadowBlur = 10 + fl * 10; g.globalAlpha = .75 + fl * .25; g.fillStyle = gr; g.beginPath(); if (g.roundRect) g.roundRect(tip, y - 3, mid - tip, 6, 3); else g.rect(tip, y - 3, mid - tip, 6); g.fill(); g.restore();
  g.save(); g.globalCompositeOperation = 'lighter';
  // jagged core redrawn every frame
  g.strokeStyle = 'rgba(255,255,255,.9)'; g.lineWidth = 1; g.beginPath(); for (let x = mid; x >= tip; x -= 6) { const yy = y + (Math.random() - .5) * 3; x === mid ? g.moveTo(x, yy) : g.lineTo(x, yy); } g.stroke();
  // arcs
  st.arcs = st.arcs || [];
  if (Math.random() < dt * 5) { const len = 10 + Math.random() * 60, x0 = tip + Math.random() * Math.max(1, mid - tip - len); st.arcs.push({ x0, x1: x0 + len, h: (6 + Math.random() * 22) * (Math.random() < .5 ? -1 : 1) * (len / 50 + .4), life: .12 + Math.random() * .15 }); }
  st.arcs = st.arcs.filter((a) => { a.life -= dt; if (a.life <= 0) return false;
    const pts = []; for (let i = 0; i <= 10; i++) { const f = i / 10; pts.push([a.x0 + (a.x1 - a.x0) * f + (Math.random() - .5) * 3, y - Math.sin(f * Math.PI) * a.h + (Math.random() - .5) * 4]); }
    g.lineCap = 'round'; g.lineJoin = 'round';
    for (const [w, c] of [[5, rgba(col, .25)], [2, rgba(col, .7)], [.8, 'rgba(255,255,255,.95)']]) { g.strokeStyle = c; g.lineWidth = w; g.beginPath(); pts.forEach(([x, yy], i) => (i ? g.lineTo(x, yy) : g.moveTo(x, yy))); g.stroke(); }
    return true; });
  if (Math.random() < .3) glowAt(g, tip + Math.random() * (mid - tip), y, 8, col, .5);
  g.restore();
}

for (const tag of ['F2', 'W1', 'L2', 'S2']) LOOKS.splice(LOOKS.findIndex((l) => l.tag === tag), 1);   // takes not picked
function skullImage() {
  const im = new Image();
  im.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(skullSVG('bone', ['#fff', '#ccc', '#999', '#333'], 't' + Math.random().toString(36).slice(2), 0, 50).replace('<svg ', '<svg xmlns="http://www.w3.org/2000/svg" width="480" height="400" '));
  return im;
}
LOOKS.find((l) => l.tag === 'F1').glow = '#ff6a1f';
LOOKS.find((l) => l.tag === 'F3').glow = '#ff6a1f';
LOOKS.find((l) => l.tag === 'W2').glow = '#4aa8ff';
const BY_KEY = { molten: 'F1', inferno: 'F3', coral: 'W2', storm: 'L1', fel: 'S1', neon: 'P1', painted: 'P2' };
// which looks each theme can use; the first is the default
export const THEMED_SKULLS = {
  fire: [['inferno', 'Inferno'], ['molten', 'Molten']],
  water: [['coral', 'Coral reef']],
  lightning: [['storm', 'Storm-charged']],
  specter: [['fel', 'Fel-possessed']],
  poster: [['neon', 'Neon glass'], ['painted', 'Painted']],
};
const hex = (v, d) => (/^#[0-9a-f]{6}$/i.test(v || '') ? v : d);
const num = (v, d) => (Number.isFinite(Number(v)) ? Number(v) : d);
// opts: the skull bar's settings; tone: the side's colour (Poster colours); prog: how far the bar has run (0 to 1)
function setCtl(o, tone, prog) {
  Object.assign(CTL, {
    auraCol: hex(o.auraCol, '#ff6a1f'), auraTheme: o.auraTheme !== false, auraSize: num(o.auraSize, 50), auraInt: num(o.auraInt, 40),
    eyeCol: hex(o.eyeCol, '#ffb347'), eyeTheme: o.eyeTheme !== false, eyeSize: num(o.eyeSize, 40), eyeInt: num(o.eyeInt, 50),
    fxCol: hex(o.fxCol, '#ff6a1f'), fxTheme: o.fxTheme !== false, fxSize: num(o.fxSize, 50), fxInt: num(o.fxInt, 50),
    emAmt: num(o.emAmt, 50), emInt: num(o.emInt, 50), prog: Math.max(0, Math.min(1, prog || 0)),
  });
  const c = hex(tone, '#c06cff'), n = parseInt(c.slice(1), 16), r = n >> 16, gg = (n >> 8) & 255, b = n & 255;
  // the second poster colour: the first turned a third of the way round the colour wheel, so the two always differ
  CTL.c1 = c; CTL.c2 = '#' + [gg, b, r].map((v) => v.toString(16).padStart(2, '0')).join('');
}
// draws one themed skull, w wide, with its top-left at (x, y); face 1 looks right, -1 left
export function themedSkull(g, st, key, x, y, w, face, dt, opts, tone, prog) {
  const L = LOOKS.find((l) => l.tag === BY_KEY[key]); if (!L) return;
  setCtl(opts || {}, tone, prog);
  if (st.key !== key) { for (const k of Object.keys(st)) delete st[k]; st.key = key; }
  g.save(); g.globalCompositeOperation = 'source-over'; g.globalAlpha = 1;
  bloodySkull(g, L, st, x, y, w, face, dt);
  g.restore();
}
// the bar for a themed side, tip on the left; false when the theme keeps the plain bar
export function themedBar(g, st, theme, tip, mid, y, dt, bS) {
  if (theme !== 'fire' && theme !== 'specter' && theme !== 'lightning') return false;
  g.save(); g.translate(0, y); g.scale(1, bS);
  if (theme === 'fire') flameJet(g, tip, mid, 0, ['#fff6d0', '#ff8a1f', '#b01800'], st, dt);
  else if (theme === 'specter') flameJet(g, tip, mid, 0, ['#f4ffe8', '#5dff3a', '#0b6d18'], st, dt);
  else stormBar(g, tip, mid, 0, st, dt);
  g.restore();
  return true;
}
