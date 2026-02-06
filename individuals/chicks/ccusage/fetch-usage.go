package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os/exec"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// DailyUsage represents a single day's token usage
type DailyUsage struct {
	Date                string          `json:"date"`
	InputTokens         int64           `json:"inputTokens"`
	OutputTokens        int64           `json:"outputTokens"`
	CacheCreationTokens int64           `json:"cacheCreationTokens"`
	CacheReadTokens     int64           `json:"cacheReadTokens"`
	TotalTokens         int64           `json:"totalTokens"`
	TotalCost           float64         `json:"totalCost"`
	ModelsUsed          []string        `json:"modelsUsed"`
	ModelBreakdowns     []ModelBreakdown `json:"modelBreakdowns"`
}

// ModelBreakdown represents per-model usage within a day
type ModelBreakdown struct {
	ModelName           string  `json:"modelName"`
	InputTokens         int64   `json:"inputTokens"`
	OutputTokens        int64   `json:"outputTokens"`
	CacheCreationTokens int64   `json:"cacheCreationTokens"`
	CacheReadTokens     int64   `json:"cacheReadTokens"`
	Cost                float64 `json:"cost"`
}

// DailyResponse wraps the daily array from ccusage
type DailyResponse struct {
	Daily []DailyUsage `json:"daily"`
}

// SessionUsage represents usage by conversation session
type SessionUsage struct {
	SessionID           string          `json:"sessionId"`
	InputTokens         int64           `json:"inputTokens"`
	OutputTokens        int64           `json:"outputTokens"`
	CacheCreationTokens int64           `json:"cacheCreationTokens"`
	CacheReadTokens     int64           `json:"cacheReadTokens"`
	TotalTokens         int64           `json:"totalTokens"`
	TotalCost           float64         `json:"totalCost"`
	LastActivity        string          `json:"lastActivity"`
	ModelsUsed          []string        `json:"modelsUsed"`
	ModelBreakdowns     []ModelBreakdown `json:"modelBreakdowns"`
	ProjectPath         string          `json:"projectPath"`
}

// SessionResponse wraps the sessions array from ccusage
type SessionResponse struct {
	Sessions []SessionUsage `json:"sessions"`
}

const dbPath = "usage.db"

func main() {
	// Initialize database
	db, err := initDB()
	if err != nil {
		log.Fatalf("Failed to initialize database: %v", err)
	}
	defer db.Close()

	// Fetch daily usage
	if err := fetchDailyUsage(db); err != nil {
		log.Fatalf("Failed to fetch daily usage: %v", err)
	}

	// Fetch session usage
	if err := fetchSessionUsage(db); err != nil {
		log.Fatalf("Failed to fetch session usage: %v", err)
	}

	fmt.Println("✅ Claude Code usage data fetched successfully!")
	fmt.Printf("📊 Database: %s\n", dbPath)
}

func initDB() (*sql.DB, error) {
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, err
	}

	// Create daily_usage table
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS daily_usage (
			date TEXT PRIMARY KEY,
			input_tokens INTEGER,
			output_tokens INTEGER,
			cache_creation_tokens INTEGER,
			cache_read_tokens INTEGER,
			total_tokens INTEGER,
			total_cost REAL,
			models_used TEXT,
			fetched_at TEXT
		)
	`)
	if err != nil {
		return nil, fmt.Errorf("failed to create daily_usage table: %w", err)
	}

	// Create model_breakdown table
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS model_breakdown (
			date TEXT,
			model_name TEXT,
			input_tokens INTEGER,
			output_tokens INTEGER,
			cache_creation_tokens INTEGER,
			cache_read_tokens INTEGER,
			cost REAL,
			fetched_at TEXT,
			PRIMARY KEY (date, model_name)
		)
	`)
	if err != nil {
		return nil, fmt.Errorf("failed to create model_breakdown table: %w", err)
	}

	// Create session_usage table
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS session_usage (
			session_id TEXT PRIMARY KEY,
			input_tokens INTEGER,
			output_tokens INTEGER,
			cache_creation_tokens INTEGER,
			cache_read_tokens INTEGER,
			total_tokens INTEGER,
			total_cost REAL,
			last_activity TEXT,
			models_used TEXT,
			project_path TEXT,
			fetched_at TEXT
		)
	`)
	if err != nil {
		return nil, fmt.Errorf("failed to create session_usage table: %w", err)
	}

	return db, nil
}

func fetchDailyUsage(db *sql.DB) error {
	// Run ccusage daily --json
	cmd := exec.Command("ccusage", "daily", "--json")
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to run ccusage: %w", err)
	}

	var response DailyResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return fmt.Errorf("failed to parse JSON: %w", err)
	}

	fetchedAt := time.Now().UTC().Format(time.RFC3339)

	// Insert daily usage data
	for _, usage := range response.Daily {
		modelsJSON, _ := json.Marshal(usage.ModelsUsed)

		_, err := db.Exec(`
			INSERT OR REPLACE INTO daily_usage
			(date, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens,
			 total_tokens, total_cost, models_used, fetched_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		`, usage.Date, usage.InputTokens, usage.OutputTokens, usage.CacheCreationTokens,
			usage.CacheReadTokens, usage.TotalTokens, usage.TotalCost, string(modelsJSON), fetchedAt)

		if err != nil {
			return fmt.Errorf("failed to insert daily usage: %w", err)
		}

		// Insert model breakdowns
		for _, model := range usage.ModelBreakdowns {
			_, err := db.Exec(`
				INSERT OR REPLACE INTO model_breakdown
				(date, model_name, input_tokens, output_tokens, cache_creation_tokens,
				 cache_read_tokens, cost, fetched_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			`, usage.Date, model.ModelName, model.InputTokens, model.OutputTokens,
				model.CacheCreationTokens, model.CacheReadTokens, model.Cost, fetchedAt)

			if err != nil {
				return fmt.Errorf("failed to insert model breakdown: %w", err)
			}
		}
	}

	fmt.Printf("✅ Fetched %d days of usage data\n", len(response.Daily))
	return nil
}

func fetchSessionUsage(db *sql.DB) error {
	// Run ccusage session --json
	cmd := exec.Command("ccusage", "session", "--json")
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to run ccusage: %w", err)
	}

	var response SessionResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return fmt.Errorf("failed to parse JSON: %w", err)
	}

	fetchedAt := time.Now().UTC().Format(time.RFC3339)

	// Insert session usage data
	for _, session := range response.Sessions {
		modelsJSON, _ := json.Marshal(session.ModelsUsed)

		_, err := db.Exec(`
			INSERT OR REPLACE INTO session_usage
			(session_id, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens,
			 total_tokens, total_cost, last_activity, models_used, project_path, fetched_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`, session.SessionID, session.InputTokens, session.OutputTokens, session.CacheCreationTokens,
			session.CacheReadTokens, session.TotalTokens, session.TotalCost, session.LastActivity,
			string(modelsJSON), session.ProjectPath, fetchedAt)

		if err != nil {
			return fmt.Errorf("failed to insert session usage: %w", err)
		}
	}

	fmt.Printf("✅ Fetched %d session records\n", len(response.Sessions))
	return nil
}
