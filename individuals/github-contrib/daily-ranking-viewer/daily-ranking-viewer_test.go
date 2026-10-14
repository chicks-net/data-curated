package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// ---------------------------------------------------------------------------
// Test fixtures and helpers
// ---------------------------------------------------------------------------

func testStats() []DailyStats {
	return []DailyStats{
		{
			Date:   "2026-01-01",
			Origin: "test-origin",
			Tags:   []string{"v1.0"},
			Contributors: []ContributorRank{
				{Login: "bob", CumulativeCommits: 50, CommitsToday: 2, Rank: 2},
				{Login: "alice", CumulativeCommits: 100, CommitsToday: 5, Rank: 1},
				{Login: "someone", CumulativeCommits: 10, CommitsToday: 0, Rank: 3},
			},
		},
		{
			Date: "2026-01-02",
			Contributors: []ContributorRank{
				{Login: "alice", CumulativeCommits: 105, CommitsToday: 5, Rank: 1},
				{Login: "bob", CumulativeCommits: 52, CommitsToday: 2, Rank: 2},
				{Login: "someone", CumulativeCommits: 10, CommitsToday: 0, Rank: 3},
			},
		},
	}
}

func keyPress(code rune, text string) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: code, Text: text}
}

func ctrlPress(code rune) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: code, Mod: tea.ModCtrl}
}

func update(m model, msg tea.Msg) (model, tea.Cmd) {
	next, cmd := m.Update(msg)
	return next.(model), cmd
}

func tick(m model) (model, tea.Cmd) {
	return update(m, tickMsg(time.Now()))
}

func isQuit(cmd tea.Cmd) bool {
	if cmd == nil {
		return false
	}
	_, ok := cmd().(tea.QuitMsg)
	return ok
}

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

func TestTruncateName(t *testing.T) {
	tests := []struct {
		name   string
		input  string
		maxLen int
		want   string
	}{
		{"shorter than max", "al", 5, "al"},
		{"exactly max", "alice", 5, "alice"},
		{"truncated with ellipsis", "alexander", 5, "al..."},
		{"maxLen of two", "ab", 2, "ab"},
		{"maxLen of three", "abcd", 3, "abc"},
		{"empty name", "", 5, ""},
		{"rune-aware", "héllo wörld", 5, "hé..."},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := truncateName(tt.input, tt.maxLen); got != tt.want {
				t.Errorf("truncateName(%q, %d) = %q, want %q", tt.input, tt.maxLen, got, tt.want)
			}
		})
	}
}

