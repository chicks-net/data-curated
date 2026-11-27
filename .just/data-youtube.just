# youtube data recipes

# Fetch YouTube video metadata and create/update database
[working-directory("individuals/chicks/youtube")]
[group('youtube')]
fetch-youtube-videos:
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if yt-dlp is installed using helper
    INSTALL_CMD=$(just _get_install_cmd yt-dlp python3-yt-dlp)
    just _require_command yt-dlp "Install with:\n  $INSTALL_CMD"

    # Check if uv is installed using helper
    just _require_command uv "Install with:\n  curl -LsSf https://astral.sh/uv/install.sh | sh"

    echo "{{GREEN}}Fetching YouTube videos...{{NORMAL}}"
    uv run fetch-videos.py

    just link-youtube-blog-posts ""

# Download YouTube playlist metadata as a JSON file (flat playlist, no videos downloaded)
# Accepts a full playlist URL or a bare playlist ID:
#   just download-youtube-playlist 'https://youtube.com/playlist?list=PLj1L6ffGFWPsNl__2w5oIW8NBAPWGV6tV' cover_songs.json
#   just download-youtube-playlist PLj1L6ffGFWPsNl__2w5oIW8NBAPWGV6tV cover_songs.json
[working-directory("individuals/chicks/youtube")]
[group('youtube')]
download-youtube-playlist PLAYLIST OUTPUT:
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if yt-dlp is installed using helper
    INSTALL_CMD=$(just _get_install_cmd yt-dlp python3-yt-dlp)
    just _require_command yt-dlp "Install with:\n  $INSTALL_CMD"

    # Check if jq is installed (pretty-prints the JSON so diffs are readable)
    INSTALL_CMD=$(just _get_install_cmd jq jq)
    just _require_command jq "Install with:\n  $INSTALL_CMD"

    URL="{{PLAYLIST}}"
    OUTPUT="{{OUTPUT}}"

    # Accept either a full playlist URL or a bare playlist ID
    if [[ "$URL" != http* ]]; then
        URL="https://youtube.com/playlist?list=$URL"
    fi

    echo "{{GREEN}}Downloading playlist metadata from $URL to $OUTPUT...{{NORMAL}}"

    # Download to a temp file first so a failed fetch doesn't clobber the
    # output. jq pretty-prints the single-line yt-dlp JSON (content is
    # unchanged) so future diffs are readable in review.
    TMP_FILE="$OUTPUT.tmp"
    trap 'rm -f "$TMP_FILE"' EXIT
    yt-dlp --flat-playlist --dump-single-json "$URL" | jq . > "$TMP_FILE"
    mv "$TMP_FILE" "$OUTPUT"

    echo "{{GREEN}}✓ Playlist metadata saved to $OUTPUT{{NORMAL}}"

# Recreate all the playlist metadata JSON files at once
[working-directory("individuals/chicks/youtube")]
[group('youtube')]
download-youtube-playlists:
    just download-youtube-playlist PLj1L6ffGFWPsNl__2w5oIW8NBAPWGV6tV cover_songs.json
    just download-youtube-playlist PL2B065C08C418EC58 fun_songs.json
    just download-youtube-playlist PLj1L6ffGFWPt054TO8HQsOrPo1Lbc6KFr learning_spanish_songs.json
    just download-youtube-playlist PLj1L6ffGFWPvX5qs5s_U8EnxdZPsp_9A5 music_videos_by_chicks.json

