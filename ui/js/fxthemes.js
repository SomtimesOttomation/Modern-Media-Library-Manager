// Versus poster themes drawn on a canvas around the poster (Fire has its own, in compare.js):
//   water     rain across the poster, rain on the glass over it (beads, and drops running down), drops down the frame,
//             ripples at the base (blue)
//   specter   "Souls of the Damned": green fel fire; a swarm of tiny screaming heads snakes round the border, hands claw out
//             from behind it and green ooze drips down the sides (Settings > Versus > Souls of the Damned)
//   blood     "Fresh and glossy": a drip curtain along the top and glossy drips of every size running down the top and sides
//   lightning white-blue crackle on the border; every few seconds a bolt races round it
//   nature    "Overgrown log frame": a weathered log frame with moss and cut ends, two vines with swaying leaves, falling leaves
// Size and intensity come from Settings > Versus > Effects > Posters. "Calm" runs slower and sparser; "Still" and the
// system's reduce-motion setting leave the steady CSS glow only. Each one stops by itself when its poster leaves the page.
import { tune, mult } from './fxtune.js';
import * as S from './store.js';
import * as D from './fxdraw.js';

// ---- Souls of the Damned: settings, images and a soft glow ----
const clampN = (v, lo, hi, def) => { const n = Number(v); return Number.isFinite(n) ? Math.max(lo, Math.min(hi, n)) : def; };
const settingsOf = () => S.state.settings || {};
let damned = null, damnedLoading = false;
function damnedImages() {
  if (damned) return damned;
  if (!damnedLoading) {
    damnedLoading = true;
    fetch('img/damned/index.json').then((r) => r.json()).then((ix) => {
      const load = (n) => new Promise((ok) => { const im = new Image(); im.onload = () => ok(im); im.onerror = () => ok(null); im.src = 'img/damned/' + n; });
      return Promise.all([Promise.all(ix.faces.map(([n, sy, kind]) => load(n).then((img) => img && { img, sy, kind }))), Promise.all(ix.hands.map(load))]).then(([faces, hands]) => {
        faces = faces.filter(Boolean); hands = hands.filter(Boolean);
        damned = { faces, hands, skulls: faces.filter((f) => f.kind === 'skull').length || 1 };
      });
    }).catch(() => { damnedLoading = false; });
  }
  return null;
}
let glowSprite = null;
const glowTints = new Map();
function glowAt(g, x, y, r, col, a) {
  if (a <= 0.004 || r <= 0.3) return;
  if (!glowSprite) {
    glowSprite = document.createElement('canvas'); glowSprite.width = glowSprite.height = 64;
    const x2 = glowSprite.getContext('2d'), gr = x2.createRadialGradient(32, 32, 0, 32, 32, 32);
    gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(0.45, 'rgba(255,255,255,.35)'); gr.addColorStop(1, 'rgba(255,255,255,0)'); x2.fillStyle = gr; x2.fillRect(0, 0, 64, 64);
  }
  let c = glowTints.get(col);
  if (!c) { c = document.createElement('canvas'); c.width = c.height = 64; const x2 = c.getContext('2d'); x2.drawImage(glowSprite, 0, 0); x2.globalCompositeOperation = 'source-in'; x2.fillStyle = col; x2.fillRect(0, 0, 64, 64); glowTints.set(col, c); }
  g.globalAlpha = Math.min(1, a); g.drawImage(c, x - r, y - r, r * 2, r * 2); g.globalAlpha = 1;
}

const PAD = { x: 34, top: 40, bottom: 34 };
export const THEMED = ['water', 'specter', 'blood', 'lightning', 'nature'];

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

