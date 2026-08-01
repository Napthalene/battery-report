param(
    [string] $OutputPath = ".\bin\windows\BatteryService.WindowsService.exe"
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $projectRoot "src\windows\BatteryService.WindowsService.cs"
$absoluteOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
}
else {
    Join-Path $projectRoot $OutputPath
}

$cscCandidates = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)

$cscPath = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($null -eq $cscPath) {
    throw "Could not find .NET Framework csc.exe."
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $absoluteOutputPath) | Out-Null

& $cscPath `
    /nologo `
    /target:exe `
    /optimize+ `
    /reference:System.ServiceProcess.dll `
    /out:$absoluteOutputPath `
    $sourcePath

if ($LASTEXITCODE -ne 0) {
    throw "Windows service build failed with exit code $LASTEXITCODE."
}

Write-Host "Built Windows service wrapper: $absoluteOutputPath"
