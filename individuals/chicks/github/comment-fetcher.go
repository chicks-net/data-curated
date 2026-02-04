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
	dbFile = "comments.db"
)

var ownOrgs = []string{"chicks-net", "fini-net"}

// CommentRecord represents a comment from GitHub
type CommentRecord struct {
	CommentID      string
	CommentType    string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	Body           string
	BodyText       string
	RepoFullName   string
	RepoOwner      string
	RepoOwnerType  string
	IssueNumber    *int
	IssueTitle     *string
	IsPullRequest  *bool
	CommitOID      *string
	DiscussionTitle *string
	GistID         *string
	HTMLURL        string
	IsOwnOrg       bool
}

func main() {
	// Setup logging
	log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.RFC3339})

	log.Info().Msg("Starting GitHub comment fetcher")

	// Get GitHub username
	username, err := getGitHubUsername()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to get GitHub username")
	}
	log.Info().Str("username", username).Msg("Fetching comments for user")

	// Initialize database
	db, err := initDatabase()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to initialize database")
	}
	defer db.Close()

	// Fetch each comment type
	types := []struct {
		name    string
		fetcher func(*sql.DB, string) error
	}{
		{"issue", fetchIssueComments},
		{"commit", fetchCommitComments},
		{"discussion", fetchDiscussionComments},
		{"gist", fetchGistComments},
	}

	totalComments := 0
	for _, t := range types {
		log.Info().Str("type", t.name).Msg("Fetching comments")
		if err := t.fetcher(db, username); err != nil {
			log.Error().Err(err).Str("type", t.name).Msg("Failed to fetch comments")
			continue
		}
		count, _ := getCommentCount(db, t.name)
		log.Info().Str("type", t.name).Int("count", count).Msg("Completed")
		totalComments += count
	}

	log.Info().Int("total", totalComments).Msg("Fetch complete")
}

func initDatabase() (*sql.DB, error) {
	db, err := sql.Open("sqlite3", dbFile)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	schema := `
	CREATE TABLE IF NOT EXISTS comments (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		comment_id TEXT NOT NULL UNIQUE,
		comment_type TEXT NOT NULL,
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL,
		body TEXT NOT NULL,
		body_text TEXT,
		repo_full_name TEXT NOT NULL,
		repo_owner TEXT NOT NULL,
		repo_owner_type TEXT NOT NULL,
		issue_number INTEGER,
		issue_title TEXT,
		is_pull_request BOOLEAN,
		commit_oid TEXT,
		discussion_title TEXT,
		gist_id TEXT,
		html_url TEXT NOT NULL,
		fetched_at TEXT NOT NULL,
		is_own_org BOOLEAN NOT NULL DEFAULT 0
	);

	CREATE INDEX IF NOT EXISTS idx_comment_id ON comments(comment_id);
	CREATE INDEX IF NOT EXISTS idx_comment_type ON comments(comment_type);
	CREATE INDEX IF NOT EXISTS idx_created_at ON comments(created_at);
	CREATE INDEX IF NOT EXISTS idx_updated_at ON comments(updated_at);
	CREATE INDEX IF NOT EXISTS idx_repo_full_name ON comments(repo_full_name);
	CREATE INDEX IF NOT EXISTS idx_is_own_org ON comments(is_own_org);
	CREATE INDEX IF NOT EXISTS idx_owner_type_created ON comments(is_own_org, comment_type, created_at);
	`

	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("failed to create schema: %w", err)
	}

	return db, nil
}

func getGitHubUsername() (string, error) {
	cmd := exec.Command("gh", "api", "user", "--jq", ".login")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to get GitHub username: %w", err)
	}
	return strings.TrimSpace(string(output)), nil
}

func isOwnOrg(owner string) bool {
	for _, org := range ownOrgs {
		if owner == org {
			return true
		}
	}
	return false
}

