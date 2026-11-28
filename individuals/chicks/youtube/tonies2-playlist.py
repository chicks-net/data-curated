#!/usr/bin/env python3
"""
Create the "All Liked Music Videos" YouTube playlist: every music video
liked on YouTube that is not already on "Sawyer Tonies 1".

The source is the account's Liked Videos list (the special "LL" playlist,
read via yt-dlp with the browser's cookies), filtered to videos YouTube
categorizes as Music. The YouTube Music "Liked Music" list is NOT used:
those are separately-liked YTM tracks and stay disjoint from videos
liked on YouTube itself.

Reading uses yt-dlp + --cookies-from-browser (macOS asks for Keychain
access once - click "Always Allow"). Creating the playlist uses
ytmusicapi with a browser.json auth file created once via
`ytmusicapi browser` (see README).

Usage:

    just create-tonies2-playlist             # dry-run: report only
    just create-tonies2-playlist ""          # actually create it

The first run scans every liked video to read its category (the LL
playlist caps at 5000, so with 4 workers this takes roughly half an
hour). Results are cached in tonies2-cache.json (gitignored), so later
runs only scan newly liked videos.

One-shot by design: if an "All Liked Music Videos" playlist already
exists, the script refuses to touch it unless --force is given (--force
only adds missing tracks - it never removes or reorders anything, so
manual curation on YouTube survives).
"""

# /// script
# dependencies = ["ytmusicapi"]
# ///

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
AUTH_FILE = SCRIPT_DIR / "browser.json"
CACHE_FILE = SCRIPT_DIR / "tonies2-cache.json"

TONIES1_ID = "PLGy4wkCuxqNg"
PLAYLIST_NAME = "All Liked Music Videos"
PLAYLIST_DESCRIPTION = "Music videos liked on YouTube, not on Sawyer Tonies 1"
LIKED_URL = "https://www.youtube.com/playlist?list=LL"

TONIE_SECONDS = 90 * 60  # Creative-Tonie capacity, informational only
ADD_CHUNK = 100  # videos added per ytmusicapi call
SAVE_EVERY = 100  # cache writes during a scan
ERROR_STREAK_STOP = 50  # consecutive failed videos that abort a scan


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def parse_id_list(raw):
    """Comma-separated string -> ordered, de-duplicated list of IDs."""
    seen = set()
    ids = []
    for item in raw.split(","):
        item = item.strip()
        if item and item not in seen:
            seen.add(item)
            ids.append(item)
    return ids


def fmt_mmss(seconds):
    if seconds is None:
        return "--:--"
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def fmt_hm(seconds):
    seconds = int(seconds or 0)
    h, rem = divmod(seconds, 3600)
    m, _ = divmod(rem, 60)
    return f"{h}h {m:02d}m" if h else f"{m}m"


def ytdlp_base(browser):
    cmd = ["yt-dlp", "--no-warnings"]
    if browser:
        cmd += ["--cookies-from-browser", browser]
    return cmd


def fetch_flat_playlist(url, browser):
    """Flat playlist dump: returns a list of {id, title, duration, ...}."""
    cmd = ytdlp_base(browser) + ["--flat-playlist", "--dump-single-json", url]
    result = subprocess.run(
        cmd, capture_output=True, text=True, check=True, timeout=600
    )
    data = json.loads(result.stdout)
    return data.get("entries") or []


def cache_entry_from_info(info):
    """Condensed per-video record kept in the cache."""
    return {
        "title": info.get("title"),
        "duration": info.get("duration"),
        "channel": info.get("channel") or info.get("uploader"),
        "categories": info.get("categories") or [],
        "scanned_at": now_iso(),
    }


def fetch_video_info(video_id, browser):
    """Full metadata for one video, or None if the fetch failed."""
    cmd = ytdlp_base(browser) + [
        "--dump-json",
        "--skip-download",
        "--ignore-errors",
        f"https://www.youtube.com/watch?v={video_id}",
    ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=True, timeout=90
        )
        return cache_entry_from_info(json.loads(result.stdout))
    except (
        subprocess.CalledProcessError,
        json.JSONDecodeError,
        subprocess.TimeoutExpired,
    ):
        return None


