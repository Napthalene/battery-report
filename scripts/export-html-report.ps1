param(
    [string] $InputPath = ".\logs\power-minute.csv",
    [string] $ConfigPath = ".\config\power-estimator.windows.json",
    [string] $OutputPath = ".\reports\power-report.html",
    [int] $RecentHours = 24,
    [bool] $IncludeLegacy = $true,
    [int] $Days = 0
)

$ErrorActionPreference = "Stop"
$invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture = $invariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $invariantCulture

$projectRoot = Split-Path -Parent $PSScriptRoot

function Convert-ToAbsolutePath {
    param([string] $Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $projectRoot $Path
}

function Convert-ToDouble {
    param([object] $Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string] $Value)) {
        return 0.0
    }

    $text = ([string] $Value).Trim().Replace(",", ".")
    return [double]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Convert-ToJsonLiteral {
    param([object] $Value)

    $Value | ConvertTo-Json -Depth 8 -Compress
}

function Read-BatteryCapacityWh {
    param([string] $Path)

    $absoluteConfigPath = Convert-ToAbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $absoluteConfigPath)) {
        return 0.0
    }

    try {
        $config = Get-Content -Raw -LiteralPath $absoluteConfigPath | ConvertFrom-Json
        if ($null -ne $config.batteryFullChargeCapacityWh -and [double] $config.batteryFullChargeCapacityWh -gt 0) {
            return [double] $config.batteryFullChargeCapacityWh
        }

        if ($null -ne $config.batteryDesignCapacityWh -and [double] $config.batteryDesignCapacityWh -gt 0) {
            return [double] $config.batteryDesignCapacityWh
        }
    }
    catch {
    }

    return 0.0
}

$absoluteInputPath = Convert-ToAbsolutePath -Path $InputPath
$absoluteOutputPath = Convert-ToAbsolutePath -Path $OutputPath
$batteryCapacityWh = Read-BatteryCapacityWh -Path $ConfigPath

if (-not (Test-Path -LiteralPath $absoluteInputPath)) {
    throw "Input CSV was not found: $absoluteInputPath"
}

$inputFiles = @()
if ($IncludeLegacy) {
    $inputDirectory = Split-Path -Parent $absoluteInputPath
    $inputName = Split-Path -Leaf $absoluteInputPath
    $inputFiles = @(
        Get-ChildItem -LiteralPath $inputDirectory -File |
            Where-Object { $_.Name -eq $inputName -or $_.Name -like "$inputName.legacy-*" } |
            Sort-Object LastWriteTime
    )
}
else {
    $inputFiles = @(Get-Item -LiteralPath $absoluteInputPath)
}

$rows = @(
    $inputFiles | ForEach-Object {
        Import-Csv -LiteralPath $_.FullName
    }
)

$rows = @(
    $rows |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.timestamp_utc) } |
        Group-Object timestamp_utc |
        ForEach-Object { $_.Group | Select-Object -Last 1 } |
        Sort-Object { [DateTimeOffset]::Parse($_.timestamp_utc) }
)

if ($Days -gt 0) {
    $cutoffUtc = [DateTimeOffset]::UtcNow.AddDays(-1 * $Days)
    $rows = @(
        $rows | Where-Object {
            [DateTimeOffset]::Parse($_.timestamp_utc) -ge $cutoffUtc
        }
    )
}

if ($rows.Count -eq 0) {
    throw "Input CSV contains no data rows for the requested report window: $absoluteInputPath"
}

