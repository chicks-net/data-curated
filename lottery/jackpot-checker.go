package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

const (
	PowerballGameID   = 12
	MegaMillionsGameID = 15
	APIBaseURL        = "https://www.calottery.com/api/DrawGameApi/DrawGamePastDrawResults"
)

// CustomTime wraps time.Time to handle the API's date format
type CustomTime struct {
	time.Time
}

// UnmarshalJSON handles the custom date format from the API
func (ct *CustomTime) UnmarshalJSON(b []byte) error {
	s := string(b)
	// Remove quotes
	s = s[1 : len(s)-1]

	// Parse the date in the format: 2025-12-03T08:00:00
	t, err := time.Parse("2006-01-02T15:04:05", s)
	if err != nil {
		return err
	}
	ct.Time = t
	return nil
}

// Draw represents the next upcoming draw with jackpot information
type Draw struct {
	DrawNumber    int        `json:"DrawNumber"`
	DrawDate      CustomTime `json:"DrawDate"`
	Jackpot       float64    `json:"JackpotAmount"`
	EstimatedCash float64    `json:"EstimatedCashValue"`
	DrawCloseTime string     `json:"DrawCloseTime"`
}

// LotteryResponse represents the API response structure
type LotteryResponse struct {
	GameID           int    `json:"GameId"`
	GameName         string `json:"GameName"`
	TotalDrawsPlayed int    `json:"TotalDrawsPlayed"`
	NextDraw         Draw   `json:"NextDraw"`
}

// JackpotRecord represents a record in our database
type JackpotRecord struct {
	Game          string
	DrawNumber    int
	DrawDate      time.Time
	Jackpot       int64
	EstimatedCash int64
	CheckedAt     time.Time
}

func main() {
	// Initialize database
	db, err := initDatabase()
	if err != nil {
		log.Fatalf("Failed to initialize database: %v", err)
	}
	defer db.Close()

	// Fetch Powerball jackpot
	fmt.Println("Fetching Powerball jackpot...")
	pbRecord, err := fetchJackpot(PowerballGameID, "Powerball")
	if err != nil {
		log.Printf("Error fetching Powerball: %v", err)
	} else {
		if err := saveJackpot(db, pbRecord); err != nil {
			log.Printf("Error saving Powerball: %v", err)
		} else {
			fmt.Printf("✓ Powerball: Draw #%d on %s - $%d million (Cash: $%.1f million)\n",
				pbRecord.DrawNumber,
				pbRecord.DrawDate.Format("2006-01-02"),
				pbRecord.Jackpot/1000000,
				float64(pbRecord.EstimatedCash)/1000000)
		}
	}

	// Fetch Mega Millions jackpot
	fmt.Println("Fetching Mega Millions jackpot...")
	mmRecord, err := fetchJackpot(MegaMillionsGameID, "Mega Millions")
	if err != nil {
		log.Printf("Error fetching Mega Millions: %v", err)
	} else {
		if err := saveJackpot(db, mmRecord); err != nil {
			log.Printf("Error saving Mega Millions: %v", err)
		} else {
			fmt.Printf("✓ Mega Millions: Draw #%d on %s - $%d million (Cash: $%.1f million)\n",
				mmRecord.DrawNumber,
				mmRecord.DrawDate.Format("2006-01-02"),
				mmRecord.Jackpot/1000000,
				float64(mmRecord.EstimatedCash)/1000000)
		}
	}

	fmt.Println("\nData saved to lottery/jackpots.db")
}

func initDatabase() (*sql.DB, error) {
	db, err := sql.Open("sqlite3", "./jackpots.db")
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Create table if it doesn't exist
	createTableSQL := `
	CREATE TABLE IF NOT EXISTS jackpots (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		game TEXT NOT NULL,
		draw_number INTEGER NOT NULL,
		draw_date TEXT NOT NULL,
		jackpot INTEGER NOT NULL,
		estimated_cash INTEGER NOT NULL,
		checked_at TEXT NOT NULL,
		UNIQUE(game, draw_number, draw_date)
	);

	CREATE INDEX IF NOT EXISTS idx_game_date ON jackpots(game, draw_date);
	CREATE INDEX IF NOT EXISTS idx_checked_at ON jackpots(checked_at);
	`

	if _, err := db.Exec(createTableSQL); err != nil {
		return nil, fmt.Errorf("failed to create table: %w", err)
	}

	return db, nil
}

func fetchJackpot(gameID int, gameName string) (*JackpotRecord, error) {
	// Construct API URL - fetch just 1 result from page 1
	url := fmt.Sprintf("%s/%d/1/1", APIBaseURL, gameID)

	// Make HTTP request
	resp, err := http.Get(url)
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("API returned status %d", resp.StatusCode)
	}

	// Read response body
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	// Parse JSON
	var lotteryData LotteryResponse
	if err := json.Unmarshal(body, &lotteryData); err != nil {
		return nil, fmt.Errorf("failed to parse JSON: %w", err)
	}

	// Create record
	record := &JackpotRecord{
		Game:          gameName,
		DrawNumber:    lotteryData.NextDraw.DrawNumber,
		DrawDate:      lotteryData.NextDraw.DrawDate.Time,
		Jackpot:       int64(lotteryData.NextDraw.Jackpot),
		EstimatedCash: int64(lotteryData.NextDraw.EstimatedCash),
		CheckedAt:     time.Now(),
	}

	return record, nil
}

func saveJackpot(db *sql.DB, record *JackpotRecord) error {
	insertSQL := `
	INSERT INTO jackpots (game, draw_number, draw_date, jackpot, estimated_cash, checked_at)
	VALUES (?, ?, ?, ?, ?, ?)
	ON CONFLICT(game, draw_number, draw_date) DO UPDATE SET
		jackpot = excluded.jackpot,
		estimated_cash = excluded.estimated_cash,
		checked_at = excluded.checked_at
	`

	_, err := db.Exec(
		insertSQL,
		record.Game,
		record.DrawNumber,
		record.DrawDate.Format("2006-01-02"),
		record.Jackpot,
		record.EstimatedCash,
		record.CheckedAt.Format(time.RFC3339),
	)

	if err != nil {
		return fmt.Errorf("failed to insert record: %w", err)
	}

	return nil
}
