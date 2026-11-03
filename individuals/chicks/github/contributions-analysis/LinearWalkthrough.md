# Linear Walkthrough: analyze-contributions.R

A step-by-step explanation of how this R script analyzes GitHub contribution data and produces three visualization graphs.

---

## 1. Library Loading (lines 6-16)

```r
library(DBI)
library(RSQLite)
library(ggplot2)
library(dplyr)
library(zoo)
library(lubridate)
library(scales)
library(png)
library(jpeg)
library(grid)
```

| Library | Purpose |
| ------- | ------- |
| **DBI / RSQLite** | Database interface for connecting to SQLite databases and executing queries |
| **ggplot2** | Grammar of graphics for building layered visualizations |
| **dplyr** | Data manipulation (filter, mutate, summarize, arrange) |
| **zoo** | Rolling average calculations with `rollmean()` |
| **lubridate** | Date parsing and manipulation (floor_date, days_in_month) |
| **scales** | Axis formatting (big.mark for thousands separators) |
| **png / jpeg** | Reading logo image files for employment period annotations |
| **grid** | Graphics utilities for embedding images (rasterGrob) |

---

## 2. Database Connection & Data Loading (lines 18-40)

```r
db_path <- "../contributions.db"

# Projection settings for the current month's grey cap
first_week_days <- 7        # days 1-7 project from a trailing pace
trailing_window_days <- 10  # size of the trailing pace window
projection_bar_width <- 25  # grey cap width in days (approximately one month)

cat("Connecting to database:", db_path, "\n")
con <- dbConnect(SQLite(), db_path)

contributions <- dbGetQuery(con, "
  SELECT date, contribution_count
  FROM contributions
  WHERE fetched_at = (
    SELECT MAX(fetched_at)
    FROM contributions c2
    WHERE c2.date = contributions.date
  )
  ORDER BY date
")
```

**Why this SQL pattern?**

The `WHERE fetched_at = (SELECT MAX(fetched_at)...)` subquery handles incremental data collection. Each time `github-contributions.go` runs, it stamps records with a `fetched_at` timestamp. If you re-run the fetch (maybe the script crashed), you'll have duplicate dates with different `fetched_at` values. This subquery ensures you get only the most recent count for each date.

**Why the relative path?** The script assumes it's run from the `contributions-analysis/` directory, so `../contributions.db` correctly resolves to `individuals/chicks/github/contributions.db`.

**Projection tunables:** The three constants next to the path configure the current-month projection (see section 9): `first_week_days` is how many days count as the "first week" (where the projection uses a trailing pace), `trailing_window_days` is the size of that pace window, and `projection_bar_width` is the width of the grey cap rectangle.

---

## 3. Database Metadata & Timestamp Formatting (lines 42-47)

```r
last_updated <- dbGetQuery(con, "SELECT MAX(fetched_at) as last_updated FROM contributions")$last_updated
last_updated_formatted <- format(as.POSIXct(last_updated, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), 
                                  "%Y-%m-%d %H:%M:%S %Z", tz = "UTC")

dbDisconnect(con)
```

**ISO 8601 parsing:** GitHub's GraphQL API returns timestamps in ISO 8601 format (e.g., `2026-02-05T14:28:07Z`). The `Z` suffix indicates UTC timezone. We parse it as UTC and format it for the plot captions.

**Why capture this?** The caption on each graph shows when the database was last updated, giving context for how current the data is.

---

## 4. Running Average Calculations (lines 51-63)

```r
contributions$date <- as.Date(contributions$date)

contributions <- contributions %>%
  arrange(date) %>%
  mutate(
    avg_14day = rollmean(contribution_count, k=14, fill=NA, align="right"),
    avg_30day = rollmean(contribution_count, k=30, fill=NA, align="right"),
    avg_90day = rollmean(contribution_count, k=90, fill=NA, align="right")
  )
```

**Why `align="right"`?** This means each average point includes the current day plus the previous N-1 days. So the 14-day average at day X is the average of days X-13 through X. This keeps the trend line current rather than shifted into the future (which would happen with `align="center"`).

**Why `fill=NA`?** For the first 13 days, there aren't enough prior days to calculate a 14-day average. `fill=NA` produces `NA` values for those positions, which ggplot handles gracefully by simply not drawing points.

