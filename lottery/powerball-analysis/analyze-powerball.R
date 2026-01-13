#!/usr/bin/env Rscript
# analyze-powerball.R
# Analyzes Powerball lottery numbers to see frequency of each number drawn
# Author: Christopher Hicks
# Data source: NY Lottery Powerball Winning Numbers (Beginning 2010)

library(tidyverse)

# Read the Powerball data
cat("Reading Powerball data...\n")
lottery_data <- read_csv("../Lottery_Powerball_Winning_Numbers__Beginning_2010.csv",
                         col_types = cols(
                           `Draw Date` = col_date(format = "%m/%d/%Y"),
                           `Winning Numbers` = col_character(),
                           Multiplier = col_character()
                         ))

cat(sprintf("Loaded %d drawings from %s to %s\n",
            nrow(lottery_data),
            format(min(lottery_data$`Draw Date`), "%Y-%m-%d"),
            format(max(lottery_data$`Draw Date`), "%Y-%m-%d")))

# Parse the winning numbers (6 space-separated numbers: first 5 are main, 6th is Powerball)
# Split each row into 6 numbers, then separate main numbers from Powerball
all_numbers <- lottery_data %>%
  separate(`Winning Numbers`,
           into = c("n1", "n2", "n3", "n4", "n5", "powerball"),
           sep = " ",
           convert = TRUE)

# Extract main numbers (first 5 numbers, range 1-69)
main_numbers <- all_numbers %>%
  select(n1, n2, n3, n4, n5) %>%
  pivot_longer(cols = everything(), names_to = "position", values_to = "Number") %>%
  select(Number)

# Count frequency of each main number
main_freq <- main_numbers %>%
  count(Number, name = "Count") %>%
  arrange(desc(Count))

cat("\n=== MAIN NUMBERS FREQUENCY (1-69) ===\n")
cat("Top 10 most frequently drawn numbers:\n")
print(head(main_freq, 10), n = 10)

cat("\nBottom 10 least frequently drawn numbers:\n")
print(tail(main_freq, 10), n = 10)

# Powerball frequency analysis (6th number, range 1-26)
powerball_freq <- all_numbers %>%
  count(powerball, name = "Count") %>%
  arrange(desc(Count)) %>%
  rename(Powerball = powerball)

cat("\n=== POWERBALL FREQUENCY (1-26) ===\n")
cat("Top 10 most frequently drawn Powerballs:\n")
print(head(powerball_freq, 10), n = 10)

# Summary statistics
cat("\n=== SUMMARY STATISTICS ===\n")
cat(sprintf("Main Numbers - Mean frequency: %.1f\n", mean(main_freq$Count)))
cat(sprintf("Main Numbers - Median frequency: %.1f\n", median(main_freq$Count)))
cat(sprintf("Main Numbers - Std Dev: %.1f\n", sd(main_freq$Count)))
cat(sprintf("\nPowerball - Mean frequency: %.1f\n", mean(powerball_freq$Count)))
cat(sprintf("Powerball - Median frequency: %.1f\n", median(powerball_freq$Count)))
cat(sprintf("Powerball - Std Dev: %.1f\n", sd(powerball_freq$Count)))

# Save detailed results to CSV files
write_csv(main_freq, "powerball-main-numbers-frequency.csv")
write_csv(powerball_freq, "powerball-ball-frequency.csv")

cat("\n=== OUTPUT FILES ===\n")
cat("Main numbers frequency saved to: powerball-main-numbers-frequency.csv\n")
cat("Powerball frequency saved to: powerball-ball-frequency.csv\n")

# Create visualization (skip if running in test mode)
if (!isTRUE(getOption("skip.plots"))) {
  # Main numbers bar chart
  p1 <- ggplot(main_freq, aes(x = reorder(Number, -Count), y = Count)) +
    geom_col(fill = "firebrick") +
    labs(title = "Powerball Main Numbers Frequency",
         subtitle = sprintf("Based on %d drawings", nrow(lottery_data)),
         x = "Number",
         y = "Times Drawn") +
    theme_minimal() +
    theme(axis.text.x = element_text(angle = 90, hjust = 1, size = 6))

  ggsave("powerball-main-numbers-chart.png", p1, width = 12, height = 6, dpi = 300)

  # Powerball bar chart
  p2 <- ggplot(powerball_freq, aes(x = reorder(Powerball, -Count), y = Count)) +
    geom_col(fill = "red") +
    labs(title = "Powerball Frequency",
         subtitle = sprintf("Based on %d drawings", nrow(lottery_data)),
         x = "Powerball Number",
         y = "Times Drawn") +
    theme_minimal() +
    theme(axis.text.x = element_text(size = 10))

  ggsave("powerball-ball-chart.png", p2, width = 10, height = 6, dpi = 300)

  cat("\nVisualization files created:\n")
  cat("  - powerball-main-numbers-chart.png\n")
  cat("  - powerball-ball-chart.png\n")
}

cat("\nAnalysis complete!\n")
