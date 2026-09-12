#!/usr/bin/env python3
"""
Fetch metadata for scanned PDFs in Google Drive and store it in a SQLite
database.

Uses the Google Drive API v3 with an OAuth desktop-app flow. Only file-level
metadata is collected — no PDF contents are downloaded, no OCR is performed.
Re-runs are idempotent via ``INSERT OR REPLACE``.

Setup (one-time):

1. Enable the Google Drive API in Google Cloud Console.
2. Create an OAuth 2.0 desktop client ID and download ``credentials.json``
   into this script's directory (gitignored).
3. First run opens a browser for consent; the token is cached at
   ``~/.config/pdf-scans/token.json`` for subsequent runs.

See ``README.md`` for full details.
"""

import argparse
import os
import sqlite3
import sys
import tomllib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Optional

# Drive API scopes — read-only metadata access.
SCOPES = ["https://www.googleapis.com/auth/drive.metadata.readonly"]

SCRIPT_DIR = Path(__file__).parent
DB_PATH = SCRIPT_DIR / "pdfs.db"
CONFIG_PATH = SCRIPT_DIR / "config.toml"
CREDENTIALS_PATH = SCRIPT_DIR / "credentials.json"
TOKEN_DIR = Path.home() / ".config" / "pdf-scans"
TOKEN_PATH = TOKEN_DIR / "token.json"

# Drive API returns at most 1000 items per page.
PAGE_SIZE = 1000

# Fields requested for each file resource. Keeps payloads small.
FILE_FIELDS = ",".join(
    [
        "id",
        "name",
        "mimeType",
        "size",
        "createdTime",
        "modifiedTime",
        "trashed",
        "trashedTime",
        "parents",
        "lastModifyingUser(displayName,emailAddress)",
        "webViewLink",
        "webContentLink",
        "md5Checksum",
        "description",
        "starred",
    ]
)

FOLDER_MIMETYPE = "application/vnd.google-apps.folder"
PDF_MIMETYPE = "application/pdf"


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def load_config() -> dict[str, Any]:
    """Load config.toml from the script directory.

    Returns an empty dict if the file is missing.
    """
    if not CONFIG_PATH.exists():
        return {}
    with CONFIG_PATH.open("rb") as fh:
        return tomllib.load(fh)


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------


def authenticate():
    """Authorize via OAuth desktop flow and return an authenticated Drive v3
    service object.

    Raises SystemExit with a helpful message if credentials.json is missing.
    """
    if not CREDENTIALS_PATH.exists():
        print(
            f"Error: {CREDENTIALS_PATH} not found.\n"
            "Download an OAuth 2.0 desktop client credentials.json from "
            "Google Cloud Console and place it in this directory.",
            file=sys.stderr,
        )
        sys.exit(1)

    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    creds: Optional[Credentials] = None
    if TOKEN_PATH.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_PATH), SCOPES)

    # Refresh or initiate the flow.
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            TOKEN_DIR.mkdir(parents=True, exist_ok=True)
            flow = InstalledAppFlow.from_client_secrets_file(
                str(CREDENTIALS_PATH), SCOPES
            )
            creds = flow.run_local_server(port=0)
        TOKEN_PATH.write_text(creds.to_json())
        os.chmod(TOKEN_PATH, 0o600)

    return build("drive", "v3", credentials=creds, static_discovery=False)


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------


