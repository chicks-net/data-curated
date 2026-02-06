# project justfile

import? '.just/shellcheck.just'
import? '.just/compliance.just'
import? '.just/gh-process.just'

# list recipes (default works without naming it)
[group('example')]
list:
	just --list

jackpot_database := "jackpots.db"

# Install prerequisites for lottery tools (Go, wget, sqlite3)
[group('lottery')]
install-lottery-deps:
	#!/usr/bin/env bash
	set -euo pipefail

	echo "Checking lottery tool prerequisites..."
	echo ""

	MISSING=()

	# Check for Go
	if ! command -v go &> /dev/null; then
		echo "❌ Go not found"
		MISSING+=("go")
	else
		echo "✓ Go $(go version | awk '{print $3}')"
	fi

	# Check for wget
	if ! command -v wget &> /dev/null; then
		echo "❌ wget not found"
		MISSING+=("wget")
	else
		echo "✓ wget $(wget --version | head -n1 | awk '{print $3}')"
	fi

	# Check for sqlite3
	if ! command -v sqlite3 &> /dev/null; then
		echo "❌ sqlite3 not found"
		MISSING+=("sqlite3")
	else
		echo "✓ sqlite3 $(sqlite3 --version | awk '{print $1}')"
	fi

	# If nothing missing, we're done
	if [ ${#MISSING[@]} -eq 0 ]; then
		echo ""
		echo "✅ All prerequisites installed!"
		exit 0
	fi

	# Install missing prerequisites
	echo ""
	echo "Installing missing prerequisites: ${MISSING[*]}"
	echo ""

	# Detect platform and install
	if [[ "$OSTYPE" == "darwin"* ]]; then
		# macOS - use Homebrew
		if ! command -v brew &> /dev/null; then
			echo "Error: Homebrew not found. Please install Homebrew first:"
			echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
			exit 1
		fi
		brew install "${MISSING[@]}"
	elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
		# Linux - try to detect package manager
		if command -v apt-get &> /dev/null; then
			# Map package names for apt-based systems
			APT_PACKAGES=()
			for pkg in "${MISSING[@]}"; do
				case "$pkg" in
					go)
						APT_PACKAGES+=("golang-go")
						;;
					*)
						APT_PACKAGES+=("$pkg")
						;;
				esac
			done
			sudo apt-get update && sudo apt-get install -y "${APT_PACKAGES[@]}"
		elif command -v yum &> /dev/null; then
			# Map package names for yum-based systems
			YUM_PACKAGES=()
			for pkg in "${MISSING[@]}"; do
				case "$pkg" in
					go)
						YUM_PACKAGES+=("golang")
						;;
					*)
						YUM_PACKAGES+=("$pkg")
						;;
				esac
			done
			sudo yum install -y "${YUM_PACKAGES[@]}"
		elif command -v dnf &> /dev/null; then
			# Map package names for dnf-based systems
			DNF_PACKAGES=()
			for pkg in "${MISSING[@]}"; do
				case "$pkg" in
					go)
						DNF_PACKAGES+=("golang")
						;;
					*)
						DNF_PACKAGES+=("$pkg")
						;;
				esac
			done
			sudo dnf install -y "${DNF_PACKAGES[@]}"
		else
			echo "Error: Could not detect package manager (apt, yum, or dnf)"
			echo "Please install manually: ${MISSING[*]}"
			exit 1
		fi
	else
		echo "Error: Unsupported platform: $OSTYPE"
		echo "Please install manually: ${MISSING[*]}"
		exit 1
	fi

	echo ""
	echo "✅ Prerequisites installed successfully!"

