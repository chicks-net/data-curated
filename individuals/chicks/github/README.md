# GitHub Data Trackers

This directory contains Go programs for tracking and analyzing GitHub activity
using the GitHub CLI (`gh`) and GraphQL API.

## Programs

### Commit History Tracker (`commit-history.go`)

Fetches individual commit details using the GitHub Search API and stores them
in a SQLite database for analysis. Uses intelligent date-based partitioning to
work around GitHub's 1000-result-per-query limit, allowing complete history
fetching.

**Features:**

- Fetches commit history using the GitHub Search API via `gh` command
- **Date-based partitioning** - fetches commits by year (2008-present)
- **Automatic subdivision** - splits busy periods into quarters or months when needed
- **No 1000 commit limit** - can fetch complete commit history across all years
- Stores commits in a SQLite database
- Extracts and indexes emojis from commit messages
- Avoids API rate limits by using authenticated `gh` CLI
- Handles pagination automatically
- Skips duplicate commits on subsequent runs
- Gracefully handles API errors and continues with remaining periods

**Database:** `commits.db`

**How it works:**

1. Divides history into yearly periods (starting from GitHub's founding in 2008)
2. Fetches each year's commits sequentially (most recent first)
3. If a year has ≥1000 commits, automatically subdivides into quarters
4. If a quarter has ≥1000 commits, further subdivides into months
5. Detects and skips duplicate commits across runs
6. Can be run multiple times to incrementally fetch more history

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
commit details with full metadata (messages, repos, SHAs), `github-contributions.go`
provides aggregated daily contribution counts for all activity types across your
entire GitHub history. Use both together for comprehensive GitHub activity analysis.

### Comment Tracker (`comment-fetcher.go`)

Fetches all comments made on GitHub projects, repositories, and gists using the
GraphQL API. Collects issue comments, commit comments, discussion comments, and
gist comments with full context.

**Features:**

- Fetches all comment types using GitHub GraphQL API
- Stores comments in unified SQLite database with type-specific metadata
- Organization filtering (marks chicks-net/fini-net comments separately)
- Incremental updates (only fetch new/updated comments)
- Handles SAML-protected repositories gracefully
- No pagination limits (fetches complete history)
- Direct URLs to each comment for easy reference

**Database:** `comments.db`

**Comment types tracked:**

- **Issue comments** - Comments on issues and pull requests
- **Commit comments** - Code review comments on commits
- **Discussion comments** - Participation in GitHub Discussions
- **Gist comments** - Comments on public gists

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

### Fetch Comments

```bash
go run comment-fetcher.go
```

Or use the justfile commands from the repository root:

```bash
just fetch-commits        # Fetch commit history (with date partitioning)
just fetch-contributions  # Fetch contribution counts
just fetch-comments       # Fetch comment history
just commit-stats         # Show commit statistics
just contribution-stats   # Show contribution statistics
just comment-stats        # Show comment statistics
just commits-db           # Open commits.db in Datasette
just contributions-db     # Open contributions.db in Datasette
just comments-db          # Open comments.db in Datasette
```

**Note on commit fetching:** The first run fetches recent years (2026, 2025, etc.)
and works backward. If API rate limits are encountered, simply run `just fetch-commits`
again later - it will skip existing commits and continue fetching older history. Run
periodically to keep your database up to date.

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

### Comments Database (`comments.db`)

Created by `comment-fetcher.go`:

```sql
CREATE TABLE comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    comment_id TEXT NOT NULL UNIQUE,
    comment_type TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    body TEXT NOT NULL,
    body_text TEXT,
    repo_full_name TEXT NOT NULL,
    repo_owner TEXT NOT NULL,
    repo_owner_type TEXT NOT NULL,
    issue_number INTEGER,
    issue_title TEXT,
    is_pull_request BOOLEAN,
    commit_oid TEXT,
    discussion_title TEXT,
    gist_id TEXT,
    html_url TEXT NOT NULL,
    fetched_at TEXT NOT NULL,
    is_own_org BOOLEAN NOT NULL DEFAULT 0
);
```

The `is_own_org` flag marks comments on chicks-net/fini-net repositories,
allowing easy filtering for external vs. internal project participation.

Indexes are created on:

- `comment_id` - Fast duplicate checking
- `comment_type` - Filter by comment type
- `created_at` - Time-based queries
- `updated_at` - Incremental update support
- `repo_full_name` - Repository-based queries
- `is_own_org` - Filter external vs. internal
- `(is_own_org, comment_type, created_at)` - Combined filtering

## Performance

### Commit History Fetching

**First run:** Fetches all available commits starting from most recent. Depending
on your commit history size and API rate limits:

- **Small history** (<2000 commits): Completes in 1-2 minutes
- **Medium history** (2000-5000 commits): May take 3-5 minutes
- **Large history** (>5000 commits): May hit API rate limits and require multiple runs

**Subsequent runs:** Very fast - only checks for new commits and skips existing ones.

**API rate limiting:** If you encounter rate limits during a long fetch, the program
will log errors but continue processing other years. Simply run it again after
15-60 minutes to resume fetching the remaining history.

**Current capability:** Successfully tested fetching 1,882 commits across 9 years
(2017-2026) in approximately 30 seconds.

## Viewing the Data

Use Datasette to browse the databases:

```bash
datasette commits.db -o
datasette contributions.db -o
datasette comments.db -o
```

Or query directly with SQLite:

```bash
sqlite3 commits.db "SELECT author_date, repo_full_name, message FROM commits ORDER BY author_date DESC LIMIT 10;"
sqlite3 contributions.db "SELECT date, contribution_count FROM contributions ORDER BY date DESC LIMIT 10;"
sqlite3 comments.db "SELECT comment_type, repo_full_name, created_at FROM comments WHERE is_own_org = 0 ORDER BY created_at DESC LIMIT 10;"
```

## Logging

The program uses structured logging with zerolog:

- Console mode (default): Human-readable output
- JSON mode: Set `JSON_LOGS=true` for machine-readable logs

## Limitations

### Commit History (`commits.db`)

- GitHub Search API returns a maximum of 1000 results **per query** (worked around via date partitioning)
- Only public commits are included in search results
- Private repository commits require appropriate permissions
- API rate limiting may temporarily prevent fetching very old commits (can be resumed later)
- Months with >1000 commits cannot be subdivided further (rare edge case)

### Contributions (`contributions.db`)

- Data starts from account creation date (2011-10-03 for chicks-net)
- Contribution counts may change retroactively as GitHub adjusts metrics
- Private contributions are included in counts but not detailed

## Example Queries

### Comment Queries

#### External comments by type

```sql
SELECT comment_type, COUNT(*) as total_comments
FROM comments
WHERE is_own_org = 0
GROUP BY comment_type
ORDER BY comment_type;
```

#### Most commented external repositories

```sql
SELECT
  repo_full_name,
  COUNT(*) as comment_count,
  MIN(created_at) as first_comment,
  MAX(created_at) as last_comment
FROM comments
WHERE is_own_org = 0
GROUP BY repo_full_name
ORDER BY comment_count DESC
LIMIT 20;
```

#### Comment activity by year

```sql
SELECT
  strftime('%Y', created_at) as year,
  comment_type,
  COUNT(*) as comments
FROM comments
WHERE is_own_org = 0
GROUP BY year, comment_type
ORDER BY year DESC, comment_type;
```

#### Recent external comments

```sql
SELECT
  comment_type,
  repo_full_name,
  COALESCE(issue_title, discussion_title, 'Commit ' || substr(commit_oid, 1, 7)) as context,
  substr(body_text, 1, 100) as preview,
  html_url
FROM comments
WHERE is_own_org = 0
ORDER BY created_at DESC
LIMIT 10;
```

#### Most active discussion participation

```sql
SELECT
  repo_full_name,
  discussion_title,
  COUNT(*) as comment_count,
  MIN(created_at) as first_comment,
  MAX(created_at) as last_comment
FROM comments
WHERE comment_type = 'discussion' AND is_own_org = 0
GROUP BY repo_full_name, discussion_title
ORDER BY comment_count DESC
LIMIT 10;
```

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

### Most active  commit days

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

Example results from a dataset of 1882 commits (as of February 2026):

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

Data is fetched from the GitHub Search API using the `gh api` command with
date-based partitioning to work around the 1000-result-per-query limit:

```bash
# Example: Fetching commits for a specific year
gh api '/search/commits?q=author:USERNAME+author-date:2025-01-01..2025-12-31&sort=author-date&order=desc'
```

The program automatically:

- Divides history into yearly periods (2008-present)
- Fetches each year sequentially with pagination
- Subdivides busy years into quarters (4 periods)
- Further subdivides busy quarters into months (up to 12 periods)
- This allows fetching complete history beyond the 1000-result API limit

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
