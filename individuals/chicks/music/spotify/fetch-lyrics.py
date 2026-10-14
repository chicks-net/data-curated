#!/usr/bin/env python3
"""
Fetch song lyrics from LRCLIB and store in a SQLite database.

Reads an Exportify CSV (a Spotify playlist export) and fetches plain and
time-synced lyrics for every track from https://lrclib.net, storing the
results in a SQLite database alongside the CSV.

The matching waterfall follows the guidance in
https://github.com/chicks-net/chicks-projects/issues/127:

1. LRCLIB /api/get - exact match by artist, track, album and duration
2. LRCLIB /api/search - fuzzy match validated by track duration
3. not_found - the track has no lyrics in the LRCLIB catalog

The database is the cache: re-runs skip tracks with a terminal status
(found, not_found, instrumental) and only retry previous errors, unless
--force is given. Instrumentals get their own status so they are not
mistaken for tracks with an unknown language.
"""

import argparse
import csv
import json
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

LRCLIB_API_BASE = "https://lrclib.net/api"
USER_AGENT = (
    "data-curated lyrics fetcher "
    "(https://github.com/chicks-net/data-curated; personal use)"
)

# Defaults live next to this script so `just fetch-lyrics` just works
DEFAULT_CSV = Path(__file__).parent / "Liked_Songs.csv"
DEFAULT_DB = Path(__file__).parent / "lyrics.db"

# Be polite with the free LRCLIB service: pause between track lookups
REQUEST_DELAY_SECONDS = 0.5
REQUEST_TIMEOUT_SECONDS = 30
# Retries for transient errors (HTTP 429, 5xx, timeouts)
MAX_RETRIES = 3
# Accept a fuzzy /api/search result only if its duration is this close
DURATION_TOLERANCE_SECONDS = 3.0

# Number of tracks processed before committing to the database
COMMIT_INTERVAL = 20

STATUS_FOUND = "found"
STATUS_NOT_FOUND = "not_found"
STATUS_INSTRUMENTAL = "instrumental"
STATUS_ERROR = "error"

# Statuses that mean the waterfall is done for a track
TERMINAL_STATUSES = (STATUS_FOUND, STATUS_NOT_FOUND, STATUS_INSTRUMENTAL)


class LrclibNotFound(Exception):
    """LRCLIB returned 404: no match for the request (permanent miss)."""


class LrclibTransientError(Exception):
    """A retryable LRCLIB failure (HTTP 429/5xx, timeout, network error)."""


def create_database(db_path: Path) -> None:
    """Create SQLite database with tracks, lyrics and fetch_history tables."""
    with sqlite3.connect(db_path) as conn:
        cursor = conn.cursor()

        cursor.execute("""
            CREATE TABLE IF NOT EXISTS tracks (
                track_id TEXT PRIMARY KEY,
                isrc TEXT,
                track_name TEXT,
                album_name TEXT,
                artist_names TEXT,
                release_date TEXT,
                duration_ms INTEGER,
                added_at TEXT,
                imported_at TEXT
            )
        """)

        cursor.execute("""
            CREATE TABLE IF NOT EXISTS lyrics (
                track_id TEXT PRIMARY KEY REFERENCES tracks(track_id),
                status TEXT NOT NULL CHECK (status IN
                    ('found', 'not_found', 'instrumental', 'error')),
                source TEXT,
                match_method TEXT CHECK (match_method IN ('get', 'search')
                    OR match_method IS NULL),
                plain_lyrics TEXT,
                synced_lyrics TEXT,
                instrumental INTEGER,
                lrclib_id INTEGER,
                error_message TEXT,
                fetched_at TEXT
            )
        """)

        cursor.execute("""
            CREATE TABLE IF NOT EXISTS fetch_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fetched_at TEXT,
                tracks_total INTEGER,
                found INTEGER,
                not_found INTEGER,
                instrumental INTEGER,
                error INTEGER,
                skipped INTEGER,
                runtime_seconds REAL
            )
        """)

        # Create indexes for common queries
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_lyrics_status ON lyrics(status)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_added_at ON tracks(added_at)"
        )

        conn.commit()


def parse_track_uri(track_uri: str) -> Optional[str]:
    """Extract the track ID from a `spotify:track:<id>` URI.

    Args:
        track_uri: Track URI from the Exportify CSV.

    Returns:
        The bare Spotify track ID, or None if the URI is malformed.
    """
    prefix = "spotify:track:"
    if track_uri.startswith(prefix):
        return track_uri[len(prefix):] or None
    return None


