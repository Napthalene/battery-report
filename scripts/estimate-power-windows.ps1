param(
    [string] $ConfigPath = ".\config\power-estimator.windows.json",
    [int] $DurationSeconds = 300,
    [switch] $Once
)

$ErrorActionPreference = "Stop"
$invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture = $invariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $invariantCulture
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:InstanceMutex = $null

function Enter-SingleInstance {
    $createdNew = $false
    try {
        $script:InstanceMutex = New-Object System.Threading.Mutex($true, "Global\BatteryServicePowerEstimator", [ref] $createdNew)
    }
    catch {
        $script:InstanceMutex = New-Object System.Threading.Mutex($true, "BatteryServicePowerEstimator", [ref] $createdNew)
    }

    if (-not $createdNew) {
        Write-Host "Another BatteryService estimator instance is already running. Exiting."
        exit 0
    }
}

function Read-Config {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file was not found: $Path"
    }

    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Convert-ToAbsolutePath {
    param(
        [string] $Path,
        [string] $BasePath = $script:ProjectRoot
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $BasePath $Path
}

function Import-LibreHardwareMonitor {
    param([string] $Directory)

    $absoluteDirectory = Convert-ToAbsolutePath -Path $Directory
    $libraryPath = Join-Path $absoluteDirectory "LibreHardwareMonitorLib.dll"

    if (-not (Test-Path -LiteralPath $libraryPath)) {
        return $null
    }

    Add-Type -Path $libraryPath

    $computer = New-Object LibreHardwareMonitor.Hardware.Computer
    $computer.IsCpuEnabled = $true
    $computer.IsGpuEnabled = $true
    $computer.IsMemoryEnabled = $true
    $computer.IsMotherboardEnabled = $true
    $computer.IsStorageEnabled = $true
    $computer.Open()

    return $computer
}

function Get-LibreHardwareCpuLoadPercent {
    param([object] $Computer)

    if ($null -eq $Computer) {
        return $null
    }

    foreach ($hardware in $Computer.Hardware) {
        if ($hardware.HardwareType.ToString() -ne "Cpu") {
            continue
        }

        $hardware.Update()

        $totalLoad = $hardware.Sensors |
            Where-Object {
                $_.SensorType.ToString() -eq "Load" -and
                ($_.Name -eq "CPU Total" -or $_.Name -eq "CPU Core #1" -or $_.Name -match "CPU")
            } |
            Select-Object -First 1

        if ($null -ne $totalLoad -and $null -ne $totalLoad.Value) {
            return [double] $totalLoad.Value
        }
    }

    return $null
}

function Get-CimProcessorLoadPercent {
    try {
        $processor = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor |
            Where-Object { $_.Name -eq "_Total" } |
            Select-Object -First 1

        if ($null -ne $processor) {
            return [double] $processor.PercentProcessorTime
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-ProcessorLoadPercent {
    param([object] $Computer)

    $load = Get-LibreHardwareCpuLoadPercent -Computer $Computer

    if ($null -eq $load) {
        $load = Get-CimProcessorLoadPercent
    }

    if ($null -eq $load) {
        throw "Unable to read CPU load from LibreHardwareMonitor or CIM."
    }

    if ($load -lt 0) {
        return 0.0
    }

    if ($load -gt 100) {
        return 100.0
    }

    return $load
}

function Get-LibreHardwarePowerSensors {
    param([object] $Computer)

    if ($null -eq $Computer) {
        return @()
    }

    $readings = New-Object System.Collections.Generic.List[object]

    foreach ($hardware in $Computer.Hardware) {
        $hardware.Update()

        foreach ($sensor in $hardware.Sensors) {
            if ($sensor.SensorType.ToString() -ne "Power" -or $null -eq $sensor.Value) {
                continue
            }

            $watts = [double] $sensor.Value
            if ($watts -lt 0 -or $watts -ge 10000) {
                continue
            }

            $readings.Add([pscustomobject] @{
                Hardware = $hardware.Name
                HardwareType = $hardware.HardwareType.ToString()
                Name = $sensor.Name
                Identifier = $sensor.Identifier.ToString()
                Watts = $watts
            })
        }
    }

    return $readings
}

function Get-NvidiaPowerWatts {
    $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if ($null -eq $nvidiaSmi) {
        return $null
    }

    $rows = & $nvidiaSmi.Source --query-gpu=power.draw --format=csv,noheader,nounits 2>$null
    $total = 0.0
    $count = 0

    foreach ($row in @($rows)) {
        $watts = 0.0
        $styles = [System.Globalization.NumberStyles]::Float
        $culture = [System.Globalization.CultureInfo]::InvariantCulture

        if ([double]::TryParse($row.Trim(), $styles, $culture, [ref] $watts) -and $watts -gt 0) {
            $total += $watts
            $count++
        }
    }

    if ($count -eq 0) {
        return $null
    }

    return $total
}

function Get-GpuPowerWatts {
    param(
        [object] $Computer,
        [bool] $IncludeLibreHardwareMonitorGpu,
        [bool] $IncludeNvidiaGpu
    )

    if ($IncludeLibreHardwareMonitorGpu) {
        $lhmGpuWatts = @(
            Get-LibreHardwarePowerSensors -Computer $Computer |
                Where-Object {
                    $_.HardwareType -match "Gpu" -and
                    $_.Watts -gt 0
                }
        )

        if ($lhmGpuWatts.Count -gt 0) {
            return ($lhmGpuWatts | Measure-Object -Property Watts -Sum).Sum
        }
    }

    if ($IncludeNvidiaGpu) {
        return Get-NvidiaPowerWatts
    }

    return $null
}

function Get-BatteryTelemetry {
    $batteryStatuses = @()
    $win32Batteries = @()
    $fullChargedCapacityMWh = $null
    $designedCapacityMWh = $null

    try {
        $batteryStatuses = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop)
    }
    catch {
        $batteryStatuses = @()
    }

    try {
        $win32Batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
    }
    catch {
        $win32Batteries = @()
    }

    try {
        $fullChargedCapacity = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop |
            Select-Object -First 1

        if ($null -ne $fullChargedCapacity -and $null -ne $fullChargedCapacity.FullChargedCapacity) {
            $fullChargedCapacityMWh = [double] $fullChargedCapacity.FullChargedCapacity
        }
    }
    catch {
    }

    try {
        $staticData = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop |
            Select-Object -First 1

        if ($null -ne $staticData -and $null -ne $staticData.DesignedCapacity) {
            $designedCapacityMWh = [double] $staticData.DesignedCapacity
        }
    }
    catch {
    }

    $powerOnline = $null
    $charging = $null
    $discharging = $null
    $chargeRateWatts = $null
    $dischargeRateWatts = $null
    $batteryRateWatts = $null
    $voltageVolts = $null
    $remainingCapacityMWh = $null
    $chargePercent = $null
    $statusText = "unknown"

    function Convert-MilliwattRate {
        param([object] $Rate)

        if ($null -eq $Rate) {
            return $null
        }

        $watts = [Math]::Abs([double] $Rate) / 1000.0
        if ($watts -le 0 -or $watts -ge 10000 -or [Math]::Abs($watts - 2147483.648) -lt 0.001) {
            return $null
        }

        return $watts
    }

    $status = $batteryStatuses | Select-Object -First 1
    if ($null -ne $status) {
        $powerOnline = $status.PowerOnline
        $charging = $status.Charging
        $discharging = $status.Discharging

        if ($null -ne $status.ChargeRate) {
            $chargeRateWatts = Convert-MilliwattRate -Rate $status.ChargeRate
        }

        if ($null -ne $status.DischargeRate) {
            $dischargeRateWatts = Convert-MilliwattRate -Rate $status.DischargeRate
        }

        if ($null -ne $status.Rate) {
            $batteryRateWatts = Convert-MilliwattRate -Rate $status.Rate
        }

        if ($null -ne $status.Voltage) {
            $voltageVolts = [double] $status.Voltage / 1000.0
        }

        if ($null -ne $status.RemainingCapacity) {
            $remainingCapacityMWh = [double] $status.RemainingCapacity
        }
    }

    $battery = $win32Batteries | Select-Object -First 1
    if ($null -ne $battery -and $null -ne $battery.EstimatedChargeRemaining) {
        $chargePercent = [double] $battery.EstimatedChargeRemaining
    }

    if ($null -eq $chargePercent -or $statusText -eq "unknown") {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $powerStatus = [System.Windows.Forms.SystemInformation]::PowerStatus

            if ($null -eq $chargePercent -and $powerStatus.BatteryLifePercent -ge 0) {
                $chargePercent = [Math]::Round($powerStatus.BatteryLifePercent * 100.0, 3)
            }

            if ($null -eq $powerOnline) {
                $powerOnline = $powerStatus.PowerLineStatus.ToString() -eq "Online"
            }

            $chargeStatusText = $powerStatus.BatteryChargeStatus.ToString()
            if ($statusText -eq "unknown") {
                if ($chargeStatusText -match "Charging") {
                    $charging = $true
                    $statusText = "charging"
                }
                elseif ($powerOnline -eq $true) {
                    $statusText = "plugged"
                }
                elseif ($powerOnline -eq $false) {
                    $discharging = $true
                    $statusText = "battery"
                }
            }
        }
        catch {
        }
    }

    if ($charging -eq $true) {
        $statusText = "charging"
    }
    elseif ($discharging -eq $true) {
        $statusText = "discharging"
    }
    elseif ($powerOnline -eq $true) {
        $statusText = "plugged"
    }
    elseif ($powerOnline -eq $false) {
        $statusText = "battery"
    }

    [pscustomobject] @{
        PowerOnline = $powerOnline
        Charging = $charging
        Discharging = $discharging
        Status = $statusText
        ChargeRateWatts = $chargeRateWatts
        DischargeRateWatts = $dischargeRateWatts
        BatteryRateWatts = $batteryRateWatts
        VoltageVolts = $voltageVolts
        RemainingCapacityMWh = $remainingCapacityMWh
        FullChargedCapacityMWh = $fullChargedCapacityMWh
        DesignedCapacityMWh = $designedCapacityMWh
        ChargePercent = $chargePercent
    }
}

function Get-CpuEstimatedWatts {
    param(
        [double] $LoadPercent,
        [double] $IdleWatts,
        [double] $TdpWatts,
        [double] $CurveExponent
    )

    $loadRatio = [Math]::Max(0.0, [Math]::Min(1.0, $LoadPercent / 100.0))
    $dynamicRange = [Math]::Max(0.0, $TdpWatts - $IdleWatts)
    $curvedLoad = [Math]::Pow($loadRatio, $CurveExponent)

    return $IdleWatts + ($dynamicRange * $curvedLoad)
}

function Get-PowerSample {
    param(
        [object] $Config,
        [object] $Computer
    )

    $cpuLoadPercent = Get-ProcessorLoadPercent -Computer $Computer
    $cpuEstimatedWatts = Get-CpuEstimatedWatts `
        -LoadPercent $cpuLoadPercent `
        -IdleWatts ([double] $Config.cpuIdleWatts) `
        -TdpWatts ([double] $Config.cpuTdpWatts) `
        -CurveExponent ([double] $Config.cpuCurveExponent)

    $gpuWatts = Get-GpuPowerWatts `
        -Computer $Computer `
        -IncludeLibreHardwareMonitorGpu ([bool] $Config.includeLibreHardwareMonitorGpu) `
        -IncludeNvidiaGpu ([bool] $Config.includeNvidiaGpu)

    if ($null -eq $gpuWatts) {
        $gpuWatts = 0.0
        $gpuSource = "unavailable"
    }
    else {
        $gpuSource = "measured"
    }

    $baselineWatts = [double] $Config.platformBaselineWatts
    $estimatedTotalWatts = $cpuEstimatedWatts + [double] $gpuWatts + $baselineWatts
    $batteryTelemetry = Get-BatteryTelemetry
    if (
        ($null -eq $batteryTelemetry.FullChargedCapacityMWh -or $batteryTelemetry.FullChargedCapacityMWh -le 0) -and
        $null -ne $Config.batteryFullChargeCapacityWh
    ) {
        $batteryTelemetry.FullChargedCapacityMWh = [double] $Config.batteryFullChargeCapacityWh * 1000.0
    }

    if (
        ($null -eq $batteryTelemetry.DesignedCapacityMWh -or $batteryTelemetry.DesignedCapacityMWh -le 0) -and
        $null -ne $Config.batteryDesignCapacityWh
    ) {
        $batteryTelemetry.DesignedCapacityMWh = [double] $Config.batteryDesignCapacityWh * 1000.0
    }

    [pscustomobject] @{
        TimestampUtc = (Get-Date).ToUniversalTime()
        CpuLoadPercent = $cpuLoadPercent
        CpuEstimatedWatts = $cpuEstimatedWatts
        GpuWatts = [double] $gpuWatts
        PlatformBaselineWatts = $baselineWatts
        EstimatedTotalWatts = $estimatedTotalWatts
        BatteryStatus = $batteryTelemetry.Status
        BatteryPowerOnline = $batteryTelemetry.PowerOnline
        BatteryCharging = $batteryTelemetry.Charging
        BatteryDischarging = $batteryTelemetry.Discharging
        BatteryChargeRateWatts = $batteryTelemetry.ChargeRateWatts
        BatteryDischargeRateWatts = $batteryTelemetry.DischargeRateWatts
        BatteryRateWatts = $batteryTelemetry.BatteryRateWatts
        BatteryVoltageVolts = $batteryTelemetry.VoltageVolts
        BatteryRemainingCapacityMWh = $batteryTelemetry.RemainingCapacityMWh
        BatteryFullChargedCapacityMWh = $batteryTelemetry.FullChargedCapacityMWh
        BatteryDesignedCapacityMWh = $batteryTelemetry.DesignedCapacityMWh
        BatteryChargePercent = $batteryTelemetry.ChargePercent
        Source = "cpu_load_curve+gpu_$gpuSource+baseline"
        Confidence = "estimated"
    }
}

function Get-MinuteAggregate {
    param([object[]] $Samples)

    $averageWatts = ($Samples | Measure-Object -Property EstimatedTotalWatts -Average).Average
    $minimumWatts = ($Samples | Measure-Object -Property EstimatedTotalWatts -Minimum).Minimum
    $maximumWatts = ($Samples | Measure-Object -Property EstimatedTotalWatts -Maximum).Maximum
    $averageCpuWatts = ($Samples | Measure-Object -Property CpuEstimatedWatts -Average).Average
    $averageGpuWatts = ($Samples | Measure-Object -Property GpuWatts -Average).Average
    $averageCpuLoad = ($Samples | Measure-Object -Property CpuLoadPercent -Average).Average
    $averageBatteryChargeRateWatts = ($Samples | Where-Object { $null -ne $_.BatteryChargeRateWatts } | Measure-Object -Property BatteryChargeRateWatts -Average).Average
    $averageBatteryDischargeRateWatts = ($Samples | Where-Object { $null -ne $_.BatteryDischargeRateWatts } | Measure-Object -Property BatteryDischargeRateWatts -Average).Average
    $averageBatteryRateWatts = ($Samples | Where-Object { $null -ne $_.BatteryRateWatts } | Measure-Object -Property BatteryRateWatts -Average).Average
    $averageBatteryVoltageVolts = ($Samples | Where-Object { $null -ne $_.BatteryVoltageVolts } | Measure-Object -Property BatteryVoltageVolts -Average).Average
    $averageBatteryChargePercent = ($Samples | Where-Object { $null -ne $_.BatteryChargePercent } | Measure-Object -Property BatteryChargePercent -Average).Average
    $first = $Samples | Select-Object -First 1
    $last = $Samples | Select-Object -Last 1
    $durationSeconds = [Math]::Max(1.0, (($last.TimestampUtc - $first.TimestampUtc).TotalSeconds + 1.0))
    $systemEnergyWh = $averageWatts * ($durationSeconds / 3600.0)
    $chargingWatts = 0.0
    $chargingSource = "unavailable"

    if ($null -ne $averageBatteryChargeRateWatts -and $averageBatteryChargeRateWatts -gt 0) {
        $chargingWatts = $averageBatteryChargeRateWatts
        $chargingSource = "battery_charge_rate"
    }
    elseif ($first.BatteryStatus -eq "charging" -or $last.BatteryStatus -eq "charging") {
        $capacityMWh = $last.BatteryFullChargedCapacityMWh
        if ($null -eq $capacityMWh -or $capacityMWh -le 0) {
            $capacityMWh = $last.BatteryDesignedCapacityMWh
        }

        if (
            $null -ne $capacityMWh -and
            $capacityMWh -gt 0 -and
            $null -ne $first.BatteryChargePercent -and
            $null -ne $last.BatteryChargePercent -and
            $last.BatteryChargePercent -gt $first.BatteryChargePercent -and
            $durationSeconds -gt 0
        ) {
            $deltaPercent = $last.BatteryChargePercent - $first.BatteryChargePercent
            $chargingEnergyWhFromPercent = ($deltaPercent / 100.0) * ($capacityMWh / 1000.0)
            $chargingWatts = $chargingEnergyWhFromPercent / ($durationSeconds / 3600.0)
            $chargingSource = "battery_percent_delta"
        }
    }

    $chargingEnergyWh = $chargingWatts * ($durationSeconds / 3600.0)
    $totalWithChargingWatts = $averageWatts + $chargingWatts
    $totalEnergyWh = $systemEnergyWh + $chargingEnergyWh

    [pscustomobject] @{
        timestamp_utc = $first.TimestampUtc.ToString("o")
        sample_count = $Samples.Count
        duration_seconds = [Math]::Round($durationSeconds, 3)
        average_watts = [Math]::Round($totalWithChargingWatts, 3)
        average_system_watts = [Math]::Round($averageWatts, 3)
        average_charging_watts = [Math]::Round($chargingWatts, 3)
        average_total_with_charging_watts = [Math]::Round($totalWithChargingWatts, 3)
        minimum_watts = [Math]::Round($minimumWatts, 3)
        maximum_watts = [Math]::Round($maximumWatts, 3)
        average_cpu_load_percent = [Math]::Round($averageCpuLoad, 3)
        average_cpu_estimated_watts = [Math]::Round($averageCpuWatts, 3)
        average_gpu_watts = [Math]::Round($averageGpuWatts, 3)
        platform_baseline_watts = [Math]::Round([double] $first.PlatformBaselineWatts, 3)
        battery_status = $last.BatteryStatus
        battery_power_online = $last.BatteryPowerOnline
        battery_charging = $last.BatteryCharging
        battery_discharging = $last.BatteryDischarging
        average_battery_charge_rate_watts = if ($null -ne $averageBatteryChargeRateWatts) { [Math]::Round($averageBatteryChargeRateWatts, 3) } else { "" }
        average_battery_discharge_rate_watts = if ($null -ne $averageBatteryDischargeRateWatts) { [Math]::Round($averageBatteryDischargeRateWatts, 3) } else { "" }
        average_battery_rate_watts = if ($null -ne $averageBatteryRateWatts) { [Math]::Round($averageBatteryRateWatts, 3) } else { "" }
        average_battery_voltage_volts = if ($null -ne $averageBatteryVoltageVolts) { [Math]::Round($averageBatteryVoltageVolts, 3) } else { "" }
        average_battery_charge_percent = if ($null -ne $averageBatteryChargePercent) { [Math]::Round($averageBatteryChargePercent, 3) } else { "" }
        battery_full_charged_capacity_mwh = if ($null -ne $last.BatteryFullChargedCapacityMWh) { [Math]::Round([double] $last.BatteryFullChargedCapacityMWh, 3) } else { "" }
        battery_designed_capacity_mwh = if ($null -ne $last.BatteryDesignedCapacityMWh) { [Math]::Round([double] $last.BatteryDesignedCapacityMWh, 3) } else { "" }
        charging_source = $chargingSource
        system_energy_wh = [Math]::Round($systemEnergyWh, 6)
        charging_energy_wh = [Math]::Round($chargingEnergyWh, 6)
        total_energy_wh = [Math]::Round($totalEnergyWh, 6)
        energy_wh = [Math]::Round($totalEnergyWh, 6)
        source = $first.Source
        confidence = $first.Confidence
    }
}

function Save-MinuteAggregate {
    param(
        [object] $Aggregate,
        [string] $OutputPath
    )

    $absoluteOutputPath = Convert-ToAbsolutePath -Path $OutputPath
    $directory = Split-Path -Parent $absoluteOutputPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    if (Test-Path -LiteralPath $absoluteOutputPath) {
        $existingHeader = Get-Content -LiteralPath $absoluteOutputPath -TotalCount 1
        $requiredColumns = @(
            "battery_status",
            "battery_power_online",
            "battery_charging",
            "battery_discharging",
            "average_battery_charge_rate_watts",
            "average_battery_discharge_rate_watts",
            "average_battery_rate_watts",
            "average_battery_voltage_volts",
            "average_battery_charge_percent",
            "average_system_watts",
            "average_charging_watts",
            "average_total_with_charging_watts",
            "system_energy_wh",
            "charging_energy_wh",
            "total_energy_wh",
            "battery_full_charged_capacity_mwh",
            "battery_designed_capacity_mwh",
            "charging_source"
        )

        $missingColumns = @($requiredColumns | Where-Object { $existingHeader -notmatch "`"$_`"" })
        if ($missingColumns.Count -gt 0) {
            $backupPath = "$absoluteOutputPath.legacy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $absoluteOutputPath -Destination $backupPath -Force
            Write-Host "Backed up old CSV schema to $backupPath"
        }
    }

    if (-not (Test-Path -LiteralPath $absoluteOutputPath)) {
        $Aggregate | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $absoluteOutputPath
        return
    }

    $Aggregate | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $absoluteOutputPath -Append -Force
}

Enter-SingleInstance

$absoluteConfigPath = Convert-ToAbsolutePath -Path $ConfigPath
$config = Read-Config -Path $absoluteConfigPath
$sampleIntervalSeconds = [int] $config.sampleIntervalSeconds
if ($sampleIntervalSeconds -lt 1) {
    throw "sampleIntervalSeconds must be at least 1."
}

$computer = Import-LibreHardwareMonitor -Directory ([string] $config.libreHardwareMonitorDirectory)

try {
    $runUntil = if ($DurationSeconds -gt 0) {
        (Get-Date).ToUniversalTime().AddSeconds($DurationSeconds)
    }
    else {
        [DateTime]::MaxValue
    }

    $samples = New-Object System.Collections.Generic.List[object]
    $minuteStart = (Get-Date).ToUniversalTime()

    do {
        $sample = Get-PowerSample -Config $config -Computer $computer
        $samples.Add($sample)

        $sampleLine = "{0} system={1:n2}W cpu={2:n2}W gpu={3:n2}W load={4:n1}% baseline={5:n2}W" -f `
            $sample.TimestampUtc.ToString("o"),
            $sample.EstimatedTotalWatts,
            $sample.CpuEstimatedWatts,
            $sample.GpuWatts,
            $sample.CpuLoadPercent,
            $sample.PlatformBaselineWatts
        if ($sample.BatteryStatus -ne "unknown") {
            $sampleLine += " battery={0} chargeRate={1:n2}W percent={2:n1}%" -f `
                $sample.BatteryStatus,
                $(if ($null -ne $sample.BatteryChargeRateWatts) { $sample.BatteryChargeRateWatts } else { 0.0 }),
                $(if ($null -ne $sample.BatteryChargePercent) { $sample.BatteryChargePercent } else { 0.0 })
        }
        Write-Host $sampleLine

        $elapsedMinuteSeconds = ((Get-Date).ToUniversalTime() - $minuteStart).TotalSeconds
        if ($Once -or $elapsedMinuteSeconds -ge 60 -or (Get-Date).ToUniversalTime().AddSeconds($sampleIntervalSeconds) -gt $runUntil) {
            $aggregate = Get-MinuteAggregate -Samples $samples.ToArray()
            Save-MinuteAggregate -Aggregate $aggregate -OutputPath ([string] $config.minuteOutputPath)
            Write-Host ("Saved aggregate: {0:n3} W, {1:n6} Wh" -f $aggregate.average_watts, $aggregate.energy_wh)
            $samples.Clear()
            $minuteStart = (Get-Date).ToUniversalTime()

            if ($Once) {
                break
            }
        }

        if ((Get-Date).ToUniversalTime().AddSeconds($sampleIntervalSeconds) -le $runUntil) {
            Start-Sleep -Seconds $sampleIntervalSeconds
        }
    }
    while ((Get-Date).ToUniversalTime() -lt $runUntil)
}
finally {
    if ($null -ne $computer) {
        $computer.Close()
    }

    if ($null -ne $script:InstanceMutex) {
        $script:InstanceMutex.ReleaseMutex()
        $script:InstanceMutex.Dispose()
    }
}
