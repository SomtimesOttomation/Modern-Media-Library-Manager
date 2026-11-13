// Mmlm.Scan: the compiled helper for server scans (several downloads at once). It is separate from Mmlm.Native on
// purpose: if it cannot be compiled on a machine, scans fall back to the plain PowerShell path and nothing else breaks.
// Compiled once with Add-Type (see Initialize-MmlmScanNative) and cached as a DLL in %LOCALAPPDATA%.
// Keep this file ASCII-only and C# 5 (no string interpolation, no "?.", no "out var", no expression-bodied members).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Xml;

namespace Mmlm.Scan
{
    public sealed class HttpResult
    {
        public string Url;
        public int Status;        // HTTP status, 0 when the server was not reached
        public string Text;       // body as UTF-8 text (text mode)
        public byte[] Data;       // body as bytes (binary mode)
        public long Bytes;        // body length after decompression
        public string Error;      // null when Status is 200
    }

    public static class Http
    {
        // WebRequest.Create(string), found once by reflection: newer .NET marks the direct call obsolete
        static readonly MethodInfo CreateMethod = typeof(WebRequest).GetMethod("Create", new Type[] { typeof(string) });

        // GETs every url, at most 'parallel' at a time. Results come back in the same order as 'urls'.
        // headerNames/headerValues are added to every request. Never throws: a failure is reported in its HttpResult.
        public static HttpResult[] GetMany(string[] urls, string[] headerNames, string[] headerValues, string accept, int timeoutMs, int parallel, bool binary)
        {
            HttpResult[] results = new HttpResult[urls.Length];
            ParallelOptions po = new ParallelOptions();
            po.MaxDegreeOfParallelism = Math.Max(1, Math.Min(parallel, 8));
            Parallel.For(0, urls.Length, po, delegate(int i) { results[i] = GetOne(urls[i], headerNames, headerValues, accept, timeoutMs, binary); });
            return results;
        }

        static HttpResult GetOne(string url, string[] names, string[] values, string accept, int timeoutMs, bool binary)
        {
            HttpResult r = new HttpResult();
            r.Url = url;
            HttpWebResponse resp = null;
            try
            {
                HttpWebRequest req = (HttpWebRequest)CreateMethod.Invoke(null, new object[] { url });
                req.Method = "GET";
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.Accept = accept;
                req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
                for (int i = 0; i < names.Length; i++) req.Headers.Add(names[i], values[i]);
                resp = (HttpWebResponse)req.GetResponse();
                r.Status = (int)resp.StatusCode;
                using (MemoryStream ms = new MemoryStream())
                {
                    using (Stream st = resp.GetResponseStream()) { st.CopyTo(ms); }
                    r.Bytes = ms.Length;
                    if (binary) r.Data = ms.ToArray(); else r.Text = Encoding.UTF8.GetString(ms.ToArray());
                }
            }
            catch (WebException we)
            {
                HttpWebResponse er = we.Response as HttpWebResponse;
                if (er != null) { r.Status = (int)er.StatusCode; er.Close(); }
                r.Error = we.Message;
            }
            catch (Exception ex)
            {
                Exception inner = ex.InnerException != null ? ex.InnerException : ex;
                r.Error = inner.Message;
            }
            finally { if (resp != null) resp.Close(); }
            return r;
        }
    }

