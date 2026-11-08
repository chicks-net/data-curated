#!/usr/bin/env python3
"""
Create and keep updated a private Spotify playlist per detected language.

Reads the lyrics-based language detection results in lyrics.db (see
fetch-lyrics.py and detect-languages.py) and syncs one Spotify playlist
per language bucket, following the guidance in
https://github.com/chicks-net/chicks-projects/issues/127:

- playlists are named `Lang: <code>` (a stable prefix the script can find again) and are created private
- only languages with at least --min-tracks tracks get a playlist
- `en` is skipped by default (it is the baseline bucket, ~560 tracks); --include-english opts in
- low-confidence detections are skipped by default (the "New Soul" -> Catalan kind of error); --include-low-confidence opts in
- `unknown`, `instrumental` and `undetectable` never get playlists: they have no language value, so the SQL only sees non-NULL languages
- re-runs are idempotent: existing `Lang: *` playlists are diffed against the database and only the adds/removes are applied

Spotify credentials are read from SPOTIPY_CLIENT_ID / _SECRET / _REDIRECT_URI
environment variables, or from a `.env` file found next to this script or in
any parent directory (including the repo root). The OAuth token is cached in
.spotify-token-cache next to this script, so the browser consent prompt only
appears on the first run (and after adding scopes).

This app was registered under Spotify's February 2026 Development Mode
rules, so the script uses spotipy >= 2.26, whose playlist methods target the
new `/playlists/{id}/items` endpoints and `POST /me/playlists`.
"""

# /// script
# dependencies = ["spotipy>=2.26"]
# ///

import argparse
import os
import sqlite3
import sys
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

import spotipy
from spotipy.cache_handler import CacheFileHandler
from spotipy.exceptions import SpotifyException
from spotipy.oauth2 import SpotifyOAuth

DEFAULT_DB = Path(__file__).parent / "lyrics.db"
TOKEN_CACHE = Path(__file__).parent / ".spotify-token-cache"

# Listing existing playlists (playlist-read-private) plus creating and
# modifying private and public ones (in case a Lang: playlist is flipped
# public by hand later)
SCOPE = (
    "playlist-read-private playlist-modify-private playlist-modify-public"
)

PLAYLIST_PREFIX = "Lang: "
# Spotify accepts at most 100 items per playlist write request
BATCH_SIZE = 100

REQUIRED_ENV = ("SPOTIPY_CLIENT_ID", "SPOTIPY_CLIENT_SECRET", "SPOTIPY_REDIRECT_URI")


def find_env_file() -> Optional[Path]:
    """Find a .env file, searching up from the CWD then from this script.

    Returns:
        Path to the first .env file found, or None.
    """
    starts = [Path.cwd(), Path(__file__).resolve().parent]
    seen: Set[Path] = set()
    for start in starts:
        for directory in [start, *start.parents]:
            if directory in seen:
                continue
            seen.add(directory)
            candidate = directory / ".env"
            if candidate.is_file():
                return candidate
    return None


def load_env_file() -> Optional[Path]:
    """Export missing SPOTIPY_* variables from a .env file.

    Existing environment variables win, so a real env var can override the
    file. Values may be quoted ("http://..." style); one layer of matching
    quotes is stripped.

    Returns:
        The .env path that was loaded, or None if there isn't one.
    """
    env_path = find_env_file()
    if env_path is None:
        return None

    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key and key not in os.environ:
            os.environ[key] = value
    return env_path


def build_language_groups(
    conn: sqlite3.Connection,
    min_tracks: int,
    include_english: bool,
    include_low_confidence: bool,
    languages_filter: Optional[Set[str]],
) -> OrderedDict:
    """Group detected track URIs by language, applying the default filters.

    Args:
        conn: SQLite connection to lyrics.db.
        min_tracks: Languages with fewer tracks than this are skipped.
        include_english: Also group `en` (the baseline bucket).
        include_low_confidence: Also include low-confidence detections.
        languages_filter: If set, only these language codes pass.

    Returns:
        Ordered dict of language code -> list of `spotify:track:` URIs,
        largest bucket first. Tracks are ordered by added_at.
    """
    rows = conn.execute(
        """
        SELECT tl.language, tl.confidence, t.track_id
        FROM track_languages tl
        JOIN tracks t USING(track_id)
        WHERE tl.language IS NOT NULL
        ORDER BY t.added_at
        """
    ).fetchall()

    groups: Dict[str, List[str]] = {}
    excluded_low: Dict[str, int] = {}
    for language, confidence, track_id in rows:
        if not include_low_confidence and confidence == "low":
            excluded_low[language] = excluded_low.get(language, 0) + 1
            continue
        groups.setdefault(language, []).append(f"spotify:track:{track_id}")

    if languages_filter is not None:
        groups = {
            code: uris for code, uris in groups.items() if code in languages_filter
        }
    if not include_english:
        groups.pop("en", None)

    # Drop buckets below the minimum, biggest bucket first
    ordered = OrderedDict()
    for code, uris in sorted(
        ((c, u) for c, u in groups.items() if len(u) >= min_tracks),
        key=lambda item: (-len(item[1]), item[0]),
    ):
        ordered[code] = uris

    return OrderedDict(
        (code, {"uris": uris, "excluded_low": excluded_low.get(code, 0)})
        for code, uris in ordered.items()
    )