func TestFormatSpeed(t *testing.T) {
	tests := []struct {
		input time.Duration
		want  string
	}{
		{500 * time.Nanosecond, "500ns"},
		{time.Millisecond, "1ms"},
		{100 * time.Millisecond, "100ms"},
		{time.Second, "1.0s"},
		{2500 * time.Millisecond, "2.5s"},
	}
	for _, tt := range tests {
		t.Run(tt.want, func(t *testing.T) {
			if got := formatSpeed(tt.input); got != tt.want {
				t.Errorf("formatSpeed(%v) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestFindSpeedIndex(t *testing.T) {
	tests := []struct {
		input time.Duration
		want  int
	}{
		{time.Millisecond, 0},                    // exact first level
		{3 * time.Millisecond, 1},                // between levels rounds up to next
		{100 * time.Millisecond, 4},              // exact middle level
		{time.Second, 8},                         // exact one-second level
		{10 * time.Second, len(speedLevels) - 1}, // beyond last level clamps
		{0, 0},                                   // zero clamps to first
	}
	for _, tt := range tests {
		t.Run(tt.input.String(), func(t *testing.T) {
			if got := findSpeedIndex(tt.input); got != tt.want {
				t.Errorf("findSpeedIndex(%v) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Input parsing
// ---------------------------------------------------------------------------

func TestReadDailyStatsFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stats.jsonl")
	content := `{"date":"2026-01-01","origin":"o","tags":["t1"],"contributors":[{"login":"a","cumulative_commits":1,"commits_today":1,"rank":1}]}` + "\n\n" +
		`{"date":"2026-01-02","contributors":[]}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	stats, err := readDailyStats(path)
	if err != nil {
		t.Fatalf("readDailyStats() error: %v", err)
	}
	if len(stats) != 2 {
		t.Fatalf("got %d days, want 2 (blank lines skipped)", len(stats))
	}
	if stats[0].Date != "2026-01-01" || stats[0].Origin != "o" {
		t.Errorf("day 0 = %+v", stats[0])
	}
	if len(stats[0].Tags) != 1 || stats[0].Tags[0] != "t1" {
		t.Errorf("day 0 tags = %v", stats[0].Tags)
	}
	if stats[0].Contributors[0].Login != "a" || stats[0].Contributors[0].CumulativeCommits != 1 {
		t.Errorf("day 0 contributors = %+v", stats[0].Contributors)
	}
	if stats[1].Date != "2026-01-02" {
		t.Errorf("day 1 = %+v", stats[1])
	}
}

func TestReadDailyStatsBadJSON(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.jsonl")
	if err := os.WriteFile(path, []byte("{not json}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := readDailyStats(path)
	if err == nil {
		t.Fatal("want error for malformed JSON line")
	}
	if !strings.Contains(err.Error(), "failed to parse JSON line") {
		t.Errorf("error = %v, want parse failure message", err)
	}
}

func TestReadDailyStatsMissingFile(t *testing.T) {
	_, err := readDailyStats(filepath.Join(t.TempDir(), "nope.jsonl"))
	if err == nil {
		t.Fatal("want error for missing file")
	}
	if !strings.Contains(err.Error(), "failed to open file") {
		t.Errorf("error = %v, want open failure message", err)
	}
}

func TestReadDailyStatsStdin(t *testing.T) {
	old := os.Stdin
	defer func() { os.Stdin = old }()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	os.Stdin = r

	// Report the pipe write error from the main test goroutine: t.Errorf
	// after the test has returned would panic.
	writeErr := make(chan error, 1)
	go func() {
		defer w.Close()
		_, err := w.WriteString(`{"date":"2026-01-01"}` + "\n" + `{"date":"2026-01-02"}` + "\n")
		writeErr <- err
	}()

	stats, err := readDailyStats("-")
	if err != nil {
		t.Fatalf("readDailyStats(\"-\") error: %v", err)
	}
	if len(stats) != 2 {
		t.Fatalf("got %d days from stdin, want 2", len(stats))
	}
	if werr := <-writeErr; werr != nil {
		t.Errorf("writing fixture to pipe: %v", werr)
	}
}

// ---------------------------------------------------------------------------
// Model construction and layout
// ---------------------------------------------------------------------------

func TestInitialModel(t *testing.T) {
	stats := testStats()
	m := initialModel(stats, 100, 100*time.Millisecond)

	if m.topN != 100 {
		t.Errorf("topN = %d, want 100", m.topN)
	}
	// Contributors must be sorted by cumulative commits, descending.
	for i, day := range m.dailyStats {
		for j := 1; j < len(day.Contributors); j++ {
			if day.Contributors[j-1].CumulativeCommits < day.Contributors[j].CumulativeCommits {
				t.Errorf("day %d contributors not sorted desc: %v", i, day.Contributors)
			}
		}
	}
	// lastCommitDate only records contributors that committed that day,
	// and the most recent day wins.
	if idx, ok := m.lastCommitDate["alice"]; !ok || idx != 1 {
		t.Errorf("lastCommitDate[alice] = %d (ok=%v), want 1", idx, ok)
	}
	if idx, ok := m.lastCommitDate["bob"]; !ok || idx != 1 {
		t.Errorf("lastCommitDate[bob] = %d (ok=%v), want 1", idx, ok)
	}
	if _, ok := m.lastCommitDate["someone"]; ok {
		t.Error("lastCommitDate[someone] should not exist (never committed)")
	}
	// Tags carry forward to later days that have none of their own.
	if tag := m.tagByIndex[0]; tag != "v1.0" {
		t.Errorf("tagByIndex[0] = %q, want %q", tag, "v1.0")
	}
	if tag := m.tagByIndex[1]; tag != "v1.0" {
		t.Errorf("tagByIndex[1] = %q, want carried-forward %q", tag, "v1.0")
	}
	// Speed defaults.
	if m.speedIndex != 4 || m.speed != 100*time.Millisecond {
		t.Errorf("speed = %v (index %d), want 100ms (index 4)", m.speed, m.speedIndex)
	}
}

func TestCalculateLayout(t *testing.T) {
	tests := []struct {
		name              string
		width, height     int
		wantBar, wantName int
		wantRows          int
	}{
		{"default 80x24", 80, 24, 41, 10, 13},
		{"narrow 40x20", 40, 20, 40, 10, 9},
		{"wide 200x60", 200, 60, 120, 30, 49},
		{"short terminal clamps rows", 100, 12, 61, 10, 3},
	}
	// Expected values are characterization tests for calculateLayout, derived
	// as follows:
	//   progressWidth: len(controlsLine) - 7
	//   barWidth:      termWidth - 39 when that lands in (20, 120), clamped to
	//                  120 when larger, left at the default 40 when smaller
	//   nameWidth:     termWidth - (43 + barWidth), clamped to [10, 30]
	//   displayRows:   termHeight - 11, minimum 3
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := initialModel(testStats(), 100, 100*time.Millisecond)
			m.termWidth = tt.width
			m.termHeight = tt.height
			m.calculateLayout()
			if m.barWidth != tt.wantBar {
				t.Errorf("barWidth = %d, want %d", m.barWidth, tt.wantBar)
			}
			if m.nameWidth != tt.wantName {
				t.Errorf("nameWidth = %d, want %d", m.nameWidth, tt.wantName)
			}
			if m.displayRows != tt.wantRows {
				t.Errorf("displayRows = %d, want %d", m.displayRows, tt.wantRows)
			}
			if want := len(controlsLine) - 7; m.progressWidth != want {
				t.Errorf("progressWidth = %d, want %d", m.progressWidth, want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Init and Update
// ---------------------------------------------------------------------------

func TestInitSchedulesTick(t *testing.T) {
	m := initialModel(testStats(), 100, time.Millisecond)
	cmd := m.Init()
	if cmd == nil {
		t.Fatal("Init() = nil, want a tick command")
	}
	msg := cmd()
	if _, ok := msg.(tickMsg); !ok {
		t.Errorf("Init() cmd produced %T, want tickMsg", msg)
	}
}

func TestUpdateTickAdvancesAndFinishes(t *testing.T) {
	m := initialModel(testStats(), 100, time.Millisecond)

	// First tick: advance to the last day, which marks the run done.
	m, cmd := tick(m)
	if cmd == nil {
		t.Fatal("tick should reschedule itself")
	}
	if m.currentIndex != 1 {
		t.Errorf("currentIndex = %d, want 1", m.currentIndex)
	}
	if !m.done || m.countdown != countdownSeconds {
		t.Errorf("done = %v, countdown = %d, want done with countdown %d", m.done, m.countdown, countdownSeconds)
	}

	// Ticking while done counts down one second at a time. Note: the tick
	// commands are not executed here because Tick sleeps for its duration.
	for i := 0; i < countdownSeconds-1; i++ {
		var cmd tea.Cmd
		m, cmd = tick(m)
		if cmd == nil {
			t.Fatalf("tick %d should still reschedule", i)
		}
		if m.countdown != countdownSeconds-1-i {
			t.Fatalf("tick %d: countdown = %d, want %d", i, m.countdown, countdownSeconds-1-i)
		}
	}
	if m.countdown != 1 {
		t.Errorf("countdown = %d, want 1 before the final tick", m.countdown)
	}

	// The final tick quits the program.
	_, cmd = tick(m)
	if !isQuit(cmd) {
		t.Error("final tick should return a quit command")
	}
}

func TestUpdateTickPaused(t *testing.T) {
	m := initialModel(testStats(), 100, time.Millisecond)
	m.paused = true

	m, cmd := tick(m)
	if cmd == nil {
		t.Fatal("paused tick should still reschedule")
	}
	if m.currentIndex != 0 {
		t.Errorf("paused tick advanced to %d, want 0", m.currentIndex)
	}
	if m.done {
		t.Error("paused tick should not mark the run done")
	}
}

func TestUpdateKeysNavigate(t *testing.T) {
	tests := []struct {
		name string
		msg  tea.KeyPressMsg
		from int
		want int
	}{
		{"l forward", keyPress('l', "l"), 0, 1},
		{"right arrow forward", tea.KeyPressMsg{Code: tea.KeyRight}, 0, 1},
		{"h back", keyPress('h', "h"), 1, 0},
		{"left arrow back", tea.KeyPressMsg{Code: tea.KeyLeft}, 1, 0},
		{"semicolon jumps +100 clamped", keyPress(';', ";"), 0, 1},
		{"g jumps -100 clamped", keyPress('g', "g"), 1, 0},
		{"r restarts", keyPress('r', "r"), 1, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := initialModel(testStats(), 100, 100*time.Millisecond)
			m.currentIndex = tt.from
			m, _ = update(m, tt.msg)
			if m.currentIndex != tt.want {
				t.Errorf("currentIndex = %d, want %d", m.currentIndex, tt.want)
			}
		})
	}
}

func TestUpdateKeysDoNotOverflow(t *testing.T) {
	m := initialModel(testStats(), 100, 100*time.Millisecond)

	// Forward past the last day stays on the last day.
	m.currentIndex = 1
	m, _ = update(m, keyPress('l', "l"))
	if m.currentIndex != 1 {
		t.Errorf("forward past end = %d, want 1", m.currentIndex)
	}

	// Backward past the first day stays on the first day.
	m.currentIndex = 0
	m, _ = update(m, keyPress('h', "h"))
	if m.currentIndex != 0 {
		t.Errorf("backward past start = %d, want 0", m.currentIndex)
	}
}

func TestUpdateKeysChangeSpeed(t *testing.T) {
	m := initialModel(testStats(), 100, 100*time.Millisecond)
	if m.speedIndex != 4 {
		t.Fatalf("starting speedIndex = %d, want 4", m.speedIndex)
	}

	m, _ = update(m, tea.KeyPressMsg{Code: tea.KeyDown}) // down: slower
	if m.speedIndex != 5 || m.speed != speedLevels[5] {
		t.Errorf("after down: speedIndex = %d, speed = %v", m.speedIndex, m.speed)
	}
	m, _ = update(m, keyPress('j', "j")) // j: slower
	if m.speedIndex != 6 || m.speed != speedLevels[6] {
		t.Errorf("after j: speedIndex = %d, speed = %v", m.speedIndex, m.speed)
	}
	m, _ = update(m, tea.KeyPressMsg{Code: tea.KeyUp}) // up: faster
	if m.speedIndex != 5 || m.speed != speedLevels[5] {
		t.Errorf("after up: speedIndex = %d, speed = %v", m.speedIndex, m.speed)
	}
	m, _ = update(m, keyPress('k', "k")) // k: faster
	if m.speedIndex != 4 || m.speed != speedLevels[4] {
		t.Errorf("after k: speedIndex = %d, speed = %v", m.speedIndex, m.speed)
	}

	// Speed changes stay within the level list.
	for i := 0; i < len(speedLevels)+5; i++ {
		m, _ = update(m, keyPress('j', "j"))
	}
	if m.speedIndex != len(speedLevels)-1 {
		t.Errorf("speedIndex = %d, want clamped to %d", m.speedIndex, len(speedLevels)-1)
	}
	for i := 0; i < len(speedLevels)+5; i++ {
		m, _ = update(m, keyPress('k', "k"))
	}
	if m.speedIndex != 0 {
		t.Errorf("speedIndex = %d, want clamped to 0", m.speedIndex)
	}
}

func TestUpdateSpaceTogglesPause(t *testing.T) {
	// Document the v2 key contract that the "space" case below relies on:
	// in bubbletea v2 the space key reports as "space" (v1 reported " ").
	if got := keyPress(' ', " ").String(); got != "space" {
		t.Fatalf("space key String() = %q, want %q", got, "space")
	}

	m := initialModel(testStats(), 100, 100*time.Millisecond)

	m, _ = update(m, keyPress(' ', " "))
	if !m.paused {
		t.Error("space should pause playback")
	}
	m, _ = update(m, keyPress(' ', " "))
	if m.paused {
		t.Error("space should resume playback")
	}
}

func TestUpdateSpaceResetsDoneState(t *testing.T) {
	m := initialModel(testStats(), 100, 100*time.Millisecond)
	m, _ = tick(m) // reach the last day: done, countdown running
	if !m.done {
		t.Fatal("precondition: model should be done")
	}

	m, _ = update(m, keyPress(' ', " "))
	if m.done {
		t.Error("space after done should clear done")
	}
	if m.countdown != 0 {
		t.Errorf("countdown = %d, want 0", m.countdown)
	}
	if !m.paused {
		t.Error("space after done should pause for review")
	}
}

func TestUpdateQuitKeys(t *testing.T) {
	for _, msg := range []tea.Msg{
		keyPress('q', "q"),
		ctrlPress('c'),
	} {
		t.Run(msg.(tea.KeyPressMsg).String(), func(t *testing.T) {
			m := initialModel(testStats(), 100, 100*time.Millisecond)
			_, cmd := update(m, msg)
			if !isQuit(cmd) {
				t.Errorf("%s should quit, got cmd %v", msg.(tea.KeyPressMsg).String(), cmd)
			}
		})
	}
}

func TestUpdateWindowSizeRecalculatesLayout(t *testing.T) {
	m := initialModel(testStats(), 100, 100*time.Millisecond)

	m, _ = update(m, tea.WindowSizeMsg{Width: 200, Height: 60})
	if m.termWidth != 200 || m.termHeight != 60 {
		t.Errorf("terminal size = %dx%d, want 200x60", m.termWidth, m.termHeight)
	}
	if m.barWidth != 120 {
		t.Errorf("barWidth = %d, want 120 after resize", m.barWidth)
	}
	if m.displayRows != 49 {
		t.Errorf("displayRows = %d, want 49 after resize", m.displayRows)
	}
}

// ---------------------------------------------------------------------------
// View rendering
// ---------------------------------------------------------------------------

func TestViewEmpty(t *testing.T) {
	v := model{}.View()
	if v.Content != "No data to display\n" {
		t.Errorf("empty view = %q", v.Content)
	}
}

func TestViewContent(t *testing.T) {
	m := initialModel(testStats(), 100, 100*time.Millisecond)
	v := m.View()

	// Styled segments are wrapped in ANSI escapes, so assert the label and
	// the styled value separately.
	for _, want := range []string{
		"Daily Contributor Rankings",
		"chicks-net/data-curated",
		"Date: ",
		"2026-01-01",
		"Origin: ",
		"test-origin",
		"v1.0",
		"Top Contributors",
		"alice",
		"bob",
		"(+5 today)",
		"Mode: ",
		"Playing",
		"Speed: ",
		"100ms",
		"Day 1/2",
		"Controls:",
	} {
		if !strings.Contains(v.Content, want) {
			t.Errorf("view missing %q", want)
		}
	}
	if v.AltScreen != true {
		t.Error("view should declare the alternate screen")
	}
}

func TestViewRespectsTopN(t *testing.T) {
	m := initialModel(testStats(), 1, 100*time.Millisecond)
	v := m.View()
	if strings.Contains(v.Content, "bob") {
		t.Error("view should show only the top 1 contributor")
	}
	if !strings.Contains(v.Content, "alice") {
		t.Error("view should still show the top contributor")
	}
}

func TestViewDoneShowsCountdown(t *testing.T) {
	m := initialModel(testStats(), 100, time.Millisecond)
	m, _ = tick(m) // reach the last day and start the countdown

	v := m.View()
	if !strings.Contains(v.Content, "Exiting in") {
		t.Errorf("done view should show the exit countdown: %q", v.Content)
	}
}

func TestViewRelaxingContributor(t *testing.T) {
	// Build 105 consecutive days where "oldtimer" only committed on day 0.
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	days := make([]DailyStats, 105)
	for i := range days {
		days[i] = DailyStats{
			Date: start.AddDate(0, 0, i).Format("2006-01-02"),
			Contributors: []ContributorRank{
				{Login: "alice", CumulativeCommits: 100 + i, CommitsToday: 1, Rank: 1},
				{Login: "oldtimer", CumulativeCommits: 5, CommitsToday: 0, Rank: 2},
			},
		}
	}
	// oldtimer's only commit happened on day 0.
	days[0].Contributors[1].CommitsToday = 1

	m := initialModel(days, 100, 100*time.Millisecond)
	m.currentIndex = 104 // 104 days since oldtimer's last commit

	v := m.View()
	if !strings.Contains(v.Content, "relaxing for 104 days") {
		t.Error("view should note the long-idle contributor")
	}
}

func TestRenderNameStyles(t *testing.T) {
	m := initialModel(testStats(), 100, 100*time.Millisecond)

	cases := []struct {
		label    string
		name     string
		relaxing bool
	}{
		{"highlighted", "Chicks", false}, // matches the [CT]h highlight regex
		{"normal", "someone", false},
		{"relaxing", "oldtimer", true},
	}

	// Each render must be visibly distinct from the others, so a style
	// regression (e.g. every path collapsing onto one style) is caught.
	seen := make(map[string]string)
	for _, c := range cases {
		rendered := m.renderName(c.name, c.relaxing)
		t.Run(c.label, func(t *testing.T) {
			if !strings.Contains(rendered, c.name) {
				t.Errorf("render lost the name: %q", rendered)
			}
			if !strings.Contains(rendered, "\x1b[") {
				t.Errorf("render is unstyled: %q", rendered)
			}
			if w := lipgloss.Width(rendered); w != m.nameWidth {
				t.Errorf("rendered width = %d, want padded to nameWidth %d", w, m.nameWidth)
			}
		})
		if other, dup := seen[rendered]; dup {
			t.Errorf("%s render duplicates the %s render: %q", c.label, other, rendered)
		}
		seen[rendered] = c.label
	}
}

func TestRenderProgressBar(t *testing.T) {
	m := initialModel(testStats(), 100, 100*time.Millisecond)

	// Day 1 of 2 = 50%.
	bar := m.renderProgressBar(50)
	if !strings.Contains(bar, "50%") {
		t.Errorf("progress bar = %q, want 50%%", bar)
	}
	if !strings.Contains(bar, "[") || !strings.Contains(bar, "]") {
		t.Errorf("progress bar = %q, want bracketed bar", bar)
	}

	// Full progress fills the whole bar.
	full := m.renderProgressBar(100)
	if !strings.Contains(full, "100%") {
		t.Errorf("full bar = %q, want 100%%", full)
	}
}