class ScanState:
    """Shared counters and process handles for the parallel scan."""

    def __init__(self, total):
        self.lock = threading.Lock()
        self.total = total
        self.done = 0
        self.procs = []
        self.stop = threading.Event()

    def note_success(self, cache, vid, entry):
        with self.lock:
            # The cache mutation belongs under the lock too: json.dump in
            # save_cache iterates the dict, which raises RuntimeError if
            # another thread inserts a new key mid-iteration.
            cache[vid] = entry
            self.done += 1
            if self.done % 25 == 0 or self.done == self.total:
                print(
                    f"\r  scanned {self.done}/{self.total}",
                    end="",
                    flush=True,
                )
            if self.done % SAVE_EVERY == 0:
                save_cache(cache)

    def abort(self, message):
        with self.lock:
            if self.stop.is_set():
                return
            self.stop.set()
            print(f"\n{message}", file=sys.stderr)
            for proc in self.procs:
                try:
                    proc.kill()
                except OSError:
                    pass


def load_cache():
    if CACHE_FILE.exists():
        try:
            with open(CACHE_FILE) as f:
                return json.load(f)
        except json.JSONDecodeError:
            print(f"Warning: {CACHE_FILE.name} is corrupt - rescanning.")
    return {}


def save_cache(cache):
    tmp = CACHE_FILE.with_suffix(".json.tmp")
    with open(tmp, "w") as f:
        json.dump(cache, f)
    os.replace(tmp, CACHE_FILE)


def scan_chunk(chunk, cache, browser, state, sleep, skip_next):
    """Scan a chunk of video IDs in one long-running yt-dlp process."""
    if not chunk or state.stop.is_set():
        return

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".urls", delete=False
    ) as batch:
        batch.write(
            "\n".join(
                f"https://www.youtube.com/watch?v={vid}" for vid in chunk
            )
        )
        batch_path = batch.name

    cmd = ytdlp_base(browser) + [
        "--dump-json",
        "--skip-download",
        "--ignore-errors",
    ]
    # Pacing keeps YouTube's per-account rate limit at bay - a full
    # speed scan of a big liked list gets blocked within minutes, and
    # the block lasts about an hour.
    if sleep > 0:
        cmd += ["--sleep-requests", str(sleep)]
    if skip_next:
        # The "next" request (initial data) is not needed for categories
        # or durations - skipping it roughly halves the requests per
        # video. --full-requests turns this off if it ever misbehaves.
        cmd += ["--extractor-args", "youtube:player_skip=initial_data"]
    cmd += ["--batch-file", batch_path]

    scanned = 0
    errors = 0
    proc = None
    try:
        # stderr merges into the same pipe: ERROR lines are counted so a
        # rate-limited or blocked run aborts quickly instead of grinding
        # through hundreds of doomed requests. JSON lines never start
        # with ERROR, so the two streams stay distinguishable.
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        with state.lock:
            state.procs.append(proc)
        for line in proc.stdout:
            if state.stop.is_set():
                break
            try:
                info = json.loads(line)
            except json.JSONDecodeError:
                if line.startswith("ERROR"):
                    errors += 1
                    if errors >= ERROR_STREAK_STOP:
                        state.abort(
                            "Too many videos failing in a row - YouTube "
                            "is likely rate-limiting (blocks last about "
                            "an hour). Progress is cached; re-run later "
                            "to resume where this left off."
                        )
                        break
                continue
            errors = 0
            vid = info.get("id")
            if not vid:
                continue
            scanned += 1
            state.note_success(cache, vid, cache_entry_from_info(info))
    finally:
        if proc is not None:
            try:
                proc.kill()
            except OSError:
                pass
        os.unlink(batch_path)

    if state.stop.is_set():
        return
    missing = len(chunk) - scanned
    if missing > 0:
        # Dead, private, or blocked videos produce no JSON line. They are
        # simply not cached, so a later run retries them.
        print(
            f"\n  note: {missing} video(s) in this batch had no data "
            "(deleted, private, or blocked) - skipped"
        )
    if scanned == 0 and len(chunk) >= 10:
        # A whole empty batch usually means YouTube is refusing requests
        # (bot check / rate limit), not that every video vanished.
        state.abort(
            "No data came back from a whole scan batch - YouTube is "
            "likely throttling. Progress is cached; wait a bit and "
            "re-run, maybe with --workers 1."
        )


