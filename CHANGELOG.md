# Changelog

## Unreleased

## 0.5.0

**Feature**
- The new page (Start-MMLM.bat): Movies and TV Shows as poster walls or grids, the TV grid as Show > Season > Episode, title and show cards (save a card as a picture), Stats with click-to-filter charts, search, Sort By, pause switch and settings. It reads the libraries your scans saved and shares the window app's settings and token.
- Ready for DashLauncher: dash.json and a dash backend (scan, badge for new titles, traffic counters, kill switch, updates). The same page runs as the launcher's Media tab once it is listed there.

**Redesign**
- The page uses the shared dash look and navigation bar, in light and dark.

**Housekeeping**
- Data logic moved into modules (MMLM.Library, MMLM.Plex, MMLM.Fetch) and the C# helper into src/Mmlm.Native.cs; the window app works as before.
- Errors in the new page's backend go to a log file; headless tests for the backend and the page.

## 0.4.0

**Feature**
- Updater uses the same design as the dash modules: it backs up, installs, restarts, and puts the old version back if the new one does not start.
- Drop-in updates: save the release zip (and its .sha256) into the updates folder next to the app and it offers to install it, for when the repository is private.

**Housekeeping**
- VERSION file; release zips get a .sha256 beside them (SHA256SUMS.txt is still published so older copies can update).

## 0.3.1

**Bug/Fix**
- Sort by dropdown showed an empty highlight instead of the chosen sort; its label no longer overlaps it.

## 0.3.0

**Feature**
- Sort By for Movies (title, date added, release date, RT critics, Metacritic, box office, runtime) and for the TV Shows page (title, first aired, date added, genre, seasons).
- Metacritic Metascore (from OMDb via Fetch info), shown as a green / yellow / red square with the score in the grid, detail view and dashboard card.

**Bug/Fix**
- Start-up freeze: the compiled helper is kept between launches and the last scan loads after the window has appeared.

**Housekeeping**
- File and folder paths are no longer shown in any view, the dashboard card, saved HTML or CSV export.

## 0.2.0

**Feature**
- Movies / TV Shows tabs above the header. Scan scans the tab you are on and keeps the other tab's titles; the other tab stays usable during a scan.
- TV Shows (Plex): poster wall with one tile per show, and a Show > Season > Episode grid (collapsed by default, Expand all / Collapse all, its own filter).
- Opens on the last scan of each tab without contacting Plex; Scan only re-reads items that changed in Plex.
- Clicking a movie in Poster view opens its card (with Export Card to PNG).

**Bug/Fix**
- Large Plex libraries: scan progress no longer stalls, and posters are fetched once per show instead of once per episode.
- Faster grid and detail list on large libraries.

**Redesign**
- The TV Shows posters and grid are an HTML page inside the app (new file: tv-template.html).
- Update window: Check for updates and Close sit side by side in the centre.
