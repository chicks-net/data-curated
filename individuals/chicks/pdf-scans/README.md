# PDF Scans Database

Metadata for scanned PDFs stored in a Google Drive folder, fetched via the
Google Drive API v3. Only file-level metadata is collected — **no PDF
contents are downloaded, no OCR is performed**.

## Quick Start

```bash
# Fetch PDF metadata from the configured folder
just fetch-pdf-metadata

# Fetch from a specific folder (overrides config.toml)
just fetch-pdf-metadata 1CtwXpXMMv06srY3z94KtGPQz7zCELhGP

# View database in browser
just pdf-scans-db

# Check database status
just pdf-scans-status
```

## Requirements

- Python 3.11+ (uses `tomllib` from the standard library)
- [`uv`](https://docs.astral.sh/uv/) — installs Python deps automatically:
  `curl -LsSf https://astral.sh/uv/install.sh | sh`
- SQLite3 (usually pre-installed)
- A Google Cloud project with the Drive API enabled

## Google Drive API Setup (one-time)

1. Open the
   [Google Cloud Console](https://console.cloud.google.com/) and create (or
   select) a project.
2. Enable the **Google Drive API**:
   APIs & Services → Library → search "Google Drive API" → Enable.
3. Configure the OAuth consent screen:
   - User type: **External** (or Internal if you're on Workspace)
   - Add yourself as a **test user** if the app stays in "Testing" status
4. Create credentials:
   - APIs & Services → Credentials → Create Credentials →
     **OAuth client ID**
   - Application type: **Desktop app**
   - Download the JSON
5. Rename the downloaded file to `credentials.json` and place it in this
   directory (`individuals/chicks/pdf-scans/credentials.json`). The file is
   gitignored.
6. On the first run, `just fetch-pdf-metadata` opens a browser window for
   consent. After authorizing, the OAuth token is cached at
   `~/.config/pdf-scans/token.json` so subsequent runs are non-interactive.

## Configuration

`config.toml` (committed — folder IDs aren't sensitive) holds defaults so you
don't have to pass them every run:

```toml
# The folder ID is the last path segment of the folder's Drive URL, e.g.:
#   https://drive.google.com/drive/folders/1CtwXpXMMv06srY3z94KtGPQz7zCELhGP
folder_id = "1CtwXpXMMv06srY3z94KtGPQz7zCELhGP"

recurse = true
```

Resolution order for the folder ID:

1. CLI argument: `just fetch-pdf-metadata <FOLDER_ID>`
2. `folder_id` in `config.toml`
3. Error (refusing to recurse all of My Drive by accident)

To disable recursion for a single run:

```bash
just fetch-pdf-metadata -- --no-recurse
```

## Database Schema

### files table

| Column | Type | Description |
| ------ | ---- | ----------- |
| id | TEXT | Drive file ID (primary key) |
| name | TEXT | File name |
| mime_type | TEXT | MIME type (always `application/pdf` here) |
| size_bytes | INTEGER | File size in bytes |
| created_time | TEXT | ISO 8601 creation timestamp |
| modified_time | TEXT | ISO 8601 modification timestamp |
| starred | INTEGER | 1 if starred, 0 otherwise |
| trashed | INTEGER | 1 if trashed, 0 otherwise |
| trashed_time | TEXT | ISO 8601 time the file was trashed (nullable) |
| web_view_link | TEXT | Drive viewer URL |
| web_content_link | TEXT | Direct download URL |
| md5_checksum | TEXT | MD5 checksum when Drive provides one |
| description | TEXT | Drive file description, if set |
| last_modifying_user_name | TEXT | Display name of last modifier |
| last_modifying_user_email | TEXT | Email of last modifier |
| parent_folder_id | TEXT | ID of the immediate parent folder |
| fetched_at | TEXT | ISO 8601 timestamp of this fetch |

### folders table

| Column | Type | Description |
| ------ | ---- | ----------- |
| id | TEXT | Drive folder ID (primary key) |
| name | TEXT | Folder name |
| parent_folder_id | TEXT | ID of the parent folder (nullable for root) |
| fetched_at | TEXT | ISO 8601 timestamp of this fetch |

### fetch_history table

| Column | Type | Description |
| ------ | ---- | ----------- |
| id | INTEGER | Auto-increment ID |
| fetched_at | TEXT | ISO 8601 timestamp |
| files_count | INTEGER | Total files processed (active + trashed) |
| success | INTEGER | 1 if successful, 0 if any folder failed |
| folder_id | TEXT | Root folder ID scanned |
| notes | TEXT | Failure details or other notes |

## Manual Usage

### Fetch metadata

```bash
cd individuals/chicks/pdf-scans
uv run fetch-pdfs.py                  # uses config.toml
uv run fetch-pdfs.py <FOLDER_ID>      # explicit folder
uv run fetch-pdfs.py --no-recurse     # top-level only
```

### View in Datasette

```bash
just pdf-scans-db
# or
datasette individuals/chicks/pdf-scans/pdfs.db -o
```

### Query with SQLite

```bash
sqlite3 individuals/chicks/pdf-scans/pdfs.db
```

Example queries:

```sql
-- Files scanned per year (excluding trashed)
SELECT substr(created_time, 1, 4) AS year, COUNT(*) AS count
FROM files
WHERE trashed = 0
GROUP BY year
ORDER BY year DESC;

-- Largest 10 files
SELECT name, size_bytes
FROM files
WHERE trashed = 0
ORDER BY size_bytes DESC
LIMIT 10;

-- Trashed files with when-trashed timestamps
SELECT name, trashed_time
FROM files
WHERE trashed = 1
ORDER BY trashed_time DESC;
```

## Data Collection

The script uses the Google Drive API v3 to list PDFs in the target folder
(and optionally subfolders) without downloading file contents:

1. Authorizes via the OAuth desktop flow (cached token after first run).
2. Enumerates the folder tree (BFS), recording each folder in `folders`.
3. For each folder, lists active PDFs and trashed PDFs separately so trashed
   files are recorded with `trashed=1` and `trashed_time` rather than
   silently skipped.
4. Upserts each file via `INSERT OR REPLACE` — re-runs are idempotent.
5. Records a `fetch_history` row for the run (used by
   `just pdf-scans-status` and `just db-status`).

## Updates

Re-run `just fetch-pdf-metadata` any time to refresh metadata. Existing rows
are overwritten with current Drive values; deleted-from-Drive files are not
removed from the local DB (they remain as a historical record). Trashed files
stay visible with `trashed=1`.

## Files

- `fetch-pdfs.py` — main fetcher script
- `pyproject.toml` — `uv` dependency manifest
- `config.toml` — default folder ID and recurse setting (committed)
- `schema.sql` — schema-only dump for documentation (committed)
- `pdfs.db` — SQLite database (created on first run, committed)
- `credentials.json` — OAuth client secret (you provide; gitignored)
- `README.md` — this file

## Privacy

`pdfs.db` contains filenames that may be personally identifying. Per the
repo's convention for personal-data collectors, the database is committed to
this repository for the owner's convenience. `credentials.json` and the
cached OAuth `token.json` are gitignored and must never be committed.

## Notes

- No OCR, no extracted text, no PDF internals — that's a deliberate scope
  limit. File-level metadata only. OCR/full-text can be a follow-on project.
- Timestamps are ISO 8601 UTC.
- The Drive API `files.list` endpoint returns at most 1000 items per page;
  the script paginates automatically.
- Shared drives are included (`supportsAllDrives`, `includeItemsFromAllDrives`).
