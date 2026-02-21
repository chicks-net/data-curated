#!/usr/bin/env Rscript
#
# Restaurant Density Map by County
#
# Creates a choropleth map of US counties showing restaurant density
# (restaurants per 10,000 residents). Uses Census Bureau CBP and ACS data.
#
# Data Sources:
# - Census Bureau County Business Patterns (CBP): Restaurant establishment counts
# - American Community Survey (ACS): Population estimates
# - maps package: County boundaries (built-in R maps)
#
# Requirements:
# - R packages: censusapi, dplyr, ggplot2, maps, mapproj, viridis
# - Census API key (free): https://api.census.gov/data/key_signup.html

library(censusapi)
library(dplyr)
library(tidyr)
library(stringr)
library(ggplot2)
library(maps)
library(mapproj)
library(viridis)

VINTAGE_YEAR <- 2021
NAICS_CODE <- "722"

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

get_population_data <- function(vintage = VINTAGE_YEAR) {
  message("Fetching population data from ACS...")
  
  population <- getCensus(
    name = "acs/acs5",
    vintage = vintage,
    vars = c("NAME", "B01003_001E"),
    region = "county:*"
  )
  
  message(sprintf("Retrieved population for %d counties", nrow(population)))
  return(population)
}

get_county_map_data <- function() {
  message("Getting county map data...")
  
  county_map <- map_data("county")
  
  message(sprintf("Map data for %d polygons", nrow(county_map)))
  return(county_map)
}

prepare_map_data <- function(restaurants, population, county_map, min_population = 1000) {
  message("Preparing map data...")
  
  data <- restaurants %>%
    left_join(population, by = c("state", "county")) %>%
    mutate(
      ESTAB = as.numeric(ESTAB),
      POP = as.numeric(B01003_001E),
      restaurants_per_10k = (ESTAB / POP) * 10000,
      GEOID = paste0(state, county)
    ) %>%
    filter(POP >= min_population) %>%
    select(NAME.x, state, county, ESTAB, POP, restaurants_per_10k) %>%
    rename(NAME = NAME.x) %>%
    separate(NAME, into = c("county_name", "state_name"), sep = ", ", fill = "right") %>%
    mutate(
      county_name = str_remove(county_name, " County$"),
      county_name = str_remove(county_name, " city$"),
      county_name = str_remove(county_name, " Municipality$"),
      county_name = str_remove(county_name, " Borough$"),
      county_name = str_remove(county_name, " Census Area$"),
      county_name = str_remove(county_name, " Parish$"),
      county_name = tolower(str_trim(county_name)),
      state_name = tolower(str_trim(state_name))
    ) %>%
    rename(region = state_name, subregion = county_name)
  
  map_data <- county_map %>%
    left_join(data, by = c("region", "subregion"), relationship = "many-to-many")
  
  message(sprintf("Matched %.0f of %.0f map polygons with data", 
                  sum(!is.na(map_data$restaurants_per_10k)) / 10,
                  nrow(county_map) / 10))
  return(map_data)
}

create_map <- function(map_data, output_file = NULL, width = 16, height = 10) {
  message("Creating map visualization...")
  
  map_data_filtered <- map_data %>%
    filter(!is.na(restaurants_per_10k))
  
  max_density <- quantile(map_data_filtered$restaurants_per_10k, 0.98, na.rm = TRUE)
  
  state_borders <- map_data("state")
  
  p <- ggplot() +
    geom_polygon(
      data = map_data,
      aes(x = long, y = lat, group = group, fill = pmin(restaurants_per_10k, max_density)),
      color = NA
    ) +
    geom_polygon(
      data = state_borders,
      aes(x = long, y = lat, group = group),
      fill = NA,
      color = "white",
      linewidth = 0.2
    ) +
    scale_fill_viridis(
      option = "plasma",
      direction = 1,
      name = "Restaurants\nper 10k",
      limits = c(0, max_density),
      breaks = c(0, 10, 20, 30, 40, 50, round(max_density)),
      labels = c("0", "10", "20", "30", "40", "50", paste0("\u2265", round(max_density))),
      na.value = "grey90"
    ) +
    coord_map("albers", lat0 = 30, lat1 = 40) +
    theme_void() +
    theme(
      plot.title = element_text(size = 18, face = "bold", hjust = 0.5),
      plot.subtitle = element_text(size = 12, hjust = 0.5, color = "gray40"),
      legend.position = "right",
      legend.title = element_text(size = 10, face = "bold"),
      legend.text = element_text(size = 9),
      plot.caption = element_text(size = 9, hjust = 0, color = "gray50")
    ) +
    labs(
      title = "Restaurant Density by County",
      subtitle = sprintf("%d — Restaurants per 10,000 residents (NAICS %s)", VINTAGE_YEAR, NAICS_CODE),
      caption = "Data: US Census Bureau (CBP, ACS 5-year estimates)\nCounties with population < 1,000 shown in grey"
    )
  
  if (!is.null(output_file)) {
    message(sprintf("Saving map to %s...", output_file))
    ggsave(
      filename = output_file,
      plot = p,
      width = width,
      height = height,
      dpi = 300,
      bg = "white"
    )
    message("Map saved successfully!")
  }
  
  return(p)
}

generate_map <- function(output_file = "restaurant-density-map.png") {
  if (Sys.getenv("CENSUS_KEY") == "") {
    stop("CENSUS_KEY not set. Get a free key at https://api.census.gov/data/key_signup.html")
  }
  
  restaurants <- get_restaurant_data()
  population <- get_population_data()
  county_map <- get_county_map_data()
  
  map_data <- prepare_map_data(restaurants, population, county_map)
  
  map_plot <- create_map(map_data, output_file)
  
  stats <- summary(map_data$restaurants_per_10k, na.rm = TRUE)
  message("\nRestaurant density statistics (per 10k residents):")
  message(sprintf("  Min: %.1f", stats["Min."]))
  message(sprintf("  1st Qu: %.1f", stats["1st Qu."]))
  message(sprintf("  Median: %.1f", stats["Median"]))
  message(sprintf("  Mean: %.1f", stats["Mean"]))
  message(sprintf("  3rd Qu: %.1f", stats["3rd Qu."]))
  message(sprintf("  Max: %.1f", stats["Max."]))
  
  top_counties <- map_data %>%
    filter(!is.na(restaurants_per_10k)) %>%
    arrange(desc(restaurants_per_10k)) %>%
    distinct(region, subregion, .keep_all = TRUE) %>%
    head(5)
  
  message("\nTop 5 counties by restaurant density:")
  for (i in 1:min(5, nrow(top_counties))) {
    county_label <- paste0(tools::toTitleCase(top_counties$subregion[i]), ", ", 
                           tools::toTitleCase(top_counties$region[i]))
    message(sprintf("  %d. %s (%.1f per 10k)", i, county_label, top_counties$restaurants_per_10k[i]))
  }
  
  return(map_plot)
}

if (!interactive() && identical(environment(), globalenv())) {
  args <- commandArgs(trailingOnly = TRUE)
  output_file <- if (length(args) > 0) args[1] else "restaurant-density-map.png"
  
  message(sprintf("Generating restaurant density map to: %s\n", output_file))
  generate_map(output_file)
}