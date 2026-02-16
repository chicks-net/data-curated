# project justfile

import? '.just/shellcheck.just'
import? '.just/compliance.just'
import? '.just/gh-process.just'

# this needs to be first in the file so that it acts as the default
# list recipes (default works without naming it)
[group('example')]
list:
	just --list

# ============================================================================
# Helper Functions (hidden recipes for internal use)
# ============================================================================

# Get file modification time in "YYYY-MM-DD HH:MM:SS" format (cross-platform)
[no-cd]
_file_mod_time FILE:
	#!/usr/bin/env bash
	if [[ "$OSTYPE" == "darwin"* ]]; then
		stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" '{{FILE}}'
	else
		stat -c "%y" '{{FILE}}' | cut -d'.' -f1
	fi

# Get file modification timestamp in seconds since epoch (cross-platform)
_file_mod_timestamp FILE:
	#!/usr/bin/env bash
	if [[ "$OSTYPE" == "darwin"* ]]; then
		stat -f "%m" '{{FILE}}'
	else
		stat -c "%Y" '{{FILE}}'
	fi

# Format seconds as human-readable age (e.g., "5d 3h 42m" or "2h 15m")
_format_age SECONDS:
	#!/usr/bin/env bash
	SECS='{{SECONDS}}'
	DAYS=$((SECS / 86400))
	HOURS=$(((SECS % 86400) / 3600))
	MINUTES=$(((SECS % 3600) / 60))
	if [ $DAYS -gt 0 ]; then
		echo "${DAYS}d ${HOURS}h ${MINUTES}m"
	elif [ $HOURS -gt 0 ]; then
		echo "${HOURS}h ${MINUTES}m"
	else
		echo "${MINUTES}m"
	fi

# Check if command exists, exit with error message if not
_require_command CMD INSTALL_MSG:
	#!/usr/bin/env bash
	CMD_NAME='{{CMD}}'
	if ! command -v "$CMD_NAME" &> /dev/null; then
		echo "{{RED}}Error: $CMD_NAME is not installed{{NORMAL}}"
		echo ""
		echo "{{INSTALL_MSG}}"
		exit 1
	fi

# Get platform-specific install command for a package
_get_install_cmd PKG_BREW PKG_APT="":
	#!/usr/bin/env bash
	BREW_PKG='{{PKG_BREW}}'
	PKG_APT="${2:-$BREW_PKG}"
	if [[ "$OSTYPE" == "darwin"* ]]; then
		echo "brew install $BREW_PKG"
	elif command -v apt-get &> /dev/null; then
		echo "sudo apt-get install $PKG_APT"
	elif command -v yum &> /dev/null; then
		echo "sudo yum install $PKG_APT"
	elif command -v dnf &> /dev/null; then
		echo "sudo dnf install $PKG_APT"
	else
		echo "Install $BREW_PKG for your platform"
	fi

# Find most recent file matching a glob pattern
_find_most_recent PATTERN ERROR_MSG:
	#!/usr/bin/env bash
	RESULT=""
	# shellcheck disable=SC1083,SC2043
	# Note: {{PATTERN}} is a just template variable that will be substituted
	# before the script runs. It must remain unquoted for glob expansion.
	for f in {{PATTERN}}; do
		[ -e "$f" ] || continue
		if [ -z "$RESULT" ] || [ "$f" -nt "$RESULT" ]; then
			RESULT="$f"
		fi
	done
	if [ -z "$RESULT" ]; then
		echo "{{ERROR_MSG}}" >&2
		exit 1
	fi
	echo "$RESULT"

# Show database file status (age and last modified time)
_show_db_age DB_PATH:
	#!/usr/bin/env bash
	if [ ! -f '{{DB_PATH}}' ]; then
		echo "{{RED}}Error: Database file not found: '{{DB_PATH}}'{{NORMAL}}"
		exit 1
	fi

	# Show file modification time
	if [[ "$OSTYPE" == "darwin"* ]]; then
		FILE_AGE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" '{{DB_PATH}}')
	else
		FILE_AGE=$(stat -c "%y" '{{DB_PATH}}' | cut -d'.' -f1)
	fi
	echo "{{YELLOW}}Database file modified:{{NORMAL}} $FILE_AGE"