def create_database() -> None:
    """Create the SQLite database schema if it doesn't already exist."""
    with sqlite3.connect(DB_PATH) as conn:
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS files (
                id TEXT PRIMARY KEY,
                name TEXT,
                mime_type TEXT,
                size_bytes INTEGER,
                created_time TEXT,
                modified_time TEXT,
                starred INTEGER,
                trashed INTEGER,
                trashed_time TEXT,
                web_view_link TEXT,
                web_content_link TEXT,
                md5_checksum TEXT,
                description TEXT,
                last_modifying_user_name TEXT,
                last_modifying_user_email TEXT,
                parent_folder_id TEXT,
                fetched_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS folders (
                id TEXT PRIMARY KEY,
                name TEXT,
                parent_folder_id TEXT,
                fetched_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS fetch_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fetched_at TEXT,
                files_count INTEGER,
                success INTEGER,
                folder_id TEXT,
                notes TEXT
            )
            """
        )
        # Indexes for common queries (mirror fetch-videos.py conventions).
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_files_created ON files(created_time)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_files_trashed ON files(trashed)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_files_parent ON files(parent_folder_id)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_folder_id)"
        )
        conn.commit()


# ---------------------------------------------------------------------------
# Drive API helpers
# ---------------------------------------------------------------------------


def list_files_in_folder(service, folder_id: str, trashed: bool) -> list[dict]:
    """List all PDFs in a single folder (one pagination stream).

    Args:
        service: Authenticated Drive v3 service.
        folder_id: Drive folder ID to list.
        trashed: If True, query trashed files; otherwise non-trashed.

    Returns:
        List of file resource dicts.
    """
    files: list[dict] = []
    page_token: Optional[str] = None

    # Drive's q syntax uses 'trashed = true' / 'trashed = false'.
    query = (
        f"'{folder_id}' in parents and mimeType = '{PDF_MIMETYPE}' "
        f"and trashed = {'true' if trashed else 'false'}"
    )

    while True:
        request = service.files().list(
            q=query,
            pageSize=PAGE_SIZE,
            fields=f"nextPageToken,files({FILE_FIELDS})",
            pageToken=page_token,
            includeItemsFromAllDrives=True,
            supportsAllDrives=True,
        )
        response = request.execute()

        files.extend(response.get("files", []))
        page_token = response.get("nextPageToken")
        if not page_token:
            break

    return files


def list_subfolders(service, folder_id: str) -> list[dict]:
    """List immediate subfolders of a folder (non-trashed)."""
    folders: list[dict] = []
    page_token: Optional[str] = None
    query = (
        f"'{folder_id}' in parents and mimeType = '{FOLDER_MIMETYPE}' "
        "and trashed = false"
    )
    fields = ",".join(["id", "name", "parents"])

    while True:
        request = service.files().list(
            q=query,
            pageSize=PAGE_SIZE,
            fields=f"nextPageToken,files({fields})",
            pageToken=page_token,
            includeItemsFromAllDrives=True,
            supportsAllDrives=True,
        )
        response = request.execute()
        folders.extend(response.get("files", []))
        page_token = response.get("nextPageToken")
        if not page_token:
            break

    return folders


def get_folder_name(service, folder_id: str) -> Optional[str]:
    """Fetch the name of a single folder by ID."""
    try:
        meta = (
            service.files()
            .get(
                fileId=folder_id,
                fields="id,name,parents",
                supportsAllDrives=True,
            )
            .execute()
        )
        return meta.get("name")
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: could not fetch folder name for {folder_id}: {exc}",
              file=sys.stderr)
        return None


def collect_folders(
    service, root_folder_id: str, recurse: bool
) -> list[dict]:
    """Collect the root folder and (optionally) all descendant folders.

    Each returned dict has keys: id, name, parent_folder_id.
    The root folder is included as the first entry.
    """
    root_name = get_folder_name(service, root_folder_id)
    root_parents = None
    try:
        meta = (
            service.files()
            .get(
                fileId=root_folder_id,
                fields="parents",
                supportsAllDrives=True,
            )
            .execute()
        )
        root_parents = meta.get("parents")
    except Exception:  # noqa: BLE001 / S110
        pass

    collected: list[dict] = [
        {
            "id": root_folder_id,
            "name": root_name,
            "parent_folder_id": root_parents[0] if root_parents else None,
        }
    ]

    if not recurse:
        return collected

    # BFS through the folder tree.
    queue: list[str] = [root_folder_id]
    seen: set[str] = {root_folder_id}
    while queue:
        current = queue.pop(0)
        children = list_subfolders(service, current)
        for child in children:
            cid = child["id"]
            if cid in seen:
                continue
            seen.add(cid)
            parents = child.get("parents") or []
            collected.append(
                {
                    "id": cid,
                    "name": child.get("name"),
                    "parent_folder_id": parents[0] if parents else current,
                }
            )
            queue.append(cid)

    return collected


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------


def store_folders(folders: Iterable[dict], fetched_at: str) -> int:
    """Upsert folder records. Returns the number of folders stored."""
    rows = list(folders)
    if not rows:
        return 0

    with sqlite3.connect(DB_PATH) as conn:
        cur = conn.cursor()
        for folder in rows:
            cur.execute(
                """
                INSERT OR REPLACE INTO folders (
                    id, name, parent_folder_id, fetched_at
                ) VALUES (?, ?, ?, ?)
                """,
                (
                    folder["id"],
                    folder.get("name"),
                    folder.get("parent_folder_id"),
                    fetched_at,
                ),
            )
        conn.commit()
    return len(rows)


def store_files(files: Iterable[dict], fetched_at: str) -> int:
    """Upsert file records. Returns the number of files stored."""
    rows = list(files)
    if not rows:
        return 0

    with sqlite3.connect(DB_PATH) as conn:
        cur = conn.cursor()
        for f in rows:
            last_user = f.get("lastModifyingUser") or {}
            parents = f.get("parents") or []
            cur.execute(
                """
                INSERT OR REPLACE INTO files (
                    id, name, mime_type, size_bytes, created_time,
                    modified_time, starred, trashed, trashed_time,
                    web_view_link, web_content_link, md5_checksum,
                    description, last_modifying_user_name,
                    last_modifying_user_email, parent_folder_id, fetched_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    f.get("id"),
                    f.get("name"),
                    f.get("mimeType"),
                    int(f["size"]) if f.get("size") is not None else None,
                    f.get("createdTime"),
                    f.get("modifiedTime"),
                    1 if f.get("starred") else 0,
                    1 if f.get("trashed") else 0,
                    f.get("trashedTime"),
                    f.get("webViewLink"),
                    f.get("webContentLink"),
                    f.get("md5Checksum"),
                    f.get("description"),
                    last_user.get("displayName"),
                    last_user.get("emailAddress"),
                    parents[0] if parents else None,
                    fetched_at,
                ),
            )
        conn.commit()
    return len(rows)


