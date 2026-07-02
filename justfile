# project justfile

import? '.just/template-sync.just'
import? '.just/repo-toml.just'
import? '.just/pr-hook.just'
import? '.just/cue-verify.just'
import? '.just/copilot.just'
import? '.just/claude.just'
import? '.just/shellcheck.just'
import? '.just/compliance.just'
import? '.just/gh-process.just'
import? '.just/data-lottery.just'
import? '.just/data-github.just'
import? '.just/data-youtube.just'

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

	# Check if package is already installed and get version.
	# Use Rscript (not 'R') to avoid R's interactive '> ' prompt appearing
	# as the last line of output, which tail -1 would capture instead of version.
	INSTALLED_VERSION=$(Rscript -e "
	tryCatch({
	  library('{{PACKAGE}}', character.only = TRUE, warn.conflicts = FALSE)
	  cat(as.character(packageVersion('{{PACKAGE}}')))
	}, error = function(e) {
	  cat('NOT_INSTALLED')
	})" 2>/dev/null | tail -1)

	# Validate we got a real version number (not an R prompt artifact like '>')
	if [[ ! "$INSTALLED_VERSION" =~ ^[0-9]+\.[0-9]+ ]]; then
		INSTALLED_VERSION="NOT_INSTALLED"
	fi

	if [ "$INSTALLED_VERSION" != "NOT_INSTALLED" ]; then
		echo "{{YELLOW}}Package {{PACKAGE}} is already installed (version $INSTALLED_VERSION){{NORMAL}}"
		echo ""

		# Check for updates
		echo "{{BLUE}}Checking for updates...{{NORMAL}}"
		UPDATE_INFO=$(Rscript -e "
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
		NEW_VERSION=$(Rscript -e "cat(as.character(packageVersion('{{PACKAGE}}')))" 2>/dev/null | tail -1)
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

# add sound to movie
[group('Utility')]
add_sound_to_movie input_video input_audio:
	ffmpeg -i "{{ input_video }}" -i "{{ input_audio }}" -c:v copy -c:a aac -map 0:v:0 -map 1:a:0 "{{ input_video }}-withsound.mp4"

# Analyze US restaurant density by county
[working-directory("us-restaurants")]
[group('restaurants')]
analyze-restaurants:
	Rscript analyze-restaurants.R

# Generate restaurant density map by county
[working-directory("us-restaurants")]
[group('restaurants')]
map-restaurants *args:
	Rscript map-restaurants.R {{ args }}

# Analyze The Tower playlog data
[working-directory("individuals/chicks/games/the-tower/analysis")]
[group('games')]
analyze-the-tower:
	Rscript analyze-playlog.R

# Update The Tower playlog data and analysis
[group('games')]
update-the-tower:
	#!/usr/bin/env bash
	set -euo pipefail

	just branch the-tower-update

	tower_playlog="individuals/chicks/games/the-tower/the_tower_playlog.tsv"
	echo "{{GREEN}}Moving playlog to $tower_playlog{{NORMAL}}"
	mv ~/Downloads/The\ Tower\ -\ PlayLog.tsv "$tower_playlog"
	dos2unix "$tower_playlog"

	just analyze-the-tower

	git add individuals/chicks/games/the-tower

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
