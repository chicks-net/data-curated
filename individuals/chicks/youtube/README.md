# YouTube Video Database

Database of public videos and shorts from the
[ChristopherHicksFINI YouTube channel](https://www.youtube.com/@ChristopherHicksFINI).

## Quick Start

```bash
# Fetch video metadata and create/update database
just fetch-youtube-videos

# Link videos to blog posts on chicks.net
just link-youtube-blog-posts        # Dry-run mode (shows what would be updated)
just link-youtube-blog-posts ""     # Actually update the database

# View database in browser
just youtube-db

# Check database status
just youtube-status
```

## Requirements

- Python 3.x
- yt-dlp: `pip install yt-dlp` or `brew install yt-dlp`
- SQLite3 (usually pre-installed)
- Go (for blog post linking): `brew install go` or see <https://go.dev/doc/install>
- Git (for blog post linking, usually pre-installed)

## Database Schema

### videos table

| Column | Type | Description |
| ------ | ---- | ----------- |
| video_id | TEXT | YouTube video ID (primary key) |
| title | TEXT | Video title |
| description | TEXT | Video description |
| upload_date | TEXT | Upload date (YYYYMMDD format) |
| duration | INTEGER | Duration in seconds |
| view_count | INTEGER | Number of views |
| like_count | INTEGER | Number of likes |
| comment_count | INTEGER | Number of comments |
| video_type | TEXT | 'video' or 'short' |
| url | TEXT | Full YouTube URL |
| thumbnail_url | TEXT | Thumbnail image URL |
| tags | TEXT | JSON array of tags |
| categories | TEXT | JSON array of categories |
| fetched_at | TEXT | ISO timestamp when data was fetched |
| width | INTEGER | Video width in pixels |
| height | INTEGER | Video height in pixels |
| fps | REAL | Frames per second |
| blog_url | TEXT | Corresponding blog post URL on chicks.net (if exists) |

### fetch_history table

Tracks each time the data was fetched:

| Column | Type | Description |
| ------ | ---- | ----------- |
| id | INTEGER | Auto-increment ID |
| fetched_at | TEXT | ISO timestamp |
| videos_count | INTEGER | Number of videos processed |
| success | INTEGER | 1 if successful, 0 if failed |

## Manual Usage

### Fetch videos

```bash
cd individuals/chicks/youtube
./fetch-videos.py
```

### View in Datasette

```bash
datasette videos.db -o
```

### Query with SQLite

```bash
sqlite3 videos.db
```

Example queries:

```sql
-- Count videos vs shorts
SELECT video_type, COUNT(*) FROM videos GROUP BY video_type;

-- Most viewed videos
SELECT title, view_count, url FROM videos ORDER BY view_count DESC LIMIT 10;

-- Videos by upload year
SELECT substr(upload_date, 1, 4) as year, COUNT(*) as count
FROM videos GROUP BY year ORDER BY year DESC;

-- Average duration by type
SELECT video_type, AVG(duration) as avg_duration
FROM videos GROUP BY video_type;
```

## Data Collection

The script uses yt-dlp to extract metadata without downloading videos:

1. Fetches the list of all videos from the channel
2. For each video, retrieves detailed metadata
3. Stores or updates records in SQLite database
4. Records fetch timestamp in history table

Video type classification:

- **short**: Videos ≤60 seconds or with `/shorts/` in URL
- **video**: All other videos

## Blog Post Linking

The `link-blog-posts.go` program automatically finds and links YouTube videos to their
corresponding blog posts on <https://www.chicks.net>:

```bash
# Run in dry-run mode to see what would be updated
just link-youtube-blog-posts

# Actually update the database
just link-youtube-blog-posts ""
```

How it works:

1. Clones/updates the <https://github.com/chicks-net/www-chicks-net> repository to `/tmp`
2. Searches all blog posts for YouTube video IDs in the content
3. Matches videos to blog posts by detecting YouTube URLs (watch, shorts, youtu.be)
4. Converts blog post filenames to proper URLs (e.g., `2024-07-22-first-youtube-short.md` → `https://www.chicks.net/2024/07/22/first-youtube-short/`)
5. Updates the `blog_url` field in the database
6. Lists all unmatched videos with their dates, titles, and YouTube URLs

The program is fast and efficient, processing hundreds of blog posts in seconds by working
with a local git clone rather than making individual API requests.

Example output:
```
✓ Found match for 'Baby shark at bakery'
  Video ID: Vyn-ayBwmrw
  Blog post: 2024-07-22-first-youtube-short.md
  URL: https://www.chicks.net/2024/07/22/first-youtube-short/

==================================================
Summary: Matched 7 out of 17 videos

==================================================
Videos without blog posts (10):

2025-12-30  Goat Cabinet Shop                     https://www.youtube.com/watch?v=MCl1Jf_WoyQ
2025-12-08  Gary with a Fez On!                   https://www.youtube.com/watch?v=2I_tEb-y5aQ
...
```

## Updates

Re-run `just fetch-youtube-videos` to update the database with latest metrics
(view counts, like counts, etc.) and any new videos.

The script uses `INSERT OR REPLACE` so existing videos will be updated with
current data.

## Files

- `fetch-videos.py` - Main script to fetch and store video metadata
- `link-blog-posts.go` - Go program to link videos to blog posts
- `videos.db` - SQLite database (created after first run)
- `go.mod`, `go.sum` - Go module dependencies
- `README.md` - This file

## Notes

- No YouTube API key required (uses yt-dlp scraping)
- Respects YouTube's rate limits through yt-dlp
- Fetching all videos may take several minutes depending on channel size
- Timestamps are in UTC
- Tags and categories stored as JSON arrays for easier querying
