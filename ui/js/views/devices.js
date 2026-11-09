// Device compatibility (from the old dashboard page): which TVs and players play each title's HDR / Dolby Vision
// natively. Curated from published specs and community reports, NOT lab-tested. Edit the flags to match your hardware.
/* ================= device compatibility ================= */
export const STATUS = {
  full:     {label:'Full',     color:'#4ADE80', tip:'Plays in its native format'},
  partial:  {label:'Partial',  color:'#FACC15', tip:'Plays as Dolby Vision, but the enhancement layer (FEL) is ignored'},
  fallback: {label:'Fallback', color:'#FB923C', tip:'Plays, but drops to HDR10 / HDR10+ / SDR'},
  none:     {label:'Fails',    color:'#FF6C8A', tip:'Wrong colours or no playback'}
};
export const ST_ORDER = ['full', 'partial', 'fallback', 'none'];

/* Capability tables - curated from published specs and community reports (Oct 2026), NOT lab-tested.
   Hover a device name for its caveats, and edit the flags below to match your own hardware / apps.
     dv5, dv8   single-layer Dolby Vision profile 5 and profile 8.x (1 = supported)
     hdr10p     HDR10+ (0 = file falls back to plain HDR10)        hlg   HLG
     dv7        how a dual-layer Profile 7 file is handled:
                'fel'   both layers - FEL and MEL play fully
                'base'  base layer + RPU only - MEL looks right, FEL loses its enhancement layer
                'mel'   MEL plays as Dolby Vision, FEL falls back to HDR10
                'hdr10' no dual-layer support - the HDR10 base layer is shown */
export const DEVICE_GROUPS = [
  {id:'tv', title:'TV Compatibility', devices:[
    {id:'sony',    name:'Sony',    dv5:1, dv8:1, hdr10p:0, hlg:1, dv7:'base', note:'Dolby Vision, HDR10, HLG - no HDR10+. Profile 7 via built-in apps is assumed to play the base layer only (not verified per model).'},
    {id:'lg',      name:'LG',      dv5:1, dv8:1, hdr10p:0, hlg:1, dv7:'base', note:'Dolby Vision, HDR10, HLG - no HDR10+. Profile 7 via built-in apps is assumed to play the base layer only (not verified per model).'},
    {id:'samsung', name:'Samsung', dv5:0, dv8:0, hdr10p:1, hlg:1, dv7:'hdr10', note:'HDR10+ and HDR10 only - Samsung has never supported Dolby Vision, so DV files fall back to HDR10 and Profile 5 shows wrong (green/purple) colours.'},
    {id:'tcl',     name:'TCL',     dv5:1, dv8:1, hdr10p:1, hlg:1, dv7:'base', note:'Dolby Vision and HDR10+ on most models since 2020 - entry-level sets can differ. Profile 7 assumed base layer only.'},
    {id:'hisense', name:'Hisense', dv5:1, dv8:1, hdr10p:1, hlg:1, dv7:'base', note:'Dolby Vision and HDR10+ on most models since 2021 - entry-level sets can differ. Profile 7 assumed base layer only.'}
  ]},
  {id:'box', title:'Streamer & Player Compatibility', devices:[
    {id:'shield',  name:'Nvidia Shield TV',            dv5:1, dv8:1, hdr10p:0, hlg:1, dv7:'base',  note:'Plays Dolby Vision P5 / P8.1. Cannot decode the FEL (enhancement layer ignored, community-reported). No HDR10+ on the current hardware.'},
    {id:'atv1',    name:'Apple TV 4K (2017 / 2021)',   dv5:1, dv8:1, hdr10p:0, hlg:1, dv7:'hdr10', note:'Single-layer Dolby Vision only - dual-layer Profile 7 is not played (HDR10 base layer shown). No HDR10+ on 1st/2nd generation.'},
    {id:'atv3',    name:'Apple TV 4K (2022)',          dv5:1, dv8:1, hdr10p:1, hlg:1, dv7:'hdr10', note:'Single-layer Dolby Vision plus HDR10+. Dual-layer Profile 7 is not played (HDR10 base layer shown).'},
    {id:'atv4',    name:'Apple TV 4K (2026, A19)',     dv5:1, dv8:1, hdr10p:1, hlg:1, dv7:'hdr10', note:'Announced 13 Oct 2026, ships 13 Nov. Same HDR10+ / Dolby Vision support as its predecessor; Profile 7 behaviour assumed unchanged.'},
    {id:'am6b',    name:'Ugoos AM6B+ (CoreELEC-ng)',   dv5:1, dv8:1, hdr10p:0, hlg:1, dv7:'fel',   note:'CoreELEC-ng plays Dolby Vision P4 / 5 / 7 FEL / 7 MEL / 8.1 / 8.4. HDR10+ support not confirmed - counted as an HDR10 fallback.'},
    {id:'firetv',  name:'Fire TV Stick 4K Max',        dv5:1, dv8:1, hdr10p:1, hlg:1, dv7:'base',  note:'Dolby Vision, HDR10+, HLG per Amazon specs. Profile 7 assumed base layer only (not verified).'},
    {id:'gtv',     name:'Google TV Streamer',          dv5:1, dv8:1, hdr10p:1, hlg:1, dv7:'base',  note:'Google lists Dolby Vision, HDR10, HDR10+, HLG. Profile 7 assumed base layer only; some users report Plex/Jellyfin Profile 8 quirks.'},
    {id:'roku',    name:'Roku Ultra',                  dv5:1, dv8:1, hdr10p:1, hlg:1, dv7:'base',  note:'Dolby Vision and HDR10+ (HDR10+ added by 2020 firmware). Profile 7 assumed base layer only (not verified).'},
    {id:'zidoo',   name:'Zidoo Z9X',                   dv5:1, dv8:1, hdr10p:1, hlg:1, dv7:'mel',   note:'Reports (older firmware): MEL plays in Dolby Vision, FEL falls back to HDR10. Check current firmware.'}
  ]}
];
export const ALL_DEVICES = DEVICE_GROUPS.flatMap(g => g.devices);

