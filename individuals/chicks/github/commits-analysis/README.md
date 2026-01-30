# Commits by Hour Analysis

This directory contains R scripts and results for analyzing GitHub commit
patterns by hour of the day.

**Important:** All hours in this analysis are shown in **commit authors' local
timezones**. The original commit data spans multiple timezones and is analyzed
as-is to preserve the actual patterns of when people commit in their local
time.

## Files

- `analyze-commits-by-hour.R` - Main R analysis script
- `commits-by-hour.png` - Bar chart showing commit frequency by hour (local time)
- `commits-by-time-period.png` - Grouped by morning/afternoon/evening/night (local time)
- `hourly-commit-distribution.csv` - Raw hourly data (local time)
- `time-period-distribution.csv` - Time period aggregated data (local time)
- `timezone-distribution.csv` - Original timezone distribution of commits

## Running the Analysis

Ensure R dependencies are installed:

```bash
just install-r-deps
```

Then run the analysis:

```bash
cd individuals/chicks/github/commits-analysis
Rscript analyze-commits-by-hour.R
```

## Data Source

Analysis uses the `commits.db` SQLite database containing up to 1000 most
recent GitHub commits, fetched via the GitHub Search API.
