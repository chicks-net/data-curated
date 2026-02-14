package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type ContributorRank struct {
	Login             string `json:"login"`
	Email             string `json:"email"`
	CumulativeCommits int    `json:"cumulative_commits"`
	CommitsToday      int    `json:"commits_today"`
	Rank              int    `json:"rank"`
}

type DailyStats struct {
	Date         string            `json:"date"`
	Contributors []ContributorRank `json:"contributors"`
}

type tickMsg time.Time

type model struct {
	dailyStats     []DailyStats
	currentIndex   int
	topN           int
	barWidth       int
	nameWidth      int
	displayRows    int
	termWidth      int
	termHeight     int
	paused         bool
	done           bool
	speed          time.Duration
	progressStyle  lipgloss.Style
	barStyle       lipgloss.Style
	nameStyle      lipgloss.Style
	highlightStyle lipgloss.Style
	countStyle     lipgloss.Style
	headerStyle    lipgloss.Style
	dateStyle      lipgloss.Style
	highlightRegex *regexp.Regexp
}

func initialModel(stats []DailyStats, topN int, speed time.Duration) model {
	for i := range stats {
		sort.Slice(stats[i].Contributors, func(j, k int) bool {
			return stats[i].Contributors[j].CumulativeCommits > stats[i].Contributors[k].CumulativeCommits
		})
	}

	m := model{
		dailyStats:     stats,
		currentIndex:   0,
		topN:           topN,
		barWidth:       40,
		nameWidth:      20,
		displayRows:    10,
		termWidth:      80,
		termHeight:     24,
		paused:         false,
		done:           false,
		speed:          speed,
		progressStyle:  lipgloss.NewStyle().Foreground(lipgloss.Color("36")),
		barStyle:       lipgloss.NewStyle().Foreground(lipgloss.Color("82")),
		nameStyle:      lipgloss.NewStyle().Foreground(lipgloss.Color("15")),
		highlightStyle: lipgloss.NewStyle().Foreground(lipgloss.Color("165")),
		countStyle:     lipgloss.NewStyle().Foreground(lipgloss.Color("226")),
		headerStyle:    lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("86")),
		dateStyle:      lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("213")),
		highlightRegex: regexp.MustCompile(`[CT]h`),
	}
	m.calculateLayout()
	return m
}

func (m *model) calculateLayout() {
	// Reserve space for:
	// - Rank number: 4 chars (" 1. ")
	// - Bar separator: 1 char ("│")
	// - Bar + space + count + today marker: ~20 chars minimum
	// - Progress bar at bottom: 60 chars
	// Available for name: width - 4 - 1 - 20 - some padding

	reserved := 30
	availableForName := m.termWidth - reserved

	m.nameWidth = 20
	if availableForName > 20 {
		m.nameWidth = availableForName
		if m.nameWidth > 40 {
			m.nameWidth = 40
		}
	} else if availableForName < 10 {
		m.nameWidth = 10
	}

	barAvailable := m.termWidth - 4 - m.nameWidth - 15
	m.barWidth = 40
	if barAvailable > 20 && barAvailable < 60 {
		m.barWidth = barAvailable
	} else if barAvailable >= 60 {
		m.barWidth = 60
	}

	// Reserve vertical space for:
	// - Header: 2 lines (title + blank)
	// - Date line: 1 line
	// - Status line: 1 line + blank = 2 lines
	// - "Top Contributors" header: 2 lines
	// - Progress bar section: 4 lines (blank + bar + blank + controls)
	// Total reserved: ~11 lines
	headerLines := 11
	availableRows := m.termHeight - headerLines
	if availableRows < 3 {
		availableRows = 3
	}
	m.displayRows = availableRows
}

func (m model) Init() tea.Cmd {
	return tea.Tick(m.speed, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case " ":
			m.paused = !m.paused
		case "right", "l":
			if m.currentIndex < len(m.dailyStats)-1 {
				m.currentIndex++
			}
		case "left", "h":
			if m.currentIndex > 0 {
				m.currentIndex--
			}
		case "r":
			m.currentIndex = 0
		case "up", "k":
			if m.speed > 100*time.Millisecond {
				m.speed -= 100 * time.Millisecond
			}
		case "down", "j":
			m.speed += 100 * time.Millisecond
		}
	case tickMsg:
		if !m.paused && m.currentIndex < len(m.dailyStats)-1 {
			m.currentIndex++
		}
		if m.currentIndex >= len(m.dailyStats)-1 {
			m.done = true
		}
		return m, tea.Tick(m.speed, func(t time.Time) tea.Msg {
			return tickMsg(t)
		})
	case tea.WindowSizeMsg:
		m.termWidth = msg.Width
		m.termHeight = msg.Height
		m.calculateLayout()
	}
	return m, nil
}