$points = @(
    $rows | ForEach-Object {
        $systemWatts = Convert-ToDouble $_.average_system_watts
        if ($systemWatts -eq 0) {
            $systemWatts = Convert-ToDouble $_.average_watts
        }

        $chargingWatts = Convert-ToDouble $_.average_charging_watts
        if ($chargingWatts -eq 0) {
            $chargingWatts = Convert-ToDouble $_.average_battery_charge_rate_watts
        }

        $totalWatts = Convert-ToDouble $_.average_total_with_charging_watts
        if ($totalWatts -eq 0) {
            $totalWatts = $systemWatts + $chargingWatts
        }

        $systemEnergyWh = Convert-ToDouble $_.system_energy_wh
        if ($systemEnergyWh -eq 0) {
            $systemEnergyWh = Convert-ToDouble $_.energy_wh
        }

        $chargingEnergyWh = Convert-ToDouble $_.charging_energy_wh
        $totalEnergyWh = Convert-ToDouble $_.total_energy_wh
        if ($totalEnergyWh -eq 0) {
            $totalEnergyWh = $systemEnergyWh + $chargingEnergyWh
        }

        [pscustomobject] @{
            timestampUtc = $_.timestamp_utc
            timestampLocal = ([DateTimeOffset]::Parse($_.timestamp_utc)).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
            durationSeconds = [Math]::Round((Convert-ToDouble $_.duration_seconds), 3)
            systemWatts = [Math]::Round($systemWatts, 3)
            chargingWatts = [Math]::Round($chargingWatts, 3)
            totalWatts = [Math]::Round($totalWatts, 3)
            averageWatts = [Math]::Round($totalWatts, 3)
            minimumWatts = [Math]::Round((Convert-ToDouble $_.minimum_watts), 3)
            maximumWatts = [Math]::Round((Convert-ToDouble $_.maximum_watts), 3)
            cpuWatts = [Math]::Round((Convert-ToDouble $_.average_cpu_estimated_watts), 3)
            gpuWatts = [Math]::Round((Convert-ToDouble $_.average_gpu_watts), 3)
            baselineWatts = [Math]::Round((Convert-ToDouble $_.platform_baseline_watts), 3)
            batteryStatus = $_.battery_status
            batteryCharging = $_.battery_charging
            batteryChargeRateWatts = [Math]::Round((Convert-ToDouble $_.average_battery_charge_rate_watts), 3)
            batteryDischargeRateWatts = [Math]::Round((Convert-ToDouble $_.average_battery_discharge_rate_watts), 3)
            batteryRateWatts = [Math]::Round((Convert-ToDouble $_.average_battery_rate_watts), 3)
            batteryVoltageVolts = [Math]::Round((Convert-ToDouble $_.average_battery_voltage_volts), 3)
            batteryChargePercent = [Math]::Round((Convert-ToDouble $_.average_battery_charge_percent), 3)
            cpuLoadPercent = [Math]::Round((Convert-ToDouble $_.average_cpu_load_percent), 3)
            systemEnergyWh = [Math]::Round($systemEnergyWh, 6)
            chargingEnergyWh = [Math]::Round($chargingEnergyWh, 6)
            totalEnergyWh = [Math]::Round($totalEnergyWh, 6)
            energyWh = [Math]::Round($totalEnergyWh, 6)
            chargingSource = $_.charging_source
            source = $_.source
            confidence = $_.confidence
        }
    }
)

for ($index = 1; $index -lt $points.Count; $index++) {
    $previousPoint = $points[$index - 1]
    $currentPoint = $points[$index]
    $percentDelta = $currentPoint.batteryChargePercent - $previousPoint.batteryChargePercent

    if (
        $batteryCapacityWh -gt 0 -and
        $currentPoint.chargingWatts -le 0 -and
        $currentPoint.batteryStatus -eq "charging" -and
        $percentDelta -gt 0
    ) {
        $chargingEnergyWh = ($percentDelta / 100.0) * $batteryCapacityWh
        $elapsedSeconds = ([DateTimeOffset]::Parse($currentPoint.timestampUtc) - [DateTimeOffset]::Parse($previousPoint.timestampUtc)).TotalSeconds
        if ($elapsedSeconds -le 0) {
            $elapsedSeconds = [Math]::Max(1.0, $currentPoint.durationSeconds)
        }

        $durationHours = $elapsedSeconds / 3600.0
        $chargingWatts = $chargingEnergyWh / $durationHours

        $currentPoint.chargingWatts = [Math]::Round($chargingWatts, 3)
        $currentPoint.batteryChargeRateWatts = [Math]::Round($chargingWatts, 3)
        $currentPoint.chargingEnergyWh = [Math]::Round($chargingEnergyWh, 6)
        $currentPoint.totalWatts = [Math]::Round($currentPoint.systemWatts + $chargingWatts, 3)
        $currentPoint.averageWatts = $currentPoint.totalWatts
        $currentPoint.totalEnergyWh = [Math]::Round($currentPoint.systemEnergyWh + $chargingEnergyWh, 6)
        $currentPoint.energyWh = $currentPoint.totalEnergyWh
        $currentPoint.chargingSource = "battery_percent_delta_report"
    }
}

