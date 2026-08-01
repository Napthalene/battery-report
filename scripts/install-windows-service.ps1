param(
    [string] $ServiceName = "BatteryServicePowerEstimator"
)

$ErrorActionPreference = "Stop"

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated Administrator PowerShell session."
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$serviceExe = Join-Path $projectRoot "bin\windows\BatteryService.WindowsService.exe"
$estimatorPath = Join-Path $projectRoot "scripts\estimate-power-windows.ps1"
$configPath = Join-Path $projectRoot "config\power-estimator.windows.json"

if (-not (Test-Path -LiteralPath $serviceExe)) {
    & (Join-Path $PSScriptRoot "build-windows-service.ps1")
}

$binPath = "`"$serviceExe`" `"$estimatorPath`" `"$configPath`" `"$projectRoot`""

$existing = sc.exe query $ServiceName 2>$null
if ($LASTEXITCODE -eq 0) {
    sc.exe stop $ServiceName | Out-Null
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

sc.exe create $ServiceName binPath= $binPath start= delayed-auto DisplayName= "BatteryService Power Estimator" | Out-Null
sc.exe description $ServiceName "Logs estimated laptop power consumption using CPU, GPU, baseline, and charging telemetry." | Out-Null
sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null
sc.exe start $ServiceName | Out-Null

Write-Host "Installed and started Windows Service: $ServiceName"
