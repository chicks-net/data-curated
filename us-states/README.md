# US States

- Data sourced from [HTML table on USPS site](https://pe.usps.com/text/pub28/28apb.htm).
- Raw data in [CSV](states.csv) and [TSV](states.tsv)
- Converted with [bash script](import.sh) into [SQLite database](states.db)

The `states` table is a SQLite `STRICT` table, so column types are enforced
at insert time. This requires SQLite >= 3.37 (2021-11) or newer, both for
the `sqlite3` CLI and any tool opening the database.

View with `datasette states.db -o`
