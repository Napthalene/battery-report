#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$project_root"

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required for update." >&2
  exit 1
fi

echo "Updating BatteryService in $project_root"
git pull --ff-only

chmod +x "$project_root/batteryservice.sh" \
  "$project_root/scripts/"*.sh \
  "$project_root/src/linux/batteryservice_linux.py" 2>/dev/null || true

if [[ "$(id -u)" -eq 0 ]]; then
  bash "$project_root/scripts/install-linux-cli.sh"
  if systemctl list-unit-files batteryservice.service >/dev/null 2>&1; then
    bash "$project_root/scripts/install-linux-systemd.sh"
  else
    echo "batteryservice.service is not installed yet. Install with:"
    echo "  sudo bash ./scripts/bootstrap-linux.sh --install"
  fi
else
  echo "Non-root update complete."
  echo "To refresh service/CLI, run:"
  echo "  sudo bash ./scripts/update-linux.sh"
fi
