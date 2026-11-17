// Drawing pieces shared by the poster themes (fxthemes.js) and the skull bar (skullfx.js): bark, sawn log ends, leaves
// and vines for Nature; glossy drips, falling drops, the drip curtain and the flowing blood bar for Blood.
const rnd = (a, b) => a + Math.random() * (b - a);

// ---- Nature -------------------------------------------------------------------------------------------------------------
// a strip of weathered log bark: grey-brown, with grain, knots and cracks; baked once and used as a repeating pattern
let barkCanvas = null;
export function bark() {
  if (barkCanvas) return barkCanvas;
  const w = 400, h = 16, c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d');
  const gr = g.createLinearGradient(0, 0, 0, h); gr.addColorStop(0, '#5a4632'); gr.addColorStop(0.5, '#3c2c1e'); gr.addColorStop(1, '#22180f');
  g.fillStyle = gr; g.fillRect(0, 0, w, h);
  for (let i = 0; i < w * h / 40; i++) { g.fillStyle = `rgba(${Math.random() < 0.5 ? '20,10,4' : '255,220,170'},${rnd(0.04, 0.14)})`; g.fillRect(rnd(0, w), rnd(0, h), rnd(4, 26), rnd(0.6, 1.6)); }
  for (let i = 0; i < w / 18; i++) { const x = rnd(0, w), y = rnd(h * 0.2, h * 0.8); g.strokeStyle = 'rgba(25,12,5,.55)'; g.lineWidth = 1; g.beginPath(); g.ellipse(x, y, rnd(3, 6), rnd(1.6, 3), 0, 0, 7); g.stroke(); g.fillStyle = 'rgba(40,20,8,.6)'; g.beginPath(); g.ellipse(x, y, 1.6, 1, 0, 0, 7); g.fill(); }
  for (let i = 0; i < w / 10; i++) { g.strokeStyle = 'rgba(15,6,2,.5)'; g.lineWidth = 0.8; g.beginPath(); const x = rnd(0, w), y = rnd(0, h); g.moveTo(x, y); g.lineTo(x + rnd(6, 20), y + rnd(-1.5, 1.5)); g.stroke(); }
  return (barkCanvas = c);
}
// the sawn end of a log: pale wood with growth rings and a dark bark rim
export function logEnd(g, x, y, r) {
  g.fillStyle = '#2a1d12'; g.beginPath(); g.arc(x, y, r + 1.5, 0, 7); g.fill();
  const gr = g.createRadialGradient(x - r * 0.2, y - r * 0.2, 0, x, y, r); gr.addColorStop(0, '#e2c69a'); gr.addColorStop(1, '#a8824f');
  g.fillStyle = gr; g.beginPath(); g.arc(x, y, r, 0, 7); g.fill();
  g.strokeStyle = 'rgba(110,70,30,.7)'; g.lineWidth = 0.7; for (let k = r * 0.25; k < r; k += r * 0.22) { g.beginPath(); g.arc(x + 0.3, y + 0.2, k, 0, 7); g.stroke(); }
  g.strokeStyle = 'rgba(70,40,15,.7)'; g.beginPath(); g.moveTo(x, y); g.lineTo(x + r * 0.8, y - r * 0.3); g.stroke();
}
export const LEAF = [['#9ccf5a', '#3f7a22'], ['#c3d65c', '#5f8a2a'], ['#79b84a', '#2d5e1a'], ['#d8b24a', '#8a5a1e'], ['#c9743a', '#6e2e14']];
export function leaf(g, x, y, len, ang, col, vein) {
  g.save(); g.translate(x, y); g.rotate(ang);
  const gr = g.createLinearGradient(0, -len * 0.3, 0, len * 0.3); gr.addColorStop(0, col[0]); gr.addColorStop(1, col[1]);
  g.fillStyle = gr; g.beginPath(); g.moveTo(0, 0); g.bezierCurveTo(len * 0.3, -len * 0.42, len * 0.75, -len * 0.3, len, 0); g.bezierCurveTo(len * 0.75, len * 0.3, len * 0.3, len * 0.42, 0, 0); g.fill();
  if (vein) {
    g.strokeStyle = 'rgba(0,0,0,.28)'; g.lineWidth = 0.6; g.beginPath(); g.moveTo(0, 0); g.lineTo(len * 0.92, 0);
    for (let i = 1; i < 4; i++) { g.moveTo(len * i * 0.22, 0); g.lineTo(len * (i * 0.22 + 0.1), -len * 0.14); g.moveTo(len * i * 0.22, 0); g.lineTo(len * (i * 0.22 + 0.1), len * 0.14); }
    g.stroke();
  }
  g.restore();
}
export function strokePts(g, pts, w, col) {
  if (pts.length < 2) return;
  g.beginPath(); g.moveTo(pts[0][0], pts[0][1]); for (const p of pts) g.lineTo(p[0], p[1]);
  g.lineWidth = w; g.strokeStyle = col; g.lineCap = 'round'; g.lineJoin = 'round'; g.stroke();
}
// the skull bar for Nature: a mossy log with a cut end at the tip and a vine wound round it, leaves swaying.
// Drawn for a bar running from `tip` to `mid` (tip on the left); the caller mirrors the canvas for the right side.
export function natureBar(g, st, tip, mid, y, dt, size) {
  st.t = (st.t || 0) + dt;
  const th = 12 * size, L = mid - tip; if (L < 3) return;
  g.save(); g.shadowColor = 'rgba(0,0,0,.6)'; g.shadowBlur = 6; g.fillStyle = g.createPattern(bark(), 'repeat');
  g.fillRect(tip, y - th / 2, L, th); g.restore();
  for (let i = 0; i < Math.max(8, L * 0.6); i++) { const x = tip + ((i * 37) % Math.max(1, L)), j = i % 7; g.fillStyle = `rgba(${70 + j * 8},${110 + j * 9},${40 + j * 4},.8)`; g.beginPath(); g.arc(x, y - th / 2 + (i % 3), (1.4 + (j % 3) * 0.6) * size, 0, 7); g.fill(); }
  logEnd(g, tip, y, th / 2);
  const pts = []; for (let x = tip + 3; x <= mid; x += 2) pts.push([x, y + Math.sin(x * 0.12 / size + st.t * 0.6) * (th * 0.55)]);
  strokePts(g, pts, 3.4 * size, 'rgba(10,25,6,.6)'); strokePts(g, pts, 2.2 * size, '#3c6e22');
  for (let i = 4; i < pts.length; i += 7) leaf(g, pts[i][0], pts[i][1], 8 * size, (i % 2 ? -1.1 : 1.9) + Math.sin(st.t * 1.8 + i) * 0.15, LEAF[i % 3], true);
}

