# GitHub Contributor Data Fetcher

This tool downloads contributor statistics from GitHub repositories and saves
them to CSV files.

## Overview

The contributor fetcher uses the GitHub API to retrieve detailed statistics
about repository contributors, including:

- Username and user ID
- Total commits
- Total additions and deletions
- Number of weeks active
- User type and admin status
- Rankings by commits, additions, and deletions

## Prerequisites

- Go 1.21 or later
- GitHub CLI (`gh`) installed and authenticated
- Required Go dependencies:
  - `github.com/rs/zerolog`

## Installation

Install the required Go dependencies:

```bash
go get github.com/rs/zerolog
go get github.com/rs/zerolog/log
```

## Usage

Run the program with a repository in the format `owner/repo`:

```bash
go run contributor-fetcher.go <owner/repo>
```

### Examples

```bash
# Fetch contributors for StackExchange/dnscontrol
go run contributor-fetcher.go StackExchange/dnscontrol

# Fetch contributors for golang/go
go run contributor-fetcher.go golang/go
```

## Output

The program generates a CSV file with the following naming convention:

```text
<owner>-<repo>-contributors-<YYYYMMDD>.csv
```

For example:

```text
StackExchange-dnscontrol-contributors-20251209.csv
```

### CSV Format

The CSV file contains the following columns:

- `login` - GitHub username
- `user_id` - Numeric user ID
- `avatar_url` - URL to user's avatar image
- `type` - User type (User, Bot, etc.)
- `site_admin` - Whether the user is a GitHub site admin
- `total_commits` - Total number of commits
- `total_additions` - Total lines added across all commits
- `total_deletions` - Total lines deleted across all commits
- `weeks_active` - Number of weeks with at least one commit
- `rank_by_commits` - Ranking based on total commits (1 = most commits)
- `rank_by_additions` - Ranking based on total additions (1 = most additions)
- `rank_by_deletions` - Ranking based on total deletions (1 = most deletions)

## Logging

The program uses structured logging with `zerolog`. By default, it outputs
human-readable console logs. To enable JSON logging, set the `JSON_LOGS`
environment variable:

```bash
JSON_LOGS=true go run contributor-fetcher.go owner/repo
```

## GitHub API Notes

This tool uses the GitHub `/repos/{owner}/{repo}/stats/contributors` endpoint.
Important notes:

- The first request may take time as GitHub computes the statistics
- If the API returns a 202 status, the data is being computed - try again
  after a few moments
- The data is cached by GitHub and refreshed periodically

## Example Output

```csv
login,user_id,avatar_url,type,site_admin,total_commits,total_additions,total_deletions,weeks_active,rank_by_commits,rank_by_additions,rank_by_deletions
tlimoncelli,6293917,https://avatars.githubusercontent.com/u/6293917,User,false,1466,639219,1483531,302,1,1,1
cafferata,1150425,https://avatars.githubusercontent.com/u/1150425,User,false,214,187338,181396,72,2,2,3
dependabot[bot],49699333,https://avatars.githubusercontent.com/in/29110,Bot,false,134,697,513,82,3,43,23
```

### Ranking Notes

- Rankings are calculated independently for each metric
- Rank 1 indicates the highest value (most commits, additions, or deletions)
- Contributors may have different ranks for different metrics
- For example, a bot might rank high in commits but lower in additions/deletions

## Error Handling

The program will exit with an error message if:

- No repository argument is provided
- The repository format is invalid (must be `owner/repo`)
- The GitHub API request fails
- The CSV file cannot be written

## Converting CSV to SQLite

Use the provided import script to convert CSV files to SQLite databases:

```bash
./import-to-sqlite.sh <csv-file>
```

### Example

```bash
./import-to-sqlite.sh StackExchange-dnscontrol-contributors-20251210.csv
```

This will create a SQLite database file with the same name (`.db` extension instead
of `.csv`). The script:

- Creates a properly typed table with INTEGER and TEXT columns
- Imports the CSV data
- Creates indexes on commonly queried columns (login, rankings, totals)
- Displays a summary and top contributors

### Database Schema

The SQLite database includes:

- Table: `contributors` with properly typed columns
- Indexes on: `login`, `rank_by_commits`, `rank_by_additions`, `rank_by_deletions`,
  `total_commits`, `total_additions`, `total_deletions`

### Querying the Database

```bash
# Interactive SQL queries
sqlite3 StackExchange-dnscontrol-contributors-20251210.db

# Example queries
sqlite3 StackExchange-dnscontrol-contributors-20251210.db \
  "SELECT login, total_commits FROM contributors ORDER BY rank_by_commits LIMIT 10;"

# Open in datasette for interactive exploration
datasette StackExchange-dnscontrol-contributors-20251210.db -o
```

## Data Analysis

The generated CSV and SQLite files can be analyzed using various tools:

- `datasette` - Open in an interactive browser interface
- SQLite - Query the data with SQL
- Excel/Google Sheets - Open CSV files and analyze visually
- Python/R - Load and analyze programmatically
