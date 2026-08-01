#!/usr/bin/env bash
set -euo pipefail

target_path="/usr/local/bin/batteryservice"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run with sudo/root." >&2
  exit 1
fi

rm -f "$target_path"
echo "Removed BatteryService CLI: $target_path"
