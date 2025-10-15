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
- `lottery/` - New York state lottery winning numbers (CSV format)
- `us-states/` - US state data with CSV, TSV, and SQLite versions
- `good-sites/` - Curated list of useful websites
- `individuals/` - Personal data collections and projects
- `us-presidents/` - US president data (appears to be recent addition)

## Development Workflow

The repository uses `just` for development workflow automation. The justfile
imports two modules from `.just/gh-process.just` for git/GitHub operations.

### Branch workflow

1. `just branch <name>` - Create new branch with timestamp: `$USER/YYYY-MM-DD-name`
2. Make changes and commit
3. `just pr` - Create PR using last commit message as title, watches checks
4. `just merge` - Squash-merge PR, delete branch, return to main with pull
5. `just sync` - Escape from branch back to main without merging

### Other commands

- `just prweb` - Open current branch's PR in browser
- `just release <version>` - Create GitHub release with generated notes
- `just` or `just list` - Show all available commands

## Linting

Markdown linting runs automatically via GitHub Actions on pushes/PRs:

- Uses `markdownlint-cli2-action` on all `*.md` files
- Excludes: `.github/pull_request_template.md`, `duolingo/character_reference.md`
- Local check: `npx markdownlint-cli2 "**/*.md"`

## Data Operations

### Viewing data

- `datasette <database>.db -o` - Open SQLite database in browser
- Example: `datasette us-states/states.db -o`

### Conversion scripts

Individual directories contain build/import scripts:

- `duolingo/build-character.sh` - TOML → markdown character reference
- `us-states/import.sh` - CSV → SQLite database

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
