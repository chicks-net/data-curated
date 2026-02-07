package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

var (
	// Regex for filename sanitization
	filenameRegex = regexp.MustCompile(`[^a-z0-9]+`)
)

type Video struct {
	VideoID     string
	Title       string
	Description string
	UploadDate  string
	URL         string
}

func main() {
	dryRun := flag.Bool("dry-run", false, "Show what would be generated without writing files")
	flag.Parse()

	// Calculate date 6 months ago
	sixMonthsAgo := time.Now().AddDate(0, -6, 0).Format("20060102")

	// Open database
	db, err := sql.Open("sqlite3", "videos.db")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	// Query for videos without blog posts that are at least 6 months old
	query := `
		SELECT video_id, title, description, upload_date, url
		FROM videos
		WHERE (blog_url IS NULL OR blog_url = '')
		AND upload_date <= ?
		ORDER BY upload_date
	`

	rows, err := db.Query(query, sixMonthsAgo)
	if err != nil {
		log.Fatal(err)
	}
	defer rows.Close()

	var videos []Video
	for rows.Next() {
		var v Video
		err := rows.Scan(&v.VideoID, &v.Title, &v.Description, &v.UploadDate, &v.URL)
		if err != nil {
			log.Fatal(err)
		}
		videos = append(videos, v)
	}
	if err := rows.Err(); err != nil {
		log.Fatal(err)
	}

	if len(videos) == 0 {
		fmt.Println("No videos found that need blog posts.")
		return
	}

	fmt.Printf("Found %d video(s) without blog posts from at least 6 months ago:\n\n", len(videos))

	// Read template
	templateBytes, err := os.ReadFile("template.md")
	if err != nil {
		log.Fatalf("Failed to read template.md: %v", err)
	}
	template := string(templateBytes)

	// Create output directory
	outputDir := "generated"
	if !*dryRun {
		if err := os.MkdirAll(outputDir, 0755); err != nil {
			log.Fatalf("Failed to create output directory: %v", err)
		}
	}

	// Generate blog posts
	for _, video := range videos {
		// Parse upload date (YYYYMMDD)
		uploadTime, err := time.Parse("20060102", video.UploadDate)
		if err != nil {
			log.Printf("Warning: Could not parse date for %s: %v", video.VideoID, err)
			continue
		}

		// Format date as ISO 8601 (date only, since upload_date is date-only)
		dateISO := uploadTime.Format("2006-01-02")

		// Create filename with date prefix (YYYY-MM-DD-title)
		datePrefix := uploadTime.Format("2006-01-02")
		titleSlug := createFilename(video.Title)
		filename := datePrefix + "-" + titleSlug

		// Generate a simple description
		funnyDescription := fmt.Sprintf("A video about %s", strings.ToLower(video.Title))

		// Fill in template
		content := template
		content = strings.ReplaceAll(content, "${TITLE}", video.Title)
		content = strings.ReplaceAll(content, "${POST_DATE_ISO}", dateISO)
		content = strings.ReplaceAll(content, "${SOMETHING_FUNNY}", funnyDescription)
		content = strings.ReplaceAll(content, "${YOUTUBE_URL}", video.URL)
		content = strings.ReplaceAll(content, "${FILENAME}", filename)
		content = strings.ReplaceAll(content, "${YOUTUBE_DESCRIPTION}", video.Description)
		content = strings.ReplaceAll(content, "${YOUTUBE_ID}", video.VideoID)

		outputPath := filepath.Join(outputDir, filename+".md")

		fmt.Printf("- %s (%s)\n", video.Title, video.UploadDate)
		fmt.Printf("  → %s\n", outputPath)

		if *dryRun {
			fmt.Println("  [DRY RUN] Would create file with content:")
			fmt.Println("  ---")
			fmt.Println(indent(content, "  "))
			fmt.Println("  ---")
			fmt.Println()
		} else {
			if err := os.WriteFile(outputPath, []byte(content), 0644); err != nil {
				log.Printf("Error writing %s: %v", outputPath, err)
			} else {
				fmt.Printf("  ✓ Created %s\n\n", outputPath)
			}
		}
	}

	if *dryRun {
		fmt.Println("Dry run complete. Run without --dry-run to generate files.")
	} else {
		fmt.Printf("Generated %d blog post(s) in %s/\n", len(videos), outputDir)
	}
}

// createFilename converts a title to a safe filename
func createFilename(title string) string {
	// Convert to lowercase
	filename := strings.ToLower(title)

	// Replace spaces and special chars with hyphens
	filename = filenameRegex.ReplaceAllString(filename, "-")

	// Remove leading/trailing hyphens
	filename = strings.Trim(filename, "-")

	// Limit length
	if len(filename) > 60 {
		filename = filename[:60]
		filename = strings.TrimRight(filename, "-")
	}

	return filename
}

// indent adds a prefix to each line of text
func indent(text, prefix string) string {
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		lines[i] = prefix + line
	}
	return strings.Join(lines, "\n")
}
