param(
    [string] $ShortcutName = "BatteryServicePowerEstimator"
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$runnerPath = Join-Path $PSScriptRoot "run-windows-estimator.cmd"

if (-not (Test-Path -LiteralPath $runnerPath)) {
    throw "Runner script was not found: $runnerPath"
}

$startupDirectory = [Environment]::GetFolderPath("Startup")
if ([string]::IsNullOrWhiteSpace($startupDirectory)) {
    throw "Unable to resolve the current user's Startup folder."
}

$shortcutPath = Join-Path $startupDirectory "$ShortcutName.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $runnerPath
$shortcut.WorkingDirectory = $projectRoot
$shortcut.WindowStyle = 7
$shortcut.Description = "Starts BatteryService power estimator at user logon."
$shortcut.Save()

Write-Host "Installed startup shortcut: $shortcutPath"
