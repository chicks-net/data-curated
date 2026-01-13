#!/usr/bin/env Rscript
# analyze-megamillions.R
# Analyzes Mega Millions lottery numbers to see frequency of each number drawn
# Author: Christopher Hicks
# Data source: NY Lottery Mega Millions Winning Numbers (Beginning 2002)

library(tidyverse)

# Read the Mega Millions data
cat("Reading Mega Millions data...\n")
lottery_data <- read_csv("../Lottery_Mega_Millions_Winning_Numbers__Beginning_2002.csv",
                         col_types = cols(
                           `Draw Date` = col_date(format = "%m/%d/%Y"),
                           `Winning Numbers` = col_character(),
                           `Mega Ball` = col_character(),
                           Multiplier = col_character()
                         ))

cat(sprintf("Loaded %d drawings from %s to %s\n",
            nrow(lottery_data),
            format(min(lottery_data$`Draw Date`), "%Y-%m-%d"),
            format(max(lottery_data$`Draw Date`), "%Y-%m-%d")))

# Parse the winning numbers (5 main numbers)
main_numbers <- lottery_data %>%
  separate_rows(`Winning Numbers`, sep = " ") %>%
  filter(`Winning Numbers` != "") %>%
  mutate(Number = as.integer(`Winning Numbers`)) %>%
  select(Number)

# Count frequency of each main number
main_freq <- main_numbers %>%
  count(Number, name = "Count") %>%
  arrange(desc(Count))

cat("\n=== MAIN NUMBERS FREQUENCY (1-70) ===\n")
cat("Top 10 most frequently drawn numbers:\n")
print(head(main_freq, 10), n = 10)

cat("\nBottom 10 least frequently drawn numbers:\n")
print(tail(main_freq, 10), n = 10)

# Mega Ball frequency analysis
mega_ball_freq <- lottery_data %>%
  mutate(`Mega Ball` = as.integer(`Mega Ball`)) %>%
  count(`Mega Ball`, name = "Count") %>%
  arrange(desc(Count))

cat("\n=== MEGA BALL FREQUENCY (1-25) ===\n")
cat("Top 10 most frequently drawn Mega Balls:\n")
print(head(mega_ball_freq, 10), n = 10)

# Summary statistics
cat("\n=== SUMMARY STATISTICS ===\n")
cat(sprintf("Main Numbers - Mean frequency: %.1f\n", mean(main_freq$Count)))
cat(sprintf("Main Numbers - Median frequency: %.1f\n", median(main_freq$Count)))
cat(sprintf("Main Numbers - Std Dev: %.1f\n", sd(main_freq$Count)))
cat(sprintf("\nMega Ball - Mean frequency: %.1f\n", mean(mega_ball_freq$Count)))
cat(sprintf("Mega Ball - Median frequency: %.1f\n", median(mega_ball_freq$Count)))
cat(sprintf("Mega Ball - Std Dev: %.1f\n", sd(mega_ball_freq$Count)))

# Save detailed results to CSV files
write_csv(main_freq, "megamillions-main-numbers-frequency.csv")
write_csv(mega_ball_freq, "megamillions-mega-ball-frequency.csv")

cat("\n=== OUTPUT FILES ===\n")
cat("Main numbers frequency saved to: megamillions-main-numbers-frequency.csv\n")
cat("Mega Ball frequency saved to: megamillions-mega-ball-frequency.csv\n")

# Create visualization if possible
if (interactive() || !is.null(getOption("device"))) {
  # Main numbers bar chart
  p1 <- ggplot(main_freq, aes(x = reorder(Number, -Count), y = Count)) +
    geom_col(fill = "steelblue") +
    labs(title = "Mega Millions Main Numbers Frequency",
         subtitle = sprintf("Based on %d drawings", nrow(lottery_data)),
         x = "Number",
         y = "Times Drawn") +
    theme_minimal() +
    theme(axis.text.x = element_text(angle = 90, hjust = 1, size = 6))

  ggsave("megamillions-main-numbers-chart.png", p1, width = 12, height = 6, dpi = 300)

  # Mega Ball bar chart
  p2 <- ggplot(mega_ball_freq, aes(x = reorder(`Mega Ball`, -Count), y = Count)) +
    geom_col(fill = "gold") +
    labs(title = "Mega Millions Mega Ball Frequency",
         subtitle = sprintf("Based on %d drawings", nrow(lottery_data)),
         x = "Mega Ball Number",
         y = "Times Drawn") +
    theme_minimal() +
    theme(axis.text.x = element_text(size = 10))

  ggsave("megamillions-mega-ball-chart.png", p2, width = 10, height = 6, dpi = 300)

  cat("\nVisualization files created:\n")
  cat("  - megamillions-main-numbers-chart.png\n")
  cat("  - megamillions-mega-ball-chart.png\n")
}

cat("\nAnalysis complete!\n")
