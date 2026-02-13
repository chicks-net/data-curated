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
	DatabaseFile     = "./commits.db"
	DateFormatShort  = "2006-01-02"
	EnvJSONLogs      = "JSON_LOGS"
	EnvJSONLogsValue = "true"
	GitHubStartYear  = 2008
	MaxReposPerYear  = 100
	CommitsPerPage   = 100
	SHALogLength     = 7
)

type CommitContributionsResponse struct {
	Data struct {
		User struct {
			ContributionsCollection struct {
				CommitContributionsByRepository []struct {
					Repository struct {
						NameWithOwner string `json:"nameWithOwner"`
					} `json:"repository"`
					Contributions struct {
						TotalCount int `json:"totalCount"`
					} `json:"contributions"`
				} `json:"commitContributionsByRepository"`
			} `json:"contributionsCollection"`
		} `json:"user"`
	} `json:"data"`
}

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

type FailedRepo struct {
	Repo string
	Year int
	Err  error
}

func main() {
	configureLogging()

	log.Info().Msg("Starting historical GitHub commits fetcher (pre-2020)")

	db, err := initDatabase()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to initialize database")
	}
	defer db.Close()

	username, err := getGitHubUsername()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to get GitHub username")
	}
	log.Info().Str("username", username).Msg("Retrieved GitHub username")

	totalFetched := 0
	newCommits := 0
	var failedRepos []FailedRepo

	startYear := GitHubStartYear
	endYear := 2019 // GitHub Search API works reliably from 2020 onward

	log.Info().
		Int("start_year", startYear).
		Int("end_year", endYear).
		Msg("Processing historical years")

	for year := endYear; year >= startYear; year-- {
		yearStart := time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC)
		yearEnd := time.Date(year, 12, 31, 23, 59, 59, 0, time.UTC)

		log.Info().
			Int("year", year).
			Str("from", yearStart.Format(DateFormatShort)).
			Str("to", yearEnd.Format(DateFormatShort)).
			Msg("Processing year")

		repos, err := discoverReposWithCommits(username, yearStart, yearEnd)
		if err != nil {
			log.Error().Err(err).Int("year", year).Msg("Error discovering repos")
			continue
		}

		if len(repos) == 0 {
			log.Info().Int("year", year).Msg("No repos with commits found for year")
			continue
		}

		log.Info().
			Int("year", year).
			Int("repos", len(repos)).
			Msg("Discovered repos with commits")

		yearFetched := 0
		yearNew := 0

		for _, repo := range repos {
			fetched, new, err := fetchRepoCommits(db, username, repo, yearStart, yearEnd)
			if err != nil {
				log.Error().
					Err(err).
					Str("repo", repo).
					Int("year", year).
					Msg("Error fetching repo commits")
				failedRepos = append(failedRepos, FailedRepo{Repo: repo, Year: year, Err: err})
				continue
			}
			yearFetched += fetched
			yearNew += new
		}

		totalFetched += yearFetched
		newCommits += yearNew

		log.Info().
			Int("year", year).
			Int("fetched", yearFetched).
			Int("new", yearNew).
			Int("total_fetched", totalFetched).
			Int("total_new", newCommits).
			Msg("Year completed")
	}

	if len(failedRepos) > 0 {
		log.Warn().
			Int("failed_count", len(failedRepos)).
			Msg("Some repos failed to fetch - consider re-running to retry")
		for _, f := range failedRepos {
			log.Warn().
				Str("repo", f.Repo).
				Int("year", f.Year).
				Err(f.Err).
				Msg("Failed repo")
		}
	}

	log.Info().
		Int("total_fetched", totalFetched).
		Int("new_commits", newCommits).
		Int("failed_repos", len(failedRepos)).
		Str("database", DatabaseFile).
		Msg("Historical commits fetch completed")
}

func configureLogging() {
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

	username := strings.TrimSpace(string(output))
	return username, nil
}

func discoverReposWithCommits(username string, from, to time.Time) ([]string, error) {
	query := fmt.Sprintf(`
	query {
		user(login: "%s") {
			contributionsCollection(from: "%s", to: "%s") {
				commitContributionsByRepository(maxRepositories: %d) {
					repository {
						nameWithOwner
					}
					contributions {
						totalCount
					}
				}
			}
		}
	}
	`, username, from.Format(time.RFC3339), to.Format(time.RFC3339), MaxReposPerYear)

	cmd := exec.Command("gh", "api", "graphql", "-f", fmt.Sprintf("query=%s", query))
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("gh api graphql failed: %w", err)
	}

	var response CommitContributionsResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, fmt.Errorf("failed to parse JSON: %w", err)
	}

	var repos []string
	for _, item := range response.Data.User.ContributionsCollection.CommitContributionsByRepository {
		if item.Contributions.TotalCount > 0 {
			repos = append(repos, item.Repository.NameWithOwner)
		}
	}

	return repos, nil
}