// rain on glass, over the poster: small beads build up, now and then a heavy drop runs down in a wobbly line,
// sweeping up the beads in its way and leaving a trail of tiny ones; the glass mists slightly
function glassDrop(g, x, y, r, a) {
  if (r < 0.6) return;
  const gr = g.createRadialGradient(x - r * 0.25, y - r * 0.35, r * 0.1, x, y, r);
  gr.addColorStop(0, `rgba(255,255,255,${0.10 * a})`); gr.addColorStop(0.65, `rgba(200,225,255,${0.06 * a})`); gr.addColorStop(1, `rgba(10,25,45,${0.55 * a})`);
  g.fillStyle = gr; g.beginPath(); g.ellipse(x, y, r, r * 1.08, 0, 0, 7); g.fill();
  g.fillStyle = `rgba(255,255,255,${0.75 * a})`; g.beginPath(); g.ellipse(x + r * 0.25, y + r * 0.4, r * 0.32, r * 0.2, 0, 0, 7); g.fill();   // the bright spot light makes through a drop
  g.fillStyle = `rgba(255,255,255,${0.5 * a})`; g.beginPath(); g.arc(x - r * 0.38, y - r * 0.45, r * 0.13, 0, 7); g.fill();
}
function rainOnGlass(S, g, o, dt, k) {
  const { w, h, ox, oy, sz, calm } = o, maxBeads = Math.round(w * h / 260 * k);
  g.save(); g.globalCompositeOperation = 'source-over';
  g.beginPath(); if (g.roundRect) g.roundRect(ox, oy, w, h, 11); else g.rect(ox, oy, w, h); g.clip();
  g.fillStyle = `rgba(190,215,240,${0.06 + 0.03 * Math.min(1, k)})`; g.fillRect(ox, oy, w, h);                 // a little mist
  for (let n = dt * (calm ? 25 : 60) * k; n > 0; n--) if (Math.random() < n && S.beads.length < maxBeads)
    S.beads.push({ x: ox + Math.random() * w, y: oy + Math.random() * h, r: (0.7 + Math.random() ** 2.2 * 3.2) * sz, a: 0 });
  if (Math.random() < dt * (calm ? 0.35 : 0.9) * k)
    S.runners.push({ x: ox + Math.random() * w, y: oy - 4, r: (2.6 + Math.random() * 2.2) * sz, v: 0, ph: Math.random() * 6, stop: 0, trail: 0 });
  for (const b of S.beads) { b.a = Math.min(1, b.a + dt * 2); glassDrop(g, b.x, b.y, b.r, b.a); }
  S.runners = S.runners.filter((d) => {
    if (d.stop > 0) d.stop -= dt; else { d.v = Math.min((calm ? 45 : 90) * (d.r / 3), d.v + 160 * dt); d.y += d.v * dt; d.x += Math.sin(d.y * 0.08 + d.ph) * 0.35; if (Math.random() < dt * 0.8) d.stop = 0.1 + Math.random() * 0.35; }
    d.trail += d.v * dt;
    if (d.trail > 7 * sz) { d.trail = 0; if (Math.random() < 0.7) S.beads.push({ x: d.x + (Math.random() - 0.5) * 1.5, y: d.y - d.r * 1.4, r: d.r * (0.22 + Math.random() * 0.2), a: 1 }); d.r *= 0.985; }
    for (let i = S.beads.length - 1; i >= 0; i--) {                                                       // sweep up beads in the way
      const b = S.beads[i]; if (Math.abs(b.x - d.x) < d.r && Math.abs(b.y - d.y) < d.r * 1.2 && b.r < d.r) { d.r = Math.min(6 * sz, Math.hypot(d.r, b.r * 0.6)); S.beads.splice(i, 1); }
    }
    g.fillStyle = 'rgba(20,35,55,0.18)'; g.fillRect(d.x - d.r * 0.45, d.y - d.r * 6, d.r * 0.9, d.r * 6);   // the wet streak behind it
    glassDrop(g, d.x, d.y, d.r, 1);
    return d.y - d.r < oy + h && d.r > 1;
  });
  if (S.beads.length > maxBeads * 1.3) S.beads.splice(0, S.beads.length - Math.round(maxBeads * 1.3));
  g.restore();
}

