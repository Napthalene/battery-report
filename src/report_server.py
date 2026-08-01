#!/usr/bin/env python3
import argparse
import html
import json
import socket
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import usage_report


def project_root():
    return Path(__file__).resolve().parents[1]


def local_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("8.8.8.8", 80))
            return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def parse_int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def rows_for_request(query, platform, default_days, default_group_by):
    days = parse_int(first(query, "days"), default_days)
    group_by = first(query, "groupBy") or first(query, "group-by") or default_group_by
    if group_by not in {"raw", "hour", "day", "week", "month", "year"}:
        group_by = default_group_by

    to_dt = datetime.now()
    from_dt = to_dt - timedelta(days=days) if days > 0 else None
    files = usage_report.discover_files(platform, first(query, "input"))
    raw_rows = usage_report.read_rows(files)
    aggregated, gaps = usage_report.aggregate(raw_rows, group_by, from_dt, to_dt)
    return aggregated, gaps, {
        "days": days,
        "group_by": group_by,
        "platform": platform,
        "from": from_dt.isoformat(timespec="seconds") if from_dt else "",
        "to": to_dt.isoformat(timespec="seconds"),
        "files": [str(path) for path in files],
    }


def first(query, name):
    values = query.get(name)
    return values[0] if values else None


def total(rows, key):
    return sum(row.get(key, 0.0) for row in rows)


def avg(rows, key):
    values = [row.get(key, 0.0) for row in rows]
    return sum(values) / len(values) if values else 0.0


