# enable-hyperv-win11home.ps1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# Skip early if Hyper-V is already enabled.
if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue).State -eq 'Enabled') {
    Write-Host "Hyper-V is already enabled. Nothing to do." -ForegroundColor Green
    return
}

# Define the path where Windows stores its feature packages
$packagePath = "$env:SystemRoot\servicing\Packages"

# Find all Hyper-V related manifest files
$packageFiles = Get-ChildItem -Path $packagePath -Filter "*Hyper-V*.mum"

if ($packageFiles.Count -eq 0) {
    Write-Error "No Hyper-V packages found. Ensure you are running this on a standard Windows 11 Home installation."
    return
}

Write-Host "Found $($packageFiles.Count) packages. Starting installation..." -ForegroundColor Yellow

# Install each package using DISM. Treat 0 (success) and 3010 (success, reboot
# required) as success; anything else is a hard failure.
foreach ($file in $packageFiles) {
    Write-Host "Installing: $($file.Name)" -ForegroundColor Gray
    Dism /online /norestart /add-package:"$($file.FullName)"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
        Write-Error "DISM failed to add package '$($file.Name)' (exit code $LASTEXITCODE)."
        exit $LASTEXITCODE
    }
}

# Now that the packages are "known" to the system, enable the feature.
Write-Host "Enabling Hyper-V Feature..." -ForegroundColor Yellow
Dism /online /norestart /enable-feature /featurename:Microsoft-Hyper-V /all
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
    Write-Error "DISM failed to enable the Hyper-V feature (exit code $LASTEXITCODE)."
    exit $LASTEXITCODE
}

Write-Host "Process complete! Please RESTART your computer now." -ForegroundColor Green
