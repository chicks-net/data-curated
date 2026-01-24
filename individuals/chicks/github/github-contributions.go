package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

const (
	DatabaseFile    = "./contributions.db"
	DateFormatShort = "2006-01-02"
	EnvJSONLogs     = "JSON_LOGS"
	EnvJSONLogsValue = "true"
	AccountCreated  = "2011-10-03" // chicks-net account creation date
)

// GraphQLResponse represents the GitHub GraphQL API response
type GraphQLResponse struct {
	Data struct {
		User struct {
			ContributionsCollection struct {
				ContributionCalendar struct {
					TotalContributions int `json:"totalContributions"`
					Weeks              []struct {
						ContributionDays []struct {
							Date              string `json:"date"`
							ContributionCount int    `json:"contributionCount"`
						} `json:"contributionDays"`
					} `json:"weeks"`
				} `json:"contributionCalendar"`
			} `json:"contributionsCollection"`
		} `json:"user"`
	} `json:"data"`
}

// ContributionRecord represents a record in our database
type ContributionRecord struct {
	Date              string
	ContributionCount int
	FetchedAt         time.Time
}

func main() {
	// Configure logging
	zerolog.TimestampFunc = func() time.Time {
		return time.Now().UTC()
	}

	if os.Getenv(EnvJSONLogs) == EnvJSONLogsValue {
		zerolog.TimeFieldFormat = time.RFC3339
		log.Logger = zerolog.New(os.Stdout).With().Timestamp().Caller().Logger()
	} else {
		output := zerolog.ConsoleWriter{
			Out:        os.Stdout,
			TimeFormat: time.RFC3339,
			FormatTimestamp: func(i interface{}) string {
				if t, ok := i.(string); ok {
					if parsed, err := time.Parse(time.RFC3339, t); err == nil {
						return parsed.UTC().Format(time.RFC3339)
					}
					return t
				}
				return ""
			},
		}
		log.Logger = log.Output(output)
	}

	log.Info().Msg("Starting GitHub contributions fetcher")

	// Initialize database
	db, err := initDatabase()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to initialize database")
	}
	defer db.Close()

	// Get GitHub username
	username, err := getGitHubUsername()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to get GitHub username")
	}
	log.Info().Str("username", username).Msg("Retrieved GitHub username")

	// Determine date range to fetch
	latestDate, err := getLatestDate(db)
	if err != nil {
		log.Error().Err(err).Msg("Failed to get latest date from database")
	}

	var startDate time.Time
	if latestDate.IsZero() {
		// First run - fetch all history
		startDate, _ = time.Parse(DateFormatShort, AccountCreated)
		log.Info().
			Str("start_date", AccountCreated).
			Msg("No existing data - fetching complete history")
	} else {
		// Subsequent run - fetch last year for incremental updates
		startDate = time.Now().UTC().AddDate(-1, 0, 0)
		log.Info().
			Str("latest_date", latestDate.Format(DateFormatShort)).
			Str("start_date", startDate.Format(DateFormatShort)).
			Msg("Found existing data - fetching last year")
	}

	// Fetch contributions year by year
	currentDate := time.Now().UTC()
	totalDays := 0
	totalContributions := 0

	for year := startDate.Year(); year <= currentDate.Year(); year++ {
		// Calculate date range for this year
		yearStart := time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC)
		yearEnd := time.Date(year, 12, 31, 23, 59, 59, 0, time.UTC)

		// Adjust first year to account creation date
		if year == startDate.Year() {
			yearStart = startDate
		}

		// Adjust last year to current date
		if year == currentDate.Year() {
			yearEnd = currentDate
		}

		log.Info().
			Int("year", year).
			Str("from", yearStart.Format(DateFormatShort)).
			Str("to", yearEnd.Format(DateFormatShort)).
			Msg("Fetching contributions for year")

		records, err := fetchContributions(username, yearStart, yearEnd)
		if err != nil {
			log.Error().
				Err(err).
				Int("year", year).
				Msg("Error fetching contributions")
			continue
		}

		// Save contributions
		saved := 0
		for _, record := range records {
			if err := saveContribution(db, &record); err != nil {
				log.Debug().
					Err(err).
					Str("date", record.Date).
					Msg("Error saving contribution (possibly duplicate)")
			} else {
				saved++
				totalContributions += record.ContributionCount
			}
		}

		totalDays += len(records)
		log.Info().
			Int("year", year).
			Int("days", len(records)).
			Int("saved", saved).
			Msg("Year processed")
	}

	log.Info().
		Int("total_days", totalDays).
		Int("total_contributions", totalContributions).
		Str("database", DatabaseFile).
		Msg("GitHub contributions fetch completed successfully")
}

