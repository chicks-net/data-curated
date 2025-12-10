#!/usr/bin/env bash

set -euo pipefail

# Check for CSV file argument
if [ $# -eq 0 ]; then
    echo "Usage: $0 <csv-file>"
    echo "Example: $0 StackExchange-dnscontrol-contributors-20251210.csv"
    exit 1
fi

CSV_FILE="$1"

# Check if CSV file exists
if [ ! -f "$CSV_FILE" ]; then
    echo "Error: CSV file '$CSV_FILE' not found"
    exit 1
fi

# Derive database name from CSV file
# Replace .csv with .db
DB_FILE="${CSV_FILE%.csv}.db"

echo "Converting CSV to SQLite database..."
echo "  Input:  $CSV_FILE"
echo "  Output: $DB_FILE"

# Remove existing database if it exists
if [ -f "$DB_FILE" ]; then
    echo "Warning: Removing existing database file: $DB_FILE"
    rm "$DB_FILE"
fi

# Import CSV into SQLite
sqlite3 "$DB_FILE" << EOF
-- Create table with proper types
CREATE TABLE contributors (
    login TEXT NOT NULL,
    user_id INTEGER NOT NULL,
    avatar_url TEXT,
    type TEXT,
    site_admin INTEGER,
    total_commits INTEGER NOT NULL,
    total_additions INTEGER NOT NULL,
    total_deletions INTEGER NOT NULL,
    weeks_active INTEGER NOT NULL,
    rank_by_commits INTEGER NOT NULL,
    rank_by_additions INTEGER NOT NULL,
    rank_by_deletions INTEGER NOT NULL
);

-- Import CSV data (skip header row)
.mode csv
.import $CSV_FILE contributors_temp

-- Copy data from temp table to main table with type conversion
INSERT INTO contributors
SELECT
    login,
    CAST(user_id AS INTEGER),
    avatar_url,
    type,
    CASE WHEN site_admin = 'true' THEN 1 ELSE 0 END,
    CAST(total_commits AS INTEGER),
    CAST(total_additions AS INTEGER),
    CAST(total_deletions AS INTEGER),
    CAST(weeks_active AS INTEGER),
    CAST(rank_by_commits AS INTEGER),
    CAST(rank_by_additions AS INTEGER),
    CAST(rank_by_deletions AS INTEGER)
FROM contributors_temp
WHERE login != 'login'; -- Skip header row

-- Drop temp table
DROP TABLE contributors_temp;

-- Create indexes for common queries
CREATE INDEX IF NOT EXISTS idx_login ON contributors(login);
CREATE INDEX IF NOT EXISTS idx_rank_commits ON contributors(rank_by_commits);
CREATE INDEX IF NOT EXISTS idx_rank_additions ON contributors(rank_by_additions);
CREATE INDEX IF NOT EXISTS idx_rank_deletions ON contributors(rank_by_deletions);
CREATE INDEX IF NOT EXISTS idx_total_commits ON contributors(total_commits);
CREATE INDEX IF NOT EXISTS idx_total_additions ON contributors(total_additions);
CREATE INDEX IF NOT EXISTS idx_total_deletions ON contributors(total_deletions);

-- Display database info
.schema contributors
SELECT COUNT(*) as total_contributors FROM contributors;
SELECT 'Top 5 by commits:' as query;
SELECT rank_by_commits, login, total_commits FROM contributors ORDER BY rank_by_commits LIMIT 5;
EOF

echo ""
echo "Database created successfully!"
ls -lh "$DB_FILE"
echo ""
echo "To explore with datasette:"
echo "  datasette $DB_FILE -o"
