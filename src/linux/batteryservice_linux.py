#!/usr/bin/env python3
import argparse
import csv
import json
import math
import os
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


CSV_COLUMNS = [
    "timestamp_utc",
    "sample_count",
    "duration_seconds",
    "average_watts",
    "average_system_watts",
    "average_charging_watts",
    "average_total_with_charging_watts",
    "minimum_watts",
    "maximum_watts",
    "average_cpu_load_percent",
    "average_cpu_estimated_watts",
    "average_gpu_watts",
    "platform_baseline_watts",
    "battery_status",
    "battery_power_online",
    "battery_charging",
    "battery_discharging",
    "average_battery_charge_rate_watts",
    "average_battery_discharge_rate_watts",
    "average_battery_rate_watts",
    "average_battery_voltage_volts",
    "average_battery_charge_percent",
    "battery_full_charged_capacity_mwh",
    "battery_designed_capacity_mwh",
    "charging_source",
    "system_energy_wh",
    "charging_energy_wh",
    "total_energy_wh",
    "energy_wh",
    "source",
    "confidence",
]


running = True


def stop(_signum, _frame):
    global running
    running = False


def utc_now():
    return datetime.now(timezone.utc)


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None


def read_number(path, divisor=1.0):
    text = read_text(path)
    if text in (None, ""):
        return None
    try:
        return float(text) / divisor
    except ValueError:
        return None


def finite_or_zero(value):
    if value is None or not math.isfinite(value):
        return 0.0
    return value


def round_value(value, digits=3):
    return round(finite_or_zero(value), digits)


def project_root():
    return Path(__file__).resolve().parents[2]


def absolute_path(root, path):
    path = Path(path)
    if path.is_absolute():
        return path
    return root / path


