# lottery data recipes

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
	echo "{{YELLOW}}Recent jackpot checks:{{NORMAL}}"
	echo ""
	sqlite3 -header -column "{{ jackpot_database }}" "SELECT \
	  game as Game, \
	  printf('Draw #%d', draw_number) as Draw, \
	  draw_date as 'Draw Date', \
	  printf('\$%,d M', jackpot/1000000) as Jackpot, \
	  printf('\$%.1f M', CAST(estimated_cash AS REAL)/1000000) as Cash, \
	  datetime(checked_at, 'localtime') as Checked \
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
	git add .
	git stp