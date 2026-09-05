package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

const (
	// GitHub API configuration
	CommitsPerPage     = 100  // Number of commits to fetch per API request
	GitHubAPILimit     = 1000 // Maximum results returned by GitHub Search API
	SHALogLength       = 7    // Number of SHA characters to display in logs
	DatabaseFile       = "./commits.db"
	InitialPage        = 1 // Starting page number for pagination
	DateFormatShort    = "2006-01-02"
	EnvJSONLogs        = "JSON_LOGS"
	EnvJSONLogsValue   = "true"
	SearchAPIStartYear = 2020 // GitHub Search API only indexes commits reliably from ~2017, use historical-commits.go for pre-2020

	// Retry configuration for transient Search API failures (rate limits, index lag)
	MaxAPIRetries   = 3                   // Retry attempts after the initial request
	RetryBaseDelay  = 15 * time.Second    // Base delay doubles each retry: 15s, 30s, 60s
	RecentPeriodAge = 30 * 24 * time.Hour // Periods ending within this window are expected to have commits for an active author
)

// TimePeriod represents a time range for fetching commits
type TimePeriod struct {
	Start time.Time
	End   time.Time
	Label string
}

// PeriodResult reports the outcome of fetching one time period
type PeriodResult struct {
	Fetched         int
	New             int
	Err             error
	SuspiciousEmpty bool // Period returned zero commits despite evidence they should exist
}

// IsCurrentYear reports whether the period falls in the current calendar year
func (p TimePeriod) IsCurrentYear() bool {
	return p.End.Year() == time.Now().UTC().Year()
}

// CommitSearchResponse represents the GitHub API response for commit search
type CommitSearchResponse struct {
	TotalCount        int            `json:"total_count"`
	IncompleteResults bool           `json:"incomplete_results"`
	Items             []CommitResult `json:"items"`
}

// CommitResult represents a single commit from the search results
type CommitResult struct {
	SHA     string `json:"sha"`
	HTMLURL string `json:"html_url"`
	Commit  struct {
		Author struct {
			Name  string    `json:"name"`
			Email string    `json:"email"`
			Date  time.Time `json:"date"`
		} `json:"author"`
		Committer struct {
			Name  string    `json:"name"`
			Email string    `json:"email"`
			Date  time.Time `json:"date"`
		} `json:"committer"`
		Message string `json:"message"`
	} `json:"commit"`
	Repository struct {
		Name     string `json:"name"`
		FullName string `json:"full_name"`
	} `json:"repository"`
}

// CommitRecord represents a record in our database
type CommitRecord struct {
	SHA            string
	AuthorName     string
	AuthorEmail    string
	AuthorDate     time.Time
	CommitterName  string
	CommitterEmail string
	CommitterDate  time.Time
	Message        string
	Emoji          string
	RepoName       string
	RepoFullName   string
	HTMLURL        string
	FetchedAt      time.Time
}

// generateYearlyPeriods creates time periods for each year from start to end
func generateYearlyPeriods(startYear, endYear int) []TimePeriod {
	var periods []TimePeriod
	for year := endYear; year >= startYear; year-- {
		start := time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC)
		end := time.Date(year, 12, 31, 23, 59, 59, 0, time.UTC)
		periods = append(periods, TimePeriod{
			Start: start,
			End:   end,
			Label: fmt.Sprintf("%d", year),
		})
	}
	return periods
}

// subdivideYearIntoQuarters splits a year into 4 quarterly periods
func subdivideYearIntoQuarters(year int) []TimePeriod {
	quarters := []TimePeriod{
		{
			Start: time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC),
			End:   time.Date(year, 3, 31, 23, 59, 59, 0, time.UTC),
			Label: fmt.Sprintf("%d-Q1", year),
		},
		{
			Start: time.Date(year, 4, 1, 0, 0, 0, 0, time.UTC),
			End:   time.Date(year, 6, 30, 23, 59, 59, 0, time.UTC),
			Label: fmt.Sprintf("%d-Q2", year),
		},
		{
			Start: time.Date(year, 7, 1, 0, 0, 0, 0, time.UTC),
			End:   time.Date(year, 9, 30, 23, 59, 59, 0, time.UTC),
			Label: fmt.Sprintf("%d-Q3", year),
		},
		{
			Start: time.Date(year, 10, 1, 0, 0, 0, 0, time.UTC),
			End:   time.Date(year, 12, 31, 23, 59, 59, 0, time.UTC),
			Label: fmt.Sprintf("%d-Q4", year),
		},
	}
	return quarters
}

