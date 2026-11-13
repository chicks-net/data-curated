package main

// Fuzz tests for the jackpot-checker code paths that face the outside world:
// the California Lottery API (the draw-date format, whole response payloads)
// and the SQLite insert (arbitrary field values).
//
// The `func FuzzXxx(f *testing.F)` signatures below are load-bearing for
// OpenSSF Scorecard: its Fuzzing check looks for exactly this pattern in
// *_test.go files. The seed corpora run as ordinary tests under `just
// go-test`; actual fuzzing runs via `just lottery-fuzz` and the weekly
// .github/workflows/fuzz.yml job. Failing inputs are written to
// testdata/fuzz/ and should be committed as regression seeds once triaged.
//
// See https://go.dev/doc/fuzz/ for native Go fuzzing details.

import (
	"encoding/json"
	"math"
	"testing"
	"time"
	"unicode/utf8"
)

// FuzzCustomTimeUnmarshalJSON feeds arbitrary bytes to the API draw-date
// parser. On success the payload must yield a canonical UTC date: the
// formatted result must be stable under re-parsing.
func FuzzCustomTimeUnmarshalJSON(f *testing.F) {
	f.Add([]byte(`"2025-12-03T08:00:00"`)) // the API's documented format
	f.Add([]byte(`"2026-02-14T20:59:59"`))
	f.Add([]byte(`null`))                  // JSON null: must error, not panic
	f.Add([]byte(`""`))                    // empty string hits the length guard
	f.Add([]byte(`a`))                     // shorter than the length guard
	f.Add([]byte(`"abc"`))                 // non-date text
	f.Add([]byte(`"2025-13-45T99:99:99"`)) // well-formed garbage
	f.Add([]byte(`12345`))                 // JSON number
	f.Add([]byte(`"🚀🚀"`))                  // longer in bytes than in runes
	f.Add([]byte(`"2025-12-03T8:00:00"`))  // lenient input: single-digit hour

	f.Fuzz(func(t *testing.T, data []byte) {
		var ct CustomTime
		if err := ct.UnmarshalJSON(data); err != nil {
			return
		}
		// A successful parse must yield a canonical UTC date. The raw input
		// need not round-trip (time.Parse accepts lenient values like the
		// single-digit hour seeded above), but the formatted result must be
		// stable: re-parsing it must produce the same string.
		const layout = "2006-01-02T15:04:05"
		formatted := ct.Format(layout)
		if ct.Location() != time.UTC {
			t.Errorf("parsed date has location %v, want UTC", ct.Location())
		}
		reparsed, err := time.Parse(layout, formatted)
		if err != nil {
			t.Errorf("formatted date %q does not re-parse: %v", formatted, err)
			return
		}
		if got := reparsed.Format(layout); got != formatted {
			t.Errorf("date formatting not stable: %q re-parses to %q", formatted, got)
		}
	})
}

// FuzzLotteryResponseParsing feeds arbitrary JSON through the same
// unmarshal-and-convert path fetchJackpot uses to build a JackpotRecord.
// json.Unmarshal rejects NaN/Infinity and out-of-range numbers like 1e999,
// so parsed amounts are always finite; out-of-range float-to-int64
// conversion is implementation-defined in Go, so exactness is only asserted
// for values that convert cleanly.
func FuzzLotteryResponseParsing(f *testing.F) {
	f.Add([]byte(`{"GameId":12,"GameName":"Powerball","TotalDrawsPlayed":1545,"NextDraw":{"DrawNumber":1545,"DrawDate":"2025-12-03T08:00:00","JackpotAmount":775000000,"EstimatedCashValue":362500000,"DrawCloseTime":"Wednesday 7:59 PM"}}`))
	f.Add([]byte(`{"GameId":15,"GameName":"Mega Millions","TotalDrawsPlayed":2134,"NextDraw":{"DrawNumber":2134,"DrawDate":"2025-12-02T08:00:00","JackpotAmount":90000000,"EstimatedCashValue":41900000,"DrawCloseTime":"Tuesday 8:00 PM"}}`))
	f.Add([]byte(`{}`))
	f.Add([]byte(`null`))
	f.Add([]byte(`{"NextDraw":{"DrawNumber":-1,"JackpotAmount":-1,"EstimatedCashValue":0}}`))
	f.Add([]byte(`{"NextDraw":{"JackpotAmount":1e308,"EstimatedCashValue":-1e308}}`)) // beyond int64 range
	f.Add([]byte(`{"NextDraw":{"DrawDate":null}}`))                                   // null date must error, not panic
	f.Add([]byte(`{"NextDraw":{"JackpotAmount":NaN}}`))                               // invalid JSON

	f.Fuzz(func(t *testing.T, data []byte) {
		var resp LotteryResponse
		if err := json.Unmarshal(data, &resp); err != nil {
			return
		}
		// The exact float-to-int conversions fetchJackpot performs must not
		// panic for any successfully-parsed payload.
		jackpot := int64(math.Round(resp.NextDraw.Jackpot))
		cash := int64(math.Round(resp.NextDraw.EstimatedCash))

		// For values that convert cleanly, the rounding must be exact.
		// 2^52 is the largest float64 below which every representable value
		// is an integer that survives int64 conversion and back.
		const safeLimit = float64(1 << 52)
		for _, amount := range []struct {
			raw  float64
			conv int64
		}{{resp.NextDraw.Jackpot, jackpot}, {resp.NextDraw.EstimatedCash, cash}} {
			rounded := math.Round(amount.raw)
			if -safeLimit <= rounded && rounded <= safeLimit && float64(amount.conv) != rounded {
				t.Errorf("int64 conversion corrupted rounded value %v to %d", rounded, amount.conv)
			}
		}
	})
}

