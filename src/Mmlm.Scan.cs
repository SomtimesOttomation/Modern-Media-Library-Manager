// Mmlm.Scan: the compiled helper for server scans (several downloads at once). It is separate from Mmlm.Native on
// purpose: if it cannot be compiled on a machine, scans fall back to the plain PowerShell path and nothing else breaks.
// Compiled once with Add-Type (see Initialize-MmlmScanNative) and cached as a DLL in %LOCALAPPDATA%.
// Keep this file ASCII-only and C# 5 (no string interpolation, no "?.", no "out var", no expression-bodied members).
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;

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
}