# Hidden recipe to verify lottery prerequisites are installed
_check_lottery_deps:
	#!/usr/bin/env bash
	set -euo pipefail
	MISSING=()
	if ! command -v go &> /dev/null; then
		MISSING+=("go")
	fi
	if ! command -v wget &> /dev/null; then
		MISSING+=("wget")
	fi
	if ! command -v sqlite3 &> /dev/null; then
		MISSING+=("sqlite3")
	fi
	if [ ${#MISSING[@]} -gt 0 ]; then
		echo "Error: Missing required tools: ${MISSING[*]}"
		echo "Run 'just install-lottery-deps' to install them."
		exit 1
	fi

# Check California lottery jackpots and show recent results
[working-directory("lottery")]
[group('lottery')]
check-jackpots: _check_lottery_deps
	#!/usr/bin/env bash
	set -euo pipefail # strict mode

	echo "Checking California Lottery jackpots..."
	echo ""
	go run jackpot-checker.go

	echo ""
	echo "Recent jackpot checks:"
	sqlite3 "{{ jackpot_database }}" "SELECT \
	  game, \
	  printf('Draw #%d', draw_number) as draw, \
	  draw_date, \
	  printf('\$%,d M', jackpot/1000000) as jackpot, \
	  printf('\$%.1f M', CAST(estimated_cash AS REAL)/1000000) as cash, \
	  datetime(checked_at) as checked \
	FROM jackpots \
	ORDER BY checked_at DESC \
	LIMIT 10;"

# Show the age of the jackpots database and when data was last updated
[working-directory("lottery")]
[group('lottery')]
jackpot-status: _check_lottery_deps
	#!/usr/bin/env bash
	set -euo pipefail # strict mode

	DB_FILE="{{ jackpot_database }}"

	if [ ! -f "$DB_FILE" ]; then
		echo "{{RED}}Error: Database file not found: $DB_FILE{{NORMAL}}"
		echo "Run 'just check-jackpots' to create it."
		exit 1
	fi

	echo "{{GREEN}}Jackpot Database Status{{NORMAL}} ($DB_FILE)"
	echo ""

	# Show database file age
	if [[ "$OSTYPE" == "darwin"* ]]; then
		# macOS stat format
		FILE_AGE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$DB_FILE")
		echo "{{YELLOW}}Database file modified:{{NORMAL}} $FILE_AGE"
	else
		# Linux stat format
		FILE_AGE=$(stat -c "%y" "$DB_FILE" | cut -d'.' -f1)
		echo "{{YELLOW}}Database file modified:{{NORMAL}} $FILE_AGE"
	fi

	# Show last database entry
	LAST_ENTRY=$(sqlite3 "$DB_FILE" "SELECT datetime(checked_at) FROM jackpots ORDER BY checked_at DESC LIMIT 1;")

	if [ -n "$LAST_ENTRY" ]; then
		echo "{{YELLOW}}Last jackpot check:{{NORMAL}} $LAST_ENTRY"
		echo ""

		# Calculate how long ago
		LAST_TIMESTAMP=$(sqlite3 "$DB_FILE" "SELECT strftime('%s', checked_at) FROM jackpots ORDER BY checked_at DESC LIMIT 1;")
		NOW=$(date +%s)
		DIFF=$((NOW - LAST_TIMESTAMP))

		DAYS=$((DIFF / 86400))
		HOURS=$(((DIFF % 86400) / 3600))
		MINUTES=$(((DIFF % 3600) / 60))

		if [ $DAYS -gt 0 ]; then
			echo "{{BLUE}}Time since last check:{{NORMAL}} $DAYS days, $HOURS hours, $MINUTES minutes ago"
		elif [ $HOURS -gt 0 ]; then
			echo "{{BLUE}}Time since last check:{{NORMAL}} $HOURS hours, $MINUTES minutes ago"
		else
			echo "{{BLUE}}Time since last check:{{NORMAL}} $MINUTES minutes ago"
		fi

		# Show total entries
		TOTAL_ENTRIES=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM jackpots;")
		echo "{{BLUE}}Total entries:{{NORMAL}} $TOTAL_ENTRIES"
	else
		echo "{{RED}}No entries found in database{{NORMAL}}"
	fi

# Download New York lottery winning numbers (Powerball and Mega Millions)
[working-directory("lottery")]
[group('lottery')]
download-lottery-numbers: _check_lottery_deps
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	wget "https://data.ny.gov/api/views/d6yy-54nr/rows.csv?accessType=DOWNLOAD" -O Lottery_Powerball_Winning_Numbers__Beginning_2010.csv
	wget "https://data.ny.gov/api/views/5xaw-6ayf/rows.csv?accessType=DOWNLOAD" -O Lottery_Mega_Millions_Winning_Numbers__Beginning_2002.csv

# Analyze Mega Millions number frequency
[working-directory("lottery/megamillions-analysis")]
[group('lottery')]
analyze-megamillions:
	Rscript analyze-megamillions.R

# Analyze Mega Millions number frequency (Perl version)
[working-directory("lottery/megamillions-analysis")]
[group('lottery')]
analyze-megamillions-pl:
	./analyze-megamillions.pl

# Analyze Powerball number frequency
[working-directory("lottery/powerball-analysis")]
[group('lottery')]
analyze-powerball:
	Rscript analyze-powerball.R

# Analyze California lottery jackpot trends
[working-directory("lottery/jackpots-analysis")]
[group('lottery')]
analyze-jackpots:
	Rscript analyze-jackpots.R

# Install all R packages used in this repository
[group('Utility')]
install-r-deps:
	#!/usr/bin/env bash
	set -euo pipefail

	echo "{{GREEN}}Installing R packages used in this repository{{NORMAL}}"
	echo ""

	# List of all R packages used across analysis scripts
	PACKAGES=(
		"tidyverse"  # Used by lottery analysis scripts (includes ggplot2, dplyr, tidyr, readr)
		"DBI"        # Database interface for jackpots and contributions analysis
		"RSQLite"    # SQLite database driver
		"zoo"        # Rolling averages in contributions analysis
		"lubridate"  # Date handling in jackpots and contributions analysis
		"scales"     # Number formatting in plots
		"censusapi"  # Census Bureau API access for restaurant analysis
	)

	echo "{{BLUE}}Packages to check/install:{{NORMAL}}"
	for pkg in "${PACKAGES[@]}"; do
		echo "  - $pkg"
	done
	echo ""

	# Install each package
	for pkg in "${PACKAGES[@]}"; do
		just install-r-package "$pkg"
		echo ""
	done

	echo "{{GREEN}}✓ All R dependencies installed!{{NORMAL}}"

# Install a single R package (e.g., zoo, ggplot2, dplyr)
[group('Utility')]
install-r-package PACKAGE:
	#!/usr/bin/env bash
	set -euo pipefail

	# Check if R is installed
	if ! command -v R &> /dev/null; then
		echo "{{RED}}Error: R is not installed{{NORMAL}}"
		echo ""
		echo "Install R:"
		if [[ "$OSTYPE" == "darwin"* ]]; then
			echo "  brew install r"
		elif command -v apt-get &> /dev/null; then
			echo "  sudo apt-get install r-base"
		elif command -v yum &> /dev/null; then
			echo "  sudo yum install R"
		elif command -v dnf &> /dev/null; then
			echo "  sudo dnf install R"
		fi
		exit 1
	fi

	echo "{{GREEN}}Checking R package: {{PACKAGE}}{{NORMAL}}"
	echo ""

	# Check if package is already installed and get version
	INSTALLED_VERSION=$(R --quiet --no-save -e "if ('{{PACKAGE}}' %in% installed.packages()[,'Package']) { cat(as.character(packageVersion('{{PACKAGE}}'))) } else { cat('NOT_INSTALLED') }" 2>/dev/null | tail -1)

	if [ "$INSTALLED_VERSION" != "NOT_INSTALLED" ]; then
		echo "{{YELLOW}}Package {{PACKAGE}} is already installed (version $INSTALLED_VERSION){{NORMAL}}"
		echo ""

		# Check for updates
		echo "{{BLUE}}Checking for updates...{{NORMAL}}"
		UPDATE_INFO=$(R --quiet --no-save -e "
		old <- old.packages(repos='https://cloud.r-project.org')
		if ('{{PACKAGE}}' %in% rownames(old)) {
		  cat('UPDATE_AVAILABLE:', old['{{PACKAGE}}', 'ReposVer'])
		} else {
		  cat('CURRENT')
		}" 2>/dev/null | tail -1)

		if [[ "$UPDATE_INFO" == UPDATE_AVAILABLE:* ]]; then
			NEW_VERSION="${UPDATE_INFO#UPDATE_AVAILABLE: }"
			echo "{{GREEN}}Update available: $INSTALLED_VERSION → $NEW_VERSION{{NORMAL}}"
			echo ""
			echo "{{BLUE}}Updating package...{{NORMAL}}"
			R --quiet --no-save -e "install.packages('{{PACKAGE}}', repos='https://cloud.r-project.org')"
			echo ""
			echo "{{GREEN}}✓ Package {{PACKAGE}} updated to $NEW_VERSION{{NORMAL}}"
		else
			echo "{{GREEN}}✓ Package {{PACKAGE}} is up to date{{NORMAL}}"
		fi
	else
		echo "{{BLUE}}Installing R package: {{PACKAGE}}{{NORMAL}}"
		echo ""

		# Install the package
		R --quiet --no-save -e "install.packages('{{PACKAGE}}', repos='https://cloud.r-project.org')"

		# Get the installed version
		NEW_VERSION=$(R --quiet --no-save -e "cat(as.character(packageVersion('{{PACKAGE}}')))" 2>/dev/null | tail -1)
		echo ""
		echo "{{GREEN}}✓ Package {{PACKAGE}} installed successfully (version $NEW_VERSION){{NORMAL}}"
	fi

# Count blog posts per month from chicks.net
[working-directory("individuals/chicks/blog")]
[group('blog')]
count-posts:
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	echo "{{GREEN}}Counting blog posts from https://www.chicks.net/posts/{{NORMAL}} ..."
	echo ""
	go run post-counter.go
	echo ""
	CSV_FILE=$(find . -maxdepth 1 -name 'blog-monthly-*.csv' -type f -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2- | sed 's|^\./||')
	if [ -n "$CSV_FILE" ] && [ -f "$CSV_FILE" ]; then
		echo "📊 CSV output: {{BLUE}}$CSV_FILE{{NORMAL}}"
		echo "Total rows: {{BLUE}}$(tail -n +2 "$CSV_FILE" | wc -l | tr -d ' '){{NORMAL}}"
	fi

# Generate graph from blog post CSV data
[working-directory("individuals/chicks/blog")]
[group('blog')]
graph-posts CSV="":
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	CSV_FILE="{{CSV}}"
	# If no CSV specified, find the most recent one
	if [ -z "$CSV_FILE" ]; then
		# Find most recent CSV file using portable bash approach
		for f in blog-monthly-*.csv; do
			[ -e "$f" ] || continue
			if [ -z "$CSV_FILE" ] || [ "$f" -nt "$CSV_FILE" ]; then
				CSV_FILE="$f"
			fi
		done
		if [ -z "$CSV_FILE" ]; then
			echo "Error: No CSV file found. Run 'just count-posts' first."
			exit 1
		fi
		echo "{{GREEN}}Generating graph from $CSV_FILE{{NORMAL}}"
	else
		if [ ! -f "$CSV_FILE" ]; then
			echo "Error: File not found: $CSV_FILE"
			exit 1
		fi
		echo "{{GREEN}}Generating graph from $CSV_FILE{{NORMAL}}"
	fi
	echo ""
	Rscript graph-generator.R "$CSV_FILE"

# Generate graph for the last 36 months of blog posts
[working-directory("individuals/chicks/blog")]
[group('blog')]
graph-posts-36:
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	# Find most recent CSV file using portable bash approach
	CSV_FILE=""
	for f in blog-monthly-*.csv; do
		[ -e "$f" ] || continue
		if [ -z "$CSV_FILE" ] || [ "$f" -nt "$CSV_FILE" ]; then
			CSV_FILE="$f"
		fi
	done
	if [ -z "$CSV_FILE" ]; then
		echo "Error: No CSV file found. Run 'just count-posts' first."
		exit 1
	fi
	echo "{{GREEN}}Generating graph for last 36 months from $CSV_FILE{{NORMAL}}"
	echo ""
	Rscript graph-generator.R "$CSV_FILE" 36

# Open a SQLite database in Datasette browser (checks if datasette is already running)
[group('Utility')]
datasette DB:
	#!/usr/bin/env bash
	set -euo pipefail # strict mode

	# Check if datasette is already running on port 8001
	if lsof -i :8001 > /dev/null 2>&1; then
		echo "{{RED}}Error: Datasette is already running on port 8001!{{NORMAL}}"
		echo ""
		# Get PID and command line from lsof output
		lsof -i :8001 | tail -n +2 | while read -r line; do
			pid=$(echo "$line" | awk '{print $2}')
			echo "{{YELLOW}}PID:{{NORMAL}} $pid"
			echo "{{YELLOW}}Command:{{NORMAL}} $(ps -p "$pid" -o command= 2>/dev/null || echo 'Unable to retrieve command')"
			echo ""
		done
		exit 1
	fi

	# Check if database file exists
	if [ ! -f "{{DB}}" ]; then
		echo "{{RED}}Error: Database file not found: {{DB}}{{NORMAL}}"
		exit 1
	fi

	# Check if datasette is installed
	if ! command -v datasette &> /dev/null; then
		echo "{{RED}}Error: datasette command not found{{NORMAL}}"
		echo "Install with: pip install datasette"
		exit 1
	fi

	echo "{{GREEN}}Opening {{DB}} in Datasette...{{NORMAL}}"
	datasette "{{DB}}" -o

# Download US Census Bureau data for a state
[working-directory("us-cities")]
[group('us-cities')]
download-census-data STATE:
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	./scripts/download-census-data.sh "{{STATE}}"

# Import downloaded Census data into SQLite database
[working-directory("us-cities")]
[group('us-cities')]
import-census-data *STATES:
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	if [ $# -eq 0 ]; then
		echo "Error: No states specified"
		echo "Usage: just import-census-data STATE [STATE ...]"
		echo "Example: just import-census-data CA VA"
		exit 1
	fi
	python3 scripts/import-to-sqlite.py "$@"

# Download and import Census data for one or more states
[working-directory("us-cities")]
[group('us-cities')]
setup-state *STATES:
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	if [ $# -eq 0 ]; then
		echo "Error: No states specified"
		echo "Usage: just setup-state STATE [STATE ...]"
		echo "Example: just setup-state CA VA NY"
		exit 1
	fi

	echo "{{GREEN}}Setting up Census data for states: $*{{NORMAL}}"
	echo ""

	# Download data for each state
	for state in "$@"; do
		echo "{{BLUE}}Downloading data for $state...{{NORMAL}}"
		./scripts/download-census-data.sh "$state"
		echo ""
	done

	# Import all states at once
	echo "{{BLUE}}Importing data into SQLite...{{NORMAL}}"
	python3 scripts/import-to-sqlite.py "$@"

# Open the US cities database in Datasette
[group('us-cities')]
cities-db:
	just datasette us-cities/cities.db

# Fetch GitHub commit history for chicks-net
[working-directory("individuals/chicks/github")]
[group('github')]
fetch-commits:
	#!/usr/bin/env bash
	set -euo pipefail
	echo "Fetching GitHub commit history..."
	go run commit-history.go

[working-directory("individuals/chicks/github/commits-analysis")]
[group('github')]
analyze-commits:
	Rscript analyze-commits-by-hour.R

# Fetch GitHub contribution history for chicks-net
[working-directory("individuals/chicks/github")]
[group('github')]
fetch-contributions:
	#!/usr/bin/env bash
	set -euo pipefail
	echo "Fetching GitHub contribution history..."
	go run github-contributions.go

# Show contribution statistics
[working-directory("individuals/chicks/github")]
[group('github')]
_contribution-stats:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f contributions.db ]; then
		echo "Error: contributions.db not found. Run 'just fetch-contributions' first."
		exit 1
	fi
	sqlite3 contributions.db "SELECT
	  COUNT(DISTINCT date) as total_days,
	  SUM(contribution_count) as total_contributions,
	  MAX(contribution_count) as max_day,
	  ROUND(AVG(contribution_count), 2) as avg_per_day,
	  MIN(date) as earliest_date,
	  MAX(date) as latest_date
	FROM contributions;"

# Show monthly contribution totals
[working-directory("individuals/chicks/github")]
[group('github')]
contribution-monthly MONTHS="24":
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f contributions.db ]; then
		echo "Error: contributions.db not found. Run 'just fetch-contributions' first."
		exit 1
	fi
	echo "Monthly Contribution Summary (last {{MONTHS}} months)"
	echo ""
	sqlite3 -header -column contributions.db "WITH latest_contributions AS (
	  SELECT 
	    date,
	    MAX(contribution_count) as contribution_count
	  FROM contributions
	  GROUP BY date
	),
	monthly_stats AS (
	  SELECT
	    strftime('%Y-%m', date) as month,
	    SUM(contribution_count) as total,
	    ROUND(AVG(contribution_count), 1) as daily_avg,
	    MAX(contribution_count) as peak_day,
	    COUNT(DISTINCT CASE WHEN contribution_count > 0 THEN date END) as active_days,
	    -- Only count inactive days up to today for current month
	    COUNT(DISTINCT CASE 
	      WHEN contribution_count = 0 AND date < date('now')
	      THEN date 
	    END) as inactive_days
	  FROM latest_contributions
	  GROUP BY month
	)
	SELECT
	  month,
	  total,
	  daily_avg,
	  peak_day,
	  active_days,
	  -- For current month, calculate total days as active_days + inactive_days
	  -- For past months, use fixed day counts
	  CASE 
	    WHEN month = strftime('%Y-%m', 'now') 
	    THEN active_days + COALESCE(inactive_days, 0)
	    ELSE (
	      CASE 
	        WHEN month = strftime('%Y-%m', date('now', 'start of month', '-1 month'))
	        THEN strftime('%d', date('now', 'start of month', '-1 day'))
	        ELSE strftime('%d', date(month || '-01', 'start of month', '+1 month', '-1 day'))
	      END
	    )
	  END as total_days,
	  inactive_days
	FROM monthly_stats
	ORDER BY month DESC
	LIMIT {{MONTHS}};"

# Show longest contribution streaks
[working-directory("individuals/chicks/github")]
[group('github')]
contribution-streaks LIMIT="10":
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f contributions.db ]; then
		echo "Error: contributions.db not found. Run 'just fetch-contributions' first."
		exit 1
	fi
	echo "Longest Contribution Streaks (top {{LIMIT}})"
	echo ""
	sqlite3 -header -column contributions.db "WITH distinct_days AS (
	  SELECT DISTINCT date
	  FROM contributions
	  WHERE contribution_count > 0
	  ORDER BY date
	),
	gaps AS (
	  SELECT
	    date,
	    LAG(date) OVER (ORDER BY date) as prev_date,
	    CASE
	      WHEN julianday(date) - julianday(LAG(date) OVER (ORDER BY date)) = 1 THEN 0
	      ELSE 1
	    END as is_new_streak
	  FROM distinct_days
	),
	streak_groups AS (
	  SELECT
	    date,
	    SUM(is_new_streak) OVER (ORDER BY date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as streak_id
	  FROM gaps
	)
	SELECT
	  MIN(date) as streak_start,
	  MAX(date) as streak_end,
	  COUNT(*) as days
	FROM streak_groups
	GROUP BY streak_id
	HAVING COUNT(*) > 1
	ORDER BY days DESC
	LIMIT {{LIMIT}};"

# View commits in Datasette
[group('github')]
commits-db:
	just datasette individuals/chicks/github/commits.db

# View contributions in Datasette
[group('github')]
contributions-db:
	just datasette individuals/chicks/github/contributions.db

# Analyze GitHub contribution trends with visualizations
[working-directory("individuals/chicks/github/contributions-analysis")]
[group('github')]
analyze-contributions:
	Rscript analyze-contributions.R

# Fetch GitHub comments on external projects
[working-directory("individuals/chicks/github")]
[group('github')]
fetch-comments:
	go run comment-fetcher.go

# Show comment statistics
[working-directory("individuals/chicks/github")]
[group('github')]
_comment-stats:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f comments.db ]; then
		echo "Error: comments.db not found. Run 'just fetch-comments' first."
		exit 1
	fi
	echo "Comment statistics (external projects only):"
	echo ""
	sqlite3 comments.db "SELECT
	  comment_type,
	  COUNT(*) as total_comments,
	  COUNT(DISTINCT repo_full_name) as repos,
	  MIN(created_at) as earliest,
	  MAX(created_at) as latest
	FROM comments
	WHERE is_own_org = 0
	GROUP BY comment_type
	ORDER BY comment_type;"

