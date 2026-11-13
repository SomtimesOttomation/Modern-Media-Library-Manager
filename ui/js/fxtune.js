// Versus (Fun mode) tuning: the VS colours and, for each element with a glow or animation, on/off, size and
// intensity (0-100; 50 is the designed look). Kept in the page settings as fxTune (JSON text) and vsColors.
import * as S from './store.js';

export const VS_DEFAULT = ['#ffe9a8', '#ff8a1a', '#e0300a'];   // top, middle, base
export const ELEMENTS = [
  ['vs', 'VS logo', 'The VS: its size, and how hard it glows and burns'],
  ['poster', 'Posters', 'The glow and the flames around each poster'],
  ['embers', 'Embers', 'Sparks rising off the VS'],
  ['skulls', 'Skulls', 'The skulls on the bar: size and glow'],
  ['bar', 'Progress bar', 'The bar between the two titles: thickness and glow'],
];
const DEF = { vs: [1, 50, 50], poster: [1, 50, 50], embers: [1, 50, 50], skulls: [1, 50, 50], bar: [1, 50, 50] };

export function tune() {
  let t = {};
  try { t = JSON.parse(S.state.settings.fxTune || '{}') || {}; } catch (e) { t = {}; }
  const o = {};
  for (const [k] of ELEMENTS) {
    const v = Array.isArray(t[k]) ? t[k] : DEF[k];
    o[k] = { on: v[0] !== 0, size: clamp(v[1], DEF[k][1]), int: clamp(v[2], DEF[k][2]) };
  }
  return o;
}
const clamp = (v, d) => { v = Number(v); return Number.isFinite(v) ? Math.max(0, Math.min(100, Math.round(v))) : d; };
// size or intensity as a multiplier: 0 -> 0.25, 50 -> 1, 100 -> 2
export const mult = (v) => (v <= 50 ? 0.25 + (v / 50) * 0.75 : 1 + (v - 50) / 50);

export function saveTune(k, field, value) {
  const t = tune(), o = {};
  for (const [id] of ELEMENTS) o[id] = [t[id].on ? 1 : 0, t[id].size, t[id].int];
  const i = { on: 0, size: 1, int: 2 }[field];
  o[k][i] = field === 'on' ? (value ? 1 : 0) : clamp(value, o[k][i]);
  return S.saveSettings({ fxTune: JSON.stringify(o) });
}
export const resetTune = () => S.saveSettings({ fxTune: '', vsColors: VS_DEFAULT.slice() });
export function vsColors() {
  const c = S.state.settings.vsColors;
  return Array.isArray(c) && c.length === 3 && c.every((x) => /^#[0-9a-f]{6}$/i.test(x)) ? c : VS_DEFAULT;
}

// The Versus tab glows for a minute after Fun mode is turned on, or until it is opened
const GLOW_KEY = 'mmlm.versusGlowUntil';
export function startTabGlow() { try { localStorage.setItem(GLOW_KEY, String(Date.now() + 60000)); } catch (e) { /* ignore */ } }
export function stopTabGlow() { try { localStorage.removeItem(GLOW_KEY); } catch (e) { /* ignore */ } }
export function tabGlowLeft() { let u = 0; try { u = Number(localStorage.getItem(GLOW_KEY)) || 0; } catch (e) { u = 0; } return Math.max(0, u - Date.now()); }
