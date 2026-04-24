package core

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// downloadPackage downloads a CAB file from the catalog.
func (o *Orchestrator) downloadPackage(pkg *DriverPackage) error {
	o.buildOutputPaths(pkg)

	// Get the download URL from the catalog
	cabURL, err := o.client.GetDownloadURL(pkg.UpdateID)
	if err != nil {
		return fmt.Errorf("get download URL: %w", err)
	}
	pkg.CabURL = cabURL

	o.progress.Send(ProgressEvent{
		Type:     EventDownloadStart,
		Provider: o.provider.Name(),
		Device:   pkg.DevicePrefix,
		Arch:     pkg.Arch,
		Status:   "Downloading...",
		Message:  filepath.Base(pkg.CabPath),
	})

	// Ensure output directory exists
	if err := EnsureDir(filepath.Dir(pkg.CabPath)); err != nil {
		return fmt.Errorf("create output dir: %w", err)
	}

	// Download the file
	outFile, err := os.Create(pkg.CabPath)
	if err != nil {
		return fmt.Errorf("create cab file: %w", err)
	}
	defer outFile.Close()

	req, err := http.NewRequest("GET", cabURL, nil)
	if err != nil {
		return fmt.Errorf("create download request: %w", err)
	}
	req.Header.Set("User-Agent", o.client.userAgent)
	req.Header.Set("Referer", o.client.baseURL+"/")

	resp, err := o.client.client.Do(req)
	if err != nil {
		return fmt.Errorf("download request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download returned HTTP %d", resp.StatusCode)
	}

	// Get content length for progress
	totalSize := resp.ContentLength
	var bytesWritten int64
	startTime := time.Now()

	buf := make([]byte, 1024*1024) // 1MB buffer
	for {
		nr, err := resp.Body.Read(buf)
		if nr > 0 {
			nw, ew := outFile.Write(buf[0:nr])
			if nw > 0 {
				bytesWritten += int64(nw)
			}
			if ew != nil {
				return fmt.Errorf("write error: %w", ew)
			}

			// Report progress
			progress := 0.0
			if totalSize > 0 {
				progress = float64(bytesWritten) / float64(totalSize)
			}
			if int(progress*10) != int(((bytesWritten-int64(nw))/totalSize)*10) || bytesWritten == int64(nw) {
				elapsed := time.Since(startTime).Seconds()
				speed := float64(bytesWritten) / 1024 / 1024 / elapsed
				o.progress.Send(ProgressEvent{
					Type:     EventDownloadProgress,
					Provider: o.provider.Name(),
					Device:   pkg.DevicePrefix,
					Arch:     pkg.Arch,
					Progress: progress,
					Status:   fmt.Sprintf("Downloading... %.1f MB/s", speed),
					Message:  fmt.Sprintf("%.1f / %.1f MB", float64(bytesWritten)/1024/1024, float64(totalSize)/1024/1024),
				})
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("read error: %w", err)
		}
	}

	// Verify file size isn't zero
	info, err := os.Stat(pkg.CabPath)
	if err != nil {
		return fmt.Errorf("stat cab file: %w", err)
	}
	if info.Size() == 0 {
		return fmt.Errorf("downloaded empty file")
	}

	o.progress.Send(ProgressEvent{
		Type:     EventDownloadDone,
		Provider: o.provider.Name(),
		Device:   pkg.DevicePrefix,
		Arch:     pkg.Arch,
		Version:  pkg.Version,
		Progress: 1.0,
		Status:   "Download complete",
		Message:  fmt.Sprintf("%.1f MB", float64(info.Size())/1024/1024),
	})

	return nil
}
