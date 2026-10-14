# music data recipes

# Fetch song lyrics from LRCLIB for the Spotify Liked Songs playlist
# (or any other Exportify CSV, e.g. just fetch-lyrics Covers.csv)
[working-directory("individuals/chicks/music/spotify")]
[group('music')]
fetch-lyrics CSV="Liked_Songs.csv":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if uv is installed using helper
    just _require_command uv "Install with:\n  curl -LsSf https://astral.sh/uv/install.sh | sh"

    # Check that the CSV exists before starting a long fetch
    if [ ! -f "{{CSV}}" ]; then
        echo "{{RED}}Error: CSV file not found: {{CSV}}{{NORMAL}}"
        echo "Exportify playlists live in this directory."
        exit 1
    fi

    echo "{{GREEN}}Fetching song lyrics from LRCLIB...{{NORMAL}}"
    # shellcheck disable=SC1083
    uv run fetch-lyrics.py --csv "{{CSV}}"

# Detect the spoken language of every track's lyrics using langdetect
# (uv auto-installs langdetect from the script's inline metadata)
[working-directory("individuals/chicks/music/spotify")]
[group('music')]
detect-languages:
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if uv is installed using helper
    just _require_command uv "Install with:\n  curl -LsSf https://astral.sh/uv/install.sh | sh"

    # Check if the database exists
    if [ ! -f "lyrics.db" ]; then
        echo "{{RED}}Error: lyrics.db not found{{NORMAL}}"
        echo "Run 'just fetch-lyrics' first."
        exit 1
    fi

    echo "{{GREEN}}Detecting lyric languages...{{NORMAL}}"
    uv run detect-languages.py

# View song lyrics database in Datasette
[group('music')]
lyrics-db:
    just datasette individuals/chicks/music/spotify/lyrics.db

# Show lyrics database status
[working-directory("individuals/chicks/music/spotify")]
[group('music')]
lyrics-status:
    #!/usr/bin/env bash
    set -euo pipefail

    DB_FILE="lyrics.db"

    if [ ! -f "$DB_FILE" ]; then
        echo "{{RED}}Error: Database file not found: $DB_FILE{{NORMAL}}"
        echo "Run 'just fetch-lyrics' to create it."
        exit 1
    fi

    echo "{{GREEN}}Song Lyrics Database Status{{NORMAL}}"
    echo ""

    # Show database file age using helper (the helper runs from the repo
    # root, so it needs a root-relative path)
    just _show_db_age "individuals/chicks/music/spotify/lyrics.db"

    # Show last fetch time
    LAST_FETCH=$(sqlite3 "$DB_FILE" "SELECT fetched_at FROM fetch_history ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")

    if [ -n "$LAST_FETCH" ]; then
        echo "{{YELLOW}}Last fetch:{{NORMAL}} $LAST_FETCH"
        echo ""

        # Show track counts
        TOTAL_TRACKS=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM tracks;")
        echo "{{BLUE}}Total tracks:{{NORMAL}} $TOTAL_TRACKS"

        # Show lyrics status breakdown
        echo ""
        echo "{{BLUE}}Lyrics status breakdown:{{NORMAL}}"
        sqlite3 -column "$DB_FILE" "SELECT status, COUNT(*) as count FROM lyrics GROUP BY status ORDER BY count DESC;"

        # Show lyrics coverage (found or instrumental)
        echo ""
        echo "{{BLUE}}Lyrics coverage:{{NORMAL}}"
        COVERAGE=$(sqlite3 "$DB_FILE" "SELECT printf('%.1f%%', 100.0 * (SELECT COUNT(*) FROM lyrics WHERE status IN ('found', 'instrumental')) / (SELECT COUNT(*) FROM tracks));")
        echo "  $COVERAGE of tracks have lyrics or are instrumental"

        # Show language detection summary (once detect-languages has run)
        LANG_TABLE=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='track_languages';")
        if [ "$LANG_TABLE" -gt 0 ]; then
            DETECTED=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM track_languages WHERE language IS NOT NULL;")
            LOW_CONF=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM track_languages WHERE confidence='low';")
            echo ""
            echo "{{BLUE}}Language detection:{{NORMAL}}"
            echo "  $DETECTED tracks with a detected language ($LOW_CONF low confidence)"
            echo "  Run 'just language-breakdown' for the full breakdown"
        fi

        # Show most recent fetch runs
        echo ""
        echo "{{BLUE}}Recent fetch runs:{{NORMAL}}"
        sqlite3 -column "$DB_FILE" "SELECT substr(fetched_at, 1, 19) as run, found, not_found, instrumental, error, skipped, ROUND(runtime_seconds) as seconds FROM fetch_history ORDER BY id DESC LIMIT 5;"
    else
        echo "{{RED}}No fetch history found{{NORMAL}}"
    fi

# Print the language breakdown and write language-breakdown.csv
[working-directory("individuals/chicks/music/spotify")]
[group('music')]
language-breakdown:
    #!/usr/bin/env bash
    set -euo pipefail

    DB_FILE="lyrics.db"

    if [ ! -f "$DB_FILE" ]; then
        echo "{{RED}}Error: Database file not found: $DB_FILE{{NORMAL}}"
        echo "Run 'just fetch-lyrics' to create it."
        exit 1
    fi

    LANG_TABLE=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='track_languages';")
    if [ "$LANG_TABLE" -eq 0 ]; then
        echo "{{RED}}Error: language detection has not run yet{{NORMAL}}"
        echo "Run 'just detect-languages' first."
        exit 1
    fi

    # One query, two renderings: CSV for the committed report, pretty
    # table for the terminal. Languages come from track_languages;
    # instrumentals, misses and undetectable lyrics get their own
    # buckets so instrumentals never count as unknown language.
    BREAKDOWN_SQL="SELECT
    CASE
        WHEN tl.track_id IS NOT NULL AND tl.language IS NOT NULL THEN tl.language
        WHEN tl.track_id IS NOT NULL THEN 'undetectable'
        WHEN l.status = 'instrumental' THEN 'instrumental'
        WHEN l.status = 'not_found' THEN 'unknown'
        ELSE 'pending'
    END AS language,
    SUM(CASE WHEN tl.language IS NOT NULL AND tl.confidence = 'low' THEN 1 ELSE 0 END) AS low_confidence,
    COUNT(*) AS count,
    printf('%.1f%%', 100.0 * COUNT(*) / (SELECT COUNT(*) FROM tracks)) AS share
    FROM tracks t
    JOIN lyrics l USING(track_id)
    LEFT JOIN track_languages tl USING(track_id)
    GROUP BY 1
    ORDER BY count DESC;"

    echo "{{GREEN}}Language Breakdown{{NORMAL}}"
    echo ""

    sqlite3 -header -csv "$DB_FILE" "$BREAKDOWN_SQL" > language-breakdown.csv
    sqlite3 -header -column "$DB_FILE" "$BREAKDOWN_SQL"

    echo ""
    echo "{{GREEN}}✓ Breakdown written to language-breakdown.csv{{NORMAL}}"
