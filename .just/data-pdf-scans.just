# pdf-scans data recipes

# Fetch PDF metadata from Google Drive
[working-directory("individuals/chicks/pdf-scans")]
[group('pdf-scans')]
fetch-pdf-metadata FOLDER_ID="":
    #!/usr/bin/env bash
    set -euo pipefail
    just _require_command uv "Install with: curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "{{GREEN}}Fetching PDF metadata from Google Drive...{{NORMAL}}"
    # If FOLDER_ID empty, fetch-pdfs.py reads config.toml
    # shellcheck disable=SC1083,SC2086
    uv run fetch-pdfs.py {{FOLDER_ID}}

# View PDF metadata database in Datasette
[group('pdf-scans')]
pdf-scans-db:
    just datasette individuals/chicks/pdf-scans/pdfs.db

# Show PDF metadata database status
[working-directory("individuals/chicks/pdf-scans")]
[group('pdf-scans')]
pdf-scans-status:
    #!/usr/bin/env bash
    set -euo pipefail
    DB_FILE="pdfs.db"
    if [ ! -f "$DB_FILE" ]; then
        echo "{{RED}}Error: Database file not found: $DB_FILE{{NORMAL}}"
        echo "Run 'just fetch-pdf-metadata' to create it."
        exit 1
    fi
    echo "{{GREEN}}PDF Scans Database Status{{NORMAL}}"
    just _show_db_age "$DB_FILE"
    LAST_FETCH=$(sqlite3 "$DB_FILE" "SELECT fetched_at FROM fetch_history ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    if [ -n "$LAST_FETCH" ]; then
        echo "{{YELLOW}}Last fetch:{{NORMAL}} $LAST_FETCH"
        echo ""
        TOTAL=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM files;")
        TRASHED=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM files WHERE trashed=1;")
        ACTIVE=$((TOTAL - TRASHED))
        echo "{{BLUE}}Total files:{{NORMAL}} $TOTAL  (active: $ACTIVE, trashed: $TRASHED)"
        echo ""
        echo "{{BLUE}}Files by year (created, excluding trashed):{{NORMAL}}"
        sqlite3 -column "$DB_FILE" "SELECT substr(created_time,1,4) as year, COUNT(*) as count FROM files WHERE trashed=0 GROUP BY year ORDER BY year DESC;"
        echo ""
        echo "{{BLUE}}Largest 5 files (excluding trashed):{{NORMAL}}"
        sqlite3 -column -header "$DB_FILE" "SELECT substr(name,1,50) as name, size_bytes FROM files WHERE trashed=0 ORDER BY size_bytes DESC LIMIT 5;"
    else
        echo "{{RED}}No fetch history found{{NORMAL}}"
    fi