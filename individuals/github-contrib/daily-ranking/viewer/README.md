# Daily Ranking Viewer

Interactive TUI (Terminal User Interface) for visualizing daily contributor rankings with animated progress bars.

## Installation

```bash
go build -o daily-ranking-viewer
```

## Usage

The viewer reads NDJSON (newline-delimited JSON) output from the `daily-ranking` tool.

### From stdin

```bash
# Generate and view in one command
daily-ranking /path/to/git/repo | ./daily-ranking-viewer

# Or with just
just daily-ranking /path/to/repo | just daily-ranking-viewer
```

### From file

```bash
# Generate to file first
daily-ranking /path/to/repo rankings.jsonl

# Then view
./daily-ranking-viewer rankings.jsonl
```

### Options

| Flag    | Default | Description                                       |
|---------|---------|---------------------------------------------------|
| `-n`    | 100     | Maximum number of contributors to display         |
| `-speed`| 500ms   | Animation speed (e.g., `200ms`, `1s`)             |

```bash
# Show top 20 contributors
./daily-ranking-viewer -n 20 rankings.jsonl

# Slow animation (1 second per frame)
./daily-ranking-viewer -speed 1s rankings.jsonl

# Fast animation (200ms per frame)
./daily-ranking-viewer -speed 200ms rankings.jsonl
```

The viewer automatically detects terminal size and adjusts:
- Number of rows displayed (based on terminal height)
- Name column width (up to 40 characters)
- Bar width (based on available space)

## Controls

| Key            | Action                 |
|----------------|------------------------|
| `space`        | Pause/play animation   |
| `h` or `←`     | Previous day           |
| `l` or `→`     | Next day               |
| `j` or `↓`     | Slow down animation    |
| `k` or `↑`     | Speed up animation     |
| `r`            | Restart from beginning |
| `q` or `ctrl+c`| Quit                   |

## Features

- Animated progression through daily contributor rankings
- Proportional bars showing relative commit counts
- Highlights contributors with commits on the current day
- Progress bar showing position in the timeline
- Adjustable animation speed
- Full keyboard navigation
- Automatic terminal size detection for optimal display

## Input Format

Expects NDJSON where each line is a JSON object with:

```json
{
  "date": "2024-01-15",
  "contributors": [
    {"login": "alice", "email": "alice@example.com", "cumulative_commits": 150, "commits_today": 5, "rank": 1},
    {"login": "bob", "email": "bob@example.com", "cumulative_commits": 89, "commits_today": 0, "rank": 2}
  ]
}
```

## Dependencies

- [bubbletea](https://github.com/charmbracelet/bubbletea) - TUI framework
- [lipgloss](https://github.com/charmbracelet/lipgloss) - Styling