func saveComment(db *sql.DB, comment CommentRecord) error {
	query := `
	INSERT OR REPLACE INTO comments (
		comment_id, comment_type, created_at, updated_at, body, body_text,
		repo_full_name, repo_owner, repo_owner_type,
		issue_number, issue_title, is_pull_request,
		commit_oid, discussion_title, gist_id,
		html_url, fetched_at, is_own_org
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`

	_, err := db.Exec(query,
		comment.CommentID,
		comment.CommentType,
		comment.CreatedAt.Format(time.RFC3339),
		comment.UpdatedAt.Format(time.RFC3339),
		comment.Body,
		comment.BodyText,
		comment.RepoFullName,
		comment.RepoOwner,
		comment.RepoOwnerType,
		comment.IssueNumber,
		comment.IssueTitle,
		comment.IsPullRequest,
		comment.CommitOID,
		comment.DiscussionTitle,
		comment.GistID,
		comment.HTMLURL,
		time.Now().Format(time.RFC3339),
		comment.IsOwnOrg,
	)

	return err
}

func getLatestUpdate(db *sql.DB, commentType string) (time.Time, error) {
	var updatedAt string
	err := db.QueryRow(
		"SELECT MAX(updated_at) FROM comments WHERE comment_type = ?",
		commentType,
	).Scan(&updatedAt)

	if err == sql.ErrNoRows || updatedAt == "" {
		return time.Time{}, nil
	}
	if err != nil {
		return time.Time{}, err
	}

	return time.Parse(time.RFC3339, updatedAt)
}

func getCommentCount(db *sql.DB, commentType string) (int, error) {
	var count int
	err := db.QueryRow(
		"SELECT COUNT(*) FROM comments WHERE comment_type = ?",
		commentType,
	).Scan(&count)
	return count, err
}

func fetchIssueComments(db *sql.DB, username string) error {
	lastUpdate, err := getLatestUpdate(db, "issue")
	if err != nil {
		log.Warn().Err(err).Msg("Failed to get latest update, fetching all")
	}

	query := `
	query($login: String!, $cursor: String) {
		user(login: $login) {
			issueComments(first: 100, after: $cursor, orderBy: {field: UPDATED_AT, direction: ASC}) {
				totalCount
				pageInfo {
					hasNextPage
					endCursor
				}
				nodes {
					id
					createdAt
					updatedAt
					body
					bodyText
					url
					repository {
						nameWithOwner
						owner {
							login
							__typename
						}
					}
					issue {
						number
						title
					}
				}
			}
		}
	}
	`

	var cursor *string
	page := 0
	savedCount := 0

	for {
		page++
		log.Debug().Int("page", page).Msg("Fetching issue comments page")

		variables := map[string]interface{}{
			"login": username,
		}
		if cursor != nil {
			variables["cursor"] = *cursor
		}

		result, err := executeGraphQL(query, variables)
		if err != nil {
			return fmt.Errorf("GraphQL query failed: %w", err)
		}

		// Parse response
		var response struct {
			Data struct {
				User struct {
					IssueComments struct {
						TotalCount int
						PageInfo   struct {
							HasNextPage bool
							EndCursor   string
						}
						Nodes []struct {
							ID        string
							CreatedAt string
							UpdatedAt string
							Body      string
							BodyText  string
							URL       string
							Repository struct {
								NameWithOwner string
								Owner struct {
									Login    string
									Typename string `json:"__typename"`
								}
							}
							Issue struct {
								Number int
								Title  string
							}
						}
					}
				}
			}
		}

		if err := json.Unmarshal(result, &response); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		// Process comments
		for _, node := range response.Data.User.IssueComments.Nodes {
			// Skip comments without repository access (SAML-protected orgs)
			if node.Repository.NameWithOwner == "" {
				continue
			}

			createdAt, err := time.Parse(time.RFC3339, node.CreatedAt)
			if err != nil {
				log.Warn().Err(err).Str("comment_id", node.ID).Msg("Invalid createdAt timestamp")
				continue
			}
			updatedAt, err := time.Parse(time.RFC3339, node.UpdatedAt)
			if err != nil {
				log.Warn().Err(err).Str("comment_id", node.ID).Msg("Invalid updatedAt timestamp")
				continue
			}

			// Skip if not updated since last fetch
			if !lastUpdate.IsZero() && !updatedAt.After(lastUpdate) {
				continue
			}

			// Determine if it's a PR (check URL pattern)
			isPR := strings.Contains(node.URL, "/pull/")

			comment := CommentRecord{
				CommentID:     node.ID,
				CommentType:   "issue",
				CreatedAt:     createdAt,
				UpdatedAt:     updatedAt,
				Body:          node.Body,
				BodyText:      node.BodyText,
				RepoFullName:  node.Repository.NameWithOwner,
				RepoOwner:     node.Repository.Owner.Login,
				RepoOwnerType: node.Repository.Owner.Typename,
				IssueNumber:   &node.Issue.Number,
				IssueTitle:    &node.Issue.Title,
				IsPullRequest: &isPR,
				HTMLURL:       node.URL,
				IsOwnOrg:      isOwnOrg(node.Repository.Owner.Login),
			}

			if err := saveComment(db, comment); err != nil {
				log.Error().Err(err).Str("comment_id", node.ID).Msg("Failed to save comment")
				continue
			}
			savedCount++
		}

		// Check for next page
		if !response.Data.User.IssueComments.PageInfo.HasNextPage {
			break
		}
		cursor = &response.Data.User.IssueComments.PageInfo.EndCursor
	}

	log.Info().Int("saved", savedCount).Msg("Issue comments saved")
	return nil
}