// ---- Blood --------------------------------------------------------------------------------------------------------------
// one drip: a stalk that thickens to a round bead, a gradient across its width, a dark rim and a white highlight
export function drip(g, x, y0, len, w, gloss, dark) {
  const bead = w * 1.25, yb = y0 + len;
  const gr = g.createLinearGradient(x - bead, 0, x + bead, 0);
  gr.addColorStop(0, dark ? '#2a0204' : '#3b0306'); gr.addColorStop(0.3, dark ? '#5e070c' : '#8a0b14'); gr.addColorStop(0.55, dark ? '#7a0b12' : '#b3141f'); gr.addColorStop(1, dark ? '#24020a' : '#3d0207');
  g.fillStyle = gr; g.beginPath();
  g.moveTo(x - w * 0.5, y0); g.bezierCurveTo(x - w * 0.45, y0 + len * 0.55, x - bead, yb - bead * 1.4, x - bead, yb); g.arc(x, yb, bead, Math.PI, 0, true);
  g.bezierCurveTo(x + bead, yb - bead * 1.4, x + w * 0.45, y0 + len * 0.55, x + w * 0.5, y0); g.closePath(); g.fill();
  if (gloss) {
    g.strokeStyle = `rgba(255,220,220,${0.55 * gloss})`; g.lineWidth = Math.max(0.6, w * 0.18); g.lineCap = 'round';
    g.beginPath(); g.moveTo(x - w * 0.18, y0 + 2); g.quadraticCurveTo(x - w * 0.25, y0 + len * 0.6, x - bead * 0.45, yb - bead * 0.2); g.stroke();
    g.fillStyle = `rgba(255,240,240,${0.85 * gloss})`; g.beginPath(); g.ellipse(x - bead * 0.38, yb - bead * 0.35, bead * 0.22, bead * 0.32, -0.4, 0, 7); g.fill();
  }
}
// a falling drop, round and glossy
export function drop(g, x, y, r) {
  const gr = g.createRadialGradient(x - r * 0.3, y - r * 0.3, 0, x, y, r * 1.3); gr.addColorStop(0, '#ef3442'); gr.addColorStop(0.6, '#b10f1c'); gr.addColorStop(1, '#4a020a');
  g.fillStyle = gr; g.beginPath(); g.ellipse(x, y, r, r * 1.3, 0, 0, 7); g.fill();
  g.fillStyle = 'rgba(255,240,240,.8)'; g.beginPath(); g.arc(x - r * 0.35, y - r * 0.4, r * 0.25, 0, 7); g.fill();
}
// drips that run from a line, grow, sometimes hang a while, and drop; list items are kept in `list`
export function stepDrips(g, list, dt, bottom, gloss = 0.95) {
  return list.filter((d) => {
    if (!d.fall) { d.len += (6 + d.w * 2.2) * dt * (d.len < d.max * 0.7 ? 1 : 0.35); if (d.len >= d.max) { d.hold = (d.hold || 0) + dt; if (d.hold > d.wait) d.fall = true; } }
    else { d.v += 220 * dt; d.y0 += d.v * dt; }
    drip(g, d.x, d.y0, d.len, d.w, gloss, d.dark);
    return d.y0 < bottom;
  });
}
export function newDrip(x, y0, size, maxLen, dark) {
  const big = Math.random(), w = (big < 0.5 ? rnd(1.4, 2.6) : big < 0.85 ? rnd(2.6, 4.5) : rnd(4.5, 7.5)) * size;
  return { x, y0, len: 0, max: rnd(12, maxLen) * (w / 3), w, v: 0, fall: false, dark, wait: Math.random() < 0.55 ? 0 : rnd(1, 6) };
}
// the drip curtain along a top edge: a solid band with drips of mixed width and length hanging from it, round tips;
// each drip slowly lengthens and, when too long, a drop breaks off and it starts short again
export function makeCurtain(n) {
  const drips = [];
  for (let i = 0; i < n; i++) drips.push({ u: (i + 0.5 + rnd(-0.3, 0.3)) / n, r: rnd(1.6, 3.6), len: rnd(3, 34), max: rnd(12, 48), sp: rnd(0.6, 2.2) });
  return { drips: drips.sort((a, b) => a.u - b.u), drops: [] };
}
export function curtain(g, C, xa, xb, yTop, band, dt, scale, bottom) {
  const yb = yTop + band, span = xb - xa;
  for (const d of C.drips) {
    d.len += d.sp * dt;
    if (d.len >= d.max) { C.drops.push({ x: xa + span * d.u, y: yb + d.len * scale - d.r * scale, r: d.r * scale * 1.05, v: 10 }); d.len = rnd(3, 8); d.max = rnd(12, 48); }
  }
  const gr = g.createLinearGradient(0, yTop, 0, yb + 40 * scale);
  gr.addColorStop(0, '#5a020a'); gr.addColorStop(0.12, '#c4111f'); gr.addColorStop(0.3, '#e5212f'); gr.addColorStop(0.7, '#a30c18'); gr.addColorStop(1, '#5a020a');
  g.save(); g.shadowColor = 'rgba(80,0,6,.6)'; g.shadowBlur = 4 * scale; g.shadowOffsetY = 1.5 * scale;
  g.beginPath(); g.moveTo(xa, yTop); g.lineTo(xb, yTop); g.lineTo(xb, yb);
  for (let i = C.drips.length - 1; i >= 0; i--) {
    const d = C.drips[i], cx = xa + span * d.u, r = d.r * scale, L = Math.max(r * 1.2, d.len * scale), f = r * 1.1;
    g.lineTo(cx + r + f, yb); g.quadraticCurveTo(cx + r, yb, cx + r, yb + f); g.lineTo(cx + r * 0.92, yb + L - r);
    g.arc(cx, yb + L - r, r * 1.08, 0, Math.PI); g.lineTo(cx - r, yb + f); g.quadraticCurveTo(cx - r, yb, cx - r - f, yb);
  }
  g.lineTo(xa, yb); g.closePath(); g.fillStyle = gr; g.fill(); g.restore();
  g.strokeStyle = 'rgba(255,225,225,.55)'; g.lineWidth = Math.max(0.7, band * 0.16); g.lineCap = 'round';
  g.beginPath(); g.moveTo(xa + 3, yTop + band * 0.3); g.lineTo(xb - 3, yTop + band * 0.3); g.stroke();
  for (const d of C.drips) {
    const cx = xa + span * d.u, r = d.r * scale, L = Math.max(r * 1.2, d.len * scale);
    if (L > r * 2.4) { g.lineWidth = Math.max(0.5, r * 0.35); g.beginPath(); g.moveTo(cx - r * 0.4, yb + r); g.lineTo(cx - r * 0.4, yb + L - r * 1.4); g.stroke(); }
    g.fillStyle = 'rgba(255,240,240,.85)'; g.beginPath(); g.ellipse(cx - r * 0.38, yb + L - r * 1.2, r * 0.26, r * 0.36, 0, 0, 7); g.fill();
  }
  C.drops = C.drops.filter((p) => { p.v += 260 * dt; p.y += p.v * dt; drop(g, p.x, p.y, p.r); return p.y < bottom; });
}
// the skull bar for Blood: a thick, slow river of blood (lumps creeping outward, light rippling over it), a small
// round end the same thickness as the bar with a long stream gathering a big blob that drops, and glossy drips hanging
// underneath. Tip on the left; the caller mirrors the canvas for the right side.
export function bloodBar(g, st, tip, mid, y, dt, size, rate, bottom) {
  st.t = (st.t || 0) + dt; st.bd = st.bd || []; st.eb = st.eb || { len: 0, max: rnd(34, 46), drops: [] };
  const th = 16 * size, x0 = tip + th / 2, x1 = mid, t = st.t; if (x1 - x0 < 4) return;
  const top = [], bot = [];
  for (let x = x1; x >= x0; x -= 2) {
    const bulge = (Math.sin(x * 0.09 / size + t * 1.1) * 1.1 + Math.sin(x * 0.031 / size + t * 0.5) * 1.3) * size;
    top.push([x, y - th / 2 - Math.max(0, bulge) * 0.5]); bot.push([x, y + th / 2 + bulge * 0.6]);
  }
  const shape = () => { g.beginPath(); g.moveTo(top[0][0], top[0][1]); for (const p of top) g.lineTo(p[0], p[1]); g.arc(x0, y, th / 2, -Math.PI / 2, Math.PI / 2, true); for (let i = bot.length - 1; i >= 0; i--) g.lineTo(bot[i][0], bot[i][1]); g.closePath(); };
  if (rate && Math.random() < dt * 3.2 * rate * ((x1 - x0) / 150)) st.bd.push({ ...newDrip(rnd(x0 + 4, x1 - 4), y + th * 0.3, size * 0.8, 32, false), wait: Math.random() < 0.6 ? 0 : rnd(0.5, 3) });
  st.bd = stepDrips(g, st.bd, dt, bottom, 0.95);
  g.save(); g.shadowColor = 'rgba(150,0,10,.55)'; g.shadowBlur = 10;
  const gr = g.createLinearGradient(0, y - th * 0.6, 0, y + th * 0.7);
  gr.addColorStop(0, '#3e0208'); gr.addColorStop(0.22, '#9b0f1c'); gr.addColorStop(0.4, '#d4202f'); gr.addColorStop(0.62, '#8a0a16'); gr.addColorStop(1, '#2a0105');
  g.fillStyle = gr; shape(); g.fill(); g.restore();
  g.save(); shape(); g.clip();
  for (let k = 0; k < 4; k++) { const sx = x1 - ((t * 16 + k * 42) % (x1 - x0 + 40)), sh = g.createLinearGradient(sx - 18, 0, sx + 18, 0); sh.addColorStop(0, 'rgba(255,190,190,0)'); sh.addColorStop(0.5, 'rgba(255,215,215,.35)'); sh.addColorStop(1, 'rgba(255,190,190,0)'); g.fillStyle = sh; g.fillRect(sx - 18, y - th, 36, th * 0.7); }
  g.restore();
  g.strokeStyle = 'rgba(255,232,232,.75)'; g.lineWidth = 1.3 * size; g.lineCap = 'round'; g.beginPath();
  top.forEach(([x, yy], i) => (i ? g.lineTo(x, yy + 2.4 * size) : g.moveTo(x, yy + 2.4 * size))); g.stroke();
  // the end: a long stream gathers a big blob, which drops
  const E = st.eb, ex = x0 - th * 0.1, ey = y + th * 0.25;
  if (rate) E.len += dt * (4 + E.len * 0.3) * rate;
  const w = Math.min(7.5, 3 + E.len * 0.2) * size;
  drip(g, ex, ey, E.len * size, w, 1, false);
  if (E.len >= E.max) { E.drops.push({ x: ex, y: ey + E.len * size, r: w * 1.3, v: 15 }); E.len = 0; E.max = rnd(34, 46); }
  E.drops = E.drops.filter((p) => { p.v += 260 * dt; p.y += p.v * dt; drop(g, p.x, p.y, p.r); return p.y < bottom; });
}

