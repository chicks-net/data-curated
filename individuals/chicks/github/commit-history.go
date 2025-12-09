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
	CommitsPerPage      = 100  // Number of commits to fetch per API request
	GitHubAPILimit      = 1000 // Maximum results returned by GitHub Search API
	SHALogLength        = 7    // Number of SHA characters to display in logs
	DatabaseFile        = "./commits.db"
	InitialPage         = 1 // Starting page number for pagination
	DateFormatShort     = "2006-01-02"
	EnvJSONLogs         = "JSON_LOGS"
	EnvJSONLogsValue    = "true"
)

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

	// Fetch commits with pagination
	page := InitialPage
	perPage := CommitsPerPage
	totalFetched := 0
	newCommits := 0

	for {
		log.Info().Int("page", page).Msg("Fetching commits")

		commits, totalCount, err := fetchCommits(username, page, perPage)
		if err != nil {
			log.Error().Err(err).Int("page", page).Msg("Error fetching commits")
			break
		}

		if len(commits) == 0 {
			log.Info().Msg("No more commits to fetch")
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
				log.Debug().Str("sha", commit.SHA).Msg("Commit already exists, skipping")
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
				newCommits++
				log.Debug().
					Str("sha", commit.SHA[:SHALogLength]).
					Str("repo", commit.Repository.FullName).
					Str("date", commit.Commit.Author.Date.Format(DateFormatShort)).
					Msg("Saved commit")
			}
		}

		totalFetched += len(commits)
		log.Info().
			Int("page", page).
			Int("fetched", len(commits)).
			Int("total_fetched", totalFetched).
			Int("new_commits", newCommits).
			Int("total_available", totalCount).
			Msg("Page processed")

		// Check if we've fetched all commits
		if totalFetched >= totalCount {
			log.Info().Msg("All commits fetched")
			break
		}

		// GitHub search API has a limit
		if totalFetched >= GitHubAPILimit {
			log.Warn().
				Int("limit", GitHubAPILimit).
				Msg("Reached GitHub search API limit")
			break
		}

		page++
	}

	log.Info().
		Int("total_fetched", totalFetched).
		Int("new_commits", newCommits).
		Str("database", DatabaseFile).
		Msg("Commit history fetch completed")
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
	cmd := exec.Command("gh", "api", "user", "--jq", ".login")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("gh api user failed: %w", err)
	}

	// Trim any whitespace/newlines safely
	username := strings.TrimSpace(string(output))

	return username, nil
}

func fetchCommits(username string, page, perPage int) ([]CommitResult, int, error) {
	// Use gh api to search for commits
	query := fmt.Sprintf("author:%s", username)
	apiURL := fmt.Sprintf("/search/commits?q=%s&sort=author-date&order=desc&per_page=%d&page=%d",
		query, perPage, page)

	cmd := exec.Command("gh", "api", apiURL)
	output, err := cmd.Output()
	if err != nil {
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
