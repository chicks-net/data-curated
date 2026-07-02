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

	# Show database file age using helper
	just _show_db_age "$DB_FILE"

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