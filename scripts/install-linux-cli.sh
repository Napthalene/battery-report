#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_path="/usr/local/bin/batteryservice"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run with sudo/root." >&2
  exit 1
fi

chmod +x "$project_root/batteryservice.sh"
ln -sfn "$project_root/batteryservice.sh" "$target_path"

echo "Installed BatteryService CLI: $target_path -> $project_root/batteryservice.sh"
echo "Try: batteryservice usage -o table"
