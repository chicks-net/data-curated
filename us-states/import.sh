#!/usr/bin/env bash

DBFILE="states.db"

# Drop and recreate so each run is a clean rebuild (STRICT enforces column
# types at insert time; requires SQLite >= 3.37).
sqlite3 "$DBFILE" << EOF
DROP TABLE IF EXISTS states;
CREATE TABLE states (
	"State" TEXT,
	"Abbreviation" TEXT
) STRICT;
.mode tabs
.import --skip 1 ./states.tsv states
EOF

ls -l "$DBFILE"
