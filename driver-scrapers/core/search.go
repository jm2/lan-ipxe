package core

import (
	"context"
	"fmt"
	"sync"
)

// SearchResult represents a candidate driver package found in the catalog.
type SearchResult struct {
	DevicePrefix string
	FamilyName   string
	Queries      []string
	Detail       *UpdateDetail
	Arch         string // Normalized to match ArchToCatalog output
}

// SearchDevice represents a single hardware target to search for.
type SearchDevice struct {
	Prefix            string
	HWID              string
	FamilyName        string
	Queries           []string
	PreferredBranches []string
}

// SearchConfig holds configuration for catalog search operations.
type SearchConfig struct {
	// AcceptedArchs are the architectures to accept (e.g., "AMD64", "ARM64")
	AcceptedArchs []string
	// DetailThrottle limits concurrent detail page fetches
	DetailThrottle int
	// ExcludeNDIS if true, excludes packages with "NDIS" in the title
	ExcludeNDIS bool
	// Progress channel for reporting search events
	Progress ProgressChan
}

// DefaultSearchConfig returns a SearchConfig with sensible defaults.
func DefaultSearchConfig() *SearchConfig {
	return &SearchConfig{
		DetailThrottle: 8,
		AcceptedArchs:  []string{"AMD64"},
		ExcludeNDIS:    false,
	}
}

// SearchDeviceWithContext searches the catalog for a single device and returns all matching results.
func SearchDeviceWithContext(ctx context.Context, client *CatalogClient, dev SearchDevice, cfg *SearchConfig) ([]*SearchResult, error) {
	var queries []string
	if len(dev.Queries) > 0 {
		queries = dev.Queries
	} else {
		queries = []string{dev.HWID + " Windows 11"}
	}

	var allResults []*SearchResult
	var wg sync.WaitGroup

	// Throttle detail page fetches globally
	sem := make(chan struct{}, cfg.DetailThrottle)

	for _, query := range queries {
		select {
		case <-ctx.Done():
			return allResults, ctx.Err()
		default:
		}

		// Report search start
		if cfg.Progress != nil {
			cfg.Progress.Send(ProgressEvent{
				Type:   EventDeviceSearchStart,
				Device: dev.Prefix,
				Status: fmt.Sprintf("Searching: %s", query),
			})
		}

		// Search the catalog
		updateIDs, err := client.Search(query)
		if err != nil {
			// Don't fail on single query error, try next query
			if cfg.Progress != nil {
				cfg.Progress.Send(ProgressEvent{
					Type:    EventDeviceSearchStart,
					Device:  dev.Prefix,
					Status:  "Search failed",
					Message: err.Error(),
				})
			}
			continue
		}

		if len(updateIDs) == 0 {
			continue
		}

		if cfg.Progress != nil {
			cfg.Progress.Send(ProgressEvent{
				Type:     EventDeviceSearchStart,
				Device:   dev.Prefix,
				Status:   fmt.Sprintf("Found %d packages", len(updateIDs)),
				Message:  fmt.Sprintf("Query: %s", query),
				Progress: 1.0,
			})
		}

		// Fetch details for each update ID in parallel (throttled)
		var detailResults []*SearchResult
		var detailMu sync.Mutex

		for _, id := range updateIDs {
			select {
			case <-ctx.Done():
				return allResults, ctx.Err()
			default:
			}

			sem <- struct{}{} // Acquire semaphore
			wg.Add(1)

			go func(updateID string) {
				defer wg.Done()
				<-sem // Release semaphore

				detail, err := client.GetDetail(updateID)
				if err != nil {
					return
				}

				if detail.Version == "" || detail.Date.IsZero() {
					return
				}

				// Check architecture
				if !contains(cfg.AcceptedArchs, detail.Arch) {
					return
				}

				// Check NDIS exclusion
				if cfg.ExcludeNDIS && detail.Title != "" && containsStr(detail.Title, "NDIS") {
					return
				}

				result := &SearchResult{
					DevicePrefix: dev.Prefix,
					FamilyName:   dev.FamilyName,
					Queries:      dev.Queries,
					Detail:       detail,
					Arch:         detail.Arch,
				}

				detailMu.Lock()
				detailResults = append(detailResults, result)
				detailMu.Unlock()
			}(id)
		}

		wg.Wait()
		allResults = append(allResults, detailResults...)
	}

	return allResults, nil
}

// SearchDevices searches the catalog for multiple devices concurrently.
func SearchDevices(ctx context.Context, client *CatalogClient, devices []SearchDevice, cfg *SearchConfig) (map[string][]*SearchResult, error) {
	results := make(map[string][]*SearchResult)
	var mu sync.Mutex
	var g errGroup

	for _, dev := range devices {
		dev := dev
		g.Go(func() error {
			devResults, err := SearchDeviceWithContext(ctx, client, dev, cfg)
			if err != nil {
				return err
			}
			mu.Lock()
			results[dev.Prefix] = devResults
			mu.Unlock()
			return nil
		})
	}

	return results, g.Wait()
}

// contains checks if a string slice contains a value.
func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}

// containsStr checks if a string contains a substring (case-insensitive).
func containsStr(s, substr string) bool {
	return len(s) > 0 && len(substr) > 0 && containsStrImpl(s, substr)
}

func containsStrImpl(s, substr string) bool {
	s = toLowerASCII(s)
	substr = toLowerASCII(substr)
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func toLowerASCII(s string) string {
	result := make([]byte, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			result[i] = c + 32
		} else {
			result[i] = c
		}
	}
	return string(result)
}

// errGroup is a simple error group similar to golang.org/x/sync/errgroup
// but without external dependencies for now.
type errGroup struct {
	errs []error
	mu   sync.Mutex
	wg   sync.WaitGroup
}

func (g *errGroup) Go(fn func() error) {
	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		if err := fn(); err != nil {
			g.mu.Lock()
			g.errs = append(g.errs, err)
			g.mu.Unlock()
		}
	}()
}

func (g *errGroup) Wait() error {
	g.wg.Wait()
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.errs) == 0 {
		return nil
	}
	return g.errs[0]
}
