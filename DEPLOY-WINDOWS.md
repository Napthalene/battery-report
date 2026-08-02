# Deploying BatteryService on Windows

BatteryService is cloneable and deployable on Windows as a real Windows Service.
The service wrapper is compiled locally with the built-in .NET Framework C#
compiler and managed by the Windows Service Control Manager.

## 1. Clone

```powershell
git clone <your-repo-url> BatteryService
cd BatteryService
```

If Git blocks the local repository because of ownership, run:

```powershell
git config --global --add safe.directory "$PWD"
```

## 2. Add LibreHardwareMonitor

For GPU/CPU sensor access, place LibreHardwareMonitor here:

```text
tools\LibreHardwareMonitor.zip
```

Then extract it:

```powershell
Expand-Archive -LiteralPath .\tools\LibreHardwareMonitor.zip -DestinationPath .\tools\LibreHardwareMonitor -Force
```

The repo ignores `tools\LibreHardwareMonitor\` and `tools\*.zip`, so local
binaries are not committed.

## 3. Check prerequisites

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Check
```

Required:

- Windows PowerShell
- .NET Framework C# compiler (`csc.exe`)
- Administrator PowerShell for service installation

Optional:

- LibreHardwareMonitor package for richer hardware sensors

## 4. Test one sample

```powershell
.\batteryservice.ps1 sample
.\batteryservice.ps1 tail
```

## 5. Install service

Run from **Administrator PowerShell**:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Install
```

Equivalent direct commands:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-windows-service.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows-service.ps1
```

## 6. Operate service

```powershell
sc.exe query BatteryServicePowerEstimator
sc.exe stop BatteryServicePowerEstimator
sc.exe start BatteryServicePowerEstimator
```

Using the CLI:

```powershell
.\batteryservice.ps1 status
.\batteryservice.ps1 logs
.\batteryservice.ps1 tail
```

## 7. Reports and usage summaries

```powershell
.\batteryservice.ps1 report
.\batteryservice.ps1 open-report
.\batteryservice.ps1 usage --from 2026-07-31 --group-by day -o table
.\batteryservice.ps1 usage --group-by month -o html --output-file .\reports\monthly.html
```

## 8. Serve report on the local network

Start a live HTTP report server:

```powershell
.\batteryservice.ps1 start-serve --days 7 --port 8765
```

Open it from another machine on the same LAN:

```text
http://WINDOWS-IP:8765/
```

Find the Windows IP with:

```powershell
ipconfig
```

The default bind address is `0.0.0.0`, which exposes the report on the machine's
network interfaces. Use it only on a trusted LAN/VPN, or bind to localhost for
tunnel-only access:

```powershell
.\batteryservice.ps1 start-serve --host 127.0.0.1 --port 8765
```

Windows Defender Firewall may ask whether Python can accept private-network
connections. Allow it only for trusted private networks.

## 9. Uninstall

Run from **Administrator PowerShell**:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-windows-service.ps1
```

Optional cleanup of legacy scheduled-task fallback:

```powershell
.\scripts\uninstall-windows-schtasks.cmd
```

## 10. Update existing deployment

After changes are pushed to GitHub, run from Administrator PowerShell:

```powershell
cd C:\Users\sedla\Documents\BatteryService
.\batteryservice.ps1 update
```

To pull Git changes without touching the Windows Service:

```powershell
.\batteryservice.ps1 update -SkipService
```

## Notes

- The service executable is `bin\windows\BatteryService.WindowsService.exe`.
- Stop the service before rebuilding the wrapper because Windows locks running
  service executables.
- Generated files under `logs\`, `reports\`, `bin\`, and local tools are ignored
  by Git.
- The Windows service starts the estimator script directly; `.ps1` and `.cmd`
  files are helper/installer/CLI scripts, not the service itself.
