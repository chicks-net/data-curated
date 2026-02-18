#!/usr/bin/env Rscript
# GitHub Contributions Analysis
# Analyzes GitHub contribution data from SQLite database
# Shows daily contribution counts with 14/30/90-day running averages

# Load required libraries
library(DBI)
library(RSQLite)
library(ggplot2)
library(dplyr)
library(zoo)
library(lubridate)
library(scales)
library(png)
library(jpeg)
library(grid)

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

# Get the latest database update timestamp
last_updated <- dbGetQuery(con, "SELECT MAX(fetched_at) as last_updated FROM contributions")$last_updated
# Parse ISO 8601 format (e.g., "2026-02-05T14:28:07Z")
last_updated_formatted <- format(as.POSIXct(last_updated, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), "%Y-%m-%d %H:%M:%S %Z", tz = "UTC")

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
    avg_14day = rollmean(contribution_count, k=14, fill=NA, align="right"),
    avg_30day = rollmean(contribution_count, k=30, fill=NA, align="right"),
    avg_90day = rollmean(contribution_count, k=90, fill=NA, align="right")
  )

# Summary Statistics
cat("=== SUMMARY STATISTICS ===\n\n")

cat("Date range:", min(contributions$date), "to", max(contributions$date), "\n")
cat("Total days:", nrow(contributions), "\n")
total_contributions <- sum(contributions$contribution_count)
cat("Total contributions:", total_contributions, "\n")
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
cat("Creating contribution graphs...\n\n")
cat("Note: You may see warnings about 'Removed N rows containing missing values'.\n")
cat("      These are expected - running averages need sufficient data points to calculate.\n\n")

# Determine a reasonable date range for plotting (last 2 years by default)
plot_start <- max(min(contributions$date), Sys.Date() - 730)  # 2 years
plot_data <- contributions %>% filter(date >= plot_start)
plot_total_contributions <- sum(plot_data$contribution_count)