func (m model) View() string {
	if len(m.dailyStats) == 0 {
		return "No data to display\n"
	}

	var b strings.Builder

	stats := m.dailyStats[m.currentIndex]
	contributors := stats.Contributors

	displayCount := m.displayRows
	if m.topN > 0 && displayCount > m.topN {
		displayCount = m.topN
	}
	if len(contributors) > displayCount {
		contributors = contributors[:displayCount]
	}

	maxCommits := 1
	if len(contributors) > 0 {
		maxCommits = contributors[0].CumulativeCommits
	}

	progress := float64(m.currentIndex+1) / float64(len(m.dailyStats)) * 100
	progressBar := m.renderProgressBar(progress)

	b.WriteString(m.headerStyle.Render("Daily Contributor Rankings"))
	b.WriteString("\n\n")

	b.WriteString(m.dateStyle.Render(fmt.Sprintf("Date: %s", stats.Date)))
	b.WriteString("\n")

	speedStr := fmt.Sprintf("%.1fs", m.speed.Seconds())
	pauseStr := "Playing"
	if m.paused {
		pauseStr = "Paused"
	}
	b.WriteString(fmt.Sprintf("%s | Speed: %s | Day %d/%d\n\n",
		m.progressStyle.Render(pauseStr),
		m.progressStyle.Render(speedStr),
		m.currentIndex+1,
		len(m.dailyStats),
	))

	b.WriteString(m.headerStyle.Render("Top Contributors"))
	b.WriteString("\n\n")

	for i, c := range contributors {
		barLength := 0
		if maxCommits > 0 {
			barLength = int(float64(c.CumulativeCommits) / float64(maxCommits) * float64(m.barWidth))
		}
		if barLength < 1 && c.CumulativeCommits > 0 {
			barLength = 1
		}

		bar := strings.Repeat("█", barLength)
		bar = m.barStyle.Render(bar)

		todayStr := ""
		if c.CommitsToday > 0 {
			todayStr = m.progressStyle.Render(fmt.Sprintf(" (+%d today)", c.CommitsToday))
		}

		line := fmt.Sprintf("%2d. %s │%s %s%s\n",
			i+1,
			m.renderName(c.Login),
			bar,
			m.countStyle.Render(fmt.Sprintf("%d", c.CumulativeCommits)),
			todayStr,
		)
		b.WriteString(line)
	}

	b.WriteString("\n")
	b.WriteString(progressBar)
	b.WriteString("\n\n")
	b.WriteString(m.progressStyle.Render("Controls: [space] pause/play │ [h/l] prev/next │ [j/k] speed │ [r] restart │ [q] quit"))

	return b.String()
}

func (m model) renderProgressBar(progress float64) string {
	width := 60
	filled := int(progress / 100 * float64(width))

	bar := strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
	return fmt.Sprintf("[%s] %.0f%%", m.barStyle.Render(bar), progress)
}

func (m model) renderName(name string) string {
	if m.highlightRegex.MatchString(name) {
		return m.highlightStyle.Width(m.nameWidth).Render(name)
	}
	return m.nameStyle.Width(m.nameWidth).Render(name)
}

func readDailyStats(input string) ([]DailyStats, error) {
	var stats []DailyStats

	var scanner *bufio.Scanner
	if input == "-" || input == "" {
		scanner = bufio.NewScanner(os.Stdin)
	} else {
		file, err := os.Open(input)
		if err != nil {
			return nil, fmt.Errorf("failed to open file: %w", err)
		}
		defer file.Close()
		scanner = bufio.NewScanner(file)
	}

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var day DailyStats
		if err := json.Unmarshal([]byte(line), &day); err != nil {
			return nil, fmt.Errorf("failed to parse JSON line: %w", err)
		}
		stats = append(stats, day)
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scanner error: %w", err)
	}

	return stats, nil
}

func main() {
	topN := flag.Int("n", 100, "maximum number of contributors to display (default fits terminal height)")
	speed := flag.Duration("speed", 500*time.Millisecond, "animation speed (e.g., 500ms, 1s)")
	flag.Parse()

	args := flag.Args()
	input := ""
	if len(args) > 0 {
		input = args[0]
	}

	stats, err := readDailyStats(input)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading input: %v\n", err)
		os.Exit(1)
	}

	if len(stats) == 0 {
		fmt.Fprintf(os.Stderr, "No daily stats found in input\n")
		os.Exit(1)
	}

	p := tea.NewProgram(
		initialModel(stats, *topN, *speed),
		tea.WithAltScreen(),
	)

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error running program: %v\n", err)
		os.Exit(1)
	}
}
