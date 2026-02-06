# Claude Code Usage Tracker

This directory contains tools for tracking and analyzing Claude Code token usage
over time using the `ccusage` command-line tool.

## Overview

The `fetch-usage.go` program fetches usage data from `ccusage` and stores it in
a local SQLite database for historical tracking and analysis.

## Database Schema

### `daily_usage` table

Daily aggregated token usage across all sessions:

- `date` (TEXT, PRIMARY KEY) - Date in YYYY-MM-DD format
- `input_tokens` (INTEGER) - Total input tokens
- `output_tokens` (INTEGER) - Total output tokens
- `cache_creation_tokens` (INTEGER) - Tokens written to cache
- `cache_read_tokens` (INTEGER) - Tokens read from cache
- `total_tokens` (INTEGER) - Sum of all token types
- `total_cost` (REAL) - Total cost in USD
- `models_used` (TEXT) - JSON array of model names
- `fetched_at` (TEXT) - Timestamp when data was fetched

### `model_breakdown` table

Per-model usage breakdown by date:

- `date` (TEXT) - Date in YYYY-MM-DD format
- `model_name` (TEXT) - Full model identifier (e.g., claude-sonnet-4-5-20250929)
- `input_tokens` (INTEGER) - Input tokens for this model
- `output_tokens` (INTEGER) - Output tokens for this model
- `cache_creation_tokens` (INTEGER) - Cache creation tokens
- `cache_read_tokens` (INTEGER) - Cache read tokens
- `cost` (REAL) - Cost in USD for this model
- `fetched_at` (TEXT) - Timestamp when data was fetched

Primary key: `(date, model_name)`

### `session_usage` table

Usage by conversation session (project):

- `session_id` (TEXT, PRIMARY KEY) - Session identifier
- `input_tokens` (INTEGER) - Total input tokens
- `output_tokens` (INTEGER) - Total output tokens
- `cache_creation_tokens` (INTEGER) - Cache creation tokens
- `cache_read_tokens` (INTEGER) - Cache read tokens
- `total_tokens` (INTEGER) - Total tokens across all types
- `total_cost` (REAL) - Total cost in USD
- `last_activity` (TEXT) - Date of last activity (YYYY-MM-DD)
- `models_used` (TEXT) - JSON array of model names
- `project_path` (TEXT) - Project path or "Unknown Project"
- `fetched_at` (TEXT) - Timestamp when data was fetched

## Usage

### Prerequisites

- Go 1.20 or later
- `ccusage` command-line tool (installed with Claude Code)
- SQLite3

### Fetch Usage Data

Run from the repository root:

```bash
just fetch-ccusage
```

Or manually:

```bash
cd individuals/chicks/ccusage
go run fetch-usage.go
```

### View Data in Browser

```bash
just ccusage-db
```

This opens the database in Datasette for interactive exploration.

### Query Examples

**Daily usage over last 7 days:**

```sql
SELECT date, total_tokens, total_cost
FROM daily_usage
WHERE date >= date('now', '-7 days')
ORDER BY date DESC;
```

**Total cost by model:**

```sql
SELECT model_name, SUM(cost) as total_cost, SUM(input_tokens + output_tokens) as direct_tokens
FROM model_breakdown
GROUP BY model_name
ORDER BY total_cost DESC;
```

**Most expensive sessions:**

```sql
SELECT session_id, total_cost, total_tokens, last_activity
FROM session_usage
ORDER BY total_cost DESC
LIMIT 10;
```

**Daily cost trend:**

```sql
SELECT date, total_cost,
  SUM(total_cost) OVER (ORDER BY date) as cumulative_cost
FROM daily_usage
ORDER BY date DESC;
```

## Data Source

Data is fetched from the `ccusage` command-line tool which reads Claude Code's
usage logs. The tool provides:

- **Daily aggregates**: Token usage grouped by date
- **Session breakouts**: Usage per conversation/project
- **Model breakdowns**: Per-model usage and costs

## Notes

- The database is stored at `individuals/chicks/ccusage/usage.db`
- Data is upserted on each run, so running multiple times is safe
- Historical data depends on Claude Code's log retention
- Cache tokens (creation and read) are separate from input/output tokens
- Model names follow the format: `claude-{model}-{version}-{date}`

## Related Commands

From repository root:

- `just fetch-ccusage` - Fetch latest usage data
- `just ccusage-db` - Open database in Datasette
- `just ccusage-stats` - Show summary statistics
