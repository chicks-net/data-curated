# GitHub Data Trackers

This directory contains Go programs for tracking and analyzing GitHub activity
using the GitHub CLI (`gh`) and GraphQL API.

## Programs

### Commit History Tracker (`commit-history.go`)

Fetches individual commit details using the GitHub Search API and stores them
in a SQLite database for analysis.

**Features:**

- Fetches commit history using the GitHub Search API via `gh` command
- Stores commits in a SQLite database
- Extracts and indexes emojis from commit messages
- Avoids API rate limits by using authenticated `gh` CLI
- Handles pagination automatically
- Skips duplicate commits on subsequent runs
- Supports up to 1000 most recent commits (GitHub API limitation)

**Database:** `commits.db`

### Contributions Tracker (`github-contributions.go`)

Fetches daily contribution counts from GitHub's contribution calendar using the
GraphQL API. Provides complete historical data from account creation (2011-10-03)
to present.

**Features:**

- Fetches complete contribution history using GitHub GraphQL API
- Stores daily contribution counts in SQLite database
- Year-by-year fetching strategy (efficient and resumable)
- Incremental updates (only fetch recent data on subsequent runs)
- Includes all contribution types (commits, PRs, issues, reviews)
- No pagination needed - complete data in ~15 API requests

**Database:** `contributions.db`

**Complementary to commit-history:** While `commit-history.go` tracks individual
commit details (limited to 1000 results), `github-contributions.go` provides
aggregated daily contribution counts for all activity types across your entire
GitHub history.

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

### Fetch Commit History

```bash
go run commit-history.go
```

### Fetch Contribution Counts

```bash
go run github-contributions.go
```

Or use the justfile commands from the repository root:

```bash
just fetch-commits        # Fetch commit history
just fetch-contributions  # Fetch contribution counts
just commit-stats         # Show commit statistics
just contribution-stats   # Show contribution statistics
just commits-db          # Open commits.db in Datasette
just contributions-db    # Open contributions.db in Datasette
```

## Database Schemas

### Commits Database (`commits.db`)

Created by `commit-history.go`:

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
    emoji TEXT,
    repo_name TEXT NOT NULL,
    repo_full_name TEXT NOT NULL,
    html_url TEXT NOT NULL,
    fetched_at TEXT NOT NULL
);
```

The `emoji` column contains the first emoji extracted from the commit message,
making it easy to analyze commit categorization patterns.

Indexes are created on:

- `sha` - Fast duplicate checking
- `author_date` - Time-based queries
- `repo_full_name` - Repository-based queries
- `author_email` - Author-based queries
- `fetched_at` - Track when data was collected
- `emoji` - Emoji-based filtering and grouping

### Contributions Database (`contributions.db`)

Created by `github-contributions.go`:

```sql
CREATE TABLE contributions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT NOT NULL,
    contribution_count INTEGER NOT NULL,
    fetched_at TEXT NOT NULL,
    UNIQUE(date, fetched_at)
);
```

The `UNIQUE(date, fetched_at)` constraint allows tracking how contribution counts
change over time (GitHub may retroactively adjust counts).

Indexes are created on:

- `date` - Fast date-based queries
- `fetched_at` - Track when data was collected
- `contribution_count` - Filter by activity level

## Viewing the Data

Use Datasette to browse the databases:

```bash
datasette commits.db -o
datasette contributions.db -o
```

Or query directly with SQLite:

```bash
sqlite3 commits.db "SELECT author_date, repo_full_name, message FROM commits ORDER BY author_date DESC LIMIT 10;"
sqlite3 contributions.db "SELECT date, contribution_count FROM contributions ORDER BY date DESC LIMIT 10;"
```

## Logging

The program uses structured logging with zerolog:

- Console mode (default): Human-readable output
- JSON mode: Set `JSON_LOGS=true` for machine-readable logs

## Limitations

### Commit History (`commits.db`)

- GitHub Search API returns a maximum of 1000 results
- Only public commits are included in search results
- Private repository commits require appropriate permissions

### Contributions (`contributions.db`)

- Data starts from account creation date (2011-10-03 for chicks-net)
- Contribution counts may change retroactively as GitHub adjusts metrics
- Private contributions are included in counts but not detailed

## Example Queries

### Contributions Queries

#### Total contributions over time

```sql
SELECT
  strftime('%Y', date) as year,
  SUM(contribution_count) as total_contributions