def render_html(rows, gaps, meta):
    total_wh = total(rows, "total_wh")
    system_wh = total(rows, "system_wh")
    charging_wh = total(rows, "charging_wh")
    avg_total_w = avg(rows, "avg_total_w")
    peak_w = max((row.get("peak_w", 0.0) for row in rows), default=0.0)
    max_wh = max((row.get("total_wh", 0.0) for row in rows), default=1.0) or 1.0
    rows_json = json.dumps(rows)

    table_rows = []
    for row in rows:
        system_width = 100 * row.get("system_wh", 0.0) / max_wh
        charge_width = 100 * row.get("charging_wh", 0.0) / max_wh
        table_rows.append(
            "<tr>"
            f"<td>{html.escape(str(row['period']))}</td>"
            f"<td>{row['total_wh']:.3f}</td>"
            f"<td>{row['system_wh']:.3f}<div class='bar system' style='width:{system_width:.1f}%'></div></td>"
            f"<td>{row['charging_wh']:.3f}<div class='bar charge' style='width:{charge_width:.1f}%'></div></td>"
            f"<td>{row['avg_total_w']:.2f}</td>"
            f"<td>{row['avg_cpu_w']:.2f}</td>"
            f"<td>{row['avg_gpu_w']:.2f}</td>"
            f"<td>{row['peak_w']:.2f}</td>"
            f"<td>{row['rows']}</td>"
            "</tr>"
        )

    gap_note = ""
    if gaps:
        gap_note = f"<p class='warn'>Detected {len(gaps)} logging gap(s) longer than 5 minutes.</p>"

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>BatteryService Report</title>
<style>
:root{{color-scheme:dark;--bg:#0b1020;--panel:#121a33;--line:#273154;--text:#edf3ff;--muted:#9fb0d0;--green:#34d399;--orange:#fb923c;--blue:#60a5fa;}}
body{{font-family:Segoe UI,Roboto,Arial,sans-serif;background:var(--bg);color:var(--text);margin:0;padding:24px;}}
header{{display:flex;gap:16px;align-items:flex-end;justify-content:space-between;flex-wrap:wrap;margin-bottom:20px;}}
h1{{margin:0;font-size:28px}} a{{color:var(--blue)}} .muted{{color:var(--muted)}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:18px 0}}
.card{{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px}}
.label{{color:var(--muted);font-size:13px}} .value{{font-size:26px;font-weight:700;margin-top:6px}}
canvas{{background:var(--panel);border:1px solid var(--line);border-radius:14px;width:100%;height:320px;margin:12px 0 20px}}
table{{border-collapse:collapse;width:100%;background:var(--panel);border:1px solid var(--line);border-radius:14px;overflow:hidden}}
th,td{{border-bottom:1px solid var(--line);padding:9px;text-align:right;white-space:nowrap}} th:first-child,td:first-child{{text-align:left}}
.bar{{height:5px;border-radius:99px;margin-top:4px}} .system{{background:var(--green)}} .charge{{background:var(--orange)}} .warn{{color:#fbbf24}}
form{{display:flex;gap:8px;align-items:center;flex-wrap:wrap}} input,select,button{{background:#0f1730;color:var(--text);border:1px solid var(--line);border-radius:9px;padding:8px}}
</style>
</head>
<body>
<header>
  <div>
    <h1>BatteryService Report</h1>
    <div class="muted">Platform {html.escape(meta['platform'])}, last {meta['days']} day(s), grouped by {html.escape(meta['group_by'])}. Auto-refreshes every 60 seconds.</div>
  </div>
  <form method="get">
    <label>Days <input name="days" type="number" min="0" value="{meta['days']}" style="width:80px"></label>
    <label>Group <select name="groupBy">
      {options(meta['group_by'])}
    </select></label>
    <button type="submit">Refresh</button>
  </form>
</header>
{gap_note}
<section class="cards">
  <div class="card"><div class="label">Total Energy</div><div class="value">{total_wh:.3f} Wh</div></div>
  <div class="card"><div class="label">System Energy</div><div class="value">{system_wh:.3f} Wh</div></div>
  <div class="card"><div class="label">Charging Energy</div><div class="value">{charging_wh:.3f} Wh</div></div>
  <div class="card"><div class="label">Average Power</div><div class="value">{avg_total_w:.2f} W</div></div>
  <div class="card"><div class="label">Peak Power</div><div class="value">{peak_w:.2f} W</div></div>
</section>
<canvas id="chart" width="1200" height="320"></canvas>
<table>
<thead><tr><th>Period</th><th>Total Wh</th><th>System Wh</th><th>Charge Wh</th><th>Avg W</th><th>CPU W</th><th>GPU W</th><th>Peak W</th><th>Rows</th></tr></thead>
<tbody>{''.join(table_rows)}</tbody>
</table>
<script>
const rows = {rows_json};
const canvas = document.getElementById('chart');
const ctx = canvas.getContext('2d');
const pad = 42;
const width = canvas.width - pad * 2;
const height = canvas.height - pad * 2;
const maxValue = Math.max(1, ...rows.map(r => r.total_wh));
ctx.clearRect(0, 0, canvas.width, canvas.height);
ctx.strokeStyle = '#273154';
ctx.fillStyle = '#9fb0d0';
ctx.font = '13px Segoe UI, Arial';
for (let i = 0; i <= 4; i++) {{
  const y = pad + height - height * i / 4;
  ctx.beginPath(); ctx.moveTo(pad, y); ctx.lineTo(pad + width, y); ctx.stroke();
  ctx.fillText((maxValue * i / 4).toFixed(1) + ' Wh', 6, y + 4);
}}
const barWidth = rows.length ? Math.max(3, width / rows.length * 0.72) : 0;
rows.forEach((row, index) => {{
  const x = pad + index * width / Math.max(1, rows.length) + 2;
  const systemHeight = height * row.system_wh / maxValue;
  const chargeHeight = height * row.charging_wh / maxValue;
  const baseY = pad + height;
  ctx.fillStyle = '#34d399';
  ctx.fillRect(x, baseY - systemHeight, barWidth, systemHeight);
  ctx.fillStyle = '#fb923c';
  ctx.fillRect(x, baseY - systemHeight - chargeHeight, barWidth, chargeHeight);
}});
</script>
</body>
</html>"""


def options(selected):
    values = ["hour", "day", "week", "month", "year", "raw"]
    return "".join(
        f"<option value='{value}'{' selected' if value == selected else ''}>{value}</option>"
        for value in values
    )


class Handler(BaseHTTPRequestHandler):
    platform = "linux"
    days = 7
    group_by = "day"

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/health":
            self.write_response("ok\n", "text/plain")
            return
        if parsed.path == "/api/usage":
            rows, gaps, meta = rows_for_request(query, self.platform, self.days, self.group_by)
            self.write_response(json.dumps({"meta": meta, "gaps": gaps, "rows": rows}, indent=2), "application/json")
            return
        if parsed.path not in {"/", "/index.html"}:
            self.send_error(404)
            return
        rows, gaps, meta = rows_for_request(query, self.platform, self.days, self.group_by)
        self.write_response(render_html(rows, gaps, meta), "text/html; charset=utf-8")

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
    parser.add_argument("--group-by", choices=["raw", "hour", "day", "week", "month", "year"], default="day")
    parser.add_argument("--platform", choices=["windows", "linux"], default="linux")
    args = parser.parse_args()

    Handler.platform = args.platform
    Handler.days = args.days
    Handler.group_by = args.group_by
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    display_host = local_ip() if args.host in {"0.0.0.0", "::"} else args.host
    print(f"Serving BatteryService report at http://{display_host}:{args.port}/")
    print("Press Ctrl+C to stop.")
    server.serve_forever()


if __name__ == "__main__":
    main()
