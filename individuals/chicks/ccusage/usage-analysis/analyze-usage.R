#!/usr/bin/env Rscript
# Claude Code Usage Analysis
# Analyzes token usage and cost data from SQLite database

# Load required libraries
library(DBI)
library(RSQLite)
library(ggplot2)
library(dplyr)
library(tidyr)
library(lubridate)
library(scales)

# Load configuration (weekly spending limit)
config_path <- "config.R"
if (file.exists(config_path)) {
  source(config_path)
} else {
  cat("Warning: config.R not found, using default weekly limit of $20.00\n")
  WEEKLY_LIMIT <- 20.00
}

# Database path (relative to script location)
db_path <- "../usage.db"

# Connect to database
cat("Connecting to database:", db_path, "\n")
con <- dbConnect(SQLite(), db_path)

# Load data
daily_usage <- dbGetQuery(con, "SELECT * FROM daily_usage ORDER BY date")
model_breakdown <- dbGetQuery(con, "SELECT * FROM model_breakdown ORDER BY date, model_name")
session_usage <- dbGetQuery(con, "SELECT * FROM session_usage ORDER BY total_cost DESC")

# Get metadata
last_updated <- dbGetQuery(con, "SELECT MAX(fetched_at) as last_updated FROM daily_usage")$last_updated

dbDisconnect(con)

cat("Loaded", nrow(daily_usage), "daily records\n")
cat("Loaded", nrow(model_breakdown), "model breakdown records\n")
cat("Loaded", nrow(session_usage), "session records\n")
cat("Last updated:", last_updated, "\n\n")

# Convert date columns
daily_usage$date <- as.Date(daily_usage$date)
model_breakdown$date <- as.Date(model_breakdown$date)

# Simplify model names for display (remove date suffix)
model_breakdown <- model_breakdown %>%
  mutate(model_display = gsub("-\\d{8}$", "", model_name))

# === SUMMARY STATISTICS ===
cat("=== SUMMARY STATISTICS ===\n\n")

# Overall totals
total_stats <- daily_usage %>%
  summarise(
    total_days = n(),
    total_tokens = sum(total_tokens, na.rm = TRUE),
    total_input = sum(input_tokens, na.rm = TRUE),
    total_output = sum(output_tokens, na.rm = TRUE),
    total_cache_creation = sum(cache_creation_tokens, na.rm = TRUE),
    total_cache_read = sum(cache_read_tokens, na.rm = TRUE),
    total_cost = sum(total_cost, na.rm = TRUE),
    avg_daily_tokens = mean(total_tokens, na.rm = TRUE),
    avg_daily_cost = mean(total_cost, na.rm = TRUE),
    max_daily_tokens = max(total_tokens, na.rm = TRUE),
    max_daily_cost = max(total_cost, na.rm = TRUE),
    first_date = min(date),
    last_date = max(date)
  )

cat("Total days tracked:", total_stats$total_days, "\n")
cat("Date range:", as.character(total_stats$first_date), "to", as.character(total_stats$last_date), "\n")
cat("Total tokens:", format(total_stats$total_tokens, big.mark = ","), "\n")
cat("  - Input:", format(total_stats$total_input, big.mark = ","), "\n")
cat("  - Output:", format(total_stats$total_output, big.mark = ","), "\n")
cat("  - Cache creation:", format(total_stats$total_cache_creation, big.mark = ","), "\n")
cat("  - Cache read:", format(total_stats$total_cache_read, big.mark = ","), "\n")
cat("Total cost: $", format(round(total_stats$total_cost, 2), nsmall = 2), "\n", sep = "")
cat("Average daily tokens:", format(round(total_stats$avg_daily_tokens), big.mark = ","), "\n")
cat("Average daily cost: $", format(round(total_stats$avg_daily_cost, 2), nsmall = 2), "\n", sep = "")
cat("Peak daily tokens:", format(total_stats$max_daily_tokens, big.mark = ","), "\n")
cat("Peak daily cost: $", format(round(total_stats$max_daily_cost, 2), nsmall = 2), "\n\n", sep = "")

# Model breakdown
cat("=== MODEL USAGE ===\n\n")
model_stats <- model_breakdown %>%
  group_by(model_display) %>%
  summarise(
    total_cost = sum(cost, na.rm = TRUE),
    total_tokens = sum(input_tokens + output_tokens, na.rm = TRUE),
    total_input = sum(input_tokens, na.rm = TRUE),
    total_output = sum(output_tokens, na.rm = TRUE),
    days_used = n_distinct(date)
  ) %>%
  arrange(desc(total_cost))

print(model_stats)
cat("\n")

# Session insights
cat("=== SESSION INSIGHTS ===\n\n")
cat("Total sessions:", nrow(session_usage), "\n")
cat("Top 5 sessions by cost:\n")
top_sessions <- session_usage %>%
  select(project_path, total_cost, total_tokens, last_activity) %>%
  head(5)
print(top_sessions)
cat("\n")

