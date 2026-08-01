#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

show_help() {
  cat <<'HELP'
BatteryService Linux bootstrap

Usage:
  bash ./scripts/bootstrap-linux.sh --check
  sudo bash ./scripts/bootstrap-linux.sh --install

Options:
  --check      Check prerequisites and print suggested next steps.
  --install    Check prerequisites and install the systemd service.
  --help       Show this help.
HELP
}

check_command() {
  local command_name="$1"
  local required="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    echo "OK: $command_name -> $(command -v "$command_name")"
    return 0
  fi

  if [[ "$required" == "required" ]]; then
    echo "MISSING: $command_name is required" >&2
    return 1
  fi

  echo "OPTIONAL: $command_name not found"
  return 0
}

run_check() {
  local failed=0

  echo "BatteryService root: $project_root"
  check_command python3 required || failed=1
  check_command systemctl required || failed=1
  check_command git optional || true
  check_command pwsh optional || true

  if [[ ! -f "$project_root/src/linux/batteryservice_linux.py" ]]; then
    echo "MISSING: src/linux/batteryservice_linux.py" >&2
    failed=1
  fi

  if [[ ! -f "$project_root/config/power-estimator.linux.json" ]]; then
    echo "MISSING: config/power-estimator.linux.json" >&2
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "Bootstrap check failed." >&2
    return 1
  fi

  chmod +x "$project_root/batteryservice.sh" \
    "$project_root/scripts/"*.sh \
    "$project_root/src/linux/batteryservice_linux.py" 2>/dev/null || true

  echo "Bootstrap check passed."
}

install_service() {
  run_check

  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: --install must be run with sudo/root." >&2
    exit 1
  fi

  bash "$project_root/scripts/install-linux-systemd.sh"
}

command_name="${1:---help}"

case "$command_name" in
  --check)
    run_check
    ;;
  --install)
    install_service
    ;;
  --help|-h|help)
    show_help
    ;;
  *)
    echo "Unknown option: $command_name" >&2
    show_help
    exit 1
    ;;
esac
