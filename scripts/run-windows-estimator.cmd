@echo off
setlocal

set "PROJECT_ROOT=%~dp0.."
for %%I in ("%PROJECT_ROOT%") do set "PROJECT_ROOT=%%~fI"

cd /d "%PROJECT_ROOT%"
if not exist "%PROJECT_ROOT%\logs" mkdir "%PROJECT_ROOT%\logs"

echo [%DATE% %TIME%] Starting BatteryService estimator as %USERNAME% >> "%PROJECT_ROOT%\logs\runner.log"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PROJECT_ROOT%\scripts\estimate-power-windows.ps1" -ConfigPath "%PROJECT_ROOT%\config\power-estimator.windows.json" -DurationSeconds 0 >> "%PROJECT_ROOT%\logs\runner.log" 2>&1
echo [%DATE% %TIME%] Estimator exited with code %ERRORLEVEL% >> "%PROJECT_ROOT%\logs\runner.log"
