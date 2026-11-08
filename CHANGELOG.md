# Changelog

## Unreleased

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