def parse_int(value: Optional[str]) -> Optional[int]:
    """Parse an integer from a CSV field, tolerating junk values."""
    if not value:
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def first_artist(artist_names: Optional[str]) -> str:
    """Return the primary artist from a semicolon-separated artist list.

    Exportify joins multiple artists with ';', e.g.
    "Lilly Wood and The Prick;Robin Schulz".
    """
    if not artist_names:
        return ""
    return artist_names.split(";")[0].strip()


def import_tracks(conn: sqlite3.Connection, csv_path: Path) -> int:
    """Import tracks from an Exportify CSV into the tracks table.

    Rows are upserted by Spotify track ID, so re-imports refresh metadata
    without touching existing lyrics rows.

    Args:
        conn: SQLite connection.
        csv_path: Path to the Exportify CSV.

    Returns:
        Number of track rows imported.
    """
    # utf-8-sig: some Exportify exports carry a UTF-8 BOM
    with open(csv_path, newline="", encoding="utf-8-sig") as csv_file:
        reader = csv.DictReader(csv_file)
        imported_at = datetime.now(timezone.utc).isoformat()
        count = 0

        for row in reader:
            track_id = parse_track_uri(row.get("Track URI") or "")
            if not track_id:
                print(
                    f"Warning: skipping row with malformed Track URI: "
                    f"{row.get('Track Name', '?')}",
                    file=sys.stderr,
                )
                continue

            conn.execute(
                """
                INSERT INTO tracks (
                    track_id, isrc, track_name, album_name, artist_names,
                    release_date, duration_ms, added_at, imported_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(track_id) DO UPDATE SET
                    isrc = excluded.isrc,
                    track_name = excluded.track_name,
                    album_name = excluded.album_name,
                    artist_names = excluded.artist_names,
                    release_date = excluded.release_date,
                    duration_ms = excluded.duration_ms,
                    added_at = excluded.added_at,
                    imported_at = excluded.imported_at
                """,
                (
                    track_id,
                    row.get("ISRC") or None,
                    row.get("Track Name") or None,
                    row.get("Album Name") or None,
                    row.get("Artist Name(s)") or None,
                    row.get("Release Date") or None,
                    parse_int(row.get("Duration (ms)")),
                    row.get("Added At") or None,
                    imported_at,
                ),
            )
            count += 1

        conn.commit()

    return count


def lrclib_get_json(path: str, params: Dict[str, Any]) -> Any:
    """GET a JSON document from the LRCLIB API, with retries.

    Args:
        path: API path, e.g. "/get" or "/search".
        params: Query parameters.

    Returns:
        Parsed JSON response.

    Raises:
        LrclibNotFound: The API returned 404 (permanent miss).
        LrclibTransientError: Failure persisted after all retries.
    """
    url = f"{LRCLIB_API_BASE}{path}?{urllib.parse.urlencode(params)}"

    last_error: Optional[Exception] = None
    for attempt in range(MAX_RETRIES):
        if attempt > 0:
            # Exponential backoff for transient failures
            time.sleep(2**attempt)
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": USER_AGENT}
            )
            with urllib.request.urlopen(
                request, timeout=REQUEST_TIMEOUT_SECONDS
            ) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise LrclibNotFound(f"{path}: no match") from e
            if e.code == 429 or e.code >= 500:
                # Transient: retry after backoff
                last_error = e
                continue
            # Other client errors are bugs in our request; surface them
            raise
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            last_error = e
            continue

    raise LrclibTransientError(f"{path}: {last_error}")


def row_from_hit(hit: Dict[str, Any], match_method: str) -> Dict[str, Any]:
    """Build a lyrics-table row from an LRCLIB API hit.

    Args:
        hit: A single result object from /api/get or /api/search.
        match_method: Either 'get' (exact) or 'search' (fuzzy).

    Returns:
        Dict of lyrics-table column values.
    """
    instrumental = 1 if hit.get("instrumental") else 0
    return {
        "status": STATUS_INSTRUMENTAL if instrumental else STATUS_FOUND,
        "source": "lrclib",
        "match_method": match_method,
        "lrclib_id": hit.get("id"),
        "plain_lyrics": hit.get("plainLyrics"),
        "synced_lyrics": hit.get("syncedLyrics"),
        "instrumental": instrumental,
        "error_message": None,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
    }


def fetch_lyrics_exact(track: sqlite3.Row) -> Optional[Dict[str, Any]]:
    """Try LRCLIB /api/get for an exact metadata match.

    Args:
        track: Track row (needs artist_names, track_name, album_name,
            duration_ms).

    Returns:
        API hit dict, or None if there is no exact match.
    """
    if track["duration_ms"] is None:
        # /api/get requires a duration; without one fall through to search
        return None

    params = {
        "artist_name": first_artist(track["artist_names"]),
        "track_name": track["track_name"] or "",
        "album_name": track["album_name"] or "",
        "duration": round(track["duration_ms"] / 1000),
    }
    try:
        return lrclib_get_json("/get", params)
    except LrclibNotFound:
        return None


