package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

type Commit struct {
	Hash    string
	Author  string
	Email   string
	Date    time.Time
	Subject string
}

type DailyStats struct {
	Date         string            `json:"date"`
	Origin       string            `json:"origin"`
	Contributors []ContributorRank `json:"contributors"`
}

type ContributorRank struct {
	Login             string `json:"login"`
	Email             string `json:"email"`
	CumulativeCommits int    `json:"cumulative_commits"`
	CommitsToday      int    `json:"commits_today"`
	Rank              int    `json:"rank"`
}

type ContributorCumulative struct {
	Login   string
	Email   string
	Commits int
}

func main() {
	zerolog.TimestampFunc = func() time.Time {
		return time.Now().UTC()
	}

	if os.Getenv("JSON_LOGS") == "true" {
		zerolog.TimeFieldFormat = time.RFC3339
		log.Logger = zerolog.New(os.Stdout).With().Timestamp().Caller().Logger()
	} else {
		output := zerolog.ConsoleWriter{
			Out:        os.Stdout,
			TimeFormat: time.RFC3339,
		}
		log.Logger = log.Output(output)
	}

	if len(os.Args) < 2 {
		log.Fatal().Msg("Usage: daily-ranking <git-repo-directory>")
	}

	repoPath := os.Args[1]
	absPath, err := filepath.Abs(repoPath)
	if err != nil {
		log.Fatal().Err(err).Str("path", repoPath).Msg("Failed to resolve absolute path")
	}

	gitDir := filepath.Join(absPath, ".git")
	if _, err := os.Stat(gitDir); os.IsNotExist(err) {
		if _, err := os.Stat(absPath); os.IsNotExist(err) {
			log.Fatal().Str("path", absPath).Msg("Directory does not exist")
		}
		log.Fatal().Str("path", absPath).Msg("Not a git repository (no .git directory found)")
	}

	log.Info().Str("repo", absPath).Msg("Processing git repository")

	commits, err := fetchCommits(absPath)
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to fetch commits")
	}

	log.Info().Int("commits", len(commits)).Msg("Retrieved commits")

	origin, err := getOriginURL(absPath)
	if err != nil {
		log.Warn().Err(err).Msg("Failed to get origin URL, using empty string")
		origin = ""
	}

	dailyRankings := computeDailyRankings(commits, origin)

	if len(os.Args) >= 3 {
		if err := writeJSON(os.Args[2], dailyRankings); err != nil {
			log.Fatal().Err(err).Msg("Failed to write output file")
		}
		log.Info().Str("file", os.Args[2]).Int("days", len(dailyRankings)).Msg("Wrote daily rankings")
	} else {
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetEscapeHTML(false)
		for _, day := range dailyRankings {
			if err := encoder.Encode(day); err != nil {
				log.Fatal().Err(err).Msg("Failed to write JSON output")
			}
		}
	}
}

func fetchCommits(repoPath string) ([]Commit, error) {
	cmd := exec.Command("git", "-C", repoPath, "log",
		"--all",
		"--format=%H%x00%an%x00%ae%x00%aI%x00%s",
		"--date-order",
	)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("git log failed: %w (stderr: %s)", err, string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("git log failed: %w", err)
	}

	var commits []Commit
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}

		parts := strings.Split(line, "\x00")
		if len(parts) < 5 {
			log.Debug().Str("line", line).Msg("Skipping malformed line")
			continue
		}

		date, err := time.Parse(time.RFC3339, parts[3])
		if err != nil {
			log.Debug().Str("date", parts[3]).Err(err).Msg("Failed to parse date, skipping commit")
			continue
		}

		commits = append(commits, Commit{
			Hash:    parts[0],
			Author:  parts[1],
			Email:   parts[2],
			Date:    date,
			Subject: parts[4],
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scanner error: %w", err)
	}

	sort.Slice(commits, func(i, j int) bool {
		return commits[i].Date.Before(commits[j].Date)
	})

	return commits, nil
}

func getOriginURL(repoPath string) (string, error) {
	cmd := exec.Command("git", "-C", repoPath, "remote", "get-url", "origin")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to get origin URL: %w", err)
	}
	return strings.TrimSpace(string(output)), nil
}

func computeDailyRankings(commits []Commit, origin string) []DailyStats {
	if len(commits) == 0 {
		return nil
	}

	contributorTotals := make(map[string]*ContributorCumulative)
	dailyCommits := make(map[string]map[string]int)

	for _, c := range commits {
		dateKey := c.Date.Format("2006-01-02")
		key := c.Email

		if dailyCommits[dateKey] == nil {
			dailyCommits[dateKey] = make(map[string]int)
		}
		dailyCommits[dateKey][key]++

		if contributorTotals[key] == nil {
			contributorTotals[key] = &ContributorCumulative{
				Login: c.Author,
				Email: c.Email,
			}
		}
		contributorTotals[key].Commits++
	}

	uniqueDates := make([]string, 0, len(dailyCommits))
	for date := range dailyCommits {
		uniqueDates = append(uniqueDates, date)
	}
	sort.Strings(uniqueDates)

	runningTotals := make(map[string]int)
	var results []DailyStats

	for _, date := range uniqueDates {
		for email, count := range dailyCommits[date] {
			runningTotals[email] += count
		}

		type ranked struct {
			email   string
			login   string
			commits int
			today   int
		}

		var rankedList []ranked
		for email, total := range runningTotals {
			rankedList = append(rankedList, ranked{
				email:   email,
				login:   contributorTotals[email].Login,
				commits: total,
				today:   dailyCommits[date][email],
			})
		}

		sort.Slice(rankedList, func(i, j int) bool {
			if rankedList[i].commits != rankedList[j].commits {
				return rankedList[i].commits > rankedList[j].commits
			}
			return rankedList[i].login < rankedList[j].login
		})

		var contributorRanks []ContributorRank
		for i, r := range rankedList {
			contributorRanks = append(contributorRanks, ContributorRank{
				Login:             r.login,
				Email:             r.email,
				CumulativeCommits: r.commits,
				CommitsToday:      r.today,
				Rank:              i + 1,
			})
		}

		results = append(results, DailyStats{
			Date:         date,
			Origin:       origin,
			Contributors: contributorRanks,
		})
	}

	return results
}

func writeJSON(filename string, rankings []DailyStats) error {
	file, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("failed to create file: %w", err)
	}
	defer file.Close()

	encoder := json.NewEncoder(file)
	encoder.SetEscapeHTML(false)

	for _, day := range rankings {
		data, err := json.Marshal(day)
		if err != nil {
			return fmt.Errorf("failed to marshal: %w", err)
		}
		if _, err := file.Write(data); err != nil {
			return fmt.Errorf("failed to write: %w", err)
		}
		if _, err := file.WriteString("\n"); err != nil {
			return fmt.Errorf("failed to write newline: %w", err)
		}
	}

	return nil
}
