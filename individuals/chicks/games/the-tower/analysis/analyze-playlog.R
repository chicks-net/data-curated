#!/usr/bin/env Rscript
# The Tower Playlog Analysis
# Analyzes play log data showing minutes per billion coins by tier

library(ggplot2)
library(dplyr)
library(scales)
library(zoo)
library(lubridate)

data_path <- "../the_tower_playlog.tsv"

cat("Reading data from:", data_path, "\n")

df <- read.delim(data_path, header = TRUE, sep = "\t", stringsAsFactors = FALSE, check.names = FALSE)

cat("Loaded", nrow(df), "records\n")

df <- df %>%
  filter(!is.na(Date) & Date != "" & !grepl("weekend|^[[:space:]]*$", Date)) %>%
  mutate(
    Date = as.Date(Date),
    Tier = as.integer(Tier),
    `Finish Wave` = as.integer(`Finish Wave`),
    Percentage = as.numeric(gsub("[^0-9.]", "", Percentage)),
    `Minutes/Billion` = as.numeric(gsub("[^0-9.]", "", `Minutes/Billion`)),
    `Time (minutes)` = as.numeric(`Time (minutes)`),
    `Total Coins (B)` = as.numeric(`Total Coins (B)`),
    `Dissonant Run` = ifelse(is.na(`Dissonant Run`) | `Dissonant Run` == "", NA_character_, `Dissonant Run`)
  ) %>%
  filter(!is.na(Date) & !is.na(Tier))

tournament_df_raw <- df %>% filter(Tier < 0)

positive_tiers_df <- df %>% filter(Tier > 0 & !is.na(`Minutes/Billion`))

# Count outliers (Minutes/Billion > 100) before filtering
outliers_count <- positive_tiers_df %>%
  filter(`Minutes/Billion` >= 100) %>%
  nrow()

# Filter to reasonable values: >0 and <100 minutes per billion
# Values >=100 are outliers that skew the visualization excessively
df <- positive_tiers_df %>%
  filter(`Minutes/Billion` > 0 & `Minutes/Billion` < 100 & `Time (minutes)` > 0)

dissonant_count <- sum(!is.na(df$`Dissonant Run`))
cat("Dissonant run records:", dissonant_count, "\n")

df_all <- df
df <- df %>% filter(is.na(`Dissonant Run`))

df$Tier_Factor <- factor(df$Tier)

cat("Filtered to", nrow(df), "valid records\n\n")

cat("=== TIER SUMMARY ===\n\n")
tier_summary <- df %>%
  group_by(Tier) %>%
  summarise(
    count = n(),
    avg_min_per_b = mean(`Minutes/Billion`, na.rm = TRUE),
    median_min_per_b = median(`Minutes/Billion`, na.rm = TRUE),
    min_val = min(`Minutes/Billion`, na.rm = TRUE),
    max_val = max(`Minutes/Billion`, na.rm = TRUE),
    .groups = "drop"
  )
print(tier_summary)
cat("\n")

cat("Generating visualization...\n")

tier_colors <- c(
  "15" = "#6A0DAD", "14" = "#7B2D8E", "13" = "#8B4D6F", "12" = "#9B6D50",
  "11" = "#AB8D31", "10" = "#DAA520", "9" = "#CD853F", "8" = "#D2691E",
  "7" = "#228B22", "6" = "#2E8B57", "5" = "#20B2AA", "4" = "#5F9EA0",
  "3" = "#4682B4", "2" = "#6495ED", "1" = "#87CEEB"
)

present_tiers <- unique(df$Tier_Factor)
tier_colors <- tier_colors[names(tier_colors) %in% present_tiers]

df_tier10plus_mp <- df %>% 
  filter(Tier >= 10) %>% 
  group_by(Tier) %>% 
  filter(n() >= 20) %>% 
  ungroup()

