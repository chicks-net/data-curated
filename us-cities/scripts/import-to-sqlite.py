#!/usr/bin/env python3

"""
Import Census Bureau city data into SQLite database

This script combines:
1. Gazetteer files (coordinates, geographic info)
2. Population estimate files (2010-2020 population data)

Into a single SQLite database for easy querying and analysis.
"""

import csv
import sqlite3
import sys
from pathlib import Path

def get_fips_code(state_input):
    """Convert state abbreviation to FIPS code"""
    state_map = {
        'AL': '01', 'AK': '02', 'AZ': '04', 'AR': '05', 'CA': '06',
        'CO': '08', 'CT': '09', 'DE': '10', 'DC': '11', 'FL': '12',
        'GA': '13', 'HI': '15', 'ID': '16', 'IL': '17', 'IN': '18',
        'IA': '19', 'KS': '20', 'KY': '21', 'LA': '22', 'ME': '23',
        'MD': '24', 'MA': '25', 'MI': '26', 'MN': '27', 'MS': '28',
        'MO': '29', 'MT': '30', 'NE': '31', 'NV': '32', 'NH': '33',
        'NJ': '34', 'NM': '35', 'NY': '36', 'NC': '37', 'ND': '38',
        'OH': '39', 'OK': '40', 'OR': '41', 'PA': '42', 'RI': '44',
        'SC': '45', 'SD': '46', 'TN': '47', 'TX': '48', 'UT': '49',
        'VT': '50', 'VA': '51', 'WA': '53', 'WV': '54', 'WI': '55',
        'WY': '56', 'PR': '72'
    }

    state_upper = state_input.upper()

    # If already a 2-digit number, return it
    if state_upper.isdigit() and len(state_upper) == 2:
        return state_upper

    return state_map.get(state_upper)

def get_state_abbrev(fips_code):
    """Convert FIPS code to state abbreviation"""
    fips_map = {
        '01': 'AL', '02': 'AK', '04': 'AZ', '05': 'AR', '06': 'CA',
        '08': 'CO', '09': 'CT', '10': 'DE', '11': 'DC', '12': 'FL',
        '13': 'GA', '15': 'HI', '16': 'ID', '17': 'IL', '18': 'IN',
        '19': 'IA', '20': 'KS', '21': 'KY', '22': 'LA', '23': 'ME',
        '24': 'MD', '25': 'MA', '26': 'MI', '27': 'MN', '28': 'MS',
        '29': 'MO', '30': 'MT', '31': 'NE', '32': 'NV', '33': 'NH',
        '34': 'NJ', '35': 'NM', '36': 'NY', '37': 'NC', '38': 'ND',
        '39': 'OH', '40': 'OK', '41': 'OR', '42': 'PA', '44': 'RI',
        '45': 'SC', '46': 'SD', '47': 'TN', '48': 'TX', '49': 'UT',
        '50': 'VT', '51': 'VA', '53': 'WA', '54': 'WV', '55': 'WI',
        '56': 'WY', '72': 'PR'
    }
    return fips_map.get(fips_code, 'UNKNOWN')

def load_gazetteer(filepath):
    """Load gazetteer file (tab-delimited) into a dictionary keyed by GEOID"""
    places = {}

    with open(filepath, 'r', encoding='utf-8') as f:
        # Read as tab-delimited
        reader = csv.DictReader(f, delimiter='\t')

        # Strip whitespace from column names
        reader.fieldnames = [name.strip() for name in reader.fieldnames]

        for row in reader:
            geoid = row['GEOID']
            places[geoid] = {
                'name': row['NAME'],
                'latitude': float(row['INTPTLAT']),
                'longitude': float(row['INTPTLONG']),
                'land_area_sqmi': float(row['ALAND_SQMI']),
                'water_area_sqmi': float(row['AWATER_SQMI']),
                'ansi_code': row['ANSICODE']
            }

    return places

def load_population(filepath, state_abbrev):
    """Load population file (CSV) into a dictionary keyed by PLACE code"""
    places = {}

    # Census files may use latin-1 encoding
    with open(filepath, 'r', encoding='latin-1') as f:
        reader = csv.DictReader(f)

        for row in reader:
            # Skip state-level summaries (SUMLEV 040)
            if row['SUMLEV'] != '162':
                continue

            place_code = row['PLACE']

            # Handle non-numeric population values (use None for missing data)
            try:
                pop_2010 = int(row['CENSUS2010POP'])
            except (ValueError, TypeError):
                pop_2010 = None

            try:
                pop_2020 = int(row['POPESTIMATE2020'])
            except (ValueError, TypeError):
                pop_2020 = None

            places[place_code] = {
                'name': row['NAME'],
                'pop_2010': pop_2010,
                'pop_2020': pop_2020,
                'state_abbrev': state_abbrev
            }

    return places

