package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
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

	// Validate string length before slicing to prevent panic
	if len(s) < 2 {
		return fmt.Errorf("invalid date string: too short")
	}

	// Remove quotes
	s = s[1 : len(s)-1]

	// Parse the date in the format: 2025-12-03T08:00:00 and interpret as UTC
	t, err := time.Parse("2006-01-02T15:04:05", s)
	if err != nil {
		return err
	}
	ct.Time = t.UTC()
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
	// Configure logging - JSON format if JSON_LOGS env var is set
	// All times use UTC consistently
	zerolog.TimestampFunc = func() time.Time {
		return time.Now().UTC()
	}

	if os.Getenv("JSON_LOGS") == "true" {
		// JSON logging for production/automated environments
		zerolog.TimeFieldFormat = time.RFC3339
		log.Logger = zerolog.New(os.Stdout).With().Timestamp().Caller().Logger()
	} else {
		// Human-readable console logging for interactive use
		output := zerolog.ConsoleWriter{
			Out:        os.Stdout,
			TimeFormat: time.RFC3339,
			FormatTimestamp: func(i interface{}) string {
				// Ensure timestamps are always displayed in UTC
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

	log.Info().Msg("Starting jackpot checker")

	// Initialize database
	db, err := initDatabase()
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to initialize database")
	}
	defer db.Close()

	// Fetch Powerball jackpot
	log.Info().Str("game", "Powerball").Msg("Fetching jackpot data")
	pbRecord, err := fetchJackpot(PowerballGameID, "Powerball")
	if err != nil {
		log.Error().Err(err).Str("game", "Powerball").Msg("Error fetching jackpot")
	} else {
		if err := saveJackpot(db, pbRecord); err != nil {
			log.Error().Err(err).Str("game", "Powerball").Msg("Error saving jackpot")
		} else {
			log.Info().
				Str("game", "Powerball").
				Int("draw_number", pbRecord.DrawNumber).
				Str("draw_date", pbRecord.DrawDate.Format("2006-01-02")).
				Int64("jackpot_dollars", pbRecord.Jackpot).
				Int64("cash_value_dollars", pbRecord.EstimatedCash).
				Msg("Jackpot data saved successfully")
		}
	}

	// Fetch Mega Millions jackpot
	log.Info().Str("game", "Mega Millions").Msg("Fetching jackpot data")
	mmRecord, err := fetchJackpot(MegaMillionsGameID, "Mega Millions")
	if err != nil {
		log.Error().Err(err).Str("game", "Mega Millions").Msg("Error fetching jackpot")
	} else {
		if err := saveJackpot(db, mmRecord); err != nil {
			log.Error().Err(err).Str("game", "Mega Millions").Msg("Error saving jackpot")
		} else {
			log.Info().
				Str("game", "Mega Millions").
				Int("draw_number", mmRecord.DrawNumber).
				Str("draw_date", mmRecord.DrawDate.Format("2006-01-02")).
				Int64("jackpot_dollars", mmRecord.Jackpot).
				Int64("cash_value_dollars", mmRecord.EstimatedCash).
				Msg("Jackpot data saved successfully")
		}
	}

	log.Info().Str("database", "jackpots.db").Msg("Jackpot checker completed successfully")
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
		checked_at TEXT NOT NULL
	);

	CREATE INDEX IF NOT EXISTS idx_game_date ON jackpots(game, draw_date);
	CREATE INDEX IF NOT EXISTS idx_checked_at ON jackpots(checked_at);
	CREATE INDEX IF NOT EXISTS idx_game_draw ON jackpots(game, draw_number, draw_date);
	`

	if _, err := db.Exec(createTableSQL); err != nil {
		return nil, fmt.Errorf("failed to create table: %w", err)
	}

	return db, nil
}

func fetchJackpot(gameID int, gameName string) (*JackpotRecord, error) {
	// Construct API URL - fetch just 1 result from page 1
	url := fmt.Sprintf("%s/%d/1/1", APIBaseURL, gameID)

	// Create HTTP client with timeout to prevent indefinite blocking
	client := &http.Client{Timeout: 30 * time.Second}

	// Make HTTP request
	resp, err := client.Get(url)
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

	// Create record with proper rounding to avoid lossy float-to-int conversion
	record := &JackpotRecord{
		Game:          gameName,
		DrawNumber:    lotteryData.NextDraw.DrawNumber,
		DrawDate:      lotteryData.NextDraw.DrawDate.Time,
		Jackpot:       int64(math.Round(lotteryData.NextDraw.Jackpot)),
		EstimatedCash: int64(math.Round(lotteryData.NextDraw.EstimatedCash)),
		CheckedAt:     time.Now().UTC(),
	}

	return record, nil
}

func saveJackpot(db *sql.DB, record *JackpotRecord) error {
	insertSQL := `
	INSERT INTO jackpots (game, draw_number, draw_date, jackpot, estimated_cash, checked_at)
	VALUES (?, ?, ?, ?, ?, ?)
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