    // ---- one Plex <Video> (movie or episode) -> a library record ---------------------------------------------------
    // A line-for-line port of ConvertFrom-MmlmPlexVideo (modules\MMLM.Plex.psm1) and the helpers it calls. The
    // PowerShell function stays as the reference and the fallback; tests\Test-MmlmScanSpeed.ps1 holds both to the same
    // golden records. Change a rule in both places or not at all.
    public static class PlexConvert
    {
        const RegexOptions IC = RegexOptions.IgnoreCase;
        static readonly Regex RxSpaces = new Regex(@"\s+");
        static readonly Regex RxUpright = new Regex("upright|spilled", IC);
        static readonly Regex RxImdbId = new Regex(@"^imdb://(tt\d+)", IC);
        static readonly Regex RxTmdbId = new Regex(@"^tmdb://(\d+)", IC);
        static readonly Regex RxImdbGuid = new Regex(@"imdb://(tt\d+)", IC);
        static readonly Regex RxTmdbGuid = new Regex(@"themoviedb://(\d+)", IC);
        static readonly Regex RxFps = new Regex(@"^(\d+(\.\d+)?)", IC);
        static readonly Regex RxDovi = new Regex("Dolby Vision|DoVi", IC);
        static readonly Regex RxAtmos = new Regex("Atmos", IC);
        static readonly Regex RxDtsxProfile = new Regex("dts-x|dtsx", IC);
        static readonly Regex RxDtsxDisplay = new Regex("DTS[-: ]X", IC);
        static readonly Regex RxDtsMa = new Regex("ma|dts-x|dtsx", IC);
        static readonly Regex RxDtsHra = new Regex("hra", IC);
        static readonly Regex RxDtsEs = new Regex("es", IC);
        static readonly Regex RxHybridWord = new Regex(@"(?i)\bhybrid\b", IC);
        static readonly Regex RxHybridStart = new Regex("^Hybrid", IC);
        static readonly Regex RxSrcRemux = new Regex("(?i)remux", IC);
        static readonly Regex RxSrcBluray = new Regex(@"(?i)blu-?ray|bdrip|brrip|\bbd\b", IC);
        static readonly Regex RxSrcWebDl = new Regex(@"(?i)web[-. ]?dl|\bamzn\b|\bnf\b|\bdsnp\b", IC);
        static readonly Regex RxSrcWebRip = new Regex("(?i)web[-. ]?rip", IC);
        static readonly Regex RxSrcWeb = new Regex(@"(?i)\bweb\b", IC);
        static readonly Regex RxSrcHdtv = new Regex("(?i)hdtv|pdtv", IC);
        static readonly Regex RxSrcDvd = new Regex(@"(?i)dvdrip|\bdvd\b", IC);

        // the record while it is being filled: the field list's order, new names added at the end (an [ordered] table)
        sealed class Rec
        {
            public readonly List<string> Names = new List<string>();
            public readonly Dictionary<string, object> Vals = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            public void Set(string name, object value) { if (!Vals.ContainsKey(name)) Names.Add(name); Vals[name] = value; }
            public object Get(string name) { object v; return Vals.TryGetValue(name, out v) ? v : null; }
            public string Str(string name) { object v = Get(name); return v == null ? "" : Convert.ToString(v, CultureInfo.InvariantCulture); }
        }
        sealed class Ratings { public double Imdb; public double Tmdb; public int RTCritic; public int RTAudience; }

        static int SafeInt(string s, IFormatProvider c) { int r; return int.TryParse(s, NumberStyles.Any, c, out r) ? r : 0; }
        static double SafeDouble(string s, IFormatProvider c) { double r; return double.TryParse(s, NumberStyles.Any, c, out r) ? r : 0.0; }
        static bool Eq(string a, string b) { return string.Equals(a, b, StringComparison.InvariantCultureIgnoreCase); }
        static bool StartsLike(string s, string prefix) { return s != null && s.StartsWith(prefix, StringComparison.InvariantCultureIgnoreCase); }
        static string Inv(int n) { return n.ToString(CultureInfo.InvariantCulture); }

        static List<XmlElement> Children(XmlElement node, string name)
        {
            List<XmlElement> list = new List<XmlElement>();
            if (node == null) return list;
            foreach (XmlNode n in node.ChildNodes) { XmlElement e = n as XmlElement; if (e != null && e.Name == name) list.Add(e); }
            return list;
        }
        static string Tags(XmlElement node, string child, int max)
        {
            if (node == null) return "";
            List<string> v = new List<string>();
            foreach (XmlElement e in Children(node, child)) { string t = e.GetAttribute("tag"); if (t.Length > 0) v.Add(t); }
            if (max > 0 && v.Count > max) v.RemoveRange(max, v.Count - max);
            return string.Join("; ", v.ToArray());
        }
        static string JoinUnique(List<string> values)
        {
            // Select-Object -Unique: case-sensitive, first occurrence kept
            List<string> u = new List<string>();
            foreach (string s in values)
            {
                bool seen = false;
                foreach (string x in u) { if (string.Compare(x, s, false, CultureInfo.CurrentCulture) == 0) { seen = true; break; } }
                if (!seen) u.Add(s);
            }
            return string.Join("; ", u.ToArray());
        }
        static string Epoch(string seconds)
        {
            long n;
            if (long.TryParse(seconds, out n) && n > 0)
            {
                try { return DateTimeOffset.FromUnixTimeSeconds(n).LocalDateTime.ToString("yyyy-MM-dd"); } catch (Exception) { }
            }
            return "";
        }

