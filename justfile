# project justfile

import? '.just/shellcheck.just'
import? '.just/compliance.just'
import? '.just/gh-process.just'

# list recipes (default works without naming it)
[group('example')]
list:
	just --list
	@echo "{{GREEN}}Your justfile is waiting for more scripts and snippets{{NORMAL}}"

# Check California lottery jackpots and show recent results
[working-directory("lottery")]
[group('lottery')]
check-jackpots:
	#!/usr/bin/env bash
	set -e
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
	wget https://data.ny.gov/api/views/d6yy-54nr/rows.csv?accessType=DOWNLOAD -O Lottery_Powerball_Winning_Numbers__Beginning_2010.csv
	wget https://data.ny.gov/api/views/5xaw-6ayf/rows.csv?accessType=DOWNLOAD -O Lottery_Mega_Millions_Winning_Numbers__Beginning_2002.csv
