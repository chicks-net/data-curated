# US Cities Database

A collection of US city data from the Census Bureau, combining geographic coordinates with population statistics from 2010 and 2020. The data is converted from Census Bureau text and CSV files into a SQLite database for easy querying and analysis.

## Data Sources

This project pulls data from two Census Bureau sources:

1. **2020 Census Gazetteer Files** - Geographic reference data including:
   - City names and locations
   - Latitude and longitude coordinates
   - Land and water area measurements
   - [Census Gazetteer Files](https://www.census.gov/geographies/reference-files/time-series/geo/gazetteer-files.html)

2. **2010-2020 Population Estimates** - Decennial census and annual estimates:
   - 2010 Census population counts
   - 2020 Census population counts
   - [City and Town Population Totals: 2010-2020](https://www.census.gov/programs-surveys/popest/technical-documentation/research/evaluation-estimates/2020-evaluation-estimates/2010s-cities-and-towns-total.html)

## Database Schema

The SQLite database contains a single `cities` table with the following fields:

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| name | TEXT | City name (e.g., "Los Angeles city") |
| state_abbrev | TEXT | Two-letter state code (e.g., "CA") |
| latitude | REAL | Latitude coordinate |
| longitude | REAL | Longitude coordinate |
| pop_2010 | INTEGER | 2010 Census population |
| pop_2020 | INTEGER | 2020 Census population |
| land_area_sqmi | REAL | Land area in square miles |
| water_area_sqmi | REAL | Water area in square miles |
| ansi_code | TEXT | ANSI feature code |
| geoid | TEXT | Census GEOID |

## Quick Start

The easiest way to work with US cities data is using the `just` commands:

### Download and import a single state

```bash
just setup-state CA
```

### Download and import multiple states

```bash
just setup-state CA VA NY TX
```

### View the database in your browser

```bash
just cities-db
```

This opens the SQLite database in [Datasette](https://datasette.io/), giving you a web interface to explore the data.

## Manual Usage

If you prefer to run the scripts directly:

### Step 1: Download Census data

```bash
./us-cities/scripts/download-census-data.sh CA
./us-cities/scripts/download-census-data.sh VA
```

The script accepts either:
- 2-digit FIPS codes (e.g., `06` for California)
- 2-letter state abbreviations (e.g., `CA` for California)

Downloaded files are saved to `us-cities/data/`:
- `2020_gaz_place_XX.txt` - Gazetteer file with coordinates
- `SUB-EST2020_XX.csv` - Population estimates file

### Step 2: Import into SQLite

```bash
python3 us-cities/scripts/import-to-sqlite.py CA VA
```

This creates or updates `us-cities/cities.db` with data from the specified states.

## Example Queries

### Top 10 cities by 2020 population

```sql
SELECT name, state_abbrev, pop_2020, latitude, longitude
FROM cities
ORDER BY pop_2020 DESC
LIMIT 10;
```

### Cities in California with population over 100,000

```sql
SELECT name, pop_2020, latitude, longitude
FROM cities
WHERE state_abbrev = 'CA' AND pop_2020 > 100000
ORDER BY pop_2020 DESC;
```

### Population growth from 2010 to 2020

```sql
SELECT
    name,
    state_abbrev,
    pop_2010,
    pop_2020,
    pop_2020 - pop_2010 AS growth,
    ROUND(100.0 * (pop_2020 - pop_2010) / pop_2010, 1) AS growth_pct
FROM cities
WHERE pop_2010 IS NOT NULL AND pop_2020 IS NOT NULL
ORDER BY growth DESC
LIMIT 20;
```

## State FIPS Codes

Common state FIPS codes for reference:

| State | FIPS | State | FIPS | State | FIPS |
|-------|------|-------|------|-------|------|
| AL | 01 | AK | 02 | AZ | 04 |
| AR | 05 | CA | 06 | CO | 08 |
| CT | 09 | DE | 10 | DC | 11 |
| FL | 12 | GA | 13 | HI | 15 |
| ID | 16 | IL | 17 | IN | 18 |
| IA | 19 | KS | 20 | KY | 21 |
| LA | 22 | ME | 23 | MD | 24 |
| MA | 25 | MI | 26 | MN | 27 |
| MS | 28 | MO | 29 | MT | 30 |
| NE | 31 | NV | 32 | NH | 33 |
| NJ | 34 | NM | 35 | NY | 36 |
| NC | 37 | ND | 38 | OH | 39 |
| OK | 40 | OR | 41 | PA | 42 |
| RI | 44 | SC | 45 | SD | 46 |
| TN | 47 | TX | 48 | UT | 49 |
| VT | 50 | VA | 51 | WA | 53 |
| WV | 54 | WI | 55 | WY | 56 |
| PR | 72 |

## Limitations

- Income data is not yet included (requires American Community Survey data)
- Some cities may have missing population data (marked as NULL in database)
- The gazetteer and population files sometimes have mismatches, resulting in some cities being skipped during import
- Data is limited to incorporated places and Census Designated Places (CDPs)

## Future Enhancements

Planned additions based on the [GitHub issue](https://github.com/fini-net/fini-projects/issues/1):

- [ ] Add median household income from American Community Survey 5-year estimates
- [ ] Add latest population projections
- [ ] Expand to all 50 states + DC + territories
- [ ] Add city-level demographic data

## License

The data comes from the US Census Bureau and is in the public domain. The scripts in this repository are available under the same license as the parent repository.

## Data Updates

Census Bureau data sources:
- Gazetteer files are updated periodically with new Census data
- Population estimates are released annually in May/June
- To get the latest data, re-run the download and import scripts

## References

- [US Census Bureau](https://www.census.gov/)
- [Census Gazetteer Files](https://www.census.gov/geographies/reference-files/time-series/geo/gazetteer-files.html)
- [City and Town Population Estimates](https://www.census.gov/programs-surveys/popest/technical-documentation/research/evaluation-estimates/2020-evaluation-estimates/2010s-cities-and-towns-total.html)
- [Datasette](https://datasette.io/) - Tool for exploring SQLite databases