        static Ratings GetRatings(XmlElement node, IFormatProvider c)
        {
            Ratings o = new Ratings();
            if (node == null) return o;
            List<string[]> pairs = new List<string[]>();
            foreach (XmlElement n in Children(node, "Rating")) pairs.Add(new string[] { n.GetAttribute("image"), n.GetAttribute("value") });
            pairs.Add(new string[] { node.GetAttribute("ratingImage"), node.GetAttribute("rating") });
            pairs.Add(new string[] { node.GetAttribute("audienceRatingImage"), node.GetAttribute("audienceRating") });
            foreach (string[] p in pairs)
            {
                string img = p[0]; double val = SafeDouble(p[1], c);
                if (img.Length == 0 || val <= 0) continue;
                if (StartsLike(img, "imdb://")) { if (o.Imdb <= 0) o.Imdb = val; }
                else if (StartsLike(img, "themoviedb://")) { if (o.Tmdb <= 0) o.Tmdb = val; }
                else if (StartsLike(img, "rottentomatoes://"))
                {
                    int pct = Convert.ToInt32(Math.Round(val * 10));
                    if (pct < 1 || pct > 100) continue;
                    if (RxUpright.IsMatch(img)) { if (o.RTAudience <= 0) o.RTAudience = pct; }
                    else { if (o.RTCritic <= 0) o.RTCritic = pct; }
                }
            }
            return o;
        }
        static double GetRating(XmlElement node, IFormatProvider c)
        {
            if (node == null) return 0.0;
            Ratings r = GetRatings(node, c);
            if (r.Imdb > 0) return r.Imdb;
            if (r.Tmdb > 0) return r.Tmdb;
            if (!StartsLike(node.GetAttribute("audienceRatingImage"), "rottentomatoes://"))
            {
                double a = SafeDouble(node.GetAttribute("audienceRating"), c);
                if (a > 0) return a;
            }
            if (!StartsLike(node.GetAttribute("ratingImage"), "rottentomatoes://")) return SafeDouble(node.GetAttribute("rating"), c);
            return 0.0;
        }
        static string GetRatingSource(XmlElement node, IFormatProvider c)
        {
            if (node == null) return "";
            Ratings r = GetRatings(node, c);
            if (r.Imdb > 0) return "IMDb";
            if (r.Tmdb > 0) return "TMDB";
            return "";
        }