# View comments in Datasette
[group('github')]
comments-db:
	just datasette individuals/chicks/github/comments.db

# Analyze US restaurant density by county
[working-directory("us-restaurants")]
[group('restaurants')]
analyze-restaurants:
	Rscript analyze-restaurants.R

# Fetch YouTube video metadata and create/update database
[working-directory("individuals/chicks/youtube")]
[group('youtube')]
fetch-youtube-videos:
	#!/usr/bin/env bash
	set -euo pipefail

	# Check if yt-dlp is installed
	if ! command -v yt-dlp &> /dev/null; then
		echo "{{RED}}Error: yt-dlp is not installed{{NORMAL}}"
		echo ""
		echo "Install with:"
		if [[ "$OSTYPE" == "darwin"* ]]; then
			echo "  brew install yt-dlp"
		else
			echo "  pip install yt-dlp"
		fi
		exit 1
	fi

	# Check if uv is installed
	if ! command -v uv &> /dev/null; then
		echo "{{RED}}Error: uv is not installed{{NORMAL}}"
		echo ""
		echo "Install with:"
		echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
		exit 1
	fi

	echo "{{GREEN}}Fetching YouTube videos...{{NORMAL}}"
	uv run fetch-videos.py

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

	# Show database file age
	if [[ "$OSTYPE" == "darwin"* ]]; then
		FILE_AGE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$DB_FILE")
		echo "{{YELLOW}}Database file modified:{{NORMAL}} $FILE_AGE"
	else
		FILE_AGE=$(stat -c "%y" "$DB_FILE" | cut -d'.' -f1)
		echo "{{YELLOW}}Database file modified:{{NORMAL}} $FILE_AGE"
	fi

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

