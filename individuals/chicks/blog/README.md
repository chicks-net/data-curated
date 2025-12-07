# Blog Post Counter

A Go program that counts the number of blog posts per month from
[chicks.net/posts](https://www.chicks.net/posts/).

## Usage

### Direct execution

```bash
go run post-counter.go
```

### Using just

From the repository root:

```bash
just count-posts
```

## What It Does

The program:

1. Fetches the blog posts page from `https://www.chicks.net/posts/`
2. Follows pagination links to gather all posts across multiple pages
3. Parses post dates using regex pattern matching
4. Groups posts by month (YYYY-MM format)
5. Writes results to CSV file named `blog-monthly-YYYYMMDD.csv`
6. Displays count of posts per month in chronological order

## Output Format

### Console Output

```text
Posts per Month:
================
2025-05: 1
2025-06: 2
2025-08: 1
================
Total Posts: 10

Results written to: blog-monthly-20251207.csv
```

### CSV Output

The program creates a CSV file with the naming pattern `blog-monthly-YYYYMMDD.csv`
where YYYYMMDD is today's date. The CSV contains:

- Header row: `Month,Count`
- Data rows: Month in YYYY-MM format, post count for that month
- Sorted chronologically by month

## Implementation Details

- Uses standard library only (no external dependencies)
- Parses dates in format: "Month Day, Year" (e.g., "November 20, 2025")
- Automatically handles pagination by following "Next »" links
- Tracks visited URLs to avoid infinite loops
- Outputs results sorted chronologically by month
