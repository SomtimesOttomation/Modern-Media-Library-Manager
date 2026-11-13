# Plex scan speed-up: plan and roadmap

**For:** the model that will build this (Opus 5.5, low effort). Follow it step by step, in order. Do not redesign it.
**Goal:** make a Plex scan of a 55,000-entry library much faster, with every record coming out exactly as it does today.
**Background:** `MMLM-Server-Scanning.md` (sent in chat earlier) describes how the scan works today. This plan assumes you have read `modules/MMLM.Plex.psm1` function `Invoke-MmlmPlexScan` and the `$script:ScanScript` block in `modules/MMLM.Host.psm1`.

## 0. Rules that apply to every step

1. **Workflow.** One branch per phase, named as given below. Commit and push as you go. Never merge; the user merges with "commit merge". Every report ends with a test zip and its `.sha256` sent in chat, and the line `Zip sent: <file>`. Build the zip with:
   `git archive --format=zip --prefix=Modern-Media-Library-Manager/ -o /mnt/user-data/outputs/Modern-Media-Library-Manager-v<VERSION>-<branch-with-dashes>.zip HEAD`
   Never use `rm` with variables in the path.
2. **PowerShell 5.1.** All `.ps1` / `.psm1` files stay ASCII-only and must run on Windows PowerShell 5.1. No ternary, no `??`, no `-Parallel`.
3. **C# is C# 5.** `src/Mmlm.Native.cs` is compiled by `Add-Type` on .NET Framework. Do not use string interpolation (`$"..."`), `?.`, `out var`, expression-bodied members, `nameof`, tuples or `async`/`await`. It must also compile under PowerShell 7 (the tests run there).
4. **Traffic gate.** Before any network call, or any wave of parallel calls: `Assert-MmlmTrafficAllowed`. After each response: `Add-MmlmTraffic -Bytes <n>`, or `Add-MmlmTraffic -Failed` for a failure. One call per request, including requests made in parallel.
5. **Cancel and progress.** Check `Test-MmlmScanCancelled` at least once per wave. Keep calling `Set-MmlmProgress` with the same texts as today ("Listing ...", "Reading Plex metadata: X of Y", "Posters: ...").
6. **Token in headers only.** Never put the Plex token in a URL.
7. **Records must not change.** Same fields, same values, same order of records. Section 2 gives the test that proves it. Run it after every phase.
8. **Do not touch Jellyfin** in phases 1 to 4. Phase 6 applies the same ideas to it.
9. **Function signatures stay the same.** `Invoke-MmlmPlexScan` is also called by the window app (`Modern-Media-Library-Manager.ps1`). Grep for every caller before changing behaviour, and keep old behaviour for callers that do not opt in.
10. **Run all tests before each report:** `tests/Test-MmlmHost.ps1`, `Test-MmlmServer.ps1`, `Test-MmlmDoctor.ps1`, `Test-MmlmJellyfin.ps1`, `tests/page-e2e.js`, and the new `tests/Test-MmlmScanSpeed.ps1`. Start `tests/plex-mock.py` (port 32499) and `tests/jellyfin-mock.py` (port 8099) first; check they are still running if a test times out. Use a fresh `LOCALAPPDATA` scratch folder per run and `MMLM_HOST_TEST_TOKEN=tok`.
11. **Explain results to the user in plain language.** They are not a programmer. Give timings as "before X, after Y".

## 1. Roadmap at a glance

| Phase | Branch | What | Expected gain | Risk |
|---|---|---|---|---|
| 1 | `housekeeping/scan-timing` | Golden test, big mock library, per-stage timings the user can copy | none (measurement) | very low |
| 2 | `feature/scan-fast-fetch` | Parallel requests, bigger batches, shows fetched in batches, compressed replies | large on first scan | low |
| 3 | `feature/scan-no-item-cache` | Stop writing one cache file per title; checkpoint instead | large on first scan | low to medium |
| 4 | `feature/scan-fast-posters` | Poster downloads several at a time | large for movie libraries | low |
| 5 | `feature/scan-native-convert` | Move the per-title conversion into C# | possibly the largest | **high: only with the user's go-ahead after timings** |
| 6 | `feature/scan-fast-jellyfin` | Phases 2 to 4 for Jellyfin | same as Plex | low |
| Parked | none | Ideas that need a check on the user's real server | n/a | n/a |

