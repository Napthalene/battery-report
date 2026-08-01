param(
    [string] $ShortcutName = "BatteryServicePowerEstimator"
)

$ErrorActionPreference = "Stop"

$startupDirectory = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDirectory "$ShortcutName.lnk"

if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Host "Removed startup shortcut: $shortcutPath"
}
else {
    Write-Host "Startup shortcut does not exist: $shortcutPath"
}
