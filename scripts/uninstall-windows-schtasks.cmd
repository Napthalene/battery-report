@echo off
setlocal

set "TASK_NAME=BatteryServicePowerEstimator"
set "WATCHDOG_TASK_NAME=BatteryServicePowerEstimatorWatchdog"

schtasks.exe /End /TN "%TASK_NAME%" >nul 2>nul
schtasks.exe /Delete /TN "%TASK_NAME%" /F
schtasks.exe /End /TN "%WATCHDOG_TASK_NAME%" >nul 2>nul
schtasks.exe /Delete /TN "%WATCHDOG_TASK_NAME%" /F >nul 2>nul
