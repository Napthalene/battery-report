#!/usr/bin/env python3
import argparse
import json
import socket
from collections import OrderedDict
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import usage_report


def local_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("8.8.8.8", 80))
            return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def first(query, name):
    values = query.get(name)
    return values[0] if values else None


def parse_int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def round_value(value, digits):
    return round(value or 0.0, digits)


def point_from_row(row):
    values = usage_report.row_values(row)
    timestamp = usage_report.parse_timestamp(row)
    timestamp_local = timestamp.strftime("%Y-%m-%d %H:%M") if timestamp else ""
    total_watts = values["total_watts"]
    system_watts = values["system_watts"]
    charging_watts = values["charging_watts"]
    return {
        "timestampUtc": row.get("timestamp_utc", ""),
        "timestampLocal": timestamp_local,
        "durationSeconds": round_value(usage_report.to_float(row.get("duration_seconds")), 3),
        "systemWatts": round_value(system_watts, 3),
        "chargingWatts": round_value(charging_watts, 3),
        "totalWatts": round_value(total_watts, 3),
        "averageWatts": round_value(total_watts, 3),
        "minimumWatts": round_value(usage_report.to_float(row.get("minimum_watts") or row.get("average_watts")), 3),
        "maximumWatts": round_value(usage_report.to_float(row.get("maximum_watts") or row.get("average_watts")), 3),
        "cpuWatts": round_value(values["cpu_watts"], 3),
        "gpuWatts": round_value(values["gpu_watts"], 3),
        "baselineWatts": round_value(values["baseline_watts"], 3),
        "batteryStatus": row.get("battery_status", ""),
        "batteryCharging": row.get("battery_charging", ""),
        "batteryChargeRateWatts": round_value(usage_report.to_float(row.get("average_battery_charge_rate_watts")), 3),
        "batteryDischargeRateWatts": round_value(usage_report.to_float(row.get("average_battery_discharge_rate_watts")), 3),
        "batteryRateWatts": round_value(usage_report.to_float(row.get("average_battery_rate_watts")), 3),
        "batteryVoltageVolts": round_value(usage_report.to_float(row.get("average_battery_voltage_volts")), 3),
        "batteryChargePercent": round_value(usage_report.to_float(row.get("average_battery_charge_percent")), 3),
        "cpuLoadPercent": round_value(usage_report.to_float(row.get("average_cpu_load_percent")), 3),
        "systemEnergyWh": round_value(values["system_wh"], 6),
        "chargingEnergyWh": round_value(values["charging_wh"], 6),
        "totalEnergyWh": round_value(values["total_wh"], 6),
        "energyWh": round_value(values["total_wh"], 6),
        "chargingSource": row.get("charging_source", ""),
        "source": row.get("source", ""),
        "confidence": row.get("confidence", ""),
    }


def avg(values):
    return sum(values) / len(values) if values else 0.0


def build_gaps(points):
    gaps = []
    for previous, current in zip(points, points[1:]):
        previous_ts = datetime.fromisoformat(previous["timestampUtc"].replace("Z", "+00:00"))
        current_ts = datetime.fromisoformat(current["timestampUtc"].replace("Z", "+00:00"))
        gap_minutes = (current_ts - previous_ts).total_seconds() / 60.0
        if gap_minutes > 5:
            gaps.append({
                "fromLocal": previous_ts.astimezone().strftime("%Y-%m-%d %H:%M:%S"),
                "toLocal": current_ts.astimezone().strftime("%Y-%m-%d %H:%M:%S"),
                "minutes": round_value(gap_minutes, 2),
            })
    return gaps


def build_hourly(points):
    groups = OrderedDict()
    for point in points:
        timestamp = datetime.fromisoformat(point["timestampUtc"].replace("Z", "+00:00")).astimezone()
        key = timestamp.strftime("%Y-%m-%d %H:00")
        groups.setdefault(key, []).append(point)
    hourly = []
    for key, group in groups.items():
        hourly.append({
            "period": key,
            "systemWh": round_value(sum(point["systemEnergyWh"] for point in group), 6),
            "chargeWh": round_value(sum(point["chargingEnergyWh"] for point in group), 6),
            "energyWh": round_value(sum(point["totalEnergyWh"] for point in group), 6),
            "averageSystemWatts": round_value(avg([point["systemWatts"] for point in group]), 3),
            "averageChargeRateWatts": round_value(avg([point["chargingWatts"] for point in group]), 3),
            "averageWatts": round_value(avg([point["totalWatts"] for point in group]), 3),
            "peakWatts": round_value(max((point["maximumWatts"] for point in group), default=0.0), 3),
            "samples": len(group),
        })
    return hourly


