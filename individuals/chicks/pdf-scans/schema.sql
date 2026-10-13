-- schema.sql — schema-only dump of pdfs.db for documentation.
-- The live database (pdfs.db) is created by fetch-pdfs.py on first run.

CREATE TABLE files (
    id TEXT PRIMARY KEY,                    -- Drive file ID
    name TEXT,
    mime_type TEXT,
    size_bytes INTEGER,
    created_time TEXT,                      -- ISO 8601
    modified_time TEXT,                     -- ISO 8601
    starred INTEGER,                        -- 0/1
    trashed INTEGER,                        -- 0/1
    trashed_time TEXT,                      -- ISO 8601, when trashed (nullable)
    web_view_link TEXT,
    web_content_link TEXT,
    md5_checksum TEXT,
    description TEXT,
    last_modifying_user_name TEXT,
    last_modifying_user_email TEXT,
    parent_folder_id TEXT,
    fetched_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE folders (
    id TEXT PRIMARY KEY,                    -- Drive folder ID
    name TEXT,
    parent_folder_id TEXT,
    fetched_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE fetch_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    fetched_at TEXT,
    files_count INTEGER,
    success INTEGER,
    folder_id TEXT,
    notes TEXT
);

CREATE INDEX idx_files_created ON files(created_time);
CREATE INDEX idx_files_trashed ON files(trashed);
CREATE INDEX idx_files_parent ON files(parent_folder_id);
CREATE INDEX idx_folders_parent ON folders(parent_folder_id);