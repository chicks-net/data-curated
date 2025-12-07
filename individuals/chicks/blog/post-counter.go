package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
)

// PostCount represents the count of posts for a given month
type PostCount struct {
	Month string
	Count int
}

func main() {
	url := "https://www.chicks.net/posts/"

	// Fetch all posts (handle pagination)
	allDates, err := fetchAllPostDates(url)
	if err != nil {
		log.Fatalf("Error fetching posts: %v", err)
	}

	// Count posts per month
	monthlyCounts := countPostsByMonth(allDates)

	// Sort by month (chronological)
	var sorted []PostCount
	for month, count := range monthlyCounts {
		sorted = append(sorted, PostCount{Month: month, Count: count})
	}
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Month < sorted[j].Month
	})

	// Display results
	fmt.Println("Posts per Month:")
	fmt.Println("================")
	totalPosts := 0
	for _, pc := range sorted {
		fmt.Printf("%s: %d\n", pc.Month, pc.Count)
		totalPosts += pc.Count
	}
	fmt.Println("================")
	fmt.Printf("Total Posts: %d\n", totalPosts)
}

// fetchAllPostDates fetches all post dates from the blog, following pagination
func fetchAllPostDates(startURL string) ([]time.Time, error) {
	var allDates []time.Time
	currentURL := startURL
	visited := make(map[string]bool)

	for currentURL != "" && !visited[currentURL] {
		visited[currentURL] = true

		dates, nextURL, err := fetchPostDatesFromPage(currentURL)
		if err != nil {
			return nil, fmt.Errorf("error fetching page %s: %w", currentURL, err)
		}

		allDates = append(allDates, dates...)
		currentURL = nextURL

		if currentURL != "" {
			log.Printf("Following pagination to: %s", currentURL)
		}
	}

	return allDates, nil
}

// fetchPostDatesFromPage fetches post dates from a single page and returns the next page URL
func fetchPostDatesFromPage(url string) ([]time.Time, string, error) {
	log.Printf("Fetching: %s", url)
	resp, err := http.Get(url)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", err
	}

	html := string(body)

	// Extract dates using regex pattern
	// Looking for: "Month Day, Year" pattern
	datePattern := regexp.MustCompile(`\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2}),\s+(\d{4})\b`)
	matches := datePattern.FindAllStringSubmatch(html, -1)

	var dates []time.Time
	for _, match := range matches {
		if len(match) >= 4 {
			dateStr := fmt.Sprintf("%s %s, %s", match[1], match[2], match[3])
			t, err := time.Parse("January 2, 2006", dateStr)
			if err == nil {
				dates = append(dates, t)
			}
		}
	}

	log.Printf("Found %d dates on this page", len(dates))

	// Look for "Next »" pagination link
	nextURL := findNextPageURL(html, url)

	if nextURL != "" {
		log.Printf("Found next page: %s", nextURL)
	} else {
		log.Printf("No next page found (this is the last page)")
	}

	return dates, nextURL, nil
}

// findNextPageURL extracts the next page URL from pagination links
func findNextPageURL(html, baseURL string) string {
	// Try multiple patterns to find "Next" pagination link
	patterns := []string{
		// Pattern 1: Standard anchor with "Next" text (case-insensitive, flexible spacing)
		`(?i)<a[^>]+href="([^"]+)"[^>]*>Next\s*[»›&raquo;]`,
		`(?i)<a[^>]+href="([^"]+)"[^>]*>\s*Next\s*»`,
		// Pattern 2: Reverse order (href after content)
		`(?i)Next\s*[»›&raquo;][^<]*</a[^>]*>\s*<a[^>]+href="([^"]+)"`,
		// Pattern 3: Look for /posts/page/ URLs specifically
		`href="(/posts/page/\d+/)"`,
	}

	for _, pattern := range patterns {
		nextPattern := regexp.MustCompile(pattern)
		match := nextPattern.FindStringSubmatch(html)

		if len(match) >= 2 {
			nextPath := match[1]
			// Convert relative URL to absolute if needed
			if strings.HasPrefix(nextPath, "/") {
				return "https://www.chicks.net" + nextPath
			} else if strings.HasPrefix(nextPath, "http") {
				return nextPath
			} else {
				// Relative path from current page
				return baseURL + "/" + nextPath
			}
		}
	}

	return ""
}

// countPostsByMonth groups dates by month and counts them
func countPostsByMonth(dates []time.Time) map[string]int {
	counts := make(map[string]int)

	for _, date := range dates {
		monthKey := date.Format("2006-01") // Format as YYYY-MM for sorting
		counts[monthKey]++
	}

	return counts
}
