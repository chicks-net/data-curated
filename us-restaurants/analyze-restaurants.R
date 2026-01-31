#!/usr/bin/env Rscript
#
# Restaurant Data Analysis by County
#
# This script fetches restaurant establishment counts from the Census Bureau's
# County Business Patterns (CBP) data and combines it with population data
# from the American Community Survey (ACS) to calculate restaurants per capita.
#
# Data Sources:
# - Census Bureau County Business Patterns (CBP): Restaurant establishment counts
# - American Community Survey (ACS): Population estimates
#
# NAICS Codes:
# - 722: Food Services and Drinking Places (all restaurants)
# - 722511: Full-Service Restaurants
# - 722513: Limited-Service Restaurants
# - 7224: Drinking Places
#
# Requirements:
# - R packages: censusapi, dplyr
# - Census API key (free): https://api.census.gov/data/key_signup.html
#
# Setup:
# Run once to store your API key:
#   Sys.setenv(CENSUS_KEY = "your_key_here")
# Or add to ~/.Renviron:
#   CENSUS_KEY=your_key_here

library(censusapi)
library(dplyr)

# Configuration
VINTAGE_YEAR <- 2021  # Most recent year with complete data
NAICS_CODE <- "722"   # All Food Services and Drinking Places

#' Get restaurant establishment counts for all US counties
#'
#' @param vintage Year of data (default: 2021)
#' @param naics NAICS code (default: "722" for all restaurants)
#' @return Data frame with county restaurant counts
get_restaurant_data <- function(vintage = VINTAGE_YEAR, naics = NAICS_CODE) {
  message("Fetching restaurant data from Census CBP...")

  restaurants <- getCensus(
    name = "cbp",
    vintage = vintage,
    vars = c("NAME", "ESTAB"),
    region = "county:*",
    NAICS2017 = naics
  )

  message(sprintf("Retrieved data for %d counties", nrow(restaurants)))
  return(restaurants)
}

#' Get population estimates for all US counties
#'
#' @param vintage Year of data (default: 2021)
#' @return Data frame with county population estimates
get_population_data <- function(vintage = VINTAGE_YEAR) {
  message("Fetching population data from ACS...")

  population <- getCensus(
    name = "acs/acs5",
    vintage = vintage,
    vars = c("NAME", "B01003_001E"),  # Total population
    region = "county:*"
  )

  message(sprintf("Retrieved population for %d counties", nrow(population)))
  return(population)
}

#' Calculate restaurants per capita and return ranked results
#'
#' @param restaurants Restaurant data from get_restaurant_data()
#' @param population Population data from get_population_data()
#' @param min_population Minimum population threshold (default: 10000)
#' @return Data frame with per capita calculations, sorted by density
calculate_per_capita <- function(restaurants, population, min_population = 10000) {
  message("Calculating restaurants per capita...")

  results <- restaurants %>%
    left_join(population, by = c("state", "county")) %>%
    mutate(
      ESTAB = as.numeric(ESTAB),
      POP = as.numeric(B01003_001E),
      restaurants_per_10k = (ESTAB / POP) * 10000
    ) %>%
    filter(POP >= min_population) %>%  # Filter small counties
    arrange(desc(restaurants_per_10k)) %>%
    select(NAME.x, state, county, ESTAB, POP, restaurants_per_10k) %>%
    rename(
      Name = NAME.x,
      Restaurants = ESTAB,
      Population = POP,
      Per_10k = restaurants_per_10k
    )

  message(sprintf("Calculated per capita for %d counties (pop >= %d)",
                  nrow(results), min_population))
  return(results)
}

#' Get top N counties by restaurant density
#'
#' @param results Per capita results from calculate_per_capita()
#' @param n Number of top counties to return (default: 20)
#' @return Data frame with top N counties
get_top_counties <- function(results, n = 20) {
  results %>%
    head(n) %>%
    mutate(
      Per_10k = round(Per_10k, 1)
    )
}

#' Get specific counties by name
#'
#' @param results Per capita results from calculate_per_capita()
#' @param county_names Vector of county names to filter
#' @return Data frame with specified counties
get_specific_counties <- function(results, county_names) {
  results %>%
    filter(Name %in% county_names) %>%
    mutate(
      Per_10k = round(Per_10k, 1)
    )
}

#' Main analysis function - combines top counties with specific counties of interest
#'
#' @param top_n Number of top counties to include (default: 10)
#' @param specific_counties Vector of county names to include (optional)
#' @return Data frame with combined results
analyze_restaurants <- function(top_n = 10, specific_counties = NULL) {
  # Check for API key
  if (Sys.getenv("CENSUS_KEY") == "") {
    stop("CENSUS_KEY not set. Get a free key at https://api.census.gov/data/key_signup.html")
  }

  # Fetch data
  restaurants <- get_restaurant_data()
  population <- get_population_data()

  # Calculate per capita
  all_results <- calculate_per_capita(restaurants, population)

  # Get top N
  top_results <- get_top_counties(all_results, n = top_n)

  # Combine with specific counties if provided
  if (!is.null(specific_counties)) {
    specific_results <- get_specific_counties(all_results, specific_counties)

    # Combine and remove duplicates
    combined <- bind_rows(top_results, specific_results) %>%
      distinct(Name, .keep_all = TRUE) %>%
      arrange(desc(Per_10k))

    return(combined)
  }

  return(top_results)
}

#' Format results for display
#'
#' @param results Results from analyze_restaurants() or other functions
#' @return Data frame with formatted columns for pretty printing
format_for_display <- function(results) {
  # Keep numeric, just ensure proper data frame structure
  as.data.frame(results)
}

#' Print results in a nice table format
#'
#' @param results Results from analyze_restaurants() or other functions
#' @param n Number of rows to print (default: all)
print_results <- function(results, n = NULL) {
  df <- format_for_display(results)

  if (is.null(n)) {
    n <- nrow(df)
  }

  # Print header
  cat(sprintf("%-50s %5s %6s %12s %12s %8s\n",
              "County", "State", "FIPS", "Restaurants", "Population", "Per 10k"))
  cat(strrep("-", 105), "\n", sep = "")

  # Print rows
  for (i in 1:min(n, nrow(df))) {
    cat(sprintf("%-50s %5s %6s %12s %12s %8.1f\n",
                substr(df$Name[i], 1, 50),
                df$state[i],
                df$county[i],
                format(df$Restaurants[i], big.mark = ","),
                format(df$Population[i], big.mark = ","),
                df$Per_10k[i]))
  }

  cat("\n")
}

# Example usage (run only if script is executed directly, not sourced)
if (!interactive() && identical(environment(), globalenv())) {
  # Example: Top 20 counties by restaurant density
  message("\n=== Top 20 US Counties by Restaurant Density ===\n")
  results <- analyze_restaurants(top_n = 20)
  print_results(results, n = 20)

  # Example: Top 10 plus specific counties of interest
  message("\n\n=== Top 10 + Specific Counties ===\n")
  counties_of_interest <- c(
    "Bucks County, Pennsylvania",           # Levittown area
    "Newport News city, Virginia",          # Independent city
    "Contra Costa County, California",      # Martinez
    "San Luis Obispo County, California",   # San Luis Obispo, Pismo Beach, Arroyo Grande
    "Los Angeles County, California",       # Los Angeles
    "San Francisco County, California"      # San Francisco
  )

  results_combined <- analyze_restaurants(
    top_n = 10,
    specific_counties = counties_of_interest
  )
  print_results(results_combined)
}