def create_database(db_path):
    """Create SQLite database with cities table"""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Create cities table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS cities (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            state_abbrev TEXT NOT NULL,
            latitude REAL,
            longitude REAL,
            pop_2010 INTEGER,
            pop_2020 INTEGER,
            land_area_sqmi REAL,
            water_area_sqmi REAL,
            ansi_code TEXT,
            geoid TEXT,
            UNIQUE(name, state_abbrev)
        )
    ''')

    # Create indexes for common queries
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_state ON cities(state_abbrev)')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_pop_2020 ON cities(pop_2020 DESC)')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_name ON cities(name)')

    conn.commit()
    return conn

def import_state_data(conn, state_code, data_dir):
    """Import data for a single state"""
    fips_code = get_fips_code(state_code)
    if not fips_code:
        print(f"Error: Invalid state code '{state_code}'")
        return False

    state_abbrev = get_state_abbrev(fips_code)

    print(f"Importing data for {state_abbrev} (FIPS: {fips_code})...")

    # File paths
    gazetteer_file = data_dir / f"2020_gaz_place_{fips_code}.txt"
    population_file = data_dir / f"SUB-EST2020_{fips_code}.csv"

    # Check files exist
    if not gazetteer_file.exists():
        print(f"  Error: Gazetteer file not found: {gazetteer_file}")
        return False

    if not population_file.exists():
        print(f"  Error: Population file not found: {population_file}")
        return False

    # Load data
    print(f"  Loading gazetteer data...")
    gaz_data = load_gazetteer(gazetteer_file)
    print(f"    Loaded {len(gaz_data)} places from gazetteer")

    print(f"  Loading population data...")
    pop_data = load_population(population_file, state_abbrev)
    print(f"    Loaded {len(pop_data)} places from population file")

    # Merge and insert data
    print(f"  Merging data and inserting into database...")
    cursor = conn.cursor()
    inserted = 0
    skipped = 0

    for geoid, gaz_place in gaz_data.items():
        # Extract place code from GEOID (last 5 digits)
        # GEOID format: SSCCCPPPPP (State, County, Place)
        # We want PPPPP
        place_code = geoid[-5:]

        if place_code in pop_data:
            pop_place = pop_data[place_code]

            try:
                cursor.execute('''
                    INSERT OR REPLACE INTO cities
                    (name, state_abbrev, latitude, longitude, pop_2010, pop_2020,
                     land_area_sqmi, water_area_sqmi, ansi_code, geoid)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''', (
                    gaz_place['name'],
                    state_abbrev,
                    gaz_place['latitude'],
                    gaz_place['longitude'],
                    pop_place['pop_2010'],
                    pop_place['pop_2020'],
                    gaz_place['land_area_sqmi'],
                    gaz_place['water_area_sqmi'],
                    gaz_place['ansi_code'],
                    geoid
                ))
                inserted += 1
            except sqlite3.Error as e:
                print(f"    Error inserting {gaz_place['name']}: {e}")
                skipped += 1
        else:
            # Place in gazetteer but not in population file
            skipped += 1

    conn.commit()
    print(f"  Inserted {inserted} cities, skipped {skipped}")

    return True

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 import-to-sqlite.py STATE_CODE [STATE_CODE ...]")
        print("")
        print("STATE_CODE can be either:")
        print("  - 2-digit FIPS code (e.g., 06 for California)")
        print("  - 2-letter state abbreviation (e.g., CA for California)")
        print("")
        print("Examples:")
        print("  python3 import-to-sqlite.py CA")
        print("  python3 import-to-sqlite.py CA VA")
        print("  python3 import-to-sqlite.py 06 51")
        sys.exit(1)

    # Get script directory
    script_dir = Path(__file__).parent
    data_dir = script_dir.parent / "data"
    db_path = script_dir.parent / "cities.db"

    # Create database
    print(f"Creating/opening database: {db_path}")
    conn = create_database(db_path)

    # Import each state
    success_count = 0
    for state_code in sys.argv[1:]:
        if import_state_data(conn, state_code, data_dir):
            success_count += 1
        print("")

    # Show summary
    cursor = conn.cursor()
    cursor.execute("SELECT COUNT(*) FROM cities")
    total_cities = cursor.fetchone()[0]

    print(f"Import complete!")
    print(f"  States imported: {success_count}/{len(sys.argv) - 1}")
    print(f"  Total cities in database: {total_cities}")
    print(f"  Database: {db_path}")

    conn.close()

if __name__ == '__main__':
    main()