func fetchCommitComments(db *sql.DB, username string) error {
	lastUpdate, err := getLatestUpdate(db, "commit")
	if err != nil {
		log.Warn().Err(err).Msg("Failed to get latest update, fetching all")
	}

	query := `
	query($login: String!, $cursor: String) {
		user(login: $login) {
			commitComments(first: 100, after: $cursor) {
				totalCount
				pageInfo {
					hasNextPage
					endCursor
				}
				nodes {
					id
					createdAt
					updatedAt
					body
					bodyText
					url
					commit {
						oid
					}
					repository {
						nameWithOwner
						owner {
							login
							__typename
						}
					}
				}
			}
		}
	}
	`

	var cursor *string
	page := 0
	savedCount := 0

	for {
		page++
		log.Debug().Int("page", page).Msg("Fetching commit comments page")

		variables := map[string]interface{}{
			"login": username,
		}
		if cursor != nil {
			variables["cursor"] = *cursor
		}

		result, err := executeGraphQL(query, variables)
		if err != nil {
			return fmt.Errorf("GraphQL query failed: %w", err)
		}

		var response struct {
			Data struct {
				User struct {
					CommitComments struct {
						TotalCount int
						PageInfo   struct {
							HasNextPage bool
							EndCursor   string
						}
						Nodes []struct {
							ID        string
							CreatedAt string
							UpdatedAt string
							Body      string
							BodyText  string
							URL       string
							Commit    struct {
								OID string
							}
							Repository struct {
								NameWithOwner string
								Owner struct {
									Login    string
									Typename string `json:"__typename"`
								}
							}
						}
					}
				}
			}
		}

		if err := json.Unmarshal(result, &response); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		for _, node := range response.Data.User.CommitComments.Nodes {
			// Skip comments without repository access (SAML-protected orgs)
			if node.Repository.NameWithOwner == "" {
				continue
			}

			createdAt, err := time.Parse(time.RFC3339, node.CreatedAt)
			if err != nil {
				log.Warn().Err(err).Str("comment_id", node.ID).Msg("Invalid createdAt timestamp")
				continue
			}
			updatedAt, err := time.Parse(time.RFC3339, node.UpdatedAt)
			if err != nil {
				log.Warn().Err(err).Str("comment_id", node.ID).Msg("Invalid updatedAt timestamp")
				continue
			}

			if !lastUpdate.IsZero() && !updatedAt.After(lastUpdate) {
				continue
			}

			comment := CommentRecord{
				CommentID:     node.ID,
				CommentType:   "commit",
				CreatedAt:     createdAt,
				UpdatedAt:     updatedAt,
				Body:          node.Body,
				BodyText:      node.BodyText,
				RepoFullName:  node.Repository.NameWithOwner,
				RepoOwner:     node.Repository.Owner.Login,
				RepoOwnerType: node.Repository.Owner.Typename,
				CommitOID:     &node.Commit.OID,
				HTMLURL:       node.URL,
				IsOwnOrg:      isOwnOrg(node.Repository.Owner.Login),
			}

			if err := saveComment(db, comment); err != nil {
				log.Error().Err(err).Str("comment_id", node.ID).Msg("Failed to save comment")
				continue
			}
			savedCount++
		}

		if !response.Data.User.CommitComments.PageInfo.HasNextPage {
			break
		}
		cursor = &response.Data.User.CommitComments.PageInfo.EndCursor
	}

	log.Info().Int("saved", savedCount).Msg("Commit comments saved")
	return nil
}

