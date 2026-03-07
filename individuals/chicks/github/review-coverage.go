package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

const (
	dbFile           = "reviews.db"
	EnvJSONLogs      = "JSON_LOGS"
	EnvJSONLogsValue = "true"
)

var ownOrgs = []string{"chicks-net", "fini-net"}

type Repository struct {
	Owner     string
	Name      string
	FullName  string
	IsOrg     bool
	PRCount   int
	FetchedAt time.Time
}

type PullRequest struct {
	Number      int
	Title       string
	State       string
	CreatedAt   time.Time
	MergedAt    *time.Time
	ClosedAt    *time.Time
	AuthorLogin string
	HeadRef     string
	BaseRef     string
}

type TimelineEvent struct {
	Event     string    `json:"event"`
	CreatedAt time.Time `json:"created_at"`
	CommitSHA string    `json:"sha"`
}

type PRReview struct {
	ID   int `json:"id"`
	User struct {
		Login string `json:"login"`
	} `json:"user"`
	State       string    `json:"state"`
	SubmittedAt time.Time `json:"submitted_at"`
}

type IssueComment struct {
	ID   int `json:"id"`
	User struct {
		Login string `json:"login"`
	} `json:"user"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
	HTMLURL   string    `json:"html_url"`
}

type BotReview struct {
	RepoFullName string
	PRNumber     int
	BotType      string
	ReviewID     string
	ReviewType   string
	AuthorLogin  string
	SubmittedAt  time.Time
	State        *string
}

type RepoStats struct {
	FullName        string
	PRCount         int
	PRsWClaude      int
	PRsWCopilot     int
	ClaudeCoverage  float64
	CopilotCoverage float64
}

type GapStats struct {
	ClaudeGaps     []PRGap
	CopilotMissing []PRGap
}

type PRGap struct {
	PRNumber       int
	Title          string
	State          string
	Pushes         int
	ClaudeReviews  int
	CopilotReviews int
}

func main() {
	if os.Getenv(EnvJSONLogs) == EnvJSONLogsValue {
		log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stdout, TimeFormat: time.RFC3339})
	} else {
		log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.RFC3339})
	}

	log.Info().Msg("Starting code review coverage analysis")

	db, err := initDatabase()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to initialize database")
	}
	defer db.Close()

	repos, err := discoverRepositories()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to discover repositories")
	}

	log.Info().Int("count", len(repos)).Msg("Discovered repositories")

	clearTables(db)

	for _, repo := range repos {
		log.Info().Str("repo", repo.FullName).Msg("Analyzing repository")
		if err := analyzeRepository(db, repo); err != nil {
			log.Error().Err(err).Str("repo", repo.FullName).Msg("Failed to analyze repository")
			continue
		}
	}

	generateReport(db)

	log.Info().Msg("Analysis complete")
}

func initDatabase() (*sql.DB, error) {
	db, err := sql.Open("sqlite3", dbFile)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	schema := `
	CREATE TABLE IF NOT EXISTS repositories (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		owner TEXT NOT NULL,
		name TEXT NOT NULL,
		full_name TEXT NOT NULL UNIQUE,
		is_org BOOLEAN NOT NULL,
		pr_count INTEGER NOT NULL DEFAULT 0,
		fetched_at TEXT NOT NULL
	);

	CREATE TABLE IF NOT EXISTS pull_requests (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		repo_full_name TEXT NOT NULL,
		pr_number INTEGER NOT NULL,
		title TEXT,
		state TEXT NOT NULL,
		created_at TEXT NOT NULL,
		merged_at TEXT,
		closed_at TEXT,
		author_login TEXT,
		opened_events INTEGER NOT NULL DEFAULT 1,
		synchronize_events INTEGER NOT NULL DEFAULT 0,
		total_pushes INTEGER NOT NULL DEFAULT 1,
		fetched_at TEXT NOT NULL,
		UNIQUE(repo_full_name, pr_number)
	);

	CREATE TABLE IF NOT EXISTS bot_reviews (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		repo_full_name TEXT NOT NULL,
		pr_number INTEGER NOT NULL,
		bot_type TEXT NOT NULL,
		review_id TEXT NOT NULL UNIQUE,
		review_type TEXT NOT NULL,
		author_login TEXT NOT NULL,
		submitted_at TEXT NOT NULL,
		state TEXT,
		fetched_at TEXT NOT NULL,
		FOREIGN KEY (repo_full_name, pr_number) REFERENCES pull_requests(repo_full_name, pr_number)
	);

	DROP VIEW IF EXISTS coverage_summary;

	CREATE VIEW coverage_summary AS
	SELECT 
		pr.repo_full_name,
		pr.pr_number,
		pr.title,
		pr.state,
		pr.author_login,
		pr.total_pushes,
		SUM(CASE WHEN br.bot_type = 'claude' THEN 1 ELSE 0 END) as claude_reviews,
		SUM(CASE WHEN br.bot_type = 'copilot' THEN 1 ELSE 0 END) as copilot_reviews
	FROM pull_requests pr
	LEFT JOIN bot_reviews br ON pr.repo_full_name = br.repo_full_name AND pr.pr_number = br.pr_number
	GROUP BY pr.repo_full_name, pr.pr_number;
	
	CREATE INDEX IF NOT EXISTS idx_pr_repo ON pull_requests(repo_full_name);
	CREATE INDEX IF NOT EXISTS idx_br_repo ON bot_reviews(repo_full_name);
	CREATE INDEX IF NOT EXISTS idx_br_type ON bot_reviews(bot_type);
	`

	_, err = db.Exec(schema)
	if err != nil {
		return nil, fmt.Errorf("failed to create schema: %w", err)
	}

	return db, nil
}

func clearTables(db *sql.DB) error {
	tables := []string{"bot_reviews", "pull_requests", "repositories"}
	for _, table := range tables {
		_, err := db.Exec(fmt.Sprintf("DELETE FROM %s", table))
		if err != nil {
			return fmt.Errorf("failed to clear table %s: %w", table, err)
		}
	}
	return nil
}

func discoverRepositories() ([]Repository, error) {
	var repos []Repository

	for _, org := range ownOrgs {
		log.Info().Str("org", org).Msg("Discovering repositories")

		isOrg, err := isOrganization(org)
		if err != nil {
			log.Warn().Err(err).Str("org", org).Msg("Failed to determine org status")
			isOrg = true
		}

		orgRepos, err := fetchRepositories(org, isOrg)
		if err != nil {
			log.Error().Err(err).Str("org", org).Msg("Failed to fetch repositories")
			continue
		}

		log.Info().Str("org", org).Int("count", len(orgRepos)).Msg("Found repositories")
		repos = append(repos, orgRepos...)
	}

	return repos, nil
}

func isOrganization(owner string) (bool, error) {
	cmd := exec.Command("gh", "api", fmt.Sprintf("users/%s", owner))
	output, err := cmd.Output()
	if err != nil {
		return false, fmt.Errorf("failed to check user type: %w", err)
	}

	var result struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(output, &result); err != nil {
		return false, fmt.Errorf("failed to parse user type: %w", err)
	}

	return result.Type == "Organization", nil
}

func fetchRepositories(owner string, isOrg bool) ([]Repository, error) {
	var repos []Repository
	page := 1
	perPage := 100

	for {
		var url string
		if isOrg {
			url = fmt.Sprintf("orgs/%s/repos?per_page=%d&page=%d&type=public", owner, perPage, page)
		} else {
			url = fmt.Sprintf("users/%s/repos?per_page=%d&page=%d&type=public", owner, perPage, page)
		}

		cmd := exec.Command("gh", "api", url)
		output, err := cmd.Output()
		if err != nil {
			return nil, fmt.Errorf("failed to fetch repositories: %w", err)
		}

		var result []struct {
			Name     string `json:"name"`
			FullName string `json:"full_name"`
			Owner    struct {
				Login string `json:"login"`
			} `json:"owner"`
		}

		if err := json.Unmarshal(output, &result); err != nil {
			return nil, fmt.Errorf("failed to parse repositories: %w", err)
		}

		if len(result) == 0 {
			break
		}

		for _, r := range result {
			repos = append(repos, Repository{
				Owner:     r.Owner.Login,
				Name:      r.Name,
				FullName:  r.FullName,
				IsOrg:     isOrg,
				FetchedAt: time.Now(),
			})
		}

		if len(result) < perPage {
			break
		}

		page++
	}

	return repos, nil
}

func analyzeRepository(db *sql.DB, repo Repository) error {
	prs, err := fetchPullRequests(repo.FullName)
	if err != nil {
		return fmt.Errorf("failed to fetch pull requests: %w", err)
	}

	if len(prs) == 0 {
		log.Info().Str("repo", repo.FullName).Msg("Skipping repository with no PRs")
		return nil
	}

	repo.PRCount = len(prs)

	if err := storeRepository(db, repo); err != nil {
		return fmt.Errorf("failed to store repository: %w", err)
	}

	for _, pr := range prs {
		if err := analyzePR(db, repo, pr); err != nil {
			log.Error().Err(err).
				Str("repo", repo.FullName).
				Int("pr", pr.Number).
				Msg("Failed to analyze PR")
			continue
		}
	}

	return nil
}

func fetchPullRequests(repoFullName string) ([]PullRequest, error) {
	var prs []PullRequest
	page := 1
	perPage := 100

	for {
		url := fmt.Sprintf("repos/%s/pulls?state=all&per_page=%d&page=%d", repoFullName, perPage, page)
		cmd := exec.Command("gh", "api", url)
		output, err := cmd.Output()
		if err != nil {
			return nil, fmt.Errorf("failed to fetch PRs: %w", err)
		}

		var result []struct {
			Number   int     `json:"number"`
			Title    string  `json:"title"`
			State    string  `json:"state"`
			Created  string  `json:"created_at"`
			MergedAt *string `json:"merged_at"`
			ClosedAt *string `json:"closed_at"`
			User     struct {
				Login string `json:"login"`
			} `json:"user"`
			Head struct {
				Ref string `json:"ref"`
			} `json:"head"`
			Base struct {
				Ref string `json:"ref"`
			} `json:"base"`
		}

		if err := json.Unmarshal(output, &result); err != nil {
			return nil, fmt.Errorf("failed to parse PRs: %w", err)
		}

		if len(result) == 0 {
			break
		}

		for _, r := range result {
			var mergedAt, closedAt *time.Time
			if r.MergedAt != nil {
				t, _ := time.Parse(time.RFC3339, *r.MergedAt)
				mergedAt = &t
			}
			if r.ClosedAt != nil {
				t, _ := time.Parse(time.RFC3339, *r.ClosedAt)
				closedAt = &t
			}

			createdAt, _ := time.Parse(time.RFC3339, r.Created)

			pr := PullRequest{
				Number:      r.Number,
				Title:       r.Title,
				State:       r.State,
				CreatedAt:   createdAt,
				MergedAt:    mergedAt,
				ClosedAt:    closedAt,
				AuthorLogin: r.User.Login,
				HeadRef:     r.Head.Ref,
				BaseRef:     r.Base.Ref,
			}
			prs = append(prs, pr)
		}

		if len(result) < perPage {
			break
		}

		page++
	}

	return prs, nil
}

func analyzePR(db *sql.DB, repo Repository, pr PullRequest) error {
	openedCount := 0
	syncCount := 0

	timeline, err := fetchTimeline(repo.FullName, pr.Number)
	if err != nil {
		log.Warn().Err(err).
			Str("repo", repo.FullName).
			Int("pr", pr.Number).
			Msg("Failed to fetch timeline, using defaults")
		openedCount = 1
	} else {
		for _, event := range timeline {
			if event.Event == "opened" {
				openedCount++
			}
			if event.Event == "synchronize" {
				syncCount++
			}
		}
	}

	if openedCount == 0 {
		openedCount = 1
	}

	if err := storePullRequest(db, repo, pr, openedCount, syncCount); err != nil {
		return fmt.Errorf("failed to store PR: %w", err)
	}

	if err := fetchPRReviews(db, repo, pr); err != nil {
		log.Warn().Err(err).
			Str("repo", repo.FullName).
			Int("pr", pr.Number).
			Msg("Failed to fetch PR reviews")
	}

	if err := fetchIssueCommentsForPR(db, repo, pr); err != nil {
		log.Warn().Err(err).
			Str("repo", repo.FullName).
			Int("pr", pr.Number).
			Msg("Failed to fetch issue comments")
	}

	return nil
}

func fetchTimeline(repoFullName string, prNumber int) ([]TimelineEvent, error) {
	url := fmt.Sprintf("repos/%s/issues/%d/timeline", repoFullName, prNumber)
	cmd := exec.Command("gh", "api", url)
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to fetch timeline: %w", err)
	}

	var events []TimelineEvent
	if err := json.Unmarshal(output, &events); err != nil {
		return nil, fmt.Errorf("failed to parse timeline: %w", err)
	}

	return events, nil
}

func storeRepository(db *sql.DB, repo Repository) error {
	_, err := db.Exec(`
		INSERT OR REPLACE INTO repositories (owner, name, full_name, is_org, pr_count, fetched_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, repo.Owner, repo.Name, repo.FullName, repo.IsOrg, repo.PRCount, repo.FetchedAt.Format(time.RFC3339))

	return err
}