# Cache efficiency
cat("=== CACHE EFFICIENCY ===\n\n")
cache_stats <- daily_usage %>%
  summarise(
    cache_creation = sum(cache_creation_tokens, na.rm = TRUE),
    cache_read = sum(cache_read_tokens, na.rm = TRUE),
    cache_hit_ratio = sum(cache_read_tokens, na.rm = TRUE) / (sum(cache_creation_tokens, na.rm = TRUE) + 1)
  )

cat("Total cache creation:", format(cache_stats$cache_creation, big.mark = ","), "tokens\n")
cat("Total cache read:", format(cache_stats$cache_read, big.mark = ","), "tokens\n")
cat("Cache hit ratio:", round(cache_stats$cache_hit_ratio, 2), "x\n")
cat("(Shows how many times cache was read vs created)\n\n")

# Weekly plan usage
cat("=== WEEKLY PLAN USAGE ===\n\n")
cat("Weekly spending limit: $", format(WEEKLY_LIMIT, nsmall = 2), "\n\n", sep = "")

# Calculate weekly aggregates
weekly_usage <- daily_usage %>%
  mutate(
    date = as.Date(date),
    week_start = floor_date(date, "week", week_start = 1)  # Week starts on Monday
  ) %>%
  group_by(week_start) %>%
  summarise(
    week_cost = sum(total_cost, na.rm = TRUE),
    week_tokens = sum(total_tokens, na.rm = TRUE),
    days_in_week = n(),
    .groups = "drop"
  ) %>%
  mutate(
    plan_pct = (week_cost / WEEKLY_LIMIT) * 100,
    over_limit = week_cost > WEEKLY_LIMIT
  ) %>%
  arrange(week_start)

cat("Weekly usage breakdown:\n")
weekly_display <- weekly_usage %>%
  mutate(
    week_label = format(week_start, "%Y-%m-%d"),
    cost_display = paste0("$", format(round(week_cost, 2), nsmall = 2)),
    pct_display = paste0(format(round(plan_pct, 1), nsmall = 1), "%"),
    status = ifelse(over_limit, "OVER", "OK")
  ) %>%
  select(week_label, cost_display, pct_display, status)

print(weekly_display)
cat("\n")

# Summary
weeks_over <- sum(weekly_usage$over_limit)
if (weeks_over > 0) {
  cat("WARNING:", weeks_over, "week(s) exceeded the weekly limit!\n\n")
} else {
  cat("All weeks are within the weekly limit.\n\n")
}

# === VISUALIZATIONS ===
cat("Generating visualizations...\n")

# 1. Daily token usage over time
# Prepare data in long format for stacking
daily_long <- daily_usage %>%
  select(date, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens) %>%
  pivot_longer(
    cols = c(input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens),
    names_to = "token_type",
    values_to = "count"
  ) %>%
  mutate(
    token_type = factor(
      token_type,
      levels = c("cache_read_tokens", "cache_creation_tokens", "output_tokens", "input_tokens"),
      labels = c("Cache Read", "Cache Creation", "Output", "Input")
    )
  )

p1 <- ggplot(daily_long, aes(x = date, y = count, fill = token_type)) +
  geom_area(alpha = 0.7) +
  scale_y_continuous(labels = comma_format()) +
  scale_fill_manual(
    values = c(
      "Input" = "#2E86AB",
      "Output" = "#A23B72",
      "Cache Creation" = "#F18F01",
      "Cache Read" = "#C73E1D"
    )
  ) +
  labs(
    title = "Daily Token Usage Over Time",
    subtitle = paste("From", min(daily_usage$date), "to", max(daily_usage$date)),
    x = "Date",
    y = "Tokens",
    fill = "Token Type"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 12),
    legend.position = "bottom"
  )

ggsave("token-usage-trends.png", p1, width = 12, height = 6, dpi = 300)

# 2. Daily cost trends
p2 <- ggplot(daily_usage, aes(x = date, y = total_cost)) +
  geom_line(color = "#2E86AB", linewidth = 1) +
  geom_point(color = "#2E86AB", size = 2, alpha = 0.6) +
  geom_smooth(method = "loess", se = TRUE, color = "#A23B72", fill = "#A23B72", alpha = 0.2) +
  scale_y_continuous(labels = dollar_format()) +
  labs(
    title = "Daily Cost Trends",
    subtitle = paste("Total spent: $", round(sum(daily_usage$total_cost, na.rm = TRUE), 2), sep = ""),
    x = "Date",
    y = "Daily Cost (USD)"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 12)
  )

ggsave("cost-trends.png", p2, width = 12, height = 6, dpi = 300)

# 3. Model usage breakdown (stacked area chart)
model_daily <- model_breakdown %>%
  group_by(date, model_display) %>%
  summarise(
    total_tokens = sum(input_tokens + output_tokens, na.rm = TRUE),
    .groups = "drop"
  )

p3 <- ggplot(model_daily, aes(x = date, y = total_tokens, fill = model_display)) +
  geom_area(alpha = 0.7) +
  scale_y_continuous(labels = comma_format()) +
  scale_fill_brewer(palette = "Set2") +
  labs(
    title = "Token Usage by Model",
    subtitle = "Daily breakdown by model type",
    x = "Date",
    y = "Tokens",
    fill = "Model"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 12),
    legend.position = "bottom"
  )

