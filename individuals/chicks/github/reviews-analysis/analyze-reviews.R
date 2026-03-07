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
  pr.title,
  pr.created_at,
  pr.total_pushes,
  pr.state,
  COUNT(DISTINCT CASE WHEN br.bot_type = 'claude' THEN br.review_id END) as claude_reviews,
  COUNT(DISTINCT CASE WHEN br.bot_type = 'copilot' THEN br.review_id END) as copilot_reviews,
  COUNT(DISTINCT br.review_id) as total_reviews
FROM pull_requests pr
LEFT JOIN bot_reviews br ON pr.repo_full_name = br.repo_full_name AND pr.pr_number = br.pr_number
GROUP BY pr.repo_full_name, pr.pr_number
"

pr_data <- dbGetQuery(con, query)
dbDisconnect(con)

pr_data$created_at <- as.POSIXct(pr_data$created_at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
pr_data$month <- floor_date(pr_data$created_at, "month")
pr_data$has_review <- pr_data$total_reviews > 0

pr_data <- pr_data %>%
  filter(created_at >= as.POSIXct("2025-05-01", tz = "UTC"))

monthly_stats <- pr_data %>%
  group_by(month) %>%
  summarize(
    total_prs = n(),
    prs_with_review = sum(has_review),
    claude_reviewed = sum(claude_reviews > 0),
    copilot_reviewed = sum(copilot_reviews > 0),
    coverage_pct = round(100 * sum(has_review) / n(), 1),
    claude_pct = round(100 * sum(claude_reviews > 0) / n(), 1),
    copilot_pct = round(100 * sum(copilot_reviews > 0) / n(), 1),
    .groups = "drop"
  ) %>%
  arrange(month)

cat("\n=== Bot Review Coverage Over Time ===\n\n")
print(monthly_stats, n = nrow(monthly_stats))

overall_coverage <- round(100 * sum(pr_data$has_review) / nrow(pr_data), 1)
cat("\n=== Overall Statistics ===\n")
cat(sprintf("Total PRs: %d\n", nrow(pr_data)))
cat(sprintf("PRs with at least one bot review: %d (%.1f%%)\n", 
    sum(pr_data$has_review), overall_coverage))
cat(sprintf("Claude reviews: %d PRs (%.1f%%)\n", 
    sum(pr_data$claude_reviews > 0), 
    round(100 * sum(pr_data$claude_reviews > 0) / nrow(pr_data), 1)))
cat(sprintf("Copilot reviews: %d PRs (%.1f%%)\n", 
    sum(pr_data$copilot_reviews > 0),
    round(100 * sum(pr_data$copilot_reviews > 0) / nrow(pr_data), 1)))

monthly_long <- monthly_stats %>%
  select(month, total_prs, claude_reviewed, copilot_reviewed) %>%
  tidyr::pivot_longer(
    cols = c(claude_reviewed, copilot_reviewed),
    names_to = "bot_type",
    values_to = "count"
  ) %>%
  mutate(
    pct = ifelse(bot_type == "claude_reviewed", 
                 monthly_stats$claude_pct[match(month, monthly_stats$month)],
                 monthly_stats$copilot_pct[match(month, monthly_stats$month)]),
    bot_type = ifelse(bot_type == "claude_reviewed", "Claude", "Copilot")
  )

monthly_stats$month_label <- format(monthly_stats$month, "%Y-%m")

plot_data <- monthly_stats
plot_data$month_num <- as.numeric(plot_data$month)

p1 <- ggplot(plot_data, aes(x = month, y = coverage_pct)) +
  geom_line(color = "#2E86AB", linewidth = 1.2) +
  geom_point(color = "#2E86AB", size = 2.5) +
  geom_hline(yintercept = overall_coverage, linetype = "dashed", 
             color = "#A23B72", alpha = 0.7) +
  annotate("text", x = min(plot_data$month), y = overall_coverage + 3,
           label = sprintf("Overall: %.1f%%", overall_coverage),
           hjust = 0, color = "#A23B72", size = 4, fontface = "bold") +
  scale_y_continuous(limits = c(0, 105), breaks = seq(0, 100, 20)) +
  scale_x_datetime(date_labels = "%b %Y", date_breaks = "3 months") +
  labs(
    title = "Expected Bot Review Coverage Over Time",
    subtitle = "Percentage of PRs receiving at least one bot review (Claude or Copilot)",
    x = NULL,
    y = "Coverage (%)"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    panel.grid.minor = element_blank(),
    plot.title = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(color = "gray40")
  )

output_dir <- file.path(repo_root, "individuals/chicks/github/reviews-analysis")
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

output_file <- file.path(output_dir, "coverage-over-time.png")

ggsave(output_file, p1, width = 12, height = 6, dpi = 150)
cat(sprintf("\nPlot saved to: %s\n", output_file))

p2 <- ggplot(plot_data, aes(x = month)) +
  geom_line(aes(y = claude_pct, color = "Claude"), linewidth = 1.2) +
  geom_point(aes(y = claude_pct, color = "Claude"), size = 2.5) +
  geom_line(aes(y = copilot_pct, color = "Copilot"), linewidth = 1.2) +
  geom_point(aes(y = copilot_pct, color = "Copilot"), size = 2.5) +
  scale_color_manual(values = c("Claude" = "#FF6B6B", "Copilot" = "#4ECDC4")) +
  scale_y_continuous(limits = c(0, 105), breaks = seq(0, 100, 20)) +
  scale_x_datetime(date_labels = "%b %Y", date_breaks = "3 months") +
  labs(
    title = "Bot Review Coverage by Type Over Time",
    subtitle = "Percentage of PRs reviewed by each bot type",
    x = NULL,
    y = "Coverage (%)",
    color = "Bot Type"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    panel.grid.minor = element_blank(),
    plot.title = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(color = "gray40"),
    legend.position = "top"
  )

output_file2 <- file.path(output_dir, "coverage-by-type.png")
ggsave(output_file2, p2, width = 12, height = 6, dpi = 150)
cat(sprintf("Plot saved to: %s\n", output_file2))

cat("\nSuccessfully analyzed bot review coverage over time\n")