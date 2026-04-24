# Driver Scraper: Holistic Code Audit & TUI Rewrite Plan

## Background

The `driver-scrapers/` directory contains a Go rewrite of the PowerShell `Get-*Drivers.ps1` scripts that scrape driver packages from the Microsoft Update Catalog. The core logic (catalog client, search, selection, download, extract) and provider definitions are structurally sound, but the TUI layer built with Bubble Tea has fundamental architectural issues that would prevent it from ever working correctly. There is also one compile-blocking bug and several general code quality problems.

## Summary of Findings

### 🔴 Critical (Blocks Compilation / Runtime)

| # | File | Issue |
|---|------|-------|
| 1 | [catalog.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/core/catalog.go#L148) | **Compile error**: `c.applyHeaders(r)` — variable `r` is undefined; should be `req` |
| 2 | [main.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/cmd/driverscrape/main.go#L222-L251) | **TUI deadlock**: Uses `p.Wait()` without ever calling `p.Run()`. `p.Wait()` blocks on `p.finished`, which is only initialized by `p.Run()`. This means `p.Wait()` blocks on a nil channel → **instant panic or deadlock** |

### 🟠 Major (TUI Won't Render / Behave Correctly)

| # | File | Issue |
|---|------|-------|
| 3 | [main.go:103-110](file:///home/jmulesa/lan-ipxe/driver-scrapers/cmd/driverscrape/main.go#L103-L110) | TUI runs in a background goroutine. Bubble Tea **must** run on the main goroutine (or at least the goroutine that owns the terminal) because it takes over stdin/stdout with raw mode. Running it in a goroutine races with provider stdout writes |
| 4 | [main.go:113](file:///home/jmulesa/lan-ipxe/driver-scrapers/cmd/driverscrape/main.go#L113) | `time.Sleep(100ms)` as synchronization — fragile race condition between TUI startup and provider events |
| 5 | [spinner.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/spinner.go) | Custom hand-rolled spinner with mutex + `time.Sleep(80ms)` **inside a `tea.Cmd`**. Sleeping inside a Cmd blocks the Bubble Tea runtime. Should use `github.com/charmbracelet/bubbles/spinner` instead |
| 6 | [model.go:64-71](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/model.go#L64-L71) | `Init()` calls both `m.spinner.tick()` (which sleeps) AND `tea.Tick()` — creating two competing tick loops. The spinner tick sleeps 80ms inside the Cmd, blocking the program's command pipeline |
| 7 | [model.go:102-105](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/model.go#L102-L105) | On `tickMsg`, calls `m.spinner.tick()` which returns **another** blocking Cmd. This creates an ever-growing chain of blocked goroutines |
| 8 | [model.go:116-157](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/model.go#L116-L157) | `View()` uses raw string concatenation instead of lipgloss styles. Most of the defined styles in [styles.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/styles.go) are **never used** |
| 9 | [model.go:233-244](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/model.go#L233-L244) | `renderOverall()` tries to count "active" downloads/extracts by scanning the last 20 events — fundamentally wrong approach; should track state, not scan events |
| 10 | [model.go:368-375](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/model.go#L368-L375) | `EventProviderDone` handler tries to mark a specific device as done using `ev.Device`/`ev.Arch`, but the orchestrator sends **two** `EventProviderDone` events: one per-device (with Device/Arch set) and one per-provider (without Device/Arch). The handler incorrectly tries to look up a device key from the provider-level event |

### 🟡 Moderate (Correctness / Quality)

| # | File | Issue |
|---|------|-------|
| 11 | [search.go:119-124](file:///home/jmulesa/lan-ipxe/driver-scrapers/core/search.go#L119-L124) | **Semaphore anti-pattern**: Acquires semaphore on line 119 (`sem <- struct{}{}`) but releases on line 124 **inside the goroutine** (`<-sem`). This means the semaphore is acquired by the launching goroutine but released by the spawned goroutine — the throttle doesn't actually work. Should acquire inside the goroutine and use `defer` |
| 12 | [downloader.go:83](file:///home/jmulesa/lan-ipxe/driver-scrapers/core/downloader.go#L83) | Progress reporting condition `int(progress*10) != int(((bytesWritten-int64(nw))/totalSize)*10)` — integer division on int64 always truncates to 0 for small values; will spam progress events. Also panics with division by zero when `totalSize` is 0 or -1 (unknown content length) |
| 13 | [types.go:322-345](file:///home/jmulesa/lan-ipxe/driver-scrapers/core/types.go#L322-L345) | Hand-rolled `itoa()` function — `strconv.Itoa` exists and is well-tested |
| 14 | [search.go:228-256](file:///home/jmulesa/lan-ipxe/driver-scrapers/core/search.go#L228-L256) | Custom `errGroup` instead of using `golang.org/x/sync/errgroup` which is already listed as a dependency in [design.md](file:///home/jmulesa/lan-ipxe/driver-scrapers/design.md) but **not in go.mod** |
| 15 | [model.go:425-426](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/model.go#L425-L426) | `type ProgressEvent core.ProgressEvent` defined but **never used** — the TUI correctly handles `core.ProgressEvent` directly in Update() |
| 16 | [model.go:409-421](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/model.go#L409-L421) | Custom `min`/`max` helper functions — Go 1.21+ has built-in `min`/`max`; with go 1.25 these are redundant |
| 17 | [providers/interface.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/providers/interface.go#L11-L19) | Intel Ethernet `PreferredBranches` contain 50 entries each (`1.0` through `3.1`) — these are nonsensical for a `NewestByDate` strategy which ignores branches entirely. The design doc says Intel uses `NewestByDate`, not branch-based selection |

> [!IMPORTANT]
> **Issues #1 and #2 together mean the code cannot compile and even if the typo is fixed, the TUI would deadlock immediately.** This confirms the report that local models are "having extreme trouble wiring up bubbletea TUIs properly."

## Proposed Changes

### Phase 1: Fix Compilation Blocker

#### [MODIFY] [catalog.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/core/catalog.go)
- Line 148: Change `c.applyHeaders(r)` → `c.applyHeaders(req)`

---

### Phase 2: Rewrite TUI Architecture

The TUI needs a structural rewrite to follow correct Bubble Tea patterns. The core issues are:

1. **`p.Run()` must be used instead of `p.Wait()`** — Run initializes the renderer, terminal, and event loop
2. **Bubble Tea must own the main goroutine** — providers run in background goroutines, not the TUI
3. **Never sleep inside a `tea.Cmd`** — use `tea.Tick` for periodic updates
4. **Use `bubbles/spinner`** instead of hand-rolling one

#### [MODIFY] [main.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/cmd/driverscrape/main.go)

Restructure the main flow:

```go
// Current (broken):
//   go runTUI(progressChan)    // TUI in background goroutine ❌
//   time.Sleep(100ms)          // race condition ❌
//   wg.Wait()                  // providers on main goroutine
//   close(progressChan)
//   <-tuiDone                  // wait for TUI

// Fixed:
//   go runProviders(...)       // providers in background goroutines
//   p.Run()                    // TUI on main goroutine, blocks until quit ✅
```

- Rewrite `runTUI()` to use `p.Run()` instead of `p.Wait()`
- Launch providers in a background goroutine, with the progress-channel-to-TUI bridge
- Remove `time.Sleep(100ms)` synchronization hack
- Remove `tea.WithInput(os.Stdin)` / `tea.WithOutput(os.Stdout)` — these are the defaults and the comment about Windows conhost is irrelevant on Linux

#### [DELETE] [spinner.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/spinner.go)

Replace with `github.com/charmbracelet/bubbles/spinner`.

#### [MODIFY] [model.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/model.go)

Major rewrite:

1. **Replace custom spinner** with `bubbles/spinner.Model`
2. **Fix `Init()`**: Return only `tea.Batch(spinner.Tick, tea.WindowSize())` — no custom tick loop
3. **Fix `Update()`**: 
   - Handle `spinner.TickMsg` properly via `s.spinner.Update(msg)`
   - Remove panic recovery (Bubble Tea already handles panics)
   - Return proper `tea.Cmd` from spinner update
4. **Fix `View()`**: Actually use the lipgloss styles defined in `styles.go`
5. **Fix `renderOverall()`**: Track downloading/extracting counts as state fields, not by scanning events
6. **Fix `handleProgress()`**:
   - Stop accumulating **all** events in `m.events` (unbounded memory growth)
   - Instead, maintain only the provider insertion order as `[]string`
   - Handle `EventProviderDone` correctly: distinguish per-device vs per-provider events
7. **Remove dead code**: `ProgressEvent` type alias, custom `min`/`max`

#### [MODIFY] [styles.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/styles.go)

- Clean up unused styles or wire them into the actual View rendering
- Fix `progressBarWithColor()` to use `.Render()` instead of `.SetString().String()` — the current approach is incorrect lipgloss usage

---

### Phase 3: Fix Core Logic Bugs

#### [MODIFY] [search.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/core/search.go)

- Fix the semaphore pattern: acquire inside goroutine, release with `defer`

```go
// Current (broken):
sem <- struct{}{}   // acquire on launcher goroutine
go func() {
    <-sem           // release inside spawned goroutine (backwards!)
    ...
}()

// Fixed:
go func() {
    sem <- struct{}{} // acquire inside goroutine (blocks if at limit)
    defer func() { <-sem }() // release when done
    ...
}()
```

- Replace custom `errGroup` with `golang.org/x/sync/errgroup` (add to go.mod)
- Remove custom `toLowerASCII`, `containsStr` — use `strings.Contains` + `strings.ToLower`

#### [MODIFY] [downloader.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/core/downloader.go)

- Fix division-by-zero when `totalSize <= 0` (unknown content length)
- Fix progress reporting logic to use proper percentage thresholds

#### [MODIFY] [types.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/core/types.go)

- Replace hand-rolled `itoa()` with `strconv.Itoa()`

---

### Phase 4: Cleanup

#### [MODIFY] [providers/interface.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/providers/interface.go)

- Remove the 50-element `PreferredBranches` slices from Intel Ethernet and Intel WiFi providers — they use `NewestByDate` strategy which ignores branches. The design doc correctly specifies no branch preferences for these providers.

#### [MODIFY] [go.mod](file:///home/jmulesa/lan-ipxe/driver-scrapers/go.mod)

- Add `github.com/charmbracelet/bubbles` dependency (for `spinner` component)
- Add `golang.org/x/sync` dependency (for `errgroup`)
- Verify go version (currently `go 1.25.0` — this is fine, built-in `min`/`max` available)

#### [DELETE] [logger.go](file:///home/jmulesa/lan-ipxe/driver-scrapers/tui/logger.go)

> [!IMPORTANT]
> **Decision needed**: The `logger.go` file implements file-based logging for the TUI since Bubble Tea owns stdout/stderr. This is a valid pattern for debugging, but it's entangled with the broken TUI via `GetLogger()` calls scattered in panic-recovery blocks. 
> 
> **Option A**: Keep the logger but remove the panic-recovery `defer` blocks (Bubble Tea handles panics). Logger becomes opt-in for debug sessions via a `--log-file` flag.
> 
> **Option B**: Remove the logger entirely. It adds complexity and the `--verbose` flag with `--no-tui` mode provides a simpler debugging path.

---

## Open Questions

> [!IMPORTANT]
> 1. **Logger disposition**: Keep as opt-in debug tool (Option A) or remove entirely (Option B)?
> 2. **go.mod module path**: The module path is `github.com/gitgerby/lan-ipxe/driver-scrapers` — is `gitgerby` the correct GitHub org, or should this be a different path?
> 3. **Testing priority**: Should I add unit tests for core logic in this pass, or focus purely on getting it compiling and the TUI working?

## Verification Plan

### Automated Tests
1. `go build ./...` — must compile cleanly
2. `go vet ./...` — no static analysis warnings  
3. `driver-scrape --no-tui --no-download --providers intel-eth --arch x64` — verify plain-text search-only mode works
4. `driver-scrape --providers intel-eth --arch x64 --no-download` — verify TUI renders and exits cleanly

### Manual Verification
- Run with TUI mode and confirm:
  - No deadlocks or panics
  - Spinner animates
  - Progress bars update as events arrive
  - `q` / `Ctrl+C` exits cleanly
  - Terminal is restored to normal after exit
