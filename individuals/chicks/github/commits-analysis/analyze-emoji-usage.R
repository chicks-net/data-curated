# Emoji Usage Analysis
# Analyzes emoji frequency in GitHub commit messages

options(tidyverse.quiet = TRUE)
library(tidyverse, warn.conflicts = FALSE)
library(DBI)
library(RSQLite)
library(lubridate)
library(scales, warn.conflicts = FALSE)

# Connect to the database
conn <- dbConnect(RSQLite::SQLite(), "../commits.db")

# Load commits data
commits <- dbGetQuery(conn, "
  SELECT sha, message, author_date, author_name, repo_full_name
  FROM commits
  WHERE message IS NOT NULL
")

# Close database connection
dbDisconnect(conn)

# Function to extract emojis from text
# Unicode emoji ranges (common ranges, not exhaustive but covers most)
extract_emojis <- function(text) {
  # Define emoji Unicode ranges
  emoji_pattern <- "[\U0001F300-\U0001F9FF]|[\U00002600-\U000027BF]|[\U0001F000-\U0001F0FF]|[\U0001FA00-\U0001FAFF]|[\U00002300-\U000023FF]"

  # Extract all emojis
  matches <- str_extract_all(text, emoji_pattern)
  unlist(matches)
}

# Extract emojis from all commit messages
cat("Extracting emojis from commit messages...\n")
all_emojis <- commits %>%
  mutate(emojis = map(message, extract_emojis)) %>%
  select(sha, message, emojis, author_date, author_name, repo_full_name) %>%
  unnest(emojis)

# Basic statistics
cat("\nTotal commits analyzed:", nrow(commits), "\n")
cat("Commits with emojis:", n_distinct(all_emojis$sha), "\n")
cat("Total emojis found:", nrow(all_emojis), "\n")
cat("Unique emojis:", n_distinct(all_emojis$emojis), "\n")

emoji_percentage <- (n_distinct(all_emojis$sha) / nrow(commits)) * 100
cat(sprintf("Percentage of commits with emojis: %.1f%%\n", emoji_percentage))

# Count emoji frequencies
emoji_counts <- all_emojis %>%
  count(emojis, sort = TRUE) %>%
  mutate(
    percentage = n / sum(n) * 100,
    rank = row_number()
  )

cat("\nTop 20 most common emojis:\n")
top_20 <- emoji_counts %>%
  slice_head(n = 20) %>%
  mutate(percentage = round(percentage, 1))
print(top_20)

# Calculate cumulative percentage
emoji_counts <- emoji_counts %>%
  mutate(cumulative_pct = cumsum(percentage))

# Find how many emojis are needed to reach at least 80% of usage
top_80_index <- which(emoji_counts$cumulative_pct >= 80)[1]
if (is.na(top_80_index)) {
  top_80 <- nrow(emoji_counts)
} else {
  top_80 <- top_80_index
}

cat(sprintf("\nTop %d emojis account for at least 80%% of all emoji usage\n", top_80))

# Create visualization of top emojis
top_n_emojis <- 20
plot_data <- emoji_counts %>% slice_head(n = top_n_emojis)

p1 <- ggplot(plot_data, aes(x = reorder(emojis, n), y = n)) +
  geom_col(fill = "steelblue", alpha = 0.7) +
  geom_text(aes(label = comma_format()(n)),
            hjust = -0.2, size = 3) +
  scale_y_continuous(labels = comma_format(),
                     expand = expansion(mult = c(0, 0.15))) +
  labs(
    title = "Top 20 Most Frequently Used Emojis in Commit Messages",
    subtitle = paste("Analysis of", comma_format()(nrow(all_emojis)),
                     "emojis across", comma_format()(nrow(commits)), "commits"),
    x = "Emoji",
    y = "Frequency"
  ) +
  theme_minimal() +
  theme(
    axis.text.y = element_text(size = 14),
    plot.title = element_text(face = "bold", size = 16),
    plot.subtitle = element_text(size = 12)
  ) +
  coord_flip()

# Analyze emoji usage over time
if (nrow(all_emojis) > 0) {
  emoji_timeline <- all_emojis %>%
    mutate(
      author_datetime = ymd_hms(author_date),
      month = floor_date(author_datetime, "month")
    ) %>%
    group_by(month) %>%
    summarize(
      emoji_count = n(),
      commit_count = n_distinct(sha),
      .groups = "drop"
    ) %>%
    mutate(
      emojis_per_commit = emoji_count / commit_count
    ) %>%
    arrange(month)

  p2 <- ggplot(emoji_timeline, aes(x = month, y = emojis_per_commit)) +
    geom_line(color = "steelblue", linewidth = 1) +
    geom_point(color = "darkblue", size = 2) +
    scale_y_continuous(labels = number_format(accuracy = 0.1)) +
    scale_x_datetime(date_labels = "%Y-%m", date_breaks = "3 months") +
    labs(
      title = "Average Emojis Per Commit Over Time",
      subtitle = paste("Monthly trend from",
                       format(min(emoji_timeline$month), "%Y-%m"), "to",
                       format(max(emoji_timeline$month), "%Y-%m")),
      x = "Month",
      y = "Emojis Per Commit"
    ) +
    theme_minimal() +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1),
      plot.title = element_text(face = "bold", size = 16),
      plot.subtitle = element_text(size = 12)
    )
}