# Extract audio from a YouTube playlist into audio files (default: mp3)
# Accepts a full playlist URL or a bare playlist ID:
#   just extract-youtube-audio 'https://youtube.com/playlist?list=PLj1L6ffGFWPsNl__2w5oIW8NBAPWGV6tV'
#   just extract-youtube-audio PLj1L6ffGFWPsNl__2w5oIW8NBAPWGV6tV ~/Downloads/tonie-mix
# OUTPUT_DIR is relative to individuals/chicks/youtube (absolute paths work
# too; defaults to audio/, which is gitignored). FORMAT: mp3 re-encodes for
# maximum compatibility; m4a skips re-encoding when the source is AAC. Both
# upload fine to a Creative-Tonie at my.tonies.com.
[working-directory("individuals/chicks/youtube")]
[group('youtube')]
extract-youtube-audio PLAYLIST OUTPUT_DIR="audio" FORMAT="mp3":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if yt-dlp is installed using helper
    INSTALL_CMD=$(just _get_install_cmd yt-dlp python3-yt-dlp)
    just _require_command yt-dlp "Install with:\n  $INSTALL_CMD"

    # Check if ffmpeg is installed (required for audio extraction/conversion)
    INSTALL_CMD=$(just _get_install_cmd ffmpeg ffmpeg)
    just _require_command ffmpeg "Install with:\n  $INSTALL_CMD"

    # Check if jq is installed (sums playlist durations for the info pass)
    INSTALL_CMD=$(just _get_install_cmd jq jq)
    just _require_command jq "Install with:\n  $INSTALL_CMD"

    URL="{{PLAYLIST}}"
    OUTPUT_DIR="{{OUTPUT_DIR}}"
    FORMAT="{{FORMAT}}"

    # Accept either a full playlist URL or a bare playlist ID
    if [[ "$URL" != http* ]]; then
        URL="https://youtube.com/playlist?list=$URL"
    fi

    # Info pass: report total playlist duration before downloading. A
    # Creative-Tonie holds 90 minutes, so warn when the playlist runs
    # longer than that (informational only - the download proceeds).
    TOTAL_SECONDS=$(yt-dlp --flat-playlist --dump-single-json "$URL" \
        | jq '[.entries[].duration // 0] | add // 0' \
        | cut -d. -f1) || TOTAL_SECONDS=""

    if [[ "$TOTAL_SECONDS" =~ ^[0-9]+$ ]]; then
        echo "{{BLUE}}Playlist duration:{{NORMAL}} $(( TOTAL_SECONDS / 60 )) minutes"
        if (( TOTAL_SECONDS > 5400 )); then
            echo "{{YELLOW}}Warning: over 90 minutes - a Creative-Tonie only holds 90.{{NORMAL}}"
        fi
    fi

    mkdir -p "$OUTPUT_DIR"
    echo "{{GREEN}}Extracting audio to $OUTPUT_DIR (format: $FORMAT)...{{NORMAL}}"

    # The %(playlist_index)02d prefix keeps playlist order in Finder (and
    # therefore track order on a Creative-Tonie). --embed-metadata gives
    # clean titles in the mytonies app. --ignore-errors so one dead video
    # doesn't kill the batch, --no-overwrites so re-runs skip finished
    # tracks instead of re-downloading the whole playlist.
    yt-dlp -x \
        --audio-format "$FORMAT" \
        --audio-quality 0 \
        --embed-metadata \
        --embed-thumbnail \
        --ignore-errors \
        --no-overwrites \
        -o "$OUTPUT_DIR/%(playlist_index)02d - %(title)s.%(ext)s" \
        "$URL"

    FILE_COUNT=$(find "$OUTPUT_DIR" -type f | wc -l | tr -d ' ')
    echo "{{GREEN}}✓ $FILE_COUNT audio files in $OUTPUT_DIR{{NORMAL}}"

# Calculate the total play time of a YouTube playlist (metadata only -
# nothing is downloaded). Accepts a full playlist URL, a bare playlist ID,
# or a saved playlist metadata JSON file (paths relative to
# individuals/chicks/youtube):
#   just playlist-length 'https://youtube.com/playlist?list=PLj1L6ffGFWPsNl__2w5oIW8NBAPWGV6tV'
#   just playlist-length PLj1L6ffGFWPsNl__2w5oIW8NBAPWGV6tV
#   just playlist-length cover_songs.json
# Also notes whether the total fits a 90-minute Creative-Tonie.
[working-directory("individuals/chicks/youtube")]
[group('youtube')]
playlist-length PLAYLIST:
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if yt-dlp is installed using helper
    INSTALL_CMD=$(just _get_install_cmd yt-dlp python3-yt-dlp)
    just _require_command yt-dlp "Install with:\n  $INSTALL_CMD"

    # Check if jq is installed using helper
    INSTALL_CMD=$(just _get_install_cmd jq jq)
    just _require_command jq "Install with:\n  $INSTALL_CMD"

    SOURCE="{{PLAYLIST}}"

    # Read metadata into a temp file, either from a saved JSON file or
    # live from YouTube (accepting a full URL or a bare playlist ID)
    TMP_JSON=$(mktemp)
    trap 'rm -f "$TMP_JSON"' EXIT
    if [[ -f "$SOURCE" ]]; then
        echo "{{GREEN}}Reading saved playlist metadata from $SOURCE...{{NORMAL}}"
        cp "$SOURCE" "$TMP_JSON"
    else
        URL="$SOURCE"
        if [[ "$URL" != http* ]]; then
            URL="https://youtube.com/playlist?list=$URL"
        fi
        echo "{{GREEN}}Fetching playlist metadata from $URL...{{NORMAL}}"
        yt-dlp --flat-playlist --dump-single-json "$URL" > "$TMP_JSON"
    fi

    TITLE=$(jq -r '.title // "Unknown"' "$TMP_JSON")
    COUNT=$(jq '(.entries // []) | length' "$TMP_JSON")
    MISSING=$(jq '[.entries[]? | select(.duration == null)] | length' "$TMP_JSON")
    SECS=$(jq '[.entries[]?.duration // 0] | add // 0' "$TMP_JSON" | cut -d. -f1)

    if (( SECS >= 3600 )); then
        DURATION="$(( SECS / 3600 ))h $(( (SECS % 3600) / 60 ))m"
    elif (( SECS >= 60 )); then
        DURATION="$(( SECS / 60 ))m $(( SECS % 60 ))s"
    else
        DURATION="${SECS}s"
    fi

    echo ""
    echo "{{BLUE}}Playlist:{{NORMAL}} $TITLE"
    echo "{{BLUE}}Videos:{{NORMAL}}   $COUNT"
    echo "{{BLUE}}Duration:{{NORMAL}} $DURATION ($SECS seconds)"

    if (( MISSING > 0 )); then
        echo "{{YELLOW}}Note:{{NORMAL}} $MISSING video(s) have no duration data and count as 0"
    fi

    # A Creative-Tonie holds 90 minutes - the point of the exercise
    if (( SECS > 5400 )); then
        echo "{{YELLOW}}Warning: over 90 minutes - a Creative-Tonie only holds 90.{{NORMAL}}"
    else
        echo "{{GREEN}}Fits on a Creative-Tonie (90-minute capacity).{{NORMAL}}"
    fi

