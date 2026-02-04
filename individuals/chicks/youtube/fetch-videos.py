#!/usr/bin/env python3
"""
Fetch YouTube video metadata using yt-dlp and store in SQLite database.

This script extracts metadata from the ChristopherHicksFINI YouTube channel
without downloading any videos.
"""

import argparse
import json
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, List, Dict, Any

# Default channel URL (can be overridden via command-line argument)
DEFAULT_CHANNEL_URL = "https://www.youtube.com/@ChristopherHicksFINI"
DB_PATH = Path(__file__).parent / "videos.db"

# Number of videos to process before committing to database
COMMIT_INTERVAL = 10


def create_database() -> None:
    """Create SQLite database with videos table."""
    with sqlite3.connect(DB_PATH) as conn:
        cursor = conn.cursor()

        cursor.execute("""
            CREATE TABLE IF NOT EXISTS videos (
                video_id TEXT PRIMARY KEY,
                title TEXT,
                description TEXT,
                upload_date TEXT,
                duration INTEGER,
                view_count INTEGER,
                like_count INTEGER,
                comment_count INTEGER,
                video_type TEXT CHECK (video_type IN ('video', 'short')),
                url TEXT,
                thumbnail_url TEXT,
                tags TEXT,
                categories TEXT,
                fetched_at TEXT,
                width INTEGER,
                height INTEGER,
                fps REAL
            )
        """)

        cursor.execute("""
            CREATE TABLE IF NOT EXISTS fetch_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fetched_at TEXT,
                videos_count INTEGER,
                success INTEGER
            )
        """)

        # Create indexes for common queries
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_upload_date ON videos(upload_date)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_video_type ON videos(video_type)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_view_count ON videos(view_count DESC)")

        conn.commit()


def fetch_video_metadata(channel_url: str) -> Optional[List[Dict[str, Any]]]:
    """Fetch video metadata using yt-dlp from both videos and shorts tabs.

    Args:
        channel_url: The YouTube channel URL to fetch from

    Returns:
        List of video metadata dictionaries, or None if fetch failed
    """
    all_videos = []

    # Fetch regular videos
    print(f"Fetching regular videos from {channel_url}/videos...")
    videos = fetch_from_url(f"{channel_url}/videos", is_shorts_tab=False)
    if videos is not None:
        all_videos.extend(videos)
        print(f"  Found {len(videos)} regular videos")

    # Fetch shorts
    print(f"Fetching shorts from {channel_url}/shorts...")
    shorts = fetch_from_url(f"{channel_url}/shorts", is_shorts_tab=True)
    if shorts is not None:
        all_videos.extend(shorts)
        print(f"  Found {len(shorts)} shorts")

    if not all_videos and videos is None and shorts is None:
        return None

    return all_videos


def fetch_from_url(url: str, is_shorts_tab: bool = False) -> Optional[List[Dict[str, Any]]]:
    """Fetch video metadata from a specific URL using yt-dlp.

    Args:
        url: The URL to fetch from
        is_shorts_tab: True if fetching from /shorts endpoint

    Returns:
        List of video metadata dictionaries, or None if fetch failed
    """
    cmd = [
        "yt-dlp",
        "--dump-json",
        "--flat-playlist",
        "--extractor-args", "youtube:skip=dash,hls",
        url
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=60)

        # Parse each line as JSON (yt-dlp outputs one JSON object per line)
        videos = []
        for line in result.stdout.strip().split('\n'):
            if line:
                video_data = json.loads(line)
                # Tag videos with their source endpoint
                video_data['_from_shorts_tab'] = is_shorts_tab
                videos.append(video_data)

        return videos
    except subprocess.CalledProcessError as e:
        print(f"Error running yt-dlp: {e}", file=sys.stderr)
        print(f"stderr: {e.stderr}", file=sys.stderr)
        return None
    except subprocess.TimeoutExpired as e:
        print(f"Timeout fetching from {url}: {e}", file=sys.stderr)
        return None
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        return None


def fetch_detailed_metadata(video_id: str) -> Optional[Dict[str, Any]]:
    """Fetch detailed metadata for a single video.

    Args:
        video_id: YouTube video ID

    Returns:
        Video metadata dictionary, or None if fetch failed
    """
    cmd = [
        "yt-dlp",
        "--dump-json",
        "--no-download",
        f"https://www.youtube.com/watch?v={video_id}"
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=30)
        return json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError, subprocess.TimeoutExpired) as e:
        print(f"Error fetching details for {video_id}: {e}", file=sys.stderr)
        return None