**Why these windows?**

- **14-day** ≈ 2 weeks (short-term variation)
- **30-day** ≈ 1 month (typical work cycle)
- **90-day** ≈ 1 quarter (seasonal/project patterns)

---

## 5. Summary Statistics Output (lines 65-85)

```r
cat("=== SUMMARY STATISTICS ===\n\n")
cat("Date range:", min(contributions$date), "to", max(contributions$date), "\n")
cat("Total days:", nrow(contributions), "\n")
total_contributions <- sum(contributions$contribution_count)
cat("Total contributions:", total_contributions, "\n")
cat("Average contributions per day:", round(mean(contributions$contribution_count), 2), "\n")
cat("Median contributions per day:", median(contributions$contribution_count), "\n")
cat("Max contributions in a day:", max(contributions$contribution_count), "\n")
cat("Days with no contributions:", sum(contributions$contribution_count == 0), "\n")
cat("Days with contributions:", sum(contributions$contribution_count > 0), "\n\n")
```

**Key metrics explained:**

- **Median vs. mean:** Median is often 0 because most days have no commits (nights, weekends, vacations). Mean tells you the average "when active" rate.
- **Days with no contributions:** Important for understanding activity patterns—GitHub streaks are visible in this metric.

---

## 6. First Plot: Two-Year Timeline (lines 87-153)

```r
plot_start <- max(min(contributions$date), Sys.Date() - 730)
plot_data <- contributions %>% filter(date >= plot_start)
plot_total_contributions <- sum(plot_data$contribution_count)

today <- Sys.Date()
points_data <- plot_data %>% filter(!(date == today & contribution_count == 0))

p <- ggplot(plot_data, aes(x = date)) +
  geom_point(data = points_data,
              aes(y = contribution_count),
              alpha = 0.3,
              size = 1,
              color = "gray50") +
  geom_line(aes(y = avg_14day, color = "14-day average"), linewidth = 0.5) +
  geom_line(aes(y = avg_30day, color = "30-day average"), linewidth = 0.8) +
  geom_line(aes(y = avg_90day, color = "90-day average"), linewidth = 0.8) +
  scale_color_manual(
    name = "Moving Averages",
    values = c(
      "14-day average" = "#2E86AB",
      "30-day average" = "#A23B72",
      "90-day average" = "#F18F01"
    )
  ) +
  labs(
    title = "GitHub Contributions Over The Last Two Years For 'chicks-net'",
    subtitle = paste("Daily contributions with running averages"),
    x = "Date",
    y = "Contributions per Day",
    caption = paste0("Total contributions (last 2 years): ", 
                      format(plot_total_contributions, big.mark = ","), 
                      " | Database last updated: ", last_updated_formatted)
  ) +
  theme_minimal() +
  scale_x_date(date_breaks = "3 months", date_labels = "%b %Y")
```

**Why drop today when it's quiet?** A zero for today usually means the day just isn't over yet, so that point is excluded from the daily scatter rather than drawn as a misleading zero. (The running-average lines still include it.)

**Layer ordering matters:** Points are drawn first (layered behind the lines), making the trend lines more prominent.

**Transparency (`alpha`):** Daily points are semi-transparent so you can see density when multiple points overlap.

**Line thickness hierarchy:** Shorter averaging windows use thinner lines because they're noisier—you want the 90-day trend (thicker) to draw the eye as the primary trend.

**Color palette:**

| Average | Color | Hex |
| ------- | ----- | --- |
| 14-day | Blue | `#2E86AB` |
| 30-day | Purple | `#A23B72` |
| 90-day | Orange | `#F18F01` |

### Milestone Annotations (lines 141-153)

