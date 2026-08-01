#!/usr/bin/env bash
set -euo pipefail

script_path="${BASH_SOURCE[0]}"
while [[ -L "$script_path" ]]; do
  script_dir="$(cd -P "$(dirname "$script_path")" && pwd)"
  link_target="$(readlink "$script_path")"
  if [[ "$link_target" == /* ]]; then
    script_path="$link_target"
  else
    script_path="$script_dir/$link_target"
  fi
done
project_root="$(cd -P "$(dirname "$script_path")" && pwd)"
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
  install-cli          Install batteryservice command to /usr/local/bin. Requires sudo/root.
  uninstall-cli        Remove batteryservice command from /usr/local/bin. Requires sudo/root.
  update               Pull latest Git changes and refresh service/CLI.
  report               Generate HTML report from Linux CSV. Example: report -Days 7
  start-serve          Serve live report on LAN. Example: start-serve --port 8765 --days 7
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
  install-cli)
    bash ./scripts/install-linux-cli.sh "$@"
    ;;
  uninstall-cli)
    bash ./scripts/uninstall-linux-cli.sh "$@"
    ;;
  update)
    bash ./scripts/update-linux.sh "$@"
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
  start-serve)
    python3 ./src/report_server.py --platform linux "$@"
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