def load_config(path):
    config_path = Path(path)
    if not config_path.is_absolute():
        config_path = project_root() / config_path
    with config_path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def read_proc_stat_total():
    text = read_text("/proc/stat")
    if not text:
        return None
    first_line = text.splitlines()[0]
    parts = first_line.split()
    if not parts or parts[0] != "cpu":
        return None
    values = [int(part) for part in parts[1:]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    total = sum(values)
    return total, idle


class CpuLoadReader:
    def __init__(self):
        self.previous = read_proc_stat_total()

    def read_percent(self):
        current = read_proc_stat_total()
        previous = self.previous
        self.previous = current
        if current is None or previous is None:
            return 0.0
        total_delta = current[0] - previous[0]
        idle_delta = current[1] - previous[1]
        if total_delta <= 0:
            return 0.0
        return max(0.0, min(100.0, (1.0 - idle_delta / total_delta) * 100.0))


class RaplReader:
    def __init__(self):
        self.zones = []
        for zone in Path("/sys/class/powercap").glob("intel-rapl:*"):
            energy_path = zone / "energy_uj"
            max_path = zone / "max_energy_range_uj"
            name = read_text(zone / "name") or zone.name
            if energy_path.exists() and name.lower() in ("package-0", "package-1", "core", "uncore"):
                self.zones.append({
                    "energy_path": energy_path,
                    "max_path": max_path,
                    "last_energy": read_number(energy_path),
                    "last_time": time.monotonic(),
                })

    def read_watts(self):
        total_watts = 0.0
        found = False
        now = time.monotonic()
        for zone in self.zones:
            energy = read_number(zone["energy_path"])
            if energy is None or zone["last_energy"] is None:
                zone["last_energy"] = energy
                zone["last_time"] = now
                continue
            elapsed = now - zone["last_time"]
            delta = energy - zone["last_energy"]
            if delta < 0:
                max_energy = read_number(zone["max_path"])
                if max_energy:
                    delta = (max_energy - zone["last_energy"]) + energy
            zone["last_energy"] = energy
            zone["last_time"] = now
            if elapsed > 0 and delta >= 0:
                total_watts += (delta / 1_000_000.0) / elapsed
                found = True
        return total_watts if found else None


def estimate_cpu_watts(load_percent, config):
    idle = float(config.get("cpuIdleWatts", 2.5))
    tdp = float(config.get("cpuTdpWatts", 45.0))
    exponent = float(config.get("cpuCurveExponent", 1.35))
    ratio = max(0.0, min(1.0, load_percent / 100.0))
    return idle + max(0.0, tdp - idle) * math.pow(ratio, exponent)


def read_hwmon_gpu_watts():
    total = 0.0
    found = False
    for path in Path("/sys/class/hwmon").glob("hwmon*/power*_input"):
        chip = read_text(path.parent / "name") or ""
        label = read_text(path.with_name(path.name.replace("_input", "_label"))) or ""
        name = f"{chip} {label}".lower()
        if not any(token in name for token in ("gpu", "amdgpu", "nvidia", "radeon")):
            continue
        microwatts = read_number(path)
        if microwatts and 0 < microwatts < 10_000_000_000:
            total += microwatts / 1_000_000.0
            found = True
    return total if found else 0.0


def read_power_supply(config):
    batteries = []
    mains_online = False
    for device in Path("/sys/class/power_supply").glob("*"):
        supply_type = (read_text(device / "type") or "").lower()
        if supply_type in ("mains", "usb", "usb-c", "usb_pd"):
            mains_online = read_text(device / "online") == "1" or mains_online
        if supply_type == "battery":
            batteries.append(device)

    battery = batteries[0] if batteries else None
    status = "unknown"
    percent = None
    voltage = None
    charge_rate = None
    discharge_rate = None
    battery_rate = None
    remaining_mwh = None
    full_mwh = float(config.get("batteryFullChargeCapacityWh", 0.0)) * 1000.0
    design_mwh = float(config.get("batteryDesignCapacityWh", 0.0)) * 1000.0

    if battery is not None:
        status = (read_text(battery / "status") or "unknown").lower()
        percent = read_number(battery / "capacity")
        voltage = read_number(battery / "voltage_now", 1_000_000.0)
        power_now = read_number(battery / "power_now", 1_000_000.0)
        energy_now = read_number(battery / "energy_now", 1000.0)
        energy_full = read_number(battery / "energy_full", 1000.0)
        energy_design = read_number(battery / "energy_full_design", 1000.0)
        if energy_now is not None:
            remaining_mwh = energy_now
        if energy_full:
            full_mwh = energy_full
        if energy_design:
            design_mwh = energy_design
        if power_now and power_now < 10000:
            battery_rate = power_now
            if status == "charging":
                charge_rate = power_now
            elif status == "discharging":
                discharge_rate = power_now

    return {
        "status": status,
        "power_online": mains_online,
        "charging": status == "charging",
        "discharging": status == "discharging",
        "charge_rate_watts": charge_rate,
        "discharge_rate_watts": discharge_rate,
        "battery_rate_watts": battery_rate,
        "voltage_volts": voltage,
        "remaining_capacity_mwh": remaining_mwh,
        "full_capacity_mwh": full_mwh,
        "design_capacity_mwh": design_mwh,
        "charge_percent": percent,
    }


def sample(config, cpu_reader, rapl_reader):
    timestamp = utc_now()
    load_percent = cpu_reader.read_percent()
    rapl_watts = rapl_reader.read_watts()
    if rapl_watts is not None and rapl_watts > 0:
        cpu_watts = rapl_watts
        source = "rapl_cpu+gpu_hwmon+baseline"
        confidence = "measured_cpu_estimated_total"
    else:
        cpu_watts = estimate_cpu_watts(load_percent, config)
        source = "cpu_load_curve+gpu_hwmon+baseline"
        confidence = "estimated"
    gpu_watts = read_hwmon_gpu_watts()
    baseline = float(config.get("platformBaselineWatts", 7.0))
    system_watts = cpu_watts + gpu_watts + baseline
    battery = read_power_supply(config)
    return {
        "timestamp": timestamp,
        "cpu_load_percent": load_percent,
        "cpu_watts": cpu_watts,
        "gpu_watts": gpu_watts,
        "baseline_watts": baseline,
        "system_watts": system_watts,
        "battery": battery,
        "source": source,
        "confidence": confidence,
    }


def average(values):
    values = [value for value in values if value is not None]
    return sum(values) / len(values) if values else None


def aggregate(samples):
    first = samples[0]
    last = samples[-1]
    duration_seconds = max(1.0, (last["timestamp"] - first["timestamp"]).total_seconds() + 1.0)
    system_watts = average([item["system_watts"] for item in samples]) or 0.0
    charging_watts = average([item["battery"]["charge_rate_watts"] for item in samples]) or 0.0
    charging_source = "battery_charge_rate" if charging_watts > 0 else "unavailable"
    first_battery = first["battery"]
    last_battery = last["battery"]
    if charging_watts <= 0 and (first_battery["charging"] or last_battery["charging"]):
        capacity_mwh = last_battery["full_capacity_mwh"] or last_battery["design_capacity_mwh"]
        first_percent = first_battery["charge_percent"]
        last_percent = last_battery["charge_percent"]
        if capacity_mwh and first_percent is not None and last_percent is not None and last_percent > first_percent:
            charging_energy_from_percent = ((last_percent - first_percent) / 100.0) * (capacity_mwh / 1000.0)
            charging_watts = charging_energy_from_percent / (duration_seconds / 3600.0)
            charging_source = "battery_percent_delta"
    system_energy_wh = system_watts * duration_seconds / 3600.0
    charging_energy_wh = charging_watts * duration_seconds / 3600.0
    total_watts = system_watts + charging_watts
    total_energy_wh = system_energy_wh + charging_energy_wh
    battery_status = last_battery["status"]
    return {
        "timestamp_utc": first["timestamp"].isoformat().replace("+00:00", "Z"),
        "sample_count": len(samples),
        "duration_seconds": round(duration_seconds, 3),
        "average_watts": round(total_watts, 3),
        "average_system_watts": round(system_watts, 3),
        "average_charging_watts": round(charging_watts, 3),
        "average_total_with_charging_watts": round(total_watts, 3),
        "minimum_watts": round(min(item["system_watts"] for item in samples), 3),
        "maximum_watts": round(max(item["system_watts"] for item in samples), 3),
        "average_cpu_load_percent": round(average([item["cpu_load_percent"] for item in samples]) or 0.0, 3),
        "average_cpu_estimated_watts": round(average([item["cpu_watts"] for item in samples]) or 0.0, 3),
        "average_gpu_watts": round(average([item["gpu_watts"] for item in samples]) or 0.0, 3),
        "platform_baseline_watts": round(first["baseline_watts"], 3),
        "battery_status": battery_status,
        "battery_power_online": last_battery["power_online"],
        "battery_charging": last_battery["charging"],
        "battery_discharging": last_battery["discharging"],
        "average_battery_charge_rate_watts": round(average([item["battery"]["charge_rate_watts"] for item in samples]) or 0.0, 3),
        "average_battery_discharge_rate_watts": round(average([item["battery"]["discharge_rate_watts"] for item in samples]) or 0.0, 3),
        "average_battery_rate_watts": round(average([item["battery"]["battery_rate_watts"] for item in samples]) or 0.0, 3),
        "average_battery_voltage_volts": round(average([item["battery"]["voltage_volts"] for item in samples]) or 0.0, 3),
        "average_battery_charge_percent": round(average([item["battery"]["charge_percent"] for item in samples]) or 0.0, 3),
        "battery_full_charged_capacity_mwh": round(last_battery["full_capacity_mwh"] or 0.0, 3),
        "battery_designed_capacity_mwh": round(last_battery["design_capacity_mwh"] or 0.0, 3),
        "charging_source": charging_source,
        "system_energy_wh": round(system_energy_wh, 6),
        "charging_energy_wh": round(charging_energy_wh, 6),
        "total_energy_wh": round(total_energy_wh, 6),
        "energy_wh": round(total_energy_wh, 6),
        "source": first["source"],
        "confidence": first["confidence"],
    }


def write_aggregate(path, row):
    path.parent.mkdir(parents=True, exist_ok=True)
    exists = path.exists()
    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS)
        if not exists:
            writer.writeheader()
        writer.writerow(row)