p <- ggplot(plot_data, aes(x = date)) +
  # Daily points - smaller and semi-transparent
  geom_point(aes(y = contribution_count),
             alpha = 0.3,
             size = 1,
             color = "gray50") +
  # Running average lines
  geom_line(aes(y = avg_14day, color = "14-day average"),
            linewidth = 0.5) +
  geom_line(aes(y = avg_30day, color = "30-day average"),
            linewidth = 0.8) +
  geom_line(aes(y = avg_90day, color = "90-day average"),
            linewidth = 0.8) +
  # Color scheme
  scale_color_manual(
    name = "Moving Averages",
    values = c(
      "14-day average" = "#2E86AB",    # Blue
      "30-day average" = "#A23B72",   # Purple
      "90-day average" = "#F18F01"    # Orange
    )
  ) +
  # Labels and theme
  labs(
    title = "GitHub Contributions Over The Last Two Years For 'chicks-net'",
    subtitle = paste("Daily contributions with running averages"),
    x = "Date",
    y = "Contributions per Day",
    caption = paste0("Total contributions (last 2 years): ", format(plot_total_contributions, big.mark = ","), " | Database last updated: ", last_updated_formatted)
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
output_file <- "contributions-last2years.png"
ggsave(output_file, p, width = 12, height = 6, dpi = 300)
cat("Saved:", output_file, "\n")

# Create a second visualization showing weekly totals
cat("\nCreating weekly contribution graph...\n")

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

# Load and process job history
jobs_csv <- "../../jobs/job_history.csv"
jobs <- read.csv(jobs_csv, stringsAsFactors = FALSE)
jobs$start_date <- as.Date(jobs$Start.Date)
jobs$end_date <- ifelse(jobs$End.Date == "",
                        as.character(Sys.Date()),
                        jobs$End.Date)
jobs$end_date <- as.Date(jobs$end_date)

# Merge all roles at the same company (combines consecutive positions)
jobs <- jobs %>%
  group_by(Company) %>%
  summarize(
    start_date = min(start_date),
    end_date = max(end_date),
    .groups = "drop"
  )

# Filter to jobs that overlap with GitHub data
github_start <- min(contributions$date)
jobs_filtered <- jobs %>%
  filter(end_date >= github_start) %>%
  arrange(start_date) %>%
  mutate(
    midpoint = start_date + (end_date - start_date) / 2,
    duration_months = interval(start_date, end_date) / months(1),
    job_index = row_number(),
    fill_color = ifelse(job_index %% 2 == 0, "#7B9FCC", "#C8BFB0")
  )

# Load logo images for companies that have them
logos_dir <- "../../jobs/"
logo_files <- list(
  "OpenX" = file.path(logos_dir, "openx-logo.png"),
  "Telmate" = file.path(logos_dir, "telmate-logo-transparent.png"),
  "Tubi" = file.path(logos_dir, "Tubi_logo_2024_purple.png")
)
logos <- list()
for (company in names(logo_files)) {
  if (file.exists(logo_files[[company]])) {
    ext <- tolower(tools::file_ext(logo_files[[company]]))
    if (ext == "jpg" || ext == "jpeg") {
      logos[[company]] <- readJPEG(logo_files[[company]])
    } else if (ext == "png") {
      logos[[company]] <- readPNG(logo_files[[company]])
    }
  }
}
jobs_filtered$has_logo <- jobs_filtered$Company %in% names(logos)

p2 <- ggplot(weekly_data, aes(x = week)) +
  # Employment periods - drawn first, behind everything else
  geom_rect(data = jobs_filtered,
            aes(xmin = start_date, xmax = end_date,
                ymin = -Inf, ymax = Inf,
                fill = fill_color),
            alpha = 0.20,
            inherit.aes = FALSE) +
  scale_fill_identity() +
  # Company labels (text for companies without logos)
  geom_text(data = subset(jobs_filtered, !has_logo),
            aes(x = midpoint,
                y = max(weekly_data$contributions, na.rm = TRUE) * 0.95,
                label = Company),
            angle = 90,
            vjust = 0.5,
            hjust = 1,
            size = 2.875,
            color = "gray30",
            alpha = 0.6,
            inherit.aes = FALSE)

# Add logos to p2
plot_max_y <- max(weekly_data$contributions, na.rm = TRUE)
for (company in names(logos)) {
  job_row <- jobs_filtered[jobs_filtered$Company == company, ]
  if (nrow(job_row) > 0) {
    img <- logos[[company]]
    img_grob <- rasterGrob(img, interpolate = TRUE)
    x_pos <- job_row$midpoint
    # Telmate logo is smaller and needs label
    if (company == "Telmate") {
      logo_height <- plot_max_y * 0.24
      logo_y <- plot_max_y * 0.92
    } else {
      logo_height <- plot_max_y * 0.60
      logo_y <- plot_max_y * 0.90
    }
    p2 <- p2 + annotation_custom(img_grob,
                                  xmin = x_pos - 120, xmax = x_pos + 120,
                                  ymin = logo_y - logo_height, ymax = logo_y)
  }
}

# Add Telmate text label to p2
telmate_row <- jobs_filtered[jobs_filtered$Company == "Telmate", ]
if (nrow(telmate_row) > 0) {
  p2 <- p2 + annotate("text",
                       x = telmate_row$midpoint,
                       y = plot_max_y * 0.96,
                       label = "Telmate",
                       size = 3,
                       color = "gray30",
                       alpha = 0.7)
}

p2 <- p2 +
  # Weekly bars
  geom_col(aes(y = contributions),
           alpha = 0.3,
           fill = "gray50") +
  # Running average lines (based on daily averages)
  geom_line(aes(y = avg_4week * 7, color = "4-week average"),
            linewidth = 0.3) +
  geom_line(aes(y = avg_13week * 7, color = "13-week average"),
            linewidth = 0.5) +
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
    title = "GitHub Contributions for chicks-net - Weekly Totals",
    subtitle = "Weekly totals with running averages and employment periods (shaded regions)",
    x = "Date",
    y = "Contributions per Week",
    caption = paste0("Total contributions: ", format(total_contributions, big.mark = ","), " | Database last updated: ", last_updated_formatted)
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

# Save the weekly totals plot
output_file2 <- "contributions-weekly.png"
ggsave(output_file2, p2, width = 14, height = 6, dpi = 300)
cat("Saved:", output_file2, "\n\n")

# Create a third visualization showing monthly totals
cat("Creating monthly contributions graph...\n")

# Aggregate by month
monthly_data <- contributions %>%
  mutate(month = floor_date(date, "month")) %>%
  group_by(month) %>%
  summarize(
    contributions = sum(contribution_count),
    avg_per_day = mean(contribution_count),
    active_days = sum(contribution_count > 0),
    .groups = "drop"
  ) %>%
  arrange(month) %>%
  mutate(
    avg_6month = rollmean(contributions, k=6, fill=NA, align="right"),
    avg_12month = rollmean(contributions, k=12, fill=NA, align="right")
  )

# Calculate projection for current (incomplete) month
current_month <- floor_date(Sys.Date(), "month")
if (current_month %in% monthly_data$month) {
  # Get days elapsed in current month
  days_in_current_month <- day(Sys.Date())
  total_days_in_month <- days_in_month(current_month)

  # Get actual contributions so far this month
  actual_contributions <- monthly_data %>%
    filter(month == current_month) %>%
    pull(contributions)

  # Project full month total
  projected_total <- actual_contributions * (total_days_in_month / days_in_current_month)
  projected_additional <- projected_total - actual_contributions

  # Calculate bar width (approximately one month in days)
  bar_width <- 25

  # Create projection data frame for geom_rect
  monthly_projection <- data.frame(
    xmin = current_month - bar_width / 2,
    xmax = current_month + bar_width / 2,
    ymin = actual_contributions,
    ymax = projected_total
  )
} else {
  # No projection needed if current month not in data
  monthly_projection <- data.frame(
    xmin = as.Date(character()),
    xmax = as.Date(character()),
    ymin = numeric(),
    ymax = numeric()
  )
}

p3 <- ggplot(monthly_data, aes(x = month)) +
  # Employment periods - drawn first, behind everything else
  geom_rect(data = jobs_filtered,
            aes(xmin = start_date, xmax = end_date,
                ymin = -Inf, ymax = Inf,
                fill = fill_color),
            alpha = 0.20,
            inherit.aes = FALSE) +
  scale_fill_identity() +
  # Company labels (text for companies without logos)
  geom_text(data = subset(jobs_filtered, !has_logo),
            aes(x = midpoint,
                y = max(monthly_data$contributions, na.rm = TRUE) * 0.95,
                label = Company),
            angle = 90,
            vjust = 0.5,
            hjust = 1,
            size = 2.875,
            color = "gray30",
            alpha = 0.6,
            inherit.aes = FALSE)

# Add logos to p3
plot_max_y <- max(monthly_data$contributions, na.rm = TRUE)
for (company in names(logos)) {
  job_row <- jobs_filtered[jobs_filtered$Company == company, ]
  if (nrow(job_row) > 0) {
    img <- logos[[company]]
    img_grob <- rasterGrob(img, interpolate = TRUE)
    x_pos <- job_row$midpoint
    # Telmate logo is smaller and needs label
    if (company == "Telmate") {
      logo_height <- plot_max_y * 0.24
      logo_y <- plot_max_y * 0.92
    } else {
      logo_height <- plot_max_y * 0.60
      logo_y <- plot_max_y * 0.90
    }
    p3 <- p3 + annotation_custom(img_grob,
                                  xmin = x_pos - 120, xmax = x_pos + 120,
                                  ymin = logo_y - logo_height, ymax = logo_y)
  }
}

# Add Telmate text label to p3
telmate_row <- jobs_filtered[jobs_filtered$Company == "Telmate", ]
if (nrow(telmate_row) > 0) {
  p3 <- p3 + annotate("text",
                       x = telmate_row$midpoint,
                       y = plot_max_y * 0.96,
                       label = "Telmate",
                       size = 3,
                       color = "gray30",
                       alpha = 0.7)
}

p3 <- p3 +
  # Monthly bars
  geom_col(aes(y = contributions),
           alpha = 0.6,
           fill = "steelblue") +
  # Projected portion for current month (greyed out)
  geom_rect(data = monthly_projection,
            aes(xmin = xmin, xmax = xmax,
                ymin = ymin, ymax = ymax),
            alpha = 0.3,
            fill = "gray60",
            inherit.aes = FALSE) +
  # Running average lines
  geom_line(aes(y = avg_6month, color = "6-month average"),
            linewidth = 0.8) +
  geom_line(aes(y = avg_12month, color = "12-month average"),
            linewidth = 1.0) +
  # Color scheme
  scale_color_manual(
    name = "Moving Averages",
    values = c(
      "6-month average" = "#A23B72",    # Purple
      "12-month average" = "#F18F01"    # Orange
    )
  ) +
  # Labels and theme
  labs(
    title = "GitHub Contributions for chicks-net - Monthly Totals",
    subtitle = "Monthly contribution totals with running averages and employment periods (shaded regions)",
    x = "Date",
    y = "Contributions per Month",
    caption = paste0("Total contributions: ", format(total_contributions, big.mark = ","), " | Database last updated: ", last_updated_formatted)
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

# Save the monthly plot
output_file3 <- "contributions-monthly.png"
ggsave(output_file3, p3, width = 14, height = 6, dpi = 300)
cat("Saved:", output_file3, "\n\n")

cat("Analysis complete!\n")
