#!/usr/bin/env bash

# Download Census Bureau data for US cities by state
# Usage: ./download-census-data.sh STATE_CODE
# Example: ./download-census-data.sh 06 (for California)
#          ./download-census-data.sh VA (for Virginia)

set -eo pipefail

# Function to convert state input to FIPS code
get_fips_code() {
    local input=$(echo "$1" | tr '[:lower:]' '[:upper:]')  # Convert to uppercase

    # If input is already a 2-digit number, use it directly
    if [[ "$input" =~ ^[0-9]{2}$ ]]; then
        echo "$input"
        return 0
    fi

    # Convert state abbreviation to FIPS code
    case "$input" in
        AL) echo "01" ;;
        AK) echo "02" ;;
        AZ) echo "04" ;;
        AR) echo "05" ;;
        CA) echo "06" ;;
        CO) echo "08" ;;
        CT) echo "09" ;;
        DE) echo "10" ;;
        DC) echo "11" ;;
        FL) echo "12" ;;
        GA) echo "13" ;;
        HI) echo "15" ;;
        ID) echo "16" ;;
        IL) echo "17" ;;
        IN) echo "18" ;;
        IA) echo "19" ;;
        KS) echo "20" ;;
        KY) echo "21" ;;
        LA) echo "22" ;;
        ME) echo "23" ;;
        MD) echo "24" ;;
        MA) echo "25" ;;
        MI) echo "26" ;;
        MN) echo "27" ;;
        MS) echo "28" ;;
        MO) echo "29" ;;
        MT) echo "30" ;;
        NE) echo "31" ;;
        NV) echo "32" ;;
        NH) echo "33" ;;
        NJ) echo "34" ;;
        NM) echo "35" ;;
        NY) echo "36" ;;
        NC) echo "37" ;;
        ND) echo "38" ;;
        OH) echo "39" ;;
        OK) echo "40" ;;
        OR) echo "41" ;;
        PA) echo "42" ;;
        RI) echo "44" ;;
        SC) echo "45" ;;
        SD) echo "46" ;;
        TN) echo "47" ;;
        TX) echo "48" ;;
        UT) echo "49" ;;
        VT) echo "50" ;;
        VA) echo "51" ;;
        WA) echo "53" ;;
        WV) echo "54" ;;
        WI) echo "55" ;;
        WY) echo "56" ;;
        PR) echo "72" ;;
        *) return 1 ;;
    esac
}

# Function to get state abbreviation from FIPS code
get_state_abbrev() {
    local fips="$1"

    case "$fips" in
        01) echo "AL" ;;
        02) echo "AK" ;;
        04) echo "AZ" ;;
        05) echo "AR" ;;
        06) echo "CA" ;;
        08) echo "CO" ;;
        09) echo "CT" ;;
        10) echo "DE" ;;
        11) echo "DC" ;;
        12) echo "FL" ;;
        13) echo "GA" ;;
        15) echo "HI" ;;
        16) echo "ID" ;;
        17) echo "IL" ;;
        18) echo "IN" ;;
        19) echo "IA" ;;
        20) echo "KS" ;;
        21) echo "KY" ;;
        22) echo "LA" ;;
        23) echo "ME" ;;
        24) echo "MD" ;;
        25) echo "MA" ;;
        26) echo "MI" ;;
        27) echo "MN" ;;
        28) echo "MS" ;;
        29) echo "MO" ;;
        30) echo "MT" ;;
        31) echo "NE" ;;
        32) echo "NV" ;;
        33) echo "NH" ;;
        34) echo "NJ" ;;
        35) echo "NM" ;;
        36) echo "NY" ;;
        37) echo "NC" ;;
        38) echo "ND" ;;
        39) echo "OH" ;;
        40) echo "OK" ;;
        41) echo "OR" ;;
        42) echo "PA" ;;
        44) echo "RI" ;;
        45) echo "SC" ;;
        46) echo "SD" ;;
        47) echo "TN" ;;
        48) echo "TX" ;;
        49) echo "UT" ;;
        50) echo "VT" ;;
        51) echo "VA" ;;
        53) echo "WA" ;;
        54) echo "WV" ;;
        55) echo "WI" ;;
        56) echo "WY" ;;
        72) echo "PR" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# Base URLs
GAZETTEER_BASE="https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2020_Gazetteer"
POPULATION_BASE="https://www2.census.gov/programs-surveys/popest/datasets/2010-2020/cities"

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATA_DIR="${SCRIPT_DIR}/../data"

# Create data directory if it doesn't exist
mkdir -p "$DATA_DIR"

# Check if state code is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 STATE_CODE"
    echo ""
    echo "STATE_CODE can be either:"
    echo "  - 2-digit FIPS code (e.g., 06 for California)"
    echo "  - 2-letter state abbreviation (e.g., CA for California)"
    echo ""
    echo "Examples:"
    echo "  $0 06    # California"
    echo "  $0 CA    # California"
    echo "  $0 51    # Virginia"
    echo "  $0 VA    # Virginia"
    exit 1
fi

STATE_INPUT="$1"
FIPS_CODE=$(get_fips_code "$STATE_INPUT")

if [ -z "$FIPS_CODE" ]; then
    echo "Error: Invalid state code '$STATE_INPUT'"
    exit 1
fi

STATE_ABBREV=$(get_state_abbrev "$FIPS_CODE")

echo "Downloading Census data for $STATE_ABBREV (FIPS: $FIPS_CODE)..."
echo ""

# Download Gazetteer file (places with coordinates)
GAZETTEER_FILE="2020_gaz_place_${FIPS_CODE}.txt"
GAZETTEER_URL="${GAZETTEER_BASE}/${GAZETTEER_FILE}"
GAZETTEER_OUTPUT="${DATA_DIR}/${GAZETTEER_FILE}"

echo "Downloading Gazetteer file (coordinates)..."
echo "  URL: $GAZETTEER_URL"
echo "  Output: $GAZETTEER_OUTPUT"

if wget -q -O "$GAZETTEER_OUTPUT" "$GAZETTEER_URL"; then
    echo "  ✓ Successfully downloaded $(wc -l < "$GAZETTEER_OUTPUT") lines"
else
    echo "  ✗ Failed to download Gazetteer file"
    rm -f "$GAZETTEER_OUTPUT"
    exit 1
fi

echo ""

# Download Population estimates file (2010-2020)
# Note: Population files don't use leading zeros (e.g., SUB-EST2020_6.csv not SUB-EST2020_06.csv)
FIPS_NO_LEADING_ZERO=$(echo "$FIPS_CODE" | sed 's/^0*//')
POPULATION_FILE="SUB-EST2020_${FIPS_NO_LEADING_ZERO}.csv"
POPULATION_URL="${POPULATION_BASE}/${POPULATION_FILE}"
POPULATION_OUTPUT="${DATA_DIR}/SUB-EST2020_${FIPS_CODE}.csv"  # Save with leading zero for consistency

echo "Downloading Population file (2010-2020 estimates)..."
echo "  URL: $POPULATION_URL"
echo "  Output: $POPULATION_OUTPUT"

if wget -q -O "$POPULATION_OUTPUT" "$POPULATION_URL"; then
    echo "  ✓ Successfully downloaded $(wc -l < "$POPULATION_OUTPUT") lines"
else
    echo "  ✗ Failed to download Population file"
    rm -f "$POPULATION_OUTPUT"
    exit 1
fi

echo ""
echo "Download complete!"
echo ""
echo "Files downloaded:"
echo "  - $GAZETTEER_OUTPUT"
echo "  - $POPULATION_OUTPUT"
echo ""
echo "Next step: Run the import script to convert to SQLite"
