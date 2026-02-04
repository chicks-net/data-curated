#!/usr/bin/env python3
"""
Fetch YouTube video metadata using yt-dlp and store in SQLite database.

This script extracts metadata from the ChristopherHicksFINI YouTube channel
without downloading any videos.
"""

import json
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

CHANNEL_URL = "https://www.youtube.com/@ChristopherHicksFINI"
DB_PATH = Path(__file__).parent / "videos.db"


def create_database():
    """Create SQLite database with videos table."""
    conn = sqlite3.connect(DB_PATH)
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
            video_type TEXT,
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
    conn.close()


def fetch_video_metadata():
    """Fetch video metadata using yt-dlp from both videos and shorts tabs."""
    all_videos = []

    # Fetch regular videos
    print(f"Fetching regular videos from {CHANNEL_URL}/videos...")
    videos = fetch_from_url(f"{CHANNEL_URL}/videos", is_shorts_tab=False)
    if videos is not None:
        all_videos.extend(videos)
        print(f"  Found {len(videos)} regular videos")

    # Fetch shorts
    print(f"Fetching shorts from {CHANNEL_URL}/shorts...")
    shorts = fetch_from_url(f"{CHANNEL_URL}/shorts", is_shorts_tab=True)
    if shorts is not None:
        all_videos.extend(shorts)
        print(f"  Found {len(shorts)} shorts")

    if not all_videos and videos is None and shorts is None:
        return None

    return all_videos


def fetch_from_url(url, is_shorts_tab=False):
    """Fetch video metadata from a specific URL using yt-dlp.

    Args:
        url: The URL to fetch from
        is_shorts_tab: True if fetching from /shorts endpoint
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


def fetch_detailed_metadata(video_id):
    """Fetch detailed metadata for a single video."""
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


def determine_video_type(video_data):
    """Determine if video is a short or regular video.

    Detection priority:
    1. Source endpoint (/shorts tab) - definitive
    2. URL pattern (/shorts/) - most reliable indicator
    3. Aspect ratio (vertical video: height > width)
    4. Duration (<= 60 seconds) combined with aspect ratio
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


def store_videos(videos):
    """Store video metadata in SQLite database."""
    if not videos:
        print("No videos to store")
        return 0

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    fetched_at = datetime.now(timezone.utc).isoformat()

    stored_count = 0
    print(f"Processing {len(videos)} videos...")

    for i, video in enumerate(videos, 1):
        video_id = video.get('id')
        if not video_id:
            continue

        print(f"[{i}/{len(videos)}] Fetching details for: {video.get('title', video_id)[:50]}...")

        # Get detailed metadata
        detailed = fetch_detailed_metadata(video_id)
        if not detailed:
            continue

        # Preserve the source endpoint tag for accurate type detection
        detailed['_from_shorts_tab'] = video.get('_from_shorts_tab', False)

        # Extract data
        tags = json.dumps(detailed.get('tags', []))
        categories = json.dumps(detailed.get('categories', []))
        video_type = determine_video_type(detailed)

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
        if stored_count % 10 == 0:
            conn.commit()

    # Record fetch history
    cursor.execute("""
        INSERT INTO fetch_history (fetched_at, videos_count, success)
        VALUES (?, ?, 1)
    """, (fetched_at, stored_count))

    conn.commit()
    conn.close()

    return stored_count


def main():
    """Main function."""
    print("YouTube Video Metadata Fetcher")
    print("=" * 50)

    # Create database if it doesn't exist
    create_database()

    # Fetch video metadata
    videos = fetch_video_metadata()

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
