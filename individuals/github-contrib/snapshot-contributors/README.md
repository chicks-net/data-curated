# Snapshot Contributors

Downloads contributor statistics from GitHub repositories and saves them to CSV files.

## Overview

Fetches detailed statistics about repository contributors using the GitHub API:

- Username and user ID
- Total commits, additions, and deletions
- Weeks active
- User type and admin status
- Rankings by commits, additions, and deletions

## Prerequisites

- Go 1.21 or later
- GitHub CLI (`gh`) installed and authenticated
- Required Go dependencies:
  - `github.com/rs/zerolog`

## Installation

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
go run contributor-fetcher.go StackExchange/dnscontrol
go run contributor-fetcher.go golang/go
```

## Output

Generates a CSV file with naming convention:

```text
<owner>-<repo>-contributors-<YYYYMMDD>.csv
```

### CSV Columns

| Column | Description |
| ------ | ----------- |
| `login` | GitHub username |
| `user_id` | Numeric user ID |
| `avatar_url` | URL to user's avatar image |
| `type` | User type (User, Bot, etc.) |
| `site_admin` | Whether the user is a GitHub site admin |
| `total_commits` | Total number of commits |
| `total_additions` | Total lines added across all commits |
| `total_deletions` | Total lines deleted across all commits |
| `weeks_active` | Number of weeks with at least one commit |
| `rank_by_commits` | Ranking by total commits (1 = most) |
| `rank_by_additions` | Ranking by total additions (1 = most) |
| `rank_by_deletions` | Ranking by total deletions (1 = most) |

### Example Output

```csv
login,user_id,avatar_url,type,site_admin,total_commits,total_additions,total_deletions,weeks_active,rank_by_commits,rank_by_additions,rank_by_deletions
tlimoncelli,6293917,https://avatars.githubusercontent.com/u/6293917,User,false,1466,639219,1483531,302,1,1,1
cafferata,1150425,https://avatars.githubusercontent.com/u/1150425,User,false,214,187338,181396,72,2,2,3
dependabot[bot],49699333,https://avatars.githubusercontent.com/in/29110,Bot,false,134,697,513,82,3,43,23
```

## Logging

Uses structured logging with `zerolog`. Enable JSON logging:

```bash
JSON_LOGS=true go run contributor-fetcher.go owner/repo
```

## GitHub API Notes

Uses the `/repos/{owner}/{repo}/stats/contributors` endpoint:

- First request may take time as GitHub computes statistics
- If API returns 202, data is being computed - retry after a few moments
- Data is cached by GitHub and refreshed periodically

## Converting CSV to SQLite

Use the provided import script:

```bash
./import-to-sqlite.sh <csv-file>
```

This creates a SQLite database with properly typed columns and indexes on commonly queried fields.

## Error Handling

Exits with error if:

- No repository argument provided
- Repository format invalid (must be `owner/repo`)
- GitHub API request fails
- CSV file cannot be written
