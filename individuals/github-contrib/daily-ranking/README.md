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
  "origin": "https://github.com/owner/repo.git",
  "contributors": [
    {"login": "Alice", "cumulative_commits": 61, "commits_today": 15, "rank": 1},
    {"login": "Bob", "cumulative_commits": 9, "commits_today": 3, "rank": 2}
  ]
}
```

Each day's output includes:

- `date` - The date in YYYY-MM-DD format
- `origin` - Git remote origin URL (empty string if not available)
- `contributors` - Array of contributor entries for that day

Each contributor entry includes:

- `login` - Author name from git (uses the most recent name for merged identities)
- `cumulative_commits` - Total commits up to and including this date
- `commits_today` - Commits made on this specific date
- `rank` - Position in the leaderboard (1 = top contributor)

## Identity Resolution

Contributors are identified by merging commits that share either a name OR an
email address. This handles two common scenarios:

1. **Multiple email addresses**: A contributor using different emails for work
   and personal commits will be correctly merged into a single identity.

2. **Name changes**: When a contributor changes their name, all commits are
   merged under a single identity using the most recent name.

For example, if "Alice" commits with `alice@work.com` and later as "Alice Smith"
with `alice@personal.com`, all commits are merged and displayed under
"Alice Smith" (the most recent name).

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

# Output to stdout (all branches)
./daily-ranking /path/to/git/repo

# Analyze a specific branch only (e.g., main)
./daily-ranking -branch main /path/to/git/repo

# Limit to top 50 contributors (default is 100)
./daily-ranking -top 50 /path/to/git/repo

# Write to file
./daily-ranking /path/to/git/repo output.jsonl
```

## Viewer

The `viewer/` directory contains an interactive TUI (Terminal User Interface)
for visualizing the daily rankings data with animated progress bars.

### Viewer Usage

```bash
# Build the viewer
cd viewer && go build -o daily-ranking-viewer

# View from stdin
./daily-ranking /path/to/repo | ./viewer/daily-ranking-viewer

# View from file
./daily-ranking /path/to/repo output.jsonl
./viewer/daily-ranking-viewer output.jsonl

# Options
./viewer/daily-ranking-viewer -n 20 output.jsonl      # Show top 20 contributors
./viewer/daily-ranking-viewer -speed 1s output.jsonl  # 1 second per frame
```

### Viewer Controls

| Key      | Action                 |
|----------|------------------------|
| `space`  | Pause/play animation   |
| `h`/`←`  | Previous day           |
| `l`/`→`  | Next day               |
| `j`/`↓`  | Slow down              |
| `k`/`↑`  | Speed up               |
| `r`      | Restart from beginning |
| `q`      | Quit                   |

### Viewer Features

- Animated progression through daily rankings
- Proportional bars showing relative contribution counts
- Highlights contributors with commits on current day
- Progress bar showing position in timeline
- Adjustable animation speed

## Use Cases

- Generate race chart animations showing contributor leaderboard changes
- Analyze contributor growth patterns over time
- Identify when contributors became active or inactive
- Track project velocity by commit velocity per contributor
