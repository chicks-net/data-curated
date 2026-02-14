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
	CumulativeCommits int    `json:"cumulative_commits"`
	CommitsToday      int    `json:"commits_today"`
	Rank              int    `json:"rank"`
}

type UnionFind struct {
	parent map[int]int
	rank   map[int]int
}

func NewUnionFind() *UnionFind {
	return &UnionFind{
		parent: make(map[int]int),
		rank:   make(map[int]int),
	}
}

func (uf *UnionFind) Find(x int) int {
	if _, exists := uf.parent[x]; !exists {
		uf.parent[x] = x
		uf.rank[x] = 0
	}
	if uf.parent[x] != x {
		uf.parent[x] = uf.Find(uf.parent[x])
	}
	return uf.parent[x]
}

func (uf *UnionFind) Union(x, y int) {
	rootX := uf.Find(x)
	rootY := uf.Find(y)
	if rootX == rootY {
		return
	}
	if uf.rank[rootX] < uf.rank[rootY] {
		uf.parent[rootX] = rootY
	} else if uf.rank[rootX] > uf.rank[rootY] {
		uf.parent[rootY] = rootX
	} else {
		uf.parent[rootY] = rootX
		uf.rank[rootX]++
	}
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

	uf := NewUnionFind()
	nameToID := make(map[string]int)
	emailToID := make(map[string]int)
	nextID := 0

	for _, c := range commits {
		nameID, nameExists := nameToID[c.Author]
		if !nameExists {
			nameID = nextID
			nameToID[c.Author] = nameID
			nextID++
		}

		emailLower := strings.ToLower(c.Email)
		emailID, emailExists := emailToID[emailLower]
		if !emailExists {
			emailID = nextID
			emailToID[emailLower] = emailID
			nextID++
		}

		uf.Union(nameID, emailID)
	}

	commitToPerson := make([]int, len(commits))
	for i, c := range commits {
		nameID := nameToID[c.Author]
		commitToPerson[i] = uf.Find(nameID)
	}

	latestNameForPerson := make(map[int]string)
	latestDateForPerson := make(map[int]time.Time)
	for i, c := range commits {
		root := commitToPerson[i]
		if existing, ok := latestDateForPerson[root]; !ok || c.Date.After(existing) {
			latestDateForPerson[root] = c.Date
			latestNameForPerson[root] = c.Author
		}
	}

	personCommitsDaily := make(map[int]map[string]int)
	for i, c := range commits {
		root := commitToPerson[i]
		dateKey := c.Date.Format("2006-01-02")
		if personCommitsDaily[root] == nil {
			personCommitsDaily[root] = make(map[string]int)
		}
		personCommitsDaily[root][dateKey]++
	}

	uniqueDates := make([]string, 0, len(commits))
	seenDates := make(map[string]bool)
	for _, c := range commits {
		dateKey := c.Date.Format("2006-01-02")
		if !seenDates[dateKey] {
			seenDates[dateKey] = true
			uniqueDates = append(uniqueDates, dateKey)
		}
	}
	sort.Strings(uniqueDates)

	runningTotals := make(map[int]int)
	todayCommits := make(map[int]int)
	var results []DailyStats

	for _, date := range uniqueDates {
		todayCommits = make(map[int]int)
		for person, dailyMap := range personCommitsDaily {
			if count, ok := dailyMap[date]; ok {
				runningTotals[person] += count
				todayCommits[person] = count
			}
		}

		type ranked struct {
			person  int
			login   string
			commits int
			today   int
		}

		var rankedList []ranked
		for person, total := range runningTotals {
			rankedList = append(rankedList, ranked{
				person:  person,
				login:   latestNameForPerson[person],
				commits: total,
				today:   todayCommits[person],
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
