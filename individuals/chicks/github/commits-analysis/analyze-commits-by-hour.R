# Commits by Hour Analysis
# Analyzes GitHub commit patterns by hour of the day

library(tidyverse)
library(DBI)
library(RSQLite)
library(lubridate)
library(scales)

# Connect to the database
conn <- dbConnect(RSQLite::SQLite(), "../commits.db")

# Load commits data
commits <- dbGetQuery(conn, "
  SELECT author_date, author_name, repo_full_name 
  FROM commits 
  WHERE author_date IS NOT NULL
")

# Close database connection
dbDisconnect(conn)

# Convert to datetime and extract hour
commits <- commits %>%
  mutate(
    author_datetime = ymd_hms(author_date),
    hour = hour(author_datetime),
    hour_label = factor(hour, levels = 0:23)
  )

# Basic statistics
cat("Total commits analyzed:", nrow(commits), "\n")
cat("Date range:", min(commits$author_datetime), "to", max(commits$author_datetime), "\n\n")

# Hourly distribution
hourly_counts <- commits %>%
  count(hour, sort = TRUE) %>%
  mutate(
    hour_label = factor(hour, levels = 0:23),
    percentage = n / sum(n) * 100
  ) %>%
  arrange(hour)

cat("Commits by hour of day:\n")
print(hourly_counts %>% 
      select(hour, n, percentage) %>% 
      mutate(percentage = round(percentage, 1)))

# Find peak hours
peak_hours <- hourly_counts %>%
  arrange(desc(n)) %>%
  slice_head(n = 3)

cat("\nPeak commit hours:\n")
for(i in 1:nrow(peak_hours)) {
  cat(sprintf("%02d:00: %d commits (%.1f%%)\n", 
              peak_hours$hour[i], 
              peak_hours$n[i], 
              peak_hours$percentage[i]))
}

# Create visualization
p1 <- ggplot(hourly_counts, aes(x = hour_label, y = n)) +
  geom_col(fill = "steelblue", alpha = 0.7) +
  geom_line(aes(group = 1), color = "darkblue", size = 1) +
  geom_point(aes(group = 1), color = "darkblue", size = 2) +
  scale_x_discrete(labels = paste0(sprintf("%02d", 0:23), ":00")) +
  scale_y_continuous(labels = comma_format()) +
  labs(
    title = "GitHub Commits by Hour of Day",
    subtitle = paste("Analysis of", comma_format()(nrow(commits)), "commits"),
    x = "Hour of Day",
    y = "Number of Commits"
  ) +
  theme_minimal() +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    plot.title = element_text(face = "bold", size = 16),
    plot.subtitle = element_text(size = 12)
  )

# Create percentage chart
p2 <- ggplot(hourly_counts, aes(x = hour_label, y = percentage)) +
  geom_col(fill = "coral", alpha = 0.7) +
  geom_line(aes(group = 1), color = "darkred", size = 1) +
  geom_point(aes(group = 1), color = "darkred", size = 2) +
  scale_x_discrete(labels = paste0(sprintf("%02d", 0:23), ":00")) +
  scale_y_continuous(labels = percent_format()) +
  labs(
    title = "Commits by Hour of Day (Percentage)",
    x = "Hour of Day",
    y = "Percentage of Total Commits"
  ) +
  theme_minimal() +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    plot.title = element_text(face = "bold", size = 16)
  )

# Analyze by time of day (morning, afternoon, evening, night)
time_periods <- commits %>%
  mutate(
    time_period = case_when(
      hour >= 6 & hour < 12 ~ "Morning (6am-12pm)",
      hour >= 12 & hour < 18 ~ "Afternoon (12pm-6pm)",
      hour >= 18 & hour < 24 ~ "Evening (6pm-12am)",
      hour >= 0 & hour < 6 ~ "Night (12am-6am)"
    )
  ) %>%
  count(time_period) %>%
  mutate(percentage = n / sum(n) * 100) %>%
  arrange(desc(n))

cat("\nCommits by time period:\n")
print(time_periods %>% mutate(percentage = round(percentage, 1)))

# Time period visualization
p3 <- ggplot(time_periods, aes(x = reorder(time_period, n), y = n, fill = time_period)) +
  geom_col(alpha = 0.8) +
  geom_text(aes(label = paste0(comma_format()(n), "\n", percent(percentage/100))), 
            hjust = 0.5, vjust = -0.5, size = 3) +
  scale_y_continuous(labels = comma_format()) +
  labs(
    title = "Commits by Time Period",
    subtitle = "Distribution across morning, afternoon, evening, and night",
    x = NULL,
    y = "Number of Commits"
  ) +
  theme_minimal() +
  theme(
    legend.position = "none",
    plot.title = element_text(face = "bold", size = 16),
    plot.subtitle = element_text(size = 12)
  ) +
  coord_flip()

# Save plots
ggsave("commits-by-hour.png", p1, width = 12, height = 6, dpi = 300)
ggsave("commits-by-hour-percentage.png", p2, width = 12, height = 6, dpi = 300)
ggsave("commits-by-time-period.png", p3, width = 10, height = 6, dpi = 300)

# Save summary data
write_csv(hourly_counts, "hourly-commit-distribution.csv", na = "NA")
write_csv(time_periods, "time-period-distribution.csv", na = "NA")

cat("\nAnalysis complete! Files saved:\n")
cat("- commits-by-hour.png\n")
cat("- commits-by-hour-percentage.png\n") 
cat("- commits-by-time-period.png\n")
cat("- hourly-commit-distribution.csv\n")
cat("- time-period-distribution.csv\n")