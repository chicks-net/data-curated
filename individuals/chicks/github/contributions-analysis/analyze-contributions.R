#!/usr/bin/env Rscript
# GitHub Contributions Analysis
# Analyzes GitHub contribution data from SQLite database
# Shows daily contribution counts with 7/30/90-day running averages

# Load required libraries
library(DBI)
library(RSQLite)
library(ggplot2)
library(dplyr)
library(zoo)
library(lubridate)
library(scales)

# Database path (relative to script location)
db_path <- "../contributions.db"

# Connect to database
cat("Connecting to database:", db_path, "\n")
con <- dbConnect(SQLite(), db_path)

# Load contribution data - get most recent fetch for each date
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
dbDisconnect(con)

cat("Loaded", nrow(contributions), "records\n\n")

# Convert date column
contributions$date <- as.Date(contributions$date)

# Calculate running averages using zoo::rollmean
# align="right" means the average includes the current day and previous days
# fill=NA handles the beginning where we don't have enough data
contributions <- contributions %>%
  arrange(date) %>%
  mutate(
    avg_7day = rollmean(contribution_count, k=7, fill=NA, align="right"),
    avg_30day = rollmean(contribution_count, k=30, fill=NA, align="right"),
    avg_90day = rollmean(contribution_count, k=90, fill=NA, align="right")
  )

# Summary Statistics
cat("=== SUMMARY STATISTICS ===\n\n")

cat("Date range:", min(contributions$date), "to", max(contributions$date), "\n")
cat("Total days:", nrow(contributions), "\n")
cat("Total contributions:", sum(contributions$contribution_count), "\n")
cat("Average contributions per day:", round(mean(contributions$contribution_count), 2), "\n")
cat("Median contributions per day:", median(contributions$contribution_count), "\n")
cat("Max contributions in a day:", max(contributions$contribution_count), "\n")
cat("Days with no contributions:", sum(contributions$contribution_count == 0), "\n")
cat("Days with contributions:", sum(contributions$contribution_count > 0), "\n\n")

# Recent activity (last 90 days)
recent <- contributions %>%
  filter(date >= Sys.Date() - 90)

cat("=== LAST 90 DAYS ===\n\n")
cat("Total contributions:", sum(recent$contribution_count), "\n")
cat("Average per day:", round(mean(recent$contribution_count), 2), "\n")
cat("Active days:", sum(recent$contribution_count > 0), "\n\n")

# Create visualization
cat("Creating contribution graph...\n")

# Determine a reasonable date range for plotting (last 2 years by default)
plot_start <- max(min(contributions$date), Sys.Date() - 730)  # 2 years
plot_data <- contributions %>% filter(date >= plot_start)

p <- ggplot(plot_data, aes(x = date)) +
  # Daily points - smaller and semi-transparent
  geom_point(aes(y = contribution_count),
             alpha = 0.3,
             size = 1,
             color = "gray50") +
  # Running average lines
  geom_line(aes(y = avg_7day, color = "7-day average"),
            linewidth = 0.8) +
  geom_line(aes(y = avg_30day, color = "30-day average"),
            linewidth = 0.8) +
  geom_line(aes(y = avg_90day, color = "90-day average"),
            linewidth = 0.8) +
  # Color scheme
  scale_color_manual(
    name = "Moving Averages",
    values = c(
      "7-day average" = "#2E86AB",    # Blue
      "30-day average" = "#A23B72",   # Purple
      "90-day average" = "#F18F01"    # Orange
    )
  ) +
  # Labels and theme
  labs(
    title = "GitHub Contributions Over Time for chicks-net",
    subtitle = paste("Daily contributions with running averages"),
    x = "Date",
    y = "Contributions per Day"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 11, color = "gray40"),
    legend.position = "top",
    legend.title = element_text(size = 10, face = "bold"),
    panel.grid.minor = element_blank()
  ) +
  scale_x_date(date_breaks = "3 months", date_labels = "%b %Y")

# Save the plot
output_file <- "contributions-timeline.png"
ggsave(output_file, p, width = 12, height = 6, dpi = 300)
cat("Saved:", output_file, "\n")

# Create a second visualization showing all-time data with better aggregation
cat("\nCreating all-time contribution graph...\n")

# For all-time view, aggregate by week to make it more readable
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

p2 <- ggplot(weekly_data, aes(x = week)) +
  # Weekly bars
  geom_col(aes(y = contributions),
           alpha = 0.3,
           fill = "gray50") +
  # Running average lines (based on daily averages)
  geom_line(aes(y = avg_4week * 7, color = "4-week average"),
            linewidth = 0.8) +
  geom_line(aes(y = avg_13week * 7, color = "13-week average"),
            linewidth = 0.8) +
  geom_line(aes(y = avg_26week * 7, color = "26-week average"),
            linewidth = 0.8) +
  # Color scheme
  scale_color_manual(
    name = "Moving Averages",
    values = c(
      "4-week average" = "#2E86AB",    # Blue
      "13-week average" = "#A23B72",   # Purple
      "26-week average" = "#F18F01"    # Orange
    )
  ) +
  # Labels and theme
  labs(
    title = "GitHub Contributions for chicks-net - All Time",
    subtitle = "Weekly totals with running averages (lines show weekly equivalent of daily averages)",
    x = "Date",
    y = "Contributions per Week"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 10, color = "gray40"),
    legend.position = "top",
    legend.title = element_text(size = 10, face = "bold"),
    panel.grid.minor = element_blank()
  ) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y")

# Save the all-time plot
output_file2 <- "contributions-alltime.png"
ggsave(output_file2, p2, width = 14, height = 6, dpi = 300)
cat("Saved:", output_file2, "\n\n")

cat("Analysis complete!\n")
