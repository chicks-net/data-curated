#!/bin/bash
# Simple wrapper script to check California lottery jackpots

set -e

cd "$(dirname "$0")"

# Check for required dependencies
if ! command -v sqlite3 &> /dev/null; then
    echo "Error: sqlite3 command not found. Please install SQLite."
    exit 1
fi

echo "Checking California Lottery jackpots..."
echo ""

go run jackpot-checker.go

echo ""
echo "Recent jackpot checks:"
sqlite3 jackpots.db "SELECT
  game,
  printf('Draw #%d', draw_number) as draw,
  draw_date,
  printf('\$%,d M', jackpot/1000000) as jackpot,
  printf('\$%.1f M', CAST(estimated_cash AS REAL)/1000000) as cash,
  datetime(checked_at) as checked
FROM jackpots
ORDER BY checked_at DESC
LIMIT 10;"
