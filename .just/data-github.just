# github data recipes

# Fetch GitHub commit history for chicks-net
[working-directory("individuals/chicks/github")]
[group('github')]
fetch-commits:
	#!/usr/bin/env bash
	set -euo pipefail
	echo "Fetching GitHub commit history..."
	go run commit-history.go

# Fetch historical GitHub commits (2008-2019) via REST API
[working-directory("individuals/chicks/github")]
[group('github')]
fetch-historical-commits:
	#!/usr/bin/env bash
	set -euo pipefail
	echo "Fetching historical GitHub commits (2008-2019)..."
	go run historical-commits.go

[working-directory("individuals/chicks/github/commits-analysis")]
[group('github')]
analyze-commits:
	Rscript analyze-commits-by-hour.R
	Rscript analyze-emoji-usage.R

# Fetch GitHub contribution history for chicks-net
[working-directory("individuals/chicks/github")]
[group('github')]
fetch-contributions:
	#!/usr/bin/env bash
	set -euo pipefail
	echo "Fetching GitHub contribution history..."
	go run github-contributions.go

# Show contribution statistics
[working-directory("individuals/chicks/github")]
[group('github')]
_contribution-stats:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f contributions.db ]; then
		echo "Error: contributions.db not found. Run 'just fetch-contributions' first."
		exit 1
	fi
	sqlite3 contributions.db "SELECT
	  COUNT(DISTINCT date) as total_days,
	  SUM(contribution_count) as total_contributions,
	  MAX(contribution_count) as max_day,
	  ROUND(AVG(contribution_count), 2) as avg_per_day,
	  MIN(date) as earliest_date,
	  MAX(date) as latest_date
	FROM contributions;"

# Show monthly contribution totals
[working-directory("individuals/chicks/github")]
[group('github')]
contribution-monthly MONTHS="24":
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f contributions.db ]; then
		echo "Error: contributions.db not found. Run 'just fetch-contributions' first."
		exit 1
	fi
	echo "Monthly Contribution Summary (last {{MONTHS}} months)"
	echo ""
	sqlite3 -header -column contributions.db "WITH latest_contributions AS (
	  SELECT
	    date,
	    MAX(contribution_count) as contribution_count
	  FROM contributions
	  GROUP BY date
	),
	monthly_stats AS (
	  SELECT
	    strftime('%Y-%m', date) as month,
	    SUM(contribution_count) as total,
	    ROUND(AVG(contribution_count), 1) as daily_avg,
	    MAX(contribution_count) as peak_day,
	    COUNT(DISTINCT CASE WHEN contribution_count > 0 THEN date END) as active_days,
	    -- Only count inactive days up to today for current month
	    COUNT(DISTINCT CASE
	      WHEN contribution_count = 0 AND date < date('now')
	      THEN date
	    END) as inactive_days
	  FROM latest_contributions
	  GROUP BY month
	)
	SELECT
	  month,
	  total,
	  daily_avg,
	  peak_day,
	  active_days,
	  -- For current month, calculate total days as active_days + inactive_days
	  -- For past months, use fixed day counts
	  CASE
	    WHEN month = strftime('%Y-%m', 'now')
	    THEN active_days + COALESCE(inactive_days, 0)
	    ELSE (
	      CASE
	        WHEN month = strftime('%Y-%m', date('now', 'start of month', '-1 month'))
	        THEN strftime('%d', date('now', 'start of month', '-1 day'))
	        ELSE strftime('%d', date(month || '-01', 'start of month', '+1 month', '-1 day'))
	      END
	    )
	  END as total_days,
	  inactive_days
	FROM monthly_stats
	ORDER BY month DESC
	LIMIT {{MONTHS}};"

