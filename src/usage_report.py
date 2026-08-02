#!/usr/bin/env python3
import argparse
import csv
import json
import math
import sys
from collections import OrderedDict
from datetime import datetime, time, timezone
from pathlib import Path


def project_root():
    return Path(__file__).resolve().parents[1]


def parse_datetime(value, end_of_day=False):
    if not value:
        return None
    text = value.strip()
    if len(text) == 10:
        date_value = datetime.strptime(text, "%Y-%m-%d").date()
        return datetime.combine(date_value, time.max if end_of_day else time.min)
    normalized = text.replace("Z", "+00:00")
    return datetime.fromisoformat(normalized).replace(tzinfo=None)


def to_float(value):
    if value is None:
        return 0.0
    text = str(value).strip()
    if not text:
        return 0.0
    try:
        return float(text.replace(",", "."))
    except ValueError:
        return 0.0


def parse_timestamp(row):
    text = row.get("timestamp_utc", "")
    if not text:
        return None
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone().replace(tzinfo=None)


def discover_files(platform, explicit_input):
    root = project_root()
    if explicit_input:
        return [Path(explicit_input).resolve()]
    if platform == "linux":
        base = root / "logs" / "power-minute-linux.csv"
    else:
        base = root / "logs" / "power-minute.csv"
    files = []
    if base.parent.exists():
        files = sorted(
            path for path in base.parent.iterdir()
            if path.is_file() and (path.name == base.name or path.name.startswith(base.name + ".legacy-"))
        )
    return files


def config_path(platform):
    name = "power-estimator.linux.json" if platform == "linux" else "power-estimator.windows.json"
    return project_root() / "config" / name


def read_cost_config(platform):
    path = config_path(platform)
    if not path.exists():
        return 0.0, "\u20ac"
    try:
        config = json.loads(path.read_text(encoding="utf-8-sig"))
        currency = config.get("electricityCurrency", "\u20ac")
        if currency == "â‚¬":
            currency = "\u20ac"
        return to_float(config.get("electricityPricePerKwh")), currency
    except (OSError, json.JSONDecodeError):
        return 0.0, "\u20ac"


def read_rows(files):
    rows = OrderedDict()
    for path in files:
        if not path.exists():
            continue
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            for row in csv.DictReader(handle):
                timestamp = row.get("timestamp_utc")
                if timestamp:
                    rows[timestamp] = row
    return sorted(rows.values(), key=lambda row: row.get("timestamp_utc", ""))


def period_key(timestamp, group_by):
    if group_by == "raw":
        return timestamp.strftime("%Y-%m-%d %H:%M:%S")
    if group_by == "hour":
        return timestamp.strftime("%Y-%m-%d %H:00")
    if group_by == "day":
        return timestamp.strftime("%Y-%m-%d")
    if group_by == "week":
        year, week, _weekday = timestamp.isocalendar()
        return f"{year}-W{week:02d}"
    if group_by == "month":
        return timestamp.strftime("%Y-%m")
    if group_by == "year":
        return timestamp.strftime("%Y")
    raise ValueError(f"Unsupported group-by value: {group_by}")


def row_values(row):
    system_wh = to_float(row.get("system_energy_wh"))
    charging_wh = to_float(row.get("charging_energy_wh"))
    total_wh = to_float(row.get("total_energy_wh") or row.get("energy_wh"))
    if system_wh == 0.0 and total_wh > 0.0:
        system_wh = total_wh - charging_wh
    if total_wh == 0.0:
        total_wh = system_wh + charging_wh
    system_watts = to_float(row.get("average_system_watts") or row.get("average_watts"))
    charging_watts = to_float(row.get("average_charging_watts"))
    total_watts = to_float(row.get("average_total_with_charging_watts") or row.get("average_watts"))
    if total_watts == 0.0:
        total_watts = system_watts + charging_watts
    return {
        "system_wh": system_wh,
        "charging_wh": charging_wh,
        "total_wh": total_wh,
        "system_watts": system_watts,
        "charging_watts": charging_watts,
        "total_watts": total_watts,
        "peak_watts": to_float(row.get("maximum_watts") or row.get("average_watts")),
        "cpu_watts": to_float(row.get("average_cpu_estimated_watts")),
        "gpu_watts": to_float(row.get("average_gpu_watts")),
        "baseline_watts": to_float(row.get("platform_baseline_watts")),
        "battery_percent": to_float(row.get("average_battery_charge_percent")),
    }


