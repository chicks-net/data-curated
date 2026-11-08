# individuals/chicks/music/spotify

My playlists from spotify, downloaded via <https://exportify.net/>.

## Lyrics

`fetch-lyrics.py` fetches lyrics for playlist tracks from
<https://lrclib.net> (a free, community-maintained lyrics database — no API
key required) and stores them in `lyrics.db`, following the guidance in
[chicks-net/chicks-projects#127](https://github.com/chicks-net/chicks-projects/issues/127).

- `just fetch-lyrics` - fetch lyrics for Liked Songs (the default CSV)
- `just fetch-lyrics Other_Playlist.csv` - fetch lyrics for any other
  Exportify playlist CSV in this directory
- `just lyrics-status` - show database status and coverage
- `just lyrics-db` - browse `lyrics.db` in Datasette

### Tables

- `tracks` - playlist track metadata imported from the CSV, keyed by
  Spotify track ID (ISRC is kept for a possible Musixmatch fallback later)
- `lyrics` - plain and time-synced lyrics per track, with a status
  (`found`, `not_found`, `instrumental`, `error`) and match method
  (`get` for an exact match, `search` for a duration-validated fuzzy match)
- `fetch_history` - one summary row per fetch run

### Matching waterfall

1. LRCLIB exact match: artist, track, album and duration
2. LRCLIB search: fuzzy match, accepted only when its duration is within 3 seconds of the Spotify duration (so covers and remixes of other tracks don't slip in)
3. `not_found` if neither matches

Instrumentals are recorded with their own status so they are not mistaken
for tracks with an unknown language later. Transient LRCLIB failures
(HTTP 429/5xx) are marked `error` and retried on the next run.

### Caching

The database is the cache: re-runs skip tracks that already have a
terminal status (`found`, `not_found`, `instrumental`) and only retry
previous errors. Pass `--force` to re-fetch everything:

```sh
uv run fetch-lyrics.py --force
```

## Language detection

`detect-languages.py` runs [langdetect](https://pypi.org/project/langdetect/)
over the stored lyrics and records the top-2 language guesses per track
in the `track_languages` table, per the guidance in
[chicks-net/chicks-projects#127](https://github.com/chicks-net/chicks-projects/issues/127):

- `just detect-languages` - detect languages for new tracks (idempotent;
  uv auto-installs langdetect from the script's inline metadata)
- `just language-breakdown` - print the breakdown and write
  `language-breakdown.csv`

Instrumentals and tracks without lyrics get no `track_languages` row,
so the breakdown reports them as their own buckets (`instrumental`,
`unknown`) instead of a made-up language. Results are deterministic
(seeded) and detection is local, so re-runs are free. Pass `--force` to
re-detect everything (`uv run detect-languages.py --force`).

A track is tagged low confidence when its lyrics are short (< 200
chars), repetitive, or the detector itself is unsure (probability
< 0.9). Choruses, bilingual songs and gibberish vocals skew a single
label, so check the `language_2` column for those.

## Language playlists

`language-playlists.py` turns the detected languages into private
Spotify playlists — one `Lang: <code> (<Language>)` playlist per
language with at least 2 tracks (e.g. `Lang: fr (French)`) — per the
guidance in
[chicks-net/chicks-projects#127](https://github.com/chicks-net/chicks-projects/issues/127):

- `just language-playlists --dry-run` - show the plan without writing
- `just language-playlists` - create/update the playlists (idempotent:
  re-runs find the existing `Lang: *` playlists and only add/remove the
  tracks the detection results changed)
- `--include-english` / `--include-low-confidence` - opt into the `en`
  bucket (~560 tracks, the baseline) and the low-confidence detections
  (skipped by default)
- `--languages fr,pt` - restrict to specific languages

Sync notes: the `Lang:` playlists are fully script-managed — anything
added to one by hand (a track, an episode) is removed on the next run.
A `Lang: *` playlist whose language falls below the track
threshold or out of the filters is left untouched, not emptied — the
output lists it as "not in today's plan". If back-to-back runs keep
reporting the same add/remove pair, that track URI was likely relinked
by Spotify (market substitution) and needs a one-time manual fix.

One-time setup: create an app at
<https://developer.spotify.com/dashboard> (check Web API, redirect URI
`http://127.0.0.1:8888/callback` — Spotify rejects `localhost` for new
apps), then put `SPOTIPY_CLIENT_ID`, `SPOTIPY_CLIENT_SECRET` and
`SPOTIPY_REDIRECT_URI` in `.env` at the repo root (gitignored). The
first run opens a browser for Spotify consent; the token is cached in
`.spotify-token-cache` (also gitignored).

The Spotify app is a personal Development Mode app, so it targets the
February 2026 Web API (spotipy ≥ 2.26: `/playlists/{id}/items` and
`POST /me/playlists`) and only works while the app owner's Spotify
Premium subscription is active. `unknown`, `instrumental` and
`undetectable` never get playlists — they are not languages.

### Collapsing the sidebar: a one-time folder

Spotify playlist folders are the way to make the `Lang: *` playlists
collapsible, but the Web API cannot create or even see folders (per
Spotify's own docs), so the script cannot make one for you. Any client
can do it once — desktop, web player, or mobile: Your Library → `+` →
Folder, name it (e.g. `Non-English songs`), then drag the `Lang: *`
playlists into it. They collapse on every device.

Folders are invisible to the Web API, so syncing keeps working
unchanged; the only manual part is dragging a playlist into the folder
when a language first crosses the track threshold. If you ever run
`--include-english` and keep `Lang: en` in the folder too, rename it to
something like `Songs by language`.
