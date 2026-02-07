package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	_ "github.com/mattn/go-sqlite3"
)

const (
	dbPath        = "videos.db"
	githubRepo    = "chicks-net/www-chicks-net"
	repoURL       = "https://github.com/chicks-net/www-chicks-net.git"
	postsPath     = "content/posts"
	blogBaseURL   = "https://www.chicks.net"
	tempRepoPath  = "/tmp/www-chicks-net-blog-linker"
)

// Video represents a video record from the database
type Video struct {
	VideoID    string
	Title      string
	UploadDate string
	URL        string
}

var (
	dryRun  = flag.Bool("dry-run", false, "Show what would be updated without making changes")
	verbose = flag.Bool("verbose", false, "Enable verbose logging")
)

func main() {
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.Lshortfile)

	// Clone or update repository
	fmt.Println("Cloning/updating blog repository...")
	if err := cloneOrUpdateRepo(); err != nil {
		log.Fatalf("Failed to clone/update repository: %v", err)
	}
	fmt.Println()

	// Open database
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer db.Close()

	// Get videos without blog URLs
	videos, err := getVideosWithoutBlogURL(db)
	if err != nil {
		log.Fatalf("Failed to query videos: %v", err)
	}

	if len(videos) == 0 {
		fmt.Println("No videos found without blog URLs")
		return
	}

	fmt.Printf("Found %d videos without blog URLs\n", len(videos))
	if *dryRun {
		fmt.Println("DRY RUN MODE - No changes will be made")
	}
	fmt.Println()

	// Get list of blog posts
	postsDir := filepath.Join(tempRepoPath, postsPath)
	files, err := getBlogPostFiles(postsDir)
	if err != nil {
		log.Fatalf("Failed to read blog posts: %v", err)
	}

	fmt.Printf("Found %d blog posts to search\n\n", len(files))

	// Process each video
	matched := 0
	var unmatched []Video
	for i, video := range videos {
		if *verbose {
			fmt.Printf("[%d/%d] Processing: %s (%s)\n", i+1, len(videos), video.VideoID, video.Title)
		}

		blogURL, postName, err := findBlogPost(video.VideoID, files)
		if err != nil {
			if *verbose {
				log.Printf("Error searching for %s: %v", video.VideoID, err)
			}
			unmatched = append(unmatched, video)
			continue
		}

		if blogURL != "" {
			matched++
			fmt.Printf("✓ Found match for '%s'\n", video.Title)
			fmt.Printf("  Video ID: %s\n", video.VideoID)
			fmt.Printf("  Blog post: %s\n", postName)
			fmt.Printf("  URL: %s\n", blogURL)

			if !*dryRun {
				err = updateBlogURL(db, video.VideoID, blogURL)
				if err != nil {
					log.Printf("Failed to update database for %s: %v", video.VideoID, err)
				} else {
					fmt.Println("  ✓ Database updated")
				}
			}
			fmt.Println()
		} else {
			unmatched = append(unmatched, video)
		}
	}

	fmt.Printf("\n" + strings.Repeat("=", 50) + "\n")
	fmt.Printf("Summary: Matched %d out of %d videos\n", matched, len(videos))
	if *dryRun {
		fmt.Println("Run without --dry-run to update the database")
	}

	// Show unmatched videos
	if len(unmatched) > 0 {
		fmt.Printf("\n" + strings.Repeat("=", 50) + "\n")
		fmt.Printf("Videos without blog posts (%d):\n\n", len(unmatched))
		for _, video := range unmatched {
			// Format upload date as YYYY-MM-DD
			dateStr := video.UploadDate
			if len(dateStr) == 8 {
				dateStr = fmt.Sprintf("%s-%s-%s", dateStr[0:4], dateStr[4:6], dateStr[6:8])
			}

			// Truncate title to 50 characters
			title := video.Title
			if len(title) > 50 {
				title = title[:47] + "..."
			}

			fmt.Printf("%s  %-50s  %s\n", dateStr, title, video.URL)
		}
	}
}

// getVideosWithoutBlogURL returns all videos that don't have a blog_url set
func getVideosWithoutBlogURL(db *sql.DB) ([]Video, error) {
	query := `SELECT video_id, title, upload_date, url FROM videos WHERE blog_url IS NULL OR blog_url = '' ORDER BY upload_date DESC`
	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var videos []Video
	for rows.Next() {
		var v Video
		if err := rows.Scan(&v.VideoID, &v.Title, &v.UploadDate, &v.URL); err != nil {
			return nil, err
		}
		videos = append(videos, v)
	}

	return videos, rows.Err()
}