$totalWh = ($points | Measure-Object -Property totalEnergyWh -Sum).Sum
$systemWh = ($points | Measure-Object -Property systemEnergyWh -Sum).Sum
$chargingWh = ($points | Measure-Object -Property chargingEnergyWh -Sum).Sum
$averageWatts = ($points | Measure-Object -Property totalWatts -Average).Average
$averageSystemWatts = ($points | Measure-Object -Property systemWatts -Average).Average
$averageChargingWatts = ($points | Measure-Object -Property chargingWatts -Average).Average
$peakWatts = ($points | Measure-Object -Property maximumWatts -Maximum).Maximum
$averageChargeRateWatts = ($points | Measure-Object -Property chargingWatts -Average).Average
$peakChargeRateWatts = ($points | Measure-Object -Property chargingWatts -Maximum).Maximum
$latestPoint = $points | Select-Object -Last 1
$startTime = [DateTimeOffset]::Parse($points[0].timestampUtc).ToLocalTime()
$endTime = [DateTimeOffset]::Parse($points[-1].timestampUtc).ToLocalTime()
$gaps = @()
for ($index = 1; $index -lt $points.Count; $index++) {
    $previous = [DateTimeOffset]::Parse($points[$index - 1].timestampUtc)
    $current = [DateTimeOffset]::Parse($points[$index].timestampUtc)
    $gapMinutes = ($current - $previous).TotalMinutes
    if ($gapMinutes -gt 5) {
        $gaps += [pscustomobject] @{
            fromLocal = $previous.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
            toLocal = $current.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
            minutes = [Math]::Round($gapMinutes, 2)
        }
    }
}

$largestGapMinutes = if ($gaps.Count -gt 0) {
    ($gaps | Measure-Object -Property minutes -Maximum).Maximum
}
else {
    0
}

$hourlyGroups = $points | Group-Object {
    ([DateTimeOffset]::Parse($_.timestampUtc)).ToLocalTime().ToString("yyyy-MM-dd HH:00")
}

$hourly = @(
    $hourlyGroups | ForEach-Object {
        [pscustomobject] @{
            period = $_.Name
            systemWh = [Math]::Round((($_.Group | Measure-Object -Property systemEnergyWh -Sum).Sum), 6)
            chargeWh = [Math]::Round((($_.Group | Measure-Object -Property chargingEnergyWh -Sum).Sum), 6)
            energyWh = [Math]::Round((($_.Group | Measure-Object -Property totalEnergyWh -Sum).Sum), 6)
            averageSystemWatts = [Math]::Round((($_.Group | Measure-Object -Property systemWatts -Average).Average), 3)
            averageChargeRateWatts = [Math]::Round((($_.Group | Measure-Object -Property chargingWatts -Average).Average), 3)
            averageWatts = [Math]::Round((($_.Group | Measure-Object -Property totalWatts -Average).Average), 3)
            peakWatts = [Math]::Round((($_.Group | Measure-Object -Property maximumWatts -Maximum).Maximum), 3)
            samples = $_.Count
        }
    }
)

$cutoff = (Get-Date).AddHours(-1 * $RecentHours)
$recentPoints = @(
    $points | Where-Object {
        ([DateTimeOffset]::Parse($_.timestampUtc)).ToLocalTime().DateTime -ge $cutoff
    }
)