# ============================================================================
# User-visible recipes
# ============================================================================

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
fetch-jackpots: _check_lottery_deps
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

	if [[ ! -f "$DB_FILE" ]]; then
		echo "{{RED}}Error: Database file not found: $DB_FILE{{NORMAL}}"
		echo "Run 'just fetch-jackpots' to create it."
		exit 1
	fi

	echo "{{GREEN}}Jackpot Database Status{{NORMAL}} ($DB_FILE)"
	echo ""

	# Show database file age using helper
	FILE_AGE=$(just _file_mod_time "$DB_FILE")
	echo "{{YELLOW}}Database file modified:{{NORMAL}} $FILE_AGE"

	# Show last database entry
	LAST_ENTRY=$(sqlite3 "$DB_FILE" "SELECT datetime(checked_at) FROM jackpots ORDER BY checked_at DESC LIMIT 1;")

	if [ -n "$LAST_ENTRY" ]; then
		echo "{{YELLOW}}Last jackpot check:{{NORMAL}} $LAST_ENTRY"
		echo ""

		# Calculate how long ago using helper
		LAST_TIMESTAMP=$(sqlite3 "$DB_FILE" "SELECT strftime('%s', checked_at) FROM jackpots ORDER BY checked_at DESC LIMIT 1;")
		NOW=$(date +%s)
		DIFF=$((NOW - LAST_TIMESTAMP))
		AGE_STR=$(just _format_age $DIFF)
		echo "{{BLUE}}Time since last check:{{NORMAL}} $AGE_STR ago"

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

