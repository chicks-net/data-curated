package main

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

const (
	DateFormatFile = "20060102"
	EnvJSONLogs    = "JSON_LOGS"
	EnvJSONLogsVal = "true"
)

// ContributorStats represents a contributor's statistics from the GitHub API
type ContributorStats struct {
	Author struct {
		Login             string `json:"login"`
		ID                int    `json:"id"`
		AvatarURL         string `json:"avatar_url"`
		GravatarID        string `json:"gravatar_id"`
		Type              string `json:"type"`
		SiteAdmin         bool   `json:"site_admin"`
	} `json:"author"`
	Total int `json:"total"`
	Weeks []struct {
		Week      int64 `json:"w"`
		Additions int   `json:"a"`
		Deletions int   `json:"d"`
		Commits   int   `json:"c"`
	} `json:"weeks"`
}

// EnrichedContributor holds contributor data with calculated totals and rankings
type EnrichedContributor struct {
	Login          string
	UserID         int
	AvatarURL      string
	Type           string
	SiteAdmin      bool
	TotalCommits   int
	TotalAdditions int
	TotalDeletions int
	WeeksActive    int
	RankByCommits  int
	RankByAdditions int
	RankByDeletions int
}

func main() {
	// Configure logging
	zerolog.TimestampFunc = func() time.Time {
		return time.Now().UTC()
	}

	if os.Getenv(EnvJSONLogs) == EnvJSONLogsVal {
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

	log.Info().Msg("Starting GitHub contributor data fetcher")

	// Check for repository argument
	if len(os.Args) < 2 {
		log.Fatal().Msg("Usage: contributor-fetcher <owner/repo>")
	}

	repo := os.Args[1]
	log.Info().Str("repository", repo).Msg("Fetching contributor data")

	// Validate repo format
	parts := strings.Split(repo, "/")
	if len(parts) != 2 {
		log.Fatal().Str("repo", repo).Msg("Invalid repository format. Expected: owner/repo")
	}

	owner := parts[0]
	repoName := parts[1]

	// Fetch contributor stats
	contributors, err := fetchContributors(repo)
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to fetch contributors")
	}

	log.Info().Int("count", len(contributors)).Msg("Retrieved contributors")

	// Enrich contributors with totals and rankings
	enriched := enrichContributors(contributors)

	log.Info().Msg("Calculated rankings")

	// Generate CSV filename
	today := time.Now().UTC().Format(DateFormatFile)
	csvFilename := fmt.Sprintf("%s-%s-contributors-%s.csv", owner, repoName, today)

	// Write CSV file
	if err := writeCSV(csvFilename, enriched); err != nil {
		log.Fatal().Err(err).Msg("Failed to write CSV file")
	}

	log.Info().
		Str("file", csvFilename).
		Int("contributors", len(contributors)).
		Msg("Successfully wrote contributor data to CSV")
}