if ($recentPoints.Count -eq 0) {
    $recentPoints = $points
}

$reportModel = [pscustomobject] @{
    generatedLocal = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    inputPath = $absoluteInputPath
    pointCount = $points.Count
    inputFiles = @($inputFiles | ForEach-Object { $_.FullName })
    days = $Days
    recentHours = $RecentHours
    startLocal = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
    endLocal = $endTime.ToString("yyyy-MM-dd HH:mm:ss")
    gapCount = $gaps.Count
    largestGapMinutes = [Math]::Round($largestGapMinutes, 2)
    gaps = $gaps
    totalWh = [Math]::Round($totalWh, 6)
    systemWh = [Math]::Round($systemWh, 6)
    chargingWh = [Math]::Round($chargingWh, 6)
    totalKwh = [Math]::Round($totalWh / 1000.0, 6)
    averageWatts = [Math]::Round($averageWatts, 3)
    averageSystemWatts = [Math]::Round($averageSystemWatts, 3)
    averageChargingWatts = [Math]::Round($averageChargingWatts, 3)
    peakWatts = [Math]::Round($peakWatts, 3)
    averageChargeRateWatts = [Math]::Round($averageChargeRateWatts, 3)
    peakChargeRateWatts = [Math]::Round($peakChargeRateWatts, 3)
    latestBatteryStatus = $latestPoint.batteryStatus
    latestBatteryPercent = $latestPoint.batteryChargePercent
    batteryCapacityWh = [Math]::Round($batteryCapacityWh, 3)
    recentPoints = $recentPoints
    hourly = $hourly
}

$reportJson = Convert-ToJsonLiteral $reportModel