```r
geom_vline(xintercept = as.Date("2025-03-10"), linetype = "dashed", color = "red", alpha = 0.6) +
geom_vline(xintercept = as.Date("2025-08-29"), linetype = "dashed", color = "red", alpha = 0.6) +
geom_vline(xintercept = as.Date("2026-09-04"), linetype = "dashed", color = "red", alpha = 0.6) +
annotate("text", x = as.Date("2025-03-10"), y = max(plot_data$contribution_count, na.rm = TRUE) * 0.95,
          label = "commitment to daily github", angle = 90, hjust = 1, vjust = -0.3,
          size = 3, color = "red", alpha = 0.7) +
annotate("text", x = as.Date("2025-08-29"), y = max(plot_data$contribution_count, na.rm = TRUE) * 0.85,
          label = "started using Claude Code", angle = 90, hjust = 1, vjust = -0.3,
          size = 3, color = "red", alpha = 0.7) +
annotate("text", x = as.Date("2026-09-04"), y = max(plot_data$contribution_count, na.rm = TRUE) * 0.75,
          label = "last day at Tubi", angle = 90, hjust = 1, vjust = -0.3,
          size = 3, color = "red", alpha = 0.7)
```

These vertical lines mark significant changes in contribution behavior. The text is rotated 90° so it fits alongside the line without overlapping the data.

---

## 7. Job History Loading & Processing (lines 179-207)

```r
jobs_csv <- "../../jobs/job_history.csv"
jobs <- read.csv(jobs_csv, stringsAsFactors = FALSE)
jobs$start_date <- as.Date(jobs$Start.Date)
jobs$end_date <- ifelse(jobs$End.Date == "",
                        as.character(Sys.Date()),
                        jobs$End.Date)
jobs$end_date <- as.Date(jobs$end_date)

jobs <- jobs %>%
  group_by(Company) %>%
  summarize(
    start_date = min(start_date),
    end_date = max(end_date),
    .groups = "drop"
  )
```

**Why merge roles at same company?** The `job_history.csv` may have multiple roles at one company (e.g., "Software Engineer" then "Senior Engineer"). For visualization purposes, we want to show one continuous employment period per company, so we merge consecutive roles by taking the earliest start and latest end.

**Handling current employment:** If `End.Date` is empty, it means the job is current, so we fill with `Sys.Date()`.

### Logo Handling (lines 209-227)

```r
logos_dir <- "../../jobs/"
logo_files <- list(
  "OpenX" = file.path(logos_dir, "openx-logo.png"),
  "Telmate" = file.path(logos_dir, "telmate-logo-transparent.png"),
  "Tubi" = file.path(logos_dir, "Tubi_logo_2024_purple.png")
)
logos <- list()
for (company in names(logo_files)) {
  if (file.exists(logo_files[[company]])) {
    ext <- tolower(tools::file_ext(logo_files[[company]]))
    if (ext == "jpg" || ext == "jpeg") {
      logos[[company]] <- readJPEG(logo_files[[company]])
    } else if (ext == "png") {
      logos[[company]] <- readPNG(logo_files[[company]])
    }
  }
}
jobs_filtered$has_logo <- jobs_filtered$Company %in% names(logos)
```

**Logo vs. text strategy:** Some companies have logo files; others will just have text labels. We check for file existence and extension type, then flag which companies have logos available.

---

## 8. Second Plot: Weekly Aggregation (lines 163-327)

```r
weekly_data <- contributions %>%
  mutate(week = floor_date(date, "week")) %>%
  group_by(week) %>%
  summarize(
    contributions = sum(contribution_count),
    avg_per_day = mean(contribution_count),
    .groups = "drop"
  ) %>%
  arrange(week) %>%
  mutate(
    avg_4week = rollmean(avg_per_day, k=4, fill=NA, align="right"),
    avg_13week = rollmean(avg_per_day, k=13, fill=NA, align="right"),
    avg_26week = rollmean(avg_per_day, k=26, fill=NA, align="right")
  )
```

**Why aggregate by week?** Daily data over 14+ years (5000+ points) would be unreadable. Weekly aggregation compresses this to ~700 points, showing the overall arc of activity over time.

**Why calculate average per day?** The running averages are based on daily averages within weeks, then multiplied by 7 when plotting to show "contributions per week" on the y-axis.

### Employment Period Overlays (lines 229-249)

```r
geom_rect(data = jobs_filtered,
          aes(xmin = start_date, xmax = end_date,
              ymin = -Inf, ymax = Inf,
              fill = fill_color),
          alpha = 0.20,
          inherit.aes = FALSE) +
scale_fill_identity() +
geom_text(data = subset(jobs_filtered, !has_logo),
          aes(x = midpoint,
              y = max(weekly_data$contributions, na.rm = TRUE) * 0.95,
              label = Company),
          angle = 90,
          vjust = 0.5,
          hjust = 1,
          size = 2.875,
          color = "gray30",
          alpha = 0.6,
          inherit.aes = FALSE)
```