def aggregate(rows, group_by, from_dt, to_dt, price_per_kwh=0.0):
    groups = OrderedDict()
    gaps = []
    previous_timestamp = None
    for row in rows:
        timestamp = parse_timestamp(row)
        if timestamp is None:
            continue
        if from_dt and timestamp < from_dt:
            continue
        if to_dt and timestamp > to_dt:
            continue
        if previous_timestamp:
            gap_minutes = (timestamp - previous_timestamp).total_seconds() / 60.0
            if gap_minutes > 5:
                gaps.append(gap_minutes)
        previous_timestamp = timestamp
        key = period_key(timestamp, group_by)
        values = row_values(row)
        group = groups.setdefault(key, {
            "period": key,
            "rows": 0,
            "total_wh": 0.0,
            "system_wh": 0.0,
            "charging_wh": 0.0,
            "total_watts_values": [],
            "system_watts_values": [],
            "charging_watts_values": [],
            "cpu_watts_values": [],
            "gpu_watts_values": [],
            "baseline_watts_values": [],
            "battery_values": [],
            "peak_watts": 0.0,
        })
        group["rows"] += 1
        group["total_wh"] += values["total_wh"]
        group["system_wh"] += values["system_wh"]
        group["charging_wh"] += values["charging_wh"]
        group["total_watts_values"].append(values["total_watts"])
        group["system_watts_values"].append(values["system_watts"])
        group["charging_watts_values"].append(values["charging_watts"])
        group["cpu_watts_values"].append(values["cpu_watts"])
        group["gpu_watts_values"].append(values["gpu_watts"])
        group["baseline_watts_values"].append(values["baseline_watts"])
        if values["battery_percent"] > 0:
            group["battery_values"].append(values["battery_percent"])
        group["peak_watts"] = max(group["peak_watts"], values["peak_watts"])
    result = []
    for group in groups.values():
        result.append({
            "period": group["period"],
            "rows": group["rows"],
            "total_wh": round(group["total_wh"], 6),
            "total_kwh": round(group["total_wh"] / 1000.0, 6),
            "cost": round((group["total_wh"] / 1000.0) * price_per_kwh, 6),
            "system_wh": round(group["system_wh"], 6),
            "charging_wh": round(group["charging_wh"], 6),
            "avg_total_w": round(avg(group["total_watts_values"]), 3),
            "avg_system_w": round(avg(group["system_watts_values"]), 3),
            "avg_charging_w": round(avg(group["charging_watts_values"]), 3),
            "avg_cpu_w": round(avg(group["cpu_watts_values"]), 3),
            "avg_gpu_w": round(avg(group["gpu_watts_values"]), 3),
            "avg_baseline_w": round(avg(group["baseline_watts_values"]), 3),
            "peak_w": round(group["peak_watts"], 3),
            "battery_percent": round(avg(group["battery_values"]), 2) if group["battery_values"] else 0.0,
        })
    return result, gaps


def avg(values):
    values = [value for value in values if value is not None and math.isfinite(value)]
    return sum(values) / len(values) if values else 0.0


def print_table(rows, currency="€"):
    columns = [
        ("period", "Period"),
        ("total_wh", "Total Wh"),
        ("cost", f"Cost {currency}"),
        ("system_wh", "System Wh"),
        ("charging_wh", "Charge Wh"),
        ("avg_total_w", "Avg W"),
        ("avg_cpu_w", "CPU W"),
        ("avg_gpu_w", "GPU W"),
        ("peak_w", "Peak W"),
        ("rows", "Rows"),
    ]
    table = [[str(row[key]) for key, _label in columns] for row in rows]
    widths = [len(label) for _key, label in columns]
    for line in table:
        for index, cell in enumerate(line):
            widths[index] = max(widths[index], len(cell))
    header = "  ".join(label.ljust(widths[index]) for index, (_key, label) in enumerate(columns))
    print(header)
    print("  ".join("-" * width for width in widths))
    for line in table:
        print("  ".join(cell.rjust(widths[index]) if index > 0 else cell.ljust(widths[index]) for index, cell in enumerate(line)))