// What kind of HDR file is this?  (sdr | hdr10 | hdr10p | hlg | dv5 | dv7 | dv8 | dvx)
export function hdrClass(r){
  const t = r.HDRType;
  if (!t || t === 'SDR') return {k:'sdr'};
  if (t === 'Dolby Vision'){
    const p = String(r.DVProfile || ''), major = parseInt(p, 10);
    if (major === 5) return {k:'dv5'};
    if (major === 7) return {k:'dv7', layer:r.DVLayer};
    if (major === 8) return {k:'dv8'};
    return {k:'dvx'};
  }
  if (t === 'HDR10+') return {k:'hdr10p'};
  if (t === 'HLG') return {k:'hlg'};
  return {k:'hdr10'};
}
// full | partial | fallback | none  (null for SDR titles - compatibility only concerns HDR / DV files)
export function deviceStatus(dev, r){
  const c = hdrClass(r);
  switch (c.k){
    case 'sdr':    return null;
    case 'hdr10':  return 'full';
    case 'hlg':    return dev.hlg ? 'full' : 'fallback';
    case 'hdr10p': return dev.hdr10p ? 'full' : 'fallback';
    case 'dv5':    return dev.dv5 ? 'full' : 'none';
    case 'dv8':    return dev.dv8 ? 'full' : 'fallback';
    case 'dv7': {
      const mel = c.layer === 'MEL';      // 'FEL' and an unverified 'Dual layer' are both treated as the harder FEL case
      if (dev.dv7 === 'fel')  return 'full';
      if (dev.dv7 === 'base') return mel ? 'full' : 'partial';
      if (dev.dv7 === 'mel')  return mel ? 'full' : 'fallback';
      return 'fallback';
    }
    default:       return dev.dv8 ? 'partial' : 'fallback';   // rare profiles (4, 10, ...)
  }
}