**Layer ordering is critical:** Employment rectangles are drawn first, appearing behind all data. Text labels for companies without logos sit on top.

**Alternating colors:** The `fill_color` column uses modulo arithmetic to alternate between two muted colors (`#7B9FCC` and `#C8BFB0`), making adjacent employment periods visually distinct.

### Logo Placement (lines 251-283)

```r
plot_max_y <- max(weekly_data$contributions, na.rm = TRUE)
for (company in names(logos)) {
  job_row <- jobs_filtered[jobs_filtered$Company == company, ]
  if (nrow(job_row) > 0) {
    img <- logos[[company]]
    img_grob <- rasterGrob(img, interpolate = TRUE)
    x_pos <- job_row$midpoint
    # Telmate logo is smaller and needs label
    if (company == "Telmate") {
      logo_height <- plot_max_y * 0.24
      logo_y <- plot_max_y * 0.92
    } else {
      logo_height <- plot_max_y * 0.20
      logo_y <- plot_max_y * 0.90
    }
    p2 <- p2 + annotation_custom(img_grob,
                                  xmin = x_pos - 120, xmax = x_pos + 120,
                                  ymin = logo_y - logo_height, ymax = logo_y)
  }
}
```

**Why different logo sizes?** The Telmate logo is scaled to 24% of the plot height and gets an extra "Telmate" text annotation above it; the other logos use 20%. The `xmin/xmax` spans 240 days of width (±120 from the employment-period midpoint). The same placement code is repeated for the monthly plot (`p3`), scaled to that plot's maximum.

---

## 9. Third Plot: Monthly Aggregation (lines 329-513)

```r
monthly_data <- contributions %>%
  mutate(month = floor_date(date, "month")) %>%
  group_by(month) %>%
  summarize(
    contributions = sum(contribution_count),
    avg_per_day = mean(contribution_count),
    active_days = sum(contribution_count > 0),
    .groups = "drop"
  ) %>%
  arrange(month) %>%
  mutate(
    avg_6month = rollmean(contributions, k=6, fill=NA, align="right"),
    avg_12month = rollmean(contributions, k=12, fill=NA, align="right")
  )
```

**Additional metric:** `active_days` counts how many days in each month had at least one contribution, useful for streak analysis.

**Why 6 and 12-month windows?** Monthly data is smoother than daily, so longer averaging windows make more sense. These show semi-annual and annual trends.

### Moving Averages for Last Month (lines 347-351)

```r
mutate(
  avg_6month = ifelse(month == max(month), NA, avg_6month),
  avg_12month = ifelse(month == max(month), NA, avg_12month)
)
```

**Why exclude the current month?** The last month is typically incomplete, so its running average would be misleadingly low. We set it to `NA` so the lines stop before the final month.

### Incomplete Month Projection (lines 353-408)

```r
current_month <- floor_date(Sys.Date(), "month")
empty_projection <- data.frame(
  xmin = as.Date(character()),
  xmax = as.Date(character()),
  ymin = numeric(),
  ymax = numeric()
)
if (current_month %in% monthly_data$month) {
  data_date <- max(contributions$date)
  days_elapsed <- day(data_date)
  total_days_in_month <- days_in_month(current_month)

  actual_contributions <- monthly_data %>%
    filter(month == current_month) %>%
    pull(contributions)

  if (days_elapsed <= first_week_days) {
    trailing_window <- contributions %>%
      filter(date > data_date - trailing_window_days, date <= data_date)
    pace <- sum(trailing_window$contribution_count) / max(nrow(trailing_window), 1)
  } else {
    pace <- actual_contributions / days_elapsed
  }

  projected_total <- actual_contributions +
    pace * (total_days_in_month - days_elapsed)
  cat("Current month projection:", format(round(projected_total), big.mark = ","),
      "projected vs", format(actual_contributions, big.mark = ","), "actual\n")

  monthly_projection <- data.frame(
    xmin = current_month - projection_bar_width / 2,
    xmax = current_month + projection_bar_width / 2,
    ymin = actual_contributions,
    ymax = projected_total
  )
} else {
  monthly_projection <- empty_projection
}
```

