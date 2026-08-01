#!/usr/bin/env bash
set -euo pipefail

service_name="batteryservice"
unit_path="/etc/systemd/system/${service_name}.service"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run with sudo/root." >&2
  exit 1
fi

systemctl stop "$service_name.service" 2>/dev/null || true
systemctl disable "$service_name.service" 2>/dev/null || true
rm -f "$unit_path"
systemctl daemon-reload
echo "Removed $service_name.service"