tier_labels_mp <- df_tier10plus_mp %>%
  group_by(Tier) %>%
  arrange(desc(Date)) %>%
  slice_head(n = 30) %>%
  summarise(
    end_date = max(Date),
    avg_last_30 = mean(`Minutes/Billion`, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(label = sprintf("T%d: %.1f", Tier, avg_last_30))

p <- ggplot(df, aes(x = Date, y = `Minutes/Billion`, color = Tier_Factor)) +
  geom_point(size = 1.5, alpha = 0.7) +
  geom_smooth(data = df_tier10plus_mp, aes(group = Tier_Factor),
              method = "loess", se = FALSE, linewidth = 1, linetype = "dashed") +
  geom_text(data = tier_labels_mp, aes(x = end_date, y = avg_last_30, 
             label = paste0("  ", label), color = factor(Tier)),
            hjust = 0, size = 3, fontface = "bold", show.legend = FALSE) +
  scale_color_manual(
    name = "Tier",
    values = tier_colors,
    drop = FALSE
  ) +
  scale_x_date(date_labels = "%b %Y", date_breaks = "1 month", expand = c(0.05, 0, 0.1, 0)) +
  scale_y_continuous(labels = comma_format(accuracy = 1), limits = c(0, 100)) +
  labs(
    title = "The Tower: Minutes per Billion Coins by Tier",
    subtitle = sprintf("n = %d plays (regular tiers, dissonant runs excluded)", nrow(df)),
    x = "Date",
    y = "Minutes per Billion Coins",
    caption = sprintf("Trend lines shown for tiers 10+ with ≥20 points. Labels show avg of last 30 plays. %d outlier(s) excluded (>=100 min/billion). %d dissonant run(s) excluded.", outliers_count, dissonant_count)
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 11),
    plot.caption = element_text(size = 9, hjust = 0),
    axis.text.x = element_text(angle = 45, hjust = 1),
    legend.position = "right",
    legend.title = element_text(face = "bold"),
    panel.grid.minor = element_blank()
  )

ggsave("minutes-per-billion-by-tier.png", p, width = 14, height = 10, dpi = 300)

df_zoom <- df %>%
  filter(Date >= as.Date("2025-09-01") & `Minutes/Billion` < 20)

zoom_excluded_date <- nrow(df) - nrow(df %>% filter(Date >= as.Date("2025-09-01")))
zoom_excluded_efficiency <- nrow(df %>% filter(Date >= as.Date("2025-09-01") & `Minutes/Billion` >= 20 & `Minutes/Billion` < 100))

df_tier10plus_mp_zoom <- df_zoom %>%
  filter(Tier >= 10) %>%
  group_by(Tier) %>%
  filter(n() >= 20) %>%
  ungroup()

tier_labels_mp_zoom <- df_tier10plus_mp_zoom %>%
  group_by(Tier) %>%
  arrange(desc(Date)) %>%
  slice_head(n = 30) %>%
  summarise(
    end_date = max(Date),
    avg_last_30 = mean(`Minutes/Billion`, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(label = sprintf("T%d: %.1f", Tier, avg_last_30))

p_zoom <- ggplot(df_zoom, aes(x = Date, y = `Minutes/Billion`, color = Tier_Factor)) +
  geom_point(size = 1.5, alpha = 0.7) +
  geom_smooth(data = df_tier10plus_mp_zoom, aes(group = Tier_Factor),
              method = "loess", se = FALSE, linewidth = 1, linetype = "dashed") +
  geom_text(data = tier_labels_mp_zoom, aes(x = end_date, y = avg_last_30,
             label = paste0("  ", label), color = factor(Tier)),
            hjust = 0, size = 3, fontface = "bold", show.legend = FALSE) +
  scale_color_manual(
    name = "Tier",
    values = tier_colors,
    drop = FALSE
  ) +
  scale_x_date(date_labels = "%b %Y", date_breaks = "1 month", expand = c(0.05, 0, 0.1, 0)) +
  scale_y_continuous(labels = comma_format(accuracy = 1), limits = c(0, 20)) +
  labs(
    title = "The Tower: Minutes per Billion Coins by Tier (Zoomed, < 20 min/B)",
    subtitle = sprintf("n = %d plays | Since Sep 2025 | Dissonant runs excluded", nrow(df_zoom)),
    x = "Date",
    y = "Minutes per Billion Coins",
    caption = sprintf("Trend lines for tiers 10+ with >=20 points in range. %d pre-Sep-2025 point(s) and %d point(s) >= 20 min/billion excluded from view.", zoom_excluded_date, zoom_excluded_efficiency)
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 11),
    plot.caption = element_text(size = 9, hjust = 0),
    axis.text.x = element_text(angle = 45, hjust = 1),
    legend.position = "right",
    legend.title = element_text(face = "bold"),
    panel.grid.minor = element_blank()
  )

ggsave("minutes-per-billion-by-tier-zoom.png", p_zoom, width = 14, height = 10, dpi = 300)

daily_summary <- df_all %>%
  group_by(Date) %>%
  summarise(
    total_billions = sum(`Total Coins (B)`, na.rm = TRUE),
    total_minutes = sum(`Time (minutes)`, na.rm = TRUE),
    total_hours = sum(`Time (minutes)`, na.rm = TRUE) / 60,
    num_plays = n(),
    .groups = "drop"
  ) %>%
  arrange(Date) %>%
  mutate(
    rolling_avg_14 = rollmean(total_billions, k = 14, fill = NA, align = "right"),
    rolling_avg_hours_14 = rollmean(total_hours, k = 14, fill = NA, align = "right")
  )

cat("\n=== DAILY SUMMARY ===\n\n")
print(daily_summary %>% 
  arrange(desc(Date)) %>% 
  head(10))
cat("\n")

p2 <- ggplot(daily_summary, aes(x = Date, y = total_billions)) +
  geom_col(fill = "#DAA520", alpha = 0.8) +
  geom_line(aes(y = rolling_avg_14), color = "#8B0000", linewidth = 1.2) +
  scale_x_date(date_labels = "%b %Y", date_breaks = "1 month") +
  scale_y_continuous(labels = comma_format(accuracy = 1)) +
  labs(
    title = "The Tower: Total Billions Earned per Day",
    subtitle = sprintf("%d days of play | Total: %.1f billions | Red line = 14-day rolling avg (includes dissonant runs)", 
                        nrow(daily_summary), sum(daily_summary$total_billions)),
    x = "Date",
    y = "Billions Earned"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 11),
    axis.text.x = element_text(angle = 45, hjust = 1),
    panel.grid.minor = element_blank()
  )

ggsave("billions-per-day.png", p2, width = 14, height = 6, dpi = 300)

p3 <- ggplot(daily_summary, aes(x = Date, y = total_hours)) +
  geom_hline(yintercept = 24, linetype = "dashed", color = "gray50") +
  geom_col(fill = "#228B22", alpha = 0.8) +
  geom_line(aes(y = rolling_avg_hours_14), color = "#8B0000", linewidth = 1.2) +
  scale_x_date(date_labels = "%b %Y", date_breaks = "1 month") +
  scale_y_continuous(labels = comma_format(accuracy = 1)) +
  labs(
    title = "The Tower: Hours Played per Day",
    subtitle = sprintf("%d days of play | Total: %.1f hours | Red line = 14-day rolling avg (includes dissonant runs)", 
                        nrow(daily_summary), 
                        sum(daily_summary$total_hours)),
    x = "Date",
    y = "Hours Played"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 11),
    axis.text.x = element_text(angle = 45, hjust = 1),
    panel.grid.minor = element_blank()
  )

