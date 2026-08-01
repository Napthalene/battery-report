#!/usr/bin/env bash
set -euo pipefail

service_name="batteryservice"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unit_template="$project_root/packaging/linux/batteryservice.service"
unit_path="/etc/systemd/system/${service_name}.service"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run with sudo/root." >&2
  exit 1
fi

sed "s#__PROJECT_ROOT__#$project_root#g" "$unit_template" > "$unit_path"
systemctl daemon-reload
systemctl enable "$service_name.service"
systemctl restart "$service_name.service"
systemctl status "$service_name.service" --no-pager