def fetch_own_playlists(sp: spotipy.Spotify, user_id: str) -> Dict[str, str]:
    """Map playlist name -> id for the current user's OWN playlists.

    Followed playlists appear in GET /me/playlists too; they are excluded
    so the script never tries to modify someone else's playlist that
    happens to be named `Lang: fr`.

    Args:
        sp: Authenticated Spotify client.
        user_id: Current user's Spotify ID.

    Returns:
        Dict of playlist name -> playlist id.
    """
    own: Dict[str, str] = {}
    page = sp.current_user_playlists(limit=50)
    while True:
        for playlist in page["items"]:
            owner = playlist.get("owner") or {}
            if owner.get("id") == user_id:
                # Later duplicates win; Spotify allows same-named playlists,
                # this tool manages only the one it last touched
                own[playlist["name"]] = playlist["id"]
        if not page.get("next"):
            break
        page = sp.next(page)
    return own


def fetch_playlist_uris(sp: spotipy.Spotify, playlist_id: str) -> List[str]:
    """Return the track URIs currently in one playlist, in order.

    Entries whose item is null (deleted catalog items) cannot be
    identified, so they are skipped; they cannot be diffed against anyway.

    Args:
        sp: Authenticated Spotify client.
        playlist_id: Spotify playlist ID.

    Returns:
        List of `spotify:track:` URIs.
    """
    uris: List[str] = []
    page = sp.playlist_items(playlist_id, limit=100)
    while True:
        for entry in page["items"]:
            item = entry.get("item")
            if item and item.get("uri"):
                uris.append(item["uri"])
        if not page.get("next"):
            break
        page = sp.next(page)
    return uris


def batched(sequence: List[str]) -> List[List[str]]:
    """Split a URI list into Spotify-sized write chunks."""
    return [
        sequence[i : i + BATCH_SIZE] for i in range(0, len(sequence), BATCH_SIZE)
    ]


def sync_playlist(
    sp: spotipy.Spotify,
    language: str,
    uris: List[str],
    playlist_id: Optional[str],
    dry_run: bool,
) -> str:
    """Make playlist `Lang: <language>` match the desired URI list.

    Existing playlists are diffed so re-runs only add missing and remove
    stale tracks (new tracks are appended at the end). The description is
    refreshed whenever the content changed, so the playlist says when it
    was last generated.

    Args:
        sp: Authenticated Spotify client.
        language: Language code (bucket name).
        uris: Desired `spotify:track:` URIs, ordered by added_at.
        playlist_id: Existing playlist ID, or None to create.
        dry_run: Print the plan without writing.

    Returns:
        One of "created", "updated", "unchanged" (or the dry-run
        counterparts "would create", "would update", "up to date").
    """
    name = PLAYLIST_PREFIX + language
    description = (
        f"Generated from lyrics-based language detection in data-curated "
        f"({len(uris)} tracks, updated {datetime.now(timezone.utc).date()}). "
        f"https://github.com/chicks-net/chicks-projects/issues/127"
    )

    if playlist_id is None:
        verb = "would create" if dry_run else "create"
        print(f"  {name}: {verb} private playlist with {len(uris)} tracks")
        if dry_run:
            return "would create"
        playlist = sp.current_user_playlist_create(
            name, public=False, description=description
        )
        playlist_id = playlist["id"]
        for chunk in batched(uris):
            sp.playlist_add_items(playlist_id, chunk)
        return "created"

    current = fetch_playlist_uris(sp, playlist_id)
    current_set = set(current)
    desired_set = set(uris)
    to_add = [uri for uri in uris if uri not in current_set]
    to_remove = [uri for uri in current if uri not in desired_set]

    if not to_add and not to_remove:
        print(f"  {name}: up to date ({len(uris)} tracks)")
        return "unchanged"

    verb = "would update" if dry_run else "update"
    print(
        f"  {name}: {verb} - add {len(to_add)}, remove {len(to_remove)} "
        f"({len(uris)} tracks total)"
    )
    if dry_run:
        return "would update"

    for chunk in batched(to_add):
        sp.playlist_add_items(playlist_id, chunk)
    # remove_all_occurrences keeps a hand-edited duplicate from surviving
    for chunk in batched(to_remove):
        sp.playlist_remove_all_occurrences_of_items(playlist_id, chunk)
    sp.playlist_change_details(playlist_id, description=description)
    return "updated"


