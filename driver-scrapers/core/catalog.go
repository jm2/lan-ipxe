package core

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// CatalogClient handles communication with the Microsoft Update Catalog API.
type CatalogClient struct {
	client    *http.Client
	baseURL   string
	userAgent string
}

// NewCatalogClient creates a new Microsoft Update Catalog client.
func NewCatalogClient(timeout time.Duration) *CatalogClient {
	if timeout == 0 {
		timeout = 5 * time.Minute
	}
	return &CatalogClient{
		client: &http.Client{
			Timeout: timeout,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) >= 10 {
					return fmt.Errorf("too many redirects")
				}
				return nil
			},
		},
		baseURL:   "https://www.catalog.update.microsoft.com",
		userAgent: "LAN-iPXE-Driver-Scraper/1.0",
	}
}

// Search queries the catalog with a search query and returns matching update IDs.
func (c *CatalogClient) Search(query string) ([]string, error) {
	searchURL := fmt.Sprintf("%s/Search.aspx?q=%s", c.baseURL, url.QueryEscape(query))

	req, err := http.NewRequest("GET", searchURL, nil)
	if err != nil {
		return nil, fmt.Errorf("create search request: %w", err)
	}
	c.applyHeaders(req)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("search request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("search returned HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read search response: %w", err)
	}

	// Re-read body for parsing
	bodyStr := string(body)

	// Extract update IDs from the search results
	// Format: goToDetails('update-id-here')
	ids := extractUpdateIDs(bodyStr)
	if len(ids) == 0 {
		return nil, nil
	}

	return ids, nil
}

// GetDetail retrieves detailed information about a specific update.
func (c *CatalogClient) GetDetail(updateID string) (*UpdateDetail, error) {
	detailURL := fmt.Sprintf("%s/ScopedViewInline.aspx?updateid=%s", c.baseURL, updateID)

	req, err := http.NewRequest("GET", detailURL, nil)
	if err != nil {
		return nil, fmt.Errorf("create detail request for %s: %w", updateID, err)
	}
	c.applyHeaders(req)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("detail request failed for %s: %w", updateID, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("detail request returned HTTP %d for %s", resp.StatusCode, updateID)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read detail response for %s: %w", updateID, err)
	}

	bodyStr := string(body)

	detail := &UpdateDetail{
		UpdateID: updateID,
	}

	// Extract version
	if m := regexFindString(`id="ScopedViewHandler_version">\s*([^<]+)`, bodyStr); m != "" {
		detail.Version = strings.TrimSpace(m)
	}

	// Extract date
	if m := regexFindString(`id="ScopedViewHandler_versionDate">\s*([^<]+)`, bodyStr); m != "" {
		detail.DateString = strings.TrimSpace(m)
		detail.Date, _ = time.Parse("1/2/2006", m) // Format: M/D/YYYY
		if detail.Date.IsZero() {
			detail.Date, _ = time.Parse("2006-01-02", m) // Fallback: ISO format
		}
	}

	// Extract title
	if m := regexFindString(`id="ScopedViewHandler_titleText">\s*([^<]+)`, bodyStr); m != "" {
		detail.Title = strings.TrimSpace(m)
	}

	// Detect architecture from page content
	detail.Arch = detectArch(bodyStr)

	return detail, nil
}