Do phases 1 to 4 one after another without stopping to ask. Report after each phase (branch, what changed, mock timings before and after, zip). **Stop after phase 4** and ask the user for the timing text from their real server (phase 1 gives them a button for it). Phase 5 is decided from those numbers.

## 2. Phase 1: measurement first (`housekeeping/scan-timing`)

### 2.1 Big mock library

Edit `tests/plex-mock.py`:

- Read an environment variable `PLEX_MOCK_SCALE` (default 0). When it is 0 the mock behaves exactly as today (existing tests depend on the current small data).
- When it is N > 0, generate N episodes spread over `N // 120 + 1` shows (several seasons each) and `N // 10` movies, deterministic (no randomness, or a fixed seed). Reuse the existing `video_movie` / `video_ep` builders so the XML shape is identical. Vary codec, resolution, HDR/Dolby Vision and audio across items by index so the conversion code is exercised.
- Add what later phases need (harmless today):
  - `/library/metadata/<k1,k2,...>` must accept any number of keys, and return shows as `<Directory>` elements when a key is a show's key.
  - Episodes in the section listing must carry `grandparentRatingKey` (real Plex does; check the builder already does).
  - Honour `Accept-Encoding: gzip` by gzipping the body and sending `Content-Encoding: gzip`.
  - Count requests: `GET /__stats` returns `{"requests": n, "maxConcurrent": m}` and `GET /__reset` zeroes them. Track concurrency with a lock.
  - Optional delay: env `PLEX_MOCK_DELAY_MS` (default 0) sleeps that long per request, to imitate a real server. Use 40 in the speed test.

### 2.2 Golden test

Create `tests/Test-MmlmScanSpeed.ps1`, modelled on `tests/Test-MmlmJellyfin.ps1` (same `Check` helper, same context set-up including parsing `FieldDefs`).

- Part A (small data, mock on port 32499): run `Invoke-MmlmServerScan` for movies and for TV with `-Rebuild $true` into a temp folder. Turn the records into a stable text: for each record, every property sorted by name, as `name=value` lines, **excluding** `PosterPath` (an absolute temp path); include `HasPoster`. Compare with `tests/golden/plex-movies.txt` and `tests/golden/plex-tv.txt`.
  - If the golden files do not exist, write them and print `golden written`. **Create them on this branch, before any speed change, from unmodified code, and commit them.** They are the definition of "records must not change".
