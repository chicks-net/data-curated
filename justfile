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
		CSV_FILE=$(ls -t blog-monthly-*.csv 2>/dev/null | head -1 || echo "")
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
	go run graph-generator.go "$CSV_FILE"

# Generate graph for the last 36 months of blog posts
[working-directory("individuals/chicks/blog")]
[group('blog')]
graph-posts-36:
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	# Find the most recent CSV file
	CSV_FILE=$(ls -t blog-monthly-*.csv 2>/dev/null | head -1 || echo "")
	if [ -z "$CSV_FILE" ]; then
		echo "Error: No CSV file found. Run 'just count-posts' first."
		exit 1
	fi
	echo "{{GREEN}}Generating graph for last 36 months from $CSV_FILE{{NORMAL}}"
	echo ""
	go run graph-generator.go "$CSV_FILE" 36

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