# Show longest contribution streaks
[working-directory("individuals/chicks/github")]
[group('github')]
contribution-streaks LIMIT="10":
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f contributions.db ]; then
		echo "Error: contributions.db not found. Run 'just fetch-contributions' first."
		exit 1
	fi
	echo "Longest Contribution Streaks (top {{LIMIT}})"
	echo ""
	sqlite3 -header -column contributions.db "WITH distinct_days AS (
	  SELECT DISTINCT date
	  FROM contributions
	  WHERE contribution_count > 0
	  ORDER BY date
	),
	gaps AS (
	  SELECT
	    date,
	    LAG(date) OVER (ORDER BY date) as prev_date,
	    CASE
	      WHEN julianday(date) - julianday(LAG(date) OVER (ORDER BY date)) = 1 THEN 0
	      ELSE 1
	    END as is_new_streak
	  FROM distinct_days
	),
	streak_groups AS (
	  SELECT
	    date,
	    SUM(is_new_streak) OVER (ORDER BY date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as streak_id
	  FROM gaps
	)
	SELECT
	  MIN(date) as streak_start,
	  MAX(date) as streak_end,
	  COUNT(*) as days
	FROM streak_groups
	GROUP BY streak_id
	HAVING COUNT(*) > 1
	ORDER BY days DESC
	LIMIT {{LIMIT}};"

# Github update cycle (once you are on a branch)
[group('github')]
github-update-all: _on_a_branch
	just fetch-comments
	just fetch-commits
	just analyze-commits
	just fetch-contributions
	just analyze-contributions
	git add individuals/chicks/github
	git stp
	just db-status

# Github update for CI (skips branch check)
_github-update-ci:
	just fetch-comments
	just fetch-commits
	just analyze-commits
	just fetch-contributions
	just analyze-contributions
	git add individuals/chicks/github
	git status --porcelain

# View commits in Datasette
[group('github')]
commits-db:
	just datasette individuals/chicks/github/commits.db

# View contributions in Datasette
[group('github')]
contributions-db:
	just datasette individuals/chicks/github/contributions.db

# Analyze GitHub contribution trends with visualizations
[working-directory("individuals/chicks/github/contributions-analysis")]
[group('github')]
analyze-contributions:
	Rscript analyze-contributions.R

# Convert LinearWalkthrough.md to PDF with proper code formatting
[working-directory("individuals/chicks/github/contributions-analysis")]
[group('github')]
walkthrough-pdf:
	pandoc LinearWalkthrough.md -o LinearWalkthrough.pdf --pdf-engine=xelatex -V mainfont="Helvetica" -V geometry:margin=0.75in -V monofont="FiraCode Nerd Font Mono" --syntax-highlighting=idiomatic -H <(printf '\\usepackage{listings}\n\\lstset{breaklines=true,basicstyle=\\ttfamily\\small,columns=flexible}')

# Download a repo and look at the top contributors to see if it is worth making into a movie.
[group('github')]
repo-preview repo:
	#!/usr/bin/env bash
	set -euo pipefail

	cd ~/Documents/git/OtherFolks

	repo_basename=$(basename "{{ repo }}" | sed -e 's/[.]git$//')

	if [[ -d "$repo_basename" ]]; then
		echo "{{BLUE}}repo exists, pull the latest{{NORMAL}}"
		cd "$repo_basename"
		git pull
	else
		git clone "{{ repo }}"
		cd "$repo_basename"
	fi

	echo "{{BLUE}}fetch tags...{{NORMAL}}"
	git fetch --tags
	echo "$(pwd) $(du -shx .)"
	repo_dir=$(pwd)
	repo_branch=$(git rev-parse --abbrev-ref HEAD)
	cd ~/Documents/git/data-curated

	echo "{{BLUE}}calculate daily rankings...{{NORMAL}}"
	ranking_json="/tmp/${repo_basename}.jsonl"
	time just daily-ranking "$repo_dir" "$ranking_json" "$repo_branch"

	just daily-ranking-viewer "$ranking_json"

# Generate an mp4 based on the Linux repo
[group('github')]
repo-to-movie repo logo:
	#!/usr/bin/env bash
	set -euo pipefail

	cd ~/Documents/git/OtherFolks

	repo_basename=$(basename "{{ repo }}" | sed -e 's/[.]git$//')

	if [[ -d "$repo_basename" ]]; then
		echo "{{BLUE}}repo exists, pull the latest{{NORMAL}}"
		cd "$repo_basename"
		git pull
	else
		git clone "{{ repo }}"
		cd "$repo_basename"
	fi

	echo "{{BLUE}}fetch tags...{{NORMAL}}"
	git fetch --tags
	echo "$(pwd) $(du -shx .)"
	repo_dir=$(pwd)
	repo_branch=$(git rev-parse --abbrev-ref HEAD)
	cd ~/Documents/git/data-curated

	echo "{{BLUE}}calculate daily rankings...{{NORMAL}}"
	ranking_json="/tmp/${repo_basename}.jsonl"
	time just daily-ranking "$repo_dir" "$ranking_json" "$repo_branch"

	echo "{{BLUE}}generate first animated GIF...{{NORMAL}}"
	cast_filename="/tmp/${repo_basename}.cast"
	gif1_filename="/tmp/${repo_basename}.gif"

	if [[ -e "$cast_filename" ]]; then
		rm "$cast_filename"
	fi
	if [[ -e "$gif1_filename" ]]; then
		rm "$gif1_filename"
	fi
	asciinema record -c "just daily-ranking-viewer $ranking_json" "$cast_filename"
	agg --speed 4 "$cast_filename" "$gif1_filename"

	echo "{{BLUE}}generate mp4...{{NORMAL}}"
	mp4_filename="/tmp/${repo_basename}.mp4"
	gif2_filename="/tmp/${repo_basename}-from-mp4.gif"

	if [[ -e "$mp4_filename" ]]; then
		rm "$mp4_filename"
	fi
	ffmpeg -i "$gif1_filename" -i "{{ logo }}" -filter_complex "[0:v]scale=3840:2160:flags=lanczos,format=yuv420p[bg];[bg][1:v]overlay=W-w-10:H-h-10" -movflags faststart "$mp4_filename"
	exiftool "$mp4_filename"

	echo "{{BLUE}}generate second animated GIF...{{NORMAL}}"
	if [[ -e "$gif2_filename" ]]; then
		rm "$gif2_filename"
	fi
	ffmpeg -i "$mp4_filename" -vf "scale=iw/2:ih/2:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" "$gif2_filename"

	echo "{{BLUE}}Done!{{NORMAL}}"

# Generate daily contributor rankings from a git repository
# Use BRANCH="main" to analyze only the main branch (matches GitHub Contributors)
[working-directory("individuals/github-contrib/daily-ranking")]
[group('github')]
daily-ranking DIR OUTPUT="" BRANCH="":
	#!/usr/bin/env bash
	set -euo pipefail

	# Check if go is installed using helper
	INSTALL_CMD=$(just _get_install_cmd go golang-go)
	just _require_command go "Install with:\n  $INSTALL_CMD\n  Or see: https://go.dev/doc/install"

	if [ ! -d "{{DIR}}/.git" ]; then
		echo "{{RED}}Error: {{DIR}} is not a git repository{{NORMAL}}"
		exit 1
	fi

	OUTPUT="{{OUTPUT}}"
	BRANCH="{{BRANCH}}"

	if [ -n "$BRANCH" ]; then
		if [ -n "$OUTPUT" ]; then
			go run daily-ranking.go -branch "$BRANCH" "{{DIR}}" "$OUTPUT"
		else
			go run daily-ranking.go -branch "$BRANCH" "{{DIR}}"
		fi
	else
		if [ -n "$OUTPUT" ]; then
			go run daily-ranking.go "{{DIR}}" "$OUTPUT"
		else
			go run daily-ranking.go "{{DIR}}"
		fi
	fi

# View daily contributor rankings with animated TUI (reads JSON from stdin or file)
# Usage: just daily-ranking DIR | just daily-ranking-viewer
#        just daily-ranking-viewer rankings.jsonl
#        just daily-ranking-viewer -n 15 -speed 1s rankings.jsonl
[group('github')]
daily-ranking-viewer filename:
	#!/usr/bin/env bash
	set -euo pipefail

	# Check if go is installed
	INSTALL_CMD=$(just _get_install_cmd go golang-go)
	just _require_command go "Install with:\n  $INSTALL_CMD\n  Or see: https://go.dev/doc/install"

	cd individuals/github-contrib/daily-ranking-viewer
	set -x
	go run . "{{ filename }}"

# Fetch GitHub comments on external projects
[working-directory("individuals/chicks/github")]
[group('github')]
fetch-comments:
	go run comment-fetcher.go

# Show comment statistics
[working-directory("individuals/chicks/github")]
[group('github')]
_comment-stats:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f comments.db ]; then
		echo "Error: comments.db not found. Run 'just fetch-comments' first."
		exit 1
	fi
	echo "Comment statistics (external projects only):"
	echo ""
	sqlite3 comments.db "SELECT
	  comment_type,
	  COUNT(*) as total_comments,
	  COUNT(DISTINCT repo_full_name) as repos,
	  MIN(created_at) as earliest,
	  MAX(created_at) as latest
	FROM comments
	WHERE is_own_org = 0
	GROUP BY comment_type
	ORDER BY comment_type;"