// subdivideQuarterIntoMonths splits a quarter into monthly periods
func subdivideQuarterIntoMonths(period TimePeriod) []TimePeriod {
	var months []TimePeriod
	current := period.Start
	for current.Before(period.End) {
		year, month, _ := current.Date()
		start := time.Date(year, month, 1, 0, 0, 0, 0, time.UTC)
		end := start.AddDate(0, 1, 0).Add(-time.Second)
		if end.After(period.End) {
			end = period.End
		}
		months = append(months, TimePeriod{
			Start: start,
			End:   end,
			Label: fmt.Sprintf("%d-%02d", year, month),
		})
		current = start.AddDate(0, 1, 0)
	}
	return months
}

// fetchCommitsForPeriod fetches all commits for a time period, subdividing if necessary
func fetchCommitsForPeriod(db *sql.DB, username string, period TimePeriod, depth int) PeriodResult {
	indent := strings.Repeat("  ", depth)
	log.Info().
		Str("period", period.Label).
		Str("start", period.Start.Format(DateFormatShort)).
		Str("end", period.End.Format(DateFormatShort)).
		Msg(indent + "Fetching commits for period")

	result := PeriodResult{}
	page := InitialPage
	perPage := CommitsPerPage

	for {
		commits, totalCount, err := fetchCommitsWithRetry(username, page, perPage, &period, depth, indent)
		if err != nil {
			log.Error().
				Err(err).
				Str("period", period.Label).
				Int("page", page).
				Msg(indent + "Error fetching commits after retries")
			result.Err = fmt.Errorf("error fetching commits: %w", err)
			return result
		}

		if len(commits) == 0 {
			if page == InitialPage && isSuspiciousEmpty(db, period) {
				log.Warn().
					Str("period", period.Label).
					Msg(indent + "Search API returned zero commits but period should have some - flagging as suspicious")
				result.SuspiciousEmpty = true
			} else {
				log.Debug().Str("period", period.Label).Msg(indent + "No more commits for period")
			}
			break
		}

		// Save commits to database
		for _, commit := range commits {
			exists, err := commitExists(db, commit.SHA)
			if err != nil {
				log.Error().Err(err).Str("sha", commit.SHA).Msg("Error checking if commit exists")
				continue
			}

			if exists {
				log.Debug().Str("sha", commit.SHA[:SHALogLength]).Msg("Commit already exists, skipping")
				continue
			}

			record := &CommitRecord{
				SHA:            commit.SHA,
				AuthorName:     commit.Commit.Author.Name,
				AuthorEmail:    commit.Commit.Author.Email,
				AuthorDate:     commit.Commit.Author.Date,
				CommitterName:  commit.Commit.Committer.Name,
				CommitterEmail: commit.Commit.Committer.Email,
				CommitterDate:  commit.Commit.Committer.Date,
				Message:        commit.Commit.Message,
				Emoji:          extractEmoji(commit.Commit.Message),
				RepoName:       commit.Repository.Name,
				RepoFullName:   commit.Repository.FullName,
				HTMLURL:        commit.HTMLURL,
				FetchedAt:      time.Now().UTC(),
			}

			if err := saveCommit(db, record); err != nil {
				log.Error().Err(err).Str("sha", commit.SHA).Msg("Error saving commit")
			} else {
				result.New++
				log.Debug().
					Str("sha", commit.SHA[:SHALogLength]).
					Str("repo", commit.Repository.FullName).
					Str("date", commit.Commit.Author.Date.Format(DateFormatShort)).
					Msg("Saved commit")
			}
		}

		result.Fetched += len(commits)
		log.Debug().
			Str("period", period.Label).
			Int("page", page).
			Int("fetched", len(commits)).
			Int("total_fetched", result.Fetched).
			Int("new_commits", result.New).
			Int("total_available", totalCount).
			Msg(indent + "Page processed")

		// Check if we've fetched all commits for this period
		if result.Fetched >= totalCount {
			log.Info().
				Str("period", period.Label).
				Int("total_fetched", result.Fetched).
				Int("new_commits", result.New).
				Msg(indent + "All commits fetched for period")
			break
		}

		// Check if we're hitting the GitHub search API limit
		if totalCount >= GitHubAPILimit && result.Fetched >= GitHubAPILimit {
			log.Warn().
				Str("period", period.Label).
				Int("limit", GitHubAPILimit).
				Msg(indent + "Hit GitHub search API limit, need to subdivide")

			// Subdivide based on current period type
			var subPeriods []TimePeriod
			if strings.Contains(period.Label, "-Q") {
				// Quarter period - subdivide into months
				log.Info().Str("period", period.Label).Msg(indent + "Subdividing quarter into months")
				subPeriods = subdivideQuarterIntoMonths(period)
			} else if !strings.Contains(period.Label, "-") {
				// Year period (no dash in label) - subdivide into quarters
				year := period.Start.Year()
				log.Info().Str("period", period.Label).Msg(indent + "Subdividing year into quarters")
				subPeriods = subdivideYearIntoQuarters(year)
			} else {
				// Month period - can't subdivide further
				log.Warn().
					Str("period", period.Label).
					Msg(indent + "Cannot subdivide month further, fetching what we can")
				break
			}

			// Recursively fetch each sub-period and merge results so
			// failures and suspicious empties propagate to the top level
			for _, subPeriod := range subPeriods {
				subResult := fetchCommitsForPeriod(db, username, subPeriod, depth+1)
				result.Fetched += subResult.Fetched
				result.New += subResult.New
				if subResult.Err != nil {
					log.Error().
						Err(subResult.Err).
						Str("sub_period", subPeriod.Label).
						Int("partial_fetched", subResult.Fetched).
						Int("partial_new", subResult.New).
						Msg("Error fetching sub-period")
					if result.Err == nil {
						result.Err = fmt.Errorf("sub-period %s: %w", subPeriod.Label, subResult.Err)
					}
				}
				if subResult.SuspiciousEmpty {
					result.SuspiciousEmpty = true
				}
			}

			return result
		}

		page++
	}

	return result
}

