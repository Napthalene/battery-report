param(
    [string] $TaskName = "BatteryServicePowerEstimator",
    [switch] $RunAsCurrentUser,
    [switch] $AtLogon,
    [switch] $StartNow
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$estimatorPath = Join-Path $PSScriptRoot "estimate-power-windows.ps1"
$configPath = Join-Path $projectRoot "config\power-estimator.windows.json"

if (-not $RunAsCurrentUser) {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principalCheck = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $isAdministrator = $principalCheck.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdministrator) {
        throw "Installing a SYSTEM startup task requires an elevated Administrator PowerShell session. Re-run PowerShell with 'Run as administrator', or use -RunAsCurrentUser for logon startup."
    }
}

if (-not (Test-Path -LiteralPath $estimatorPath)) {
    throw "Estimator script was not found: $estimatorPath"
}

if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Estimator config was not found: $configPath"
}

$powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-WindowStyle", "Hidden",
    "-File", "`"$estimatorPath`"",
    "-ConfigPath", "`"$configPath`"",
    "-DurationSeconds", "0"
) -join " "

$action = New-ScheduledTaskAction `
    -Execute $powerShellPath `
    -Argument $arguments `
    -WorkingDirectory $projectRoot

$trigger = if ($AtLogon -or $RunAsCurrentUser) {
    New-ScheduledTaskTrigger -AtLogOn
}
else {
    New-ScheduledTaskTrigger -AtStartup
}

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

if ($RunAsCurrentUser) {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal `
        -UserId $currentIdentity `
        -LogonType Interactive `
        -RunLevel Highest
}
else {
    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest
}

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Logs estimated laptop power consumption using CPU load, GPU watts, and baseline."

Register-ScheduledTask `
    -TaskName $TaskName `
    -InputObject $task `
    -Force | Out-Null

if ($StartNow) {
    Start-ScheduledTask -TaskName $TaskName
}

Write-Host "Installed scheduled task: $TaskName"
Write-Host "Mode: $(if ($RunAsCurrentUser) { "current user at logon" } elseif ($AtLogon) { "SYSTEM at logon" } else { "SYSTEM at startup" })"
Write-Host "Estimator: $estimatorPath"
Write-Host "Config: $configPath"