$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>BatteryService Power Report</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0b1020;
      --panel: #111936;
      --panel-2: #162044;
      --text: #eef3ff;
      --muted: #9fb0d0;
      --grid: rgba(255,255,255,.12);
      --cpu: #7dd3fc;
      --gpu: #a78bfa;
      --base: #fbbf24;
      --total: #34d399;
      --charge: #fb923c;
      --danger: #fb7185;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Segoe UI, system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
      background: radial-gradient(circle at top left, #1e2b62, var(--bg) 42rem);
      color: var(--text);
    }
    main { max-width: 1200px; margin: 0 auto; padding: 32px 20px 48px; }
    header { display: flex; justify-content: space-between; gap: 16px; align-items: flex-end; margin-bottom: 24px; }
    h1 { margin: 0; font-size: clamp(28px, 4vw, 44px); letter-spacing: -.04em; }
    .subtitle { color: var(--muted); margin-top: 6px; }
    .cards { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 14px; margin-bottom: 18px; }
    .card, .panel {
      background: linear-gradient(180deg, rgba(255,255,255,.055), rgba(255,255,255,.025));
      border: 1px solid rgba(255,255,255,.11);
      border-radius: 18px;
      box-shadow: 0 16px 48px rgba(0,0,0,.25);
    }
    .card { padding: 18px; }
    .label { color: var(--muted); font-size: 13px; text-transform: uppercase; letter-spacing: .08em; }
    .value { font-size: 30px; font-weight: 750; margin-top: 6px; }
    .unit { color: var(--muted); font-size: 15px; margin-left: 3px; }
    .grid { display: grid; grid-template-columns: 1fr; gap: 18px; }
    .panel { padding: 18px; }
    .panel h2 { margin: 0 0 12px; font-size: 20px; }
    canvas { width: 100%; height: 320px; display: block; }
    .legend { display: flex; flex-wrap: wrap; gap: 12px; color: var(--muted); font-size: 13px; margin-top: 8px; }
    .swatch { width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th, td { padding: 10px 8px; border-bottom: 1px solid rgba(255,255,255,.08); text-align: right; }
    th:first-child, td:first-child { text-align: left; }
    th { color: var(--muted); font-weight: 600; }
    .note { color: var(--muted); font-size: 13px; line-height: 1.5; margin-top: 10px; }
    @media (max-width: 800px) {
      header { display: block; }
      .cards { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      canvas { height: 260px; }
    }
  </style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>BatteryService Power Report</h1>
      <div class="subtitle" id="range"></div>
    </div>
    <div class="subtitle" id="generated"></div>
  </header>

  <section class="cards">
    <div class="card"><div class="label">Total Energy</div><div class="value" id="totalEnergy"></div></div>
    <div class="card"><div class="label">System Energy</div><div class="value" id="systemEnergy"></div></div>
    <div class="card"><div class="label">Charging Energy</div><div class="value" id="chargingEnergy"></div></div>
    <div class="card"><div class="label">Avg Total Power</div><div class="value" id="averagePower"></div></div>
    <div class="card"><div class="label">Peak Power</div><div class="value" id="peakPower"></div></div>
    <div class="card"><div class="label">Battery</div><div class="value" id="batteryState"></div></div>
    <div class="card"><div class="label">Recording Gaps</div><div class="value" id="gapCount"></div></div>
  </section>

  <section class="grid">
    <div class="panel">
      <h2>Total Watts: CPU + GPU + Baseline + Charging</h2>
      <canvas id="totalChart" width="1100" height="320"></canvas>
      <div class="legend"><span><i class="swatch" style="background:var(--total)"></i>Total with charging</span><span><i class="swatch" style="background:var(--danger)"></i>System min/max envelope</span></div>
    </div>

    <div class="panel">
      <h2>Component Split: CPU + GPU + Baseline + Charging</h2>
      <canvas id="splitChart" width="1100" height="320"></canvas>
      <div class="legend"><span><i class="swatch" style="background:var(--cpu)"></i>CPU estimated</span><span><i class="swatch" style="background:var(--gpu)"></i>GPU measured</span><span><i class="swatch" style="background:var(--base)"></i>Baseline</span><span><i class="swatch" style="background:var(--charge)"></i>Battery charging</span></div>
    </div>

    <div class="panel">
      <h2>Cumulative Energy</h2>
      <canvas id="energyChart" width="1100" height="320"></canvas>
      <div class="note">Total energy is system energy plus charging energy. If charging watts are unavailable, charging contributes 0 Wh until firmware exposes rate or percent-delta estimation has enough data.</div>
    </div>

    <div class="panel">
      <h2>Battery Charging</h2>
      <canvas id="batteryChart" width="1100" height="320"></canvas>
      <div class="legend"><span><i class="swatch" style="background:var(--charge)"></i>Battery charge rate watts</span><span><i class="swatch" style="background:var(--total)"></i>Battery percent</span></div>
      <div class="note">Charge watts describe energy flowing into the battery. They are shown separately from estimated laptop consumption so charging overhead is visible instead of hidden.</div>
    </div>

    <div class="panel">
      <h2>Hourly Summary</h2>
      <table>
        <thead><tr><th>Hour</th><th>Total Wh</th><th>System Wh</th><th>Charge Wh</th><th>Avg Total W</th><th>Avg System W</th><th>Avg Charge W</th><th>Peak W</th><th>Rows</th></tr></thead>
        <tbody id="hourlyRows"></tbody>
      </table>
    </div>

    <div class="panel">
      <h2>Recording Gaps</h2>
      <table>
        <thead><tr><th>From</th><th>To</th><th>Minutes</th></tr></thead>
        <tbody id="gapRows"></tbody>
      </table>
      <div class="note">Gaps larger than 5 minutes usually mean the scheduled task or logger process was stopped.</div>
    </div>
  </section>
</main>

<script>
const report = $reportJson;
const css = getComputedStyle(document.documentElement);
const colors = {
  total: css.getPropertyValue("--total").trim(),
  danger: css.getPropertyValue("--danger").trim(),
  charge: css.getPropertyValue("--charge").trim(),
  cpu: css.getPropertyValue("--cpu").trim(),
  gpu: css.getPropertyValue("--gpu").trim(),
  base: css.getPropertyValue("--base").trim(),
  grid: css.getPropertyValue("--grid").trim(),
  text: css.getPropertyValue("--text").trim(),
  muted: css.getPropertyValue("--muted").trim()
};

document.getElementById("generated").textContent = "Generated " + report.generatedLocal;
document.getElementById("range").textContent = report.startLocal + " → " + report.endLocal + " · " + (report.days > 0 ? ("last " + report.days + " day(s)") : "all data") + " · recent chart window: " + report.recentHours + "h";
document.getElementById("totalEnergy").innerHTML = report.totalWh.toFixed(3) + '<span class="unit">Wh</span>';
document.getElementById("systemEnergy").innerHTML = report.systemWh.toFixed(3) + '<span class="unit">Wh</span>';
document.getElementById("chargingEnergy").innerHTML = report.chargingWh.toFixed(3) + '<span class="unit">Wh</span>';
document.getElementById("averagePower").innerHTML = report.averageWatts.toFixed(2) + '<span class="unit">W</span>';
document.getElementById("peakPower").innerHTML = report.peakWatts.toFixed(2) + '<span class="unit">W</span>';
document.getElementById("batteryState").innerHTML = (report.latestBatteryPercent || 0).toFixed(0) + '<span class="unit">% ' + (report.latestBatteryStatus || "unknown") + '</span>';
document.getElementById("gapCount").innerHTML = report.gapCount + '<span class="unit"> max ' + report.largestGapMinutes.toFixed(0) + 'm</span>';

function scale(values, height, padding) {
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = Math.max(1, max - min);
  return value => height - padding - ((value - min) / span) * (height - padding * 2);
}

function drawAxes(ctx, width, height, padding, minValue, maxValue) {
  ctx.strokeStyle = colors.grid;
  ctx.fillStyle = colors.muted;
  ctx.lineWidth = 1;
  ctx.font = "12px Segoe UI";
  for (let index = 0; index <= 4; index++) {
    const y = padding + ((height - padding * 2) * index / 4);
    const value = maxValue - ((maxValue - minValue) * index / 4);
    ctx.beginPath();
    ctx.moveTo(padding, y);
    ctx.lineTo(width - padding, y);
    ctx.stroke();
    ctx.fillText(value.toFixed(1), 8, y + 4);
  }
}

function pathLine(ctx, points, getY, color, width, height, padding) {
  if (!points.length) return;
  ctx.strokeStyle = color;
  ctx.lineWidth = 2.5;
  ctx.beginPath();
  points.forEach((point, index) => {
    const x = padding + index * ((width - padding * 2) / Math.max(1, points.length - 1));
    const y = getY(point);
    if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  ctx.stroke();
}

function drawTotalChart() {
  const canvas = document.getElementById("totalChart");
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  const padding = 42;
  const points = report.recentPoints;
  const values = points.flatMap(point => [point.minimumWatts, point.totalWatts, point.maximumWatts + point.chargingWatts]);
  const minValue = Math.max(0, Math.min(...values) - 2);
  const maxValue = Math.max(...values) + 2;
  const y = value => height - padding - ((value - minValue) / Math.max(1, maxValue - minValue)) * (height - padding * 2);
  ctx.clearRect(0, 0, width, height);
  drawAxes(ctx, width, height, padding, minValue, maxValue);
  pathLine(ctx, points, point => y(point.maximumWatts), colors.danger, width, height, padding);
  pathLine(ctx, points, point => y(point.minimumWatts), colors.danger, width, height, padding);
  pathLine(ctx, points, point => y(point.totalWatts), colors.total, width, height, padding);
}

function drawSplitChart() {
  const canvas = document.getElementById("splitChart");
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  const padding = 42;
  const points = report.recentPoints;
  const totals = points.map(point => point.cpuWatts + point.gpuWatts + point.baselineWatts + point.chargingWatts);
  const maxValue = Math.max(...totals) + 2;
  const y = value => height - padding - (value / Math.max(1, maxValue)) * (height - padding * 2);
  const barWidth = Math.max(2, (width - padding * 2) / Math.max(1, points.length) * 0.72);
  ctx.clearRect(0, 0, width, height);
  drawAxes(ctx, width, height, padding, 0, maxValue);
  points.forEach((point, index) => {
    const x = padding + index * ((width - padding * 2) / Math.max(1, points.length - 1)) - barWidth / 2;
    let bottom = height - padding;
    [
      [point.baselineWatts, colors.base],
      [point.gpuWatts, colors.gpu],
      [point.cpuWatts, colors.cpu],
      [point.chargingWatts, colors.charge]
    ].forEach(([value, color]) => {
      const top = y((height - padding - bottom) / (height - padding * 2) * maxValue + value);
      ctx.fillStyle = color;
      ctx.fillRect(x, top, barWidth, bottom - top);
      bottom = top;
    });
  });
}

function drawEnergyChart() {
  const canvas = document.getElementById("energyChart");
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  const padding = 42;
  let sum = 0;
  const points = report.recentPoints.map(point => ({ ...point, cumulativeWh: (sum += point.energyWh) }));
  const maxValue = Math.max(...points.map(point => point.cumulativeWh), 1);
  const y = value => height - padding - (value / maxValue) * (height - padding * 2);
  ctx.clearRect(0, 0, width, height);
  drawAxes(ctx, width, height, padding, 0, maxValue);
  pathLine(ctx, points, point => y(point.cumulativeWh), colors.total, width, height, padding);
}

function drawBatteryChart() {
  const canvas = document.getElementById("batteryChart");
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  const padding = 42;
  const points = report.recentPoints;
  const maxCharge = Math.max(...points.map(point => point.chargingWatts), 1);
  const maxPercent = Math.max(...points.map(point => point.batteryChargePercent), 100);
  const yCharge = value => height - padding - (value / maxCharge) * (height - padding * 2);
  const yPercent = value => height - padding - (value / maxPercent) * (height - padding * 2);
  ctx.clearRect(0, 0, width, height);
  drawAxes(ctx, width, height, padding, 0, maxCharge);
  pathLine(ctx, points, point => yCharge(point.chargingWatts), colors.charge, width, height, padding);
  pathLine(ctx, points, point => yPercent(point.batteryChargePercent), colors.total, width, height, padding);
}

function renderHourlyTable() {
  const rows = report.hourly.slice(-24).reverse().map(row =>
    "<tr>" +
      "<td>" + row.period + "</td>" +
      "<td>" + row.energyWh.toFixed(3) + "</td>" +
      "<td>" + row.systemWh.toFixed(3) + "</td>" +
      "<td>" + row.chargeWh.toFixed(3) + "</td>" +
      "<td>" + row.averageWatts.toFixed(2) + "</td>" +
      "<td>" + row.averageSystemWatts.toFixed(2) + "</td>" +
      "<td>" + row.averageChargeRateWatts.toFixed(2) + "</td>" +
      "<td>" + row.peakWatts.toFixed(2) + "</td>" +
      "<td>" + row.samples + "</td>" +
    "</tr>"
  ).join("");
  document.getElementById("hourlyRows").innerHTML = rows;
}

function renderGapTable() {
  const rows = report.gaps.slice(-25).reverse().map(row =>
    "<tr>" +
      "<td>" + row.fromLocal + "</td>" +
      "<td>" + row.toLocal + "</td>" +
      "<td>" + row.minutes.toFixed(2) + "</td>" +
    "</tr>"
  ).join("");
  document.getElementById("gapRows").innerHTML = rows || '<tr><td colspan="3">No gaps larger than 5 minutes.</td></tr>';
}

drawTotalChart();
drawSplitChart();
drawEnergyChart();
drawBatteryChart();
renderHourlyTable();
renderGapTable();
</script>
</body>
</html>
"@

$outputDirectory = Split-Path -Parent $absoluteOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$html | Set-Content -Encoding UTF8 -LiteralPath $absoluteOutputPath
Write-Host "Wrote HTML report to $absoluteOutputPath"
