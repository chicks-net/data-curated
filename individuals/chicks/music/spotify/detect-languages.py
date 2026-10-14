#!/usr/bin/env python3
"""
Detect the spoken language of every track's lyrics in lyrics.db.

Runs langdetect over the plain lyrics fetched from LRCLIB (see
fetch-lyrics.py) and stores the top-2 language guesses per track,
following the guidance in
https://github.com/chicks-net/chicks-projects/issues/127:

- keep the top-2 languages, since choruses and bilingual songs skew a single-label result
- tag short, repetitive or low-probability lyrics as low confidence
- instrumentals and misses are not language results; lyrics.status encodes them

The database is the cache: re-runs only process found tracks that do
not have a track_languages row yet. --force re-detects everything.
Detection is local and seeded, so results are deterministic and re-runs
are free.
"""

# /// script
# dependencies = ["langdetect"]
# ///

import argparse
import re
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

from langdetect import DetectorFactory, detect_langs
from langdetect.lang_detect_exception import LangDetectException

DEFAULT_DB = Path(__file__).parent / "lyrics.db"

# langdetect samples internally, so fix the seed for reproducible runs
DETECTOR_SEED = 0

# Text shorter than this many characters is flagged low confidence
SHORT_TEXT_CHARS = 200
# Repetition heuristic: at least this many lines with fewer than this
# share unique means chorus-heavy lyrics -> low confidence
REPETITIVE_MIN_LINES = 8
REPETITIVE_UNIQUE_RATIO = 0.25
# The detector itself being unsure also means low confidence; catches
# gibberish choruses (Eiffel 65) and near-ties between languages
MIN_LANGUAGE_PROBABILITY = 0.9

# langdetect returns zh-cn / zh-tw variants; group them as one language
LANGUAGE_ALIASES = {"zh-cn": "zh", "zh-tw": "zh"}

# [00:12.34] style timestamps in synced lyrics
SYNCED_TIMESTAMP_RE = re.compile(r"^\[[0-9]+:[0-9]{2}(?:\.[0-9]+)?\]\s*")
# Lines that are entirely a bracketed tag, e.g. [Chorus] or [Verse 1]
BRACKET_TAG_LINE_RE = re.compile(r"^\s*\[[^\]]*\]\s*$")

CONFIDENCE_HIGH = "high"
CONFIDENCE_LOW = "low"

# Number of tracks processed before committing to the database
COMMIT_INTERVAL = 50

# Print progress every this many tracks
PROGRESS_INTERVAL = 50


def normalize_language(code: str) -> str:
    """Normalize a langdetect code (maps zh-cn / zh-tw to zh)."""
    return LANGUAGE_ALIASES.get(code, code)


def clean_lyrics(
    plain_lyrics: Optional[str], synced_lyrics: Optional[str]
) -> Optional[str]:
    """Return the best available text to analyze, without tag noise.

    Prefers plain lyrics; falls back to synced lyrics with the
    [00:12.34] timestamps stripped. Bracketed tag lines ([Chorus]) and
    blank lines are dropped from either form.

    Args:
        plain_lyrics: Plain lyrics from LRCLIB (may be None).
        synced_lyrics: Time-synced lyrics from LRCLIB (may be None).

    Returns:
        Cleaned lyric text, or None if there is nothing to analyze.
    """
    text = plain_lyrics
    if not text and synced_lyrics:
        text = "\n".join(
            SYNCED_TIMESTAMP_RE.sub("", line) for line in synced_lyrics.splitlines()
        )
    if not text:
        return None

    lines = []
    for line in text.splitlines():
        if BRACKET_TAG_LINE_RE.match(line):
            continue
        if line.strip():
            lines.append(line.strip())
    return "\n".join(lines) if lines else None


def is_repetitive(text: str) -> bool:
    """Flag chorus-heavy lyrics as repetitive.

    Args:
        text: Cleaned lyric text (no blank lines).

    Returns:
        True if there are enough lines that a low unique-line share is
        meaningful.
    """
    lines = text.splitlines()
    if len(lines) < REPETITIVE_MIN_LINES:
        return False
    return len(set(lines)) / len(lines) < REPETITIVE_UNIQUE_RATIO


def detect_language(text: str) -> Optional[Dict[str, Any]]:
    """Detect the language of one lyric text.

    Args:
        text: Cleaned lyric text.

    Returns:
        Dict with top-2 language guesses, probabilities and confidence,
        or None if langdetect finds nothing usable.
    """
    try:
        ranked = sorted(detect_langs(text), key=lambda lang: -lang.prob)
    except LangDetectException:
        # e.g. lyrics that are all "oh oh oh" - no detectable features
        return None

    if not ranked:
        return None

    result: Dict[str, Any] = {
        "language": normalize_language(ranked[0].lang),
        "language_probability": round(ranked[0].prob, 4),
        "language_2": None,
        "language_2_probability": None,
    }
    if len(ranked) > 1:
        result["language_2"] = normalize_language(ranked[1].lang)
        result["language_2_probability"] = round(ranked[1].prob, 4)

    chars = len(text)
    if (
        chars < SHORT_TEXT_CHARS
        or is_repetitive(text)
        or ranked[0].prob < MIN_LANGUAGE_PROBABILITY
    ):
        result["confidence"] = CONFIDENCE_LOW
    else:
        result["confidence"] = CONFIDENCE_HIGH
    result["chars_analyzed"] = chars
    return result


