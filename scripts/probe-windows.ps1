param(
    [int] $DurationSeconds = 30,
    [int] $IntervalSeconds = 5,
    [string] $OutputPath = ""
)

$ErrorActionPreference = "Stop"

function Get-CommandPath {
    param([string] $Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

function Invoke-Safe {
    param(
        [scriptblock] $Script,
        [object] $Fallback = $null
    )

    try {
        return & $Script
    }
    catch {
        return $Fallback
    }
}

function Get-CimClassNames {
    param([string] $Namespace)

    Invoke-Safe {
        Get-CimClass -Namespace $Namespace |
            Select-Object -ExpandProperty CimClassName |
            Sort-Object
    } @()
}

function Get-WmiPowerSensors {
    param([string] $Namespace)

    $classes = Get-CimClassNames -Namespace $Namespace
    if ($classes -notcontains "Sensor") {
        return @()
    }

    Invoke-Safe {
        Get-CimInstance -Namespace $Namespace -ClassName Sensor |
            Where-Object {
                $_.SensorType -eq "Power" -or
                $_.SensorType -eq 5 -or
                $_.Name -match "power|watt|package|gpu"
            } |
            Select-Object @{
                Name = "Namespace"
                Expression = { $Namespace }
            }, Identifier, Name, SensorType, Value, Min, Max
    } @()
}

function Get-PowerCounterPaths {
    $counterSets = Invoke-Safe {
        Get-Counter -ListSet *power* |
            Where-Object {
                $_.CounterSetName -match "Power Meter|Energy|Battery|Processor Power" -and
                $_.CounterSetName -notmatch "PowerShell"
            } |
            Select-Object -ExpandProperty PathsWithInstances
    } @()

    $counterSets |
        Where-Object {
            $_ -match "\\Power Meter\(.*\)\\Power" -or
            $_ -match "watt|energy"
        } |
        Sort-Object -Unique
}

function Read-CounterValues {
    param([string[]] $Paths)

    if ($Paths.Count -eq 0) {
        return @()
    }

    $values = New-Object System.Collections.Generic.List[object]

    foreach ($path in $Paths) {
        $sample = Invoke-Safe {
            (Get-Counter -Counter $path -ErrorAction Stop).CounterSamples |
                Select-Object Path, CookedValue, Status
        } @()

        foreach ($item in @($sample)) {
            $values.Add($item)
        }
    }

    $values
}

function Get-BatteryTelemetry {
    $batteryStatus = Invoke-Safe {
        Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus |
            Select-Object InstanceName, PowerOnline, Charging, Discharging,
                Voltage, Rate, ChargeRate, DischargeRate, RemainingCapacity
    } @()

    $win32Battery = Invoke-Safe {
        Get-CimInstance -ClassName Win32_Battery |
            Select-Object Name, BatteryStatus, EstimatedChargeRemaining,
                EstimatedRunTime, DesignVoltage
    } @()

    [ordered] @{
        BatteryStatus = @($batteryStatus)
        Win32Battery = @($win32Battery)
    }
}

function Get-NvidiaTelemetry {
    $nvidiaSmi = Get-CommandPath "nvidia-smi"
    if ($null -eq $nvidiaSmi) {
        return [ordered] @{
            Available = $false
            Path = $null
            PowerReadings = @()
        }
    }

    $csv = Invoke-Safe {
        & $nvidiaSmi --query-gpu=index,name,power.draw,power.limit --format=csv,noheader,nounits
    } @()

    $readings = @($csv | ForEach-Object {
        $parts = $_ -split ",\s*"
        if ($parts.Count -ge 4) {
            $powerDrawWatts = $null
            $powerLimitWatts = $null
            $parsedPowerDraw = 0.0
            $parsedPowerLimit = 0.0

            if ([double]::TryParse($parts[2], [ref] $parsedPowerDraw)) {
                $powerDrawWatts = $parsedPowerDraw
            }

            if ([double]::TryParse($parts[3], [ref] $parsedPowerLimit)) {
                $powerLimitWatts = $parsedPowerLimit
            }

            [ordered] @{
                Index = $parts[0]
                Name = $parts[1]
                PowerDrawWatts = $powerDrawWatts
                PowerLimitWatts = $powerLimitWatts
            }
        }
    })

    [ordered] @{
        Available = $true
        Path = $nvidiaSmi
        PowerReadings = $readings
    }
}

function Get-StaticDiscovery {
    $powerCounterPaths = @(Get-PowerCounterPaths)
    $openHardwareSensors = @(Get-WmiPowerSensors -Namespace "root\OpenHardwareMonitor")
    $libreHardwareSensors = @(Get-WmiPowerSensors -Namespace "root\LibreHardwareMonitor")

    [ordered] @{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        MachineName = $env:COMPUTERNAME
        PowerCounterPaths = $powerCounterPaths
        Battery = Get-BatteryTelemetry
        OpenHardwareMonitorSensors = $openHardwareSensors
        LibreHardwareMonitorSensors = $libreHardwareSensors
        Nvidia = Get-NvidiaTelemetry
    }
}

function Get-LiveSample {
    param([string[]] $PowerCounterPaths)

    [ordered] @{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        Counters = @(Read-CounterValues -Paths $PowerCounterPaths)
        Battery = Get-BatteryTelemetry
        OpenHardwareMonitorSensors = @(Get-WmiPowerSensors -Namespace "root\OpenHardwareMonitor")
        LibreHardwareMonitorSensors = @(Get-WmiPowerSensors -Namespace "root\LibreHardwareMonitor")
        Nvidia = Get-NvidiaTelemetry
    }
}

function Test-UsableWatts {
    param([object] $Value)

    if ($null -eq $Value) {
        return $false
    }

    $watts = 0.0
    if (-not [double]::TryParse([string] $Value, [ref] $watts)) {
        return $false
    }

    return (-not [double]::IsNaN($watts)) -and
        (-not [double]::IsInfinity($watts)) -and
        $watts -gt 0 -and
        $watts -lt 10000 -and
        [Math]::Abs($watts - 2147483648) -gt 0.001
}

function Get-ProbeSummary {
    param([object[]] $Samples)

    $usableCounters = @(
        $Samples |
            ForEach-Object { $_.Counters } |
            Where-Object {
                $_.Path -match "\\power meter\(.*\)\\power$" -and
                (Test-UsableWatts -Value $_.CookedValue)
            } |
            Select-Object Path, CookedValue -Unique
    )

    $usableHardwareSensors = @(
        $Samples |
            ForEach-Object { @($_.OpenHardwareMonitorSensors) + @($_.LibreHardwareMonitorSensors) } |
            Where-Object { Test-UsableWatts -Value $_.Value } |
            Select-Object Namespace, Identifier, Name, Value -Unique
    )

    $usableNvidiaSensors = @(
        $Samples |
            ForEach-Object { $_.Nvidia.PowerReadings } |
            Where-Object { Test-UsableWatts -Value $_.PowerDrawWatts } |
            Select-Object Index, Name, PowerDrawWatts -Unique
    )

    $usableBatteryRates = @(
        $Samples |
            ForEach-Object { $_.Battery.BatteryStatus } |
            Where-Object {
                (Test-UsableWatts -Value (($_.Rate) / 1000.0)) -or
                (Test-UsableWatts -Value (($_.ChargeRate) / 1000.0)) -or
                (Test-UsableWatts -Value (($_.DischargeRate) / 1000.0))
            } |
            Select-Object InstanceName, PowerOnline, Charging, Discharging,
                Rate, ChargeRate, DischargeRate -Unique
    )

    $recommendedSource = "none"
    if ($usableCounters.Count -gt 0) {
        $recommendedSource = "direct_power_counter"
    }
    elseif ($usableHardwareSensors.Count -gt 0 -or $usableNvidiaSensors.Count -gt 0) {
        $recommendedSource = "component_power_estimate"
    }
    elseif ($usableBatteryRates.Count -gt 0) {
        $recommendedSource = "battery_rate_context_only"
    }

    [ordered] @{
        RecommendedSource = $recommendedSource
        UsableDirectPowerCounters = $usableCounters
        UsableHardwarePowerSensors = $usableHardwareSensors
        UsableNvidiaPowerSensors = $usableNvidiaSensors
        UsableBatteryRates = $usableBatteryRates
        Notes = @(
            "A Power Meter counter value of 2147483648 is treated as unusable.",
            "Battery rates are not enough for plugged-and-full wall consumption.",
            "If no direct source is usable, run LibreHardwareMonitor/OpenHardwareMonitor with WMI enabled or use a service provider library."
        )
    }
}

if ($IntervalSeconds -lt 1) {
    throw "IntervalSeconds must be at least 1."
}

if ($DurationSeconds -lt 0) {
    throw "DurationSeconds must be 0 or greater."
}

$discovery = Get-StaticDiscovery
$sampleCount = if ($DurationSeconds -eq 0) { 1 } else { [Math]::Max(1, [Math]::Floor($DurationSeconds / $IntervalSeconds)) }
$samples = New-Object System.Collections.Generic.List[object]

for ($index = 0; $index -lt $sampleCount; $index++) {
    $samples.Add((Get-LiveSample -PowerCounterPaths $discovery.PowerCounterPaths))

    if ($index -lt ($sampleCount - 1)) {
        Start-Sleep -Seconds $IntervalSeconds
    }
}

$report = [ordered] @{
    ProbeVersion = 1
    Platform = "windows"
    DurationSeconds = $DurationSeconds
    IntervalSeconds = $IntervalSeconds
    Discovery = $discovery
    Samples = $samples
    Summary = Get-ProbeSummary -Samples $samples
    Interpretation = [ordered] @{
        BestSignals = @(
            "PowerCounterPaths containing \\Power Meter(*)\\Power indicate a direct system/adapter power sensor.",
            "OpenHardwareMonitor or LibreHardwareMonitor Power sensors can provide CPU/GPU/component watts if their WMI provider is running.",
            "Nvidia PowerDrawWatts is useful GPU power if nvidia-smi is available.",
            "Battery Rate/ChargeRate/DischargeRate is mostly useful on battery or while charging, not when plugged and full."
        )
    }
}

$json = $report | ConvertTo-Json -Depth 8

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $json
}
else {
    $directory = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $json | Set-Content -Encoding UTF8 -Path $OutputPath
    Write-Host "Wrote probe report to $OutputPath"
}