const THEMES = {
  water: {
    glow: true,
    init: () => ({ rain: [], drips: [], rings: [], beads: [], runners: [] }),
    step(S, g, o, dt, k) {
      const { w, h, ox, oy, W, H, sz, calm } = o;
      rainOnGlass(S, g, o, dt, k);
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
    init: () => ({ fl: [], heads: [], hands: [], drips: [], t: 0 }),
    step(S, g, o, dt, k) {
      const { w, h, ox, oy, sz, calm } = o, set = settingsOf();
      const L = 2 * (w + h), edge = (d) => { const [x, y, side] = edgePoint(d, w, h); return [ox + x, oy + y, side]; };
      S.t += dt;
      const cnt = clampN(set.dmSkulls, 12, 128, 24), handN = clampN(set.dmHands, 0, 48, 8), claw = clampN(set.dmClaw, 0, 50, 28) / 10;
      const vary = clampN(set.dmVariety, 0, 60, 0) / 100, dk = 1 + clampN(set.dmDrips, 0, 100, 0) / 100 * 0.3;
      const vsz = (q) => 1 + q.vr * vary;
      // fel fire: green flames rising off every edge (thicker with Size, more with Intensity, never blown out)
      const tame = 1 / Math.sqrt(Math.max(0.1, k * sz));
      for (let n = dt * (calm ? 110 : 230) * k; n > 0; n--) {
        if (Math.random() >= n) continue;
        const [x, y, side] = edge(Math.random() * L), out = side === 1 ? 1 : side === 3 ? -1 : 0;
        S.fl.push({ x, y, vx: out * (8 + Math.random() * 14) + (Math.random() - 0.5) * 8, vy: -(calm ? 26 : 44) - Math.random() * 40, life: 1, dec: 0.8 + Math.random() * 0.8, r: (7 + Math.random() * 9) * sz });
      }
      if (S.fl.length > 900) S.fl.splice(0, S.fl.length - 900);
      S.fl = S.fl.filter((p) => {
        p.life -= p.dec * dt; p.x += p.vx * dt + Math.sin(S.t * 9 + p.y * 0.05) * 0.4; p.y += p.vy * dt;
        if (p.life <= 0) return false;
        const Lf = p.life, c = Lf > 0.8 ? '#eaffd9' : Lf > 0.55 ? '#7dff4a' : Lf > 0.3 ? '#2bd61a' : '#0b4d12';
        glowAt(g, p.x, p.y, p.r * (0.4 + Lf * 0.7), c, Lf * Lf * 0.6 * tame);
        return true;
      });
      g.globalCompositeOperation = 'source-over';
      const imgs = damnedImages(); if (!imgs) return;
      // green ooze dripping down the sides (and from near the top corners); Drips adds up to 30% more of everything
      if (Math.random() < dt * (calm ? 1.2 : 2.2) * dk) {
        const r = Math.random(), left = Math.random() < 0.5, inw = Math.random() * w * 0.1, big = Math.random();
        const x = r < 0.8 ? (left ? ox + inw : ox + w - inw) : (left ? ox + 2 + Math.random() * 20 + inw : ox + w - 2 - Math.random() * 20 - inw);
        const y = r < 0.8 ? oy + 6 + Math.random() * h * 0.85 : oy;
        const size = big < 0.55 ? 1 + Math.random() : big < 0.9 ? 2 + Math.random() * 1.5 : 3.5 + Math.random() * 2;
        S.drips.push({ x, y0: y, y, len: 0, max: (10 + Math.random() * 24) * (size / 2.5), v: 0, r: size * dk, fall: false });
      }
      g.lineCap = 'round';
      S.drips = S.drips.filter((d) => {
        if (!d.fall) { d.len += (8 + d.r * 3) * dt * dk; if (d.len >= d.max) d.fall = true; } else { d.v += (160 + d.r * 30) * dt * dk; d.y += d.v * dt; }
        const top = d.fall ? d.y - d.max * 0.7 : d.y0, gr = g.createLinearGradient(d.x, top, d.x, d.y + d.len);
        gr.addColorStop(0, 'rgba(60,200,40,0)'); gr.addColorStop(0.5, `rgba(90,230,60,${Math.min(1, 0.55 * dk)})`); gr.addColorStop(1, `rgba(150,255,110,${Math.min(1, 0.95 * dk)})`);
        g.strokeStyle = gr; g.lineWidth = d.r * 0.9; g.beginPath(); g.moveTo(d.x, top); g.lineTo(d.x, d.y + d.len); g.stroke();
        g.fillStyle = `rgba(160,255,120,${Math.min(1, 0.95 * dk)})`; g.beginPath(); g.ellipse(d.x, d.y + d.len, d.r, d.r * (d.fall ? 1.5 : 1.15), 0, 0, 7); g.fill();
        return d.y + d.len < o.H + 10;
      });
      // hands clawing out from behind the poster's edges
      for (let n = dt * handN * 0.35; n > 0; n--) {
        if (Math.random() >= n || S.hands.length >= handN) continue;
        S.hands.push({ side: Math.floor(Math.random() * 4), u: 0.15 + Math.random() * 0.7, t: 0, len: 2.2 + Math.random() * 1.2, img: imgs.hands[Math.floor(Math.random() * imgs.hands.length)],
          s: 0.85 + Math.random() * 0.3, tilt: (Math.random() - 0.5) * 0.7, flip: Math.random() < 0.5, claw: Math.random() < 0.5, rate: 0.8 + Math.random() * 0.4, ph: 0, vr: Math.random() * 2 - 1 });
      }
      if (S.hands.length > handN) S.hands.length = handN;
      S.hands = S.hands.filter((q) => {
        if (q.claw) q.len = Math.max(q.len, 3.6);
        q.t += dt; const kk = q.t / q.len; if (kk >= 1) return false;
        const out = kk < 0.3 ? (kk / 0.3) ** 0.6 : kk < 0.75 ? 1 : 1 - (kk - 0.75) / 0.25;
        const grab = kk > 0.3 && kk < 0.75 ? Math.abs(Math.sin(q.t * 7)) : 0, on = q.claw && claw > 0 && kk > 0.25 && kk < 0.8;
        q.ph += dt * claw * q.rate; const ph = q.ph % 1;
        const rake = on ? (ph < 0.3 ? -1 + 2 * (ph / 0.3) ** 0.5 : 1 - 2 * ((ph - 0.3) / 0.7)) : 0, curl = on ? Math.max(0, Math.sin(ph * Math.PI * 2)) : 0;
        const im = q.img, hh = 36 * q.s * vsz(q), ww = hh * im.width / im.height;
        const ang = [0, Math.PI / 2, Math.PI, -Math.PI / 2][q.side] + q.tilt + rake * 0.45;
        const ex = q.side === 0 ? ox + w * q.u : q.side === 1 ? ox + w : q.side === 2 ? ox + w * q.u : ox, ey = q.side === 0 ? oy : q.side === 1 ? oy + h * q.u : q.side === 2 ? oy + h : oy + h * q.u;
        g.save(); g.translate(ex, ey); g.rotate(ang); g.beginPath(); g.rect(-ww, -hh * 1.6, ww * 2, hh * 1.6); g.clip();
        if (q.flip) g.scale(-1, 1);
        g.scale(1 + curl * 0.06, 1 - (q.claw ? curl * 0.22 : grab * 0.08));
        g.globalAlpha = 0.95; g.shadowColor = 'rgba(93,255,58,.85)'; g.shadowBlur = 5;
        g.drawImage(im, -ww / 2, -hh * out * 0.92, ww, hh); g.restore();
        return true;
      });
      // the swarm: tiny screaming heads snaking round the border both ways
      while (S.heads.length < cnt) {
        const r = Math.random(), fi = r < 0.5 ? Math.floor(Math.random() * imgs.skulls) : r < 0.75 ? imgs.faces.findIndex((f) => f.kind === 'horned') : imgs.faces.findIndex((f) => f.kind === 'clown');
        S.heads.push({ d: Math.random() * L, sp: 45 + Math.random() * 65, dir: Math.random() < 0.5 ? -1 : 1, amp: 6 + Math.random() * 10, c: Math.random() * 3, per: 2.6 + Math.random() * 1.6,
          jn: 0, jx: 0, jy: 0, rot: (Math.random() - 0.5) * 0.7, ph: Math.random() * 6, a: 0.75 + Math.random() * 0.25, fi: Math.max(0, fi), vr: Math.random() * 2 - 1 });
      }
      if (S.heads.length > cnt) S.heads.length = cnt;
      for (const F of S.heads) {
        const face = imgs.faces[F.fi]; if (!face) continue;
        F.d += F.sp * F.dir * dt * (calm ? 0.5 : 1); F.c += dt; if (F.c > F.per) F.c = 0;
        const [ex2, ey2, side] = edge(F.d), weave = Math.sin(F.d * 0.06 + F.ph) * F.amp;
        const x = ex2 + (side === 1 ? weave : side === 3 ? -weave : 0), y = ey2 + (side === 0 ? -weave : side === 2 ? weave : 0);
        F.jn -= dt; if (F.jn <= 0) { F.jn = 0.06 + Math.random() * 0.44; F.jx = (Math.random() - 0.5) * 6; F.jy = (Math.random() - 0.5) * 4; }
        if (Math.random() < 0.05) continue;                                    // a missing frame
        const c = F.c, scream = c < 1 ? 0 : c < 1.3 ? (c - 1) / 0.3 : c < 2.2 ? 1 : Math.max(0, 1 - (c - 2.2) / 0.4);
        const im = face.img, H2 = 15.3 * vsz(F) * (1 + scream * 0.25), W2 = H2 * im.width / im.height, sy = im.height * face.sy, split = 1 + scream * 0.66, sc = H2 / im.height;
        g.save(); g.translate(x + F.jx, y + F.jy); g.rotate(F.rot + Math.sin(S.t * 3 + F.ph) * 0.08);
        g.globalAlpha = F.a; g.shadowColor = 'rgba(93,255,58,.95)'; g.shadowBlur = 16 * H2 / 15.3;
        const draw = () => {
          if (split < 1.08) { g.drawImage(im, -W2 / 2, -H2 / 2, W2, H2); return; }
          const ov = 8;
          g.drawImage(im, 0, sy - ov, im.width, im.height - sy + ov, -W2 / 2, -H2 / 2 + (sy - ov) * sc, W2, (im.height - sy + ov) * sc * split);
          g.drawImage(im, 0, 0, im.width, sy, -W2 / 2, -H2 / 2, W2, sy * sc);
        };
        draw(); g.shadowBlur = 7 * H2 / 15.3; if (split < 1.08) draw();
        g.restore();
      }
      g.globalAlpha = 1; g.globalCompositeOperation = 'lighter';
    },
  },
  blood: {
    glow: false,
    init: () => ({ drips: [], top: null }),
    step(S, g, o, dt, k) {
      const { w, h, ox, oy, sz, calm } = o, rate = (calm ? 1.2 : 2.6) * k;
      // glossy drips of every thickness and length run down from the top edge and both sides; some hang a while
      for (let n = dt * rate; n > 0; n--) {
        if (Math.random() >= n) continue;
        const side = Math.random() < 0.45, x = side ? (Math.random() < 0.5 ? ox + Math.random() * 6 : ox + w - Math.random() * 6) : ox + 4 + Math.random() * (w - 8);
        S.drips.push(D.newDrip(x, side ? oy + Math.random() * h * 0.5 : oy, sz, 85, Math.random() < 0.15));
      }
      if (S.drips.length > 140) S.drips.splice(0, S.drips.length - 140);
      S.drips = D.stepDrips(g, S.drips, calm ? dt * 0.6 : dt, o.H + 10, 0.95);
      // over them, the drip curtain along the top: a band of blood with drips hanging from it
      S.top = S.top || D.makeCurtain(Math.max(8, Math.round(w / 12)));
      D.curtain(g, S.top, ox - 2, ox + w + 2, oy - 3 * sz, 9 * sz, calm ? dt * 0.5 : dt, 1.25 * sz, o.H + 10);
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
    init: () => ({ grow: 0, fall: [], t: 0, vt: 1 }),
    step(S, g, o, dt, k) {
      const { w, h, ox, oy, sz, calm } = o, th = 12 * sz;
      S.t += dt; S.grow = Math.min(1, S.grow + dt / (calm ? 8 : 4));
      const R = { x: ox - th / 2, y: oy - th / 2, w: w + th, h: h + th };
      const fresh = (c) => { c.width = Math.round(o.W * o.dpr); c.height = Math.round(o.H * o.dpr); const v = c.getContext('2d'); v.setTransform(o.dpr, 0, 0, o.dpr, 0, 0); v.clearRect(0, 0, o.W, o.H); return v; };
      // the log frame, moss and cut log ends: baked once per size
      if (!S.frame || S.fw !== o.W || S.fh !== o.H || S.fsz !== sz) {
        S.fw = o.W; S.fh = o.H; S.fsz = sz; S.frame = S.frame || document.createElement('canvas');
        const v = fresh(S.frame);
        v.save(); v.shadowColor = 'rgba(0,0,0,.6)'; v.shadowBlur = 10; v.fillStyle = v.createPattern(D.bark(), 'repeat');
        v.beginPath(); v.rect(ox - th, oy - th, w + th * 2, h + th * 2); v.rect(ox, oy, w, h); v.fill('evenodd'); v.restore();
        v.strokeStyle = 'rgba(255,220,170,.18)'; v.lineWidth = 1; v.strokeRect(ox - th + 0.5, oy - th + 0.5, w + th * 2 - 1, h + th * 2 - 1);
        v.strokeStyle = 'rgba(0,0,0,.6)'; v.strokeRect(ox - 0.5, oy - 0.5, w + 1, h + 1);
        const L = 2 * (R.w + R.h);
        for (let i = 0; i < L / 3.3; i++) { const [x, y] = edgePoint(i * 3.3, R.w, R.h), j = (i * 53) % 7; v.fillStyle = `rgba(${70 + j * 8},${110 + j * 9},${40 + j * 4},${0.5 + j * 0.05})`; v.beginPath(); v.arc(R.x + x + ((i * 31) % 9 - 4) * sz, R.y + y + ((i * 17) % 9 - 4) * sz - 2 * sz, (1.1 + (j % 3) * 0.6) * sz, 0, 7); v.fill(); }
        for (const [cx, cy] of [[R.x, R.y], [R.x + R.w, R.y], [R.x, R.y + R.h], [R.x + R.w, R.y + R.h]]) D.logEnd(v, cx, cy, th * 0.75);
      }
      g.save(); g.setTransform(1, 0, 0, 1, 0, 0); g.drawImage(S.frame, 0, 0); g.restore();
      // two vines creeping round it with leaves swaying: redrawn ten times a second, not every frame
      S.vt += dt;
      if (!S.vines || S.vt > 0.1 || S.vw !== o.W || S.vh !== o.H) {
        S.vt = 0; S.vw = o.W; S.vh = o.H; S.vines = S.vines || document.createElement('canvas');
        const v = fresh(S.vines), Ltot = 2 * (R.w + R.h), reach = S.grow * (0.55 + 0.45 * Math.min(1, k));
        for (const [ph, amp, col, wid] of [[0, 7, '#2f5a1c', 3], [2.4, 5, '#3c6e22', 2.2]]) {
          const n = Math.round(Ltot / 3), pts = [];
          for (let i = 0; i <= n * reach; i++) {
            const d = i / n * Ltot, [ex, ey, sd] = edgePoint(d, R.w, R.h), wv = Math.sin(d * 0.045 / sz + ph + Math.sin(S.t * 0.4) * 0.1) * amp * sz;
            pts.push([R.x + ex + (sd === 1 ? wv : sd === 3 ? -wv : 0), R.y + ey + (sd === 0 ? -wv : sd === 2 ? wv : 0), d]);
          }
          D.strokePts(v, pts, (wid + 1.6) * sz, 'rgba(10,25,6,.6)'); D.strokePts(v, pts, wid * sz, col);
          for (let i = 6; i < pts.length; i += 9) { const [x, y, d] = pts[i]; D.leaf(v, x, y, (9 + (i % 4) * 2) * sz, Math.sin(d * 0.05 / sz + ph) * 1.3 + (i % 2 ? 1.2 : -1.9) + Math.sin(S.t * 1.6 + i) * 0.12, D.LEAF[(i * 37) % 3], true); }
        }
      }
      g.save(); g.setTransform(1, 0, 0, 1, 0, 0); g.drawImage(S.vines, 0, 0); g.restore();
      // the odd leaf falls past
      if (Math.random() < dt * (calm ? 0.5 : 1.2) * k) S.fall.push({ x: ox - 10 + Math.random() * (w + 20), y: oy - 14, r: Math.random() * 6, v: 14 + Math.random() * 12, s: (7 + Math.random() * 4) * sz, c: D.LEAF[Math.floor(Math.random() * 5)] });
      S.fall = S.fall.filter((f) => { f.y += f.v * dt; f.x += Math.sin(f.y * 0.05 + f.r) * 0.6; f.r += dt * 1.4; D.leaf(g, f.x, f.y, f.s, f.r, f.c, false); return f.y < o.H + 10; });
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
    if (theme === 'specter') el.style.borderWidth = (3 * (1 + 1.5 * pt.int / 100)).toFixed(1) + 'px';   // Intensity widens the border up to 2.5x
    T.step(state, g, { w, h, ox: PAD.x, oy: PAD.top, W, H, dpr, sz: mult(pt.size), calm: !!el.closest('.motion-calm') }, dt, mult(pt.int));
    g.globalCompositeOperation = 'source-over';
  };
  const stop = () => { cancelAnimationFrame(raf); cv.remove(); el.style.borderWidth = ''; el.classList.remove('fx-themed'); if (el._themeFx === api) el._themeFx = null; };
  const api = { stop };
  el._themeFx = api;
  raf = requestAnimationFrame(frame);
}