def scan_missing(ids, cache, browser, workers, sleep, skip_next):
    """Fetch full metadata (categories) for every ID not in the cache."""
    todo = [vid for vid in ids if vid not in cache]
    if not todo:
        return

    # Interleave IDs across workers so progress advances over the whole
    # list evenly, and a killed worker leaves holes spread out (a later
    # run retries whatever is missing from the cache).
    chunks = [todo[i::workers] for i in range(workers)]
    chunks = [chunk for chunk in chunks if chunk]

    state = ScanState(len(todo))
    print(
        f"Scanning {len(todo)} liked videos for their categories "
        f"({workers} workers, {sleep}s between requests, cached in "
        f"{CACHE_FILE.name})..."
    )
    print(
        "  first scan of a big liked list takes a while "
        "(YouTube caps the list at 5000)"
    )

    try:
        threads = []
        for chunk in chunks:
            thread = threading.Thread(
                target=scan_chunk,
                args=(chunk, cache, browser, state, sleep, skip_next),
            )
            thread.daemon = True
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        state.abort("Interrupted - progress is cached.")
    finally:
        # Workers mutate the cache under the lock; take it for the final
        # save as well (a KeyboardInterrupt can leave daemon threads
        # running for a moment).
        with state.lock:
            save_cache(cache)
        print()

    if state.stop.is_set():
        print(
            "Scan aborted early: YouTube was rate-limiting. Continuing "
            f"with cached results ({len(todo) - state.done} of {len(todo)} "
            "videos were not fetched) - re-run later to retry them."
        )
        return

    missing = len(todo) - state.done
    if missing > 0:
        print(
            f"Scan incomplete: {missing} of {len(todo)} videos could not "
            "be fetched (rate-limited, deleted, or blocked). They were "
            "skipped - re-run the recipe later to retry them."
        )


def is_music(entry):
    return "music" in [
        category.lower() for category in entry.get("categories") or []
    ]


def find_playlist(yt):
    for playlist in yt.get_library_playlists(limit=None):
        if playlist.get("title") == PLAYLIST_NAME:
            return playlist
    return None


def ensure_browser_auth():
    """Make sure browser.json is recognized as browser auth.

    YTMusic only treats the file as browser auth when its headers
    contain a "SAPISIDHASH ..." authorization entry - the setup wizard
    writes one when headers are pasted from DevTools, but a hand-built
    header set (or a DevTools paste that missed it) can lack it.
    ytmusicapi recomputes the hash from the SAPISID cookie on every
    request, so any synthesized placeholder works; patch it in place.
    """
    data = json.loads(AUTH_FILE.read_text())
    if "SAPISIDHASH" in (data.get("authorization") or ""):
        return
    match = re.search(r"SAPISID=([^;]+)", data.get("cookie", ""))
    if not match:
        return  # no SAPISID to hash - let YTMusic raise its own error
    timestamp = str(int(time.time()))
    digest = hashlib.sha1(
        f"{timestamp} {match.group(1)} https://music.youtube.com".encode()
    ).hexdigest()
    data["authorization"] = f"SAPISIDHASH {timestamp}_{digest}"
    AUTH_FILE.write_text(json.dumps(data))
    print("Patched authorization header into browser.json")