func fetchContributors(repo string) ([]ContributorStats, error) {
	// Use gh api to fetch contributor stats
	apiURL := fmt.Sprintf("/repos/%s/stats/contributors", repo)

	log.Debug().Str("endpoint", apiURL).Msg("Calling GitHub API")

	cmd := exec.Command("gh", "api", apiURL)
	output, err := cmd.Output()
	if err != nil {
		// Check if it's an ExitError to get stderr
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("gh api failed: %w (stderr: %s)", err, string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("gh api failed: %w", err)
	}

	var contributors []ContributorStats
	if err := json.Unmarshal(output, &contributors); err != nil {
		return nil, fmt.Errorf("failed to parse JSON response: %w", err)
	}

	return contributors, nil
}

func enrichContributors(contributors []ContributorStats) []EnrichedContributor {
	enriched := make([]EnrichedContributor, 0, len(contributors))

	// Calculate totals for each contributor
	for _, contrib := range contributors {
		totalAdditions := 0
		totalDeletions := 0
		weeksActive := 0

		for _, week := range contrib.Weeks {
			totalAdditions += week.Additions
			totalDeletions += week.Deletions
			if week.Commits > 0 {
				weeksActive++
			}
		}

		enriched = append(enriched, EnrichedContributor{
			Login:          contrib.Author.Login,
			UserID:         contrib.Author.ID,
			AvatarURL:      contrib.Author.AvatarURL,
			Type:           contrib.Author.Type,
			SiteAdmin:      contrib.Author.SiteAdmin,
			TotalCommits:   contrib.Total,
			TotalAdditions: totalAdditions,
			TotalDeletions: totalDeletions,
			WeeksActive:    weeksActive,
		})
	}

	// Calculate rankings
	calculateRankings(enriched)

	// Sort by total commits descending (to maintain consistent ordering)
	sort.Slice(enriched, func(i, j int) bool {
		return enriched[i].TotalCommits > enriched[j].TotalCommits
	})

	return enriched
}

func calculateRankings(contributors []EnrichedContributor) {
	// Rank by total commits
	sortedByCommits := make([]EnrichedContributor, len(contributors))
	copy(sortedByCommits, contributors)
	sort.Slice(sortedByCommits, func(i, j int) bool {
		return sortedByCommits[i].TotalCommits > sortedByCommits[j].TotalCommits
	})
	rankMap := make(map[string]int)
	for rank, contrib := range sortedByCommits {
		rankMap[contrib.Login] = rank + 1
	}
	for i := range contributors {
		contributors[i].RankByCommits = rankMap[contributors[i].Login]
	}

	// Rank by total additions
	sortedByAdditions := make([]EnrichedContributor, len(contributors))
	copy(sortedByAdditions, contributors)
	sort.Slice(sortedByAdditions, func(i, j int) bool {
		return sortedByAdditions[i].TotalAdditions > sortedByAdditions[j].TotalAdditions
	})
	rankMap = make(map[string]int)
	for rank, contrib := range sortedByAdditions {
		rankMap[contrib.Login] = rank + 1
	}
	for i := range contributors {
		contributors[i].RankByAdditions = rankMap[contributors[i].Login]
	}

	// Rank by total deletions
	sortedByDeletions := make([]EnrichedContributor, len(contributors))
	copy(sortedByDeletions, contributors)
	sort.Slice(sortedByDeletions, func(i, j int) bool {
		return sortedByDeletions[i].TotalDeletions > sortedByDeletions[j].TotalDeletions
	})
	rankMap = make(map[string]int)
	for rank, contrib := range sortedByDeletions {
		rankMap[contrib.Login] = rank + 1
	}
	for i := range contributors {
		contributors[i].RankByDeletions = rankMap[contributors[i].Login]
	}
}

func writeCSV(filename string, contributors []EnrichedContributor) error {
	file, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("failed to create CSV file: %w", err)
	}
	defer file.Close()

	writer := csv.NewWriter(file)
	defer writer.Flush()

	// Write header
	header := []string{
		"login",
		"user_id",
		"avatar_url",
		"type",
		"site_admin",
		"total_commits",
		"total_additions",
		"total_deletions",
		"weeks_active",
		"rank_by_commits",
		"rank_by_additions",
		"rank_by_deletions",
	}
	if err := writer.Write(header); err != nil {
		return fmt.Errorf("failed to write CSV header: %w", err)
	}

	// Write contributor data
	for _, contrib := range contributors {
		row := []string{
			contrib.Login,
			fmt.Sprintf("%d", contrib.UserID),
			contrib.AvatarURL,
			contrib.Type,
			fmt.Sprintf("%t", contrib.SiteAdmin),
			fmt.Sprintf("%d", contrib.TotalCommits),
			fmt.Sprintf("%d", contrib.TotalAdditions),
			fmt.Sprintf("%d", contrib.TotalDeletions),
			fmt.Sprintf("%d", contrib.WeeksActive),
			fmt.Sprintf("%d", contrib.RankByCommits),
			fmt.Sprintf("%d", contrib.RankByAdditions),
			fmt.Sprintf("%d", contrib.RankByDeletions),
		}

		if err := writer.Write(row); err != nil {
			return fmt.Errorf("failed to write CSV row for %s: %w", contrib.Login, err)
		}

		log.Debug().
			Str("login", contrib.Login).
			Int("commits", contrib.TotalCommits).
			Int("rank", contrib.RankByCommits).
			Msg("Wrote contributor")
	}

	return nil
}
