$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$Command = if ($args.Count -gt 0) { [string] $args[0] } else { "help" }
$Arguments = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }

function Show-Help {
    @"
BatteryService CLI

Usage:
  .\batteryservice.ps1 <command> [options]

Commands:
  help                 Show this help.
  status               Show Windows Service status and recent logs.
  sample               Record one immediate sample.
  start                Start Windows Service if installed.
  stop                 Stop Windows Service if installed.
  restart              Restart Windows Service if installed.
  install-service      Build and install the Windows Service. Requires admin.
  uninstall-service    Remove the Windows Service. Requires admin.
  install-task         Install legacy SYSTEM scheduled task. Requires admin.
  install-watchdog     Install legacy scheduled-task watchdog. Requires admin.
  restart-task         Restart legacy scheduled task.
  report               Generate HTML report. Example: report -Days 7
  open-report          Generate and open HTML report. Example: open-report -Days 7
  tail                 Tail latest minute CSV rows.
  logs                 Tail runner/service logs.
  usage                Show usage summary. Example: usage --from 2026-07-31 --group-by day -o table
  probe                Run Windows sensor probe.
  probe-lhm            Run LibreHardwareMonitor direct probe.
  build-service        Build Windows Service wrapper.

Examples:
  .\batteryservice.ps1 sample
  .\batteryservice.ps1 report
  .\batteryservice.ps1 open-report
  .\batteryservice.ps1 install-service
"@
}

function Invoke-Script {
    param(
        [string] $Path,
        [string[]] $ExtraArguments = @()
    )

    $filteredArguments = @($ExtraArguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($filteredArguments.Count -gt 0) {
        & (Join-Path $ProjectRoot $Path) @filteredArguments
    }
    else {
        & (Join-Path $ProjectRoot $Path)
    }
}

function Invoke-CmdScript {
    param([string] $Path)
    & cmd.exe /c (Join-Path $ProjectRoot $Path)
}

function Tail-IfExists {
    param(
        [string] $Path,
        [int] $Count = 20
    )

    $absolutePath = Join-Path $ProjectRoot $Path
    if (Test-Path -LiteralPath $absolutePath) {
        Get-Content -Tail $Count -LiteralPath $absolutePath
    }
    else {
        Write-Host "File not found: $absolutePath"
    }
}

Set-Location $ProjectRoot

switch ($Command.ToLowerInvariant()) {
    "help" { Show-Help }
    "-h" { Show-Help }
    "--help" { Show-Help }
    "status" { Invoke-Script -Path "scripts\get-windows-service-status.ps1" -ExtraArguments $Arguments }
    "sample" { & (Join-Path $ProjectRoot "scripts\estimate-power-windows.ps1") -Once }
    "start" { Start-Service -Name "BatteryServicePowerEstimator" }
    "stop" { Stop-Service -Name "BatteryServicePowerEstimator" }
    "restart" {
        Restart-Service -Name "BatteryServicePowerEstimator"
        Invoke-Script "scripts\get-windows-service-status.ps1"
    }
    "install-service" { Invoke-Script -Path "scripts\install-windows-service.ps1" -ExtraArguments $Arguments }
    "uninstall-service" { Invoke-Script -Path "scripts\uninstall-windows-service.ps1" -ExtraArguments $Arguments }
    "install-task" { Invoke-CmdScript "scripts\install-windows-schtasks-system.cmd" }
    "install-watchdog" { Invoke-CmdScript "scripts\install-windows-schtasks-watchdog-system.cmd" }
    "restart-task" { Invoke-CmdScript "scripts\restart-windows-schtasks.cmd" }
    "report" {
        $filteredArguments = @($Arguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        & (Join-Path $ProjectRoot "scripts\export-html-report.ps1") @filteredArguments
    }
    "open-report" {
        $filteredArguments = @($Arguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        & (Join-Path $ProjectRoot "scripts\export-html-report.ps1") @filteredArguments
        Start-Process (Join-Path $ProjectRoot "reports\power-report.html")
    }
    "tail" { Tail-IfExists "logs\power-minute.csv" 10 }
    "logs" {
        Write-Host "--- windows-service.log ---"
        Tail-IfExists "logs\windows-service.log" 30
        Write-Host "--- runner.log ---"
        Tail-IfExists "logs\runner.log" 30
    }
    "usage" {
        $filteredArguments = @($Arguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        python (Join-Path $ProjectRoot "src\usage_report.py") usage --platform windows @filteredArguments
    }
    "probe" { Invoke-Script -Path "scripts\probe-windows.ps1" -ExtraArguments $Arguments }
    "probe-lhm" { Invoke-Script -Path "scripts\probe-librehardwaremonitor.ps1" -ExtraArguments $Arguments }
    "build-service" { Invoke-Script -Path "scripts\build-windows-service.ps1" -ExtraArguments $Arguments }
    default {
        Write-Host "Unknown command: $Command"
        Show-Help
        exit 1
    }
}