# View comments in Datasette
[group('github')]
comments-db:
	just datasette individuals/chicks/github/comments.db

# Analyze code review bot coverage across all repos
[working-directory("individuals/chicks/github")]
[group('github')]
review-coverage:
	go run review-coverage.go

# Analyze bot review coverage over time
[working-directory("individuals/chicks/github/reviews-analysis")]
[group('github')]
analyze-reviews:
	Rscript analyze-reviews.R

# Analyze bot review timing (how long it takes each bot to review)
[working-directory("individuals/chicks/github/reviews-analysis")]
[group('github')]
analyze-review-timing:
	Rscript analyze-review-timing.R

# View review coverage database in Datasette
[group('github')]
reviews-db:
	just datasette individuals/chicks/github/reviews.db

# List releases from chicks-net and fini-net repos in the last N days
# Output: ISO date <TAB> release URL, sorted newest first
[group('github')]
list-releases DAYS="7":
	#!/usr/bin/env bash
	set -euo pipefail

	# Check for required commands
	just _require_command gh "Install gh CLI: https://cli.github.com/"
	just _require_command jq "Install jq: https://stedolan.github.io/jq/download/"

	DAYS="{{DAYS}}"

	# Compute cutoff timestamp (portable for both GNU and BSD date)
	if date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
		CUTOFF=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
	else
		CUTOFF=$(date -u -v-"${DAYS}d" +%Y-%m-%dT%H:%M:%SZ)
	fi

	echo "Releases in the last ${DAYS} days (since ${CUTOFF})"
	echo ""

	for org in chicks-net fini-net; do
		gh repo list "$org" --json nameWithOwner --limit 200 --jq '.[].nameWithOwner' 2>/dev/null | while read -r repo; do
			gh release list -R "$repo" --json tagName,publishedAt --limit 50 2>/dev/null \
				| jq -r --arg cutoff "$CUTOFF" --arg repo "$repo" \
					'.[] | select(.publishedAt != null and .publishedAt >= $cutoff) | "\(.publishedAt)\thttps://github.com/\($repo)/releases/tag/\(.tagName)"' 2>/dev/null || true
		done
	done | sort -r