# Fetch Claude Code usage data and create/update database
[working-directory("individuals/chicks/ccusage")]
[group('ccusage')]
fetch-ccusage:
	#!/usr/bin/env bash
	set -euo pipefail

	# Check if ccusage is installed
	if ! command -v ccusage &> /dev/null; then
		echo "{{RED}}Error: ccusage is not installed{{NORMAL}}"
		echo ""
		echo "ccusage is provided by Claude Code"
		exit 1
	fi

	echo "{{GREEN}}Fetching Claude Code usage data...{{NORMAL}}"
	go run fetch-usage.go

# View Claude Code usage database in Datasette
[group('ccusage')]
ccusage-db:
	just datasette individuals/chicks/ccusage/usage.db

# Show Claude Code usage statistics
[working-directory("individuals/chicks/ccusage")]
[group('ccusage')]
ccusage-stats:
	#!/usr/bin/env bash
	set -euo pipefail

	DB_FILE="usage.db"

	if [ ! -f "$DB_FILE" ]; then
		echo "{{RED}}Error: Database file not found: $DB_FILE{{NORMAL}}"
		echo "Run 'just fetch-ccusage' to create it."
		exit 1
	fi

	echo "{{GREEN}}Claude Code Usage Statistics{{NORMAL}}"
	echo ""

	# Show database file age
	if [[ "$OSTYPE" == "darwin"* ]]; then
		FILE_AGE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$DB_FILE")
		echo "{{YELLOW}}Database file modified:{{NORMAL}} $FILE_AGE"
	else
		FILE_AGE=$(stat -c "%y" "$DB_FILE" | cut -d'.' -f1)
		echo "{{YELLOW}}Database file modified:{{NORMAL}} $FILE_AGE"
	fi

	# Show date range
	echo ""
	echo "{{BLUE}}Date range:{{NORMAL}}"
	sqlite3 "$DB_FILE" "SELECT
	  MIN(date) as first_date,
	  MAX(date) as last_date,
	  COUNT(*) as total_days
	FROM daily_usage;"

	# Show overall totals
	echo ""
	echo "{{BLUE}}Overall totals:{{NORMAL}}"
	sqlite3 -header -column "$DB_FILE" "SELECT
	  SUM(input_tokens) as input_tokens,
	  SUM(output_tokens) as output_tokens,
	  SUM(cache_creation_tokens) as cache_creation,
	  SUM(cache_read_tokens) as cache_read,
	  SUM(total_tokens) as total_tokens,
	  printf('\$%.2f', SUM(total_cost)) as total_cost
	FROM daily_usage;"

	# Show last 7 days
	echo ""
	echo "{{BLUE}}Last 7 days:{{NORMAL}}"
	sqlite3 -header -column "$DB_FILE" "SELECT
	  date,
	  total_tokens,
	  printf('\$%.2f', total_cost) as cost
	FROM daily_usage
	ORDER BY date DESC
	LIMIT 7;"

	# Show top sessions by cost
	echo ""
	echo "{{BLUE}}Top 5 sessions by cost:{{NORMAL}}"
	sqlite3 -header -column "$DB_FILE" "SELECT
	  CASE
	    WHEN LENGTH(session_id) > 40 THEN SUBSTR(session_id, 1, 37) || '...'
	    ELSE session_id
	  END as session,
	  printf('\$%.2f', total_cost) as cost,
	  total_tokens
	FROM session_usage
	ORDER BY total_cost DESC
	LIMIT 5;"

