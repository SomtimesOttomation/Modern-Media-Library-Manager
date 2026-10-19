# Modern Media Library Manager

A Windows desktop tool that scans a movie and TV library and shows it as a sortable grid, a detail view and a polished HTML dashboard.

It reads either a local or network (UNC) folder with MediaInfo, or a Plex server, and caches results so rescans are fast.

## Features

- **Two sources:** a local or UNC folder (MediaInfo plus `.nfo` and poster sidecars) or a Plex server.
- **Fast, responsive scans:** runs in the background, reads several files in parallel (1-12, adjustable while scanning), resumes from a per-file cache, and shows a rainbow progress bar with percent and ETA.
- **Live Workers pane:** per-reader file, stage, load and throughput.
- **Rich technical fields:** resolution, video and audio codecs, HDR and Dolby Vision profile (optional FEL/MEL probe with ffmpeg and dovi_tool), subtitles, chapters, runtime, source clues.
- **Fetch info:** look up year, genre, rating, studio, director, certification, Rotten Tomatoes critic score and box office from TMDB, the IMDb ratings file and OMDb. Your hand-typed values always win.
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

Fetched and hand-typed values are kept in `%LOCALAPPDATA%\Modern-Media-Library-Manager\metadata\store.json`, never written into your media files.

Optional: save TMDB's official logo as `lib\tmdb-logo.png` (see [TMDB's logo and attribution page](https://www.themoviedb.org/about/logos-attribution)) and it appears in the Credits box.

## Plex

Choose **Plex server**, enter the server address (for example `http://plex-server:32400`) and click **Token...** the first time. The token is stored encrypted (DPAPI).

## Status

Actively developed. Newer features (parallel scan, Workers pane, Fetch info) are young, so expect rough edges; issues and pull requests are welcome.

## Credits and disclaimers

- This product uses the TMDB API but is not endorsed or certified by TMDB.
- Ratings data courtesy of IMDb (imdb.com), used under its non-commercial data licence.
- Rotten Tomatoes scores and box office come from the OMDb API (CC BY-NC 4.0). Rotten Tomatoes is a trademark of its owners; the tomato and popcorn icons in the grid are original drawings.
- MediaInfo by MediaArea. WebView2 by Microsoft.
- This tool is for personal, non-commercial use.
