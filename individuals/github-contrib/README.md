# GitHub Contributor Tools

A collection of Go tools for analyzing GitHub repository contributors.

## Tools

| Tool | Description |
| ------ | ------------- |
| [snapshot-contributors](snapshot-contributors/) | Fetch contributor statistics from GitHub API |
| [daily-ranking](daily-ranking/) | Generate daily rankings from git commit history |
| [daily-ranking-viewer](daily-ranking-viewer/) | Interactive TUI for visualizing daily rankings |

## Demo

![Daily Ranking Viewer Demo](linux-from-mp4.gif)

- [Demo video MP4](linux.mp4)
- [Demo video intermediate animated GIF](linux.gif)
- [Asciinema recording](linux.cast)

## Watch on YouTube

- [Linux kernel](https://youtu.be/eVn4suxlQnc)
- [Nixpkgs](https://youtu.be/zSiPkI6ybJ0)
- [Rust](https://youtu.be/VpNbSJWqakc)

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

## Asciimena notes

- 4k video == 3840 × 2160

```bash
stty -a          :   48 rows; 170 columns
Image Width                     : 1650
Image Height                    : 1096
```

```bash
stty -a          :   48 rows; 202 columns
Image Width                     : 1958
Image Height                    : 1096
```