// cloneOrUpdateRepo clones or updates the blog repository
func cloneOrUpdateRepo() error {
	// Check if repo already exists
	if _, err := os.Stat(tempRepoPath); err == nil {
		// Repo exists, pull latest changes
		if *verbose {
			fmt.Println("Repository exists, pulling latest changes...")
		}
		cmd := exec.Command("git", "-C", tempRepoPath, "pull", "--quiet")
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to pull repo: %w\nOutput: %s", err, output)
		}
		return nil
	}

	// Clone repo
	if *verbose {
		fmt.Println("Cloning repository...")
	}
	cmd := exec.Command("git", "clone", "--depth", "1", "--single-branch", "--branch", "main", repoURL, tempRepoPath)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to clone repo: %w\nOutput: %s", err, output)
	}

	return nil
}

// getBlogPostFiles returns all markdown files in the posts directory
func getBlogPostFiles(postsDir string) ([]string, error) {
	var files []string

	entries, err := os.ReadDir(postsDir)
	if err != nil {
		return nil, fmt.Errorf("failed to read posts directory: %w", err)
	}

	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".md") {
			files = append(files, entry.Name())
		}
	}

	return files, nil
}

// findBlogPost searches blog posts for a video ID and returns the blog URL if found
func findBlogPost(videoID string, fileNames []string) (string, string, error) {
	// Pattern to match YouTube URLs in blog posts
	patterns := []*regexp.Regexp{
		regexp.MustCompile(fmt.Sprintf(`youtube\.com/watch\?v=%s`, regexp.QuoteMeta(videoID))),
		regexp.MustCompile(fmt.Sprintf(`youtube\.com/shorts/%s`, regexp.QuoteMeta(videoID))),
		regexp.MustCompile(fmt.Sprintf(`youtu\.be/%s`, regexp.QuoteMeta(videoID))),
	}

	postsDir := filepath.Join(tempRepoPath, postsPath)

	for _, fileName := range fileNames {
		filePath := filepath.Join(postsDir, fileName)

		// Read file content
		content, err := os.ReadFile(filePath)
		if err != nil {
			if *verbose {
				log.Printf("Failed to read %s: %v", fileName, err)
			}
			continue
		}

		contentStr := string(content)

		// Check if video ID is in the content
		found := false
		for _, pattern := range patterns {
			if pattern.MatchString(contentStr) {
				found = true
				break
			}
		}

		if found {
			blogURL := convertFileNameToBlogURL(fileName)
			return blogURL, fileName, nil
		}
	}

	return "", "", nil
}

// convertFileNameToBlogURL converts a blog post filename to its URL
// Example: 2024-07-22-first-youtube-short.md -> https://www.chicks.net/2024/07/22/first-youtube-short/
func convertFileNameToBlogURL(filename string) string {
	// Remove .md extension
	name := strings.TrimSuffix(filename, ".md")

	// Handle different date formats
	// Format 1: YYYY-MM-DD-title.md
	re1 := regexp.MustCompile(`^(\d{4})-(\d{2})-(\d{2})-(.+)$`)
	if matches := re1.FindStringSubmatch(name); matches != nil {
		year, month, day, slug := matches[1], matches[2], matches[3], matches[4]
		return fmt.Sprintf("%s/%s/%s/%s/%s/", blogBaseURL, year, month, day, slug)
	}

	// Format 2: YYYY-MM-DD_HH:MM:SS_title.md (LinkedIn style)
	re2 := regexp.MustCompile(`^(\d{4})-(\d{2})-(\d{2})_[\d:]+_(.+)$`)
	if matches := re2.FindStringSubmatch(name); matches != nil {
		year, month, day, slug := matches[1], matches[2], matches[3], matches[4]
		return fmt.Sprintf("%s/%s/%s/%s/%s/", blogBaseURL, year, month, day, slug)
	}

	// Fallback: just use the filename as slug (shouldn't happen with proper blog post format)
	return fmt.Sprintf("%s/posts/%s/", blogBaseURL, name)
}

// updateBlogURL updates the blog_url for a video in the database
func updateBlogURL(db *sql.DB, videoID, blogURL string) error {
	query := `UPDATE videos SET blog_url = ? WHERE video_id = ?`
	_, err := db.Exec(query, blogURL, videoID)
	return err
}
