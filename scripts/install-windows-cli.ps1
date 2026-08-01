param(
    [string] $CommandDirectory = "$env:USERPROFILE\bin"
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$targetDirectory = if ([System.IO.Path]::IsPathRooted($CommandDirectory)) {
    $CommandDirectory
}
else {
    Join-Path (Get-Location).Path $CommandDirectory
}

New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null

$commandPath = Join-Path $targetDirectory "batteryservice.cmd"
$scriptPath = Join-Path $projectRoot "batteryservice.ps1"

@"
@echo off
powershell -ExecutionPolicy Bypass -File "$scriptPath" %*
"@ | Set-Content -Encoding ASCII -LiteralPath $commandPath

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathParts = @($userPath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($pathParts -notcontains $targetDirectory) {
    $newPath = (($pathParts + $targetDirectory) -join ";")
    try {
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "Added to user PATH: $targetDirectory"
        Write-Host "Open a new terminal before using the command globally."
    }
    catch {
        Write-Host "Installed command shim, but could not update user PATH automatically."
        Write-Host "Add this directory to PATH manually if needed: $targetDirectory"
    }
}

Write-Host "Installed BatteryService CLI: $commandPath"
Write-Host "Try: batteryservice usage -o table"