def main():
    parser = argparse.ArgumentParser(description="BatteryService Linux logger")
    parser.add_argument("--config", default="config/power-estimator.linux.json")
    parser.add_argument("--duration-seconds", type=int, default=0)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    config = load_config(args.config)
    root = project_root()
    output_path = absolute_path(root, config.get("minuteOutputPath", "logs/power-minute-linux.csv"))
    interval = max(1, int(config.get("sampleIntervalSeconds", 5)))
    cpu_reader = CpuLoadReader()
    rapl_reader = RaplReader()
    samples = []
    minute_start = time.monotonic()
    end_time = time.monotonic() + args.duration_seconds if args.duration_seconds > 0 else None
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    time.sleep(0.2)
    while running:
        item = sample(config, cpu_reader, rapl_reader)
        samples.append(item)
        print(
            f"{item['timestamp'].isoformat()} system={item['system_watts']:.2f}W "
            f"cpu={item['cpu_watts']:.2f}W gpu={item['gpu_watts']:.2f}W "
            f"load={item['cpu_load_percent']:.1f}% battery={item['battery']['status']}",
            flush=True,
        )
        should_flush = args.once or (time.monotonic() - minute_start >= 60)
        if end_time is not None and time.monotonic() + interval > end_time:
            should_flush = True
        if should_flush and samples:
            row = aggregate(samples)
            write_aggregate(output_path, row)
            print(f"Saved aggregate: {row['average_watts']:.3f} W, {row['energy_wh']:.6f} Wh", flush=True)
            samples = []
            minute_start = time.monotonic()
            if args.once:
                break
        if end_time is not None and time.monotonic() >= end_time:
            break
        time.sleep(interval)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"BatteryService Linux logger failed: {error}", file=sys.stderr)
        raise