# View YouTube video database in Datasette
[group('youtube')]
youtube-db:
    just datasette individuals/chicks/youtube/videos.db

# Show YouTube database status
[working-directory("individuals/chicks/youtube")]
[group('youtube')]
youtube-status:
    #!/usr/bin/env bash
    set -euo pipefail

    DB_FILE="videos.db"

    if [ ! -f "$DB_FILE" ]; then
        echo "{{RED}}Error: Database file not found: $DB_FILE{{NORMAL}}"
        echo "Run 'just fetch-youtube-videos' to create it."
        exit 1
    fi

    echo "{{GREEN}}YouTube Video Database Status{{NORMAL}}"
    echo ""

    # Show database file age using helper (the helper runs from the repo
    # root, so it needs a root-relative path)
    just _show_db_age "individuals/chicks/youtube/videos.db"

    # Show last fetch time
    LAST_FETCH=$(sqlite3 "$DB_FILE" "SELECT fetched_at FROM fetch_history ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")

    if [ -n "$LAST_FETCH" ]; then
        echo "{{YELLOW}}Last fetch:{{NORMAL}} $LAST_FETCH"
        echo ""

        # Show video counts
        TOTAL_VIDEOS=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM videos;")
        echo "{{BLUE}}Total videos:{{NORMAL}} $TOTAL_VIDEOS"

        # Show video type breakdown
        echo ""
        echo "{{BLUE}}Video type breakdown:{{NORMAL}}"
        sqlite3 -column "$DB_FILE" "SELECT video_type, COUNT(*) as count FROM videos GROUP BY video_type;"

        # Show most recent videos
        echo ""
        echo "{{BLUE}}Most recent uploads (last 5):{{NORMAL}}"
        sqlite3 -column "$DB_FILE" "SELECT substr(title, 1, 50) as title, upload_date FROM videos ORDER BY upload_date DESC LIMIT 5;"
    else
        echo "{{RED}}No fetch history found{{NORMAL}}"
    fi

# Link YouTube videos to blog posts by searching GitHub repo
[working-directory("individuals/chicks/youtube")]
[group('youtube')]
link-youtube-blog-posts DRY_RUN="--dry-run":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if go is installed using helper
    INSTALL_CMD=$(just _get_install_cmd go golang-go)
    just _require_command go "Install with:\n  $INSTALL_CMD\n  Or see: https://go.dev/doc/install"

    # Check if gh CLI is installed (preferred for API access)
    if ! command -v gh &> /dev/null; then
        INSTALL_CMD=$(just _get_install_cmd gh gh)
        echo "{{YELLOW}}Warning: gh CLI is not installed{{NORMAL}}"
        echo "Using direct API calls (subject to rate limits)"
        echo ""
        echo "For better performance, install gh CLI:"
        echo "  $INSTALL_CMD"
        echo ""
    fi

    # Check if database exists
    if [ ! -f "videos.db" ]; then
        echo "{{RED}}Error: videos.db not found{{NORMAL}}"
        echo "Run 'just fetch-youtube-videos' first."
        exit 1
    fi

    echo "{{GREEN}}Linking YouTube videos to blog posts...{{NORMAL}}"
    # shellcheck disable=SC1083
    go run link-blog-posts.go {{DRY_RUN}}

# Generate blog posts for YouTube videos missing blog posts (6+ months old)
[working-directory("individuals/chicks/youtube")]
[group('youtube')]
generate-blog-posts DRY_RUN="--dry-run":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if go is installed using helper
    INSTALL_CMD=$(just _get_install_cmd go golang-go)
    just _require_command go "Install with:\n  $INSTALL_CMD\n  Or see: https://go.dev/doc/install"

    # Check if database exists
    if [ ! -f "videos.db" ]; then
        echo "{{RED}}Error: videos.db not found{{NORMAL}}"
        echo "Run 'just fetch-youtube-videos' first."
        exit 1
    fi

    # Check if template exists
    if [ ! -f "template.md" ]; then
        echo "{{RED}}Error: template.md not found{{NORMAL}}"
        exit 1
    fi

    echo "{{GREEN}}Generating blog posts for YouTube videos...{{NORMAL}}"
    # shellcheck disable=SC1083
    go run generate-blog-posts.go {{DRY_RUN}}