ggsave("model-usage-breakdown.png", p3, width = 12, height = 6, dpi = 300)

# 4. Cache efficiency over time
daily_usage <- daily_usage %>%
  mutate(
    direct_tokens = input_tokens + output_tokens,
    cache_total = cache_creation_tokens + cache_read_tokens,
    cache_pct = (cache_total / (direct_tokens + cache_total)) * 100
  )

p4 <- ggplot(daily_usage, aes(x = date)) +
  geom_col(aes(y = cache_creation_tokens), fill = "#F18F01", alpha = 0.6) +
  geom_col(aes(y = cache_read_tokens), fill = "#C73E1D", alpha = 0.6) +
  geom_line(aes(y = cache_pct * 1000), color = "#2E86AB", linewidth = 1) +
  scale_y_continuous(
    name = "Cache Tokens",
    labels = comma_format(),
    sec.axis = sec_axis(~ . / 1000, name = "Cache % of Total", labels = percent_format(scale = 1))
  ) +
  labs(
    title = "Cache Usage Efficiency",
    subtitle = "Orange = creation, Red = reads, Blue line = cache % of total tokens",
    x = "Date"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 10),
    axis.title.y.right = element_text(color = "#2E86AB"),
    axis.text.y.right = element_text(color = "#2E86AB")
  )

ggsave("cache-efficiency.png", p4, width = 12, height = 6, dpi = 300)

# 5. Top sessions by cost (horizontal bar chart)
if (nrow(session_usage) > 0) {
  # Simplify project paths for display
  top_10_sessions <- session_usage %>%
    head(10) %>%
    mutate(
      # Extract last part of path for display
      project_display = ifelse(
        grepl("/", project_path),
        basename(project_path),
        project_path
      ),
      # Truncate if still too long
      project_display = ifelse(
        nchar(project_display) > 30,
        paste0(substr(project_display, 1, 27), "..."),
        project_display
      )
    )

  p5 <- ggplot(top_10_sessions, aes(x = reorder(project_display, total_cost), y = total_cost)) +
    geom_col(fill = "#2E86AB", alpha = 0.8) +
    geom_text(aes(label = dollar(total_cost, accuracy = 0.01)), hjust = -0.1, size = 3) +
    coord_flip() +
    scale_y_continuous(
      labels = dollar_format(),
      expand = expansion(mult = c(0, 0.15))
    ) +
    labs(
      title = "Top 10 Sessions by Cost",
      subtitle = "Most expensive projects/conversations",
      x = "Project",
      y = "Total Cost (USD)"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = 16, face = "bold"),
      plot.subtitle = element_text(size = 12)
    )

  ggsave("top-sessions.png", p5, width = 10, height = 8, dpi = 300)
}

# 6. Weekly plan usage percentage
if (nrow(weekly_usage) > 0) {
  p6 <- ggplot(weekly_usage, aes(x = week_start, y = plan_pct)) +
    geom_hline(yintercept = 100, linetype = "dashed", color = "#C73E1D", linewidth = 1) +
    geom_col(aes(fill = over_limit), alpha = 0.8) +
    geom_text(
      aes(label = paste0(round(plan_pct, 1), "%\n$", round(week_cost, 2))),
      vjust = ifelse(weekly_usage$plan_pct > 100, 1.1, -0.3),
      size = 3.5,
      fontface = "bold"
    ) +
    scale_fill_manual(
      values = c("FALSE" = "#2E86AB", "TRUE" = "#C73E1D"),
      labels = c("Within Limit", "Over Limit")
    ) +
    scale_y_continuous(
      labels = percent_format(scale = 1),
      expand = expansion(mult = c(0, 0.15))
    ) +
    scale_x_date(
      date_breaks = "1 week",
      date_labels = "%b %d",
      expand = expansion(mult = 0.02)
    ) +
    labs(
      title = "Weekly Plan Usage",
      subtitle = paste0("Weekly limit: $", format(WEEKLY_LIMIT, nsmall = 2), " (100% = limit)"),
      x = "Week Starting",
      y = "Percentage of Weekly Limit",
      fill = "Status"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = 16, face = "bold"),
      plot.subtitle = element_text(size = 12),
      legend.position = "bottom",
      axis.text.x = element_text(angle = 45, hjust = 1)
    )

  ggsave("weekly-plan-usage.png", p6, width = 12, height = 7, dpi = 300)
}

cat("\nAnalysis complete! Generated visualizations:\n")
cat("  - token-usage-trends.png: Daily token usage by type (stacked area)\n")
cat("  - cost-trends.png: Daily cost with trend line\n")
cat("  - model-usage-breakdown.png: Token usage by model over time\n")
cat("  - cache-efficiency.png: Cache creation/reads and efficiency percentage\n")
if (nrow(session_usage) > 0) {
  cat("  - top-sessions.png: Top 10 most expensive sessions\n")
}
if (nrow(weekly_usage) > 0) {
  cat("  - weekly-plan-usage.png: Weekly spending as percentage of plan limit\n")
}