ggsave("hours-per-day.png", p3, width = 14, height = 6, dpi = 300)

df_tier10plus <- df %>% filter(Tier >= 10)

time_outliers_count <- df %>%
  filter(`Time (minutes)` / 60 > 10) %>%
  nrow()

tier_labels <- df_tier10plus %>%
  group_by(Tier, Tier_Factor) %>%
  arrange(desc(Date)) %>%
  slice_head(n = 10) %>%
  summarise(
    end_date = max(Date),
    end_hours = mean(`Time (minutes)` / 60),
    .groups = "drop"
  ) %>%
  mutate(
    hours = floor(end_hours),
    minutes = round((end_hours - hours) * 60),
    label = sprintf("Tier %d: %dh%02dm", Tier, hours, minutes)
  )

p4 <- ggplot(df, aes(x = Date, y = `Time (minutes)` / 60, color = Tier_Factor)) +
  geom_point(size = 1.5, alpha = 0.7) +
  geom_smooth(data = df_tier10plus, aes(group = Tier_Factor), 
              method = "loess", se = FALSE, linewidth = 1, linetype = "dashed") +
  geom_text(data = tier_labels, aes(x = end_date, y = end_hours, 
             label = paste0("  ", label)), 
            hjust = 0, size = 3, fontface = "bold") +
  scale_color_manual(
    name = "Tier",
    values = tier_colors,
    drop = FALSE
  ) +
  scale_x_date(date_labels = "%b %Y", date_breaks = "1 month", expand = c(0.05, 0, 0.1, 0)) +
  scale_y_continuous(labels = comma_format(accuracy = 1)) +
  coord_cartesian(ylim = c(0, 10)) +
  labs(
    title = "The Tower: Time to Finish Levels",
    subtitle = sprintf("n = %d plays (regular tiers, dissonant runs excluded)", nrow(df)),
    x = "Date",
    y = "Time (Hours)",
    caption = sprintf("Trend lines shown for tiers 10+ only. %d outlier(s) not shown (>10 hours). Dissonant runs excluded.", time_outliers_count)
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 11),
    plot.caption = element_text(size = 9, hjust = 0),
    axis.text.x = element_text(angle = 45, hjust = 1),
    legend.position = "right",
    legend.title = element_text(face = "bold"),
    panel.grid.minor = element_blank()
  )

