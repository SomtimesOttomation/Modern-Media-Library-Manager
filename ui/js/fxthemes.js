// Versus poster themes drawn on a canvas around the poster (Fire has its own, in compare.js):
//   water     rain across the poster, drops running down the frame, ripples at the base (blue)
//   specter   "Spectral": green ooze dripping off the frame; now and then a small skull snakes round the border
//   lightning white-blue crackle on the border; every few seconds a bolt races round it
//   nature    vines creep in from the corners (brown and green) and leaves drift down
// Size and intensity come from Settings > Versus > Effects > Posters. "Calm" runs slower and sparser; "Still" and the
// system's reduce-motion setting leave the steady CSS glow only. Each one stops by itself when its poster leaves the page.
import { tune, mult } from './fxtune.js';

const PAD = { x: 34, top: 40, bottom: 34 };
export const THEMED = ['water', 'specter', 'lightning', 'nature'];

// a point on the poster's border, d pixels clockwise from its top-left corner
function edgePoint(d, w, h) {
  const P = 2 * (w + h);
  d = ((d % P) + P) % P;
  if (d < w) return [d, 0, 0];
  if (d < w + h) return [w, d - w, 1];
  if (d < 2 * w + h) return [w - (d - w - h), h, 2];
  return [0, h - (d - 2 * w - h), 3];
}
function miniSkull(g, x, y, s, col) {
  g.save(); g.translate(x, y); g.scale(s / 16, s / 16);
  g.fillStyle = col; g.beginPath(); g.arc(0, -2, 7, Math.PI, 0); g.lineTo(7, 2); g.quadraticCurveTo(7, 6, 4, 6); g.lineTo(4, 9); g.lineTo(-4, 9); g.lineTo(-4, 6); g.quadraticCurveTo(-7, 6, -7, 2); g.closePath(); g.fill();
  g.fillStyle = '#0b0f0a'; g.beginPath(); g.arc(-3, 0, 2.2, 0, 7); g.arc(3, 0, 2.2, 0, 7); g.fill();
  g.restore();
}
function jag(g, pts, amp) {
  g.beginPath(); g.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length; i++) g.lineTo(pts[i][0] + (Math.random() - 0.5) * amp, pts[i][1] + (Math.random() - 0.5) * amp);
  g.stroke();
}

