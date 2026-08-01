param(
    [switch] $SkipService
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    throw "git.exe is required for update."
}

Write-Host "Updating BatteryService in $projectRoot"
git pull --ff-only

if ($SkipService) {
    Write-Host "Skipped Windows Service refresh."
    exit 0
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Git update complete."
    Write-Host "Run from Administrator PowerShell to rebuild/reinstall service:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\update-windows.ps1"
    exit 0
}

sc.exe stop BatteryServicePowerEstimator | Out-Null
Start-Sleep -Seconds 3
Get-Process BatteryService.WindowsService -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

& (Join-Path $PSScriptRoot "build-windows-service.ps1")
& (Join-Path $PSScriptRoot "install-windows-service.ps1")
& (Join-Path $PSScriptRoot "install-windows-cli.ps1")

Write-Host "BatteryService Windows update complete."