ggsave("time-to-finish.png", p4, width = 14, height = 10, dpi = 300)

p5 <- ggplot(df_tier10plus, aes(x = Tier_Factor, y = Percentage)) +
  geom_boxplot(fill = "#4682B4", alpha = 0.7, outlier.shape = 1) +
  scale_y_continuous(labels = comma_format(accuracy = 1)) +
  labs(
    title = "The Tower: Percentage Score Distribution by Tier (Tiers 10+)",
    subtitle = sprintf("n = %d plays across %d tiers", nrow(df_tier10plus), length(unique(df_tier10plus$Tier))),
    x = "Tier",
    y = "Percentage of Prior Max Score"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold"),
    plot.subtitle = element_text(size = 11),
    axis.text.x = element_text(size = 11),
    panel.grid.minor = element_blank()
  )

ggsave("percentage-by-tier-boxplot.png", p5, width = 10, height = 8, dpi = 300)

cat("\n=== TOURNAMENT ANALYSIS ===\n\n")

tournament_df <- tournament_df_raw %>%
  mutate(Tournament_Tier = abs(Tier)) %>%
  filter(!is.na(`Finish Wave`) & `Finish Wave` > 0)

cat("Tournament records found:", nrow(tournament_df), "\n")

tournament_counts <- tournament_df %>%
  group_by(Tournament_Tier) %>%
  summarise(count = n(), .groups = "drop")

valid_tiers <- tournament_counts %>% filter(count >= 10) %>% pull(Tournament_Tier)
excluded_count <- sum(tournament_counts %>% filter(count < 10) %>% pull(count))

cat("Tournament tiers with >= 10 plays:", paste(sort(valid_tiers), collapse = ", "), "\n")
if (excluded_count > 0) {
  cat("Excluded", excluded_count, "plays from tiers with < 10 data points\n")
}
cat("\n")

tournament_df <- tournament_df %>% filter(Tournament_Tier %in% valid_tiers)

