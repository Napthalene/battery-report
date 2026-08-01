# BatteryService

Software-only laptop power tracking for Windows and Linux.

For deployment from a fresh clone, see `DEPLOY-WINDOWS.md` and
`DEPLOY-LINUX.md`.

The first implementation step is a sensor probe. It discovers whether the
machine exposes direct system power, CPU/GPU power, battery telemetry, or Linux
power counters. That result determines the best service provider to implement.

## Windows probe

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\probe-windows.ps1 -DurationSeconds 60 -IntervalSeconds 5 -OutputPath .\probe-windows.json
```

## LibreHardwareMonitor probe

If `tools\LibreHardwareMonitor.zip` is present, extract it and run:

```powershell
Expand-Archive -LiteralPath .\tools\LibreHardwareMonitor.zip -DestinationPath .\tools\LibreHardwareMonitor -Force
powershell -ExecutionPolicy Bypass -File .\scripts\probe-librehardwaremonitor.ps1 -DurationSeconds 60 -IntervalSeconds 5 -OutputPath .\probe-librehardwaremonitor.json
```

## Linux probe

```bash
bash ./scripts/probe-linux.sh 60 5 ./probe-linux.json
```

## Planned service

- Runs automatically on boot.
- Samples every few seconds.
- Stores one-minute averages in SQLite.
- Calculates energy as watt-hours.
- Supports Windows Service and Linux `systemd`.
- Uses provider priority from direct system power to CPU/GPU estimate.

See `docs/measurement-strategy.md` for the current measurement model.

## CLI

Windows:

```powershell
cd C:\Users\sedla\Documents\BatteryService
.\batteryservice.ps1 help
.\batteryservice.ps1 sample
.\batteryservice.ps1 report
.\batteryservice.ps1 open-report
.\batteryservice.ps1 report -Days 7
.\batteryservice.ps1 open-report -Days 30
.\batteryservice.ps1 status
.\batteryservice.ps1 usage --from 2026-07-31 --group-by day -o table
```

Linux:

```bash
cd /path/to/BatteryService
./batteryservice.sh help
./batteryservice.sh sample
./batteryservice.sh report
./batteryservice.sh status
./batteryservice.sh usage --from 2026-07-31 --group-by day -o table
./batteryservice.sh start-serve --days 7 --port 8765
```

Install the Linux CLI globally:

```bash
sudo ./batteryservice.sh install-cli
batteryservice usage -o table
```

Update an installed Linux clone:

```bash
cd /path/to/BatteryService
sudo batteryservice update
```

Update an installed Windows clone from Administrator PowerShell:

```powershell
cd C:\Users\sedla\Documents\BatteryService
.\batteryservice.ps1 update
```

Usage command options:

```text
usage --from yyyy-mm-dd --to yyyy-mm-dd --group-by raw|hour|day|week|month|year -o table|json|csv|html
```

Examples:

```powershell
.\batteryservice.ps1 usage --from 2026-07-31 --group-by hour -o table
.\batteryservice.ps1 usage --from 2026-07-01 --group-by day -o csv --output-file .\reports\july-usage.csv
.\batteryservice.ps1 usage --group-by month -o html --output-file .\reports\monthly-usage.html
```

```bash
./batteryservice.sh usage --from 2026-07-31 --group-by hour -o table
./batteryservice.sh usage --group-by month -o json
```

## Linux LAN report server

Serve the live report from the Linux VM over HTTP:

```bash
batteryservice start-serve --days 7 --port 8765
```

Then open it from another machine on the same local network:

```text
http://VM-IP:8765/
```

Useful options:

```text
start-serve --host 0.0.0.0 --port 8765 --days 7 --group-by day
```

The server is intentionally simple and has no authentication. Bind it only on a
trusted LAN/VPN, or use `--host 127.0.0.1` for SSH tunnel-only access.

## Windows estimator prototype

This prototype estimates plugged-in consumption from CPU load, GPU watts, and a
configurable platform baseline:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\estimate-power-windows.ps1 -DurationSeconds 300
```

