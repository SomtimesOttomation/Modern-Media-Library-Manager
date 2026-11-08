# Changelog

## Unreleased

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
