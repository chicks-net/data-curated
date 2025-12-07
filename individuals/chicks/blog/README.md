# Blog Post Counter

A Go program that counts the number of blog posts per month from
[chicks.net/posts](https://www.chicks.net/posts/).

## Usage

```bash
go run post-counter.go
```

## What It Does

The program:

1. Fetches the blog posts page from `https://www.chicks.net/posts/`
2. Follows pagination links (if present) to gather all posts
3. Parses post dates using regex pattern matching
4. Groups posts by month (YYYY-MM format)
5. Displays count of posts per month in chronological order

## Output Format

```text
Posts per Month:
================
2025-05: 1
2025-06: 2
2025-08: 1
================
Total Posts: 10
```

## Implementation Details

- Uses standard library only (no external dependencies)
- Parses dates in format: "Month Day, Year" (e.g., "November 20, 2025")
- Automatically handles pagination by following "Next »" links
- Tracks visited URLs to avoid infinite loops
- Outputs results sorted chronologically by month
