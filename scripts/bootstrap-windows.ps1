param(
    [switch] $Check,
    [switch] $Install,
    [switch] $Help
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Show-Help {
    @"
BatteryService Windows bootstrap

Usage:
  powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Check
  powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Install

Options:
  -Check      Check prerequisites and print next steps.
  -Install    Check prerequisites, build, and install the Windows Service.
  -Help       Show this help.
"@
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-CSharpCompiler {
    $candidates = @(
        "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )

    $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Invoke-Check {
    $failed = $false
    Write-Host "BatteryService root: $ProjectRoot"

    $powershellPath = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if ($powershellPath) {
        Write-Host "OK: powershell.exe -> $powershellPath"
    }
    else {
        Write-Host "MISSING: powershell.exe is required"
        $failed = $true
    }

    $pythonPath = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    if ($pythonPath) {
        Write-Host "OK: python.exe -> $pythonPath"
    }
    else {
        Write-Host "MISSING: python.exe is required for usage summaries"
        $failed = $true
    }

    $cscPath = Find-CSharpCompiler
    if ($cscPath) {
        Write-Host "OK: csc.exe -> $cscPath"
    }
    else {
        Write-Host "MISSING: .NET Framework csc.exe is required to build the Windows Service wrapper"
        $failed = $true
    }

    $lhmZip = Join-Path $ProjectRoot "tools\LibreHardwareMonitor.zip"
    $lhmDirectory = Join-Path $ProjectRoot "tools\LibreHardwareMonitor"
    if (Test-Path -LiteralPath $lhmDirectory) {
        Write-Host "OK: LibreHardwareMonitor extracted -> $lhmDirectory"
    }
    elseif (Test-Path -LiteralPath $lhmZip) {
        Write-Host "INFO: LibreHardwareMonitor.zip found. Extract with:"
        Write-Host "      Expand-Archive -LiteralPath .\tools\LibreHardwareMonitor.zip -DestinationPath .\tools\LibreHardwareMonitor -Force"
    }
    else {
        Write-Host "INFO: LibreHardwareMonitor not found. GPU/CPU sensors may be limited."
    }

    if (Test-IsAdministrator) {
        Write-Host "OK: running as Administrator"
    }
    else {
        Write-Host "INFO: not running as Administrator. Service installation requires Administrator PowerShell."
    }

    if ($failed) {
        throw "Bootstrap check failed."
    }

    Write-Host "Bootstrap check passed."
}

function Invoke-Install {
    Invoke-Check

    if (-not (Test-IsAdministrator)) {
        throw "Run -Install from an elevated Administrator PowerShell session."
    }

    Set-Location $ProjectRoot
    & (Join-Path $PSScriptRoot "build-windows-service.ps1")
    & (Join-Path $PSScriptRoot "install-windows-service.ps1")
}

if ($Help -or (-not $Check -and -not $Install)) {
    Show-Help
    exit 0
}

if ($Check) {
    Invoke-Check
}

if ($Install) {
    Invoke-Install
}
