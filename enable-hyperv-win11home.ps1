# Define the path where Windows stores its feature packages
$packagePath = "$env:SystemRoot\servicing\Packages"

# Find all Hyper-V related manifest files
$packageFiles = Get-ChildItem -Path $packagePath -Filter "*Hyper-V*.mum"

if ($packageFiles.Count -eq 0) {
    Write-Error "No Hyper-V packages found. Ensure you are running this on a standard Windows 11 Home installation."
    return
}

Write-Host "Found $($packageFiles.Count) packages. Starting installation..." -ForegroundColor Yellow

# Install each package using DISM
foreach ($file in $packageFiles) {
    Write-Host "Installing: $($file.Name)" -ForegroundColor Gray
    Dism /online /norestart /add-package:"$($file.FullName)"
}

# Now that the packages are "known" to the system, enable the feature
Write-Host "Enabling Hyper-V Feature..." -ForegroundColor Yellow
Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V" -All -NoRestart

Write-Host "Process complete! Please RESTART your computer now." -ForegroundColor Green