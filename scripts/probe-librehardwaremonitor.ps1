param(
    [string] $LibraryDirectory = ".\tools\LibreHardwareMonitor",
    [int] $DurationSeconds = 30,
    [int] $IntervalSeconds = 5,
    [string] $OutputPath = ""
)

$ErrorActionPreference = "Stop"

function Resolve-LibraryDirectory {
    param([string] $Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    return $resolved.Path
}

function Get-SensorsFromHardware {
    param([object] $Hardware)

    $sensors = New-Object System.Collections.Generic.List[object]

    foreach ($sensor in $Hardware.Sensors) {
        $sensors.Add([pscustomobject] [ordered] @{
            Hardware = $Hardware.Name
            HardwareType = $Hardware.HardwareType.ToString()
            Identifier = $sensor.Identifier.ToString()
            Name = $sensor.Name
            SensorType = $sensor.SensorType.ToString()
            Value = $sensor.Value
            Min = $sensor.Min
            Max = $sensor.Max
        })
    }

    return $sensors
}

function Test-UsableWatts {
    param([object] $Value)

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [ValueType]) {
        $watts = [double] $Value
    }
    else {
        $watts = 0.0
        $styles = [System.Globalization.NumberStyles]::Float
        $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
        $currentCulture = [System.Globalization.CultureInfo]::CurrentCulture

        if (-not [double]::TryParse([string] $Value, $styles, $invariantCulture, [ref] $watts) -and
            -not [double]::TryParse([string] $Value, $styles, $currentCulture, [ref] $watts)) {
            return $false
        }
    }

    return (-not [double]::IsNaN($watts)) -and
        (-not [double]::IsInfinity($watts)) -and
        $watts -gt 0 -and
        $watts -lt 10000
}

function Get-LibreHardwareSample {
    param([object] $Computer)

    foreach ($hardware in $Computer.Hardware) {
        $hardware.Update()
    }

    $sensors = New-Object System.Collections.Generic.List[object]
    foreach ($hardware in $Computer.Hardware) {
        foreach ($sensor in (Get-SensorsFromHardware -Hardware $hardware)) {
            $sensors.Add($sensor)
        }
    }

    [ordered] @{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        PowerSensors = @($sensors | Where-Object { $_.SensorType -eq "Power" })
    }
}

function Get-Summary {
    param([object[]] $Samples)

    $usablePowerSensors = @(
        $Samples |
            ForEach-Object { $_.PowerSensors } |
            Where-Object { Test-UsableWatts -Value $_.Value } |
            Group-Object Identifier |
            ForEach-Object {
                $latest = $_.Group | Select-Object -Last 1
                [ordered] @{
                    Identifier = $latest.Identifier
                    Hardware = $latest.Hardware
                    Name = $latest.Name
                    LatestWatts = $latest.Value
                    Samples = $_.Count
                }
            }
    )

    $zeroPowerSensors = @(
        $Samples |
            Select-Object -Last 1 |
            ForEach-Object { $_.PowerSensors } |
            Where-Object {
                $_.Value -ne $null -and
                [Math]::Abs([double] $_.Value) -lt 0.000001
            } |
            Select-Object Hardware, Name, Identifier, Value
    )

    [ordered] @{
        RecommendedSource = if ($usablePowerSensors.Count -gt 0) { "librehardwaremonitor_component_power" } else { "none" }
        UsablePowerSensors = $usablePowerSensors
        ZeroPowerSensors = $zeroPowerSensors
        Notes = @(
            "CPU package power may require elevated permissions or LibreHardwareMonitor's low-level driver.",
            "A Windows Service running as LocalSystem may read sensors that a normal user shell cannot.",
            "GPU package power alone is useful but should be combined with CPU power and a configurable platform baseline."
        )
    }
}

if ($IntervalSeconds -lt 1) {
    throw "IntervalSeconds must be at least 1."
}

if ($DurationSeconds -lt 0) {
    throw "DurationSeconds must be 0 or greater."
}

$libraryDirectoryPath = Resolve-LibraryDirectory -Path $LibraryDirectory
$libraryPath = Join-Path $libraryDirectoryPath "LibreHardwareMonitorLib.dll"

if (-not (Test-Path -LiteralPath $libraryPath)) {
    throw "LibreHardwareMonitorLib.dll was not found at $libraryPath"
}

Add-Type -Path $libraryPath

$computer = New-Object LibreHardwareMonitor.Hardware.Computer
$computer.IsCpuEnabled = $true
$computer.IsGpuEnabled = $true
$computer.IsMemoryEnabled = $true
$computer.IsMotherboardEnabled = $true
$computer.IsStorageEnabled = $true
$computer.Open()

try {
    $sampleCount = if ($DurationSeconds -eq 0) { 1 } else { [Math]::Max(1, [Math]::Floor($DurationSeconds / $IntervalSeconds)) }
    $samples = New-Object System.Collections.Generic.List[object]

    for ($index = 0; $index -lt $sampleCount; $index++) {
        $samples.Add((Get-LibreHardwareSample -Computer $computer))

        if ($index -lt ($sampleCount - 1)) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }

    $report = [ordered] @{
        ProbeVersion = 1
        Platform = "windows"
        Provider = "librehardwaremonitor"
        LibraryPath = $libraryPath
        DurationSeconds = $DurationSeconds
        IntervalSeconds = $IntervalSeconds
        Samples = $samples
        Summary = Get-Summary -Samples $samples
    }

    $json = $report | ConvertTo-Json -Depth 10

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $json
    }
    else {
        $directory = Split-Path -Parent $OutputPath
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }

        $json | Set-Content -Encoding UTF8 -Path $OutputPath
        Write-Host "Wrote LibreHardwareMonitor probe report to $OutputPath"
    }
}
finally {
    $computer.Close()
}
