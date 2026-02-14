# GitHub Contributor Tools

A collection of Go tools for analyzing GitHub repository contributors.

## Tools

| Tool | Description |
|------|-------------|
| [snapshot-contributors](snapshot-contributors/) | Fetch contributor statistics from GitHub API |
| [daily-ranking](daily-ranking/) | Generate daily rankings from git commit history |
| [daily-ranking-viewer](daily-ranking-viewer/) | Interactive TUI for visualizing daily rankings |

## Prerequisites

All tools require:

- Go 1.21 or later
- GitHub CLI (`gh`) installed and authenticated (for tools using GitHub API)

## Data Analysis

Generated data files can be analyzed with:

- `datasette` - Interactive browser interface for SQLite databases
- SQLite - Direct SQL queries
- Excel/Google Sheets - Open CSV files
- Python/R - Programmatic analysis

## Converting CSV to SQLite

Use `sqlite3` to import CSV data:

```bash
sqlite3 output.db <<EOF
.mode csv
.import data.csv tablename
EOF
```

Or open directly in datasette:

```bash
datasette data.db -o
```