func fetchRepoCommits(db *sql.DB, username, repoName string, from, to time.Time) (int, int, error) {
	parts := strings.Split(repoName, "/")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("invalid repo name format: %s", repoName)
	}
	owner := parts[0]
	repo := parts[1]

	totalFetched := 0
	newCommits := 0
	page := 1

	for {
		apiURL := fmt.Sprintf("/repos/%s/%s/commits?author=%s&since=%s&until=%s&per_page=%d&page=%d",
			owner, repo, username,
			from.Format(time.RFC3339),
			to.Format(time.RFC3339),
			CommitsPerPage, page)

		log.Debug().
			Str("repo", repoName).
			Int("page", page).
			Str("api_url", apiURL).
			Msg("Fetching commits from repo")

		cmd := exec.Command("gh", "api", apiURL)
		output, err := cmd.Output()
		if err != nil {
			return totalFetched, newCommits, fmt.Errorf("gh api failed: %w", err)
		}

		var commits []map[string]interface{}
		if err := json.Unmarshal(output, &commits); err != nil {
			return totalFetched, newCommits, fmt.Errorf("failed to parse JSON: %w", err)
		}

		if len(commits) == 0 {
			break
		}

		for _, commitData := range commits {
			commit, err := parseCommit(commitData, repoName)
			if err != nil {
				log.Debug().Err(err).Msg("Error parsing commit")
				continue
			}

			exists, err := commitExists(db, commit.SHA)
			if err != nil {
				log.Error().Err(err).Str("sha", commit.SHA).Msg("Error checking if commit exists")
				continue
			}

			if exists {
				log.Debug().Str("sha", commit.SHA[:SHALogLength]).Msg("Commit already exists, skipping")
				continue
			}

			if err := saveCommit(db, commit); err != nil {
				log.Error().Err(err).Str("sha", commit.SHA).Msg("Error saving commit")
			} else {
				newCommits++
				log.Debug().
					Str("sha", commit.SHA[:SHALogLength]).
					Str("repo", commit.RepoFullName).
					Str("date", commit.AuthorDate.Format(DateFormatShort)).
					Msg("Saved commit")
			}
		}

		totalFetched += len(commits)

		if len(commits) < CommitsPerPage {
			break
		}

		page++
	}

	log.Info().
		Str("repo", repoName).
		Int("fetched", totalFetched).
		Int("new", newCommits).
		Msg("Repo processing completed")

	return totalFetched, newCommits, nil
}

func parseCommit(data map[string]interface{}, repoName string) (*CommitRecord, error) {
	sha, ok := data["sha"].(string)
	if !ok {
		return nil, fmt.Errorf("missing or invalid sha")
	}

	htmlURL, _ := data["html_url"].(string)

	commitData, ok := data["commit"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("missing commit data")
	}

	authorData, ok := commitData["author"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("missing author data")
	}

	authorName, _ := authorData["name"].(string)
	authorEmail, _ := authorData["email"].(string)
	authorDateStr, _ := authorData["date"].(string)
	authorDate, err := time.Parse(time.RFC3339, authorDateStr)
	if err != nil {
		authorDate, err = time.Parse("2006-01-02T15:04:05Z", authorDateStr)
		if err != nil {
			return nil, fmt.Errorf("failed to parse author date: %w", err)
		}
	}

	committerData, ok := commitData["committer"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("missing committer data")
	}

	committerName, _ := committerData["name"].(string)
	committerEmail, _ := committerData["email"].(string)
	committerDateStr, _ := committerData["date"].(string)
	committerDate, err := time.Parse(time.RFC3339, committerDateStr)
	if err != nil {
		committerDate, err = time.Parse("2006-01-02T15:04:05Z", committerDateStr)
		if err != nil {
			return nil, fmt.Errorf("failed to parse committer date: %w", err)
		}
	}

	message, _ := commitData["message"].(string)

	parts := strings.Split(repoName, "/")
	repoShortName := repoName
	if len(parts) == 2 {
		repoShortName = parts[1]
	}

	return &CommitRecord{
		SHA:            sha,
		AuthorName:     authorName,
		AuthorEmail:    authorEmail,
		AuthorDate:     authorDate,
		CommitterName:  committerName,
		CommitterEmail: committerEmail,
		CommitterDate:  committerDate,
		Message:        message,
		Emoji:          extractEmoji(message),
		RepoName:       repoShortName,
		RepoFullName:   repoName,
		HTMLURL:        htmlURL,
		FetchedAt:      time.Now().UTC(),
	}, nil
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

func extractEmoji(message string) string {
	emojiPattern := regexp.MustCompile(`[\x{1F600}-\x{1F64F}]|` +
		`[\x{1F300}-\x{1F5FF}]|` +
		`[\x{1F680}-\x{1F6FF}]|` +
		`[\x{1F1E0}-\x{1F1FF}]|` +
		`[\x{2600}-\x{26FF}]|` +
		`[\x{2700}-\x{27BF}]|` +
		`[\x{1F900}-\x{1F9FF}]|` +
		`[\x{1FA00}-\x{1FA6F}]|` +
		`[\x{1FA70}-\x{1FAFF}]|` +
		`[\x{FE00}-\x{FE0F}]|` +
		`[\x{1F018}-\x{1F270}]|` +
		`[\x{238C}-\x{2454}]|` +
		`[\x{20D0}-\x{20FF}]`)

	match := emojiPattern.FindString(message)
	return match
}