func storePullRequest(db *sql.DB, repo Repository, pr PullRequest, openedCount, syncCount int) error {
	var mergedAt, closedAt interface{}
	if pr.MergedAt != nil {
		mergedAt = pr.MergedAt.Format(time.RFC3339)
	}
	if pr.ClosedAt != nil {
		closedAt = pr.ClosedAt.Format(time.RFC3339)
	}

	totalPushes := openedCount + syncCount

	_, err := db.Exec(`
		INSERT OR REPLACE INTO pull_requests 
		(repo_full_name, pr_number, title, state, created_at, merged_at, closed_at, author_login, 
		 opened_events, synchronize_events, total_pushes, fetched_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, repo.FullName, pr.Number, pr.Title, pr.State, pr.CreatedAt.Format(time.RFC3339),
		mergedAt, closedAt, pr.AuthorLogin, openedCount, syncCount, totalPushes, time.Now().Format(time.RFC3339))

	return err
}

func fetchPRReviews(db *sql.DB, repo Repository, pr PullRequest) error {
	url := fmt.Sprintf("repos/%s/pulls/%d/reviews", repo.FullName, pr.Number)
	cmd := exec.Command("gh", "api", url)
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to fetch PR reviews: %w", err)
	}

	var reviews []struct {
		ID   int `json:"id"`
		User struct {
			Login string `json:"login"`
		} `json:"user"`
		State       string `json:"state"`
		SubmittedAt string `json:"submitted_at"`
	}

	if err := json.Unmarshal(output, &reviews); err != nil {
		return fmt.Errorf("failed to parse PR reviews: %w", err)
	}

	for _, review := range reviews {
		if isBot(review.User.Login) {
			botType := getBotType(review.User.Login)
			submittedAt, _ := time.Parse(time.RFC3339, review.SubmittedAt)
			state := review.State

			_, err := db.Exec(`
				INSERT OR IGNORE INTO bot_reviews 
				(repo_full_name, pr_number, bot_type, review_id, review_type, author_login, submitted_at, state, fetched_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
			`, repo.FullName, pr.Number, botType, fmt.Sprintf("%d", review.ID), "pr_review",
				review.User.Login, submittedAt.Format(time.RFC3339), state, time.Now().Format(time.RFC3339))

			if err != nil {
				log.Warn().Err(err).
					Str("repo", repo.FullName).
					Int("pr", pr.Number).
					Int("review_id", review.ID).
					Msg("Failed to store bot review")
			}
		}
	}

	return nil
}

func fetchIssueCommentsForPR(db *sql.DB, repo Repository, pr PullRequest) error {
	url := fmt.Sprintf("repos/%s/issues/%d/comments", repo.FullName, pr.Number)
	cmd := exec.Command("gh", "api", url)
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to fetch issue comments: %w", err)
	}

	var comments []struct {
		ID   int `json:"id"`
		User struct {
			Login string `json:"login"`
		} `json:"user"`
		CreatedAt string `json:"created_at"`
	}

	if err := json.Unmarshal(output, &comments); err != nil {
		return fmt.Errorf("failed to parse issue comments: %w", err)
	}

	for _, comment := range comments {
		if isBot(comment.User.Login) {
			botType := getBotType(comment.User.Login)
			createdAt, _ := time.Parse(time.RFC3339, comment.CreatedAt)

			_, err := db.Exec(`
				INSERT OR IGNORE INTO bot_reviews 
				(repo_full_name, pr_number, bot_type, review_id, review_type, author_login, submitted_at, state, fetched_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
			`, repo.FullName, pr.Number, botType, fmt.Sprintf("%d", comment.ID), "issue_comment",
				comment.User.Login, createdAt.Format(time.RFC3339), nil, time.Now().Format(time.RFC3339))

			if err != nil {
				log.Warn().Err(err).
					Str("repo", repo.FullName).
					Int("pr", pr.Number).
					Int("comment_id", comment.ID).
					Msg("Failed to store bot comment")
			}
		}
	}

	return nil
}

func isBot(login string) bool {
	return login == "claude[bot]" || login == "copilot-pull-request-reviewer[bot]"
}

func getBotType(login string) string {
	if strings.Contains(login, "claude") {
		return "claude"
	}
	if strings.Contains(login, "copilot") {
		return "copilot"
	}
	return "unknown"
}

func generateReport(db *sql.DB) {
	fmt.Println("\n=== Code Review Bot Coverage Analysis ===\n")

	totalRepos, totalPRs := getTotals(db)
	fmt.Printf("Repositories Analyzed: %d\n", totalRepos)
	fmt.Printf("Total PRs: %d\n", totalPRs)

	repoStats := getRepoStats(db)
	fmt.Println("\n--- Repository Summary ---")

	for _, stats := range repoStats {
		fmt.Printf("\n%s:\n", stats.FullName)
		fmt.Printf("  PRs: %d\n", stats.PRCount)

		if stats.PRCount > 0 {
			fmt.Printf("  Claude Coverage: %.1f%% (%d/%d)\n",
				stats.ClaudeCoverage, stats.PRsWClaude, stats.PRCount)
			fmt.Printf("  Copilot Coverage: %.1f%% (%d/%d)\n",
				stats.CopilotCoverage, stats.PRsWCopilot, stats.PRCount)

			if stats.PRsWClaude == 0 {
				fmt.Printf("  ⚠️  No Claude reviews despite having PRs\n")
			}
			if stats.PRsWCopilot == 0 {
				fmt.Printf("  ℹ️  No Copilot reviews\n")
			}
		}
	}

	gapStats := getGapStats(db)

	fmt.Println("\n--- PRs with Review Gaps ---")

	if len(gapStats.ClaudeGaps) > 0 {
		fmt.Printf("\nClaude Review Gaps (reviews < pushes):\n")
		fmt.Printf("%-40s | %-6s | %-6s | %-6s\n", "PR", "State", "Pushes", "Claude")
		fmt.Printf("%s-+-%s-+-%s-+-%s\n",
			strings.Repeat("-", 40), strings.Repeat("-", 6), strings.Repeat("-", 6), strings.Repeat("-", 6))
		for _, gap := range gapStats.ClaudeGaps {
			title := gap.Title
			if len(title) > 37 {
				title = title[:34] + "..."
			}
			fmt.Printf("#%-5d %-33s | %-6s | %-6d | %-6d (%d gap)\n",
				gap.PRNumber, title, strings.ToUpper(gap.State), gap.Pushes, gap.ClaudeReviews,
				gap.Pushes-gap.ClaudeReviews)
		}
	} else {
		fmt.Println("\n✓ No Claude review gaps found")
	}

	if len(gapStats.CopilotMissing) > 0 {
		fmt.Printf("\nPRs Missing Copilot Reviews:\n")
		fmt.Printf("%-40s | %-6s\n", "PR", "State")
		fmt.Printf("%s-+-%s\n", strings.Repeat("-", 40), strings.Repeat("-", 6))
		for _, gap := range gapStats.CopilotMissing {
			title := gap.Title
			if len(title) > 37 {
				title = title[:34] + "..."
			}
			fmt.Printf("#%-5d %-33s | %-6s\n",
				gap.PRNumber, title, strings.ToUpper(gap.State))
		}
	} else {
		fmt.Println("\n✓ All PRs have Copilot reviews")
	}

	fmt.Println()
}

func getTotals(db *sql.DB) (int, int) {
	var totalRepos, totalPRs int
	db.QueryRow("SELECT COUNT(*) FROM repositories").Scan(&totalRepos)
	db.QueryRow("SELECT COUNT(*) FROM pull_requests").Scan(&totalPRs)
	return totalRepos, totalPRs
}

func getRepoStats(db *sql.DB) []RepoStats {
	rows, err := db.Query(`
		SELECT 
			r.full_name,
			r.pr_count,
			COUNT(DISTINCT CASE WHEN br.bot_type = 'claude' THEN pr.pr_number END) as prs_w_claude,
			COUNT(DISTINCT CASE WHEN br.bot_type = 'copilot' THEN pr.pr_number END) as prs_w_copilot
		FROM repositories r
		LEFT JOIN pull_requests pr ON r.full_name = pr.repo_full_name
		LEFT JOIN bot_reviews br ON pr.repo_full_name = br.repo_full_name AND pr.pr_number = br.pr_number
		GROUP BY r.full_name
		ORDER BY r.full_name
	`)
	if err != nil {
		log.Error().Err(err).Msg("Failed to get repo stats")
		return nil
	}
	defer rows.Close()

	var stats []RepoStats
	for rows.Next() {
		var s RepoStats
		var prsWClaude, prsWCopilot int
		if err := rows.Scan(&s.FullName, &s.PRCount, &prsWClaude, &prsWCopilot); err != nil {
			log.Error().Err(err).Msg("Failed to scan repo stats")
			continue
		}
		s.PRsWClaude = prsWClaude
		s.PRsWCopilot = prsWCopilot
		if s.PRCount > 0 {
			s.ClaudeCoverage = float64(prsWClaude) / float64(s.PRCount) * 100
			s.CopilotCoverage = float64(prsWCopilot) / float64(s.PRCount) * 100
		}
		stats = append(stats, s)
	}

	return stats
}

func getGapStats(db *sql.DB) *GapStats {
	gaps := &GapStats{}

	rows, err := db.Query(`
		SELECT 
			pr.repo_full_name,
			pr.pr_number,
			pr.title,
			pr.state,
			pr.total_pushes,
			COALESCE(SUM(CASE WHEN br.bot_type = 'claude' THEN 1 ELSE 0 END), 0) as claude_reviews
		FROM pull_requests pr
		LEFT JOIN bot_reviews br ON pr.repo_full_name = br.repo_full_name AND pr.pr_number = br.pr_number
		GROUP BY pr.repo_full_name, pr.pr_number
		HAVING COALESCE(SUM(CASE WHEN br.bot_type = 'claude' THEN 1 ELSE 0 END), 0) < pr.total_pushes
		ORDER BY pr.pr_number DESC
	`)
	if err != nil {
		log.Error().Err(err).Msg("Failed to get Claude gaps")
	} else {
		defer rows.Close()
		for rows.Next() {
			var repoFullName, title, state string
			var prNumber, pushes, claudeReviews int
			if err := rows.Scan(&repoFullName, &prNumber, &title, &state, &pushes, &claudeReviews); err != nil {
				log.Error().Err(err).Msg("Failed to scan Claude gap")
				continue
			}
			gaps.ClaudeGaps = append(gaps.ClaudeGaps, PRGap{
				PRNumber:      prNumber,
				Title:         title,
				State:         state,
				Pushes:        pushes,
				ClaudeReviews: claudeReviews,
			})
		}
	}

	rows, err = db.Query(`
		SELECT 
			pr.repo_full_name,
			pr.pr_number,
			pr.title,
			pr.state
		FROM pull_requests pr
		LEFT JOIN bot_reviews br ON pr.repo_full_name = br.repo_full_name AND pr.pr_number = br.pr_number AND br.bot_type = 'copilot'
		WHERE br.id IS NULL
		ORDER BY pr.pr_number DESC
	`)
	if err != nil {
		log.Error().Err(err).Msg("Failed to get Copilot gaps")
	} else {
		defer rows.Close()
		for rows.Next() {
			var repoFullName, title, state string
			var prNumber int
			if err := rows.Scan(&repoFullName, &prNumber, &title, &state); err != nil {
				log.Error().Err(err).Msg("Failed to scan Copilot gap")
				continue
			}
			gaps.CopilotMissing = append(gaps.CopilotMissing, PRGap{
				PRNumber: prNumber,
				Title:    title,
				State:    state,
			})
		}
	}

	return gaps
}
