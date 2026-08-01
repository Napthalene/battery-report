#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command_name="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

show_help() {
  cat <<'HELP'
BatteryService CLI

Usage:
  ./batteryservice.sh <command> [options]

Commands:
  help                 Show this help.
  status               Show systemd service status.
  sample               Record one immediate Linux sample.
  start                Start systemd service.
  stop                 Stop systemd service.
  restart              Restart systemd service.
  install-service      Install Linux systemd service. Requires sudo/root.
  uninstall-service    Remove Linux systemd service. Requires sudo/root.
  report               Generate HTML report from Linux CSV. Example: report -Days 7
  tail                 Tail latest Linux minute CSV rows.
  logs                 Show recent systemd journal logs.
  usage                Show usage summary. Example: usage --from 2026-07-31 --group-by day -o table
  probe                Run Linux sensor probe.

Examples:
  ./batteryservice.sh sample
  ./batteryservice.sh report
  sudo ./batteryservice.sh install-service
HELP
}

cd "$project_root"

case "$command_name" in
  help|-h|--help)
    show_help
    ;;
  status)
    systemctl status batteryservice --no-pager
    ;;
  sample)
    python3 ./src/linux/batteryservice_linux.py --config ./config/power-estimator.linux.json --once
    ;;
  start)
    systemctl start batteryservice
    ;;
  stop)
    systemctl stop batteryservice
    ;;
  restart)
    systemctl restart batteryservice
    systemctl status batteryservice --no-pager
    ;;
  install-service)
    bash ./scripts/install-linux-systemd.sh "$@"
    ;;
  uninstall-service)
    bash ./scripts/uninstall-linux-systemd.sh "$@"
    ;;
  report)
    if command -v pwsh >/dev/null 2>&1; then
      pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/export-html-report.ps1 -InputPath ./logs/power-minute-linux.csv "$@"
    elif command -v powershell >/dev/null 2>&1; then
      powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/export-html-report.ps1 -InputPath ./logs/power-minute-linux.csv "$@"
    else
      echo "PowerShell is required for HTML report generation." >&2
      exit 1
    fi
    ;;
  tail)
    tail -n 10 ./logs/power-minute-linux.csv
    ;;
  logs)
    journalctl -u batteryservice -n 100 --no-pager
    ;;
  usage)
    python3 ./src/usage_report.py usage --platform linux "$@"
    ;;
  probe)
    bash ./scripts/probe-linux.sh "$@"
    ;;
  *)
    echo "Unknown command: $command_name" >&2
    show_help
    exit 1
    ;;
esac
