package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/gitgerby/lan-ipxe/driver-scrapers/core"
	"github.com/gitgerby/lan-ipxe/driver-scrapers/providers"
	"github.com/gitgerby/lan-ipxe/driver-scrapers/tui"
)

var version = "dev"

func main() {
	// Parse flags
	arch := flag.String("arch", "x64", "Target architecture (x64, arm64, all)")
	output := flag.String("output", "./drivers", "Download output directory")
	providersFlag := flag.String("providers", "all", "Comma-separated list of providers to run (intel-eth, intel-wifi, marvell, realtek, qualcomm, mediatek)")
	noDownload := flag.Bool("no-download", false, "Search only, skip download and extraction")
	noExtract := flag.Bool("no-extract", false, "Download but skip CAB extraction")
	noTUI := flag.Bool("no-tui", false, "Plain text output instead of TUI")
	workers := flag.Int("workers", runtime.NumCPU(), "Max concurrent downloads")
	detailThrottle := flag.Int("detail-throttle", 8, "Max concurrent detail page fetches")
	timeout := flag.Duration("timeout", 5*time.Minute, "Request timeout per operation")
	verbose := flag.Bool("verbose", false, "Enable debug logging")
	showVersion := flag.Bool("version", false, "Show version")
	flag.Parse()

	if *showVersion {
		fmt.Println("driver-scrape", version)
		os.Exit(0)
	}

	// Validate architecture
	archVal, err := core.ValidateArch(*arch)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// Build accepted architectures list
	var acceptedArchs []string
	switch archVal {
	case core.ArchX64:
		acceptedArchs = []string{"AMD64"}
	case core.ArchARM64:
		acceptedArchs = []string{"ARM64"}
	case core.ArchAll:
		acceptedArchs = []string{"AMD64", "ARM64"}
	}

	// Parse providers list
	providerKeys := parseProviders(*providersFlag)

	// Convert output to absolute path so all derived paths work correctly
	if absOutput, err := filepath.Abs(*output); err == nil {
		*output = absOutput
	}

	// Create output directory
	if err := core.EnsureDir(*output); err != nil {
		fmt.Fprintf(os.Stderr, "Error creating output directory: %v\n", err)
		os.Exit(1)
	}

	// Build provider map
	allProviders := buildProviderMap()
	selectedProviders := make([]core.DriverProvider, 0)
	for _, key := range providerKeys {
		p, ok := allProviders[key]
		if !ok {
			fmt.Fprintf(os.Stderr, "Error: unknown provider '%s'\n", key)
			fmt.Fprintf(os.Stderr, "Available providers: %s\n", strings.Join(providerKeysList(allProviders), ", "))
			os.Exit(1)
		}
		selectedProviders = append(selectedProviders, p)
	}

	// Create progress channel
	progressChan := make(core.ProgressChan, 64)

	// Create orchestrator config
	cfg := &core.OrchestratorConfig{
		AcceptedArchs:  acceptedArchs,
		OutputDir:      *output,
		DetailThrottle: *detailThrottle,
		MaxDownloads:   *workers,
		NoDownload:     *noDownload,
		NoExtract:      *noExtract,
		Timeout:        int(timeout.Seconds()),
		Verbose:        *verbose,
	}

	// Run TUI or plain output in a goroutine and wait for it to finish
	tuiDone := make(chan struct{})
	go func() {
		if *noTUI {
			runPlainOutput(progressChan, selectedProviders)
		} else {
			runTUI(progressChan)
		}
		close(tuiDone)
	}()

	// Give the TUI a moment to set up before providers start
	time.Sleep(100 * time.Millisecond)

	// Run providers concurrently
	var wg sync.WaitGroup
	results := make([]*core.ProviderResult, len(selectedProviders))

	for i, p := range selectedProviders {
		wg.Add(1)
		go func(idx int, prov core.DriverProvider) {
			defer wg.Done()

			// Create orchestrator
			orch := core.NewOrchestrator(prov, cfg, progressChan)

			// Run the orchestrator and store result
			results[idx] = orch.Run()
		}(i, p)
	}

	// Wait for all providers to complete, then close the progress channel
	wg.Wait()
	close(progressChan)

	// Wait for TUI/plain output to finish
	<-tuiDone

	// Print summary
	fmt.Println()
	fmt.Println("========================================")
	fmt.Println("Driver Scraping Complete")
	fmt.Println("========================================")

	totalSuccess, totalFailed, totalSkipped := 0, 0, 0
	for _, r := range results {
		if r == nil {
			continue
		}
		totalSuccess += r.Success
		totalFailed += r.Failed
		totalSkipped += r.Skipped
		fmt.Printf("%s: %d success, %d failed, %d skipped\n",
			r.ProviderName, r.Success, r.Failed, r.Skipped)
		if len(r.Errors) > 0 {
			for _, err := range r.Errors {
				fmt.Printf("  ERROR: %v\n", err)
			}
		}
	}

	fmt.Println()
	fmt.Printf("Total: %d success, %d failed, %d skipped\n",
		totalSuccess, totalFailed, totalSkipped)

	if totalFailed > 0 {
		os.Exit(1)
	}
}

func parseProviders(s string) []string {
	if s == "all" {
		return []string{"intel-eth", "intel-wifi", "marvell", "realtek", "qualcomm", "mediatek"}
	}

	var result []string
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p != "" {
			result = append(result, p)
		}
	}
	return result
}

