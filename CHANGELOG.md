# Changelog

## Unreleased

**Housekeeping**
- MMLM now talks to the media server through one layer (step 1 of Jellyfin support); no visible change.

## 0.14.0

**Feature**
- Poster size is remembered per view: Movies posters, TV posters, Clear logos and Banners each keep their own size.
- Settings > Artwork: Reset to Defaults puts every poster size back to 100%.

## 0.13.2

**Bug/Fix**
- The launcher's About page now lists every outside source Fetch info uses (TMDB, OMDb, IMDb ratings file).
- PlexDoctor's schedule is off by default; turning one on asks you to confirm first.

## 0.13.1

**Bug/Fix**
- DashLauncher refused to load the module after v0.13.0: a data source name in dash.json was over 80 characters. Shortened, and the tests now check dash.json the way the launcher does.

## 0.13.0

**Feature**
- PlexDoctor (Settings > PlexDoctor): a read-only check-up of your Plex library, weekly, every 2 weeks or monthly (or Run check-up now). Finds unreadable files, unmatched or likely wrong matches, gaps in a season, missing posters, duplicates, AV1 files the Shield can't play and (optional) missing English subtitles. Compact or Verbose reports; a toast when it finds issues, a green check when it doesn't.
- Poster size works per tab, and in TV Shows also sizes the Clear and Banners views.

## 0.12.0

**Feature**
- TV Shows: a new Clear view with each show's clear logo; views now run Posters, Clear, Banners, Grid, Dashboard (Dashboard always last).
- TV Shows: Fetch info looks up whether each show is Ongoing or Ended (TMDB, your key); the series view shows Status above Seasons and an Ended block after the seasons.

**Bug/Fix**
- Closing a show now returns to the view it was opened from instead of Posters.
- Clicking the empty parts of the top bar now also closes the series view.

## 0.11.0

**Feature**
- Settings > Artwork: a Refresh artwork button fetches every ticked picture again from Plex (after changing banners, logos or backgrounds there).

**Bug/Fix**
- Cropped TV banners and clear logos saved by v0.10.0 are now replaced by themselves.

## 0.10.1

**Bug/Fix**
- TV banners and clear logos were cropped; they now keep their full shape (banners at 1000x185) and are fetched again once.

## 0.10.0

**Feature**
- Settings > Artwork: clear logos instead of title text, and background art behind cards, the series view and Compare (from your own Plex server, opt-in).
- TV Shows: a new Banners view (Plex banners when ticked in Settings > Artwork; background art and logo stand in otherwise).
- Box office adjusted for inflation (2024 dollars): shown on cards, as sorts, Grid columns and search fields (boxadj), and as an Adjust for inflation checkbox in Compare.

**Bug/Fix**
- Compare: titles with no box office or Metacritic now say so, with Fetch info for just those titles; the Opening weekend row only shows when there is a value.

## 0.9.0

**Feature**
- Compare (Movies): two movies head to head on box office and critics, with a video-game VS and themed poster borders.
- Compare collections: totals and averages for each side, then a #1 vs #1 tournament by worldwide gross (up to 10 rounds).
- Settings > Fun: border effect for each side (Auto, Fire, Lightning, Specter, Poster colours, Off), animation level, VS style and the rules.

## 0.8.0

**Feature**
- Collections: separate lists for Movies and TV Shows.
- Collection mode: tick titles with a + on the posters (or the grid's first column), name the collection and press Done.
- Search: several filters separated by semicolons (4k; genre:action; 90s), all must match.

**Bug/Fix**
- Clearing the search and switching tabs straight away could bring the old search back.

## 0.7.1

**Redesign**
- TV series view: one rounded card with a gap below it; arrows instead of scroll bars on the season strip, cast and related shows; a click beside the card goes back to the posters.

## 0.7.0

**Feature**
- Movie posters show the Rotten Tomatoes critics score (tomato or splat) and the Metacritic score on its coloured square instead of the IMDb star; movie cards always list Metacritic, or say it has not been fetched yet.

**Bug/Fix**
- The search box deleted a space as soon as it was typed.

**Redesign**
- TV series view: rounded corners on the posters, episode stills, related shows and the season strip.

## 0.6.0

**Feature**
- New page: each tab has Posters, Grid and Dashboard; pick a sort again to reverse it; a poster size slider (up to 200%); width presets 16:9 / 21:9 / 32:9 or a custom width dragged at the edges.
- Search: field searches (res:4k genre:action year:1990-1999 rating>8), everyday phrases (90s sitcoms, 4k atmos, highly rated thrillers, unwatched), a line showing how it was read, and an Advanced search panel.
- Collections in the new page (shared with the window app): pick one, add titles or shows from their cards, rule collections from a search, searchable by name.
- TV series view: a Plex-style page per show with a gradient from the season poster, episode stills with watched marks, cast and related shows (from your Plex server, saved after the first open).
- Tools in the new page: Fetch info (with a warning; keys in Settings), FEL/MEL check (also optional during Plex scans), CSV export and the standalone HTML dashboard; All details on every card.
- Your own dashboards: charts over any field (bars, columns, donut, big number, top titles), with suggestions and per-chart filters; the Dashboard follows the search box.

**Bug/Fix**
- Metacritic, Rotten Tomatoes, box office and hand-typed values were missing in the new page after its scans.

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