def create_database(db_path: Path) -> None:
    """Create the track_languages table in lyrics.db if missing."""
    with sqlite3.connect(db_path) as conn:
        cursor = conn.cursor()

        cursor.execute("""
            CREATE TABLE IF NOT EXISTS track_languages (
                track_id TEXT PRIMARY KEY REFERENCES tracks(track_id),
                language TEXT,
                language_probability REAL,
                language_2 TEXT,
                language_2_probability REAL,
                confidence TEXT CHECK (confidence IN ('high', 'low')
                    OR confidence IS NULL),
                chars_analyzed INTEGER,
                source TEXT,
                detected_at TEXT
            )
        """)

        # Create index for common queries
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_tl_language "
            "ON track_languages(language)"
        )

        conn.commit()


def process_tracks(conn: sqlite3.Connection, force: bool) -> Tuple[Dict[str, int], float]:
    """Detect languages for all pending found tracks.

    Args:
        conn: SQLite connection.
        force: Re-detect tracks that already have a row.

    Returns:
        Tuple of (counts by outcome, runtime seconds).
    """
    started = time.monotonic()
    counts = {
        "detected": 0,
        "low_confidence": 0,
        "undetectable": 0,
    }

    if force:
        conn.execute("DELETE FROM track_languages")
        conn.commit()

    rows = conn.execute(
        """
        SELECT t.track_id, t.track_name, t.artist_names,
            l.plain_lyrics, l.synced_lyrics
        FROM tracks t
        JOIN lyrics l USING(track_id)
        LEFT JOIN track_languages tl USING(track_id)
        WHERE l.status = 'found' AND tl.track_id IS NULL
        ORDER BY t.added_at
        """
    ).fetchall()
    print(f"{len(rows)} tracks to analyze")

    for i, (track_id, track_name, artist_names, plain, synced) in enumerate(
        rows, 1
    ):
        text = clean_lyrics(plain, synced)
        result = detect_language(text) if text else None

        detected_at = datetime.now(timezone.utc).isoformat()
        if result is None:
            # Lyrics exist but no language could be identified; keep a
            # row so incremental runs don't retry it every time
            conn.execute(
                """
                INSERT INTO track_languages (
                    track_id, language, language_probability, language_2,
                    language_2_probability, confidence, chars_analyzed,
                    source, detected_at
                ) VALUES (?, NULL, NULL, NULL, NULL, NULL, ?, ?, ?)
                ON CONFLICT(track_id) DO UPDATE SET
                    language = NULL,
                    language_probability = NULL,
                    language_2 = NULL,
                    language_2_probability = NULL,
                    confidence = NULL,
                    chars_analyzed = excluded.chars_analyzed,
                    source = excluded.source,
                    detected_at = excluded.detected_at
                """,
                (
                    track_id,
                    len(text) if text else 0,
                    "langdetect",
                    detected_at,
                ),
            )
            counts["undetectable"] += 1
        else:
            conn.execute(
                """
                INSERT INTO track_languages (
                    track_id, language, language_probability, language_2,
                    language_2_probability, confidence, chars_analyzed,
                    source, detected_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(track_id) DO UPDATE SET
                    language = excluded.language,
                    language_probability = excluded.language_probability,
                    language_2 = excluded.language_2,
                    language_2_probability = excluded.language_2_probability,
                    confidence = excluded.confidence,
                    chars_analyzed = excluded.chars_analyzed,
                    source = excluded.source,
                    detected_at = excluded.detected_at
                """,
                (
                    track_id,
                    result["language"],
                    result["language_probability"],
                    result["language_2"],
                    result["language_2_probability"],
                    result["confidence"],
                    result["chars_analyzed"],
                    "langdetect",
                    detected_at,
                ),
            )
            counts["detected"] += 1
            if result["confidence"] == CONFIDENCE_LOW:
                counts["low_confidence"] += 1

        if i % COMMIT_INTERVAL == 0:
            conn.commit()
        if i % PROGRESS_INTERVAL == 0:
            print(f"[{i}/{len(rows)}]")

    conn.commit()
    return counts, time.monotonic() - started


def main() -> None:
    """Main function."""
    parser = argparse.ArgumentParser(
        description="Detect lyric languages with langdetect and store in lyrics.db."
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB,
        help=f"SQLite database to update (default: {DEFAULT_DB.name})",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-detect tracks that already have a language result",
    )
    args = parser.parse_args()

    if not args.db.exists():
        print(f"Error: database not found: {args.db}", file=sys.stderr)
        print("Run 'just fetch-lyrics' to create it.", file=sys.stderr)
        sys.exit(1)

    # Deterministic results across runs
    DetectorFactory.seed = DETECTOR_SEED

    print("Lyric Language Detection (langdetect)")
    print("=" * 50)
    print(f"Database: {args.db}")
    print()

    create_database(args.db)

    with sqlite3.connect(args.db) as conn:
        counts, runtime = process_tracks(conn, args.force)

        # Quick top-10 preview; the full breakdown is 'just language-breakdown'
        preview = conn.execute(
            """
            SELECT language, COUNT(*) as count
            FROM track_languages
            WHERE language IS NOT NULL
            GROUP BY language
            ORDER BY count DESC
            LIMIT 10
            """
        ).fetchall()

    print()
    print("=" * 50)
    print(
        f"Detected: {counts['detected']} "
        f"(low confidence: {counts['low_confidence']}), "
        f"undetectable: {counts['undetectable']}"
    )
    print(f"Completed in {runtime:.0f} seconds")
    print()
    print("Top languages:")
    for language, count in preview:
        print(f"  {language}: {count}")
    print()
    print("Full breakdown:")
    print("  just language-breakdown")


if __name__ == "__main__":
    main()