def build_report(query, platform, default_days, default_recent_hours):
    days = parse_int(first(query, "days"), default_days)
    recent_hours = parse_int(first(query, "recentHours") or first(query, "recent-hours"), default_recent_hours)
    to_dt = datetime.now()
    from_dt = to_dt - timedelta(days=days) if days > 0 else None
    files = usage_report.discover_files(platform, first(query, "input"))
    raw_rows = usage_report.read_rows(files)
    points = []
    for row in raw_rows:
        timestamp = usage_report.parse_timestamp(row)
        if timestamp is None:
            continue
        if from_dt and timestamp < from_dt:
            continue
        points.append(point_from_row(row))

    if not points:
        return {
            "generatedLocal": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "inputPath": str(files[0]) if files else "",
            "pointCount": 0,
            "inputFiles": [str(path) for path in files],
            "days": days,
            "recentHours": recent_hours,
            "startLocal": "",
            "endLocal": "",
            "gapCount": 0,
            "largestGapMinutes": 0,
            "gaps": [],
            "totalWh": 0,
            "systemWh": 0,
            "chargingWh": 0,
            "totalKwh": 0,
            "averageWatts": 0,
            "averageSystemWatts": 0,
            "averageChargingWatts": 0,
            "peakWatts": 0,
            "averageChargeRateWatts": 0,
            "peakChargeRateWatts": 0,
            "latestBatteryStatus": "unknown",
            "latestBatteryPercent": 0,
            "batteryCapacityWh": 0,
            "recentPoints": [],
            "hourly": [],
        }

    gaps = build_gaps(points)
    largest_gap = max((gap["minutes"] for gap in gaps), default=0.0)
    recent_cutoff = datetime.now() - timedelta(hours=recent_hours)
    recent_points = [
        point for point in points
        if datetime.fromisoformat(point["timestampUtc"].replace("Z", "+00:00")).astimezone().replace(tzinfo=None) >= recent_cutoff
    ] or points
    latest = points[-1]
    start = datetime.fromisoformat(points[0]["timestampUtc"].replace("Z", "+00:00")).astimezone()
    end = datetime.fromisoformat(points[-1]["timestampUtc"].replace("Z", "+00:00")).astimezone()
    total_wh = sum(point["totalEnergyWh"] for point in points)
    system_wh = sum(point["systemEnergyWh"] for point in points)
    charging_wh = sum(point["chargingEnergyWh"] for point in points)

    return {
        "generatedLocal": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "inputPath": str(files[0]) if files else "",
        "pointCount": len(points),
        "inputFiles": [str(path) for path in files],
        "days": days,
        "recentHours": recent_hours,
        "startLocal": start.strftime("%Y-%m-%d %H:%M:%S"),
        "endLocal": end.strftime("%Y-%m-%d %H:%M:%S"),
        "gapCount": len(gaps),
        "largestGapMinutes": round_value(largest_gap, 2),
        "gaps": gaps,
        "totalWh": round_value(total_wh, 6),
        "systemWh": round_value(system_wh, 6),
        "chargingWh": round_value(charging_wh, 6),
        "totalKwh": round_value(total_wh / 1000.0, 6),
        "averageWatts": round_value(avg([point["totalWatts"] for point in points]), 3),
        "averageSystemWatts": round_value(avg([point["systemWatts"] for point in points]), 3),
        "averageChargingWatts": round_value(avg([point["chargingWatts"] for point in points]), 3),
        "peakWatts": round_value(max((point["maximumWatts"] for point in points), default=0.0), 3),
        "averageChargeRateWatts": round_value(avg([point["chargingWatts"] for point in points]), 3),
        "peakChargeRateWatts": round_value(max((point["chargingWatts"] for point in points), default=0.0), 3),
        "latestBatteryStatus": latest["batteryStatus"] or "unknown",
        "latestBatteryPercent": latest["batteryChargePercent"],
        "batteryCapacityWh": 0,
        "recentPoints": recent_points,
        "hourly": build_hourly(points),
    }