def main() -> None:
    """Main function."""
    parser = argparse.ArgumentParser(
        description=(
            "Sync one private Spotify playlist per lyrics-detected language "
            "(named 'Lang: <code>')."
        )
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB,
        help=f"SQLite database to read (default: {DEFAULT_DB.name})",
    )
    parser.add_argument(
        "--min-tracks",
        type=int,
        default=2,
        help="Minimum tracks for a language to get a playlist (default: 2)",
    )
    parser.add_argument(
        "--include-english",
        action="store_true",
        help="Also sync the 'en' bucket (~560 tracks, the baseline)",
    )
    parser.add_argument(
        "--include-low-confidence",
        action="store_true",
        help=(
            "Also include low-confidence detections (short, repetitive or "
            "unsure lyrics); skipped by default"
        ),
    )
    parser.add_argument(
        "--languages",
        type=str,
        default=None,
        help=(
            "Comma-separated language codes to restrict to, e.g. 'fr,pt'. "
            "Still subject to the other filters."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would happen without touching Spotify",
    )
    args = parser.parse_args()

    if not args.db.exists():
        print(f"Error: database not found: {args.db}", file=sys.stderr)
        print("Run 'just fetch-lyrics' and 'just detect-languages' first.", file=sys.stderr)
        sys.exit(1)

    env_path = load_env_file()
    missing = [name for name in REQUIRED_ENV if not os.environ.get(name)]
    if missing:
        print(
            f"Error: missing Spotify credentials: {', '.join(missing)}",
            file=sys.stderr,
        )
        print(
            "Create an app at https://developer.spotify.com/dashboard (Web "
            "API, redirect URI http://127.0.0.1:8888/callback) and put "
            "SPOTIPY_CLIENT_ID, SPOTIPY_CLIENT_SECRET and "
            "SPOTIPY_REDIRECT_URI in .env.",
            file=sys.stderr,
        )
        sys.exit(1)

    languages_filter: Optional[Set[str]] = None
    if args.languages is not None:
        languages_filter = {
            code.strip() for code in args.languages.split(",") if code.strip()
        }

    print("Spotify Language Playlists")
    print("=" * 50)
    print(f"Database: {args.db}")
    if env_path:
        print(f"Credentials: {env_path}")
    if args.dry_run:
        print("DRY RUN - nothing will be written to Spotify")
    print()

    with sqlite3.connect(args.db) as conn:
        has_languages = conn.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' "
            "AND name='track_languages'"
        ).fetchone()[0]
        if not has_languages:
            print("Error: track_languages table missing from lyrics.db", file=sys.stderr)
            print("Run 'just detect-languages' first.", file=sys.stderr)
            sys.exit(1)
        groups = build_language_groups(
            conn,
            args.min_tracks,
            args.include_english,
            args.include_low_confidence,
            languages_filter,
        )

    if not groups:
        print(
            f"No languages with at least {args.min_tracks} tracks passed the "
            "filters - nothing to do."
        )
        return

    print(f"Languages to sync (min {args.min_tracks} tracks):")
    for code, group in groups.items():
        note = ""
        if group["excluded_low"]:
            note = (
                f" (+{group['excluded_low']} low-confidence excluded)"
            )
        print(f"  {code}: {len(group['uris'])} tracks{note}")
    print()

    print("Authenticating with Spotify (browser consent on first run)...")
    sp = spotipy.Spotify(
        auth_manager=SpotifyOAuth(
            scope=SCOPE,
            cache_handler=CacheFileHandler(cache_path=str(TOKEN_CACHE)),
        )
    )
    me = sp.current_user()
    user_id = me["id"]
    print(f"Signed in as {me.get('display_name') or user_id}")
    print()

    existing = fetch_own_playlists(sp, user_id)

    print("Plan:")
    stats: Dict[str, int] = {}
    failures = 0
    for code, group in groups.items():
        name = PLAYLIST_PREFIX + code
        try:
            outcome = sync_playlist(
                sp, code, group["uris"], existing.get(name), args.dry_run
            )
        except SpotifyException as e:
            print(f"  {name}: FAILED - {e.http_status} {e.msg}")
            failures += 1
            continue
        stats[outcome] = stats.get(outcome, 0) + 1

    print()
    print("=" * 50)
    summary = ", ".join(f"{count} {label}" for label, count in stats.items())
    print(f"Result: {summary or 'nothing'}")
    if failures:
        print(
            f"{failures} language(s) failed - re-run to retry; Spotify "
            "rate limits reset quickly"
        )
        sys.exit(1)
    print()
    print(
        "Playlists are private. In Spotify set any of them public if you "
        "want to share; the script can still update them."
    )


if __name__ == "__main__":
    main()