# Check age of all database files in the repository
[group('Utility')]
db-status:
	#!/usr/bin/env bash
	set -euo pipefail

	echo "{{GREEN}}Database File Status{{NORMAL}}"
	echo ""

	# Find all .db files and count them
	DB_COUNT=$(find . -name "*.db" -type f | wc -l | tr -d ' ')

	if [ "$DB_COUNT" -eq 0 ]; then
		echo "{{YELLOW}}No database files found{{NORMAL}}"
		exit 0
	fi

	NOW=$(date +%s)

	# Print header
	printf "%-50s %-20s %-15s\n" "DATABASE FILE" "MODIFIED" "AGE"
	printf "%-50s %-20s %-15s\n" "$(printf '%.0s-' {1..50})" "$(printf '%.0s-' {1..20})" "$(printf '%.0s-' {1..15})"

	# Process each database file
	find . -name "*.db" -type f | sort | while IFS= read -r db; do
		# Get file modification time
		if [[ "$OSTYPE" == "darwin"* ]]; then
			# macOS
			MOD_TIME=$(stat -f "%m" "$db")
			MOD_DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$db")
		else
			# Linux
			MOD_TIME=$(stat -c "%Y" "$db")
			MOD_DATE=$(date -r "$db" "+%Y-%m-%d %H:%M")
		fi

		# Calculate age in seconds
		AGE_SECONDS=$((NOW - MOD_TIME))

		# Convert to days/hours/minutes
		DAYS=$((AGE_SECONDS / 86400))
		HOURS=$(((AGE_SECONDS % 86400) / 3600))
		MINUTES=$(((AGE_SECONDS % 3600) / 60))

		# Format age string
		if [ $DAYS -gt 0 ]; then
			AGE_STR="${DAYS}d ${HOURS}h ${MINUTES}m"
		elif [ $HOURS -gt 0 ]; then
			AGE_STR="${HOURS}h ${MINUTES}m"
		else
			AGE_STR="${MINUTES}m"
		fi

		# Determine color based on path and age
		# Blue: us-* databases and individuals/github-contrib/ (static/manual datasets)
		# Red: older than 24 hours (86400 seconds)
		# Yellow: older than 8 hours (28800 seconds)
		# Green: newer than 8 hours
		if [[ "$db" == ./us-* || "$db" == ./individuals/github-contrib/* ]]; then
			COLOR="{{BLUE}}"
		elif [ $AGE_SECONDS -gt 86400 ]; then
			COLOR="{{RED}}"
		elif [ $AGE_SECONDS -gt 28800 ]; then
			COLOR="{{YELLOW}}"
		else
			COLOR="{{GREEN}}"
		fi

		# Print the line with color for the age column
		printf "%-50s %-20s ${COLOR}%-15s{{NORMAL}}\n" "$db" "$MOD_DATE" "$AGE_STR"
	done