FROM contributions
GROUP BY year
ORDER BY year DESC;
```

#### Most active days

```sql
SELECT date, contribution_count
FROM contributions
ORDER BY contribution_count DESC
LIMIT 20;
```

#### Average contributions by day of week

```sql
SELECT
  CASE CAST(strftime('%w', date) AS INTEGER)
    WHEN 0 THEN 'Sunday'
    WHEN 1 THEN 'Monday'
    WHEN 2 THEN 'Tuesday'
    WHEN 3 THEN 'Wednesday'
    WHEN 4 THEN 'Thursday'
    WHEN 5 THEN 'Friday'
    WHEN 6 THEN 'Saturday'
  END as day_of_week,
  ROUND(AVG(contribution_count), 2) as avg_contributions,
  COUNT(*) as total_days
FROM contributions
GROUP BY strftime('%w', date)
ORDER BY CAST(strftime('%w', date) AS INTEGER);
```

#### Contribution streaks

```sql
WITH distinct_days AS (
  SELECT DISTINCT date
  FROM contributions
  WHERE contribution_count > 0
  ORDER BY date
),
gaps AS (
  SELECT
    date,
    LAG(date) OVER (ORDER BY date) as prev_date,
    CASE
      WHEN julianday(date) - julianday(LAG(date) OVER (ORDER BY date)) = 1 THEN 0
      ELSE 1
    END as is_new_streak
  FROM distinct_days
),
streak_groups AS (
  SELECT
    date,
    SUM(is_new_streak) OVER (ORDER BY date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as streak_id
  FROM gaps
)
SELECT
  MIN(date) as streak_start,
  MAX(date) as streak_end,
  COUNT(*) as days
FROM streak_groups
GROUP BY streak_id
HAVING COUNT(*) > 1
ORDER BY days DESC
LIMIT 10;
```

#### Monthly contribution summary

```sql
SELECT
  strftime('%Y-%m', date) as month,
  SUM(contribution_count) as total,
  ROUND(AVG(contribution_count), 1) as daily_avg,
  MAX(contribution_count) as peak_day,
  COUNT(DISTINCT CASE WHEN contribution_count > 0 THEN date END) as active_days,
  COUNT(DISTINCT CASE WHEN contribution_count = 0 THEN date END) as inactive_days
FROM contributions
GROUP BY month
ORDER BY month DESC
LIMIT 12;
```

### Commit History Queries

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

### Commits by emoji

```sql
SELECT emoji, COUNT(*) as count
FROM commits
WHERE LENGTH(emoji) > 0
GROUP BY emoji
ORDER BY count DESC;
```

### Most popular emojis with percentages

```sql
SELECT
  emoji,
  COUNT(*) as count,
  ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM commits WHERE LENGTH(emoji) > 0), 1) as percentage
FROM commits
WHERE LENGTH(emoji) > 0
GROUP BY emoji
ORDER BY count DESC
LIMIT 20;
```

Example results from a dataset of 999 commits (898 with emojis):

|emoji|count|percentage|
|-----|-----|----------|
|🧼|24|2.7|
|🐈|19|2.1|
|📚|11|1.2|
|📖|10|1.1|
|📓|9|1.0|
|🧹|9|1.0|
|✅|8|0.9|
|📃|8|0.9|
|🧑|8|0.9|
|🪨|8|0.9|
|📒|7|0.8|
|📛|7|0.8|
|🛝|7|0.8|
|🧰|7|0.8|
|🌀|6|0.7|
|👔|6|0.7|
|📊|6|0.7|
|📗|6|0.7|
|🔬|6|0.7|
|🚚|6|0.7|

### Recent commits with emojis

```sql
SELECT emoji, substr(message, 1, 60) as message_preview, repo_full_name
FROM commits
WHERE LENGTH(emoji) > 0
ORDER BY author_date DESC
LIMIT 10;
```

### Emoji usage over time

```sql
SELECT strftime('%Y-%m', author_date) as month, emoji, COUNT(*) as count
FROM commits
WHERE LENGTH(emoji) > 0
GROUP BY month, emoji
ORDER BY month DESC, count DESC;
```

## Data Sources

### Commit History

Data is fetched from the GitHub Search API using the `gh api` command:

```bash
gh api '/search/commits?q=author:USERNAME&sort=author-date&order=desc'
```

### Contributions

Data is fetched from the GitHub GraphQL API using the `gh api graphql` command:

```bash
gh api graphql -f query='
  query {
    user(login: "USERNAME") {
      contributionsCollection(from: "2011-10-03T00:00:00Z", to: "2026-01-23T23:59:59Z") {
        contributionCalendar {
          totalContributions
          weeks {
            contributionDays {
              date
              contributionCount
            }
          }
        }
      }
    }
  }
'
```

Both approaches use your authenticated GitHub CLI session, avoiding rate limits
that would affect unauthenticated API requests.