**How projection works:** The projected month-end total is what has already been banked plus the unknown remainder at an estimated daily pace:

```text
projected_total = actual_contributions + pace * (total_days_in_month - days_elapsed)
```

Because the banked month-to-date total is never scaled, the projection can never
fall below it - the grey cap is never inverted, and no special-case guard is
needed. On the last day of a completed month the remainder is zero, so the cap
has zero height and simply does not show.

**Two pace estimates:**

- **Days 1-7** (`days_elapsed <= first_week_days`): the average over a trailing
  10-day window that reaches back into the prior month. On the 2nd of the
  month, month-to-date scaling would multiply a two-day sample by 15; the
  trailing window smooths that out. The database stores a row for every day
  (zero-contribution days included), so rows are days with data - a missing
  row means the fetch lagged, and it is excluded from the average rather
  than counted as a zero.
- **Day 8 onward:** the month-to-date average
  (`actual_contributions / days_elapsed`), which by then rests on enough days
  to be a reasonable estimate.

**Why anchor to `max(contributions$date)`?** If the fetch job has not run yet
today, the wall clock would claim more elapsed days than the data contains.
Anchoring both `days_elapsed` and the window filter to the latest date in the
data keeps the formula and the data consistent.

**Worked examples:**

- 15 days into a 30-day month with 30 contributions: pace = 30/15 = 2/day, so
  the projection is `30 + 2 * 15 = 60`.
- November 2nd with 23 contributions banked and a trailing 10-day window
  totaling 171: pace = 17.1/day, so the projection is `23 + 17.1 * 28 = 501.8`
  (printed as 502).

**The `cat()` line** prints the projection on every run (e.g. `Current month
projection: 502 projected vs 23 actual`) so the estimate is visible without
squinting at the chart.

**Bar width calculation:** `projection_bar_width = 25` days keeps the cap
aligned with the monthly bar.

```r
geom_rect(data = monthly_projection,
          aes(xmin = xmin, xmax = xmax,
              ymin = ymin, ymax = ymax),
          alpha = 0.3,
          fill = "gray60",
          inherit.aes = FALSE)
```

**Visual distinction:** The projected portion is drawn in semi-transparent
gray (`alpha = 0.3`) after the blue bars, so it caps the month-to-date total.
It clearly reads as an estimate, not actual data.

---

## 10. Output Files

Three PNG files are created:

| File | Dimensions | Description |
| ---- | ---------- | ----------- |
| `contributions-last2years.png` | 12×6 inches, 300 DPI | Daily data with 14/30/90-day running averages |
| `contributions-weekly.png` | 14×6 inches, 300 DPI | Weekly totals with employment periods overlay |
| `contributions-monthly.png` | 14×6 inches, 300 DPI | Monthly totals with projection for current month |

```r
ggsave(output_file, p, width = 12, height = 6, dpi = 300)
ggsave(output_file2, p2, width = 14, height = 6, dpi = 300)
ggsave(output_file3, p3, width = 14, height = 6, dpi = 300)
```

The 14-inch width for weekly/monthly plots accommodates 14+ years of data, while the 12-inch width for the daily plot provides enough space for 2 years of daily points.

---

## Data Flow Summary

```text
contributions.db
        │
        ▼
┌──────────────────────┐
│ Load & deduplicate   │  (MAX fetched_at per date)
└──────────────────────┘
        │
        ▼
┌──────────────────────┐
│ Calculate running    │  (14/30/90-day for daily)
│ averages             │  (4/13/26-week for weekly)
└──────────────────────┘        (6/12-month for monthly)
        │
        ├─── Plot 1: Daily (last 2 years)
        │
        ├─── Plot 2: Weekly (all time) + employment overlay
        │
        └─── Plot 3: Monthly (all time) + projection

job_history.csv
        │
        ▼
┌──────────────────────┐
│ Merge roles by       │
│ company              │
└──────────────────────┘
        │
        ▼
┌──────────────────────┐
│ Load logos for       │
│ known companies      │
└──────────────────────┘
        │
        └─── Overlay on plots 2 & 3
```