# Lottery update cycle (once you are on a branch)
[working-directory("lottery")]
[group('lottery')]
lottery-update-all: _check_lottery_deps _on_a_branch
	just jackpot-status
	just download-lottery-numbers
	just analyze-megamillions
	just analyze-powerball
	just fetch-jackpots
	just analyze-jackpots
	just jackpot-status
	just db-status
	git add lottery
	git stp

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
		"png"        # PNG image reading for logos in contributions analysis
		"jpeg"       # JPEG image reading for logos in contributions analysis
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

	# Check if R is installed using helper
	INSTALL_CMD=$(just _get_install_cmd r r-base)
	just _require_command R "Install R:\n  $INSTALL_CMD"

	echo "{{GREEN}}Checking R package: {{PACKAGE}}{{NORMAL}}"
	echo ""

	# Check if package is already installed and get version
	INSTALLED_VERSION=$(R --quiet --no-save -e "
	tryCatch({
	  library('{{PACKAGE}}', character.only = TRUE)
	  cat(as.character(packageVersion('{{PACKAGE}}')))
	}, error = function(e) {
	  cat('NOT_INSTALLED')
	})
	" 2>/dev/null | tail -1)

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
	CSV_FILE=$(just _find_most_recent "blog-monthly-*.csv" "No CSV files found")
	echo "📊 CSV output: {{BLUE}}$CSV_FILE{{NORMAL}}"
	echo "Total rows: {{BLUE}}$(tail -n +2 "$CSV_FILE" | wc -l | tr -d ' '){{NORMAL}}"

# Generate graph from blog post CSV data
[working-directory("individuals/chicks/blog")]
[group('blog')]
graph-posts CSV="":
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	CSV_FILE="{{CSV}}"
	# If no CSV specified, find the most recent one
	if [ -z "$CSV_FILE" ]; then
		CSV_FILE=$(just _find_most_recent "blog-monthly-*.csv" "Error: No CSV file found. Run 'just count-posts' first.")
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
	CSV_FILE=$(just _find_most_recent "blog-monthly-*.csv" "Error: No CSV file found. Run 'just count-posts' first.")
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

	# Check if datasette is installed using helper
	just _require_command datasette "Install with: pip install datasette"

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

# Fetch historical GitHub commits (2008-2019) via REST API
[working-directory("individuals/chicks/github")]
[group('github')]
fetch-historical-commits:
	#!/usr/bin/env bash
	set -euo pipefail
	echo "Fetching historical GitHub commits (2008-2019)..."
	go run historical-commits.go

[working-directory("individuals/chicks/github/commits-analysis")]
[group('github')]
analyze-commits:
	Rscript analyze-commits-by-hour.R
	Rscript analyze-emoji-usage.R

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

# Github update cycle (once you are on a branch)
[group('github')]
github-update-all: _on_a_branch
	just fetch-comments
	just fetch-commits
	just analyze-commits
	just fetch-contributions
	just analyze-contributions
	git add individuals/chicks/github
	git stp
	just db-status

# Github update for CI (skips branch check)
_github-update-ci:
	just fetch-comments
	just fetch-commits
	just analyze-commits
	just fetch-contributions
	just analyze-contributions
	git add individuals/chicks/github
	git status --porcelain

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

# Run tests for just daily-ranking
[working-directory("individuals/github-contrib/daily-ranking")]
[group('github')]
daily-ranking-tests:
	just daily-ranking ~/Documents/git/megamap /tmp/megamap.jsonl main
	just daily-ranking ~/Documents/git/OtherFolks/terraform-provider-digitalocean /tmp/terraform-provider-digitalocean.jsonl main
	just daily-ranking ~/Documents/git/dnscontrol  /tmp/dnscontrol.jsonl main
	just daily-ranking ~/Documents/git/OtherFolks/linux /tmp/linux.jsonl master

# Generate an mp4 based on the Linux repo
[group('github')]
daily-ranking-test-movie:
	rm individuals/github-contrib/linux.cast
	asciinema record -c "just daily-ranking-viewer /tmp/linux.jsonl" individuals/github-contrib/linux.cast
	agg --speed 4 individuals/github-contrib/linux.cast individuals/github-contrib/linux.gif

	rm individuals/github-contrib/linux.mp4
	ffmpeg -i individuals/github-contrib/linux.gif -i  ~/Pictures/logos/Linux_TuxPenguin.png -filter_complex "[0:v]scale=3840:2160:flags=lanczos,format=yuv420p[bg];[bg][1:v]overlay=W-w-10:H-h-10" -movflags faststart individuals/github-contrib/linux.mp4
	exiftool individuals/github-contrib/linux.mp4

	rm individuals/github-contrib/linux-from-mp4.gif
	ffmpeg -i individuals/github-contrib/linux.mp4 -vf "scale=iw/2:ih/2:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" individuals/github-contrib/linux-from-mp4.gif

# Generate daily contributor rankings from a git repository
# Use BRANCH="main" to analyze only the main branch (matches GitHub Contributors)
[working-directory("individuals/github-contrib/daily-ranking")]
[group('github')]
daily-ranking DIR OUTPUT="" BRANCH="":
	#!/usr/bin/env bash
	set -euo pipefail

	# Check if go is installed using helper
	INSTALL_CMD=$(just _get_install_cmd go golang-go)
	just _require_command go "Install with:\n  $INSTALL_CMD\n  Or see: https://go.dev/doc/install"

	if [ ! -d "{{DIR}}/.git" ]; then
		echo "{{RED}}Error: {{DIR}} is not a git repository{{NORMAL}}"
		exit 1
	fi

	OUTPUT="{{OUTPUT}}"
	BRANCH="{{BRANCH}}"

	if [ -n "$BRANCH" ]; then
		if [ -n "$OUTPUT" ]; then
			go run daily-ranking.go -branch "$BRANCH" "{{DIR}}" "$OUTPUT"
		else
			go run daily-ranking.go -branch "$BRANCH" "{{DIR}}"
		fi
	else
		if [ -n "$OUTPUT" ]; then
			go run daily-ranking.go "{{DIR}}" "$OUTPUT"
		else
			go run daily-ranking.go "{{DIR}}"
		fi
	fi

# View daily contributor rankings with animated TUI (reads JSON from stdin or file)
# Usage: just daily-ranking DIR | just daily-ranking-viewer
#        just daily-ranking-viewer rankings.jsonl
#        just daily-ranking-viewer -n 15 -speed 1s rankings.jsonl
[group('github')]
daily-ranking-viewer filename:
	#!/usr/bin/env bash
	set -euo pipefail

	# Check if go is installed
	INSTALL_CMD=$(just _get_install_cmd go golang-go)
	just _require_command go "Install with:\n  $INSTALL_CMD\n  Or see: https://go.dev/doc/install"

	cd individuals/github-contrib/daily-ranking-viewer
	set -x
	go run . "{{ filename }}"

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

	# Check if yt-dlp is installed using helper
	INSTALL_CMD=$(just _get_install_cmd yt-dlp python3-yt-dlp)
	just _require_command yt-dlp "Install with:\n  $INSTALL_CMD"

	# Check if uv is installed using helper
	just _require_command uv "Install with:\n  curl -LsSf https://astral.sh/uv/install.sh | sh"

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
	go run generate-blog-posts.go {{DRY_RUN}}

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

	# Show database file age using helper
	just _show_db_age "$DB_FILE"

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

# Analyze Claude Code usage trends with visualizations
[working-directory("individuals/chicks/ccusage/usage-analysis")]
[group('ccusage')]
analyze-ccusage:
	Rscript analyze-usage.R

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
		# Get file modification time using helper
		MOD_TIME=$(just _file_mod_timestamp "$db")
		MOD_DATE=$(just _file_mod_time "$db" | cut -d' ' -f1,2 | sed 's/:..$//')

		# Calculate age in seconds and format using helper
		AGE_SECONDS=$((NOW - MOD_TIME))
		AGE_STR=$(just _format_age $AGE_SECONDS)

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
