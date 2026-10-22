# Modern Media Library Manager

A Windows desktop app that scans a movie library and turns it into something you can actually browse: a sortable grid, a detail view with posters, and an interactive HTML dashboard.

It reads a local or network folder with MediaInfo, or talks to a Plex server, and remembers what it has already read so rescans are fast. **Your media is only ever read, never changed.**

<img width="2076" height="1271" alt="image" src="https://github.com/user-attachments/assets/4f13a311-ca62-4a58-989d-3a6c7f700496" />
<img width="2083" height="1264" alt="image" src="https://github.com/user-attachments/assets/3a913498-c879-466f-925e-d7c050b7377e" />




## Verify your download

The script is not code-signed, so Windows will treat it as an unknown download. Please check what you have before running it:

1. **Get it from the [Releases page](../../releases)**, not from a copy someone else posted.
2. **Compare the SHA-256 hash.** Every release lists the hash of its zip file (and of each script inside it) in the release notes and in `SHA256SUMS.txt`. In PowerShell:

   ```powershell
   Get-FileHash .\Modern-Media-Library-Manager-v1.2.0.zip -Algorithm SHA256
   ```

   The `Hash` line must match the release notes (upper or lower case does not matter). If it does not, do not run it. Releases are also built by GitHub from the tagged source and carry a build-provenance attestation you can check with `gh attestation verify`.
