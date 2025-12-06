# data-curated/lottery

Kudos to the great State of New York for their
[awesome data sources](https://catalog.data.gov/dataset/?tags=winning)
for the winning lottery numbers.

## Quick Start

Using the project's justfile workflow:

```bash
# Check California lottery jackpots (Powerball, Mega Millions)
just check-jackpots

# Download New York lottery winning numbers
just download-lottery-numbers
```

## California Lottery Jackpot Checker

The `jackpot-checker.go` program fetches current Mega Millions and Powerball
jackpot amounts from the California State Lottery API and stores them in a
SQLite database.

See [JACKPOT-README.md](JACKPOT-README.md) for details on usage.

## New York Lottery Data

Download historical winning numbers for Powerball and Mega Millions:

```bash
just download-lottery-numbers
```

This fetches CSV files from New York State's open data portal:

- `Lottery_Powerball_Winning_Numbers__Beginning_2010.csv`
- `Lottery_Mega_Millions_Winning_Numbers__Beginning_2002.csv`
