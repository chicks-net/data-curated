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

## Development Process

The project uses GitHub for development workflow:

1. Development happens in feature branches
2. Pull requests are created for changes
3. GitHub Actions run automated checks (markdownlint)
4. Changes are merged to `main` branch

Note: The CONTRIBUTING.md references a `justfile` for development commands,
but this file doesn't exist in the repository root. The development process
is primarily git-based.

## Common Commands

### Linting

- `markdownlint` runs automatically via GitHub Actions on all `*.md` files

### Data Viewing

- Use `datasette <database>.db -o` to view SQLite databases
- Example: `datasette us-states/states.db -o`

### Data Conversion

Individual directories may contain conversion scripts:

- `duolingo/build-character.sh` - Converts TOML to markdown character reference
- `us-states/import.sh` - Converts CSV to SQLite database

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
