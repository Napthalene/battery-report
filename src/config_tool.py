#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


DEFAULT_CURRENCY = "\u20ac"


def project_root():
    return Path(__file__).resolve().parents[1]


def config_path(platform):
    name = "power-estimator.linux.json" if platform == "linux" else "power-estimator.windows.json"
    return project_root() / "config" / name


def parse_price(value):
    match = re.search(r"[-+]?\d+(?:[.,]\d+)?", value or "")
    if not match:
        raise ValueError(f"Could not parse kWh price from: {value}")
    return float(match.group(0).replace(",", "."))


def normalize_currency(value):
    if value in {None, "", "â‚¬"}:
        return DEFAULT_CURRENCY
    return value


def read_config(path):
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_config(path, config):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="BatteryService config helper")
    parser.add_argument("--platform", choices=["windows", "linux"], required=True)
    parser.add_argument("--cost", help="Cost of 1 kWh in EUR, e.g. 0.4")
    args = parser.parse_args()

    path = config_path(args.platform)
    config = read_config(path)
    if args.cost is not None:
        price = parse_price(args.cost)
        config["electricityPricePerKwh"] = price
        config["electricityCurrency"] = normalize_currency(config.get("electricityCurrency"))
        write_config(path, config)
        print(f"Set electricity price to {price:.6g}{config['electricityCurrency']}/kWh in {path}")
        return

    price = float(config.get("electricityPricePerKwh", 0.0) or 0.0)
    currency = normalize_currency(config.get("electricityCurrency"))
    print(f"{price:.6g}{currency}/kWh")


if __name__ == "__main__":
    main()