// fetchCommitsWithRetry fetches a page of commits, retrying with
// exponential backoff on failure to ride out rate limits and
// transient Search API errors
func fetchCommitsWithRetry(username string, page, perPage int, period *TimePeriod, depth int, indent string) ([]CommitResult, int, error) {
	var lastErr error
	for attempt := 0; attempt <= MaxAPIRetries; attempt++ {
		if attempt > 0 {
			delay := RetryBaseDelay * (1 << (attempt - 1))
			log.Warn().
				Str("period", period.Label).
				Int("page", page).
				Int("attempt", attempt).
				Dur("delay", delay).
				Err(lastErr).
				Msg(indent + "Retrying commit fetch")
			time.Sleep(delay)
		}

		commits, totalCount, err := fetchCommits(username, page, perPage, period)
		if err == nil {
			return commits, totalCount, nil
		}
		lastErr = err
	}
	return nil, 0, lastErr
}

// isSuspiciousEmpty reports whether a zero-commit period should be
// trusted. A period is suspect when the database already holds commits
// in that date range, or when the period has started and overlaps the
// recent window where an active author would be expected to have
// commits. Periods that have not started yet legitimately have none.
func isSuspiciousEmpty(db *sql.DB, period TimePeriod) bool {
	exists, err := commitsExistInRange(db, period.Start, period.End)
	if err != nil {
		log.Error().Err(err).Str("period", period.Label).Msg("Error checking for existing commits in period")
		return false
	}
	if exists {
		return true
	}
	now := time.Now().UTC()
	if period.Start.After(now) {
		return false
	}
	return now.Sub(period.End) < RecentPeriodAge
}