def record_fetch_history(
    fetched_at: str,
    files_count: int,
    success: int,
    folder_id: str,
    notes: str = "",
) -> None:
    """Insert a fetch_history row for this run."""
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            """
            INSERT INTO fetch_history (
                fetched_at, files_count, success, folder_id, notes
            ) VALUES (?, ?, ?, ?, ?)
            """,
            (fetched_at, files_count, success, folder_id, notes),
        )
        conn.commit()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Fetch metadata for scanned PDFs in a Google Drive folder and "
            "store it in a SQLite database. No file contents are downloaded."
        )
    )
    parser.add_argument(
        "folder_id",
        nargs="?",
        default="",
        help=(
            "Google Drive folder ID to scan. If omitted, falls back to "
            "folder_id in config.toml."
        ),
    )
    parser.add_argument(
        "--no-recurse",
        action="store_true",
        help="Do not recurse into subfolders (overrides config.toml).",
    )
    args = parser.parse_args()

    config = load_config()

    # Resolve folder ID: CLI arg > config.toml > error.
    folder_id: str = args.folder_id or config.get("folder_id", "")
    if not folder_id:
        print(
            "Error: no folder ID provided.\n"
            "Pass a folder ID as an argument, or set folder_id in "
            f"{CONFIG_PATH}.\n"
            "The folder ID is the last path segment of the folder's Drive URL.",
            file=sys.stderr,
        )
        sys.exit(2)

    # Resolve recurse: --no-recurse flag > config.toml > default True.
    recurse: bool = (
        not args.no_recurse
        if args.no_recurse
        else bool(config.get("recurse", True))
    )

    print("Google Drive PDF Metadata Fetcher")
    print("=" * 50)
    print(f"Folder ID: {folder_id}")
    print(f"Recurse:   {recurse}")
    print()

    create_database()

    print("Authorizing with Google Drive...")
    service = authenticate()

    # Collect the folder tree.
    print("Enumerating folders..." + (" (recursing)" if recurse else ""))
    folders = collect_folders(service, folder_id, recurse)
    print(f"  Found {len(folders)} folder(s)")

    fetched_at = datetime.now(timezone.utc).isoformat()

    # Store folders first so parent references exist.
    folder_count = store_folders(folders, fetched_at)
    print(f"  Stored {folder_count} folder record(s)")

    # Fetch PDFs (active and trashed) for every collected folder.
    total_files = 0
    total_trashed = 0
    failed_folders: list[str] = []

    for i, folder in enumerate(folders, 1):
        fid = folder["id"]
        fname = folder.get("name") or fid
        print(f"[{i}/{len(folders)}] Scanning: {fname}")

        try:
            active = list_files_in_folder(service, fid, trashed=False)
            trashed = list_files_in_folder(service, fid, trashed=True)
        except Exception as exc:  # noqa: BLE001
            print(f"  Warning: failed to list {fid}: {exc}", file=sys.stderr)
            failed_folders.append(fid)
            continue

        stored_active = store_files(active, fetched_at)
        stored_trashed = store_files(trashed, fetched_at)
        total_files += stored_active
        total_trashed += stored_trashed
        print(
            f"  {stored_active} active, {stored_trashed} trashed "
            f"(total this folder: {stored_active + stored_trashed})"
        )

    success = 1 if not failed_folders else 0
    notes = ""
    if failed_folders:
        notes = f"Failed folders: {', '.join(failed_folders)}"

    record_fetch_history(
        fetched_at=fetched_at,
        files_count=total_files + total_trashed,
        success=success,
        folder_id=folder_id,
        notes=notes,
    )

    print()
    print("=" * 50)
    print(
        f"Stored {total_files} active + {total_trashed} trashed = "
        f"{total_files + total_trashed} total file records in {DB_PATH}"
    )
    if failed_folders:
        print(f"Warning: {len(failed_folders)} folder(s) failed: {failed_folders}")
    print()
    print("View the database with:")
    print("  just pdf-scans-db")
    print(f"  or: datasette {DB_PATH} -o")

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()