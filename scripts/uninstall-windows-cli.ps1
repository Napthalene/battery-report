param(
    [string] $CommandDirectory = "$env:USERPROFILE\bin"
)

$ErrorActionPreference = "Stop"

$targetDirectory = if ([System.IO.Path]::IsPathRooted($CommandDirectory)) {
    $CommandDirectory
}
else {
    Join-Path (Get-Location).Path $CommandDirectory
}

$commandPath = Join-Path $targetDirectory "batteryservice.cmd"
if (Test-Path -LiteralPath $commandPath) {
    Remove-Item -LiteralPath $commandPath -Force
}

Write-Host "Removed BatteryService CLI: $commandPath"