3. **Check the scan report.** Release notes link to a VirusTotal report for that exact zip. A PowerShell script that downloads its helper files can draw a flag or two from heuristic engines; the report shows which engines said what, so you can judge for yourself.
4. **Read the source.** It is a plain-text PowerShell script and an HTML template. Nothing is compiled or obfuscated, and the full list of what it reads, writes and connects to is in [What it touches on your system](#what-it-touches-on-your-system) and [Network activity](#network-activity).

The hash is published with each release rather than written in this file, because this file is inside the zip and would change the very hash it describes.

The launcher starts PowerShell with `-ExecutionPolicy Bypass` for that one process only. Because the script is unsigned and came from the internet, Windows blocks it otherwise. It changes no system setting. If you prefer, run `Get-ChildItem . -Recurse | Unblock-File` once and start the `.ps1` file yourself.

## Highlights

- **Two sources.** A local or UNC folder (MediaInfo, plus `.nfo` and poster files beside each movie) or a Plex server.
- **Technical detail per file.** Resolution, video and audio codecs, bit rates, HDR and Dolby Vision profile, subtitles, chapters, runtime and more, with an optional FEL/MEL probe for dual-layer Dolby Vision.
- **A plain-language source label for every movie.** Remux, web release, encode, DVD and so on, worked out from the file itself. See [How source labels are decided](#how-source-labels-are-decided).
- **Online info.** Fetch year, genre, ratings, studio, director, certification, Rotten Tomatoes critic score and box office from TMDB, the IMDb ratings file and OMDb.
- **Edit info.** Type in what no free source offers (Rotten Tomatoes audience score, CinemaScore, opening weekends, all-time box office) or correct anything else. Your values always win and survive rescans.
- **Fast and responsive.** Scans run in the background, read several files in parallel, resume from a per-file cache and show a rainbow progress bar for the current step plus an overall bar, each with an ETA.
- **Views and export.** Grid, detail view, dashboard (embedded WebView2, with a browser fallback), CSV export and saved HTML.
- **Filtering.** Free text, or `field:value` terms such as `source:unknown` or `resolution:2160p`. Number columns take ranges and comparisons (`year:1980-1989`, `rating:>=7.5`), and several terms combine to narrow further. As you type, a drop-down suggests field names and the values that actually exist in your library (with counts); Down and Enter pick one.
- **Collections.** Your own named title lists, either Static (you add titles) or Dynamic (a saved filter plus an optional sort and limit, so a "top 10" works). Pick one and the grid, detail view, dashboard and exports show only its titles, and the dashboard takes the collection's name as its title. See [Collections](#collections).
- **Remembers** your source, options, window size and column layout.

TV shows are not supported yet; the option is visible but disabled.

## Collections

A collection is a named list of titles that you can run the dashboard on: a franchise, a genre, a studio, a decade, a top 10, whatever you feel like that day.

- **Static (manual additions).** Select titles in the grid (Ctrl-click or Shift-click for several), then click **Add selected...** or right-click and choose **Add to collection...**. Type a new name to create the collection on the spot. You can also build one from filters: in the editor type a filter and click **Add** to put every matching title in the list, change the filter and **Add** again, then **Create** (or **Save** when editing). Sort and limit choose which titles Add takes, so a top 10 works too.
- **Dynamic (grows with library changes).** A saved filter that is re-evaluated on every scan, so it stays current as your library changes. It uses the same syntax as the filter box, plus an optional sort and limit. A top 10 is a Dynamic collection with no filter, sorted by rating (highest first), limited to 10.
- **Using one.** Pick it in the **Collection** box under the toolbar. The grid, detail view, dashboard, CSV export and saved HTML all follow it, and **All titles** switches back to the whole library.
- **Release order.** Tick **By release date** on a collection to keep it in chronological order, oldest first (a franchise in release order, or a top 10 shown by year). The grid, detail list, dashboard and popup all follow it.
- **View Collection.** The dashboard has a **View Collection** button that opens the collection's posters in a popup window, with search and sort. It follows any chart filters you have clicked, opens a title's full details when you click a poster, and works in a saved HTML file too.

Collections work with both Plex and local scans. They are matched by IMDb or TMDB id, falling back to title and year, so they survive rescans, renames and moving between Plex and a folder. They are saved only in this app's own data file; nothing is written to Plex or to your media.

## Requirements

- Windows with Windows PowerShell 5.1 (included with Windows 10 and 11).
- The `Get-MediaInfo` PowerShell module (installed automatically on first local scan).
- The WebView2 runtime for the embedded dashboard (its DLLs download automatically on first use; otherwise the dashboard opens in your browser).
- Optional: `ffmpeg.exe` and `dovi_tool.exe` in `lib\` or on your PATH, only for FEL/MEL detection.

## Getting started

1. Keep `Modern-Media-Library-Manager.ps1`, `dashboard-template.html` and `Run-ModernMediaLibraryManager.cmd` together in one folder.
2. If Windows blocked the download, run once in PowerShell: `Get-ChildItem . -Recurse | Unblock-File`
3. Double-click `Run-ModernMediaLibraryManager.cmd`. It starts PowerShell in the mode WinForms needs.
4. Pick a source, then click **Scan Media**.

### Using Plex

Choose **Plex server**. The first time, a single dialog asks for your server address (for example `http://your-server:32400`) and your Plex access token. The token is stored encrypted for your Windows account. The dialog links to Plex's guide for finding it.

## How source labels are decided

Every movie gets one of these labels:

| Label | Meaning |
| --- | --- |
| 4K Remux | A full-quality 4K disc copy |
| 4K Web-DL | A 4K file that falls short of a disc copy: streaming source, re-encode or upscale |
| Blu-ray Remux | A full-quality 1080p disc copy |
| Blu-ray Encode | Any other 1080p or 720p file |
| DVD | Standard definition |
| DV/HDR Hybrid | A Dolby Vision layer combined with another source's HDR base |
| Unknown | No usable video stream |

The decision is made from **what the file actually contains, never from its name**, because names get cleaned up, renamed or scrubbed. The app weighs, roughly in this order:

1. **Resolution class**, which separates DVD, 720p/1080p and 4K.
2. **Video codec.** A 4K disc is always HEVC, so a 4K file in any other codec cannot be a disc copy.
3. **File size**, the strongest single signal. Disc copies are large; streaming and re-encoded files are noticeably smaller.
4. **Video bit rate**, as a check for short films whose size understates their quality.
5. **Encoder tags** written into the stream. A re-encode usually leaves its encoder's signature, while an untouched disc stream does not.
6. **Dolby Vision profile.** Some profiles only exist on discs, some only on streaming services, and a Dolby Vision layer combined with a re-encode's signature points to a hybrid.

The size and bit-rate thresholds are plain constants near the top of the source-label section of the script, so you can tune them to your own library. A hidden **SourceWhy** column explains each decision in a short sentence, and **Edit info** lets you override any label by hand. The label is recalculated after every scan rather than stored, so changing a threshold never needs a cache rebuild.

Limits worth knowing: measurements cannot see everything (an upscaled file with a Dolby Vision layer can look like a genuine hybrid), and Plex does not expose encoder tags, so hybrid detection is stronger for local scans.

## Online lookups (Fetch info)

Click the gear button, then paste your keys under **Online lookups**. They are stored encrypted for your Windows account only.

| Source | Key | Used for |
| --- | --- | --- |
| [TMDB](https://www.themoviedb.org/settings/api) | free key (required) | year, genre, certification, studio, director, worldwide box office |
| [IMDb ratings file](https://developer.imdb.com/non-commercial-datasets/) | none | rating and votes (downloaded weekly) |
| [OMDb](https://www.omdbapi.com/apikey.aspx) | free key (optional, 1,000 requests a day) | Rotten Tomatoes critic score, domestic box office |

In **Plex scans**, the Rotten Tomatoes critic and audience scores are read straight from Plex when your server has them, with no key needed. For local scans there is no free, permitted source for the audience score, CinemaScore or opening-weekend figures, so Fetch info leaves those empty. Fill them in with **Edit info**.

Fetched values only fill empty fields unless you tick **Replace existing values**. Values you type in always win.

Optional: save TMDB's official logo as `lib\tmdb-logo.png` (see [TMDB's logo and attribution page](https://www.themoviedb.org/about/logos-attribution)) and it appears in the Credits box.

## What it touches on your system

**Your media is read-only.** The app never creates, changes, renames, moves or deletes your media files, and it never writes into your library folders. That includes `.nfo` files and poster images, which are only read. Nothing is written back to Plex either: every request to the Plex server is a read.

Everything the app does write is its own working data:

| What | Where | Why |
| --- | --- | --- |
| Settings (folder, options, column layout, encrypted tokens and keys) | `%LOCALAPPDATA%\Modern-Media-Library-Manager\settings.json` | remembers your setup |
| Scan cache (one small JSON file per media file) | `...\Cache\` | makes rescans fast; **Rebuild local cache** deletes and recreates these |
| Poster thumbnails | `...\Thumbs\` | grid, detail view and dashboard |
| Collections (named title lists) | `...\collections.json` | **Collections** |
| Fetched and typed-in values | `...\metadata\store.json` | **Fetch info** and **Edit info**; applied on top of every scan, so they survive cache rebuilds |
| IMDb ratings file | `...\datasets\` | downloaded weekly for **Fetch info** |
| Full MediaInfo text per file | `...\Inform\` | reference for source-clue research |
| Live dashboard page | `...\Dashboard\` | the dashboard shown inside the app |
| WebView2 DLLs | `lib\` next to the script | downloaded once for the embedded dashboard |
| The `Get-MediaInfo` PowerShell module | your PowerShell module folder (current user) | installed on first local scan if missing |
| Files you ask for | where you choose | **Export CSV** and **Save HTML** (a saved dashboard also gets a `thumbs` folder beside it unless posters are embedded) |
| Temporary files | your Windows temp folder, deleted straight after | only when **Detect FEL / MEL** is on: a short video sample is extracted for analysis, never your original file |

What it reads: media files (through MediaInfo, and ffmpeg for the optional FEL/MEL probe), `.nfo` and poster files beside them, and your Plex libraries. Online lookups send only titles, years and IDs to TMDB, OMDb and IMDb's public file; your keys go only to their own service.

To reset the app completely, close it and delete the `%LOCALAPPDATA%\Modern-Media-Library-Manager` folder. Your media is unaffected.

Writing `.nfo` sidecar files is not implemented. If it is added, it will be opt-in, with a preview before anything is written.

## Updating

Click **Check for updates** at the bottom right of the window. The app asks GitHub for the latest release and, if there is a newer one, shows what changed. Nothing is downloaded until you click **Download update**. It then:

1. downloads the release zip and its `SHA256SUMS.txt`, and checks the zip against that checksum (a mismatch discards it);
2. unpacks it to a staging folder and checks the files inside, including that the new script is readable and carries the release's version number;
3. waits for you to click **Restart to finish updating**. The app closes, the new files go in (the old ones are kept in `%LOCALAPPDATA%\Modern-Media-Library-Manager\Update\previous`), the new version starts and re-runs your last scan from the cache. If it fails to start, the old version is put back automatically.

If only the dashboard template changed, no restart is needed. Your settings, token, scan cache, collections and the `lib\` files are never touched. The checksum comes from the same release as the zip, so it proves the download is complete and intact; to prove who built it, use the attestation check in [Verify your download](#verify-your-download).

## Network activity

The app connects only to the places below. Nothing is sent anywhere else, and there is no telemetry.

| Connects to | When | What is sent or fetched | How to avoid it |
| --- | --- | --- | --- |
| **nuget.org** | First time the dashboard is shown in the app window, if the three WebView2 files are missing | Downloads the Microsoft.Web.WebView2 package and extracts three DLLs into `lib\` | Copy `Microsoft.Web.WebView2.Core.dll`, `Microsoft.Web.WebView2.WinForms.dll` and `WebView2Loader.dll` into `lib\` yourself; or use **Save HTML** and open the file in your browser |
| **PowerShell Gallery** | First local-folder scan, if the `Get-MediaInfo` module is not installed | Installs the module for the current user (Windows PowerShell may also offer to install its NuGet provider) | Install it yourself first: `Install-Module Get-MediaInfo -Scope CurrentUser`; Plex scans do not need it |
| **datasets.imdbws.com** | **Fetch info**, about once a week | Downloads IMDb's public ratings file. Nothing about your library is sent | Do not use **Fetch info** |
| **themoviedb.org** and **omdbapi.com** | **Fetch info**, only if you pasted a key | Titles, years and IMDb or TMDB ids, plus your own key | Leave the keys empty |
| **api.github.com** and **github.com** | Only when you click **Check for updates** (bottom right), and again if you then choose **Download update** | Asks for the latest release, then downloads its zip and checksum file. Nothing about you or your library is sent | Never click it |
| **Your Plex server** | Plex scans | Read-only requests with your token, to the address you entered | Use a local-folder scan |

Local-folder scans and the saved HTML dashboards make no connections of their own. Your files, paths and file names are never uploaded.

## Status

Actively developed. Newer features (parallel scanning, Fetch info, Edit info, source labels) are young, so expect rough edges. Issues and pull requests are welcome.

## Credits and disclaimers

- This product uses the TMDB API but is not endorsed or certified by TMDB.
- Ratings data courtesy of IMDb (imdb.com), used under its non-commercial data licence.
- Rotten Tomatoes scores come from your Plex server (Plex scans) or the OMDb API, and box office from OMDb (CC BY-NC 4.0). Rotten Tomatoes is a trademark of its owners; the tomato and popcorn icons in the grid are original drawings.
- MediaInfo by MediaArea. WebView2 by Microsoft.
- This tool is for personal, non-commercial use.
