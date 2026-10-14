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
