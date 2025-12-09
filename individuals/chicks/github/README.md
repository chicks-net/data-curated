# GitHub Commit History Tracker

This Go program fetches your GitHub commit history using the GitHub CLI (`gh`)
and stores it in a SQLite database for analysis.

## Features

- Fetches commit history using the GitHub Search API via `gh` command
- Stores commits in a SQLite database
- Avoids API rate limits by using authenticated `gh` CLI
- Handles pagination automatically
- Skips duplicate commits on subsequent runs
- Supports up to 1000 most recent commits (GitHub API limitation)

## Prerequisites

- Go 1.25.5 or later
- GitHub CLI (`gh`) installed and authenticated
- SQLite3

## Installation

```bash
cd individuals/chicks/github
go mod download
```

## Usage

Run the program from the `individuals/chicks/github` directory:

```bash
go run commit-history.go
```

Or build and run:

```bash
go build -o commit-history commit-history.go
./commit-history
```

## Database Schema

The program creates a `commits.db` SQLite database with the following schema:

```sql
CREATE TABLE commits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sha TEXT NOT NULL UNIQUE,
    author_name TEXT NOT NULL,
    author_email TEXT NOT NULL,
    author_date TEXT NOT NULL,
    committer_name TEXT NOT NULL,
    committer_email TEXT NOT NULL,
    committer_date TEXT NOT NULL,
    message TEXT NOT NULL,
    repo_name TEXT NOT NULL,
    repo_full_name TEXT NOT NULL,
    html_url TEXT NOT NULL,
    fetched_at TEXT NOT NULL
);
```

Indexes are created on:

- `sha` - Fast duplicate checking
- `author_date` - Time-based queries
- `repo_full_name` - Repository-based queries
- `author_email` - Author-based queries
- `fetched_at` - Track when data was collected

## Viewing the Data

Use Datasette to browse the commit history:

```bash
datasette commits.db -o
```

Or query directly with SQLite:

```bash
sqlite3 commits.db "SELECT author_date, repo_full_name, message FROM commits ORDER BY author_date DESC LIMIT 10;"
```

## Logging

The program uses structured logging with zerolog:

- Console mode (default): Human-readable output
- JSON mode: Set `JSON_LOGS=true` for machine-readable logs

## Limitations

- GitHub Search API returns a maximum of 1000 results
- Only public commits are included in search results
- Private repository commits require appropriate permissions

## Example Queries

### Commits per repository

```sql
SELECT repo_full_name, COUNT(*) as commit_count
FROM commits
GROUP BY repo_full_name
ORDER BY commit_count DESC;
```

### Commits by month

```sql
SELECT strftime('%Y-%m', author_date) as month, COUNT(*) as commits
FROM commits
GROUP BY month
ORDER BY month DESC;
```

### Most active days

```sql
SELECT DATE(author_date) as date, COUNT(*) as commits
FROM commits
GROUP BY date
ORDER BY commits DESC
LIMIT 10;
```

## Data Sources

Data is fetched from the GitHub Search API using the `gh api` command:

```bash
gh api '/search/commits?q=author:USERNAME&sort=author-date&order=desc'
```

This approach uses your authenticated GitHub CLI session, avoiding rate limits
that would affect unauthenticated API requests.
