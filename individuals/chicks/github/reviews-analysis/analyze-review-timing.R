#!/usr/bin/env Rscript
library(DBI)
library(RSQLite)
library(ggplot2)
library(dplyr)
library(lubridate)

args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
if (length(script_path) > 0) {
  script_dir <- dirname(normalizePath(script_path))
  repo_root <- dirname(dirname(dirname(dirname(script_dir))))
} else {
  repo_root <- getwd()
}

db_path <- file.path(repo_root, "individuals/chicks/github/reviews.db")

if (!file.exists(db_path)) {
  stop("Database not found: ", db_path)
}

con <- dbConnect(RSQLite::SQLite(), db_path)

query <- "
SELECT 
  pr.repo_full_name,
  pr.pr_number,
  pr.created_at as pr_created_at,
  br.bot_type,
  br.submitted_at,
  br.review_type
FROM pull_requests pr
INNER JOIN bot_reviews br ON pr.repo_full_name = br.repo_full_name AND pr.pr_number = br.pr_number
-- Exclude data before May 2025, when we started using AI in repos
WHERE pr.created_at >= '2025-05-01'
ORDER BY pr.repo_full_name, pr.pr_number, br.submitted_at
"

data <- dbGetQuery(con, query)
dbDisconnect(con)

data$pr_created_at <- as.POSIXct(data$pr_created_at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
data$submitted_at <- as.POSIXct(data$submitted_at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

data$time_to_review <- as.numeric(difftime(data$submitted_at, data$pr_created_at, units = "mins"))

first_reviews <- data %>%
  group_by(repo_full_name, pr_number, bot_type) %>%
  slice_min(submitted_at, n = 1) %>%
  ungroup()

bot_stats <- first_reviews %>%
  group_by(bot_type) %>%
  summarize(
    n_reviews = n(),
    median_minutes = median(time_to_review),
    mean_minutes = mean(time_to_review),
    min_minutes = min(time_to_review),
    max_minutes = max(time_to_review),
    reviews_under_5min = sum(time_to_review <= 5),
    reviews_under_1hr = sum(time_to_review <= 60),
    reviews_under_24hr = sum(time_to_review <= 1440),
    .groups = "drop"
  )

cat("\n=== Bot Review Timing Statistics (May 2025 onwards) ===\n\n")

for (bot in c("claude", "copilot")) {
  stats <- bot_stats %>% filter(bot_type == bot)
  if (nrow(stats) == 0) {
    cat(sprintf("No %s reviews in this time period\n\n", bot))
    next
  }
  
  cat(sprintf("Bot: %s\n\n", toupper(bot)))
  cat(sprintf("  Total first reviews: %d\n", stats$n_reviews))
  cat(sprintf("  Median time: %.1f minutes (%.1f seconds)\n", 
      stats$median_minutes, stats$median_minutes * 60))
  cat(sprintf("  Mean time: %.1f minutes\n", stats$mean_minutes))
  cat(sprintf("  Min time: %.1f minutes (%.1f seconds)\n", 
      stats$min_minutes, stats$min_minutes * 60))
  cat(sprintf("  Max time: %.1f minutes (%.1f hours)\n\n", 
      stats$max_minutes, stats$max_minutes / 60))
  cat(sprintf("  Reviews within 5 minutes: %d (%.1f%%)\n", 
      stats$reviews_under_5min,
      100 * stats$reviews_under_5min / stats$n_reviews))
  cat(sprintf("  Reviews within 1 hour: %d (%.1f%%)\n", 
      stats$reviews_under_1hr,
      100 * stats$reviews_under_1hr / stats$n_reviews))
  cat(sprintf("  Reviews within 24 hours: %d (%.1f%%)\n\n", 
      stats$reviews_under_24hr,
      100 * stats$reviews_under_24hr / stats$n_reviews))
  cat("\n")
}

monthly_timing <- first_reviews %>%
  mutate(month = floor_date(pr_created_at, "month")) %>%
  group_by(month, bot_type) %>%
  summarize(
    n = n(),
    median_time = median(time_to_review),
    mean_time = mean(time_to_review),
    .groups = "drop"
  ) %>%
  arrange(month, bot_type)

cat("=== Monthly Median Time to First Review (minutes) ===\n\n")
monthly_wide <- monthly_timing %>%
  select(month, bot_type, median_time) %>%
  tidyr::pivot_wider(names_from = bot_type, values_from = median_time)
print(monthly_wide)

p1 <- ggplot(first_reviews, aes(x = bot_type, y = time_to_review, fill = bot_type)) +
  geom_boxplot(alpha = 0.7) +
  scale_y_log10(limits = c(0.1, NA), breaks = c(0.1, 1, 5, 10, 30, 60, 120, 360, 1440)) +
  scale_fill_manual(values = c("claude" = "#FF6B6B", "copilot" = "#4ECDC4")) +
  labs(
    title = "Time to First Review by Bot Type",
    subtitle = "Minutes between PR creation and first bot review (May 2025 onwards)",
    x = NULL,
    y = "Minutes (log scale)"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "none",
    plot.title = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(color = "gray40")
  )

data_for_histogram <- first_reviews %>%
  mutate(
    time_bucket = case_when(
      time_to_review <= 1 ~ "<= 1 min",
      time_to_review <= 5 ~ "1-5 min",
      time_to_review <= 10 ~ "5-10 min",
      time_to_review <= 30 ~ "10-30 min",
      time_to_review <= 60 ~ "30-60 min",
      time_to_review <= 360 ~ "1-6 hours",
      TRUE ~ "> 6 hours"
    ),
    time_bucket = factor(time_bucket, 
                         levels = c("<= 1 min", "1-5 min", "5-10 min", "10-30 min", 
                                    "30-60 min", "1-6 hours", "> 6 hours"))
  )

p2 <- ggplot(data_for_histogram, aes(x = time_bucket, fill = bot_type)) +
  geom_bar(position = position_dodge(width = 0.8), alpha = 0.7) +
  facet_wrap(~ bot_type, scales = "free_y") +
  scale_fill_manual(values = c("claude" = "#FF6B6B", "copilot" = "#4ECDC4")) +
  labs(
    title = "Distribution of Time to First Review",
    subtitle = "How quickly each bot posts its first review (May 2025 onwards)",
    x = NULL,
    y = "Number of Reviews"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "none",
    axis.text.x = element_text(angle = 45, hjust = 1),
    strip.text = element_text(face = "bold", size = 11),
    plot.title = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(color = "gray40")
  )

p3 <- ggplot(monthly_timing, aes(x = month, y = median_time, color = bot_type)) +
  geom_line(linewidth = 1.2) +
  geom_point(size = 2.5) +
  scale_color_manual(values = c("claude" = "#FF6B6B", "copilot" = "#4ECDC4")) +
  scale_y_continuous(breaks = seq(0, 60, 5)) +
  scale_x_datetime(date_labels = "%b %Y", date_breaks = "1 month") +
  labs(
    title = "Median Time to First Review Over Time",
    subtitle = "Monthly median minutes between PR creation and first bot review",
    x = NULL,
    y = "Median Minutes",
    color = "Bot Type"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    legend.position = "top",
    plot.title = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(color = "gray40")
  )

output_dir <- file.path(repo_root, "individuals/chicks/github/reviews-analysis")
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

output_file1 <- file.path(output_dir, "review-timing-boxplot.png")
ggsave(output_file1, p1, width = 8, height = 6, dpi = 150)
cat(sprintf("\nPlot saved to: %s\n", output_file1))

output_file2 <- file.path(output_dir, "review-timing-distribution.png")
ggsave(output_file2, p2, width = 12, height = 6, dpi = 150)
cat(sprintf("Plot saved to: %s\n", output_file2))

output_file3 <- file.path(output_dir, "review-timing-over-time.png")
ggsave(output_file3, p3, width = 12, height = 6, dpi = 150)
cat(sprintf("Plot saved to: %s\n", output_file3))

cat("\nSuccessfully analyzed bot review timing\n")