func fetchDiscussionComments(db *sql.DB, username string) error {
	lastUpdate, err := getLatestUpdate(db, "discussion")
	if err != nil {
		log.Warn().Err(err).Msg("Failed to get latest update, fetching all")
	}

	query := `
	query($login: String!, $cursor: String) {
		user(login: $login) {
			repositoryDiscussionComments(first: 100, after: $cursor) {
				totalCount
				pageInfo {
					hasNextPage
					endCursor
				}
				nodes {
					id
					createdAt
					updatedAt
					body
					bodyText
					url
					discussion {
						title
						repository {
							nameWithOwner
							owner {
								login
								__typename
							}
						}
					}
				}
			}
		}
	}
	`

	var cursor *string
	page := 0
	savedCount := 0

	for {
		page++
		log.Debug().Int("page", page).Msg("Fetching discussion comments page")

		variables := map[string]interface{}{
			"login": username,
		}
		if cursor != nil {
			variables["cursor"] = *cursor
		}

		result, err := executeGraphQL(query, variables)
		if err != nil {
			return fmt.Errorf("GraphQL query failed: %w", err)
		}

		var response struct {
			Data struct {
				User struct {
					RepositoryDiscussionComments struct {
						TotalCount int
						PageInfo   struct {
							HasNextPage bool
							EndCursor   string
						}
						Nodes []struct {
							ID        string
							CreatedAt string
							UpdatedAt string
							Body      string
							BodyText  string
							URL       string
							Discussion struct {
								Title      string
								Repository struct {
									NameWithOwner string
									Owner struct {
										Login    string
										Typename string `json:"__typename"`
									}
								}
							}
						}
					}
				}
			}
		}

		if err := json.Unmarshal(result, &response); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		for _, node := range response.Data.User.RepositoryDiscussionComments.Nodes {
			// Skip comments without repository access (SAML-protected orgs)
			if node.Discussion.Repository.NameWithOwner == "" {
				continue
			}

			createdAt, err := time.Parse(time.RFC3339, node.CreatedAt)
			if err != nil {
				log.Warn().Err(err).Str("comment_id", node.ID).Msg("Invalid createdAt timestamp")
				continue
			}
			updatedAt, err := time.Parse(time.RFC3339, node.UpdatedAt)
			if err != nil {
				log.Warn().Err(err).Str("comment_id", node.ID).Msg("Invalid updatedAt timestamp")
				continue
			}

			if !lastUpdate.IsZero() && !updatedAt.After(lastUpdate) {
				continue
			}

			comment := CommentRecord{
				CommentID:       node.ID,
				CommentType:     "discussion",
				CreatedAt:       createdAt,
				UpdatedAt:       updatedAt,
				Body:            node.Body,
				BodyText:        node.BodyText,
				RepoFullName:    node.Discussion.Repository.NameWithOwner,
				RepoOwner:       node.Discussion.Repository.Owner.Login,
				RepoOwnerType:   node.Discussion.Repository.Owner.Typename,
				DiscussionTitle: &node.Discussion.Title,
				HTMLURL:         node.URL,
				IsOwnOrg:        isOwnOrg(node.Discussion.Repository.Owner.Login),
			}

			if err := saveComment(db, comment); err != nil {
				log.Error().Err(err).Str("comment_id", node.ID).Msg("Failed to save comment")
				continue
			}
			savedCount++
		}

		if !response.Data.User.RepositoryDiscussionComments.PageInfo.HasNextPage {
			break
		}
		cursor = &response.Data.User.RepositoryDiscussionComments.PageInfo.EndCursor
	}

	log.Info().Int("saved", savedCount).Msg("Discussion comments saved")
	return nil
}