// commitsExistInRange reports whether the database holds any commit
// with an author_date inside the given range
func commitsExistInRange(db *sql.DB, start, end time.Time) (bool, error) {
	var count int
	err := db.QueryRow(
		"SELECT COUNT(*) FROM commits WHERE author_date >= ? AND author_date <= ?",
		start.Format(time.RFC3339), end.Format(time.RFC3339),
	).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("failed to check for commits in range: %w", err)
	}
	return count > 0, nil
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

	log.Info().Msg("Starting GitHub commit history fetcher")

	// Initialize database
	db, err := initDatabase()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to initialize database")
	}
	defer db.Close()

	// Get GitHub username from gh api
	username, err := getGitHubUsername()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to get GitHub username")
	}
	log.Info().Str("username", username).Msg("Retrieved GitHub username")

	// Fetch commits using date-based partitioning
	currentYear := time.Now().UTC().Year()
	periods := generateYearlyPeriods(SearchAPIStartYear, currentYear)

	totalFetched := 0
	newCommits := 0

	log.Info().
		Int("start_year", SearchAPIStartYear).
		Int("end_year", currentYear).
		Int("periods", len(periods)).
		Msg("Starting date-partitioned fetch (use historical-commits.go for pre-2020)")

	type problemPeriod struct {
		label         string
		result        PeriodResult
		isCurrentYear bool
	}

	var problemPeriods []problemPeriod

	for _, period := range periods {
		result := fetchCommitsForPeriod(db, username, period, 0)
		totalFetched += result.Fetched
		newCommits += result.New

		if result.Err != nil {
			log.Error().
				Err(result.Err).
				Str("period", period.Label).
				Int("partial_fetched", result.Fetched).
				Int("partial_new", result.New).
				Msg("Error fetching period")
			problemPeriods = append(problemPeriods, problemPeriod{label: period.Label, result: result, isCurrentYear: period.IsCurrentYear()})
		} else {
			if result.SuspiciousEmpty {
				log.Warn().
					Str("period", period.Label).
					Msg("Period returned zero commits despite evidence commits should exist")
				problemPeriods = append(problemPeriods, problemPeriod{label: period.Label, result: result, isCurrentYear: period.IsCurrentYear()})
			}

			log.Info().
				Str("period", period.Label).
				Int("period_fetched", result.Fetched).
				Int("period_new", result.New).
				Int("total_fetched", totalFetched).
				Int("total_new", newCommits).
				Msg("Period completed")
		}
	}

	// Surface problem periods in the final summary instead of
	// silently skipping them (see issue #490)
	if len(problemPeriods) > 0 {
		log.Warn().
			Int("problem_periods", len(problemPeriods)).
			Msg("Some periods failed or returned suspiciously empty results")
		for _, p := range problemPeriods {
			if p.result.Err != nil {
				log.Warn().
					Str("period", p.label).
					Bool("current_year", p.isCurrentYear).
					Err(p.result.Err).
					Msg("Failed period")
			} else {
				log.Warn().
					Str("period", p.label).
					Bool("current_year", p.isCurrentYear).
					Msg("Suspiciously empty period")
			}
		}
	}

	log.Info().
		Int("total_fetched", totalFetched).
		Int("new_commits", newCommits).
		Int("problem_periods", len(problemPeriods)).
		Str("database", DatabaseFile).
		Msg("Commit history fetch completed")

	// A gap in the current year means recent commits went missing
	// from the database; fail the run so the update pipeline notices
	// instead of committing a silently stale commits.db
	for _, p := range problemPeriods {
		if p.isCurrentYear {
			log.Error().
				Str("period", p.label).
				Msg("Current-year period incomplete - failing so the gap is retried instead of silently accepted")
			os.Exit(1)
		}
	}
}

func initDatabase() (*sql.DB, error) {
	db, err := sql.Open("sqlite3", DatabaseFile)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	createTableSQL := `
	CREATE TABLE IF NOT EXISTS commits (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		sha TEXT NOT NULL UNIQUE,
		author_name TEXT NOT NULL,
		author_email TEXT NOT NULL,
		author_date TEXT NOT NULL,
		committer_name TEXT NOT NULL,
		committer_email TEXT NOT NULL,
		committer_date TEXT NOT NULL,
		message TEXT NOT NULL,
		emoji TEXT,
		repo_name TEXT NOT NULL,
		repo_full_name TEXT NOT NULL,
		html_url TEXT NOT NULL,
		fetched_at TEXT NOT NULL
	);

	CREATE INDEX IF NOT EXISTS idx_sha ON commits(sha);
	CREATE INDEX IF NOT EXISTS idx_author_date ON commits(author_date);
	CREATE INDEX IF NOT EXISTS idx_repo_full_name ON commits(repo_full_name);
	CREATE INDEX IF NOT EXISTS idx_author_email ON commits(author_email);
	CREATE INDEX IF NOT EXISTS idx_fetched_at ON commits(fetched_at);
	CREATE INDEX IF NOT EXISTS idx_emoji ON commits(emoji);
	`

	if _, err := db.Exec(createTableSQL); err != nil {
		return nil, fmt.Errorf("failed to create table: %w", err)
	}

	return db, nil
}