def determine_video_type(video_data: Dict[str, Any]) -> str:
    """Determine if video is a short or regular video.

    Detection priority:
    1. Source endpoint (/shorts tab) - definitive
    2. URL pattern (/shorts/) - most reliable indicator
    3. Aspect ratio (vertical video: height > width)
    4. Duration (<= 60 seconds) combined with aspect ratio

    Args:
        video_data: Video metadata dictionary

    Returns:
        Either 'short' or 'video'
    """
    # Check if this came from the /shorts endpoint - that's definitive
    if video_data.get('_from_shorts_tab'):
        return 'short'

    url = video_data.get('webpage_url', '')
    duration = video_data.get('duration', 0)
    width = video_data.get('width')
    height = video_data.get('height')

    # Check URL pattern - this is the most reliable indicator
    if url and '/shorts/' in url:
        return 'short'

    # Calculate aspect ratio if dimensions are available
    is_vertical = False
    if width and height and width > 0:
        aspect_ratio = height / width
        # Vertical videos have aspect ratio > 1.0 (height > width)
        # Shorts are typically 9:16 (1.78) but allow some flexibility
        is_vertical = aspect_ratio > 1.0

    # If video is vertical and under 60 seconds, it's likely a short
    # (even if URL doesn't contain /shorts/)
    if is_vertical and duration and 0 < duration <= 60:
        return 'short'

    # If only duration check passes but not vertical, it's a regular short video
    # (not a YouTube Short format)
    return 'video'


def store_videos(videos: List[Dict[str, Any]]) -> int:
    """Store video metadata in SQLite database.

    Args:
        videos: List of video metadata dictionaries

    Returns:
        Number of videos successfully stored
    """
    if not videos:
        print("No videos to store")
        return 0

    with sqlite3.connect(DB_PATH) as conn:
        cursor = conn.cursor()
        fetched_at = datetime.now(timezone.utc).isoformat()

        stored_count = 0
        failed_videos = []
        print(f"Processing {len(videos)} videos...")

        for i, video in enumerate(videos, 1):
            video_id = video.get('id')
            if not video_id:
                continue

            print(f"[{i}/{len(videos)}] Fetching details for: {video.get('title', video_id)[:50]}...")

            # Get detailed metadata
            detailed = fetch_detailed_metadata(video_id)
            if not detailed:
                # Track failed fetches to report at the end
                failed_videos.append({
                    'video_id': video_id,
                    'title': video.get('title', 'Unknown')
                })
                continue

            # Preserve the source endpoint tag for accurate type detection
            detailed['_from_shorts_tab'] = video.get('_from_shorts_tab', False)

            # Extract data
            tags = json.dumps(detailed.get('tags', []))
            categories = json.dumps(detailed.get('categories', []))
            video_type = determine_video_type(detailed)

            # Using parameterized queries to prevent SQL injection
            cursor.execute("""
                INSERT OR REPLACE INTO videos (
                    video_id, title, description, upload_date, duration,
                    view_count, like_count, comment_count, video_type,
                    url, thumbnail_url, tags, categories, fetched_at,
                    width, height, fps
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                video_id,
                detailed.get('title'),
                detailed.get('description'),
                detailed.get('upload_date'),
                detailed.get('duration'),
                detailed.get('view_count'),
                detailed.get('like_count'),
                detailed.get('comment_count'),
                video_type,
                detailed.get('webpage_url'),
                detailed.get('thumbnail'),
                tags,
                categories,
                fetched_at,
                detailed.get('width'),
                detailed.get('height'),
                detailed.get('fps')
            ))

            stored_count += 1

            # Commit periodically to prevent data loss on interruption
            if stored_count % COMMIT_INTERVAL == 0:
                conn.commit()

        # Record fetch history
        # Using parameterized queries to prevent SQL injection
        cursor.execute("""
            INSERT INTO fetch_history (fetched_at, videos_count, success)
            VALUES (?, ?, 1)
        """, (fetched_at, stored_count))

        conn.commit()

        # Report failed fetches if any
        if failed_videos:
            print(f"\n⚠️  Failed to fetch details for {len(failed_videos)} video(s):")
            for failed in failed_videos[:5]:  # Show first 5 failures
                print(f"  - {failed['video_id']}: {failed['title'][:50]}")
            if len(failed_videos) > 5:
                print(f"  ... and {len(failed_videos) - 5} more")

        return stored_count


def main() -> None:
    """Main function."""
    parser = argparse.ArgumentParser(
        description="Fetch YouTube video metadata using yt-dlp and store in SQLite database."
    )
    parser.add_argument(
        "--channel",
        default=DEFAULT_CHANNEL_URL,
        help=f"YouTube channel URL (default: {DEFAULT_CHANNEL_URL})"
    )
    args = parser.parse_args()

    print("YouTube Video Metadata Fetcher")
    print("=" * 50)
    print(f"Channel: {args.channel}")
    print()

    # Create database if it doesn't exist
    create_database()

    # Fetch video metadata
    videos = fetch_video_metadata(args.channel)

    if videos is None:
        print("\nFailed to fetch videos. Make sure yt-dlp is installed:")
        print("  pip install yt-dlp")
        print("  or: brew install yt-dlp")
        sys.exit(1)

    if not videos:
        print("No videos found")
        sys.exit(0)

    # Store in database
    count = store_videos(videos)

    print("\n" + "=" * 50)
    print(f"Successfully stored {count} videos in {DB_PATH}")
    print(f"\nView the database with:")
    print(f"  just youtube-db")
    print(f"  or: datasette {DB_PATH} -o")


if __name__ == "__main__":
    main()