// FuzzSaveJackpot pushes arbitrary field values through the parameterized
// SQLite insert. Every record must insert without error (proving the
// parameterized queries cannot be broken by hostile data) and read back
// exactly as handed to the driver.
func FuzzSaveJackpot(f *testing.F) {
	f.Add("Powerball", 1545, "2025-12-03T08:00:00Z", int64(775000000), int64(362500000))
	f.Add("Mega Millions", 2134, "2025-12-02T08:00:00Z", int64(90000000), int64(41900000))
	f.Add("Powerball'); DROP TABLE jackpots;--", -1, "2025-12-03T08:00:00Z", int64(-1), int64(0))
	f.Add("🚀 jackpot", 0, "2025-12-03T08:00:00Z", int64(9223372036854775807), int64(-9223372036854775808))
	f.Add("name with \"double\" and 'single' quotes", 999999999, "2025-12-03T08:00:00-08:00", int64(0), int64(0))

	f.Fuzz(func(t *testing.T, game string, drawNumber int, drawDate string, jackpot, estimatedCash int64) {
		// DrawDate comes from parsed API JSON, so only RFC 3339 strings are
		// in scope here.
		drawDateParsed, err := time.Parse(time.RFC3339, drawDate)
		if err != nil {
			return
		}
		record := &JackpotRecord{
			Game:          game,
			DrawNumber:    drawNumber,
			DrawDate:      drawDateParsed,
			Jackpot:       jackpot,
			EstimatedCash: estimatedCash,
			CheckedAt:     time.Now().UTC(),
		}

		db, err := initDatabaseAt(":memory:")
		if err != nil {
			t.Fatalf("failed to open in-memory database: %v", err)
		}
		defer db.Close()
		// ':memory:' databases are private per connection; pin the pool to
		// one connection so the insert and the read-back share the same one.
		db.SetMaxOpenConns(1)

		if err := saveJackpot(db, record); err != nil {
			t.Fatalf("saveJackpot rejected a parameterized insert: %v", err)
		}

		var gotGame string
		var gotDrawNumber int
		var gotDrawDate string
		var gotJackpot int64
		var gotCash int64
		err = db.QueryRow(`SELECT game, draw_number, draw_date, jackpot, estimated_cash FROM jackpots`).Scan(
			&gotGame, &gotDrawNumber, &gotDrawDate, &gotJackpot, &gotCash)
		if err != nil {
			t.Fatalf("failed to read back inserted row: %v", err)
		}

		// Invalid UTF-8 game names are stored byte-for-byte by SQLite but
		// are not worth asserting on; they never occur via the API constants.
		if utf8.ValidString(game) && gotGame != game {
			t.Errorf("game round-trip mismatch: inserted %q, got %q", game, gotGame)
		}
		if gotDrawNumber != drawNumber {
			t.Errorf("draw_number round-trip mismatch: inserted %d, got %d", drawNumber, gotDrawNumber)
		}
		// The same expression saveJackpot uses to store draw_date.
		if wantDate := record.DrawDate.Format("2006-01-02"); gotDrawDate != wantDate {
			t.Errorf("draw_date round-trip mismatch: inserted %q, got %q", wantDate, gotDrawDate)
		}
		if gotJackpot != jackpot {
			t.Errorf("jackpot round-trip mismatch: inserted %d, got %d", jackpot, gotJackpot)
		}
		if gotCash != estimatedCash {
			t.Errorf("estimated_cash round-trip mismatch: inserted %d, got %d", estimatedCash, gotCash)
		}
	})
}