const THEMES = {
  water: {
    glow: true,
    init: () => ({ rain: [], drips: [], rings: [] }),
    step(S, g, o, dt, k) {
      const { w, h, ox, oy, W, H, sz, calm } = o;
      for (let n = dt * (calm ? 50 : 120) * k; n > 0; n--) { if (Math.random() < n) S.rain.push({ x: Math.random() * (W + 60) - 30, y: -20, v: (calm ? 320 : 560) + Math.random() * 200, l: (10 + Math.random() * 14) * sz }); }
      if (Math.random() < dt * (calm ? 1.2 : 3) * k) { const left = Math.random() < 0.5; S.drips.push({ x: ox + (left ? 0 : w), y: oy + Math.random() * h * 0.6, v: 30 + Math.random() * 40, r: (1.6 + Math.random() * 1.8) * sz }); }
      g.lineCap = 'round';
      g.strokeStyle = 'rgba(170,215,255,0.38)'; g.lineWidth = 1.1 * sz;
      S.rain = S.rain.filter((p) => { p.y += p.v * dt; p.x -= p.v * 0.18 * dt; g.beginPath(); g.moveTo(p.x, p.y); g.lineTo(p.x + p.l * 0.18, p.y - p.l); g.stroke();
        if (p.y > oy + h && p.x > ox && p.x < ox + w && Math.random() < 0.05) S.rings.push({ x: p.x, y: oy + h + 4, r: 1, a: 0.6 });
        return p.y < H + 20; });
      S.drips = S.drips.filter((p) => { p.v += 90 * dt; p.y += p.v * dt;
        const gr = g.createLinearGradient(p.x, p.y - 26 * o.sz, p.x, p.y); gr.addColorStop(0, 'rgba(120,190,255,0)'); gr.addColorStop(1, 'rgba(190,230,255,0.85)');
        g.strokeStyle = gr; g.lineWidth = p.r; g.beginPath(); g.moveTo(p.x, p.y - 26 * o.sz); g.lineTo(p.x, p.y); g.stroke();
        g.fillStyle = 'rgba(210,240,255,0.9)'; g.beginPath(); g.arc(p.x, p.y, p.r, 0, 7); g.fill();
        if (p.y >= oy + h) { S.rings.push({ x: p.x, y: oy + h + 4, r: 2, a: 0.8 }); return false; } return true; });
      S.rings = S.rings.filter((r) => { r.r += 40 * dt * sz; r.a -= 0.9 * dt; if (r.a <= 0) return false;
        g.strokeStyle = `rgba(150,210,255,${r.a})`; g.lineWidth = 1.2; g.beginPath(); g.ellipse(r.x, r.y, r.r, r.r * 0.3, 0, 0, 7); g.stroke(); return true; });
    },
  },
  specter: {
    glow: true,
    init: () => ({ drips: [], skull: null, next: 2 + Math.random() * 3, t: 0 }),
    step(S, g, o, dt, k) {
      const { w, h, ox, oy, sz, calm } = o;
      S.t += dt;
      if (Math.random() < dt * (calm ? 1.4 : 3.5) * k) {
        const r = Math.random(); let x, y;
        if (r < 0.6) { x = ox + Math.random() * w; y = oy; } else { x = ox + (r < 0.8 ? 0 : w); y = oy + Math.random() * h * 0.5; }
        S.drips.push({ x, y, y0: y, len: 0, max: (14 + Math.random() * 30) * sz, v: 0, r: (2 + Math.random() * 2.5) * sz, fall: false });
      }
      // ooze along the top edge
      g.fillStyle = 'rgba(110,255,120,0.18)';
      for (let i = 0; i < 9; i++) { const x = ox + (i + 0.5) * w / 9, bob = Math.sin(S.t * 2 + i) * 2; g.beginPath(); g.ellipse(x, oy + bob, (w / 18) * 1.1, 5 * sz, 0, 0, 7); g.fill(); }
      S.drips = S.drips.filter((d) => {
        if (!d.fall) { d.len += (calm ? 8 : 16) * dt; if (d.len >= d.max) d.fall = true; }
        else { d.v += 160 * dt; d.y += d.v * dt; }
        const top = d.fall ? d.y - d.max * 0.6 : d.y0;
        const gr = g.createLinearGradient(d.x, top, d.x, d.y + d.len);
        gr.addColorStop(0, 'rgba(90,255,110,0.05)'); gr.addColorStop(1, 'rgba(150,255,140,0.9)');
        g.strokeStyle = gr; g.lineWidth = d.r * 0.9; g.lineCap = 'round'; g.beginPath(); g.moveTo(d.x, top); g.lineTo(d.x, d.y + d.len); g.stroke();
        g.fillStyle = 'rgba(170,255,150,0.95)'; g.beginPath(); g.arc(d.x, d.y + d.len, d.r, 0, 7); g.fill();
        return d.y + d.len < o.H + 10;
      });
      // the small skull that snakes round the border now and then
      S.next -= dt;
      if (!S.skull && S.next <= 0) S.skull = { d: Math.random() * 2 * (w + h), run: 0, len: (calm ? 6 : 4) };
      if (S.skull) {
        const s = S.skull; s.run += dt;
        const P = 2 * (w + h), speed = P / s.len;
        for (let i = 14; i >= 0; i--) {
          const [x, y] = edgePoint(s.d + (s.run * speed) - i * 7 * sz, w, h);
          const wob = Math.sin(s.run * 12 - i * 0.7) * 3 * sz;
          g.fillStyle = `rgba(120,255,140,${0.5 * (1 - i / 15)})`; g.beginPath(); g.arc(ox + x + wob, oy + y + wob, (4 - i * 0.2) * sz, 0, 7); g.fill();
        }
        const [hx, hy] = edgePoint(s.d + s.run * speed, w, h);
        miniSkull(g, ox + hx, oy + hy, 13 * sz, 'rgba(200,255,190,0.95)');
        if (s.run >= s.len) { S.skull = null; S.next = (calm ? 9 : 5) / Math.max(0.3, k) + Math.random() * 3; }
      }
    },
  },
  lightning: {
    glow: true,
    init: () => ({ sparks: [], bolt: null, next: 0.6 + Math.random() }),
    step(S, g, o, dt, k) {
      const { w, h, ox, oy, sz, calm } = o;
      for (let n = dt * (calm ? 10 : 26) * k; n > 0; n--) { if (Math.random() < n) S.sparks.push({ d: Math.random() * 2 * (w + h), life: 0.12 + Math.random() * 0.16, age: 0, len: (20 + Math.random() * 40) * sz }); }
      g.lineJoin = 'round'; g.lineCap = 'round';
      S.sparks = S.sparks.filter((s) => {
        s.age += dt; if (s.age > s.life) return false;
        const pts = []; for (let i = 0; i <= 5; i++) { const [x, y] = edgePoint(s.d + i * s.len / 5, w, h); pts.push([ox + x, oy + y]); }
        g.strokeStyle = 'rgba(120,180,255,0.6)'; g.lineWidth = 6 * sz; jag(g, pts, 9 * sz);
        g.strokeStyle = 'rgba(245,250,255,1)'; g.lineWidth = 1.8 * sz; jag(g, pts, 6 * sz);
        return true;
      });
      S.next -= dt;
      if (!S.bolt && S.next <= 0) S.bolt = { d: Math.random() * 2 * (w + h), run: 0, len: calm ? 2.2 : 1.2 };
      if (S.bolt) {
        const b = S.bolt; b.run += dt;
        const P = 2 * (w + h), head = b.d + (b.run / b.len) * P, tail = Math.min(P * 0.45, 260 * sz);
        const pts = []; for (let i = 0; i <= 30; i++) { const [x, y] = edgePoint(head - tail + i * tail / 30, w, h); pts.push([ox + x, oy + y]); }
        g.strokeStyle = 'rgba(110,170,255,0.5)'; g.lineWidth = 14 * sz; jag(g, pts, 14 * sz);
        g.strokeStyle = 'rgba(200,225,255,0.85)'; g.lineWidth = 3.5 * sz; jag(g, pts, 8 * sz);
        g.strokeStyle = '#ffffff'; g.lineWidth = 1.4 * sz; jag(g, pts, 5 * sz);
        // a fork off the head now and then
        if (Math.random() < 0.35) { const [x, y] = pts[pts.length - 1]; const a = Math.random() * 6.28; g.strokeStyle = 'rgba(220,235,255,0.8)'; g.lineWidth = 1.2 * sz; jag(g, [[x, y], [x + Math.cos(a) * 12 * sz, y + Math.sin(a) * 12 * sz], [x + Math.cos(a) * 24 * sz, y + Math.sin(a) * 24 * sz]], 6 * sz); }
        if (b.run >= b.len) { S.bolt = null; S.next = (calm ? 5 : 2) / Math.max(0.3, k) + Math.random() * 1.5; }
      }
    },
  },
  nature: {
    glow: false,
    init: () => ({ grow: 0, leaves: [], t: 0 }),
    step(S, g, o, dt, k) {
      const { w, h, ox, oy, sz, calm } = o;
      S.t += dt;
      S.grow = Math.min(1, S.grow + dt / (calm ? 9 : 5));
      // one vine from each corner, growing along both edges that meet there; drawn once per growth step into a
      // layer of its own (redrawing every leaf each frame is what made this theme slow)
      const reach = Math.round((0.18 + 0.32 * Math.min(1, k)) * S.grow * 50) / 50;
      if (!S.layer || S.reach !== reach || S.lw !== o.W || S.lh !== o.H || S.lsz !== sz) {
        S.reach = reach; S.lw = o.W; S.lh = o.H; S.lsz = sz;
        S.layer = S.layer || document.createElement('canvas');
        S.layer.width = Math.round(o.W * o.dpr); S.layer.height = Math.round(o.H * o.dpr);
        const v = S.layer.getContext('2d'); v.setTransform(o.dpr, 0, 0, o.dpr, 0, 0); v.clearRect(0, 0, o.W, o.H);
        const corners = [[0, 0, 1, 1], [w, 0, -1, 1], [w, h, -1, -1], [0, h, 1, -1]];
        for (const [cx, cy, sx, sy] of corners) {
          for (const along of ['x', 'y']) {
            const L = (along === 'x' ? w : h) * reach;
            v.strokeStyle = '#6b4a2b'; v.lineWidth = 2.6 * sz; v.lineCap = 'round'; v.beginPath();
            for (let q = 0; q <= L; q += 3) {
              const wav = Math.sin(q / 9) * 4 * sz;
              const x = ox + cx + (along === 'x' ? sx * q : -sx * wav), y = oy + cy + (along === 'y' ? sy * q : -sy * wav);
              if (q === 0) v.moveTo(x, y); else v.lineTo(x, y);
            }
            v.stroke();
            for (let q = 12; q <= L; q += 16) {
              const wav = Math.sin(q / 9) * 4 * sz, side = (q / 16) % 2 ? 1 : -1;
              const x = ox + cx + (along === 'x' ? sx * q : -sx * wav), y = oy + cy + (along === 'y' ? sy * q : -sy * wav);
              v.save(); v.translate(x, y); v.rotate((along === 'x' ? 0 : Math.PI / 2) + side * 0.9);
              v.fillStyle = side > 0 ? '#5f9e3a' : '#7dbb4a'; v.beginPath(); v.ellipse(6 * sz, 0, 6 * sz, 2.8 * sz, 0, 0, 7); v.fill();
              v.strokeStyle = 'rgba(30,60,20,0.6)'; v.lineWidth = 0.7; v.beginPath(); v.moveTo(0, 0); v.lineTo(11 * sz, 0); v.stroke();
              v.restore();
            }
          }
        }
      }
      g.save(); g.setTransform(1, 0, 0, 1, 0, 0); g.drawImage(S.layer, 0, 0); g.restore();
      if (Math.random() < dt * (calm ? 0.5 : 1.3) * k) S.leaves.push({ x: ox + Math.random() * w, y: oy - 10, vy: 22 + Math.random() * 20, rot: Math.random() * 6, vr: (Math.random() - 0.5) * 3, sw: Math.random() * 6, col: Math.random() < 0.3 ? '#a8742f' : Math.random() < 0.5 ? '#7dbb4a' : '#5f9e3a' });
      S.leaves = S.leaves.filter((p) => {
        p.y += p.vy * dt; p.sw += dt * 2; p.rot += p.vr * dt;
        const x = p.x + Math.sin(p.sw) * 16;
        g.save(); g.translate(x, p.y); g.rotate(p.rot); g.fillStyle = p.col; g.beginPath(); g.ellipse(0, 0, 6 * sz, 2.8 * sz, 0, 0, 7); g.fill(); g.restore();
        return p.y < o.H + 10;
      });
    },
  },
};