func getGitHubUsername() (string, error) {
	// In CI (GitHub Actions), use GITHUB_ACTOR environment variable
	if actor := os.Getenv("GITHUB_ACTOR"); actor != "" {
		return actor, nil
	}

	// Fall back to gh CLI for local development
	cmd := exec.Command("gh", "api", "user", "--jq", ".login")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("gh api user failed: %w", err)
	}

	// Trim any whitespace/newlines safely
	username := strings.TrimSpace(string(output))

	return username, nil
}

func fetchCommits(username string, page, perPage int, period *TimePeriod) ([]CommitResult, int, error) {
	// Use gh api to search for commits
	query := fmt.Sprintf("author:%s", username)

	// Add date range to query if period is specified
	if period != nil {
		dateRange := fmt.Sprintf("%s..%s",
			period.Start.Format(DateFormatShort),
			period.End.Format(DateFormatShort))
		// Use + for URL encoding of spaces in query
		query = fmt.Sprintf("%s+author-date:%s", query, dateRange)
	}

	apiURL := fmt.Sprintf("/search/commits?q=%s&sort=author-date&order=desc&per_page=%d&page=%d",
		query, perPage, page)

	log.Debug().
		Str("query", query).
		Str("api_url", apiURL).
		Msg("Making API request")

	cmd := exec.Command("gh", "api", apiURL)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, 0, fmt.Errorf("gh api failed: %s", string(exitErr.Stderr))
		}
		return nil, 0, fmt.Errorf("gh api failed: %w", err)
	}

	var response CommitSearchResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, 0, fmt.Errorf("failed to parse JSON: %w", err)
	}

	return response.Items, response.TotalCount, nil
}

func commitExists(db *sql.DB, sha string) (bool, error) {
	var count int
	err := db.QueryRow("SELECT COUNT(*) FROM commits WHERE sha = ?", sha).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("failed to check if commit exists: %w", err)
	}
	return count > 0, nil
}

func saveCommit(db *sql.DB, record *CommitRecord) error {
	insertSQL := `
	INSERT INTO commits (
		sha, author_name, author_email, author_date,
		committer_name, committer_email, committer_date,
		message, emoji, repo_name, repo_full_name, html_url, fetched_at
	)
	VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`

	_, err := db.Exec(
		insertSQL,
		record.SHA,
		record.AuthorName,
		record.AuthorEmail,
		record.AuthorDate.Format(time.RFC3339),
		record.CommitterName,
		record.CommitterEmail,
		record.CommitterDate.Format(time.RFC3339),
		record.Message,
		record.Emoji,
		record.RepoName,
		record.RepoFullName,
		record.HTMLURL,
		record.FetchedAt.Format(time.RFC3339),
	)

	if err != nil {
		return fmt.Errorf("failed to insert commit: %w", err)
	}

	return nil
}

// extractEmoji extracts the first emoji from a commit message
// Returns empty string if no emoji is found
func extractEmoji(message string) string {
	// Regex pattern to match emojis
	// This covers most common emoji ranges in Unicode
	emojiPattern := regexp.MustCompile(`[\x{1F600}-\x{1F64F}]|` + // Emoticons
		`[\x{1F300}-\x{1F5FF}]|` + // Misc Symbols and Pictographs
		`[\x{1F680}-\x{1F6FF}]|` + // Transport and Map
		`[\x{1F1E0}-\x{1F1FF}]|` + // Flags
		`[\x{2600}-\x{26FF}]|` + // Misc symbols
		`[\x{2700}-\x{27BF}]|` + // Dingbats
		`[\x{1F900}-\x{1F9FF}]|` + // Supplemental Symbols and Pictographs
		`[\x{1FA00}-\x{1FA6F}]|` + // Chess Symbols
		`[\x{1FA70}-\x{1FAFF}]|` + // Symbols and Pictographs Extended-A
		`[\x{FE00}-\x{FE0F}]|` + // Variation Selectors
		`[\x{1F018}-\x{1F270}]|` + // Various asian characters
		`[\x{238C}-\x{2454}]|` + // Misc items
		`[\x{20D0}-\x{20FF}]`) // Combining Diacritical Marks for Symbols

	match := emojiPattern.FindString(message)
	return match
}
