package main

import (
	"database/sql"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
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
	// Regex for extracting hashtags
	hashtagRegex = regexp.MustCompile(`#\w+`)
)

type Video struct {
	VideoID      string
	Title        string
	Description  string
	UploadDate   string
	URL          string
	ThumbnailURL string
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
		SELECT video_id, title, description, upload_date, url, thumbnail_url
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
		err := rows.Scan(&v.VideoID, &v.Title, &v.Description, &v.UploadDate, &v.URL, &v.ThumbnailURL)
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

		// Extract keywords from hashtags in description
		keywords := extractKeywords(video.Description)

		// Fill in template
		// Note: Escape single quotes for TOML single-quoted strings
		content := template
		content = strings.ReplaceAll(content, "${TITLE}", escapeTOMLString(video.Title))
		content = strings.ReplaceAll(content, "${POST_DATE_ISO}", dateISO)
		content = strings.ReplaceAll(content, "${SOMETHING_FUNNY}", escapeTOMLString(funnyDescription))
		content = strings.ReplaceAll(content, "${YOUTUBE_URL}", video.URL)
		content = strings.ReplaceAll(content, "${FILENAME}", filename)
		content = strings.ReplaceAll(content, "${YOUTUBE_DESCRIPTION}", video.Description)
		content = strings.ReplaceAll(content, "${YOUTUBE_ID}", video.VideoID)
		content = strings.ReplaceAll(content, "${KEYWORDS_LIST}", keywords)

		outputPath := filepath.Join(outputDir, filename+".md")
		imagePath := filepath.Join(outputDir, filename+".jpg")

		fmt.Printf("- %s (%s)\n", video.Title, video.UploadDate)
		fmt.Printf("  → %s\n", outputPath)
		fmt.Printf("  → %s\n", imagePath)

		if *dryRun {
			fmt.Println("  [DRY RUN] Would create file with content:")
			fmt.Println("  ---")
			fmt.Println(indent(content, "  "))
			fmt.Println("  ---")
			fmt.Printf("  [DRY RUN] Would download thumbnail from: %s\n", video.ThumbnailURL)
			fmt.Println()
		} else {
			// Write markdown file
			if err := os.WriteFile(outputPath, []byte(content), 0644); err != nil {
				log.Printf("Error writing %s: %v", outputPath, err)
			} else {
				fmt.Printf("  ✓ Created %s\n", outputPath)
			}

			// Download thumbnail
			if video.ThumbnailURL != "" {
				if err := downloadThumbnail(video.ThumbnailURL, imagePath); err != nil {
					log.Printf("Error downloading thumbnail: %v", err)
				} else {
					fmt.Printf("  ✓ Downloaded cover image to %s\n", imagePath)
				}
			} else {
				log.Printf("Warning: No thumbnail URL for video %s", video.VideoID)
			}
			fmt.Println()
		}
	}

	if *dryRun {
		fmt.Println("Dry run complete. Run without --dry-run to generate files.")
	} else {
		fmt.Printf("Generated %d blog post(s) in %s/\n", len(videos), outputDir)
	}
}

// escapeTOMLString escapes single quotes for TOML single-quoted strings
// In TOML, single quotes inside a single-quoted string are escaped as ''
func escapeTOMLString(s string) string {
	return strings.ReplaceAll(s, "'", "''")
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

// extractKeywords extracts hashtags from text and returns them as a quoted list
func extractKeywords(text string) string {
	matches := hashtagRegex.FindAllString(text, -1)
	if len(matches) == 0 {
		return ""
	}

	// Strip # prefix and quote each keyword
	keywords := make([]string, len(matches))
	for i, match := range matches {
		// Remove # prefix and wrap in quotes
		keywords[i] = fmt.Sprintf(`"%s"`, strings.TrimPrefix(match, "#"))
	}

	return strings.Join(keywords, ", ")
}

// indent adds a prefix to each line of text
func indent(text, prefix string) string {
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		lines[i] = prefix + line
	}
	return strings.Join(lines, "\n")
}

// downloadThumbnail downloads a thumbnail from a URL and saves it to the specified path
func downloadThumbnail(url, outputPath string) error {
	// Create HTTP GET request
	resp, err := http.Get(url)
	if err != nil {
		return fmt.Errorf("failed to download thumbnail: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("bad status: %s", resp.Status)
	}

	// Create output file
	out, err := os.Create(outputPath)
	if err != nil {
		return fmt.Errorf("failed to create file: %w", err)
	}
	defer out.Close()

	// Copy data
	_, err = io.Copy(out, resp.Body)
	if err != nil {
		return fmt.Errorf("failed to write file: %w", err)
	}

	return nil
}