func fetchGistComments(db *sql.DB, username string) error {
	lastUpdate, err := getLatestUpdate(db, "gist")
	if err != nil {
		log.Warn().Err(err).Msg("Failed to get latest update, fetching all")
	}

	query := `
	query($login: String!, $cursor: String) {
		user(login: $login) {
			gistComments(first: 100, after: $cursor) {
				totalCount
				pageInfo {
					hasNextPage
					endCursor
				}
				nodes {
					id
					createdAt
					updatedAt
					body
					bodyText
					gist {
						id
						name
						owner {
							login
							__typename
						}
					}
				}
			}
		}
	}
	`

	var cursor *string
	page := 0
	savedCount := 0

	for {
		page++
		log.Debug().Int("page", page).Msg("Fetching gist comments page")

		variables := map[string]interface{}{
			"login": username,
		}
		if cursor != nil {
			variables["cursor"] = *cursor
		}

		result, err := executeGraphQL(query, variables)
		if err != nil {
			return fmt.Errorf("GraphQL query failed: %w", err)
		}

		var response struct {
			Data struct {
				User struct {
					GistComments struct {
						TotalCount int
						PageInfo   struct {
							HasNextPage bool
							EndCursor   string
						}
						Nodes []struct {
							ID        string
							CreatedAt string
							UpdatedAt string
							Body      string
							BodyText  string
							Gist      struct {
								ID    string
								Name  string
								Owner struct {
									Login    string
									Typename string `json:"__typename"`
								}
							}
						}
					}
				}
			}
		}

		if err := json.Unmarshal(result, &response); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		for _, node := range response.Data.User.GistComments.Nodes {
			createdAt, err := time.Parse(time.RFC3339, node.CreatedAt)
			if err != nil {
				log.Warn().Err(err).Str("comment_id", node.ID).Msg("Invalid createdAt timestamp")
				continue
			}
			updatedAt, err := time.Parse(time.RFC3339, node.UpdatedAt)
			if err != nil {
				log.Warn().Err(err).Str("comment_id", node.ID).Msg("Invalid updatedAt timestamp")
				continue
			}

			if !lastUpdate.IsZero() && !updatedAt.After(lastUpdate) {
				continue
			}

			// Gists don't have a "nameWithOwner" concept, use owner/gist_name or owner/gist_id
			repoFullName := fmt.Sprintf("%s/%s", node.Gist.Owner.Login, node.Gist.Name)
			if node.Gist.Name == "" {
				repoFullName = fmt.Sprintf("%s/%s", node.Gist.Owner.Login, node.Gist.ID)
			}

			// Construct gist URL (links to gist page, not specific comment)
			// Note: GitHub GraphQL API doesn't provide direct comment URLs for gists
			gistURL := fmt.Sprintf("https://gist.github.com/%s/%s", node.Gist.Owner.Login, node.Gist.ID)

			comment := CommentRecord{
				CommentID:     node.ID,
				CommentType:   "gist",
				CreatedAt:     createdAt,
				UpdatedAt:     updatedAt,
				Body:          node.Body,
				BodyText:      node.BodyText,
				RepoFullName:  repoFullName,
				RepoOwner:     node.Gist.Owner.Login,
				RepoOwnerType: node.Gist.Owner.Typename,
				GistID:        &node.Gist.ID,
				HTMLURL:       gistURL,
				IsOwnOrg:      isOwnOrg(node.Gist.Owner.Login),
			}

			if err := saveComment(db, comment); err != nil {
				log.Error().Err(err).Str("comment_id", node.ID).Msg("Failed to save comment")
				continue
			}
			savedCount++
		}

		if !response.Data.User.GistComments.PageInfo.HasNextPage {
			break
		}
		cursor = &response.Data.User.GistComments.PageInfo.EndCursor
	}

	log.Info().Int("saved", savedCount).Msg("Gist comments saved")
	return nil
}

func executeGraphQL(query string, variables map[string]interface{}) ([]byte, error) {
	args := []string{"api", "graphql", "-f", fmt.Sprintf("query=%s", query)}

	// Add variables as individual field arguments
	for key, value := range variables {
		args = append(args, "-F", fmt.Sprintf("%s=%v", key, value))
	}

	cmd := exec.Command("gh", args...)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("gh api failed: %s", string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("failed to execute gh api: %w", err)
	}

	return output, nil
}