// the Blood theme's skull, "Drenched": drawn over the Bone skull (skull space 120 x 100, facing right) - the bone
// stained deep red and blotchy, a cap of blood over the crown, blood welling in the eye and nose, and streams running
// down from the crown, the eye, the nose and the jaw, gathering gobs that drop
const SKULL_OUTLINE = 'M20,60 C10,44 14,20 40,11 C62,4 90,10 101,30 C104,36 106,40 104,44 L100,47 C104,52 108,58 107,63 L102,64 C104,68 104,72 102,75 L101,80 L78,80 C74,74 66,70 58,70 C52,72 48,76 46,80 C40,80 36,74 34,70 C28,68 22,66 20,60 Z M52,72 C55,82 60,90 70,93 L97,94 C101,93 103,90 102,86 L100,83 L80,83 C73,83 67,80 62,76 Z';
let skullPath = null;
const DRENCH = [[34, 22, 4.5, 40], [52, 14, 5, 58], [70, 12, 3.4, 44], [86, 54, 4.5, 34], [103, 62, 3.6, 24], [96, 88, 6, 20], [80, 91, 4.5, 18], [26, 40, 3.6, 30]];
export function drenched(g, st, x, y, w, face, dt, bottom, moving) {
  const k = w / 120; st.t = (st.t || 0) + dt;
  skullPath = skullPath || new Path2D(SKULL_OUTLINE);
  g.save(); g.translate(x + (face < 0 ? w : 0), y); g.scale(k * face, k);
  g.save(); g.clip(skullPath);
  g.globalCompositeOperation = 'multiply'; g.fillStyle = 'rgba(150,10,18,.55)'; g.fill(skullPath);
  g.globalCompositeOperation = 'source-over';
  for (let i = 0; i < 18; i++) { const sx = 22 + ((i * 47) % 80), sy = 14 + ((i * 29) % 70); const gr = g.createRadialGradient(sx, sy, 0, sx, sy, 10); gr.addColorStop(0, 'rgba(70,0,6,.55)'); gr.addColorStop(1, 'rgba(70,0,6,0)'); g.fillStyle = gr; g.fillRect(sx - 10, sy - 10, 20, 20); }
  const cap = g.createLinearGradient(0, 4, 0, 34); cap.addColorStop(0, '#e5212f'); cap.addColorStop(0.5, '#a30c18'); cap.addColorStop(1, '#5a020a');
  g.fillStyle = cap; g.beginPath(); g.moveTo(10, 0); g.lineTo(110, 0); g.lineTo(110, 30);
  for (let xx = 110; xx >= 10; xx -= 3) g.lineTo(xx, 22 + Math.sin(xx * 0.35 + st.t * 0.8) * 2.4 + Math.sin(xx * 0.9) * 1.6 + (xx < 40 ? (40 - xx) * 0.55 : 0));
  g.closePath(); g.fill();
  g.strokeStyle = 'rgba(255,225,225,.6)'; g.lineWidth = 1.4; g.beginPath(); g.moveTo(40, 13); g.quadraticCurveTo(64, 7, 90, 14); g.stroke();
  const pulse = 0.85 + Math.sin(st.t * 2) * 0.1, eye = g.createRadialGradient(87, 46, 1, 88, 49, 9);
  eye.addColorStop(0, '#ff4a55'); eye.addColorStop(0.5, '#b10f1c'); eye.addColorStop(1, '#3a0207');
  g.fillStyle = eye; g.beginPath(); g.ellipse(88, 50, 8.6 * pulse, 7.6 * pulse, 0, 0, 7); g.fill();
  g.fillStyle = 'rgba(255,240,240,.85)'; g.beginPath(); g.ellipse(85.5, 46.5, 2, 1.3, -0.5, 0, 7); g.fill();
  g.fillStyle = '#9a0c18'; g.beginPath(); g.moveTo(101, 55); g.lineTo(106, 62); g.lineTo(100, 63); g.closePath(); g.fill();
  g.restore();
  st.runs = st.runs || DRENCH.map(([sx, sy, sw, sl]) => ({ sx, sy, sw, sl, len: rnd(0, sl), drops: [] }));
  for (const r of st.runs) {
    if (moving) r.len += dt * (6 + r.sw * 1.6) * moving;
    if (r.len > r.sl) { r.drops.push({ y: r.sy + r.len, v: 10, r: r.sw }); r.len = r.sl * rnd(0.35, 0.6); }
    drip(g, r.sx, r.sy, r.len, r.sw, 1, false);
    r.drops = r.drops.filter((d) => { d.v += 260 * dt / k; d.y += d.v * dt; drop(g, r.sx, d.y, d.r); return y + d.y * k < bottom; });
  }
  g.restore();
}
