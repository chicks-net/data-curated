# California Lottery Jackpot Checker

A Go program that fetches current jackpot amounts for Mega Millions and Powerball
from the California State Lottery and stores them in a SQLite database.

## What It Does

The program hits the official California Lottery API endpoints and grabs:

- Current jackpot amounts for both games
- Estimated cash values
- Draw numbers and dates
- Timestamp of when the data was checked

All this gets stored in `jackpots.db` for tracking over time.

## Running It

Make sure you've got Go installed, then:

```bash
cd lottery
go run jackpot-checker.go
```

You'll see output like:

```text
Fetching Powerball jackpot...
✓ Powerball: Draw #1545 on 2025-12-03 - $775 million (Cash: $362.5 million)
Fetching Mega Millions jackpot...
✓ Mega Millions: Draw #2134 on 2025-12-02 - $90 million (Cash: $41.9 million)

Data saved to lottery/jackpots.db
```

## Building a Binary

If you want a standalone executable:

```bash
go build -o jackpot-checker jackpot-checker.go
./jackpot-checker
```

## Viewing the Data

Check out the database with SQLite:

```bash
sqlite3 jackpots.db "SELECT * FROM jackpots;"
```

Or get fancy with formatted output:

```bash
sqlite3 jackpots.db "SELECT game, draw_number, draw_date,
  printf('\$%,d', jackpot) as jackpot,
  printf('\$%,d', estimated_cash) as cash_value,
  checked_at
FROM jackpots
ORDER BY checked_at DESC;"
```

If you've got Datasette installed:

```bash
datasette jackpots.db -o
```

## How It Works

The program uses the California Lottery's official API endpoints:

- **Powerball**: `https://www.calottery.com/api/DrawGameApi/DrawGamePastDrawResults/12/1/1`
- **Mega Millions**: `https://www.calottery.com/api/DrawGameApi/DrawGamePastDrawResults/15/1/1`

These are the same endpoints the official website uses to display jackpot info.

The database schema handles duplicate entries gracefully - if you run it multiple
times for the same draw, it'll update the existing record with the latest check time.

## Database Schema

```sql
CREATE TABLE jackpots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    game TEXT NOT NULL,
    draw_number INTEGER NOT NULL,
    draw_date TEXT NOT NULL,
    jackpot INTEGER NOT NULL,
    estimated_cash INTEGER NOT NULL,
    checked_at TEXT NOT NULL,
    UNIQUE(game, draw_number, draw_date)
);
```

Amounts are stored as integers (actual dollar amounts, not millions).

## Scheduling

Throw it in a cron job to track jackpots over time:

```cron
# Check twice a week (Tuesday and Friday at 8 AM)
0 8 * * 2,5 cd /path/to/lottery && /usr/local/bin/go run jackpot-checker.go
```

Or use it in a systemd timer, GitHub Action, whatever floats your boat.

## Dependencies

- Go 1.16 or later
- `github.com/mattn/go-sqlite3` (SQLite driver)

Install dependencies:

```bash
go get github.com/mattn/go-sqlite3
```

Or let Go handle it automatically when you run the program.

## Credits

API endpoints discovered through examination of the California State Lottery website
and helpful folks who've documented the API structure on GitHub.

## Sources

- [California State Lottery](https://www.calottery.com/)
- [GitHub Gist with API Documentation](https://gist.github.com/bramp/6ae5a9977f805e18cbee0b0b362d9fef)
- [USA Mega (Lottery Results)](https://www.usamega.com/)
