// Mmlm.Native: the small compiled helper of Modern Media Library Manager (TV page data and the library snapshot).
// Compiled once with Add-Type and cached as a DLL in %LOCALAPPDATA% (the version is in the file name).
// Keep this file ASCII-only.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Management.Automation;
using System.IO;
using System.Text;

namespace Mmlm.Native
{
    public static class TvData
    {
        internal static object Get(PSObject o, string name)
        {
            PSPropertyInfo p = o.Properties[name];
            if (p == null) return null;
            object v = p.Value;
            if (v is PSObject) v = ((PSObject)v).BaseObject;
            return v;
        }
        static string Str(PSObject o, string name) { object v = Get(o, name); return v == null ? "" : Convert.ToString(v, CultureInfo.InvariantCulture); }
        static double Num(PSObject o, string name)
        {
            object v = Get(o, name); if (v == null) return 0;
            double d; return double.TryParse(Convert.ToString(v, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d : 0;
        }
        internal static void JStr(StringBuilder sb, string s)
        {
            if (string.IsNullOrEmpty(s)) { sb.Append("null"); return; }
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '<': sb.Append("\\u003c"); break;
                    default:
                        if (c < 0x20 || c > 0x7e) sb.Append("\\u").Append(((int)c).ToString("x4")); else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }
        static void JNum(StringBuilder sb, double d) { sb.Append(d == 0 ? "0" : d.ToString("0.##", CultureInfo.InvariantCulture)); }

        // Groups episode records by show and season and returns the show names in display order.
        public static Dictionary<string, SortedDictionary<int, List<PSObject>>> Index(object[] records)
        {
            var idx = new Dictionary<string, SortedDictionary<int, List<PSObject>>>(StringComparer.Ordinal);
            foreach (object r in records)
            {
                PSObject o = r as PSObject ?? PSObject.AsPSObject(r);
                string show = Str(o, "Show");
                if (show.Length == 0) continue;
                SortedDictionary<int, List<PSObject>> seasons;
                if (!idx.TryGetValue(show, out seasons)) { seasons = new SortedDictionary<int, List<PSObject>>(); idx[show] = seasons; }
                int sn = (int)Num(o, "Season");
                List<PSObject> list;
                if (!seasons.TryGetValue(sn, out list)) { list = new List<PSObject>(); seasons[sn] = list; }
                list.Add(o);
            }
            return idx;
        }

        public static string[] ShowOrder(Dictionary<string, SortedDictionary<int, List<PSObject>>> idx)
        {
            var names = new List<string>(idx.Keys);
            names.Sort(StringComparer.OrdinalIgnoreCase);
            return names.ToArray();
        }

        public static int MinYear(SortedDictionary<int, List<PSObject>> seasons)
        {
            int y = 0;
            foreach (var kv in seasons) foreach (PSObject o in kv.Value) { int v = (int)Num(o, "Year"); if (v > 0 && (y == 0 || v < y)) y = v; }
            return y;
        }

        public static PSObject FirstEpisode(SortedDictionary<int, List<PSObject>> seasons)
        {
            foreach (var kv in seasons) if (kv.Value.Count > 0) return kv.Value[0];
            return null;
        }

        public static string BuildJs(Dictionary<string, SortedDictionary<int, List<PSObject>>> idx, IDictionary posters, string library, string generated)
        {
            var sb = new StringBuilder(8 * 1024 * 1024);
            sb.Append("window.TVDATA={\"generated\":"); JStr(sb, generated);
            sb.Append(",\"library\":"); JStr(sb, library);
            sb.Append(",\"cols\":[\"e\",\"title\",\"year\",\"rating\",\"runtime\",\"res\",\"codec\",\"hdr\",\"audio\",\"size\",\"added\",\"aired\"],\"shows\":[");
            bool firstShow = true;
            foreach (string show in ShowOrder(idx))
            {
                var seasons = idx[show];
                PSObject f = FirstEpisode(seasons);
                if (!firstShow) sb.Append(','); firstShow = false;
                sb.Append("{\"n\":"); JStr(sb, show);
                sb.Append(",\"p\":"); JStr(sb, posters != null && posters.Contains(show) ? Convert.ToString(posters[show]) : "");
                sb.Append(",\"lib\":"); JStr(sb, Str(f, "Library"));
                sb.Append(",\"genre\":"); JStr(sb, Str(f, "Genre"));
                sb.Append(",\"studio\":"); JStr(sb, Str(f, "Studio"));
                sb.Append(",\"cert\":"); JStr(sb, Str(f, "MPAARating"));
                sb.Append(",\"seasons\":[");
                bool firstSeason = true;
                foreach (var kv in seasons)
                {
                    if (!firstSeason) sb.Append(','); firstSeason = false;
                    sb.Append("{\"s\":").Append(kv.Key).Append(",\"eps\":[");
                    var eps = new List<PSObject>(kv.Value);
                    eps.Sort((a, b) => { int c = Num(a, "Episode").CompareTo(Num(b, "Episode")); return c != 0 ? c : string.CompareOrdinal(Str(a, "Title"), Str(b, "Title")); });
                    bool firstEp = true;
                    foreach (PSObject r in eps)
                    {
                        if (!firstEp) sb.Append(','); firstEp = false;
                        string t = Str(r, "Title");
                        if (t.StartsWith(show + " - ", StringComparison.Ordinal)) t = t.Substring(show.Length + 3);
                        string a1 = Str(r, "AudioFormat"), a2 = Str(r, "AudioLayout");
                        string audio = (a1 + " " + a2).Trim();
                        sb.Append('['); JNum(sb, Num(r, "Episode"));
                        sb.Append(','); JStr(sb, t);
                        sb.Append(','); JNum(sb, Num(r, "Year"));
                        sb.Append(','); JNum(sb, Num(r, "Rating"));
                        sb.Append(','); JNum(sb, Num(r, "RuntimeMin"));
                        sb.Append(','); JStr(sb, Str(r, "ResolutionClass"));
                        sb.Append(','); JStr(sb, Str(r, "VideoCodec"));
                        sb.Append(','); JStr(sb, Str(r, "HDRType"));
                        sb.Append(','); JStr(sb, audio);
                        sb.Append(','); JNum(sb, Num(r, "FileSizeGB"));
                        sb.Append(','); JStr(sb, Str(r, "Added"));
                        sb.Append(','); JStr(sb, Str(r, "ReleaseDate"));
                        sb.Append(']');
                    }
                    sb.Append("]}");
                }
                sb.Append("]}");
            }
            sb.Append("]};");
            return sb.ToString();
        }
    }
    public static class Snapshot
    {
        // The library snapshot: every record of the last scan in one compact binary file, so the app opens on it without contacting Plex.
        const int Magic = 0x31534D4D;   // "MMS1"
        public static string LastMeta = "";

        static void WriteInt(BinaryWriter w, int v) { uint u = (uint)v; while (u >= 0x80) { w.Write((byte)(u | 0x80)); u >>= 7; } w.Write((byte)u); }
        static int ReadInt(BinaryReader r) { int v = 0, shift = 0; byte b; do { b = r.ReadByte(); v |= (b & 0x7F) << shift; shift += 7; } while ((b & 0x80) != 0); return v; }

        static void WriteVal(BinaryWriter w, object v)
        {
            if (v is PSObject) v = ((PSObject)v).BaseObject;
            if (v == null || v is DBNull) { w.Write((byte)0); return; }
            if (v is string) { string s = (string)v; if (s.Length == 0) { w.Write((byte)8); return; } w.Write((byte)1); w.Write(s); return; }
            if (v is int) { w.Write((byte)2); w.Write((int)v); return; }
            if (v is long) { w.Write((byte)3); w.Write((long)v); return; }
            if (v is double) { w.Write((byte)4); w.Write((double)v); return; }
            if (v is float || v is decimal) { w.Write((byte)4); w.Write(Convert.ToDouble(v, CultureInfo.InvariantCulture)); return; }
            if (v is bool) { w.Write((byte)5); w.Write((bool)v); return; }
            if (v is DateTime) { w.Write((byte)6); w.Write(((DateTime)v).ToBinary()); return; }
            if (v is Array) { Array a = (Array)v; w.Write((byte)7); WriteInt(w, a.Length); foreach (object x in a) WriteVal(w, x); return; }
            if (v is short || v is byte) { w.Write((byte)2); w.Write(Convert.ToInt32(v)); return; }
            w.Write((byte)1); w.Write(Convert.ToString(v, CultureInfo.InvariantCulture));
        }
        static object ReadVal(BinaryReader r)
        {
            byte t = r.ReadByte();
            switch (t)
            {
                case 0: return null;
                case 1: return r.ReadString();
                case 2: return r.ReadInt32();
                case 3: return r.ReadInt64();
                case 4: return r.ReadDouble();
                case 5: return r.ReadBoolean();
                case 6: return DateTime.FromBinary(r.ReadInt64());
                case 7: { int n = ReadInt(r); object[] a = new object[n]; for (int i = 0; i < n; i++) a[i] = ReadVal(r); return a; }
                case 8: return "";
                default: throw new InvalidDataException("Unknown value tag " + t);
            }
        }

        public static void Save(object[] records, string path, string meta)
        {
            string tmp = path + ".tmp";
            var names = new Dictionary<string, int>(StringComparer.Ordinal);
            using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            using (var w = new BinaryWriter(fs, Encoding.UTF8))
            {
                w.Write(Magic); w.Write(meta ?? ""); WriteInt(w, records.Length);
                foreach (object rec in records)
                {
                    PSObject o = rec as PSObject ?? PSObject.AsPSObject(rec);
                    var props = new List<PSPropertyInfo>();
                    foreach (PSPropertyInfo p in o.Properties) if (p is PSNoteProperty) props.Add(p);
                    WriteInt(w, props.Count);
                    foreach (PSPropertyInfo p in props)
                    {
                        int ix;
                        if (names.TryGetValue(p.Name, out ix)) WriteInt(w, ix + 1);
                        else { names[p.Name] = names.Count; WriteInt(w, 0); w.Write(p.Name); }
                        WriteVal(w, p.Value);
                    }
                }
            }
            if (File.Exists(path)) File.Delete(path);
            File.Move(tmp, path);
        }

        public static object[] Load(string path)
        {
            var names = new List<string>();
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
            using (var r = new BinaryReader(fs, Encoding.UTF8))
            {
                if (r.ReadInt32() != Magic) throw new InvalidDataException("Not a library snapshot: " + path);
                LastMeta = r.ReadString();
                int n = ReadInt(r);
                var outp = new object[n];
                for (int i = 0; i < n; i++)
                {
                    var o = new PSObject();
                    int pc = ReadInt(r);
                    for (int k = 0; k < pc; k++)
                    {
                        int ix = ReadInt(r);
                        string name;
                        if (ix == 0) { name = r.ReadString(); names.Add(name); } else name = names[ix - 1];
                        o.Properties.Add(new PSNoteProperty(name, ReadVal(r)));
                    }
                    outp[i] = o;
                }
                return outp;
            }
        }
    }

    public static class PageData
    {
        // The library for the HTML page: {"fields":[...],"rows":[[...],...]}, one array per record in field order.
        // Poster paths are swapped for the page's own URLs (posterUrls: path -> "thumbs/x.jpg"); paths never reach the page.
        // "Rid" is each title's id for collections: "p:<Plex key>", or for a local file the hashed id in localIds (path -> "h:...").
        public static string Rows(object[] records, string[] fields, IDictionary posterUrls, string fieldsJson, IDictionary localIds)
        {
            var sb = new StringBuilder(records.Length * 400 + 1024);
            sb.Append("{\"fields\":").Append(fieldsJson).Append(",\"rows\":[");
            bool firstRec = true;
            foreach (object rec in records)
            {
                PSObject o = rec as PSObject ?? PSObject.AsPSObject(rec);
                if (!firstRec) sb.Append(',');
                firstRec = false;
                sb.Append('[');
                for (int i = 0; i < fields.Length; i++)
                {
                    if (i > 0) sb.Append(',');
                    if (fields[i] == "Rid")
                    {
                        object pk = TvData.Get(o, "PlexKey");
                        string k = pk == null ? "" : Convert.ToString(pk, CultureInfo.InvariantCulture);
                        if (k.Length > 0) { TvData.JStr(sb, "p:" + k); continue; }
                        object fp = TvData.Get(o, "FullPath");
                        string f = fp == null ? "" : Convert.ToString(fp, CultureInfo.InvariantCulture);
                        object rid = (f.Length > 0 && localIds != null && localIds.Contains(f)) ? localIds[f] : null;
                        TvData.JStr(sb, rid == null ? "" : Convert.ToString(rid, CultureInfo.InvariantCulture));
                        continue;
                    }
                    if (fields[i] == "Poster")
                    {
                        object pp = TvData.Get(o, "PosterPath");
                        string key = pp == null ? "" : Convert.ToString(pp, CultureInfo.InvariantCulture);
                        object url = (key.Length > 0 && posterUrls != null && posterUrls.Contains(key)) ? posterUrls[key] : null;
                        TvData.JStr(sb, url == null ? "" : Convert.ToString(url, CultureInfo.InvariantCulture));
                        continue;
                    }
                    Val(sb, TvData.Get(o, fields[i]));
                }
                sb.Append(']');
            }
            sb.Append("]}");
            return sb.ToString();
        }
        static void Val(StringBuilder sb, object v)
        {
            if (v == null || v is DBNull) { sb.Append("null"); return; }
            if (v is string) { TvData.JStr(sb, (string)v); return; }
            if (v is bool) { sb.Append((bool)v ? "true" : "false"); return; }
            if (v is int || v is long || v is short || v is byte) { sb.Append(Convert.ToInt64(v).ToString(CultureInfo.InvariantCulture)); return; }
            if (v is double || v is float || v is decimal)
            {
                double d = Convert.ToDouble(v, CultureInfo.InvariantCulture);
                if (double.IsNaN(d) || double.IsInfinity(d)) { sb.Append("null"); return; }
                sb.Append(d == 0 ? "0" : d.ToString("0.###", CultureInfo.InvariantCulture)); return;
            }
            if (v is DateTime) { TvData.JStr(sb, ((DateTime)v).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture)); return; }
            if (v is Array)
            {
                var parts = new List<string>();
                foreach (object x in (Array)v) { object y = x is PSObject ? ((PSObject)x).BaseObject : x; if (y != null) parts.Add(Convert.ToString(y, CultureInfo.InvariantCulture)); }
                TvData.JStr(sb, string.Join(", ", parts.ToArray())); return;
            }
            TvData.JStr(sb, Convert.ToString(v, CultureInfo.InvariantCulture));
        }
    }
}
