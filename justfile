# project justfile

import? '.just/shellcheck.just'
import? '.just/compliance.just'
import? '.just/gh-process.just'

# list recipes (default works without naming it)
[group('example')]
list:
	just --list
	@echo "{{GREEN}}Your justfile is waiting for more scripts and snippets{{NORMAL}}"

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
			sudo apt-get update && sudo apt-get install -y "${MISSING[@]}"
		elif command -v yum &> /dev/null; then
			sudo yum install -y "${MISSING[@]}"
		elif command -v dnf &> /dev/null; then
			sudo dnf install -y "${MISSING[@]}"
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

# Check California lottery jackpots and show recent results
[working-directory("lottery")]
[group('lottery')]
check-jackpots:
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	if ! command -v sqlite3 &> /dev/null; then
		echo "Error: sqlite3 command not found. Please install SQLite."
		exit 1
	fi
	echo "Checking California Lottery jackpots..."
	echo ""
	go run jackpot-checker.go
	echo ""
	echo "Recent jackpot checks:"
	sqlite3 jackpots.db "SELECT \
	  game, \
	  printf('Draw #%d', draw_number) as draw, \
	  draw_date, \
	  printf('\$%,d M', jackpot/1000000) as jackpot, \
	  printf('\$%.1f M', CAST(estimated_cash AS REAL)/1000000) as cash, \
	  datetime(checked_at) as checked \
	FROM jackpots \
	ORDER BY checked_at DESC \
	LIMIT 10;"

# Download New York lottery winning numbers (Powerball and Mega Millions)
[working-directory("lottery")]
[group('lottery')]
download-lottery-numbers:
	#!/usr/bin/env bash
	set -euo pipefail # strict mode
	wget https://data.ny.gov/api/views/d6yy-54nr/rows.csv?accessType=DOWNLOAD -O Lottery_Powerball_Winning_Numbers__Beginning_2010.csv
	wget https://data.ny.gov/api/views/5xaw-6ayf/rows.csv?accessType=DOWNLOAD -O Lottery_Mega_Millions_Winning_Numbers__Beginning_2002.csv
