-- Migration to remove UNIQUE constraint from jackpots table
-- This allows storing multiple check records for the same draw

BEGIN TRANSACTION;

-- Create new table with the updated schema (without UNIQUE constraint)
CREATE TABLE jackpots_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    game TEXT NOT NULL,
    draw_number INTEGER NOT NULL,
    draw_date TEXT NOT NULL,
    jackpot INTEGER NOT NULL,
    estimated_cash INTEGER NOT NULL,
    checked_at TEXT NOT NULL
);

-- Copy all existing data
INSERT INTO jackpots_new (id, game, draw_number, draw_date, jackpot, estimated_cash, checked_at)
SELECT id, game, draw_number, draw_date, jackpot, estimated_cash, checked_at
FROM jackpots;

-- Drop the old table
DROP TABLE jackpots;

-- Rename the new table to the original name
ALTER TABLE jackpots_new RENAME TO jackpots;

-- Recreate indexes
CREATE INDEX idx_game_date ON jackpots(game, draw_date);
CREATE INDEX idx_checked_at ON jackpots(checked_at);
CREATE INDEX idx_game_draw ON jackpots(game, draw_number, draw_date);

COMMIT;