def create_playlist(kept_ids, privacy, force):
    from ytmusicapi import YTMusic

    if not AUTH_FILE.exists():
        sys.exit(
            f"{AUTH_FILE.name} not found. Authenticate once with:\n"
            "  cd individuals/chicks/youtube\n"
            "  uvx ytmusicapi browser\n"
            "(see README for details)"
        )

    ensure_browser_auth()
    yt = YTMusic(str(AUTH_FILE))

    existing = find_playlist(yt)
    if existing:
        playlist_id = existing.get("playlistId")
        url = f"https://www.youtube.com/playlist?list={playlist_id}"
        if not force:
            sys.exit(
                f'"{PLAYLIST_NAME}" already exists ({url}).\n'
                "One-shot by design: rename or delete it first, or "
                "re-run with --force to only add missing tracks "
                "(nothing is ever removed)."
            )
        print(f'"{PLAYLIST_NAME}" exists ({url}) - adding missing tracks.')
        existing_tracks = (
            yt.get_playlist(playlist_id, limit=None).get("tracks") or []
        )
        existing_ids = {track.get("videoId") for track in existing_tracks}
        to_add = [
            vid for vid in kept_ids if vid not in existing_ids
        ]
        already_on_it = len(kept_ids) - len(to_add)
        if already_on_it:
            print(f"  {already_on_it} of the tracks are already on it")
    else:
        playlist_id = yt.create_playlist(
            title=PLAYLIST_NAME,
            description=PLAYLIST_DESCRIPTION,
            privacy_status=privacy.upper(),
        )
        if isinstance(playlist_id, dict):
            playlist_id = playlist_id.get("playlistId")
        if not playlist_id:
            sys.exit("Playlist creation failed.")
        to_add = kept_ids
        print(f'Created "{PLAYLIST_NAME}" ({privacy}).')

    if not to_add:
        print("Nothing to add.")
    for i in range(0, len(to_add), ADD_CHUNK):
        chunk = to_add[i : i + ADD_CHUNK]
        yt.add_playlist_items(playlist_id, videoIds=chunk)
        print(f"  added {min(i + ADD_CHUNK, len(to_add))}/{len(to_add)}")
        time.sleep(0.5)

    print(f"\nDone: https://www.youtube.com/playlist?list={playlist_id}")
    print(
        "Track order follows the liked list (newest first) - reorder "
        "on YouTube if you like, then extract with:\n"
        f"  just extract-youtube-audio {playlist_id}"
    )