# Analyze emoji usage by repository
emoji_by_repo <- all_emojis %>%
  group_by(repo_full_name) %>%
  summarize(
    emoji_count = n(),
    commit_count = n_distinct(sha),
    unique_emojis = n_distinct(emojis),
    .groups = "drop"
  ) %>%
  mutate(
    emojis_per_commit = emoji_count / commit_count
  ) %>%
  arrange(desc(emoji_count)) %>%
  slice_head(n = 15)

p3 <- ggplot(emoji_by_repo, aes(x = reorder(repo_full_name, emoji_count), y = emoji_count)) +
  geom_col(fill = "coral", alpha = 0.7) +
  geom_text(aes(label = paste0(comma_format()(emoji_count), " (", round(emojis_per_commit, 1), "/commit)")),
            hjust = -0.1, size = 3) +
  scale_y_continuous(labels = comma_format(),
                     expand = expansion(mult = c(0, 0.2))) +
  labs(
    title = "Emoji Usage by Repository",
    subtitle = "Top 15 repositories by emoji count (with average emojis per commit)",
    x = "Repository",
    y = "Total Emojis"
  ) +
  theme_minimal() +
  theme(
    axis.text.y = element_text(size = 9),
    plot.title = element_text(face = "bold", size = 16),
    plot.subtitle = element_text(size = 12)
  ) +
  coord_flip()

# Save plots
ggsave("emoji-frequency.png", p1, width = 10, height = 8, dpi = 300)
cat("\nSaved: emoji-frequency.png\n")

if (exists("p2")) {
  ggsave("emoji-timeline.png", p2, width = 12, height = 6, dpi = 300)
  cat("Saved: emoji-timeline.png\n")
}

ggsave("emoji-by-repo.png", p3, width = 12, height = 8, dpi = 300)
cat("Saved: emoji-by-repo.png\n")

# Save summary data
write_csv(emoji_counts, "emoji-frequency.csv", na = "NA")
cat("Saved: emoji-frequency.csv\n")

if (exists("emoji_timeline")) {
  write_csv(emoji_timeline, "emoji-timeline.csv", na = "NA")
  cat("Saved: emoji-timeline.csv\n")
}

write_csv(emoji_by_repo, "emoji-by-repo.csv", na = "NA")
cat("Saved: emoji-by-repo.csv\n")

# Create summary statistics
summary_stats <- tibble(
  metric = c(
    "Total commits",
    "Commits with emojis",
    "Total emojis",
    "Unique emojis",
    "Percentage of commits with emojis",
    "Average emojis per commit (when used)",
    "Most common emoji",
    "Most common emoji frequency"
  ),
  value = c(
    nrow(commits),
    n_distinct(all_emojis$sha),
    nrow(all_emojis),
    n_distinct(all_emojis$emojis),
    round(emoji_percentage, 1),
    round(nrow(all_emojis) / n_distinct(all_emojis$sha), 2),
    emoji_counts$emojis[1],
    emoji_counts$n[1]
  )
)

write_csv(summary_stats, "emoji-summary.csv", na = "NA")
cat("Saved: emoji-summary.csv\n")

cat("\nAnalysis complete!\n")
