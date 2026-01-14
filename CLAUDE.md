# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## Repository Overview

This is a data-curated collection repository containing various datasets
organized by topic. The repository is primarily focused on data collection,
curation, and conversion into different formats for analysis tools like
Datasette and SQLite.

## Repository Structure

- `duolingo/` - Spanish learning character data in TOML format with build scripts
- `lottery/` - NY lottery winning numbers (CSV) + CA lottery jackpot tracker (Go/SQLite)
- `us-states/` - US state data with CSV, TSV, and SQLite versions
- `us-cities/` - US city data from Census Bureau (coordinates, population 2010-2020)
- `good-sites/` - Curated list of useful websites
- `individuals/` - Personal data collections and projects
- `us-presidents/` - US president data
- `.just/` - Shared justfile modules for workflow automation (from template-repo)

## Development Workflow

The repository uses `just` for development workflow automation. The justfile
imports modules from `.just/` directory:

- `gh-process.just` - Git/GitHub PR workflow automation
- `compliance.just` - Repository health checks for community standards
- `shellcheck.just` - Bash script linting for just recipes

### Branch workflow

1. `just branch <name>` - Create new branch with timestamp: `$USER/YYYY-MM-DD-name`
2. Make changes and commit
3. `just pr` - Create PR using last commit message as title, watches checks
4. `just merge` - Squash-merge PR, delete branch, return to main with pull
5. `just sync` - Escape from branch back to main without merging

### Lottery commands

- `just install-lottery-deps` - Install prerequisites (Go, wget, sqlite3)
- `just check-jackpots` - Fetch California lottery jackpots, show recent results
- `just jackpot-status` - Show database age and when data was last updated
- `just download-lottery-numbers` - Download NY lottery winning numbers (CSV)
- `just analyze-megamillions` - Analyze Mega Millions number frequency (requires R)
- `just analyze-powerball` - Analyze Powerball number frequency (requires R)
- `just analyze-jackpots` - Analyze California lottery jackpot trends (requires R)

### Blog analysis commands

- `just count-posts` - Count blog posts per month from chicks.net
- `just graph-posts` - Generate graph from blog post CSV data (all months)
- `just graph-posts-36` - Generate graph for the last 36 months of blog posts

### US cities commands

- `just setup-state <STATE> [STATE...]` - Download and import Census data for state(s)
- `just download-census-data <STATE>` - Download Census data for a single state
- `just import-census-data <STATE> [STATE...]` - Import downloaded Census data to SQLite
- `just cities-db` - Open cities.db in Datasette browser

### Other commands

- `just datasette <DB>` - Open any SQLite database in Datasette browser
- `just prweb` - Open current branch's PR in browser
- `just release <version>` - Create GitHub release with generated notes
- `just` or `just list` - Show all available commands

## Linting and CI/CD

Markdown linting runs automatically via GitHub Actions on pushes/PRs:

- Uses `markdownlint-cli2-action` on all `*.md` files
- Excludes: `.github/pull_request_template.md`, `duolingo/character_reference.md`
- Local check: `npx markdownlint-cli2 "**/*.md"`

Other automated workflows:

- `claude.yml` - Claude Code responds to @claude mentions in issues/PRs/comments
- `claude-code-review.yml` - Automated code reviews via Claude
- `actionlint.yml` - Lints GitHub Actions workflow files
- `checkov.yml` - Security and compliance scanning

## Data Operations

### Viewing data

- `datasette <database>.db -o` - Open SQLite database in browser
- Example: `datasette us-states/states.db -o`

### Conversion and build scripts

Individual directories contain build/import scripts:

- `duolingo/build-character.sh` - TOML → markdown character reference
- `us-states/import.sh` - CSV → SQLite database
- `us-cities/scripts/download-census-data.sh` - Download Census Bureau data for states
- `us-cities/scripts/import-to-sqlite.py` - Import Census data into SQLite
- `individuals/chicks/google-maps/process-reviews.sh` - Process Google Maps review data

Most data operations are now integrated into the justfile (see commands above).

### Go programs

The repository contains several Go programs:

- `lottery/jackpot-checker.go` - Fetches Mega Millions and Powerball jackpots from California Lottery API
  - Run with: `just check-jackpots` (preferred) or `cd lottery && go run jackpot-checker.go`
  - Stores data in `lottery/jackpots.db` SQLite database
  - See lottery/JACKPOT-README.md for full documentation
- `individuals/chicks/blog/post-counter.go` - Counts blog posts per month from chicks.net
  - Run with: `just count-posts`
  - Generates timestamped CSV files with monthly post counts
- `individuals/chicks/blog/graph-generator.go` - Generates PNG graphs from blog post CSV data
  - Run with: `just graph-posts` or `just graph-posts-36`
  - Creates timestamped PNG files visualizing post frequency over time

### R analysis scripts

The repository contains R scripts for statistical analysis and visualization:

- `lottery/megamillions-analysis/analyze-megamillions.R` - Analyzes Mega Millions number frequency
  - Run with: `just analyze-megamillions`
  - Requires NY lottery CSV data (download with `just download-lottery-numbers`)
  - Generates frequency tables and visualizations
- `lottery/powerball-analysis/analyze-powerball.R` - Analyzes Powerball number frequency
  - Run with: `just analyze-powerball`
  - Requires NY lottery CSV data (download with `just download-lottery-numbers`)
  - Generates frequency tables and visualizations
- `lottery/jackpots-analysis/analyze-jackpots.R` - Analyzes California lottery jackpot trends
  - Run with: `just analyze-jackpots`
  - Uses `lottery/jackpots.db` (populated by `just check-jackpots`)
  - Generates 4 visualizations: trends, cash percentage, distribution, changes
  - See lottery/jackpots-analysis/README.md for details

## Data Formats

The repository works with multiple data formats:

- **CSV/TSV** - Raw tabular data
- **SQLite** - Converted databases for analysis
- **TOML** - Structured configuration data (Duolingo characters)
- **JSON** - API responses and structured data
- **Markdown** - Documentation and formatted references

## Architecture Notes

This is a data repository rather than a traditional software project.
Each directory represents a distinct dataset or data collection project.
Most datasets follow a pattern of:

1. Raw data in CSV or similar format
2. Conversion scripts to transform data
3. Output in multiple formats (especially SQLite for Datasette)
4. README documentation explaining data sources and usage

Lottery number CSVs may not be in chronological order due to upstream issues that we cannot fix.