        static void AudioFormat(string codec, string profile, string display, out string label, out string obj)
        {
            string c = codec.ToLowerInvariant(); string p = profile.ToLowerInvariant();
            if (c.StartsWith("truehd", StringComparison.Ordinal)) label = "Dolby TrueHD";
            else if (c.StartsWith("eac3", StringComparison.Ordinal)) label = "Dolby Digital Plus";
            else if (c.StartsWith("ac3", StringComparison.Ordinal)) label = "Dolby Digital";
            else if (c.StartsWith("dca", StringComparison.Ordinal) || c.StartsWith("dts", StringComparison.Ordinal))
            {
                if (RxDtsMa.IsMatch(p)) label = "DTS-HD Master Audio";
                else if (RxDtsHra.IsMatch(p)) label = "DTS-HD High Resolution Audio";
                else if (RxDtsEs.IsMatch(p)) label = "DTS-ES";
                else label = "DTS";
            }
            else if (c.StartsWith("aac", StringComparison.Ordinal)) label = "AAC";
            else if (c.StartsWith("flac", StringComparison.Ordinal)) label = "FLAC";
            else if (c.StartsWith("mp3", StringComparison.Ordinal)) label = "MP3";
            else if (c.StartsWith("opus", StringComparison.Ordinal)) label = "Opus";
            else if (c.StartsWith("vorbis", StringComparison.Ordinal)) label = "Vorbis";
            else if (c.StartsWith("pcm", StringComparison.Ordinal)) label = "PCM";
            else label = c.Length > 0 ? c.ToUpperInvariant() : "Unknown";
            obj = "";
            if (RxAtmos.IsMatch(display)) obj = "Dolby Atmos";
            else if (RxDtsxProfile.IsMatch(p) || RxDtsxDisplay.IsMatch(display)) obj = "DTS:X";
        }
        static string AudioLayout(int channels)
        {
            switch (channels)
            {
                case 0: return "Unknown";
                case 1: return "Mono";
                case 2: return "Stereo";
                case 6: return "5.1";
                case 7: return "6.1";
                case 8: return "7.1";
                default: return Inv(channels) + " ch";
            }
        }
        static string ResolutionClass(int width, int height)
        {
            if (width <= 0 && height <= 0) return "Unknown";
            if (width >= 3400 || height >= 2000) return "4K";
            if (width >= 2400 || height >= 1300) return "1440p";
            if (width >= 1800 || height >= 1000) return "1080p";
            if (width >= 1200 || height >= 700) return "720p";
            return "SD";
        }
        static string SourceFromName(string name)
        {
            if (RxHybridWord.IsMatch(name)) return "DV/HDR Hybrid";
            if (RxSrcRemux.IsMatch(name)) return "Remux";
            if (RxSrcBluray.IsMatch(name)) return "Blu-ray";
            if (RxSrcWebDl.IsMatch(name)) return "WEB-DL";
            if (RxSrcWebRip.IsMatch(name)) return "WEBRip";
            if (RxSrcWeb.IsMatch(name)) return "WEB-DL";
            if (RxSrcHdtv.IsMatch(name)) return "HDTV";
            if (RxSrcDvd.IsMatch(name)) return "DVD";
            return "Unknown";
        }
        static string ResolveSource(string source, string fileName, string hdrType, string dvProfile)
        {
            if (RxHybridWord.IsMatch(fileName)) return "DV/HDR Hybrid";
            if (StartsLike(source, "Hybrid")) source = RxHybridStart.Replace(source, "DV/HDR Hybrid");
            if (source.Length > 0 && !Eq(source, "Unknown")) return source;
            if (!Eq(hdrType, "Dolby Vision")) return "Unknown";
            if (Eq(dvProfile, "7")) return "UHD Blu-ray (inferred)";
            if (Eq(dvProfile, "5")) return "WEB-DL (inferred)";
            if (Eq(dvProfile, "8.1")) return "DV/HDR Hybrid (inferred)";
            return "Unknown";
        }
        static string HdrStack(string hdrType, string dvProfile, string dvLayer, string dvBase)
        {
            if (!Eq(hdrType, "Dolby Vision")) return hdrType;
            string label = "Dolby Vision";
            if (dvProfile.Length > 0) label += " P" + dvProfile;
            if (Eq(dvLayer, "FEL")) label += " FEL";
            else if (Eq(dvLayer, "MEL")) label += " MEL";
            else if (Eq(dvLayer, "Dual layer")) label += " (dual layer)";
            if (Eq(dvBase, "HDR10") || Eq(dvBase, "HLG") || Eq(dvBase, "SDR")) label += " + " + dvBase;
            return label;
        }