if (nrow(tournament_df) > 0) {
  tournament_summary <- tournament_df %>%
    group_by(Tournament_Tier) %>%
    summarise(
      count = n(),
      avg_wave = mean(`Finish Wave`, na.rm = TRUE),
      max_wave = max(`Finish Wave`, na.rm = TRUE),
      avg_coins = mean(`Total Coins (B)`, na.rm = TRUE),
      avg_time = mean(`Time (minutes)`, na.rm = TRUE),
      .groups = "drop"
    )
  print(tournament_summary)
  cat("\n")
  
  tournament_df$Tier_Label <- paste0("T-", tournament_df$Tournament_Tier)
  tier_levels <- sort(unique(tournament_df$Tournament_Tier))
  tournament_df$Tier_Factor <- factor(tournament_df$Tier_Label, levels = paste0("T-", tier_levels))
  
  tournament_colors <- setNames(
    scales::hue_pal()(length(tier_levels)),
    paste0("T-", tier_levels)
  )
  
  p6 <- ggplot(tournament_df, aes(x = Date, y = `Finish Wave`, color = Tier_Factor)) +
    geom_point(size = 2, alpha = 0.8) +
    geom_smooth(aes(group = Tier_Factor), method = "loess", se = FALSE, linewidth = 1) +
    scale_color_manual(name = "Tournament", values = tournament_colors, drop = FALSE) +
    scale_x_date(date_labels = "%b %Y", date_breaks = "1 month") +
    scale_y_continuous(labels = comma_format(accuracy = 1)) +
    labs(
      title = "The Tower: Tournament Waves Achieved Over Time",
      subtitle = sprintf("n = %d tournament plays (tiers with >= 10 plays only)", nrow(tournament_df)),
      x = "Date",
      y = "Waves Achieved"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = 16, face = "bold"),
      plot.subtitle = element_text(size = 11),
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = "right",
      legend.title = element_text(face = "bold"),
      panel.grid.minor = element_blank()
    )
  
  ggsave("tournament-waves.png", p6, width = 12, height = 6, dpi = 300)
  
  tournament_daily_by_tier <- tournament_df %>%
    group_by(Date, Tier_Label, Tier_Factor) %>%
    summarise(
      total_coins = sum(`Total Coins (B)`, na.rm = TRUE),
      total_time = sum(`Time (minutes)`, na.rm = TRUE),
      num_plays = n(),
      .groups = "drop"
    )
  
  p7 <- ggplot(tournament_daily_by_tier, aes(x = Date, y = total_coins, fill = Tier_Factor)) +
    geom_col(position = "stack", alpha = 0.8) +
    geom_smooth(aes(group = Tier_Factor, color = Tier_Factor), method = "loess", se = FALSE, linewidth = 1) +
    scale_fill_manual(name = "Tournament", values = tournament_colors, drop = FALSE) +
    scale_color_manual(name = "Tournament", values = tournament_colors, drop = FALSE) +
    scale_x_date(date_labels = "%b %Y", date_breaks = "1 month") +
    scale_y_continuous(labels = comma_format(accuracy = 1)) +
    labs(
      title = "The Tower: Tournament Coins Earned Over Time",
      subtitle = sprintf("n = %d tournament plays | Total: %.1f billions", 
                         nrow(tournament_df), sum(tournament_daily_by_tier$total_coins, na.rm = TRUE)),
      x = "Date",
      y = "Total Coins (Billions)"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = 16, face = "bold"),
      plot.subtitle = element_text(size = 11),
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = "right",
      legend.title = element_text(face = "bold"),
      panel.grid.minor = element_blank()
    )
  
  ggsave("tournament-coins.png", p7, width = 12, height = 6, dpi = 300)
  
  p8 <- ggplot(tournament_daily_by_tier, aes(x = Date, y = total_time / 60, fill = Tier_Factor)) +
    geom_col(position = "stack", alpha = 0.8) +
    geom_smooth(aes(group = Tier_Factor, color = Tier_Factor), method = "loess", se = FALSE, linewidth = 1) +
    scale_fill_manual(name = "Tournament", values = tournament_colors, drop = FALSE) +
    scale_color_manual(name = "Tournament", values = tournament_colors, drop = FALSE) +
    scale_x_date(date_labels = "%b %Y", date_breaks = "1 month") +
    scale_y_continuous(labels = comma_format(accuracy = 1)) +
    labs(
      title = "The Tower: Tournament Time Played Over Time",
      subtitle = sprintf("n = %d tournament plays | Total: %.1f hours", 
                         nrow(tournament_df), sum(tournament_daily_by_tier$total_time, na.rm = TRUE) / 60),
      x = "Date",
      y = "Time (Hours)"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = 16, face = "bold"),
      plot.subtitle = element_text(size = 11),
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = "right",
      legend.title = element_text(face = "bold"),
      panel.grid.minor = element_blank()
    )
  
  ggsave("tournament-time.png", p8, width = 12, height = 6, dpi = 300)
  
  cat("Tournament visualizations generated.\n")
} else {
  cat("No tournament tiers with >= 10 plays found.\n")
}

