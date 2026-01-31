# US Restaurant Data Analysis

Analysis of restaurant establishment counts and density (restaurants per capita)
using US Census Bureau data.

## Overview

This analysis combines two Census Bureau datasets to calculate restaurant
density by county:

1. **County Business Patterns (CBP)** - Annual establishment counts by NAICS code
2. **American Community Survey (ACS)** - Population estimates for per capita calculations

**Background:** This implementation is based on prior research documented in
[`Restaurant_data_sources_by_geographic_area_Claude.pdf`](Restaurant_data_sources_by_geographic_area_Claude.pdf),
which explored various data sources and R packages for accessing US restaurant data at county and city levels.

## Example Output

Running `just analyze-restaurants` produces:

```text
=== Top 20 US Counties by Restaurant Density ===

County                                             State   FIPS  Restaurants   Population  Per 10k
---------------------------------------------------------------------------------------------------------
Williamsburg city, Virginia                           51    830          121       15,299     79.1
Fairfax city, Virginia                                51    600          184       23,980     76.7
Mono County, California                               06    051          100       13,291     75.2
Summit County, Colorado                               08    117          233       31,042     75.1
Pitkin County, Colorado                               08    097          127       17,471     72.7
Falls Church city, Virginia                           51    610          105       14,494     72.4
Dare County, North Carolina                           37    055          260       36,718     70.8
Nantucket County, Massachusetts                       25    019           97       13,795     70.3
Cape May County, New Jersey                           34    009          657       95,488     68.8
Worcester County, Maryland                            24    047          358       52,322     68.4
Grand County, Colorado                                08    049          102       15,629     65.3
Vilas County, Wisconsin                               55    125          143       22,813     62.7
Dukes County, Massachusetts                           25    007          123       20,277     60.7
Fredericksburg city, Virginia                         51    630          169       28,027     60.3
Park County, Montana                                  30    067          101       17,072     59.2
Charlottesville city, Virginia                        51    540          266       46,597     57.1
New York County, New York                             36    061        9,197    1,669,127     55.1
Door County, Wisconsin                                55    029          158       29,713     53.2
Gunnison County, Colorado                             08    051           89       16,851     52.8
Mackinac County, Michigan                             26    097           55       10,814     50.9


=== Top 10 + Specific Counties ===

County                                             State   FIPS  Restaurants   Population  Per 10k
---------------------------------------------------------------------------------------------------------
Williamsburg city, Virginia                           51    830          121       15,299     79.1
Fairfax city, Virginia                                51    600          184       23,980     76.7
Mono County, California                               06    051          100       13,291     75.2
Summit County, Colorado                               08    117          233       31,042     75.1
Pitkin County, Colorado                               08    097          127       17,471     72.7
Falls Church city, Virginia                           51    610          105       14,494     72.4
Dare County, North Carolina                           37    055          260       36,718     70.8
Nantucket County, Massachusetts                       25    019           97       13,795     70.3
Cape May County, New Jersey                           34    009          657       95,488     68.8
Worcester County, Maryland                            24    047          358       52,322     68.4
San Francisco County, California                      06    075        3,867      865,933     44.7
San Luis Obispo County, California                    06    079          793      282,771     28.0
Los Angeles County, California                        06    037       22,401   10,019,635     22.4
Bucks County, Pennsylvania                            42    017        1,371      643,872     21.3
Newport News city, Virginia                           51    700          376      185,069     20.3
Contra Costa County, California                       06    013        2,036    1,161,643     17.5
```

The analysis reveals that tourist destinations and resort communities have the highest
restaurant density - Williamsburg, VA tops the list with 79.1 restaurants per 10,000
residents. The second output shows how specific counties of interest (like San Francisco,
Los Angeles) compare to the top-ranking counties.

## Data Sources

### Census Bureau County Business Patterns (CBP)

The CBP provides annual counts of establishments with paid employees by industry
(NAICS code) for every US county, state, and ZIP code. Data includes:

- Number of establishments
- Total employment
- Annual payroll
- Coverage: Annual data from 1986-2023 (2023 is most recent)

**Download:** <https://www.census.gov/programs-surveys/cbp/data/datasets.html>
**API Docs:** <https://www.census.gov/data/developers/data-sets/cbp-zbp/cbp-api.html>
**Interactive:** <https://data.census.gov> (search "County Business Patterns")

### American Community Survey (ACS)

The ACS provides detailed demographic and economic data, including population
estimates. We use the 5-year estimates which provide the most reliable county-level
population data.

**Download:** <https://www.census.gov/programs-surveys/acs/data.html>
**API Docs:** <https://www.census.gov/data/developers/data-sets/acs-5year.html>

### Alternative Data Sources

**USDA Food Environment Atlas** - Pre-packaged county-level restaurant data with
other food environment indicators. Easier to use but less current than CBP.

- Download: <https://www.ers.usda.gov/data-products/food-environment-atlas/>
- Coverage: 2007, 2009, 2012, 2014 (derived from CBP)

**BLS QCEW Data** - Quarterly Census of Employment and Wages. Includes establishment
counts but focuses more on employment data.

