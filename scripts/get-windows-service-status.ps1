param(
    [string] $ServiceName = "BatteryServicePowerEstimator"
)

$ErrorActionPreference = "Stop"

Get-Service -Name $ServiceName -ErrorAction Stop | Format-List Name,DisplayName,Status,StartType,ServiceType
if (Test-Path -LiteralPath ".\logs\windows-service.log") {
    Write-Host "--- windows-service.log tail ---"
    Get-Content -Tail 30 -LiteralPath ".\logs\windows-service.log"
}