cat("\nAnalysis complete! Generated visualizations:\n")
  cat("  - minutes-per-billion-by-tier.png: Scatter plot of minutes/billion by tier\n")
  cat("  - minutes-per-billion-by-tier-zoom.png: Zoomed view (since Sep 2025, < 20 min/billion)\n")
  cat("  - billions-per-day.png: Total billions earned per day\n")
  cat("  - hours-per-day.png: Hours played per day\n")
  cat("  - time-to-finish.png: Scatter plot of time to finish levels\n")
  cat("  - percentage-by-tier-boxplot.png: Box plots of percentage by tier (tiers 10+)\n")
if (nrow(tournament_df) > 0) {
  cat("  - tournament-waves.png: Tournament waves achieved over time\n")
  cat("  - tournament-coins.png: Tournament coins earned over time\n")
  cat("  - tournament-time.png: Tournament time played over time\n")
}

cat("\n=== RECENT STATS TABLE ===\n\n")

recent_cutoff <- floor_date(max(df$Date) - months(4), "month")
df_recent <- df %>% filter(Date >= recent_cutoff)

if (nrow(df_recent) == 0) {
  cat("No games found in the last 4 months. Skipping stats table generation.\n")
  quit(save = "no")
}

recent_start_label <- format(recent_cutoff, "%b %Y")
recent_end_label <- format(max(df$Date), "%b %Y")

