# Mega Millions Number Frequency Analysis

Ever wondered if some lottery numbers really do come up more often than
others? Well, now you can find out with cold, hard data.

This directory contains tools to analyze the complete history of Mega Millions
winning numbers from the NY Lottery dataset (starting in 2002) to show you
which numbers have been drawn most frequently. Pick your poison: R for pretty
visualizations, or Perl if you just want the numbers.

## Quick Start

### R Version (with visualizations)

Make sure you've got R and tidyverse installed, then run:

```bash
cd lottery/megamillions-analysis
Rscript analyze-megamillions.R
```

If you don't have tidyverse installed, run this in R first:

```r
install.packages("tidyverse")
```

The R script will crunch through all the historical drawings and generate:

- Frequency tables (CSV files)
- Bar chart visualizations (PNG files)
- Console output with top/bottom performers

### Perl Version (analysis only)

If you prefer Perl or don't want to mess with R, there's also a Perl version
that does the same frequency analysis (but without the fancy charts):

```bash
cd lottery/megamillions-analysis
./analyze-megamillions.pl
```

First-time setup requires installing a couple CPAN modules:

```bash
cpanm Text::CSV_XS Statistics::Descriptive
```

The Perl script generates:

- Frequency tables (CSV files with `-perl` suffix)
- Console output with top/bottom performers
- Same statistical analysis (mean, median, standard deviation)

## Analysis Results

Based on **2,466 drawings** from May 17, 2002 to January 9, 2026:

### Main Numbers (1-75)

**Most frequently drawn:**

- 31 (238 times)
- 10 (235 times)
- 17 (227 times)
- 14 (226 times)
- 20 (225 times)

**Least frequently drawn:**

- 72 (20 times)
- 71 (22 times)
- 75 (25 times)
- 74 (30 times)
- 73 (31 times)

![Mega Millions Main Numbers Frequency](megamillions-main-numbers-chart.png)

### Mega Ball (1-25)

**Most frequently drawn:**

- 7 and 9 (97 times each)
- 3 and 10 (93 times each)
- 1, 4, and 13 (91 times each)

![Mega Millions Mega Ball Frequency](megamillions-mega-ball-chart.png)

## Output Files

The R script generates these files:

- `megamillions-main-numbers-frequency.csv` - Complete frequency table for
  all 75 main numbers
- `megamillions-mega-ball-frequency.csv` - Complete frequency table for all
  Mega Balls
- `megamillions-main-numbers-chart.png` - Bar chart visualization of main
  number frequencies
- `megamillions-mega-ball-chart.png` - Bar chart visualization of Mega Ball
  frequencies

The Perl script generates these files (with `-perl` suffix to avoid conflicts):

- `megamillions-main-numbers-frequency-perl.csv` - Same frequency data as
  the R version
- `megamillions-mega-ball-frequency-perl.csv` - Same Mega Ball frequency
  data as the R version

## About the Data

The source data comes from the NY Lottery's official Mega Millions winning
numbers dataset, which goes back to the game's inception in 2002. The CSV file
lives in the parent `lottery/` directory.

Note that numbers 71-75 appear less frequently because they were only added to
the pool more recently when Mega Millions expanded the number range in October
2017. Before that expansion, the main numbers only went up to 70, and before
previous changes it was even smaller. So don't go thinking those high numbers
are "due" - they just haven't been in the game as long.

## Technical Details

### R Implementation

The R script uses tidyverse for data wrangling and ggplot2 for visualizations. It:

1. Reads the CSV file from the parent directory
2. Parses the space-separated winning numbers
3. Counts frequency for each number and Mega Ball
4. Generates summary statistics (mean, median, standard deviation)
5. Creates bar charts sorted by frequency
6. Exports everything to CSV and PNG files

The whole thing runs in a few seconds, even with decades of lottery data.

### Perl Implementation

The Perl version (`analyze-megamillions.pl`) replicates the core analysis
functionality using standard CPAN modules:

- **Text::CSV_XS** - Fast CSV parsing (way faster than the pure-Perl version)
- **Statistics::Descriptive** - Statistical calculations (mean, median, std dev)

The Perl script does everything the R script does except for generating
visualizations. If you want charts, use the R version. If you just want the
frequency data and don't want to install R, the Perl version works great.

Both scripts analyze the exact same data and produce identical frequency
counts, so pick whichever one fits your workflow better.
