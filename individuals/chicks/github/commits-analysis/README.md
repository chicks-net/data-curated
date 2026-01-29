# Commits by Hour Analysis

This directory contains R scripts and results for analyzing GitHub commit patterns by hour of the day.

**Important:** All hours in this analysis are shown in **commit authors' local timezones**. The original commit data spans multiple timezones and is analyzed as-is to preserve the actual patterns of when people commit in their local time.

## Files

- `analyze-commits-by-hour.R` - Main R analysis script
- `commits-by-hour.png` - Bar chart showing commit frequency by hour (local time)
- `commits-by-hour-percentage.png` - Percentage chart of commits by hour (local time)
- `commits-by-time-period.png` - Grouped by morning/afternoon/evening/night (local time)
- `hourly-commit-distribution.csv` - Raw hourly data (local time)
- `time-period-distribution.csv` - Time period aggregated data (local time)
- `timezone-distribution.csv` - Original timezone distribution of commits

## Key Findings

Based on analysis of 999 commits (all times in **UTC**):

**Timezone Distribution (original):**
- PDT (-07:00): 56.1% of commits
- EDT (-04:00): 18.0% of commits  
- CDT (-05:00): 14.2% of commits
- MDT (-08:00): 11.2% of commits
- MDT (-06:00): 0.4% of commits

**Peak Hours (Local Time):**
- 2:00 PM (14:00): 110 commits (11.0%)
- 1:00 PM (13:00): 106 commits (10.6%) 
- 2:00 AM (02:00): 82 commits (8.2%)

**Time Period Distribution (Local Time):**
- Afternoon (12pm-6pm): 45.1% of commits
- Night (12am-6am): 25.4% of commits
- Evening (6pm-12am): 22.0% of commits
- Morning (6am-12pm): 7.4% of commits

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

Analysis uses the `commits.db` SQLite database containing up to 1000 most recent GitHub commits, fetched via the GitHub Search API.