tier_stats <- df_recent %>%
  group_by(Tier) %>%
  summarise(
    Games = n(),
    `Avg Duration` = mean(`Time (minutes)`, na.rm = TRUE) / 60,
    `Max Duration` = max(`Time (minutes)`, na.rm = TRUE) / 60,
    `Avg Coins (B)` = mean(`Total Coins (B)`, na.rm = TRUE),
    `Max Coins (B)` = max(`Total Coins (B)`, na.rm = TRUE),
    `Avg Min/Billion` = mean(`Minutes/Billion`, na.rm = TRUE),
    `Avg Coins/Hr` = mean(`Total Coins (B)` / (`Time (minutes)` / 60), na.rm = TRUE),
    `Total Coins (B)` = sum(`Total Coins (B)`, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(Tier))

all_stats <- df_recent %>%
  summarise(
    Games = n(),
    `Avg Duration` = mean(`Time (minutes)`, na.rm = TRUE) / 60,
    `Max Duration` = max(`Time (minutes)`, na.rm = TRUE) / 60,
    `Avg Coins (B)` = mean(`Total Coins (B)`, na.rm = TRUE),
    `Max Coins (B)` = max(`Total Coins (B)`, na.rm = TRUE),
    `Avg Min/Billion` = mean(`Minutes/Billion`, na.rm = TRUE),
    # Avg Coins/Hr is mean-of-ratios: each game's rate weighted equally, not total/total
    `Avg Coins/Hr` = mean(`Total Coins (B)` / (`Time (minutes)` / 60), na.rm = TRUE),
    `Total Coins (B)` = sum(`Total Coins (B)`, na.rm = TRUE)
  )

fmt_hrs <- function(x) {
  total_mins <- round(x * 60)
  sprintf("%dh%02dm", total_mins %/% 60, total_mins %% 60)
}

fmt_dec <- function(x, digits = 1) {
  sprintf(paste0("%.", digits, "f"), x)
}

fmt_coins <- function(x) {
  format(round(x, 1), big.mark = ",", nsmall = 1, scientific = FALSE)
}

table_rows <- vapply(seq_len(nrow(tier_stats)), function(i) {
  row <- tier_stats[i, ]
  sprintf(
    "| %d | %d | %s | %s | %s | %s | %s | %s | %s |",
    row$Tier, row$Games,
    fmt_coins(row$`Total Coins (B)`),
    fmt_hrs(row$`Avg Duration`), fmt_hrs(row$`Max Duration`),
    fmt_dec(row$`Avg Coins (B)`), fmt_dec(row$`Max Coins (B)`),
    fmt_dec(row$`Avg Min/Billion`), fmt_dec(row$`Avg Coins/Hr`)
  )
}, character(1))

all_row <- sprintf(
  "| **All** | **%d** | **%s** | **%s** | **%s** | **%s** | **%s** | **%s** | **%s** |",
  all_stats$Games,
  fmt_coins(all_stats$`Total Coins (B)`),
  fmt_hrs(all_stats$`Avg Duration`), fmt_hrs(all_stats$`Max Duration`),
  fmt_dec(all_stats$`Avg Coins (B)`), fmt_dec(all_stats$`Max Coins (B)`),
  fmt_dec(all_stats$`Avg Min/Billion`), fmt_dec(all_stats$`Avg Coins/Hr`)
)

stats_table <- c(
  sprintf("### Recent Statistics (%s \u2013 %s)", recent_start_label, recent_end_label),
  "",
  "| Tier | Games | Total Coins (B) | Avg Duration | Max Duration | Avg Coins (B) | Max Coins (B) | Avg Min/B | Avg Coins/Hr |",
  "| ----- | ------: | --------------: | -----------: | -----------: | --------------: | --------------: | ----------: | -------------: |",
  table_rows,
  all_row,
  ""
)

cat(paste(stats_table, collapse = "\n"), "\n")

readme_path <- "../README.md"
readme_lines <- readLines(readme_path, warn = FALSE)

start_marker <- "<!-- RECENT-STATS-START -->"
end_marker <- "<!-- RECENT-STATS-END -->"

start_idx <- which(readme_lines == start_marker)
end_idx <- which(readme_lines == end_marker)

if (length(start_idx) != 1 || length(end_idx) != 1) {
  stop("Expected exactly one RECENT-STATS-START and one RECENT-STATS-END marker in README.md. Found ", length(start_idx), " start and ", length(end_idx), " end markers.")
}

after_stats_end <- if (end_idx < length(readme_lines)) readme_lines[(end_idx + 1):length(readme_lines)] else character(0)

new_readme <- c(
  readme_lines[1:start_idx],
  "",
  "<!-- Auto-generated by analyze-playlog.R \u2014 do not edit between these markers -->",
  "",
  stats_table,
  end_marker,
  after_stats_end
)

writeLines(new_readme, readme_path)
cat("Updated README.md with recent stats table.\n")

cat("\n=== RECENT TOURNAMENT STATS TABLE ===\n\n")

# Use df_all (includes dissonant runs) for tournament date range so the
# end-label reflects the most recent play of any kind, not just regular tiers.
# 6-month window (vs 4-month for regular stats) because tournaments are less frequent.
tournament_recent_cutoff <- floor_date(max(df_all$Date) - months(6), "month")
df_tournament_recent <- tournament_df_raw %>%
  mutate(Tournament_Tier = abs(Tier)) %>%
  filter(Date >= tournament_recent_cutoff) %>%
  filter(!is.na(`Finish Wave`) & `Finish Wave` > 0)

if (nrow(df_tournament_recent) == 0) {
  cat("No tournament games found in the last 6 months. Skipping tournament stats table generation.\n")
} else {
  tournament_recent_start_label <- format(tournament_recent_cutoff, "%b %Y")
  tournament_recent_end_label <- format(max(df_tournament_recent$Date), "%b %Y")

  tournament_tier_stats <- df_tournament_recent %>%
    group_by(Tournament_Tier) %>%
    summarise(
      Games = n(),
      `Avg Duration` = mean(`Time (minutes)`, na.rm = TRUE) / 60,
      `Max Duration` = max(`Time (minutes)`, na.rm = TRUE) / 60,
      `Avg Coins (B)` = mean(`Total Coins (B)`, na.rm = TRUE),
      `Max Coins (B)` = max(`Total Coins (B)`, na.rm = TRUE),
      `Avg Wave` = mean(`Finish Wave`, na.rm = TRUE),
      `Max Wave` = max(`Finish Wave`, na.rm = TRUE),
      `Total Coins (B)` = sum(`Total Coins (B)`, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(desc(Tournament_Tier))

  tournament_all_stats <- df_tournament_recent %>%
    summarise(
      Games = n(),
      `Avg Duration` = mean(`Time (minutes)`, na.rm = TRUE) / 60,
      `Max Duration` = max(`Time (minutes)`, na.rm = TRUE) / 60,
      `Avg Coins (B)` = mean(`Total Coins (B)`, na.rm = TRUE),
      `Max Coins (B)` = max(`Total Coins (B)`, na.rm = TRUE),
      `Avg Wave` = mean(`Finish Wave`, na.rm = TRUE),
      `Max Wave` = max(`Finish Wave`, na.rm = TRUE),
      `Total Coins (B)` = sum(`Total Coins (B)`, na.rm = TRUE)
    )

  tournament_table_rows <- vapply(seq_len(nrow(tournament_tier_stats)), function(i) {
    row <- tournament_tier_stats[i, ]
    sprintf(
      "| T-%d | %d | %s | %s | %s | %s | %s | %.0f | %.0f |",
      row$Tournament_Tier, row$Games,
      fmt_coins(row$`Total Coins (B)`),
      fmt_hrs(row$`Avg Duration`), fmt_hrs(row$`Max Duration`),
      fmt_dec(row$`Avg Coins (B)`), fmt_dec(row$`Max Coins (B)`),
      row$`Avg Wave`, row$`Max Wave`
    )
  }, character(1))

  tournament_all_row <- sprintf(
    "| **All** | **%d** | **%s** | **%s** | **%s** | **%s** | **%s** | **%.0f** | **%.0f** |",
    tournament_all_stats$Games,
    fmt_coins(tournament_all_stats$`Total Coins (B)`),
    fmt_hrs(tournament_all_stats$`Avg Duration`), fmt_hrs(tournament_all_stats$`Max Duration`),
    fmt_dec(tournament_all_stats$`Avg Coins (B)`), fmt_dec(tournament_all_stats$`Max Coins (B)`),
    tournament_all_stats$`Avg Wave`, tournament_all_stats$`Max Wave`
  )

  tournament_stats_table <- c(
    sprintf("### Recent Tournament Statistics (%s \u2013 %s)", tournament_recent_start_label, tournament_recent_end_label),
    "",
    "| Tier | Games | Total Coins (B) | Avg Duration | Max Duration | Avg Coins (B) | Max Coins (B) | Avg Wave | Max Wave |",
    "| ----- | ------: | --------------: | -----------: | -----------: | --------------: | --------------: | ------: | ------: |",
    tournament_table_rows,
    tournament_all_row,
    ""
  )

  cat(paste(tournament_stats_table, collapse = "\n"), "\n")

  tournament_start_marker <- "<!-- RECENT-TOURNAMENT-STATS-START -->"
  tournament_end_marker <- "<!-- RECENT-TOURNAMENT-STATS-END -->"

  readme_lines <- readLines(readme_path, warn = FALSE)

  t_start_idx <- which(readme_lines == tournament_start_marker)
  t_end_idx <- which(readme_lines == tournament_end_marker)

  if (length(t_start_idx) != 1 || length(t_end_idx) != 1) {
    stop("Expected exactly one RECENT-TOURNAMENT-STATS-START and one RECENT-TOURNAMENT-STATS-END marker in README.md. Found ", length(t_start_idx), " start and ", length(t_end_idx), " end markers.")
  }

  after_end <- if (t_end_idx < length(readme_lines)) readme_lines[(t_end_idx + 1):length(readme_lines)] else character(0)

  new_readme <- c(
    readme_lines[1:t_start_idx],
    "",
    "<!-- Auto-generated by analyze-playlog.R \u2014 do not edit between these markers -->",
    "",
    tournament_stats_table,
    tournament_end_marker,
    after_end
  )

  writeLines(new_readme, readme_path)
  cat("Updated README.md with recent tournament stats table.\n")
}