export function themeFx(el, theme) {
  el._themeFx?.stop(); el._themeFx = null;
  const T = THEMES[theme];
  if (!T) return;
  const still = () => el.closest('.motion-still') || matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (still()) return;
  const cv = document.createElement('canvas'); cv.className = 'fx-theme-canvas'; cv.setAttribute('aria-hidden', 'true');
  el.append(cv); el.classList.add('fx-themed');
  const g = cv.getContext('2d');
  let W = 0, H = 0, w = 0, h = 0, dpr = 1, raf = 0, last = 0, seen = false;
  const state = T.init();
  const size = () => {
    w = el.clientWidth; h = el.clientHeight; dpr = Math.min(2, window.devicePixelRatio || 1);
    W = w + PAD.x * 2; H = h + PAD.top + PAD.bottom;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); cv.style.width = W + 'px'; cv.style.height = H + 'px';
  };
  const frame = (t) => {
    raf = requestAnimationFrame(frame);
    if (!el.isConnected) { if (seen) stop(); return; }
    if (!seen) { seen = true; size(); last = t; return; }
    if (el.clientWidth !== w || el.clientHeight !== h) size();
    if (still()) { stop(); return; }
    const dt = Math.min(0.05, (t - last) / 1000); last = t;
    const pt = tune().poster;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, H);
    g.globalCompositeOperation = T.glow ? 'lighter' : 'source-over';
    T.step(state, g, { w, h, ox: PAD.x, oy: PAD.top, W, H, dpr, sz: mult(pt.size), calm: !!el.closest('.motion-calm') }, dt, mult(pt.int));
    g.globalCompositeOperation = 'source-over';
  };
  const stop = () => { cancelAnimationFrame(raf); cv.remove(); el.classList.remove('fx-themed'); if (el._themeFx === api) el._themeFx = null; };
  const api = { stop };
  el._themeFx = api;
  raf = requestAnimationFrame(frame);
}
