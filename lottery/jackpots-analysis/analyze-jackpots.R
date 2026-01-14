#!/usr/bin/env Rscript
# Lottery Jackpots Analysis
# Analyzes California Lottery jackpot data from SQLite database

# Load required libraries
library(DBI)
library(RSQLite)
library(ggplot2)
library(dplyr)
library(tidyr)
library(lubridate)
library(scales)

# Database path (relative to script location)
db_path <- "../jackpots.db"

# Connect to database
cat("Connecting to database:", db_path, "\n")
con <- dbConnect(SQLite(), db_path)

# Load jackpot data
jackpots <- dbGetQuery(con, "SELECT * FROM jackpots")
dbDisconnect(con)

cat("Loaded", nrow(jackpots), "records\n\n")

# Convert date columns
jackpots$draw_date <- as.Date(jackpots$draw_date)
jackpots$checked_at <- as.POSIXct(jackpots$checked_at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# Convert jackpots to millions for easier reading
jackpots$jackpot_millions <- jackpots$jackpot / 1000000
jackpots$cash_millions <- jackpots$estimated_cash / 1000000

# Calculate cash value as percentage of jackpot
jackpots$cash_pct <- (jackpots$estimated_cash / jackpots$jackpot) * 100

# Get unique draws (remove duplicate checks of same draw)
unique_draws <- jackpots %>%
  arrange(game, draw_date, desc(checked_at)) %>%
  group_by(game, draw_number, draw_date) %>%
  slice(1) %>%
  ungroup() %>%
  arrange(draw_date)

cat("Unique draws:", nrow(unique_draws), "\n\n")

# Summary Statistics
cat("=== SUMMARY STATISTICS ===\n\n")

summary_stats <- unique_draws %>%
  group_by(game) %>%
  summarise(
    num_draws = n(),
    min_jackpot = min(jackpot_millions),
    max_jackpot = max(jackpot_millions),
    avg_jackpot = mean(jackpot_millions),
    median_jackpot = median(jackpot_millions),
    avg_cash_pct = mean(cash_pct),
    first_draw = min(draw_date),
    last_draw = max(draw_date)
  )

print(summary_stats)
cat("\n")

# Jackpot trends over time
cat("=== JACKPOT TRENDS ===\n\n")

# Calculate jackpot changes
jackpot_changes <- unique_draws %>%
  group_by(game) %>%
  arrange(draw_date) %>%
  mutate(
    prev_jackpot = lag(jackpot_millions),
    jackpot_change = jackpot_millions - prev_jackpot,
    pct_change = ((jackpot_millions - prev_jackpot) / prev_jackpot) * 100
  ) %>%
  filter(!is.na(jackpot_change))

# Count increases vs resets (decreases)
change_summary <- jackpot_changes %>%
  group_by(game) %>%
  summarise(
    total_changes = n(),
    increases = sum(jackpot_change > 0),
    resets = sum(jackpot_change < 0),
    avg_increase = mean(jackpot_change[jackpot_change > 0]),
    avg_reset = mean(jackpot_change[jackpot_change < 0]),
    max_increase = max(jackpot_change),
    max_reset = min(jackpot_change)
  )

print(change_summary)
cat("\n")

# Recent jackpot status
cat("=== CURRENT JACKPOTS ===\n\n")
current <- unique_draws %>%
  group_by(game) %>%
  arrange(desc(draw_date)) %>%
  slice(1) %>%
  select(game, draw_date, jackpot_millions, cash_millions, cash_pct)

print(current)
cat("\n")

# Create visualizations
cat("Generating visualizations...\n")

# 1. Jackpot trends over time
p1 <- ggplot(unique_draws, aes(x = draw_date, y = jackpot_millions, color = game)) +
  geom_line(linewidth = 1) +
  geom_point(size = 2, alpha = 0.6) +
  scale_y_continuous(labels = dollar_format(prefix = "$", suffix = "M")) +
  scale_color_manual(values = c("Mega Millions" = "#002868", "Powerball" = "#C8102E")) +
  labs(
    title = "Lottery Jackpot Trends",
    subtitle = paste("Data from", min(unique_draws$draw_date), "to", max(unique_draws$draw_date)),
    x = "Draw Date",
    y = "Jackpot Amount",
    color = "Game"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 12),
    legend.position = "bottom"
  )

ggsave("jackpot-trends.png", p1, width = 12, height = 6, dpi = 300)

# 2. Cash value percentage comparison
p2 <- ggplot(unique_draws, aes(x = game, y = cash_pct, fill = game)) +
  geom_boxplot(alpha = 0.7) +
  scale_fill_manual(values = c("Mega Millions" = "#002868", "Powerball" = "#C8102E")) +
  labs(
    title = "Cash Value as Percentage of Advertised Jackpot",
    subtitle = "Distribution comparison between games",
    x = "Game",
    y = "Cash Value (%)",
    fill = "Game"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 12),
    legend.position = "none"
  )

ggsave("cash-percentage.png", p2, width = 10, height = 6, dpi = 300)

# 3. Jackpot distribution histogram
p3 <- ggplot(unique_draws, aes(x = jackpot_millions, fill = game)) +
  geom_histogram(bins = 30, alpha = 0.7, position = "identity") +
  scale_x_continuous(labels = dollar_format(prefix = "$", suffix = "M")) +
  scale_fill_manual(values = c("Mega Millions" = "#002868", "Powerball" = "#C8102E")) +
  labs(
    title = "Distribution of Jackpot Amounts",
    subtitle = "Frequency of different jackpot levels",
    x = "Jackpot Amount",
    y = "Count",
    fill = "Game"
  ) +
  facet_wrap(~game, ncol = 1) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 12),
    legend.position = "none"
  )

ggsave("jackpot-distribution.png", p3, width = 10, height = 8, dpi = 300)

# 4. Jackpot changes over time
p4 <- ggplot(jackpot_changes, aes(x = draw_date, y = jackpot_change, color = game)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_line(alpha = 0.6) +
  geom_point(size = 2, alpha = 0.6) +
  scale_y_continuous(labels = dollar_format(prefix = "$", suffix = "M")) +
  scale_color_manual(values = c("Mega Millions" = "#002868", "Powerball" = "#C8102E")) +
  labs(
    title = "Jackpot Changes Between Draws",
    subtitle = "Positive values = jackpot increased, negative = jackpot reset (someone won)",
    x = "Draw Date",
    y = "Change in Jackpot",
    color = "Game"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 10),
    legend.position = "bottom"
  )

ggsave("jackpot-changes.png", p4, width = 12, height = 6, dpi = 300)

cat("\nAnalysis complete! Generated 4 visualizations:\n")
cat("  - jackpot-trends.png: Overall jackpot trends over time\n")
cat("  - cash-percentage.png: Cash value percentage comparison\n")
cat("  - jackpot-distribution.png: Distribution of jackpot amounts\n")
cat("  - jackpot-changes.png: Changes between consecutive draws\n")
