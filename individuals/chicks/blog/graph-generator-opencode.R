#!/usr/bin/env Rscript

# Blog Post Graph Generator - R version
# Replaces graph-generator.go with R-based visualization
# Usage: Rscript graph-generator.R <csv-file> [months]

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 1) {
  cat("Usage: Rscript graph-generator.R <csv-file> [months]\n")
  quit(status = 1)
}

csv_file <- args[1]

# Parse optional months argument (default to 0 = all months)
last_months <- 0
if (length(args) >= 2) {
  last_months <- as.integer(args[2])
  if (is.na(last_months) || last_months < 0) {
    cat("Error: Months argument must be a positive integer\n")
    quit(status = 1)
  }
}

# Check if file exists
if (!file.exists(csv_file)) {
  cat("Error: File", csv_file, "not found\n")
  quit(status = 1)
}

# Load required libraries
suppressPackageStartupMessages({
  library(ggplot2)
  library(scales)
  library(lubridate)
})

# Read and process CSV data
read_blog_data <- function(filename) {
  data <- read.csv(filename, stringsAsFactors = FALSE)
  
  if (nrow(data) == 0) {
    stop("No data found in CSV")
  }
  
  # Parse dates and ensure proper ordering
  data$Date <- as.Date(paste0(data$Month, "-01"), format = "%Y-%m-%d")
  data <- data[order(data$Date), ]
  
  # Fill in missing months with zero counts
  min_date <- min(data$Date)
  max_date <- max(data$Date)
  
  all_months <- seq(min_date, max_date, by = "month")
  complete_data <- data.frame(
    Month = format(all_months, "%Y-%m"),
    Date = all_months,
    Count = 0
  )
  
  # Merge with actual data
  for (i in 1:nrow(data)) {
    idx <- which(complete_data$Month == data$Month[i])
    if (length(idx) > 0) {
      complete_data$Count[idx] <- data$Count[i]
    }
  }
  
  return(complete_data)
}

# Generate the plot
generate_blog_graph <- function(data, output_file) {
  # Calculate nice y-axis max
  max_count <- max(data$Count)
  y_max <- ceiling(max_count / 5) * 5
  if (y_max == 0) y_max <- 5
  
  # Create smooth spline interpolation that goes through all points
  if (nrow(data) >= 3) {
    # Convert dates to numeric for spline interpolation
    x_numeric <- as.numeric(data$Date)
    # Use natural spline interpolation
    spline_interp <- spline(x = x_numeric, y = data$Count, method = "natural", n = length(x_numeric) * 4)
    # Convert back to dates
    smooth_dates <- as.Date(spline_interp$x, origin = "1970-01-01")
    smooth_data <- data.frame(Date = smooth_dates, Count = spline_interp$y)
  } else {
    smooth_data <- data
  }
  
  # Create the plot
  p <- ggplot(data, aes(x = Date, y = Count)) +
    # Add smooth line using spline interpolation
    geom_line(data = smooth_data, aes(x = Date, y = Count), 
              color = "#26a641", linewidth = 1.2, alpha = 0.8) +
    geom_point(color = "#8b949e", size = 2, alpha = 0.7) +
    scale_x_date(
      date_labels = "%b '%y",
      date_breaks = if (nrow(data) > 60) "12 months" else if (nrow(data) > 36) "4 months" else "3 months",
      expand = expansion(mult = c(0.02, 0.02))
    ) +
    scale_y_continuous(
      limits = c(0, y_max),
      breaks = seq(0, y_max, length.out = 6),
      expand = expansion(mult = c(0, 0.05))
    ) +
    labs(
      title = "Blog Posts Per Month",
      x = "Months",
      y = "Posts"
    ) +
    theme_minimal(base_size = 14) +
    theme(
      plot.title = element_text(
        size = 18,
        face = "bold",
        color = "#8b949e",
        hjust = 0.5,
        margin = margin(b = 20)
      ),
      panel.grid.major = element_line(
        color = "#8b949e",
        linewidth = 0.5
      ),
      panel.grid.minor = element_blank(),
      axis.text = element_text(color = "#8b949e", size = 12),
      axis.title = element_text(color = "#8b949e", size = 14),
      panel.border = element_rect(
        color = "#8b949e",
        linewidth = 1,
        fill = NA
      ),
      legend.position = "none"
    )
  
  # Save the plot
  ggsave(
    output_file,
    plot = p,
    width = 12,
    height = 6,
    dpi = 300,
    bg = "white"
  )
  
  return(output_file)
}

# Main execution
tryCatch({
  data <- read_blog_data(csv_file)
  
  # Limit to last N months if specified
  if (last_months > 0 && last_months < nrow(data)) {
    data <- tail(data, last_months)
  }
  
  # Generate output filename with timestamp to ensure different names
  timestamp <- format(Sys.time(), "%Y%m%d-%H%M%S")
  base_name <- tools::file_path_sans_ext(csv_file)
  
  output_file <- paste0(base_name, "-chart-", timestamp, ".png")
  if (last_months > 0) {
    output_file <- paste0(base_name, "-chart-", last_months, "mo-", timestamp, ".png")
  }
  
  result_file <- generate_blog_graph(data, output_file)
  cat("Graph generated:", result_file, "\n")
  
}, error = function(e) {
  cat("Error:", e$message, "\n")
  quit(status = 1)
})