def fetch_lyrics_search(track: sqlite3.Row) -> Optional[Dict[str, Any]]:
    """Try LRCLIB /api/search and pick the best duration match.

    Search results are only accepted when their duration is within
    DURATION_TOLERANCE_SECONDS of the CSV duration, so covers and remixes
    from other tracks do not slip in.

    Args:
        track: Track row (needs track_name, artist_names, duration_ms).

    Returns:
        Best API hit dict, or None if nothing matches closely enough.
    """
    artist = first_artist(track["artist_names"])
    if not track["track_name"] or not artist:
        return None

    params = {"artist_name": artist, "track_name": track["track_name"]}
    try:
        results = lrclib_get_json("/search", params)
    except LrclibNotFound:
        return None
    if not isinstance(results, list) or not results:
        return None

    if track["duration_ms"] is None:
        # No duration to validate against; take the most relevant hit
        return results[0]

    expected = track["duration_ms"] / 1000
    best: Optional[Dict[str, Any]] = None
    best_diff = DURATION_TOLERANCE_SECONDS + 1.0
    for result in results:
        result_duration = result.get("duration")
        if result_duration is None:
            continue
        diff = abs(result_duration - expected)
        if diff <= DURATION_TOLERANCE_SECONDS and diff < best_diff:
            best = result
            best_diff = diff

    return best


def lookup_lyrics(track: sqlite3.Row) -> Dict[str, Any]:
    """Run the LRCLIB waterfall for one track.

    Args:
        track: Track row from the tracks table.

    Returns:
        Dict of lyrics-table column values (status plus payload).
    """
    fetched_at = datetime.now(timezone.utc).isoformat()
    error_row = {
        "status": STATUS_ERROR,
        "source": "lrclib",
        "match_method": None,
        "lrclib_id": None,
        "plain_lyrics": None,
        "synced_lyrics": None,
        "instrumental": 0,
        "error_message": None,
        "fetched_at": fetched_at,
    }

    # 1. Exact match by artist, track, album and duration
    try:
        hit = fetch_lyrics_exact(track)
    except LrclibTransientError as e:
        error_row["error_message"] = f"/get: {e}"
        return error_row
    if hit is not None:
        return row_from_hit(hit, "get")

    # 2. Fuzzy search validated by duration
    try:
        hit = fetch_lyrics_search(track)
    except LrclibTransientError as e:
        error_row["error_message"] = f"/search: {e}"
        return error_row
    if hit is not None:
        return row_from_hit(hit, "search")

    # 3. No lyrics in the LRCLIB catalog
    error_row["status"] = STATUS_NOT_FOUND
    return error_row


def store_lyrics(conn: sqlite3.Connection, track_id: str, row: Dict[str, Any]) -> None:
    """Upsert one lyrics-table row.

    Args:
        conn: SQLite connection.
        track_id: Spotify track ID (primary key of the lyrics table).
        row: Column values from lookup_lyrics().
    """
    conn.execute(
        """
        INSERT INTO lyrics (
            track_id, status, source, match_method, plain_lyrics,
            synced_lyrics, instrumental, lrclib_id, error_message,
            fetched_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(track_id) DO UPDATE SET
            status = excluded.status,
            source = excluded.source,
            match_method = excluded.match_method,
            plain_lyrics = excluded.plain_lyrics,
            synced_lyrics = excluded.synced_lyrics,
            instrumental = excluded.instrumental,
            lrclib_id = excluded.lrclib_id,
            error_message = excluded.error_message,
            fetched_at = excluded.fetched_at
        """,
        (
            track_id,
            row["status"],
            row["source"],
            row["match_method"],
            row["plain_lyrics"],
            row["synced_lyrics"],
            row["instrumental"],
            row["lrclib_id"],
            row["error_message"],
            row["fetched_at"],
        ),
    )


