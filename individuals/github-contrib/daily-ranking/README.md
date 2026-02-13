# Daily Contributor Rankings

Generates daily contributor rankings from a git repository's commit history.
Useful for creating visualizations like contribution race charts or analyzing
contributor activity patterns over time.

## Output Format

Produces NDJSON (newline-delimited JSON) where each line represents a day with
all contributors ranked by cumulative commits:

```json
{
  "date": "2017-03-14",
  "contributors": [
    {"login": "Alice", "email": "alice@example.com", "cumulative_commits": 61, "commits_today": 15, "rank": 1},
    {"login": "Bob", "email": "bob@example.com", "cumulative_commits": 9, "commits_today": 3, "rank": 2}
  ]
}
```

Each contributor entry includes:

- `login` - Author name from git
- `email` - Author email (used as unique identifier)
- `cumulative_commits` - Total commits up to and including this date
- `commits_today` - Commits made on this specific date
- `rank` - Position in the leaderboard (1 = top contributor)

## Usage

### With just (recommended)

```bash
# Output to stdout
just daily-ranking /path/to/git/repo

# Write to file
just daily-ranking /path/to/git/repo output.jsonl
```

### Direct execution

```bash
# Build
go build -o daily-ranking

# Output to stdout
./daily-ranking /path/to/git/repo

# Write to file
./daily-ranking /path/to/git/repo output.jsonl
```

## Use Cases

- Generate race chart animations showing contributor leaderboard changes
- Analyze contributor growth patterns over time
- Identify when contributors became active or inactive
- Track project velocity by commit velocity per contributor