- Download: <https://www.bls.gov/cew/downloadable-data-files.htm>
- Coverage: Quarterly and annual, county and state level

## NAICS Codes for Restaurants

The North American Industry Classification System (NAICS) uses the following codes
for food service establishments:

- **722** - Food Services and Drinking Places (all restaurants)
  - **722511** - Full-Service Restaurants
  - **722513** - Limited-Service Restaurants (fast food, counter service)
  - **7224** - Drinking Places (bars, taverns, nightclubs)

The default analysis uses NAICS 722 to include all restaurant types.

## Requirements

### R Packages

```r
install.packages("censusapi")
install.packages("dplyr")
```

### Census API Key

You need a free Census API key to use this script.

1. Sign up at <https://api.census.gov/data/key_signup.html>
2. Set your key in one of three ways:

#### Option 1: Environment variable for current session

```r
Sys.setenv(CENSUS_KEY = "your_key_here")
```

#### Option 2: Add to ~/.Renviron (persistent)

```bash
echo 'CENSUS_KEY=your_key_here' >> ~/.Renviron
```

Then restart R.

#### Option 3: Pass directly to getCensus() calls

```r
getCensus(..., key = "your_key_here")
```

## Usage

### Quick Start (Recommended)

Use the justfile recipe from the repository root:

```bash
just analyze-restaurants
```

This will display:

1. Top 20 US counties by restaurant density (restaurants per 10,000 residents)
2. Top 10 counties plus specific counties of interest (California, Virginia, Pennsylvania)

### Direct Execution

Run the R script directly to see top 20 counties by restaurant density:

```bash
cd us-restaurants
Rscript analyze-restaurants.R
```

### Use as Library

Source the script in your R session to use the functions:

```r
source("analyze-restaurants.R")

# Get top 20 counties by restaurant density
results <- analyze_restaurants(top_n = 20)
print(results)

# Get top 10 plus specific counties of interest
counties <- c(
  "San Luis Obispo County, California",
  "Los Angeles County, California"
)
results <- analyze_restaurants(top_n = 10, specific_counties = counties)
print(results)
```

### Individual Functions

```r
# Fetch restaurant establishment counts
restaurants <- get_restaurant_data(vintage = 2021, naics = "722")

# Fetch population data
population <- get_population_data(vintage = 2021)

# Calculate per capita metrics (filters counties < 10,000 population)
results <- calculate_per_capita(restaurants, population, min_population = 10000)

# Get top N counties
top_20 <- get_top_counties(results, n = 20)

# Get specific counties by name
specific <- get_specific_counties(results, c(
  "San Francisco County, California",
  "Bucks County, Pennsylvania"
))
```

## Output Format

The analysis returns a data frame with the following columns:

- **Name** - County name with state
- **state** - State FIPS code
- **county** - County FIPS code
- **Restaurants** - Number of restaurant establishments
- **Population** - Total population (formatted with commas)
- **Per_10k** - Restaurants per 10,000 residents (rounded to 1 decimal)

Results are sorted by restaurant density (Per_10k) in descending order.

## Understanding the Results

### Restaurants Per Capita

The metric "restaurants per 10,000 residents" normalizes establishment counts
by population, allowing fair comparison between large and small counties.

- Higher values indicate more restaurants relative to population
- Tourist destinations often rank high (beach towns, resort areas)
- Small counties can skew results (default: minimum 10,000 population)

### County vs City Level Data

This analysis uses **county-level** data because the Census CBP API supports
`county:*` for fetching all counties at once. To analyze **city/place-level**
data, you would need to:

1. Fetch place data by state: `region = "place:*", regionin = "state:06"`
2. Loop through all states
3. Combine results

County-level data provides a good approximation and is much simpler to work with.

## Data Vintage

The script defaults to **2021** data because:

- CBP 2021 is the most recent year with stable, complete data
- ACS 5-year 2021 estimates (2017-2021) align well with CBP 2021
- Population estimates from regular PEP don't support `county:*` API calls

You can change the vintage by modifying the `VINTAGE_YEAR` constant or passing
the `vintage` parameter to functions.

## Limitations

- CBP only includes establishments **with paid employees**
- Very small restaurants and sole proprietors may be excluded
- Data is 2-3 years behind current year
- County-level aggregation obscures city-level variations
- Independent cities (like Newport News, VA) are treated as counties

## Related Data

For more detailed restaurant data, consider:

- **Economic Census** - Every 5 years, most detailed (2012, 2017, 2022)
- **ZIP Code Business Patterns** - Same as CBP but at ZIP code level
- **State-level business registries** - Current but format varies by state
- **Private data sources** - Yelp, SafeGraph, Foursquare (commercial)

## References

- Census CBP: <https://www.census.gov/programs-surveys/cbp.html>
- Census ACS: <https://www.census.gov/programs-surveys/acs>
- censusapi R package: <https://github.com/hrecht/censusapi>
- NAICS codes: <https://www.census.gov/naics/>

## License

Data from US Census Bureau is public domain. Code in this repository follows
the repository's overall license.