def process_tracks(
    conn: sqlite3.Connection, force: bool, delay: float
) -> Tuple[Dict[str, int], float]:
    """Fetch lyrics for all pending tracks.

    Args:
        conn: SQLite connection.
        force: Re-fetch tracks that already have a terminal status.
        delay: Seconds to pause between track lookups.

    Returns:
        Tuple of (counts by outcome, runtime seconds).
    """
    started = time.monotonic()
    counts = {
        STATUS_FOUND: 0,
        STATUS_NOT_FOUND: 0,
        STATUS_INSTRUMENTAL: 0,
        STATUS_ERROR: 0,
    }

    done: set = set()
    tracks = conn.execute("SELECT * FROM tracks ORDER BY added_at").fetchall()
    if not force:
        placeholders = ",".join("?" * len(TERMINAL_STATUSES))
        done = {
            row[0]
            for row in conn.execute(
                f"SELECT track_id FROM lyrics WHERE status IN ({placeholders})",
                TERMINAL_STATUSES,
            )
        }

    pending = [t for t in tracks if t["track_id"] not in done]
    skipped = len(tracks) - len(pending)
    done_note = f" ({skipped} already done)" if skipped else ""
    print(f"{len(tracks)} tracks in database, {len(pending)} to fetch{done_note}")

    for i, track in enumerate(pending, 1):
        try:
            result = lookup_lyrics(track)
        except Exception as e:  # noqa: BLE001 - keep one bad track from
            # killing a long run; it is retried on the next run
            result = {
                "status": STATUS_ERROR,
                "source": "lrclib",
                "match_method": None,
                "lrclib_id": None,
                "plain_lyrics": None,
                "synced_lyrics": None,
                "instrumental": 0,
                "error_message": repr(e),
                "fetched_at": datetime.now(timezone.utc).isoformat(),
            }

        store_lyrics(conn, track["track_id"], result)
        counts[result["status"]] += 1

        display = (track["track_name"] or "?")[:50]
        artist = first_artist(track["artist_names"])
        print(f"[{i}/{len(pending)}] {result['status']}: {display} - {artist}")

        # Commit periodically to prevent data loss on interruption
        if i % COMMIT_INTERVAL == 0:
            conn.commit()

        # Be polite to the free LRCLIB API
        if delay > 0:
            time.sleep(delay)

    conn.commit()
    return counts, time.monotonic() - started


def record_fetch_history(
    conn: sqlite3.Connection,
    counts: Dict[str, int],
    tracks_total: int,
    skipped: int,
    runtime: float,
) -> None:
    """Record a summary of this fetch run."""
    conn.execute(
        """
        INSERT INTO fetch_history (
            fetched_at, tracks_total, found, not_found, instrumental,
            error, skipped, runtime_seconds
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """,
        (
            datetime.now(timezone.utc).isoformat(),
            tracks_total,
            counts[STATUS_FOUND],
            counts[STATUS_NOT_FOUND],
            counts[STATUS_INSTRUMENTAL],
            counts[STATUS_ERROR],
            skipped,
            runtime,
        ),
    )
    conn.commit()


def main() -> None:
    """Main function."""
    parser = argparse.ArgumentParser(
        description="Fetch song lyrics from LRCLIB and store in a SQLite database."
    )
    parser.add_argument(
        "--csv",
        type=Path,
        default=DEFAULT_CSV,
        help=f"Exportify CSV to import (default: {DEFAULT_CSV.name})",
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB,
        help=f"SQLite database to write (default: {DEFAULT_DB.name})",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=REQUEST_DELAY_SECONDS,
        help=f"Seconds between API requests (default: {REQUEST_DELAY_SECONDS})",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-fetch tracks that already have a terminal status",
    )
    args = parser.parse_args()

    if not args.csv.exists():
        print(f"Error: CSV not found: {args.csv}", file=sys.stderr)
        sys.exit(1)

    print("Song Lyrics Fetcher (LRCLIB)")
    print("=" * 50)
    print(f"CSV: {args.csv}")
    print(f"Database: {args.db}")
    print()

    # Create database if it doesn't exist
    create_database(args.db)

    with sqlite3.connect(args.db) as conn:
        conn.row_factory = sqlite3.Row

        imported = import_tracks(conn, args.csv)
        print(f"Imported {imported} tracks from {args.csv.name}")
        print()

        counts, runtime = process_tracks(conn, args.force, args.delay)

        tracks_total = conn.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
        skipped = tracks_total - sum(counts.values())
        record_fetch_history(conn, counts, tracks_total, skipped, runtime)

    print()
    print("=" * 50)
    summary = (
        f"Found: {counts[STATUS_FOUND]}, "
        f"instrumental: {counts[STATUS_INSTRUMENTAL]}, "
        f"not found: {counts[STATUS_NOT_FOUND]}, "
        f"error: {counts[STATUS_ERROR]}, "
        f"skipped: {skipped}"
    )
    print(summary)
    print(f"Completed in {runtime:.0f} seconds in {args.db}")
    print()
    print("View the database with:")
    print("  just lyrics-db")
    print(f"  or: datasette {args.db} -o")


if __name__ == "__main__":
    main()