// GetDownloadURL sends a POST to the download dialog and returns the CAB URL.
func (c *CatalogClient) GetDownloadURL(updateID string) (string, error) {
	downloadURL := fmt.Sprintf("%s/DownloadDialog.aspx", c.baseURL)

	// Build POST body - must be sent as form parameter "updateIDs"
	// See PowerShell: -Body @{updateIDs = $PostData}
	postData := fmt.Sprintf(`updateIDs=[{"size":0,"updateID":"%s","uidInfo":"%s"}]`, updateID, updateID)

	req, err := http.NewRequest("POST", downloadURL, strings.NewReader(postData))
	if err != nil {
		return "", fmt.Errorf("create download request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Referer", c.baseURL+"/")
	c.applyHeaders(r)
	resp, err := c.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("download request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download dialog returned HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read download response: %w", err)
	}

	bodyStr := string(body)

	// Extract the .cab URL from the response
	// The response contains a redirect or a dialog with the download URL
	cabURL := extractCabURL(bodyStr)
	if cabURL == "" {
		return "", fmt.Errorf("could not extract CAB URL from download dialog")
	}

	// Normalize relative URLs
	if strings.HasPrefix(cabURL, "/") {
		cabURL = "https://www.catalog.update.microsoft.com" + cabURL
	}

	return cabURL, nil
}

// applyHeaders adds standard headers to a request.
func (c *CatalogClient) applyHeaders(req *http.Request) {
	req.Header.Set("User-Agent", c.userAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	req.Header.Set("Accept-Language", "en-US,en;q=0.5")
	req.Header.Set("Referer", c.baseURL+"/")
}

// UpdateDetail holds parsed information about a catalog update.
type UpdateDetail struct {
	UpdateID   string
	Version    string
	DateString string
	Date       time.Time
	Title      string
	Arch       string // "AMD64", "ARM64", "x86"
}

// extractUpdateIDs extracts unique update IDs from catalog search results.
func extractUpdateIDs(html string) []string {
	seen := make(map[string]bool)
	var ids []string

	// Match goToDetails('uuid-here') or goToDetails("uuid-here")
	start := 0
	for {
		idx := strings.Index(html[start:], "goToDetails(")
		if idx == -1 {
			break
		}
		idx += start
		rest := html[idx+len("goToDetails("):]

		// Find the opening quote
		quoteStart := strings.IndexAny(rest, "'\"")
		if quoteStart == -1 {
			start = idx + 1
			continue
		}
		quoteChar := rest[quoteStart]
		rest = rest[quoteStart+1:]

		// Find the closing quote
		quoteEnd := strings.IndexRune(rest, rune(quoteChar))
		if quoteEnd == -1 {
			start = idx + 1
			continue
		}

		id := rest[:quoteEnd]
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}

		start = idx + len("goToDetails(") + quoteStart + 1 + quoteEnd + 1
	}

	return ids
}

// detectArch detects the architecture from catalog page content.
func detectArch(html string) string {
	// Check for ARM64 first (more specific)
	if strings.Contains(html, "ARM64") {
		return "ARM64"
	}
	// Check for AMD64/x64
	if strings.Contains(html, "AMD64") || strings.Contains(html, "x64") || strings.Contains(html, "amd64") {
		return "AMD64"
	}
	return "x86"
}

// extractCabURL extracts the .cab download URL from the download dialog response.
func extractCabURL(html string) string {
	// Match https://...*.cab patterns
	start := 0
	for {
		idx := strings.Index(html[start:], ".cab")
		if idx == -1 {
			break
		}

		// Look backwards from .cab to find the start of the URL
		cabEnd := idx + start + 4
		cabStart := cabEnd
		for cabStart > 0 {
			if html[cabStart-1] < ' ' || html[cabStart-1] == '"' || html[cabStart-1] == '\'' || html[cabStart-1] == '<' || html[cabStart-1] == '>' {
				break
			}
			cabStart--
		}

		// Check if it starts with http
		urlStr := html[cabStart:cabEnd]
		if strings.HasPrefix(urlStr, "http") {
			return urlStr
		}

		start = cabEnd
		if start >= len(html) {
			break
		}
	}

	return ""
}

// regexFindString compiles a regex pattern and returns the first match from the input string.
func regexFindString(pattern, input string) string {
	re, err := regexp.Compile(pattern)
	if err != nil {
		return ""
	}
	matches := re.FindStringSubmatch(input)
	if len(matches) < 2 {
		return ""
	}
	return matches[1]
}