def write_csv(rows, output_path):
    fieldnames = list(rows[0].keys()) if rows else [
        "period", "rows", "total_wh", "total_kwh", "system_wh", "charging_wh"
    ]
    with open(output_path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_json(rows, output_path=None):
    payload = json.dumps(rows, indent=2)
    if output_path:
        Path(output_path).write_text(payload, encoding="utf-8")
    else:
        print(payload)


def write_html(rows, output_path):
    labels = [row["period"] for row in rows]
    total = [row["total_wh"] for row in rows]
    system = [row["system_wh"] for row in rows]
    charging = [row["charging_wh"] for row in rows]
    html = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>BatteryService Usage</title>
<style>
body{{font-family:Segoe UI,Arial,sans-serif;background:#0b1020;color:#eef3ff;margin:24px}}
table{{border-collapse:collapse;width:100%;margin-top:24px}}td,th{{border-bottom:1px solid #263155;padding:8px;text-align:right}}td:first-child,th:first-child{{text-align:left}}
.bar{{height:18px;background:#34d399;border-radius:4px}}.charge{{background:#fb923c}}
</style></head><body>
<h1>BatteryService Usage</h1>
<table><thead><tr><th>Period</th><th>Total Wh</th><th>Cost</th><th>System Wh</th><th>Charge Wh</th><th>Avg W</th><th>Rows</th></tr></thead><tbody>
"""
    max_wh = max(total) if total else 1
    for row in rows:
        system_width = 100 * row["system_wh"] / max_wh if max_wh else 0
        charge_width = 100 * row["charging_wh"] / max_wh if max_wh else 0
        html += (
            f"<tr><td>{row['period']}</td><td>{row['total_wh']:.3f}</td>"
            f"<td>{row['cost']:.4f}</td>"
            f"<td>{row['system_wh']:.3f}<div class='bar' style='width:{system_width:.1f}%'></div></td>"
            f"<td>{row['charging_wh']:.3f}<div class='bar charge' style='width:{charge_width:.1f}%'></div></td>"
            f"<td>{row['avg_total_w']:.2f}</td><td>{row['rows']}</td></tr>"
        )
    html += "</tbody></table></body></html>"
    Path(output_path).write_text(html, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="BatteryService usage reporter")
    parser.add_argument("usage", nargs="?", default="usage")
    parser.add_argument("--from", dest="from_date")
    parser.add_argument("--to", dest="to_date")
    parser.add_argument("--group-by", choices=["raw", "hour", "day", "week", "month", "year"], default="day")
    parser.add_argument("-o", "--output", choices=["table", "json", "csv", "html"], default="table")
    parser.add_argument("--platform", choices=["windows", "linux"], default="windows")
    parser.add_argument("--input")
    parser.add_argument("--output-file")
    args = parser.parse_args()
    files = discover_files(args.platform, args.input)
    rows = read_rows(files)
    from_dt = parse_datetime(args.from_date)
    to_dt = parse_datetime(args.to_date, end_of_day=True)
    config_price, currency = read_cost_config(args.platform)
    aggregated, _gaps = aggregate(rows, args.group_by, from_dt, to_dt, config_price)
    if args.output == "table":
        print_table(aggregated, currency)
    elif args.output == "json":
        write_json(aggregated, args.output_file)
    elif args.output == "csv":
        output = args.output_file or str(project_root() / "reports" / "usage.csv")
        Path(output).parent.mkdir(parents=True, exist_ok=True)
        write_csv(aggregated, output)
        print(f"Wrote {output}")
    elif args.output == "html":
        output = args.output_file or str(project_root() / "reports" / "usage.html")
        Path(output).parent.mkdir(parents=True, exist_ok=True)
        write_html(aggregated, output)
        print(f"Wrote {output}")


if __name__ == "__main__":
    main()