def main():
    # Progress prints use \r updates, so make sure output flushes even
    # when piped (e.g. `just create-tonies2-playlist | tee log`)
    sys.stdout.reconfigure(line_buffering=True)

    parser = argparse.ArgumentParser(
        description=(
            'Create the "All Liked Music Videos" playlist: music videos '
            'liked on YouTube that are not on "Sawyer Tonies 1".'
        )
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report only; do not create or change any playlist",
    )
    parser.add_argument(
        "--browser",
        default="chrome",
        help="browser for yt-dlp cookies (default: chrome)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        metavar="N",
        help="only consider the newest N liked videos (for quick tests)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=4,
        metavar="N",
        help="concurrent yt-dlp scan processes (default: 4)",
    )
    parser.add_argument(
        "--sleep",
        type=float,
        default=0.5,
        metavar="SECONDS",
        help="pause between yt-dlp requests during the scan "
        "(default: 0.5; 0 disables)",
    )
    parser.add_argument(
        "--full-requests",
        action="store_true",
        help="do not skip YouTube's 'next' metadata request during the "
        "scan (slower, more rate-limit-prone, but a fallback if "
        "category data ever looks wrong)",
    )
    parser.add_argument(
        "--include-ids",
        default="",
        help="comma-separated video IDs to include even if not "
        "categorized as Music",
    )
    parser.add_argument(
        "--exclude-ids",
        default="",
        help="comma-separated video IDs to leave out",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="if the playlist already exists, add missing tracks "
        "instead of refusing",
    )
    parser.add_argument(
        "--privacy",
        choices=["private", "unlisted", "public"],
        default="private",
        help="visibility of the created playlist (default: private)",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="discard the metadata cache and rescan everything",
    )
    args = parser.parse_args()

    include_ids = parse_id_list(args.include_ids)
    exclude_ids = parse_id_list(args.exclude_ids)

    if args.refresh and CACHE_FILE.exists():
        CACHE_FILE.unlink()
    cache = load_cache()

    print(f"Reading liked videos ({args.browser} cookies)...")
    liked = fetch_flat_playlist(LIKED_URL, args.browser)
    if args.limit:
        liked = liked[: args.limit]
    unavailable = [entry for entry in liked if not entry.get("id")]
    liked = [entry for entry in liked if entry.get("id")]
    print(f"Liked videos: {len(liked)}" + (" (LL caps at 5000)" if len(liked) >= 5000 else ""))

    print("Reading Sawyer Tonies 1...")
    tonies1 = fetch_flat_playlist(
        f"https://www.youtube.com/playlist?list={TONIES1_ID}", None
    )
    tonies1_ids = {entry["id"] for entry in tonies1 if entry.get("id")}
    print(f"Sawyer Tonies 1: {len(tonies1_ids)} videos")

    # Videos already on Tonies 1 don't need a category scan.
    scan_ids = [
        entry["id"]
        for entry in liked
        if entry["id"] not in tonies1_ids
    ] + [vid for vid in include_ids if vid not in tonies1_ids]
    scan_missing(
        scan_ids,
        cache,
        args.browser,
        args.workers,
        args.sleep,
        not args.full_requests,
    )

    # Music videos among the likes, in liked order (newest first).
    kept = []
    for entry in liked:
        vid = entry["id"]
        if vid in exclude_ids or vid in tonies1_ids:
            continue
        info = cache.get(vid)
        if info and (is_music(info) or vid in include_ids):
            record = {"id": vid, **info}
            record["forced"] = vid in include_ids and not is_music(info)
            kept.append(record)

    # --include-ids entries that were filtered out (or never liked at all)
    kept_ids = {record["id"] for record in kept}
    for vid in include_ids:
        if vid in kept_ids or vid in tonies1_ids or vid in exclude_ids:
            continue
        info = cache.get(vid) or fetch_video_info(vid, args.browser)
        if info:
            kept.append({"id": vid, "forced": not is_music(info), **info})
        else:
            print(f"Warning: --include-ids video {vid} could not be fetched")

    if unavailable:
        print(
            f"Note: {len(unavailable)} liked entries are unavailable "
            "(deleted/private) - skipped"
        )

    total_seconds = sum(record.get("duration") or 0 for record in kept)
    forced_count = sum(1 for record in kept if record.get("forced"))
    on_tonies1 = sum(1 for entry in liked if entry["id"] in tonies1_ids)

    if not kept and len(cache) > 100:
        print()
        print(
            "No music videos found although many videos were scanned - "
            "category data may not be arriving. Re-run with "
            "--full-requests to rule that out."
        )

    print()
    summary = f"Music videos among the likes: {len(kept)}"
    if forced_count:
        summary += f" ({forced_count} forced via --include-ids)"
    print(summary)
    print(f"Excluded (already on Sawyer Tonies 1): {on_tonies1}")
    print(f'Tracks for "{PLAYLIST_NAME}": {len(kept)}, {fmt_hm(total_seconds)} total')
    print()
    for i, record in enumerate(kept, 1):
        title = (record.get("title") or "?")[:70]
        channel = (record.get("channel") or "?")[:30]
        print(f"  {i:4d}. [{fmt_mmss(record.get('duration'))}] {title} - {channel}")

    if total_seconds > TONIE_SECONDS:
        print()
        print(
            f"Note: {fmt_hm(total_seconds)} is over a Creative-Tonie's "
            "90 minutes. The playlist is uncapped by design - when "
            "loading a Tonie, extract just the first 90 minutes' worth."
        )

    if args.dry_run:
        print()
        print(
            "Dry-run only. To create the playlist:\n"
            '  just create-tonies2-playlist ""'
        )
        return

    print()
    create_playlist([record["id"] for record in kept], args.privacy, args.force)


if __name__ == "__main__":
    main()