func buildProviderMap() map[string]core.DriverProvider {
	m := make(map[string]core.DriverProvider)

	intelEth := providers.NewIntelEthernet()
	m[intelEth.ProviderKey()] = intelEth

	intelWifi := providers.NewIntelWiFi()
	m[intelWifi.ProviderKey()] = intelWifi

	marvell := providers.NewMarvell()
	m[marvell.ProviderKey()] = marvell

	realtek := providers.NewRealtek()
	m[realtek.ProviderKey()] = realtek

	qualcomm := providers.NewQualcomm()
	m[qualcomm.ProviderKey()] = qualcomm

	mediatek := providers.NewMediaTek()
	m[mediatek.ProviderKey()] = mediatek

	return m
}

func providerKeysList(m map[string]core.DriverProvider) []string {
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}

// ====================================================================
// TUI — uses the tui package with proper terminal capture
// ====================================================================

func runTUI(progressChan core.ProgressChan) {
	model := tui.NewModel()

	// CRITICAL: On Windows, bubbletea MUST be given explicit stdin/stdout
	// bindings. Without WithInput(os.Stdin), bubbletea creates a program
	// with a nil input channel, causing p.Wait() to deadlock forever.
	//
	// Additionally, we must use the legacy renderer (WithAltScreen(false)
	// is not enough) because PowerShell's conhost does not properly support
	// the ANSI renderer. The legacy renderer uses basic cursor positioning
	// that works on all Windows terminals.
	p := tea.NewProgram(
		model,
		tea.WithInput(os.Stdin),
		tea.WithOutput(os.Stdout),
		tea.WithAltScreen(),
	)

	// Send progress events to the TUI in a goroutine.
	// When the progress channel closes (all providers done), send tea.Quit
	// so the TUI exits cleanly instead of blocking forever.
	go func() {
		for ev := range progressChan {
			p.Send(ev)
		}
		p.Quit()
	}()

	p.Wait()
}

// ====================================================================
// Plain output
// ====================================================================

func runPlainOutput(progressChan core.ProgressChan, providers []core.DriverProvider) {
	type deviceKey struct {
		provider string
		device   string
		arch     string
	}

	deviceStatus := make(map[deviceKey]*plainDeviceState)
	providerStatus := make(map[string]*plainProviderState)
	var mu sync.Mutex

	for ev := range progressChan {
		mu.Lock()

		ps, ok := providerStatus[ev.Provider]
		if !ok {
			ps = &plainProviderState{name: ev.Provider}
			providerStatus[ev.Provider] = ps
		}

		key := deviceKey{
			provider: ev.Provider,
			device:   ev.Device,
			arch:     ev.Arch,
		}

		ds, ok := deviceStatus[key]
		if !ok && ev.Device != "" {
			ds = &plainDeviceState{prefix: ev.Device, arch: ev.Arch}
			deviceStatus[key] = ds
		}

		switch ev.Type {
		case core.EventProviderStart:
			fmt.Printf("[%s] => %s\n", time.Now().Format("15:04:05"), ev.Provider)

		case core.EventDeviceSearchStart:
			if ds != nil {
				fmt.Printf("[%s]   [SEARCH] %s %s\n", time.Now().Format("15:04:05"), ds.prefix, ev.Status)
			}

		case core.EventPackageSelected:
			if ds != nil {
				fmt.Printf("[%s]   [SELECT] %s [%s] v%s\n", time.Now().Format("15:04:05"), ds.prefix, ds.arch, ev.Version)
			}

		case core.EventDownloadStart:
			if ds != nil {
				fmt.Printf("[%s]   [DOWNLOAD] %s [%s] %s\n", time.Now().Format("15:04:05"), ds.prefix, ds.arch, ev.Message)
			}

		case core.EventDownloadProgress:
			if ds != nil {
				fmt.Printf("[%s]   [DOWNLOAD] %s [%s] %.1f%% %s\n", time.Now().Format("15:04:05"), ds.prefix, ds.arch, ev.Progress*100, ev.Message)
			}

		case core.EventDownloadDone:
			if ds != nil {
				fmt.Printf("[%s]   [DOWNLOAD] %s [%s] Complete %s\n", time.Now().Format("15:04:05"), ds.prefix, ds.arch, ev.Message)
			}

		case core.EventExtractStart:
			if ds != nil {
				fmt.Printf("[%s]   [EXTRACT] %s [%s] %s\n", time.Now().Format("15:04:05"), ds.prefix, ds.arch, ev.Message)
			}

		case core.EventExtractDone:
			if ds != nil {
				fmt.Printf("[%s]   [EXTRACT] %s [%s] Complete %s\n", time.Now().Format("15:04:05"), ds.prefix, ds.arch, ev.Message)
			}

		case core.EventProviderDone:
			ps.done = true
			fmt.Printf("[%s] => %s complete: %s\n", time.Now().Format("15:04:05"), ev.Provider, ev.Message)

		case core.EventProviderFailed:
			ps.failed = true
			fmt.Printf("[%s] => %s FAILED: %s\n", time.Now().Format("15:04:05"), ev.Provider, ev.Message)
		}

		mu.Unlock()
	}
}

type plainDeviceState struct {
	prefix string
	arch   string
}

type plainProviderState struct {
	name   string
	done   bool
	failed bool
}