def render_html(report):
    report_json = json.dumps(report)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="60">
  <title>BatteryService Power Report</title>
  <style>
    :root {{
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
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      font-family: Segoe UI, system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
      background: radial-gradient(circle at top left, #1e2b62, var(--bg) 42rem);
      color: var(--text);
    }}
    main {{ max-width: 1200px; margin: 0 auto; padding: 32px 20px 48px; }}
    header {{ display: flex; justify-content: space-between; gap: 16px; align-items: flex-end; margin-bottom: 24px; }}
    h1 {{ margin: 0; font-size: clamp(28px, 4vw, 44px); letter-spacing: -.04em; }}
    .subtitle {{ color: var(--muted); margin-top: 6px; }}
    .controls {{ display: flex; gap: 8px; align-items: center; justify-content: flex-end; flex-wrap: wrap; margin-top: 8px; }}
    .controls input, .controls button {{ background: var(--panel-2); color: var(--text); border: 1px solid rgba(255,255,255,.16); border-radius: 10px; padding: 8px 10px; }}
    .cards {{ display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 14px; margin-bottom: 18px; }}
    .card, .panel {{
      background: linear-gradient(180deg, rgba(255,255,255,.055), rgba(255,255,255,.025));
      border: 1px solid rgba(255,255,255,.11);
      border-radius: 18px;
      box-shadow: 0 16px 48px rgba(0,0,0,.25);
    }}
    .card {{ padding: 18px; }}
    .label {{ color: var(--muted); font-size: 13px; text-transform: uppercase; letter-spacing: .08em; }}
    .value {{ font-size: 30px; font-weight: 750; margin-top: 6px; }}
    .unit {{ color: var(--muted); font-size: 15px; margin-left: 3px; }}
    .grid {{ display: grid; grid-template-columns: 1fr; gap: 18px; }}
    .panel {{ padding: 18px; overflow-x: auto; }}
    .panel h2 {{ margin: 0 0 12px; font-size: 20px; }}
    canvas {{ width: 100%; height: 320px; display: block; }}
    .legend {{ display: flex; flex-wrap: wrap; gap: 12px; color: var(--muted); font-size: 13px; margin-top: 8px; }}
    .swatch {{ width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th, td {{ padding: 10px 8px; border-bottom: 1px solid rgba(255,255,255,.08); text-align: right; }}
    th:first-child, td:first-child {{ text-align: left; }}
    th {{ color: var(--muted); font-weight: 600; }}
    .note {{ color: var(--muted); font-size: 13px; line-height: 1.5; margin-top: 10px; }}
    @media (max-width: 800px) {{
      header {{ display: block; }}
      .cards {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
      canvas {{ height: 260px; }}
    }}
  </style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>BatteryService Power Report</h1>
      <div class="subtitle" id="range"></div>
    </div>
    <div>
      <div class="subtitle" id="generated"></div>
      <form class="controls" method="get">
        <label>Days <input name="days" type="number" min="0" value="{report['days']}" style="width: 76px"></label>
        <label>Recent hours <input name="recentHours" type="number" min="1" value="{report['recentHours']}" style="width: 76px"></label>
        <button type="submit">Refresh</button>
      </form>
    </div>
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
const report = {report_json};
const css = getComputedStyle(document.documentElement);
const colors = {{
  total: css.getPropertyValue("--total").trim(),
  danger: css.getPropertyValue("--danger").trim(),
  charge: css.getPropertyValue("--charge").trim(),
  cpu: css.getPropertyValue("--cpu").trim(),
  gpu: css.getPropertyValue("--gpu").trim(),
  base: css.getPropertyValue("--base").trim(),
  grid: css.getPropertyValue("--grid").trim(),
  text: css.getPropertyValue("--text").trim(),
  muted: css.getPropertyValue("--muted").trim()
}};

document.getElementById("generated").textContent = "Generated " + report.generatedLocal;
document.getElementById("range").textContent = (report.startLocal || "no data") + " → " + (report.endLocal || "no data") + " · " + (report.days > 0 ? ("last " + report.days + " day(s)") : "all data") + " · recent chart window: " + report.recentHours + "h";
document.getElementById("totalEnergy").innerHTML = report.totalWh.toFixed(3) + '<span class="unit">Wh</span>';
document.getElementById("systemEnergy").innerHTML = report.systemWh.toFixed(3) + '<span class="unit">Wh</span>';
document.getElementById("chargingEnergy").innerHTML = report.chargingWh.toFixed(3) + '<span class="unit">Wh</span>';
document.getElementById("averagePower").innerHTML = report.averageWatts.toFixed(2) + '<span class="unit">W</span>';
document.getElementById("peakPower").innerHTML = report.peakWatts.toFixed(2) + '<span class="unit">W</span>';
document.getElementById("batteryState").innerHTML = (report.latestBatteryPercent || 0).toFixed(0) + '<span class="unit">% ' + (report.latestBatteryStatus || "unknown") + '</span>';
document.getElementById("gapCount").innerHTML = report.gapCount + '<span class="unit"> max ' + report.largestGapMinutes.toFixed(0) + 'm</span>';

function drawAxes(ctx, width, height, padding, minValue, maxValue) {{
  ctx.strokeStyle = colors.grid;
  ctx.fillStyle = colors.muted;
  ctx.lineWidth = 1;
  ctx.font = "12px Segoe UI";
  for (let index = 0; index <= 4; index++) {{
    const y = padding + ((height - padding * 2) * index / 4);
    const value = maxValue - ((maxValue - minValue) * index / 4);
    ctx.beginPath();
    ctx.moveTo(padding, y);
    ctx.lineTo(width - padding, y);
    ctx.stroke();
    ctx.fillText(value.toFixed(1), 8, y + 4);
  }}
}}

function pathLine(ctx, points, getY, color, width, height, padding) {{
  if (!points.length) return;
  ctx.strokeStyle = color;
  ctx.lineWidth = 2.5;
  ctx.beginPath();
  points.forEach((point, index) => {{
    const x = padding + index * ((width - padding * 2) / Math.max(1, points.length - 1));
    const y = getY(point);
    if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  }});
  ctx.stroke();
}}

function drawTotalChart() {{
  const canvas = document.getElementById("totalChart");
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  const padding = 42;
  const points = report.recentPoints;
  if (!points.length) return;
  const values = points.flatMap(point => [point.minimumWatts, point.totalWatts, point.maximumWatts + point.chargingWatts]);
  const minValue = Math.max(0, Math.min(...values) - 2);
  const maxValue = Math.max(...values) + 2;
  const y = value => height - padding - ((value - minValue) / Math.max(1, maxValue - minValue)) * (height - padding * 2);
  ctx.clearRect(0, 0, width, height);
  drawAxes(ctx, width, height, padding, minValue, maxValue);
  pathLine(ctx, points, point => y(point.maximumWatts), colors.danger, width, height, padding);
  pathLine(ctx, points, point => y(point.minimumWatts), colors.danger, width, height, padding);
  pathLine(ctx, points, point => y(point.totalWatts), colors.total, width, height, padding);
}}

function drawSplitChart() {{
  const canvas = document.getElementById("splitChart");
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  const padding = 42;
  const points = report.recentPoints;
  if (!points.length) return;
  const totals = points.map(point => point.cpuWatts + point.gpuWatts + point.baselineWatts + point.chargingWatts);
  const maxValue = Math.max(...totals) + 2;
  const y = value => height - padding - (value / Math.max(1, maxValue)) * (height - padding * 2);
  const barWidth = Math.max(2, (width - padding * 2) / Math.max(1, points.length) * 0.72);
  ctx.clearRect(0, 0, width, height);
  drawAxes(ctx, width, height, padding, 0, maxValue);
  points.forEach((point, index) => {{
    const x = padding + index * ((width - padding * 2) / Math.max(1, points.length - 1)) - barWidth / 2;
    let bottom = height - padding;
    [
      [point.baselineWatts, colors.base],
      [point.gpuWatts, colors.gpu],
      [point.cpuWatts, colors.cpu],
      [point.chargingWatts, colors.charge]
    ].forEach(([value, color]) => {{
      const top = y((height - padding - bottom) / (height - padding * 2) * maxValue + value);
      ctx.fillStyle = color;
      ctx.fillRect(x, top, barWidth, bottom - top);
      bottom = top;
    }});
  }});
}}

function drawEnergyChart() {{
  const canvas = document.getElementById("energyChart");
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  const padding = 42;
  let sum = 0;
  const points = report.recentPoints.map(point => ({{ ...point, cumulativeWh: (sum += point.energyWh) }}));
  if (!points.length) return;
  const maxValue = Math.max(...points.map(point => point.cumulativeWh), 1);
  const y = value => height - padding - (value / maxValue) * (height - padding * 2);
  ctx.clearRect(0, 0, width, height);
  drawAxes(ctx, width, height, padding, 0, maxValue);
  pathLine(ctx, points, point => y(point.cumulativeWh), colors.total, width, height, padding);
}}

function drawBatteryChart() {{
  const canvas = document.getElementById("batteryChart");
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  const padding = 42;
  const points = report.recentPoints;
  if (!points.length) return;
  const maxCharge = Math.max(...points.map(point => point.chargingWatts), 1);
  const maxPercent = Math.max(...points.map(point => point.batteryChargePercent), 100);
  const yCharge = value => height - padding - (value / maxCharge) * (height - padding * 2);
  const yPercent = value => height - padding - (value / maxPercent) * (height - padding * 2);
  ctx.clearRect(0, 0, width, height);
  drawAxes(ctx, width, height, padding, 0, maxCharge);
  pathLine(ctx, points, point => yCharge(point.chargingWatts), colors.charge, width, height, padding);
  pathLine(ctx, points, point => yPercent(point.batteryChargePercent), colors.total, width, height, padding);
}}

function renderHourlyTable() {{
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
  document.getElementById("hourlyRows").innerHTML = rows || '<tr><td colspan="9">No data rows found.</td></tr>';
}}

function renderGapTable() {{
  const rows = report.gaps.slice(-25).reverse().map(row =>
    "<tr>" +
      "<td>" + row.fromLocal + "</td>" +
      "<td>" + row.toLocal + "</td>" +
      "<td>" + row.minutes.toFixed(2) + "</td>" +
    "</tr>"
  ).join("");
  document.getElementById("gapRows").innerHTML = rows || '<tr><td colspan="3">No gaps larger than 5 minutes.</td></tr>';
}}

drawTotalChart();
drawSplitChart();
drawEnergyChart();
drawBatteryChart();
renderHourlyTable();
renderGapTable();
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    platform = "linux"
    days = 7
    recent_hours = 24

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/health":
            self.write_response("ok\n", "text/plain")
            return
        report = build_report(query, self.platform, self.days, self.recent_hours)
        if parsed.path == "/api/usage":
            self.write_response(json.dumps(report, indent=2), "application/json")
            return
        if parsed.path not in {"/", "/index.html"}:
            self.send_error(404)
            return
        self.write_response(render_html(report), "text/html; charset=utf-8")

    def write_response(self, content, content_type):
        payload = content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}")


def main():
    parser = argparse.ArgumentParser(description="Serve BatteryService report over HTTP")
    parser.add_argument("--host", default="0.0.0.0", help="Address to bind. Use 0.0.0.0 for LAN access.")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--recent-hours", type=int, default=24)
    parser.add_argument("--group-by", choices=["raw", "hour", "day", "week", "month", "year"], default="day", help=argparse.SUPPRESS)
    parser.add_argument("--platform", choices=["windows", "linux"], default="linux")
    args = parser.parse_args()

    Handler.platform = args.platform
    Handler.days = args.days
    Handler.recent_hours = args.recent_hours
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    display_host = local_ip() if args.host in {"0.0.0.0", "::"} else args.host
    print(f"Serving BatteryService report at http://{display_host}:{args.port}/")
    print("Press Ctrl+C to stop.")
    server.serve_forever()


if __name__ == "__main__":
    main()