func initDatabase() (*sql.DB, error) {
	db, err := sql.Open("sqlite3", DatabaseFile)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	createTableSQL := `
	CREATE TABLE IF NOT EXISTS contributions (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		date TEXT NOT NULL,
		contribution_count INTEGER NOT NULL,
		fetched_at TEXT NOT NULL,
		UNIQUE(date, fetched_at)
	);

	CREATE INDEX IF NOT EXISTS idx_date ON contributions(date);
	CREATE INDEX IF NOT EXISTS idx_fetched_at ON contributions(fetched_at);
	CREATE INDEX IF NOT EXISTS idx_count ON contributions(contribution_count);
	`

	if _, err := db.Exec(createTableSQL); err != nil {
		return nil, fmt.Errorf("failed to create table: %w", err)
	}

	return db, nil
}

func getGitHubUsername() (string, error) {
	cmd := exec.Command("gh", "api", "user", "--jq", ".login")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("gh api user failed: %w", err)
	}

	username := string(output)
	// Remove trailing newline
	if len(username) > 0 && username[len(username)-1] == '\n' {
		username = username[:len(username)-1]
	}

	return username, nil
}

func fetchContributions(username string, from, to time.Time) ([]ContributionRecord, error) {
	// GraphQL query for contributions
	query := fmt.Sprintf(`
	query {
		user(login: "%s") {
			contributionsCollection(from: "%s", to: "%s") {
				contributionCalendar {
					totalContributions
					weeks {
						contributionDays {
							date
							contributionCount
						}
					}
				}
			}
		}
	}
	`, username, from.Format(time.RFC3339), to.Format(time.RFC3339))

	// Execute GraphQL query via gh CLI
	cmd := exec.Command("gh", "api", "graphql", "-f", fmt.Sprintf("query=%s", query))
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("gh api graphql failed: %w", err)
	}

	// Parse response
	var response GraphQLResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, fmt.Errorf("failed to parse JSON: %w", err)
	}

	// Extract contribution days
	var records []ContributionRecord
	fetchedAt := time.Now().UTC()

	for _, week := range response.Data.User.ContributionsCollection.ContributionCalendar.Weeks {
		for _, day := range week.ContributionDays {
			records = append(records, ContributionRecord{
				Date:              day.Date,
				ContributionCount: day.ContributionCount,
				FetchedAt:         fetchedAt,
			})
		}
	}

	return records, nil
}

func saveContribution(db *sql.DB, record *ContributionRecord) error {
	insertSQL := `
	INSERT INTO contributions (date, contribution_count, fetched_at)
	VALUES (?, ?, ?)
	`

	_, err := db.Exec(
		insertSQL,
		record.Date,
		record.ContributionCount,
		record.FetchedAt.Format(time.RFC3339),
	)

	if err != nil {
		return fmt.Errorf("failed to insert record: %w", err)
	}

	return nil
}

func getLatestDate(db *sql.DB) (time.Time, error) {
	var dateStr string
	err := db.QueryRow(`
		SELECT date
		FROM contributions
		ORDER BY date DESC
		LIMIT 1
	`).Scan(&dateStr)

	if err == sql.ErrNoRows {
		return time.Time{}, nil
	}

	if err != nil {
		return time.Time{}, fmt.Errorf("failed to get latest date: %w", err)
	}

	date, err := time.Parse(DateFormatShort, dateStr)
	if err != nil {
		return time.Time{}, fmt.Errorf("failed to parse date: %w", err)
	}

	return date, nil
}
