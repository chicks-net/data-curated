#!/usr/bin/env bash

DBFILE="states.db"

sqlite3 "$DBFILE" << EOF
.mode tabs
.import ./states.tsv states
EOF

ls -l "$DBFILE"
