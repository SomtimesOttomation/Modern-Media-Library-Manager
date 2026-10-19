# Modern Media Library Manager

A Windows desktop tool that scans a movie and TV library and shows it as a sortable grid, a detail view and a polished HTML dashboard.

It reads either a local or network (UNC) folder with MediaInfo, or a Plex server, and caches results so rescans are fast.

## Features

- **Two sources:** a local or UNC folder (MediaInfo plus `.nfo` and poster sidecars) or a Plex server.
- **Fast, responsive scans:** runs in the background, reads several files in parallel (1-12, adjustable while scanning), resumes from a per-file cache, and shows a rainbow progress bar with percent and ETA.
- **Live Workers pane:** per-reader file, stage, load and throughput.
- **Rich technical fields:** resolution, video and audio codecs, HDR and Dolby Vision profile (optional FEL/MEL probe with ffmpeg and dovi_tool), subtitles, chapters, runtime, source clues.
- **Fetch info:** look up year, genre, rating, studio, director, certification, Rotten Tomatoes critic score and box office from TMDB, the IMDb ratings file and OMDb. Your hand-typed values always win.
- **Edit info:** select a title (button or right-click) and type in what no free source has: Rotten Tomatoes audience score, CinemaScore, opening weekends, all-time box office, or corrections to year, genre and so on.
- **Views and export:** grid, detail view with posters, an interactive dashboard (WebView2, with a browser fallback), CSV export and saved HTML.
- **Filtering:** free text, or `field:value` such as `source:unknown` or `resolution:2160p`.
- **Remembers** your folder, options and column layout.

## Requirements

- Windows with Windows PowerShell 5.1 (included with Windows 10/11).
- The `Get-MediaInfo` PowerShell module (installed automatically on first run).
- WebView2 runtime for the embedded dashboard (the DLLs are downloaded automatically on first use; otherwise the dashboard opens in your browser).
- Optional: `ffmpeg.exe` and `dovi_tool.exe` in `lib\` (or on PATH) for FEL/MEL detection.

## Run it

1. Keep these files together: `Modern-Media-Library-Manager.ps1`, `dashboard-template.html`, `Run-ModernMediaLibraryManager.cmd`.
2. If Windows blocked the download, run once in PowerShell: `Get-ChildItem . -Recurse | Unblock-File`
3. Double-click `Run-ModernMediaLibraryManager.cmd` (it starts PowerShell with `-STA`, which WinForms needs).

## Online lookups (Fetch info)

Click the gear button, then paste your keys under **Online lookups**. They are stored encrypted for your Windows user only.

| Source | Key | Used for |
| --- | --- | --- |
| [TMDB](https://www.themoviedb.org/settings/api) | free key (required) | year, genre, certification, studio, director, worldwide box office |
| [IMDb ratings file](https://developer.imdb.com/non-commercial-datasets/) | none | rating and votes (downloaded weekly) |
| [OMDb](https://www.omdbapi.com/apikey.aspx) | free key (optional, 1,000 requests a day) | Rotten Tomatoes critic score, domestic box office |

Fetched and hand-typed values are kept in `%LOCALAPPDATA%\Modern-Media-Library-Manager\metadata\store.json`, never written into your media files (see [What it touches](#what-it-touches-on-your-system)).

There is no free, permitted source for the Rotten Tomatoes audience score, CinemaScore or opening-weekend figures, so Fetch info leaves those empty. Type them in with **Edit info**.

Optional: save TMDB's official logo as `lib\tmdb-logo.png` (see [TMDB's logo and attribution page](https://www.themoviedb.org/about/logos-attribution)) and it appears in the Credits box.

## Plex

Choose **Plex server**, enter the server address (for example `http://plex-server:32400`) and click **Token...** the first time. The token is stored encrypted (DPAPI).

## What it touches on your system

**Your media is read-only.** The app never creates, changes, renames, moves or deletes your media files, and it never writes anything into your library folders. This includes `.nfo` files and poster images: they are only read. Nothing is written back to Plex either; every request to the Plex server is a read (GET).

Everything the app does write is its own working data, listed here:

| What | Where | Why |
| --- | --- | --- |
| Settings (folder, options, column layout, encrypted tokens and keys) | `%LOCALAPPDATA%\Modern-Media-Library-Manager\settings.json` | remembers your setup |
| Scan cache (one small JSON file per media file) | `...\Cache\` | makes rescans fast; **Rebuild local cache** deletes and recreates these |
| Poster thumbnails | `...\Thumbs\` | grid, detail view and dashboard |
| Fetched and typed-in values | `...\metadata\store.json` | **Fetch info** and **Edit info**; applied on top of every scan, so they survive cache rebuilds |
| IMDb ratings file | `...\datasets\` | downloaded weekly for **Fetch info** |
| Full MediaInfo text per file | `...\Inform\` | source-clue research |
| Live dashboard page | `...\Dashboard\` | the dashboard shown inside the app |
| WebView2 DLLs | `lib\` next to the script | downloaded once for the embedded dashboard |
| The `Get-MediaInfo` PowerShell module | your PowerShell module folder (current user) | installed on first local scan if missing |
| Files you ask for | where you choose | **Export CSV** and **Save HTML** (a saved dashboard also gets a `thumbs` folder beside it unless posters are embedded) |
| Temporary files | your Windows temp folder, deleted straight after | only when **Detect FEL / MEL** is on: a short video sample is extracted for analysis, never your original file |

What it reads: media files (through MediaInfo, and ffmpeg for the optional FEL/MEL probe), `.nfo` and poster files beside them, and your Plex libraries. Online lookups send only titles, years and IDs to TMDB, OMDb and IMDb's public file; your keys go only to their own service.

To reset the app completely, close it and delete the `%LOCALAPPDATA%\Modern-Media-Library-Manager` folder. Your media is unaffected.

Writing `.nfo` sidecar files is not implemented. If it is added, it will be opt-in, with a preview before anything is written.

## Status

Actively developed. Newer features (parallel scan, Workers pane, Fetch info) are young, so expect rough edges; issues and pull requests are welcome.

## Credits and disclaimers

- This product uses the TMDB API but is not endorsed or certified by TMDB.
- Ratings data courtesy of IMDb (imdb.com), used under its non-commercial data licence.
- Rotten Tomatoes scores and box office come from the OMDb API (CC BY-NC 4.0). Rotten Tomatoes is a trademark of its owners; the tomato and popcorn icons in the grid are original drawings.
- MediaInfo by MediaArea. WebView2 by Microsoft.
- This tool is for personal, non-commercial use.
