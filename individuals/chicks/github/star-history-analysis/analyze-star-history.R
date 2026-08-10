#!/usr/bin/env Rscript
# GitHub Star History Analysis
# Fetches stargazer timestamps from GitHub GraphQL API and plots cumulative
# star counts over time per repo, replicating star-history.com charts locally.

# Load required libraries
library(ggplot2)
library(dplyr)
library(tidyr)
library(zoo)
library(lubridate)
library(scales)
library(jsonlite)

# Define the two org + repo sets that the brag page displays.
# Use names without hyphens as keys; org name is stored explicitly below.
orgs <- list(
  list(org = "chicks-net",
       repos = c("megamap", "fbdata-forensics", "smokeping-config",
                 "chicks-home", "google-plus-posts-dumper", "data-curated")),
  list(org = "fini-net",
       repos = c("fini-coredns-example", "template-repo",
                 "fini-infra", "gh-observer"))
)

# Fetch stargazers (with starredAt timestamps) for one repo via gh api graphql.
# Returns a data.frame with columns: repo, starredAt (POSIXct), org, repo_name.
fetch_repo_stargazers <- function(org, repo) {
  cat("  Fetching", paste0(org, "/", repo), "...\n")
  query <- sprintf('query($cursor: String) {
  repository(owner: "%s", name: "%s") {
    stargazers(first: 100, after: $cursor, orderBy: {field: STARRED_AT, direction: ASC}) {
      totalCount
      edges { starredAt node { login } }
      pageInfo { endCursor hasNextPage }
    }
  }
}', org, repo)

  stars <- character(0)
  cursor <- NULL
  has_cursor <- FALSE
  total <- NA_integer_
  page <- 0L

  repeat {
    page <- page + 1L
    if (has_cursor) {
      body <- list(query = query, variables = list(cursor = cursor))
    } else {
      body <- list(query = query, variables = list())
    }
    body_json <- jsonlite::toJSON(body, auto_unbox = TRUE)
    args <- c("api", "graphql", "--input", "-")
    json_out <- system2("gh", args, input = body_json,
                        stdout = TRUE, stderr = TRUE)
    if (!is.null(attr(json_out, "status"))) {
      if (attr(json_out, "status") != 0) {
        stop("gh api graphql failed for ", org, "/", repo, ":\n",
             paste(json_out, collapse = "\n"))
      }
    }
    payload <- tryCatch(
      jsonlite::fromJSON(paste(json_out, collapse = "\n")),
      error = function(e) {
        stop("Failed to parse GraphQL JSON for ", org, "/", repo,
             " (stdout/stderr may have interleaved):\n",
             paste(json_out, collapse = "\n"), "\n",
             "Parse error: ", conditionMessage(e))
      }
    )
    sg <- payload$data$repository$stargazers
    if (is.null(sg)) {
      stop("No stargazers returned for ", org, "/", repo,
           " (API error?): ", paste(json_out, collapse = "\n"))
    }
    total <- sg$totalCount
    if (length(sg$edges) > 0) {
      stars <- c(stars, sg$edges$starredAt)
    }
    if (!sg$pageInfo$hasNextPage || length(sg$edges) == 0) break
    cursor <- sg$pageInfo$endCursor
    has_cursor <- TRUE
  }

  if (length(stars) == 0L) {
    cat("    no stars (skipped from chart)\n")
    return(NULL)
  }

  cat("    ", length(stars), "stars across", page, "page(s)\n")
  data.frame(
    org = org,
    repo = repo,
    starred_at = as.POSIXct(stars, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    stringsAsFactors = FALSE
  )
}

# Fetch all repos for one org, returning a combined data.frame.
fetch_org_stargazers <- function(org, repos) {
  cat("Fetching stargazers for", org, ":\n")
  do.call(rbind, lapply(repos, function(r) fetch_repo_stargazers(org, r)))
}

# Build a cumulative-star plot for one org from raw stargazer events.
plot_star_history <- function(events, org, out_file) {
  if (is.null(events) || nrow(events) == 0) {
    cat("No stargazer events for", org, "- skipping", out_file, "\n")
    return(invisible(NULL))
  }

  # One row per star event; cumulative count per repo over time.
  events <- events %>%
    mutate(star_date = as.Date(starred_at)) %>%
    arrange(repo, star_date) %>%
    group_by(repo) %>%
    mutate(cumulative = row_number()) %>%
    ungroup()

  # Plot only the actual star-event points (plus a zero start point per repo
  # and a current-date endpoint so each line extends horizontally to today)
  # and let geom_line connect them with straight diagonal segments. This avoids
  # the daily-grid flat-with-jumps jaggedness while keeping the curve accurate.
  repos_with_stars <- unique(events$repo)
  starts <- data.frame(
    repo = repos_with_stars,
    star_date = min(events$star_date) - 1,
    cumulative = 0L,
    stringsAsFactors = FALSE
  )

  ends <- events %>%
    group_by(repo) %>%
    summarize(star_date = Sys.Date(),
              cumulative = max(cumulative), .groups = "drop")

  plot_data <- bind_rows(
    starts,
    events %>% select(repo, star_date, cumulative),
    ends
  )

  repo_total <- events %>%
    group_by(repo) %>%
    summarize(total = max(cumulative), .groups = "drop") %>%
    arrange(desc(total))
  plot_data$repo <- factor(plot_data$repo, levels = repo_total$repo)

  last_updated <- format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z", tz = "UTC")

  p <- ggplot(plot_data, aes(x = star_date, y = cumulative, color = repo)) +
    geom_line(linewidth = 0.8) +
    scale_y_continuous(breaks = function(lims) {
      span <- diff(range(lims))
      step <- if (span <= 5) 1 else if (span <= 10) 2 else if (span <= 25) 5 else if (span <= 50) 10 else 20
      seq(floor(min(lims) / step) * step, ceiling(max(lims) / step) * step, by = step)
    }, minor_breaks = NULL) +
    scale_color_brewer(palette = "Set2") +
    labs(
      title = paste0("Star History for ", org),
      subtitle = paste0(nrow(repo_total),
                       " repos with stars | Total: ",
                       sum(repo_total$total), " stars"),
      x = "Date",
      y = "Cumulative Stars",
      color = "Repository",
      caption = paste0("Source: GitHub GraphQL stargazers API | Updated: ",
                       last_updated)
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = 20, face = "bold"),
      plot.subtitle = element_text(size = 14, color = "gray40"),
      legend.position = "top",
      legend.title = element_text(size = 13, face = "bold"),
      legend.text = element_text(size = 12),
      axis.text = element_text(size = 12),
      axis.title = element_text(size = 14),
      plot.caption = element_text(size = 10),
      panel.grid.minor = element_blank()
    )

  span_days <- as.numeric(max(events$star_date) - min(events$star_date))
  if (span_days > 730) {
    p <- p + scale_x_date(date_breaks = "1 year", date_labels = "%Y")
  } else {
    p <- p + scale_x_date(date_breaks = "3 months", date_labels = "%b %Y")
  }

  ggsave(out_file, p, width = 12, height = 6, dpi = 300)
  cat("Saved:", out_file, "\n")
  invisible(p)
}

# Run for both orgs.
cat("=== STAR HISTORY ANALYSIS ===\n\n")
for (entry in orgs) {
  org_name <- entry$org
  cat("\n--- ", org_name, " ---\n", sep = "")
  events <- fetch_org_stargazers(org_name, entry$repos)
  out_file <- paste0("star-history-", org_name, ".png")
  plot_star_history(events, org_name, out_file)
}

cat("\nAnalysis complete!\n")