        // fieldNames/fieldTypes: the app's field list (name and 'string' / 'int' / 'long' / 'double' / 'bool').
        // culture: the scan's number culture ($script:Culture); titleCase: (Get-Culture).TextInfo.
        public static PSObject Convert(XmlElement video, XmlElement show, string libraryName, string[] fieldNames, string[] fieldTypes, IFormatProvider culture, TextInfo titleCase)
        {
            Rec rec = new Rec();
            for (int i = 0; i < fieldNames.Length; i++)
            {
                object d = null;
                switch (fieldTypes[i])
                {
                    case "string": d = ""; break;
                    case "int": d = 0; break;
                    case "long": d = 0L; break;
                    case "double": d = 0.0; break;
                    case "bool": d = false; break;
                }
                rec.Set(fieldNames[i], d);
            }
            if (libraryName == null) libraryName = "";
            bool isEp = Eq(video.GetAttribute("type"), "episode");
            XmlElement meta = (isEp && show != null) ? show : video;          // tags (genre, cast, ...) live on the show for episodes

            // ---- best media version -> first part -> streams
            XmlElement media = null; int bestW = 0, bestB = 0;
            foreach (XmlElement m in Children(video, "Media"))
            {
                int mw = SafeInt(m.GetAttribute("width"), culture), mb = SafeInt(m.GetAttribute("bitrate"), culture);
                if (media == null || mw > bestW || (mw == bestW && mb > bestB)) { media = m; bestW = mw; bestB = mb; }
            }
            List<XmlElement> parts = new List<XmlElement>(); XmlElement part = null; List<XmlElement> streams = new List<XmlElement>();
            if (media != null)
            {
                parts = Children(media, "Part");
                if (parts.Count > 0) part = parts[0];
                if (part != null) streams = Children(part, "Stream");
            }
            XmlElement vs = null; List<XmlElement> audio = new List<XmlElement>(); List<XmlElement> subs = new List<XmlElement>();
            foreach (XmlElement st in streams)
            {
                string t = st.GetAttribute("streamType");
                if (Eq(t, "1")) { if (vs == null) vs = st; }
                else if (Eq(t, "2")) audio.Add(st);
                else if (Eq(t, "3")) subs.Add(st);
            }
            XmlElement aSel = null;
            foreach (XmlElement a in audio) { if (Eq(a.GetAttribute("selected"), "1")) { aSel = a; break; } }
            if (aSel == null && audio.Count > 0) aSel = audio[0];

            // ---- titles / descriptive metadata
            string title = video.GetAttribute("title");
            rec.Set("Library", libraryName);
            if (isEp)
            {
                int season = SafeInt(video.GetAttribute("parentIndex"), culture);
                int epNum = SafeInt(video.GetAttribute("index"), culture);
                string showTitle = video.GetAttribute("grandparentTitle");
                rec.Set("Show", showTitle);
                rec.Set("Season", season);
                rec.Set("Episode", epNum);
                rec.Set("Title", string.Format(CultureInfo.CurrentCulture, "{0} - S{1:00}E{2:00} - {3}", showTitle, season, epNum, title));
            }
            else rec.Set("Title", title);

            string releaseDate = video.GetAttribute("originallyAvailableAt");
            rec.Set("ReleaseDate", releaseDate);
            int year = SafeInt(video.GetAttribute("year"), culture);
            if (year <= 0 && releaseDate.Length >= 4) year = SafeInt(releaseDate.Substring(0, 4), culture);
            if (year <= 0 && show != null) year = SafeInt(show.GetAttribute("year"), culture);
            rec.Set("Year", year);
            rec.Set("Genre", Tags(meta, "Genre", 0));
            string mpaa = video.GetAttribute("contentRating");
            if (mpaa.Length == 0 && show != null) mpaa = show.GetAttribute("contentRating");
            rec.Set("MPAARating", mpaa);
            double videoRating = GetRating(video, culture);
            double rating = videoRating;
            if (rating <= 0 && show != null) rating = GetRating(show, culture);
            rec.Set("Rating", rating);
            string rsrc = GetRatingSource(video, culture);
            if (rsrc.Length == 0 && videoRating <= 0 && show != null) rsrc = GetRatingSource(show, culture);
            rec.Set("RatingSource", rsrc);
            Ratings rt = GetRatings(video, culture);
            if (rt.RTCritic <= 0 && rt.RTAudience <= 0 && show != null) rt = GetRatings(show, culture);
            if (rt.RTCritic > 0) rec.Set("RTCritic", rt.RTCritic);
            if (rt.RTAudience > 0) rec.Set("RTAudience", rt.RTAudience);
            rec.Set("Studio", meta.GetAttribute("studio"));
            rec.Set("Director", Tags(video, "Director", 3));
            rec.Set("Cast", Tags(meta, "Role", 6));
            rec.Set("Collection", Tags(video, "Collection", 1));
            rec.Set("Country", Tags(meta, "Country", 0));
            rec.Set("Tagline", video.GetAttribute("tagline"));
            rec.Set("Plot", RxSpaces.Replace(video.GetAttribute("summary"), " "));
            foreach (XmlElement g in Children(meta, "Guid"))
            {
                string id = g.GetAttribute("id");
                Match mi = RxImdbId.Match(id);
                if (mi.Success) rec.Set("IMDBID", mi.Groups[1].Value);
                else { Match mt = RxTmdbId.Match(id); if (mt.Success) rec.Set("TMDBID", mt.Groups[1].Value); }
            }
            if (rec.Str("IMDBID").Length == 0) { Match mg = RxImdbGuid.Match(meta.GetAttribute("guid")); if (mg.Success) rec.Set("IMDBID", mg.Groups[1].Value); }
            if (rec.Str("TMDBID").Length == 0) { Match mg2 = RxTmdbGuid.Match(meta.GetAttribute("guid")); if (mg2.Success) rec.Set("TMDBID", mg2.Groups[1].Value); }

            // ---- file / container
            string file = part != null ? part.GetAttribute("file") : "";
            double durMs = media != null ? SafeDouble(media.GetAttribute("duration"), culture) : 0.0;
            if (durMs <= 0) durMs = SafeDouble(video.GetAttribute("duration"), culture);
            double sizeBytes = 0.0;
            foreach (XmlElement p in parts) sizeBytes += SafeDouble(p.GetAttribute("size"), culture);
            double overallKbps = media != null ? SafeDouble(media.GetAttribute("bitrate"), culture) : 0.0;
            string cont = media != null ? media.GetAttribute("container") : "";

            rec.Set("RuntimeMin", Math.Round(durMs / 60000, 2));
            string fileName = file.Length > 0 ? Path.GetFileName(file) : "";
            rec.Set("FileName", fileName);
            rec.Set("Ext", file.Length > 0 ? Path.GetExtension(file).TrimStart('.').ToLowerInvariant() : cont);
            rec.Set("Type", "Video");
            string cl = cont.ToLowerInvariant(); string container;
            if (cl.StartsWith("mkv", StringComparison.Ordinal)) container = "Matroska";
            else if (cl.StartsWith("mp4", StringComparison.Ordinal) || cl.StartsWith("m4v", StringComparison.Ordinal) || cl.StartsWith("mov", StringComparison.Ordinal)) container = "MPEG-4";
            else if (cl.StartsWith("avi", StringComparison.Ordinal)) container = "AVI";
            else if (cl.StartsWith("ts", StringComparison.Ordinal) || cl.StartsWith("mpegts", StringComparison.Ordinal)) container = "MPEG-TS";
            else if (cl.StartsWith("m2ts", StringComparison.Ordinal)) container = "BDAV";
            else container = cont.Length > 0 ? cont.ToUpperInvariant() : "";
            rec.Set("Container", container);
            rec.Set("FileSizeGB", Math.Round(sizeBytes / 1073741824.0, 2));
            rec.Set("OverallBitRateMbps", Math.Round(overallKbps / 1000, 2));
            string source = file.Length > 0 ? SourceFromName(Path.GetFileNameWithoutExtension(file)) : "Unknown";
            rec.Set("Source", source);
            rec.Set("Added", Epoch(video.GetAttribute("addedAt")));
            rec.Set("Modified", Epoch(video.GetAttribute("updatedAt")));
            if (file.Length > 0)
            {
                int cut = file.LastIndexOfAny(new char[] { '\\', '/' });
                rec.Set("Directory", cut > 0 ? file.Substring(0, cut) : "");
            }
            rec.Set("FullPath", file);
            rec.Set("HasNfo", true);
            rec.Set("ViewCount", SafeInt(video.GetAttribute("viewCount"), culture));
            rec.Set("LastViewed", Epoch(video.GetAttribute("lastViewedAt")));
            rec.Set("PlexKey", video.GetAttribute("ratingKey"));
            string thumb = (isEp && video.GetAttribute("grandparentThumb").Length > 0) ? video.GetAttribute("grandparentThumb") : video.GetAttribute("thumb");
            rec.Set("PlexThumb", thumb);

            // ---- video
            int w = media != null ? SafeInt(media.GetAttribute("width"), culture) : 0;
            int h = media != null ? SafeInt(media.GetAttribute("height"), culture) : 0;
            if (vs != null)
            {
                if (w <= 0) w = SafeInt(vs.GetAttribute("width"), culture);
                if (h <= 0) h = SafeInt(vs.GetAttribute("height"), culture);
            }
            string codecRaw = vs != null ? vs.GetAttribute("codec") : (media != null ? media.GetAttribute("videoCodec") : "");
            string cr = codecRaw.ToLowerInvariant(); string codec;
            if (cr.StartsWith("hevc", StringComparison.Ordinal) || cr.StartsWith("h265", StringComparison.Ordinal)) codec = "HEVC";
            else if (cr.StartsWith("h264", StringComparison.Ordinal) || cr.StartsWith("avc", StringComparison.Ordinal)) codec = "AVC";
            else if (cr.StartsWith("vc1", StringComparison.Ordinal)) codec = "VC-1";
            else if (cr.StartsWith("mpeg2", StringComparison.Ordinal)) codec = "MPEG";
            else if (cr.StartsWith("mpeg4", StringComparison.Ordinal)) codec = "MPEG-4 Visual";
            else if (cr.StartsWith("av1", StringComparison.Ordinal)) codec = "AV1";
            else if (cr.StartsWith("vp9", StringComparison.Ordinal)) codec = "VP9";
            else codec = codecRaw.Length > 0 ? codecRaw.ToUpperInvariant() : "";
            double fps = vs != null ? SafeDouble(vs.GetAttribute("frameRate"), culture) : 0.0;
            if (fps <= 0 && media != null) { Match mf = RxFps.Match(media.GetAttribute("videoFrameRate")); if (mf.Success) fps = SafeDouble(mf.Groups[1].Value, culture); }
            double vbr = vs != null ? SafeDouble(vs.GetAttribute("bitrate"), culture) * 1000 : 0.0;
            if (vbr <= 0) vbr = overallKbps * 1000;

            rec.Set("Width", w);
            rec.Set("Height", h);
            rec.Set("Resolution", w > 0 ? Inv(w) + "x" + Inv(h) : "");
            rec.Set("ResolutionClass", ResolutionClass(w, h));
            rec.Set("DAR", media != null ? SafeDouble(media.GetAttribute("aspectRatio"), culture) : 0.0);
            rec.Set("VideoCodec", codec);
            if (vs != null) rec.Set("FormatProfile", titleCase.ToTitleCase(vs.GetAttribute("profile")));
            rec.Set("VideoBitRateMbps", Math.Round(vbr / 1000000, 2));
            rec.Set("FrameRate", fps);
            double pixelRate = (double)w * (double)h * fps;
            rec.Set("BitsPerPixel", (pixelRate > 0 && vbr > 0) ? Math.Round(vbr / pixelRate, 3) : 0.0);
            if (vs != null)
            {
                string scan = vs.GetAttribute("scanType");
                rec.Set("ScanType", scan.Length > 0 ? titleCase.ToTitleCase(scan) : "");
                rec.Set("BitDepth", SafeInt(vs.GetAttribute("bitDepth"), culture));
                rec.Set("ChromaSubsampling", vs.GetAttribute("chromaSubsampling"));
                string range = vs.GetAttribute("colorRange");
                rec.Set("ColorRange", Eq(range, "tv") ? "Limited" : (Eq(range, "pc") ? "Full" : range));
            }

            // ---- HDR / Dolby Vision (Plex exposes the DOVI* flags on the video stream)
            string trc = vs != null ? vs.GetAttribute("colorTrc") : "";
            string display = vs != null ? (vs.GetAttribute("displayTitle") + " " + vs.GetAttribute("extendedDisplayTitle")) : "";
            bool doviOn = false;
            if (vs != null)
            {
                string dp = vs.GetAttribute("DOVIPresent");
                doviOn = Eq(dp, "1") || Eq(dp, "true") || RxDovi.IsMatch(display);
            }
            string hdrType = doviOn ? "Dolby Vision" : (Eq(trc, "smpte2084") ? "HDR10" : (Eq(trc, "arib-std-b67") ? "HLG" : "SDR"));

            string dvProfile = "", dvLayer = "", dvBase = "";
            if (doviOn)
            {
                int num = SafeInt(vs.GetAttribute("DOVIProfile"), culture);
                string compat = vs.GetAttribute("DOVIBLCompatID"); string bas;
                if (Eq(compat, "1") || Eq(compat, "6")) bas = "HDR10";
                else if (Eq(compat, "2")) bas = "SDR";
                else if (Eq(compat, "4")) bas = "HLG";
                else bas = "None";
                if (num == 5) bas = "None";
                string prof = "";
                if (num > 0)
                {
                    prof = Inv(num);
                    if (num == 8 || num == 10)
                    {
                        if (bas == "HDR10") prof = Inv(num) + ".1";
                        else if (bas == "SDR") prof = Inv(num) + ".2";
                        else if (bas == "HLG") prof = Inv(num) + ".4";
                    }
                }
                string el = vs.GetAttribute("DOVIELPresent");
                bool dual = Eq(el, "1") || Eq(el, "true") || num == 4 || num == 7;
                dvProfile = prof;
                dvBase = bas;
                dvLayer = num <= 0 ? "" : (dual ? "Dual layer" : "Single layer");
            }
            rec.Set("HDRType", hdrType);
            rec.Set("DVProfile", dvProfile);
            rec.Set("DVLayer", dvLayer);
            rec.Set("DVBase", dvBase);
            rec.Set("HasHDR10Plus", false);         // Plex does not report HDR10+ (dynamic metadata)
            rec.Set("HDRStack", HdrStack(hdrType, dvProfile, dvLayer, dvBase));
            rec.Set("Source", ResolveSource(rec.Str("Source"), rec.Str("FileName"), hdrType, dvProfile));
            rec.Set("HDRFormat", hdrType == "Dolby Vision" ? "Dolby Vision" : (hdrType == "HDR10" ? "SMPTE ST 2084" : (hdrType == "HLG" ? "HLG" : "")));
            if (doviOn)
            {
                rec.Set("HDRFormatLevel", vs.GetAttribute("DOVILevel"));
                rec.Set("HDRFormatSettings", dvLayer == "Dual layer" ? "BL+EL+RPU" : "BL+RPU");
                rec.Set("HDRFormatCompat", dvBase);
            }
            if (vs != null)
            {
                rec.Set("Primaries", vs.GetAttribute("colorPrimaries"));
                rec.Set("Transfer", trc);
                rec.Set("Matrix", vs.GetAttribute("colorSpace"));
            }

            // ---- audio (the selected / first track)
            if (aSel != null)
            {
                int ch = SafeInt(aSel.GetAttribute("channels"), culture);
                string adis = aSel.GetAttribute("displayTitle") + " " + aSel.GetAttribute("extendedDisplayTitle");
                string label, obj;
                AudioFormat(aSel.GetAttribute("codec"), aSel.GetAttribute("profile"), adis, out label, out obj);
                rec.Set("AudioFormat", label);
                rec.Set("ObjectAudio", obj);
                rec.Set("AudioTitle", aSel.GetAttribute("title"));
                rec.Set("AudioBitRateKbps", System.Convert.ToInt32(SafeDouble(aSel.GetAttribute("bitrate"), culture)));
                rec.Set("AudioChannels", ch);
                rec.Set("AudioLayout", AudioLayout(ch));
                rec.Set("AudioSamplingRate", aSel.GetAttribute("samplingRate"));
                rec.Set("AudioBitDepth", aSel.GetAttribute("bitDepth"));
            }
            else if (media != null)
            {
                int ch2 = SafeInt(media.GetAttribute("audioChannels"), culture);
                string label2, obj2;
                AudioFormat(media.GetAttribute("audioCodec"), media.GetAttribute("audioProfile"), "", out label2, out obj2);
                rec.Set("AudioFormat", label2);
                rec.Set("AudioChannels", ch2);
                rec.Set("AudioLayout", AudioLayout(ch2));
            }
            rec.Set("AudioTracks", audio.Count);
            List<string> langs = new List<string>();
            foreach (XmlElement a in audio) { string l = a.GetAttribute("language"); if (l.Length > 0) langs.Add(l); }
            rec.Set("AudioLanguages", JoinUnique(langs));

            // ---- subtitles
            rec.Set("SubtitleTracks", subs.Count);
            List<string> sl = new List<string>(); List<string> sf = new List<string>();
            foreach (XmlElement s in subs)
            {
                string l = s.GetAttribute("language"); if (l.Length > 0) sl.Add(l);
                string f = s.GetAttribute("codec"); if (f.Length > 0) sf.Add(f.ToUpperInvariant());
            }
            rec.Set("SubtitleLanguages", JoinUnique(sl));
            rec.Set("SubtitleFormats", JoinUnique(sf));

            PSObject o = new PSObject();
            foreach (string name in rec.Names) o.Properties.Add(new PSNoteProperty(name, rec.Vals[name]));
            return o;
        }
    }
}