Write one aggregate immediately:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\estimate-power-windows.ps1 -Once
```

## Auto-start on Windows

Preferred: install the real Windows Service wrapper from an elevated
Administrator PowerShell. The `.ps1` files below are installer/build helpers;
the installed service is a Windows Service managed by the Windows Service
Control Manager.

```powershell
cd C:\Users\sedla\Documents\BatteryService
powershell -ExecutionPolicy Bypass -File .\scripts\build-windows-service.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows-service.ps1
```

Check it:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\get-windows-service-status.ps1
Get-Content -Tail 20 .\logs\windows-service.log
Get-Content -Tail 5 .\logs\power-minute.csv
```

Remove it:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-windows-service.ps1
```

Equivalent direct Windows Service commands:

```powershell
sc.exe stop BatteryServicePowerEstimator
sc.exe start BatteryServicePowerEstimator
sc.exe query BatteryServicePowerEstimator
sc.exe delete BatteryServicePowerEstimator
```

If you need to rebuild the service executable, stop the service first:

```powershell
sc.exe stop BatteryServicePowerEstimator
taskkill /IM BatteryService.WindowsService.exe /F
powershell -ExecutionPolicy Bypass -File .\scripts\build-windows-service.ps1
```

Legacy fallback: install as a startup scheduled task running as `SYSTEM`:

Install as a startup scheduled task running as `SYSTEM`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows-scheduled-task.ps1 -StartNow
```

If PowerShell scheduled-task registration is blocked, use the `schtasks.exe`
fallback from an elevated command prompt:

```cmd
scripts\install-windows-schtasks-system.cmd
```

Install the watchdog too, so logging restarts automatically if the long-running
process exits:

```cmd
scripts\install-windows-schtasks-watchdog-system.cmd
```

Check status:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\get-windows-scheduled-task-status.ps1
```

Restart the running scheduled task after script changes:

```cmd
scripts\restart-windows-schtasks.cmd
```

Remove it:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-windows-scheduled-task.ps1
```

Fallback uninstall:

```cmd
scripts\uninstall-windows-schtasks.cmd
```

If sensor access behaves differently as `SYSTEM`, install it for the current user
at logon instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows-scheduled-task.ps1 -RunAsCurrentUser -StartNow
```

Fallback current-user logon task:

```cmd
scripts\install-windows-schtasks.cmd
```

Both fallback installers schedule `scripts\run-windows-estimator.cmd`, which
starts the estimator from the repository root with absolute config paths.

If Task Scheduler access is blocked, install a current-user Startup-folder
shortcut:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows-startup-shortcut.ps1
```

Remove the shortcut:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-windows-startup-shortcut.ps1
```

## HTML usage report

Generate a standalone graphical report from the minute CSV:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\export-html-report.ps1
```

The default output is `reports\power-report.html`.

Limit report data to the last N days:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\export-html-report.ps1 -Days 7
```

The report separates `CPU + GPU + baseline` system use from battery charging
use, then shows the combined total. Charging watts come from firmware charge
rate when available, or from battery percent/capacity delta when enough data is
available. If Windows exposes neither rate nor capacity delta, charging is shown
as `0 W` with `charging_source = unavailable`.

## Linux systemd service

The Linux logger uses Python 3 and reads Linux power telemetry from:

- `/sys/class/power_supply`
- `/sys/class/hwmon/*/power*_input`
- `/sys/class/powercap/intel-rapl:*`
- `/proc/stat` as a CPU-load fallback

Install on Linux:

```bash
cd /path/to/BatteryService
sudo bash ./scripts/install-linux-systemd.sh
```

The `.sh` file is only an installer helper. The installed service is a real
`systemd` service at `/etc/systemd/system/batteryservice.service`.

Equivalent direct Linux service commands:

```bash
sudo cp ./packaging/linux/batteryservice.service /etc/systemd/system/batteryservice.service
sudo sed -i "s#__PROJECT_ROOT__#$(pwd)#g" /etc/systemd/system/batteryservice.service
sudo systemctl daemon-reload
sudo systemctl enable batteryservice
sudo systemctl restart batteryservice
```

Check it:

```bash
systemctl status batteryservice --no-pager
journalctl -u batteryservice -n 100 --no-pager
tail -n 5 ./logs/power-minute-linux.csv
```

Remove it:

```bash
sudo bash ./scripts/uninstall-linux-systemd.sh
```