- Part B (second scan, no rebuild, passing the first scan's records as `-Prior` keyed by `PlexKey`): same text must come out, and the request count (`$ctx.Traffic.Requests` difference) is recorded.
- Part C (speed, only when env `MMLM_SPEED_TEST=1`): expects a second mock already started on a different port with `PLEX_MOCK_SCALE=55000 PLEX_MOCK_DELAY_MS=40` (add a `--port` argument or `PLEX_MOCK_PORT` env to the mock). Time a full TV scan and a rescan; print seconds, request count and the mock's `maxConcurrent`. No pass/fail except "finished without error" and "record count equals the mock's item count".

Record the phase-1 numbers from Part C in the commit message and in the report. These are the "before" numbers. (The sandbox runs PowerShell 7, which is faster than the user's 5.1; the ratio before/after is what matters.)

### 2.3 Per-stage timings

In `modules/MMLM.Library.psm1` add and export:

```powershell
function Add-MmlmScanTime {
    # Adds seconds to a named stage of the running scan (shown in Settings > Servers > Last scan timings).
    param([string]$Stage, [double]$Seconds, [int]$Count = 0)
    if ($null -eq $script:Sync) { return }
    if (-not $script:Sync.ContainsKey('Times') -or $null -eq $script:Sync.Times) { $script:Sync.Times = [ordered]@{} }
    $t = $script:Sync.Times
    if (-not $t.Contains($Stage)) { $t[$Stage] = @{ Seconds = 0.0; Count = 0 } }
    $t[$Stage].Seconds += $Seconds; $t[$Stage].Count += $Count
}
```

In `Invoke-MmlmPlexScan`, wrap each stage with a `[Diagnostics.Stopwatch]` and call `Add-MmlmScanTime` with these stage names (use exactly these):

- `list` (step 1), `compare` (step 2), `fetch` (network time inside step 3), `convert` (time inside `ConvertFrom-MmlmPlexVideo`), `cache-write` (per-item cache file writes), `shows` (show node requests), `posters` (step 4 poster work), `fel` (FEL probe).
- Pass `-Count` as the number of requests or items for that stage.

In `$script:ScanScript` (Host) time: `load-prior`, `scan-total`, `save-snapshot`, `artwork`, `export-page`, `card`. At the end (in the `try`, after the card is written) write the timings to `(Join-Path $Job.CacheDir ('scan-timing-' + $Job.Tab + '.txt'))`: a first line with date, tab, server kind, item count, new count, and PowerShell version; then one line per stage: `stage  seconds  count`. Also write it when the scan fails or is cancelled (put the writing in `finally`, guarded with try/catch).

Add a host command `scan.timing` (`Fetch = $false`): returns `@{ movies = <file text or ''>; tv = <file text or ''> }`.

In `ui/js/views/settings.js`, Servers tab, under the full-rescan buttons, add a row "Last scan timings" with a button **Copy timings**. It calls `scan.timing`, shows the text in a small `<pre>` under the button, and copies it to the clipboard (`navigator.clipboard.writeText` inside the click handler, with a catch that just leaves the text selected). Add the matching case to `ui/dev/mock.js` returning sample text.

### 2.4 Report for phase 1

Branch, the mock "before" numbers, the zip. Tell the user: "After your next scan, open Settings > Servers > Copy timings and paste the text here." Then continue to phase 2 without waiting.

## 3. Phase 2: fast fetching (`feature/scan-fast-fetch`, branched from phase 1)

### 3.1 C# parallel downloader

Add to `src/Mmlm.Native.cs`, inside `namespace Mmlm.Native` (add any missing `using` lines: `System`, `System.IO`, `System.Net`, `System.Text`, `System.Threading`, `System.Threading.Tasks`):

```csharp
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
    static Http()
    {
        if (ServicePointManager.DefaultConnectionLimit < 8) ServicePointManager.DefaultConnectionLimit = 8;
        ServicePointManager.Expect100Continue = false;
    }

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
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
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
                using (Stream s = resp.GetResponseStream()) { s.CopyTo(ms); }
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
        catch (Exception ex) { r.Error = ex.Message; }
        finally { if (resp != null) resp.Close(); }
        return r;
    }
}
```

Note: `Initialize-MmlmNative` checks for the type `Mmlm.Native.TvData`. The DLL name includes a hash of the source, so a changed source compiles to a new DLL automatically. Do not change that function.

### 3.2 PowerShell wrapper in `MMLM.Plex.psm1`

Add `Get-MmlmPlexMany`:

- Parameters: `[string]$BaseUrl, [string]$Token, [object[]]$Requests` (each `@{ Path = '...'; Query = @{...} }`), `[int]$Parallel = 4`, `[switch]$Binary`, `[string]$Accept = 'application/xml'`.
- Build each URL exactly as `New-MmlmPlexRequest` does (same escaping). Headers: `X-Plex-Token`, `X-Plex-Client-Identifier` (`$script:PlexClientId`), `X-Plex-Product` (`Modern Media Library Manager`).
- If `('Mmlm.Native.Http' -as [type])` is null, try `Initialize-MmlmNative` inside try/catch. If the type is still missing, **fall back** to one request at a time through the existing `New-MmlmPlexRequest` path and return the same result shape. Tests that do not set `AppRoot` in the context will take this fallback; that is fine.
- Call `Assert-MmlmTrafficAllowed` once, then `[Mmlm.Native.Http]::GetMany(...)`.
- For each result: `Add-MmlmTraffic -Bytes $r.Bytes` when `Status -eq 200`, else `Add-MmlmTraffic -Failed`.
- If any result has `Status -eq 401`: throw `'Plex rejected the token (401 Unauthorized).'` (same text as today).
- If every result has `Status -eq 0`: throw `("Could not reach Plex at {0}: {1}" -f $BaseUrl, $firstError)` (same text as today).
- Return the results array (order preserved).

Parallelism: read `$script:PlexParallel` if set (from context), default **4**. Never above 6.

### 3.3 Step 1 (listing) changes

In `Get-MmlmPlexStubs`:

- Page size 200 -> **1000**.
- Fetch the first page as today (it gives `totalSize`). Then build the remaining page requests and fetch them with `Get-MmlmPlexMany` in waves of `$Parallel` pages. Between waves: cancel check and the same "Listing ..." progress text. Append stubs in page order.
- If any page in a wave failed (`Status -ne 200`), refetch that page once with the old single-request function; if it fails again, let the error throw as today.
- Add one property to each stub: `ShowKey = $n.GetAttribute('grandparentRatingKey')` (empty for movies).
- Keep the "no paging info: one page is all there is" behaviour.

### 3.4 Step 3 (details) changes

In `Invoke-MmlmPlexScan`:

- **Shows first.** After step 2, collect the distinct non-empty `ShowKey` values of the to-do items. Fetch them in batches of **100** keys per request (`/library/metadata/<k1,...,k100>?includeGuids=1`), in waves through `Get-MmlmPlexMany`. Parse each reply and store each `<Directory>` in `$showCache[ratingKey]`. Any show still missing afterwards is fetched lazily by the existing `Get-MmlmPlexShowNode` (leave that function as the fallback; it already checks the cache first). Time this as stage `shows`.
- **Details in waves.** Batch size 25 -> **100**. Build `$Parallel` batches per wave, fetch the wave with `Get-MmlmPlexMany`, then convert the items of each batch in order. For a batch whose result failed, or whose reply does not contain some keys, call the existing `Get-MmlmPlexMetadataMap` for just the missing keys (it has the one-by-one fallback). Parse XML with `New-Object Xml.XmlDocument` + `LoadXml` as today.
- Keep the same per-item `try { ConvertFrom-MmlmPlexVideo ... } catch { Write-Warning ... }`.
- Progress: update "Reading Plex metadata: X of Y" once per batch as today.
- Memory: do not keep all XML documents; let each wave's documents go out of scope before the next wave.

### 3.5 Compression for the old path too

In `New-MmlmPlexRequest` add `$req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate`. Verify with the mock that image requests through `Save-MmlmPlexPoster` still work.

### 3.6 Checks for phase 2

- Golden test Part A and B: identical output.
- New checks in `Test-MmlmScanSpeed.ps1`: the mock's `maxConcurrent` is at most 6; a full scan of the small data makes fewer requests than phase 1 recorded; a scan with the mock told to fail one batch (add `PLEX_MOCK_FAIL_ONCE=<path substring>` to the mock: first matching request returns 500, later ones succeed) still returns every record.
- Kill switch: set `$ctx.Traffic.Halted = $true` before a scan and check it throws `Traffic to data sources is paused.` and the mock saw no requests.
- Part C numbers: report before and after.

## 4. Phase 3: no per-title cache files (`feature/scan-no-item-cache`, from phase 2)

Today every new record is written to its own JSON file (`ConvertTo-Json`, 55,000 files). The saved library already lets a rescan skip unchanged titles; the files only help when a first scan is cancelled part-way, and for callers that pass no `-Prior`.

1. **Find the callers.** `grep -n "Invoke-MmlmPlexScan\|Invoke-MmlmServerScan"` across the repo. The Host's ScanScript passes `-Prior`. If the window app (`Modern-Media-Library-Manager.ps1`) calls the scan without `-Prior`, it depends on the cache files: it must keep today's behaviour.
2. **Opt-in switch through the context.** In `Invoke-MmlmPlexScan`, read `$useItemCache = -not [bool]$script:NoItemCache`. In the Host, add `NoItemCache = $true` to the context hashtable it builds for workers (near line 318 of `MMLM.Host.psm1`, where `CacheVersion` is set). The window app does not set it, so it keeps the old path.
3. **When `NoItemCache` is on:**
   - Step 2: skip the cache-file name hash, the `Add-Member CacheFile`, the `Test-Path` and the read. A stub is either reused from `$Prior` or goes on the to-do list.
   - Step 3: do not write the per-item file. Set the record's `PlexUpdated` right after conversion (the code that adds the note property in step 4 can stay; it will find it already set).
   - Step 4 FEL probe: skip the cache-file rewrite.
4. **Checkpoint so a cancelled first scan is not wasted.** The ScanScript owns the snapshot, so do it there with a callback:
   - Add an optional parameter to the context, not the signature: `$script:ScanCheckpoint` (a scriptblock). In step 3, after every **5,000** newly converted records, and once when the scan is cancelled during step 3, call `& $script:ScanCheckpoint $byKey.Values` inside try/catch.
   - In ScanScript, before calling `Invoke-MmlmServerScan`: define the checkpoint to save the given records to `$Job.Snapshot + '.partial'` using `[Mmlm.Native.Snapshot]::Save` (same call shape as the real save). Pass it by adding it to the module context (`Set-MmlmServerContext -Values @{ ScanCheckpoint = $cb }`).
   - When building `$prior`: if `<snapshot>.partial` exists and this is not a Rebuild, load it too and add its records to `$prior` for keys not already present. **But** records from the partial file must not count as "already known" for the "new titles" badge: keep a separate set of keys that came from the real snapshot and use that for `$new`.
   - After the real snapshot is saved successfully, delete the `.partial` file. On Rebuild, delete it at the start.
   - First verify that `Snapshot.Save` / `Load` keep the `PlexUpdated` property (the rescan logic already relies on it). Add a check to the test: save, load, compare `PlexUpdated`.
5. **Leave existing cache files on disk alone.** The same folder holds other caches.
6. **Checks:** golden test identical. New check: start a scan on the big mock, cancel it after the first checkpoint (set `$sync.Cancel = $true` from a timer or after N progress updates), scan again, and confirm the second scan makes far fewer detail requests and returns every record. Check the "new" count on a first scan interrupted and resumed equals the full item count.

## 5. Phase 4: fast posters (`feature/scan-fast-posters`, from phase 3)

In step 4 of `Invoke-MmlmPlexScan`:

1. Before the per-stub loop, collect the distinct `PlexThumb` values whose poster file does not exist yet. Compute the destination path exactly as `Save-MmlmPlexPoster` does (`plex-<hash>.jpg` in `$script:ThumbFolder`); move that path calculation into a small helper used by both.
2. Download the missing ones in waves of `$Parallel` with `Get-MmlmPlexMany -Binary -Accept 'image/jpeg,image/*'`, path `/photo/:/transcode`, query `width=240 height=360 minSize=1 upscale=1 url=<thumb>`. Write each non-empty result to `<dest>.part` then rename, as today. Progress text during this: `Posters: X of Y images`.
3. Stop rule: if **two waves in a row** have no successful download, stop downloading posters for this scan (the rest stay without a poster and are retried next scan).
4. Then run the existing per-stub loop unchanged. It will find the files present and only assign `PosterPath` / `HasPoster`; its own single download stays as a fallback.
5. In `Sync-MmlmServerArtwork` (`MMLM.Server.psm1`) do **not** change anything in this phase.
6. Small CPU fixes in ScanScript `Export-PageLibrary` (same branch, separate commit):
   - Replace `Remove` + `Add` of the `Art` / `Logo` / `Banner` properties with: if the property exists, set its `Value`; otherwise add it.
   - Replace `Sort-Object { [string]$_.Added } -Descending` with `Sort-Object -Property Added -Descending` **only if** the golden card output is identical on the mock; otherwise leave it.
7. **Checks:** golden test identical (`HasPoster` included). Poster files exist for every distinct thumb the mock serves. Mock `maxConcurrent` at most 6. Part C numbers.

**After phase 4: stop.** Report the mock before/after table for phases 1 to 4 and ask the user to run a full scan on the phase-4 build and paste the "Copy timings" text.

## 6. Phase 5: native conversion (`feature/scan-native-convert`). Only with the user's go-ahead.

Decide from the user's real timings:

- If `convert` is **under a quarter** of `scan-total`: do not do this phase. Say so and stop.
- Otherwise explain the trade-off to the user in two sentences (largest remaining gain; a careful rewrite of about 230 lines, so a small risk of a detail coming out differently on unusual files) and wait for a yes.

If it goes ahead:

1. Widen the golden data first. Extend the mock's generated items so every branch of `ConvertFrom-MmlmPlexVideo` is hit: multiple `Media` versions, missing streams, each HDR type, Dolby Vision profiles 5 / 7 / 8, each audio codec in `Get-MmlmPlexAudioFormat`, missing ratings, episodes with and without a show node, external subtitles. Regenerate the golden files **from the PowerShell implementation** and commit them before writing any C#.
2. Port `ConvertFrom-MmlmPlexVideo` and the helpers it calls (`Get-MmlmPlexTags`, `Get-MmlmPlexRatings`, `Get-MmlmPlexRating`, `Get-MmlmPlexRatingSource`, `Get-MmlmPlexAudioFormat`, `Convert-MmlmPlexEpoch`, and the Library helpers such as `Get-MmlmResolutionClass`, `Get-MmlmHdrType`, `Get-MmlmDolbyVisionInfo`, `Get-MmlmHdrStack`, `Get-MmlmAudioLabel`, `Get-MmlmAudioLayout`, `Resolve-MmlmSourceLabel`) into a C# class `Mmlm.Native.PlexConvert` with one entry point that takes the `<Video>` `XmlElement`, the show `XmlElement` (or null), the library name and the field-name list, and returns a `PSObject` with the same properties, in the same order, with the same types as `New-MmlmEmptyRecord` produces. Port line by line. Do not "improve" any rule.
   - Watch for PowerShell behaviours: case-insensitive `-eq` / `-match` / `-like`, `[int]` conversion that rounds to even, `-join` on null, empty string versus null, culture (the app uses invariant culture).
3. Keep the PowerShell function. In `Invoke-MmlmPlexScan` use the native one when the type exists and `$script:NativeConvert` is not `$false`; on any exception for an item, fall back to the PowerShell function for that item.
4. Test: run both implementations over every item of the widened mock and compare the stable text record by record; zero differences allowed. Add this comparison to `Test-MmlmScanSpeed.ps1`.
5. Add a line to the timing file saying which converter ran.

## 7. Phase 6: the same for Jellyfin (`feature/scan-fast-jellyfin`)

Only after the Plex phases are merged. Apply phases 2 to 4 to `MMLM.Jellyfin.psm1`:

- `Get-MmlmJellyfinMany` wrapper over the same `Mmlm.Native.Http.GetMany` (headers `Authorization: MediaBrowser ...` and `X-Emby-Token`, accept `application/json`).
- Listing pages 500 -> 1000, fetched in waves after the first page.
- Detail batches of 100 ids in waves; the series request stays one per wave.
- `NoItemCache` and the checkpoint (shared code from phase 3).
- Posters in waves.
- Golden files `tests/golden/jellyfin-*.txt`, created before the change. Add request counting and concurrency stats to `tests/jellyfin-mock.py` first.
- Extra for Jellyfin: `ConvertFrom-Json` on PowerShell 5.1 is slow on big replies. Measure it in the timings (`parse` stage) before deciding anything; do not replace it in this phase.

## 8. Parked ideas (do not build without a check on the user's real server)

Each needs a fact that only the user's Plex server can confirm. If the user asks for more speed after phase 4, offer these, with the check needed:

1. **Skip the scan when nothing changed.** `/library/sections` gives each library a `contentChangedAt` / `updatedAt`. Unknown: whether it moves when only metadata changes (a rating update, new artwork). Check: note the values, refresh one title's metadata in Plex, look again.
2. **Ask only for changed titles** with an `updatedAt>=` filter on the listing, plus an ids-only listing to detect deletions. Unknown: filter support and behaviour on the user's server version.
3. **Details from the listing itself**, skipping step 3. Unknown: whether the listing's `<Video>` elements include `<Stream>` details (HDR, Dolby Vision, Atmos) on the user's server version; possibly with `includeElements=Stream`.
4. **Show the library first, download posters in the background.** A design change to the page (posters appear as they arrive), not a risk to data.
5. **Read Plex's database file directly.** Fastest of all, but needs file access to the Plex PC, and it is not a supported way to use Plex. Last resort.
6. **Faster "after scan" steps in C#** (page export for 55,000 records) if the timings show `export-page` is large.

## 9. What to report at the end of each phase

1. One sentence: what is faster and by how much on the mock (before X s, after Y s; requests before, after).
2. What the user will notice.
3. Anything not tested (always: "tested against the stand-in server only").
4. `On branch <name>, not merged.` plus any other unmerged branches.
5. `Zip sent: <file>`
