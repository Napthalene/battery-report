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

## 8. Uninstall

Run from **Administrator PowerShell**:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-windows-service.ps1
```

Optional cleanup of legacy scheduled-task fallback:

```powershell
.\scripts\uninstall-windows-schtasks.cmd
```

## Notes

- The service executable is `bin\windows\BatteryService.WindowsService.exe`.
- Stop the service before rebuilding the wrapper because Windows locks running
  service executables.
- Generated files under `logs\`, `reports\`, `bin\`, and local tools are ignored
  by Git.
- The Windows service starts the estimator script directly; `.ps1` and `.cmd`
  files are helper/installer/CLI scripts, not the service itself.
